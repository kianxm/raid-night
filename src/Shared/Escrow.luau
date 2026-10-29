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

	Transport (server layer, not this module):
	  - debitDefender runs wherever the defender's profile is loaded. If the defender is online,
	    deliver it as a ProfileStore message so their session applies it; if offline, the raider's
	    server loads the profile, applies it and releases it.
	  - Recovery (`recover`) runs on either party's load and on a timer. It never debits afresh:
	    a Pending record settles from the defender's saved debit, or is voided if there is none.
	  - Idempotency entries (appliedTransfers) of a still-open raid are never pruned.
]]

local Types = require("./Types")
local Config = require("./Config")
local RaidRules = require("./RaidRules")

type PlayerProfile = Types.PlayerProfile
type EscrowRecord = Types.EscrowRecord
type AppliedTransfer = Types.AppliedTransfer
type Critter = Types.Critter
type EscrowOpenIndex = Types.EscrowOpenIndex

local Escrow = {}

-- Persistence interface the driver needs. The server implements it with ProfileStore and a
-- DataStore for records; the simulation implements it in memory with crash injection.
-- `load*` returns a working copy; nothing persists until the matching `save*` is called.
export type Store = {
	loadRecord: (raidId: string) -> EscrowRecord?,
	saveRecord: (record: EscrowRecord) -> (),
	loadProfile: (userId: number) -> PlayerProfile,
	saveProfile: (profile: PlayerProfile) -> (),
}

local function cloneCritter(critter: Critter): Critter
	return table.clone(critter)
end

function Escrow.create(
	raidId: string,
	raiderUserId: number,
	defenderUserId: number,
	critterUid: string?,
	glowRequested: number,
	isRevenge: boolean,
	now: number
): EscrowRecord
	assert(raiderUserId ~= defenderUserId, "Escrow.create: raider and defender must differ")
	assert(glowRequested >= 0, "Escrow.create: glowRequested must be >= 0")
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
	}
end

--[[
	Step 1, on the DEFENDER's profile. Takes the grabbed critter (if it is still on a pad and the
	defender is under the daily loss cap) and up to `glowRequested` from storage. Records the
	defender-side consequences (shield, revenge token, log). Idempotent: a repeat returns the
	first result unchanged.
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

	local taken: Critter? = nil
	if record.critterUid then
		local critter = defender.critters[record.critterUid]
		local underLossCap = defender.lossesToday < Config.Limits.maxLossesPerDay
		-- The critter may have moved to the vault, been sold, or been stolen by a concurrent raid
		-- since the snapshot. In those cases the raid still succeeds, with Glow only.
		if critter and critter.placement == "Pad" and underLossCap then
			taken = cloneCritter(critter)
			defender.critters[record.critterUid] = nil
		end
	end

	local glow = math.clamp(math.floor(defender.stored), 0, record.glowRequested)
	defender.stored -= glow

	local applied: AppliedTransfer = {
		role = "Debit",
		at = now,
		critter = taken,
		glow = glow,
	}
	defender.appliedTransfers[record.raidId] = applied

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
	Step 3, on the RAIDER's profile. Adds the escrowed critter (to Inventory, trade-locked) and
	the Glow (banked: loot is safe once home). Idempotent.
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
	return applied
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

-- Cancels a raid before anything moved. Returns false if it is too late to void.
-- Needs the defender's profile: a crash between saving the defender and saving the record
-- leaves the record Pending even though the debit already landed. Voiding then would strand
-- the loot, so the defender's appliedTransfers entry is the real "too late" signal.
function Escrow.void(record: EscrowRecord, defender: PlayerProfile, now: number): boolean
	assert(defender.userId == record.defenderUserId, "void: wrong profile")
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

-- Whether two records describe the same transfer (same raid, parties, request and revenge).
function Escrow.sameTransfer(a: EscrowRecord, b: EscrowRecord): boolean
	return a.raidId == b.raidId
		and a.raiderUserId == b.raiderUserId
		and a.defenderUserId == b.defenderUserId
		and a.critterUid == b.critterUid
		and a.glowRequested == b.glowRequested
		and a.isRevenge == b.isRevenge
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
	if not Escrow.sameTransfer(stored, incoming) then
		return false, "a different transfer already uses this raidId"
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
	the defender if that has not happened yet. Only the call that created the record uses it;
	later paths use `recover`, which never debits afresh. Idempotent. `checkpoint`, if given, is
	called before the defender's first save and after every save; the simulation injects crashes
	there.
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
	Recovery: advances a record using only what is already saved and only the parties that are
	present (`isPresent(userId)`: loaded in this server). Never debits afresh.
	  Pending, defender present: their saved debit for this raid -> record Debited; no debit ->
	    Voided (nothing moved; the defender's session lock means no debit can still land).
	  Debited, raider present: credit and commit.
	Anything whose party is absent is left as is, for that party's next load. Idempotent.
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

	if record.state == "Pending" then
		if not isPresent(record.defenderUserId) then
			return record
		end
		local defender = store.loadProfile(record.defenderUserId)
		local applied = defender.appliedTransfers[raidId]
		if applied == nil then
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
