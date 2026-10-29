--!strict
--[[
	Escrow: moves raid loot from a defender's profile to a raider's profile without ever
	duplicating or losing a critter, even if a server crashes between any two writes.

	Why this exists: Roblox DataStore has no transactions across keys. The defender and the
	raider are separate keys, usually loaded (session-locked) by different servers. So a
	transfer is split into steps that are each a single-key write, and every step is idempotent
	(safe to repeat). An escrow record, stored under its own key per raidId, tracks progress.

	State machine:

	    Pending ──debitDefender + markDebited──▶ Debited ──creditRaider + markCommitted──▶ Committed
	       │
	       └──void (only before any debit)──▶ Voided

	Invariants (checked by tests/specs/EscrowSimulation.spec.luau):
	  1. A critter uid exists in exactly one place: one profile, or in flight for one raid.
	     In flight means taken from the defender but not yet credited to the raider; it is held
	     durably in the record (Debited) or, if a crash hit between the two saves, in the
	     defender's appliedTransfers entry until recovery copies it to the record.
	  2. Glow is conserved: Glow taken from a defender equals Glow given to the raider.
	  3. Repeating any step, any number of times, changes nothing after the first success.
	  4. Daily loss limits hold at the debit, by the record's kind (decision D-031). Live: a
	     critter still on its pad is taken exactly when the den is not protected at the debit
	     (RaidRules.liveProtectedAtDebit: today's live losses below protectionLossShare of the
	     largest of the day's base, the den's Glow/s just before the debit (D-036) and the
	     record's grab-time rate (D-037)), so the steal that crosses the line is the last while
	     the den stays as it is; refilling it reopens it, and shrinking it during a carry cannot
	     refuse that carry. The day's first live loss sets the base from the record's grab-time
	     base when it has one (D-034). Async: nothing once the defender lost maxLossesPerDay
	     critters that day.
	  5. A Live debit that takes nothing grants nothing (D-033): no shield, revenge token, pair
	     count or raid-log entry; only its idempotency entry.
	  6. The raider's side (P1.3d): an Async credit that moved something (a critter or Glow)
	     records, in the same write as its idempotency entry, the raider's Outgoing raid-log
	     entry, one pair count against the defender, and for a revenge record naming a token
	     (revengeRaidId) that token removed (D-054). An empty Async credit and every Live credit
	     record none of them (D-033, D-052), so a failed revenge keeps its token, and a repeat
	     changes nothing.

	Transport (server layer, not this module), by the record's kind:
	  - Live: same-server steals. EscrowService.transferLive runs `advance` with both profiles
	    loaded in its own server. Only the call that creates a record ever debits, and its
	    same-server retries while that server awaits them (they keep its createNonce). Recovery
	    (`recover`) never debits a Live record afresh: Pending settles from the defender's saved
	    debit, or is voided once a confirmed save proves this server still holds the defender's
	    session and no debit was saved.
	  - Async (P1.1; closes decision D-012's race): never voided. Every path (`recover`, from any
	    server, as often as it likes) delivers the debit: on the defender's profile when it is
	    loaded here, otherwise through `Store.debitAbsent` (one atomic write to a profile no
	    server holds, or a message to the server that holds it, which delivers it there). The
	    defender's saved data decides alone: debitDefender is idempotent by raidId, so a debit
	    delivered twice, late or by two servers lands once, and with no void there is nothing for
	    a late debit to race.
	  - Recovery runs on either party's load and on a timer. Idempotency entries
	    (appliedTransfers) of a still-open raid are never pruned.
]]

local Types = require("./Types")
local Config = require("./Config")
local RaidRules = require("./RaidRules")
local Economy = require("./Economy")

type PlayerProfile = Types.PlayerProfile
type EscrowRecord = Types.EscrowRecord
type AppliedTransfer = Types.AppliedTransfer
type Critter = Types.Critter
type EscrowOpenIndex = Types.EscrowOpenIndex
type TransferKind = Types.TransferKind

local Escrow = {}

-- Persistence interface the driver needs. The server implements it with ProfileStore and a
-- DataStore for records; the simulation implements it in memory with crash injection.
-- `load*` returns a working copy; nothing persists until the matching `save*` is called.
-- `saveProfileWithoutEntry` is the void proof: it returns only once a save written by a session
-- that still holds the profile's lock has landed with NO appliedTransfers entry for `raidId`,
-- and errors otherwise (a stale session whose lock another server took can never pass it).
-- `debitAbsent` (Async records only) delivers the debit to a defender who is not loaded here:
-- it runs Escrow.debitAbsentProfile (accrue to the debit, then debitDefender) on their latest
-- saved profile in one atomic write that lands only while no server holds that profile, and
-- returns the saved entry; or, when a server holds it, asks that server (a message) and returns
-- nil. It errors when it could do neither.
export type Store = {
	loadRecord: (raidId: string) -> EscrowRecord?,
	saveRecord: (record: EscrowRecord) -> (),
	loadProfile: (userId: number) -> PlayerProfile,
	saveProfile: (profile: PlayerProfile) -> (),
	saveProfileWithoutEntry: (profile: PlayerProfile, raidId: string) -> (),
	debitAbsent: ((record: EscrowRecord, now: number) -> AppliedTransfer?)?,
}

local function cloneCritter(critter: Critter): Critter
	return table.clone(critter)
end

-- A record's liveBaseRate is kept to this many steps per Glow/s. A short decimal survives the
-- DataStore's JSON round trip exactly, so a retry's fresh record still equals the stored one
-- (Escrow.sameTransfer compares it) even if a tuning value makes den rates long decimals.
local BASE_RATE_STEPS = 1000

--[[
	May a record of this kind carry this grab-time base (decision D-034)? nil always may (no
	measurement). Otherwise only a Live record, and only a finite number >= 0 (NaN, inf and
	negatives are refused; so is a rate so large that rounding it overflows). Escrow.create
	asserts it; EscrowService refuses a call that fails it before writing anything.
]]
function Escrow.checkLiveBaseRate(kind: TransferKind, liveBaseRate: any): (boolean, string?)
	if liveBaseRate == nil then
		return true, nil
	end
	if kind ~= "Live" then
		return false, "only a Live transfer carries a liveBaseRate"
	end
	if type(liveBaseRate) ~= "number" or not (liveBaseRate >= 0 and liveBaseRate * BASE_RATE_STEPS < math.huge) then
		return false, "liveBaseRate must be nil or a finite number >= 0"
	end
	return true, nil
end

--[[
	May a record carry this revengeRaidId (P1.3d)? It names the raider's own revenge token (the
	raidId of the raid on them that granted it), which the record's credit marks used. nil always
	may (not a revenge raid, or no token named). Otherwise only an Async revenge record, and only a
	raidId-shaped string (1 to Config.Escrow.maxRaidIdLength characters). Live revenge spends no
	token yet (D-052). Escrow.create asserts it; EscrowService refuses a call that fails it before
	writing anything.
]]
function Escrow.checkRevengeRaidId(kind: TransferKind, isRevenge: boolean, revengeRaidId: any): (boolean, string?)
	if revengeRaidId == nil then
		return true, nil
	end
	if kind ~= "Async" then
		return false, "only an Async transfer carries a revengeRaidId"
	end
	if isRevenge ~= true then
		return false, "only a revenge transfer carries a revengeRaidId"
	end
	if type(revengeRaidId) ~= "string" or #revengeRaidId == 0 or #revengeRaidId > Config.Escrow.maxRaidIdLength then
		return false, `revengeRaidId must be nil or 1 to {Config.Escrow.maxRaidIdLength} characters`
	end
	return true, nil
end

-- `kind` is required: it picks the debit's daily loss rule, so no caller may leave it to chance.
-- `liveBaseRate` (Live only, D-034): Economy.denRate of the defender's den when the grab was
-- accepted; stored rounded to the nearest 0.001 Glow/s. nil = not measured.
-- `revengeRaidId` (Async revenge only, P1.3d): the raider's revenge token this raid uses, from
-- server state (the raid's start); nil = none named.
function Escrow.create(
	raidId: string,
	raiderUserId: number,
	defenderUserId: number,
	critterUid: string?,
	glowRequested: number,
	isRevenge: boolean,
	now: number,
	kind: TransferKind,
	liveBaseRate: number?,
	revengeRaidId: string?
): EscrowRecord
	assert(raiderUserId ~= defenderUserId, "Escrow.create: raider and defender must differ")
	assert(glowRequested >= 0, "Escrow.create: glowRequested must be >= 0")
	assert(kind == "Live" or kind == "Async", `Escrow.create: unknown kind {kind}`)
	local baseOk, baseWhy = Escrow.checkLiveBaseRate(kind, liveBaseRate)
	assert(baseOk, `Escrow.create: {baseWhy}`)
	local revengeOk, revengeWhy = Escrow.checkRevengeRaidId(kind, isRevenge, revengeRaidId)
	assert(revengeOk, `Escrow.create: {revengeWhy}`)
	return {
		raidId = raidId,
		raiderUserId = raiderUserId,
		defenderUserId = defenderUserId,
		critterUid = critterUid,
		glowRequested = glowRequested,
		state = "Pending",
		critter = nil,
		glow = 0,
		isRevenge = isRevenge,
		createdAt = now,
		updatedAt = now,
		kind = kind,
		liveBaseRate = if liveBaseRate then math.floor(liveBaseRate * BASE_RATE_STEPS + 0.5) / BASE_RATE_STEPS else nil,
		revengeRaidId = revengeRaidId,
	}
end

-- A record's kind. Missing means "Live": every record written before the field existed is a
-- Phase 0 live steal (decision D-031).
function Escrow.kindOf(record: EscrowRecord): TransferKind
	return record.kind or "Live"
end

--[[
	Step 1, on the DEFENDER's profile. Takes the grabbed critter if it is still on a pad and the
	den's daily loss rule allows it (decision D-031): a Live record takes nothing from a den that
	is live-protected at the debit (RaidRules.liveProtectedAtDebit, read with the critter still in
	the den: the largest of the day's base, the den's Glow/s (D-036) and the record's grab-time
	rate (D-037)), an Async record nothing once the defender is at Config.Limits.maxLossesPerDay.
	Glow from storage: a Live record up to `glowRequested`; an Async record (P1.1) the raid's
	share (RaidRules.lootGlow) of what is stored at this debit, which the server accrues first,
	never the snapshot's figure. Never more than is stored. Records the defender-side consequences:
	the live loss value (with the record's grab-time base on the day's first live loss, D-034),
	then shield, pair count, revenge token and log (RaidRules.recordIncoming). A Live debit that
	took no critter and no Glow grants none of those (decision D-033): an empty steal must not
	use up the raider's pair slot or reward the defender. Its appliedTransfers entry is still
	written, for idempotency.
	Idempotent: a repeat returns the first result unchanged.
]]
function Escrow.debitDefender(defender: PlayerProfile, record: EscrowRecord, now: number): AppliedTransfer
	assert(defender.userId == record.defenderUserId, "debitDefender: wrong profile")
	local existing = defender.appliedTransfers[record.raidId]
	if existing then
		assert(existing.role == "Debit", "debitDefender: raidId already used for a credit")
		return existing
	end
	assert(record.state == "Pending", `debitDefender: record is {record.state}, expected Pending`)

	RaidRules.resetDailyIfNeeded(defender, now)

	local live = Escrow.kindOf(record) == "Live"
	local taken: Critter? = nil
	if record.critterUid then
		local critter = defender.critters[record.critterUid]
		local mayLose = if live
			then not RaidRules.liveProtectedAtDebit(defender, now, record.liveBaseRate)
			else defender.lossesToday < Config.Limits.maxLossesPerDay
		-- The critter may have moved to the vault, been sold, or been stolen by a concurrent raid
		-- since the snapshot, or the den may be at its daily limit. In those cases the raid still
		-- succeeds, with Glow only.
		if critter and critter.placement == "Pad" and mayLose then
			if live then
				-- While it is still in the den; the base is the grab's when the record has one.
				RaidRules.recordLiveLoss(defender, critter, now, record.liveBaseRate)
			end
			taken = cloneCritter(critter)
			defender.critters[record.critterUid] = nil
		end
	end

	-- Live: up to the record's request. Async (P1.1): the raid's share (RaidRules.lootGlow, the one
	-- formula) of what is stored now, which the server accrued up to this debit; the snapshot's
	-- request is only the estimate the raid showed. Never more than is stored.
	local storedNow = math.floor(defender.stored)
	local glow = if live
		then math.clamp(storedNow, 0, record.glowRequested)
		else math.clamp(
			RaidRules.lootGlow({ storedGlow = storedNow } :: any, record.isRevenge),
			0,
			math.max(storedNow, 0)
		)
	defender.stored -= glow

	local applied: AppliedTransfer = {
		role = "Debit",
		at = now,
		critter = taken,
		glow = glow,
	}
	defender.appliedTransfers[record.raidId] = applied

	if live and taken == nil and glow == 0 then
		return applied -- an empty live commit grants nothing (D-033)
	end
	RaidRules.recordIncoming(
		defender,
		record.raidId,
		record.raiderUserId,
		if taken then taken.speciesId else nil,
		glow,
		record.isRevenge,
		now
	)

	return applied
end

--[[
	The debit for a defender no server holds, run inside the server's one atomic write to their
	saved profile (Store.debitAbsent). First the den's offline income up to `now` (Money model:
	accrue before `stored` changes), so an Async debit takes its share of what is stored at the
	debit; then debitDefender. A repeat (this raid's debit already saved) changes nothing, not
	even the accrual. Returns (write, applied): write is false for a repeat.
]]
function Escrow.debitAbsentProfile(
	defender: PlayerProfile,
	record: EscrowRecord,
	now: number
): (boolean, AppliedTransfer)
	local fresh = defender.appliedTransfers[record.raidId] == nil
	if fresh then
		-- Factor 1 on purpose: offline income is unboosted (VIP is online-only, D-061 (2);
		-- Config.Purchases.vipBoostsOffline is false). A defender loaded in a server accrues at
		-- their factor there instead (EscrowService's loadProfile, through IncomeService.accrue).
		-- Reversing vipBoostsOffline must revisit this accrue.
		Economy.accrue(defender, now)
	end
	return fresh, Escrow.debitDefender(defender, record, now)
end

-- Step 2, on the RECORD. Stores what was actually taken. Idempotent.
function Escrow.markDebited(record: EscrowRecord, applied: AppliedTransfer, now: number)
	if record.state == "Debited" or record.state == "Committed" then
		return
	end
	assert(record.state == "Pending", `markDebited: record is {record.state}`)
	record.critter = if applied.critter then cloneCritter(applied.critter) else nil
	record.glow = applied.glow
	record.state = "Debited"
	record.updatedAt = now
end

--[[
	The raider-side consequences of an Async credit (P1.3d), from the record and the credit only:
	the Outgoing raid-log entry and the pair count against the defender (RaidRules.recordOutgoing,
	the count canRaid's pair limit reads), and, for a revenge record that names a token
	(revengeRaidId), that token removed (D-054: one revenge raid per token), if it is still there
	and targets this defender. Only creditRaider calls it, for a fresh credit that moved something, so it lands in
	the same write as the credit's appliedTransfers entry: once per raidId, never on a repeat.
]]
local function recordRaiderSide(raider: PlayerProfile, record: EscrowRecord, given: Critter?, now: number)
	RaidRules.recordOutgoing(
		raider,
		record.raidId,
		record.defenderUserId,
		true,
		if given then given.speciesId else nil,
		record.glow,
		record.isRevenge,
		now
	)
	local tokenId = record.revengeRaidId
	local token = if record.isRevenge and tokenId then raider.revengeTokens[tokenId] else nil
	if tokenId and token and token.targetUserId == record.defenderUserId then
		raider.revengeTokens[tokenId] = nil -- one revenge raid per token (D-054)
	end
end

--[[
	Step 3, on the RAIDER's profile. Adds the escrowed critter (to Inventory, trade-locked) and
	the Glow (banked: loot is safe once home). An Async credit that moved something also records
	the raid on the raider (recordRaiderSide: Outgoing log, pair count, revenge token); an empty
	one (nothing moved: no critter, no Glow) records nothing, like an empty live debit (D-033),
	and a Live credit records nothing (D-052). Idempotent: a repeat returns the first result and
	changes nothing.
]]
function Escrow.creditRaider(raider: PlayerProfile, record: EscrowRecord, now: number): AppliedTransfer
	assert(raider.userId == record.raiderUserId, "creditRaider: wrong profile")
	local existing = raider.appliedTransfers[record.raidId]
	if existing then
		assert(existing.role == "Credit", "creditRaider: raidId already used for a debit")
		return existing
	end
	assert(
		record.state == "Debited" or record.state == "Committed",
		`creditRaider: record is {record.state}, expected Debited`
	)

	local given: Critter? = nil
	if record.critter then
		local critter = cloneCritter(record.critter)
		assert(raider.critters[critter.uid] == nil, `creditRaider: uid {critter.uid} already owned (duplicate)`)
		critter.placement = "Inventory"
		critter.padIndex = nil
		critter.acquiredAt = now
		critter.stolenLockUntil = now + Config.Raid.stolenTradeLockSeconds
		raider.critters[critter.uid] = critter
		given = cloneCritter(critter)
	end

	raider.glow += record.glow

	local applied: AppliedTransfer = {
		role = "Credit",
		at = now,
		critter = given,
		glow = record.glow,
	}
	raider.appliedTransfers[record.raidId] = applied

	if Escrow.kindOf(record) == "Async" and (given ~= nil or record.glow > 0) then
		recordRaiderSide(raider, record, given, now)
	end
	return applied
end

--[[
	Whether `saved` (an appliedTransfers entry read back from saved data, any shape) is exactly
	`expected`: same role, time, Glow and critter, every critter field alike. The server confirms
	a profile save with it, so a debit only counts once the very entry it will record is saved:
	a stale session's own debit can never be confirmed by another server's save of a different
	one for the same raid in the same second (the record's loot is always the surviving debit's).
]]
function Escrow.sameApplied(expected: AppliedTransfer, saved: any): boolean
	if type(saved) ~= "table" then
		return false
	end
	if saved.role ~= expected.role or saved.at ~= expected.at or saved.glow ~= expected.glow then
		return false
	end
	local a, b = expected.critter, saved.critter
	if a == nil or b == nil then
		return a == nil and b == nil
	end
	if type(b) ~= "table" then
		return false
	end
	for key, value in a :: any do
		if b[key] ~= value then
			return false
		end
	end
	for key in b do
		if (a :: any)[key] == nil then
			return false
		end
	end
	return true
end

-- Step 4, on the RECORD. Terminal. Idempotent.
function Escrow.markCommitted(record: EscrowRecord, now: number)
	if record.state == "Committed" then
		return
	end
	assert(record.state == "Debited", `markCommitted: record is {record.state}`)
	record.state = "Committed"
	record.updatedAt = now
end

-- Cancels a Live raid before anything moved. Returns false if it is too late to void, and always
-- for an Async record, which is never voided (P1.1): any server may still deliver its debit.
-- Needs the defender's profile: a crash between saving the defender and saving the record
-- leaves the record Pending even though the debit already landed. Voiding then would strand
-- the loot, so the defender's appliedTransfers entry is the real "too late" signal.
function Escrow.void(record: EscrowRecord, defender: PlayerProfile, now: number): boolean
	assert(defender.userId == record.defenderUserId, "void: wrong profile")
	if Escrow.kindOf(record) == "Async" then
		return false
	end
	if record.state == "Voided" then
		return true
	end
	if record.state ~= "Pending" or defender.appliedTransfers[record.raidId] ~= nil then
		return false
	end
	record.state = "Voided"
	record.updatedAt = now
	return true
end

function Escrow.isTerminal(record: EscrowRecord): boolean
	return record.state == "Committed" or record.state == "Voided"
end

--[[
	Kill switches (docs/contracts.md, approved by Kian 2026-10-28): may a NEW raid or transfer of
	this kind start? `raids` is the master switch for every kind. "Async" raids, and any revenge
	raid, also need `asyncRaids`. Unknown kinds are refused. Pass `Config.Flags` in.

	Switches only stop new transfers. Nothing below (advance and its steps) reads a flag, so a
	record already in Pending or Debited always finishes.
]]
export type KillSwitches = { raids: boolean, asyncRaids: boolean }

function Escrow.canStartTransfer(flags: KillSwitches, kind: string, isRevenge: boolean?): (boolean, string?)
	if kind ~= "Live" and kind ~= "Async" then
		return false, `unknown transfer kind {kind}`
	end
	if not flags.raids then
		return false, "raids are switched off"
	end
	if (kind == "Async" or isRevenge) and not flags.asyncRaids then
		return false, if isRevenge then "revenge raids are switched off" else "async raids are switched off"
	end
	return true, nil
end

-- Whether two records describe the same transfer (same raid, parties, request, revenge, kind,
-- grab-time base and revenge token; a missing kind is "Live", a missing liveBaseRate or
-- revengeRaidId matches only a missing one).
function Escrow.sameTransfer(a: EscrowRecord, b: EscrowRecord): boolean
	return a.raidId == b.raidId
		and a.raiderUserId == b.raiderUserId
		and a.defenderUserId == b.defenderUserId
		and a.critterUid == b.critterUid
		and a.glowRequested == b.glowRequested
		and a.isRevenge == b.isRevenge
		and Escrow.kindOf(a) == Escrow.kindOf(b)
		and a.liveBaseRate == b.liveBaseRate
		and a.revengeRaidId == b.revengeRaidId
end

local FORWARD: { [string]: { [string]: true } } = {
	Pending = { Pending = true, Debited = true, Voided = true },
	Debited = { Debited = true, Committed = true },
	Committed = { Committed = true },
	Voided = { Voided = true },
}

--[[
	The record store's write rule: may `incoming` replace `stored` (nil = no record yet)? A record
	is created once, in Pending, and then only moves forward along the state machine. A repeat of
	the same state is allowed only if it agrees on the loot. Pure; the server checks it inside its
	DataStore update, and the simulation's store asserts it on every write.
]]
function Escrow.canReplace(stored: EscrowRecord?, incoming: EscrowRecord): (boolean, string?)
	if stored == nil then
		if incoming.state == "Pending" then
			return true, nil
		end
		return false, `no record to move to {incoming.state}`
	end
	-- This also pins liveBaseRate (D-034) and revengeRaidId (P1.3d) exactly: never filled in,
	-- changed or dropped.
	if not Escrow.sameTransfer(stored, incoming) then
		return false, "a different transfer already uses this raidId"
	end
	if stored.createNonce ~= incoming.createNonce then
		return false, "the creating call's nonce never changes"
	end
	if stored.kind ~= incoming.kind then
		return false, "a record's kind never changes" -- not even filling in a missing one
	end
	local allowed = FORWARD[stored.state]
	if not allowed or not allowed[incoming.state] then
		return false, `cannot move from {stored.state} to {incoming.state}`
	end
	if stored.state == "Debited" or stored.state == "Committed" then
		local storedUid = if stored.critter then stored.critter.uid else nil
		local incomingUid = if incoming.critter then incoming.critter.uid else nil
		if storedUid ~= incomingUid or stored.glow ~= incoming.glow then
			return false, "conflicting loot for this raidId"
		end
	end
	return true, nil
end

--[[
	The record store's create rule (inside the server's UpdateAsync). Returns the record to write
	(nil = leave the key as is) and whether the stored record is this call's own: written now, or
	by an earlier attempt of the same call whose response was lost (same createNonce). Only the
	call that owns the create may drive it with `advance`; any other caller must `recover`.
]]
function Escrow.decideCreate(stored: EscrowRecord?, incoming: EscrowRecord): (EscrowRecord?, boolean)
	if stored == nil then
		return incoming, true
	end
	return nil, incoming.createNonce ~= nil and stored.createNonce == incoming.createNonce
end

--[[
	The open-index rule for adding a raid (inside the server's UpdateAsync). Returns the index to
	write, or nil when nothing changes. Adding a raid already listed (a retry with the same raidId)
	keeps its role and moves createdAt to the later time, so the retry's create is protected by
	the 15-minute staleness rule again (an entry with no record is removed only once stale).
]]
function Escrow.indexAdd(
	stored: EscrowOpenIndex?,
	raidId: string,
	role: "Raider" | "Defender",
	createdAt: number
): EscrowOpenIndex?
	local open: EscrowOpenIndex = stored or {}
	local existing = open[raidId]
	if existing and existing.createdAt >= createdAt then
		return nil
	end
	open[raidId] = { role = if existing then existing.role else role, createdAt = createdAt }
	return open
end

-- Saves a debit the defender's profile already holds, then records it. Shared by advance and
-- recover so both settle a debit the same way.
local function commitDebit(
	store: Store,
	record: EscrowRecord,
	defender: PlayerProfile,
	applied: AppliedTransfer,
	now: number,
	check: (string) -> ()
)
	store.saveProfile(defender)
	check("savedDefender")
	Escrow.markDebited(record, applied, now)
	store.saveRecord(record)
	check("savedRecordDebited")
end

local function creditAndCommit(store: Store, record: EscrowRecord, now: number, check: (string) -> ())
	local raider = store.loadProfile(record.raiderUserId)
	Escrow.creditRaider(raider, record, now)
	store.saveProfile(raider)
	check("savedRaider")
	Escrow.markCommitted(record, now)
	store.saveRecord(record)
	check("savedRecordCommitted")
end

--[[
	The live path: drives a record to a terminal state, one single-key write at a time, debiting
	the defender if that has not happened yet. Only the call that created a Live record uses it
	(and its same-server retries, which keep its createNonce); later paths use `recover`, which
	never debits a Live record afresh. Async records are driven by `recover` from every path.
	Idempotent. `checkpoint`, if given, is called before the defender's first save and after
	every save; the simulation injects crashes there.
]]
function Escrow.advance(raidId: string, store: Store, now: number, checkpoint: ((string) -> ())?): EscrowRecord?
	local function check(name: string)
		if checkpoint then
			checkpoint(name)
		end
	end

	local record = store.loadRecord(raidId)
	if not record then
		return nil
	end

	if record.state == "Pending" then
		local defender = store.loadProfile(record.defenderUserId)
		local applied = Escrow.debitDefender(defender, record, now)
		check("debitedUnsaved")
		commitDebit(store, record, defender, applied, now, check)
	end

	if record.state == "Debited" then
		creditAndCommit(store, record, now, check)
	end

	return record
end

--[[
	An Async record (P1.1): never voided; its debit is delivered from wherever this runs, then
	the raider is credited where they are present. The defender loaded here: debit and save
	their profile (a stale session's save fails, so nothing is recorded). Absent:
	store.debitAbsent, which writes the debit to a profile no server holds and returns the saved
	entry, or asks the holding server by message and returns nil (that server's recovery
	finishes it). debitDefender's idempotency makes every repeat, from any server, a no-op once
	a debit is saved; the daily loss rule is applied at whichever delivery lands first.
]]
local function settleAsync(
	record: EscrowRecord,
	store: Store,
	now: number,
	isPresent: (userId: number) -> boolean,
	check: (string) -> ()
): EscrowRecord
	if record.state == "Pending" then
		if isPresent(record.defenderUserId) then
			local defender = store.loadProfile(record.defenderUserId)
			local applied = Escrow.debitDefender(defender, record, now)
			check("debitedUnsaved")
			commitDebit(store, record, defender, applied, now, check)
		else
			local debitAbsent = assert(store.debitAbsent, "recover: this store cannot reach an absent defender")
			local applied = debitAbsent(record, now)
			check("deliveredDebit")
			if applied == nil then
				return record -- the server that holds the defender delivers it
			end
			Escrow.markDebited(record, applied, now)
			store.saveRecord(record)
			check("savedRecordDebited")
		end
	end

	if record.state == "Debited" and isPresent(record.raiderUserId) then
		creditAndCommit(store, record, now, check)
	end

	return record
end

--[[
	Recovery: advances a record using only the parties that are present (`isPresent(userId)`:
	loaded in this server). Idempotent.
	A Live record never debits afresh, only from what is already saved:
	  Pending, defender present: their saved debit for this raid -> record Debited; no debit ->
	    first prove it (store.saveProfileWithoutEntry: a save by a session that still holds the
	    defender's lock, without an entry), then Voided. A server whose session went stale (another
	    server took the lock and may hold the debit) fails the proof and leaves the record alone.
	  Debited, raider present: credit and commit.
	  Anything whose party is absent is left as is, for that party's next load.
	An Async record is never voided: settleAsync delivers its debit (to an absent defender too)
	and credits the raider where present.
]]
function Escrow.recover(
	raidId: string,
	store: Store,
	now: number,
	isPresent: (userId: number) -> boolean,
	checkpoint: ((string) -> ())?
): EscrowRecord?
	local function check(name: string)
		if checkpoint then
			checkpoint(name)
		end
	end

	local record = store.loadRecord(raidId)
	if not record then
		return nil
	end

	if Escrow.kindOf(record) == "Async" then
		return settleAsync(record, store, now, isPresent, check)
	end

	if record.state == "Pending" then
		if not isPresent(record.defenderUserId) then
			return record
		end
		local defender = store.loadProfile(record.defenderUserId)
		local applied = defender.appliedTransfers[raidId]
		if applied == nil then
			store.saveProfileWithoutEntry(defender, raidId) -- errors unless proven: no void
			check("provedNoDebit")
			Escrow.void(record, defender, now)
			store.saveRecord(record)
			check("savedRecordVoided")
			return record
		end
		assert(applied.role == "Debit", "recover: raidId already used for a credit")
		commitDebit(store, record, defender, applied, now, check)
	end

	if record.state == "Debited" and isPresent(record.raiderUserId) then
		creditAndCommit(store, record, now, check)
	end

	return record
end

-- Drops idempotency entries older than the retention window, except for raids still listed in
-- the player's open-escrow index (`open`): those entries are the only proof a step already ran,
-- and an open escrow can stay open for longer than the window while a party is away.
function Escrow.pruneApplied(profile: PlayerProfile, now: number, open: EscrowOpenIndex): number
	local removed = 0
	for raidId, applied in profile.appliedTransfers do
		if open[raidId] == nil and now - applied.at > Config.Escrow.appliedTransferRetentionSeconds then
			profile.appliedTransfers[raidId] = nil
			removed += 1
		end
	end
	return removed
end

return Escrow
