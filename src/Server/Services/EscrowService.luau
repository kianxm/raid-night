--!strict
--[[
	EscrowService (owner: data agent; every change reviewed by the reviewer agent)

	Turns a successful live raid into a safe transfer using Shared/Escrow.luau, and finishes any
	transfer that a crash or an unconfirmed save left in flight.

	Public API (everything else is private):
	  canStartTransfer(kind, isRevenge?)  may a NEW transfer start? Escrow.canStartTransfer with
	                          Config.Flags: `raids` is the master switch; "Async" and revenge also
	                          need `asyncRaids`; unknown kinds are refused. The only code here that
	                          reads a flag (a Lune test guards this).
	  transferLive(raidId, raiderUserId, defenderUserId, critterUid, glowRequested, isRevenge?,
	               liveBaseRate?)
	                          same-server live steal. Yields (seconds normally, about 2 minutes
	                          worst case). Returns (status, reason):
	                            "Committed"  the loot moved; both saves confirmed
	                            "InFlight"   started, or may have; recovery finishes it. Retry with
	                                         the SAME raidId; never restart the raid under a new one
	                            "Refused"    nothing moved: switch off, bad input, a party not
	                                         loaded, raidId used by another transfer, or Voided
	                          A raidId that already has a record (or is busy or awaiting retry here)
	                          is never re-gated: the call reports its true state and finishes what
	                          it can. Only the call that creates the record debits the defender,
	                          and its same-server retries while this server awaits them (kept
	                          createNonce, below).
	                          critterUid and glowRequested must come from server state (RaidRules
	                          loot math, the server-tracked carry), never from a remote.
	                          liveBaseRate (D-034): Economy.denRate of the owner's den, measured
	                          by RaidService when it accepted the grab, before the owner was
	                          alerted, and kept with the carry. It is the base for the day's first
	                          live loss. nil = not measured (the debit measures the den then). Not
	                          nil and not a finite number >= 0: "Refused" before any write.
	                          Retrying (P0.5): pass IDENTICAL arguments every time (raidId, both
	                          userIds, critterUid, glowRequested, isRevenge, liveBaseRate). Once a
	                          record exists, the same raidId with any other argument returns
	                          "Refused" ("raidId already used by a different transfer") and
	                          changes nothing. While this server awaits a retry of the raid, the
	                          retry reuses the first call's createNonce: a create that landed with
	                          its response lost is still that call's own, so the steal continues
	                          instead of voiding.

	Storage (docs/contracts.md), DataStore "EscrowRecords"; memory instead when
	DataService.persistence() is "Memory" (Studio without API access, or Studio's memory switch,
	the only mode with test profiles). The mode is taken once from a non-nil persistence(), so it
	always matches the profiles' whatever order services start in. While persistence() is nil
	(DataService not started, or ProfileStore still checking) nothing is read or written: every
	call refuses or fails and is retried later (fail closed).
	  Escrow_<raidId>  EscrowRecord: created once, then forward only (Escrow.canReplace runs
	                   inside every UpdateAsync)
	  Open_<userId>    Types.EscrowOpenIndex, for BOTH parties: written before the record, removed
	                   once it is terminal; with no record, only once older than 15 minutes (a
	                   re-add by a retry moves createdAt forward, Escrow.indexAdd)
	Each DataStore call: 4 attempts, 1/2/4 s backoff. Every transform is idempotent.

	New raid: busy lock -> start checks -> index both parties -> create record (with a per-call
	createNonce, so an attempt that landed but errored is still this call's own) -> Escrow.advance
	(debit + saveNow, record Debited, credit + saveNow, record Committed) -> index cleanup in the
	background. Profiles come fresh from DataService.getProfile (accrued first), and a profile
	save counts only when the written data holds this raid's exact appliedTransfers entry.

	Recovery never reads a flag. On every profile load: read Open_<userId>, prune
	appliedTransfers except open raids, then Escrow.recover each open raid (Pending with the
	defender here: their saved debit -> Debited; none -> a confirmed save by this session without
	the entry, then Voided; Debited with the raider here: credit and commit). A sweep retries what
	this server left in flight, with per-raid backoff, while the party the record needs is here
	(Pending: the defender, Debited: the raider); otherwise that party's next load picks it up.

	Studio test profiles (DataService.loadTestProfile, decision D-019) have no load to recover
	from, so DataService refuses to release one while an escrow for it is open here.

	Live loss rules (decision D-031): transferLive creates "Live" records, whose debit takes no
	critter from a den that is live-protected at the debit (Escrow.debitDefender; measured
	against the larger of the day's base and the den's Glow/s then, D-036), measures the day's
	first live loss against the record's liveBaseRate when it has one (D-034), and grants the
	defender nothing when it takes nothing (D-033). Live steals use this same-server path, on the
	two profiles loaded here, until P1.1 adds the cross-server one.

	TODO (P1.1, decision D-012): the void assumes only the creating call debits. Debits delivered
	by ProfileStore message (or applied to an offline profile) will race it. Read the TODO in
	Shared/Escrow.luau before adding any async transport.
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Economy = require(ReplicatedStorage.Shared.Economy)
local Escrow = require(ReplicatedStorage.Shared.Escrow)
local Types = require(ReplicatedStorage.Shared.Types)
local DataService = require(script.Parent.DataService)

type EscrowRecord = Types.EscrowRecord
type EscrowOpenIndex = Types.EscrowOpenIndex
type PlayerProfile = Types.PlayerProfile

export type TransferKind = Types.TransferKind
export type TransferStatus = "Committed" | "InFlight" | "Refused"

local STORE_NAME = "EscrowRecords"
local MAX_RAID_ID_LENGTH = Config.Escrow.maxRaidIdLength
local CALL_RETRY_DELAYS = { 1, 2, 4 } -- seconds between DataStore attempts
local INDEX_STALE_SECONDS = 15 * 60 -- a record-less index entry younger than this may be mid-create
local SWEEP_SECONDS = 15
local RETRY_FIRST_SECONDS = 30
local RETRY_MAX_SECONDS = 30 * 60
local CLOSE_WAIT_SECONDS = 25

local EscrowService = {}

-- `nonce`: the creating call's createNonce, kept for that call's retry (startOrResume).
type Retry = { from: number, need: number, delay: number, nextAt: number, nonce: string? }

local mode: ("DataStore" | "Memory")? = nil
local dataStore: DataStore? = nil
local memory: { [string]: any } = {}
local getOptions = Instance.new("DataStoreGetOptions")
getOptions.UseCache = false -- recovery must see the latest record, not a 4 s cached copy

local busy: { [string]: true } = {} -- raidIds being driven right now in this server
local retry: { [string]: Retry } = {} -- raids this server left in flight
local needsIndex: { [number]: Retry } = {} -- loaded players whose index read failed

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in value do
		copy[k] = deepCopy(v)
	end
	return copy
end

local function isHere(userId: number): boolean
	return DataService.getProfile(userId) ~= nil
end

local function backoff(previous: Retry?, from: number, need: number): Retry
	local delay = if previous then math.min(previous.delay * 2, RETRY_MAX_SECONDS) else RETRY_FIRST_SECONDS
	local nonce = if previous then previous.nonce else nil
	return { from = from, need = need, delay = delay, nextAt = os.clock() + delay, nonce = nonce }
end

-- Where escrow records live: the profiles' mode (D-019), decided once from a non-nil
-- DataService.persistence(). nil until then, and nil is never cached or defaulted, so escrow can
-- never pick DataStore while profiles turn out to be in memory (or the reverse).
local function storage(): ("DataStore" | "Memory")?
	if mode ~= nil then
		return mode
	end
	local decided = DataService.persistence()
	if decided == nil then
		return nil
	end
	if decided == "DataStore" then
		dataStore = DataStoreService:GetDataStore(STORE_NAME)
	else
		warn("[EscrowService] memory persistence: escrow records live in memory for this session")
	end
	mode = decided
	return mode
end

-- storage(), or an error when it is not decided yet: no read or write ever guesses a backend.
local function backend(): "DataStore" | "Memory"
	local decided = storage()
	if decided == nil then
		error("escrow storage not ready: DataService has not decided where profiles live", 0)
	end
	return decided
end

local function withRetries<T>(what: string, fn: () -> T): T
	local lastError: any = nil
	for attempt = 1, #CALL_RETRY_DELAYS + 1 do
		local ok, result = pcall(fn)
		if ok then
			return result
		end
		lastError = result
		if attempt <= #CALL_RETRY_DELAYS then
			task.wait(CALL_RETRY_DELAYS[attempt])
		end
	end
	error(`{what} failed after {#CALL_RETRY_DELAYS + 1} attempts: {lastError}`, 0)
end

local function read(key: string): any
	if backend() == "Memory" then
		return deepCopy(memory[key])
	end
	local store = assert(dataStore, "escrow storage not ready")
	return withRetries(`read {key}`, function()
		return (store:GetAsync(key, getOptions))
	end)
end

-- transform(stored) returns the new value, or nil to leave the key unchanged.
local function update(key: string, transform: (any) -> any)
	if backend() == "Memory" then
		local result = transform(deepCopy(memory[key]))
		if result ~= nil then
			memory[key] = deepCopy(result)
		end
		return
	end
	local store = assert(dataStore, "escrow storage not ready")
	withRetries(`update {key}`, function()
		store:UpdateAsync(key, transform)
	end)
end

local function recordKey(raidId: string): string
	return `Escrow_{raidId}`
end

local function indexKey(userId: number): string
	return `Open_{userId}`
end

local function saveRecord(record: EscrowRecord)
	local refusal: string? = nil
	update(recordKey(record.raidId), function(stored)
		local ok, why = Escrow.canReplace(stored, record)
		refusal = if ok then nil else why
		return if ok then record else nil
	end)
	if refusal then
		error(`escrow record {record.raidId} refused: {refusal}`, 0)
	end
end

-- Write-once (Escrow.decideCreate). Returns the stored record (an existing one wins) and whether
-- it is this call's own: written now, or by an earlier attempt of this call whose response was
-- lost (same createNonce). Only this call's own record may be driven with Escrow.advance.
local function createRecord(record: EscrowRecord): (EscrowRecord, boolean)
	local existing: EscrowRecord? = nil
	local ours = false
	update(recordKey(record.raidId), function(stored: EscrowRecord?)
		local toWrite, isOurs = Escrow.decideCreate(stored, record)
		existing, ours = stored, isOurs
		return toWrite
	end)
	return existing or record, ours
end

local function indexAdd(userId: number, raidId: string, role: "Raider" | "Defender", createdAt: number)
	update(indexKey(userId), function(stored: EscrowOpenIndex?)
		return Escrow.indexAdd(stored, raidId, role, createdAt)
	end)
end

-- Removes one entry; returns true once it is gone. With `staleBefore`, keeps an entry created at
-- or after that time (its record may still be being created). Decided inside the transform.
local function indexRemove(userId: number, raidId: string, staleBefore: number?): boolean
	local gone = false
	update(indexKey(userId), function(stored: EscrowOpenIndex?)
		local entry = if stored then stored[raidId] else nil
		if stored == nil or entry == nil then
			gone = true
			return nil
		end
		if staleBefore and entry.createdAt >= staleBefore then
			gone = false
			return nil
		end
		gone = true
		stored[raidId] = nil
		return stored
	end)
	return gone
end

local function closeIndexes(record: EscrowRecord)
	for _, userId in { record.raiderUserId, record.defenderUserId } do
		local ok, err = pcall(indexRemove, userId, record.raidId)
		if not ok then
			warn(`[EscrowService] index cleanup {record.raidId}/{userId} failed; their next load retries: {err}`)
		end
	end
end

-- Escrow.Store for one raid. Profiles come fresh from DataService each time. `last.record` is a
-- copy of the record as last read or confirmed written, so a drive that errors part-way still
-- knows which party the record needs next.
local function storeFor(raidId: string, last: { record: EscrowRecord? }): Escrow.Store
	return {
		loadRecord = function(id: string): EscrowRecord?
			local record: EscrowRecord? = read(recordKey(id))
			last.record = if record then table.clone(record) else nil
			return record
		end,
		saveRecord = function(record: EscrowRecord)
			saveRecord(record)
			last.record = table.clone(record)
		end,
		loadProfile = function(userId: number): PlayerProfile
			local profile = DataService.getProfile(userId)
			if not profile then
				error(`profile {userId} is not loaded in this server`, 0)
			end
			-- Money model: accrue before `stored` changes. P2.8 GATE (D-032; docs/contracts.md, Money
			-- model): before Config.Flags.purchases turns on, pass the player's
			-- Economy.glowBoostFactor here, or accrue after a call that did. Factor 1 only under-pays
			-- a boosted window, never over-pays, and today every factor is 1 (purchases is off).
			Economy.accrue(profile, os.time())
			return profile
		end,
		saveProfile = function(profile: PlayerProfile)
			if DataService.getProfile(profile.userId) ~= profile then
				error(`profile {profile.userId} changed session before its save`, 0)
			end
			local entry = profile.appliedTransfers[raidId]
			if entry == nil then
				error(`profile {profile.userId} has no entry for {raidId} to save`, 0)
			end
			local role, at = entry.role, entry.at
			local ok, why = DataService.saveNow(profile.userId, function(saved: any): boolean
				local applied = type(saved) == "table"
					and type(saved.appliedTransfers) == "table"
					and saved.appliedTransfers[raidId]
				return type(applied) == "table" and applied.role == role and applied.at == at
			end)
			if not ok then
				error(`save not confirmed: {why}`, 0)
			end
		end,
		-- The void proof (Escrow.recover). Only a save THIS session wrote counts: when another
		-- server has taken the lock, ProfileStore ends this session (IsActive false, so getProfile
		-- no longer returns this table) BEFORE firing OnAfterSave with that server's data, which
		-- may lack the entry only because its debit has not saved yet. A final save on leave does
		-- not count either (the session is already inactive); the void then waits for a later load.
		--
		-- TODO (P1.1, decision D-012; #25 review): one window stays open. saveNow accepts any
		-- OnAfterSave while the session is active, including an autosave whose UpdateAsync was
		-- already in flight: its transform ran while we held the lock, then another server took
		-- the lock (about 40 s with no release from us) and debited, and only then did the
		-- autosave's response arrive. That save "proves" a void the new owner contradicts. Phase 0
		-- accepts it (it needs a DataStore call hanging for over 40 s). The P1.1 void tombstone
		-- must be written INSIDE this proof save (in the saved data that confirm checks), so the
		-- proof and the tombstone land in one write and a later debit sees it and refuses.
		saveProfileWithoutEntry = function(profile: PlayerProfile, id: string)
			assert(id == raidId, "escrow store used for another raid")
			local userId = profile.userId
			if DataService.getProfile(userId) ~= profile then
				error(`profile {userId} changed session before its void proof`, 0)
			end
			local ok, why = DataService.saveNow(userId, function(saved: any): boolean
				return DataService.getProfile(userId) == profile
					and profile.appliedTransfers[raidId] == nil
					and type(saved) == "table"
					and type(saved.appliedTransfers) == "table"
					and saved.appliedTransfers[raidId] == nil
			end)
			if not ok then
				error(`void not proven: {why}`, 0)
			end
		end,
	}
end

-- The party a record needs next: Pending settles where the defender is loaded, Debited where
-- the raider is. With no record seen, `from` (whose index led here).
local function needFor(record: EscrowRecord?, from: number): number
	if record and record.state == "Pending" then
		return record.defenderUserId
	elseif record and record.state == "Debited" then
		return record.raiderUserId
	end
	return from
end

-- Advances one raid as far as it can go. The caller holds busy[raidId]. `live` only for the call
-- that created the record; every other path recovers. `from` is whose index led here.
-- Never reads a kill switch.
local function drive(raidId: string, from: number, live: boolean): (TransferStatus, string?)
	local last: { record: EscrowRecord? } = {}
	local store = storeFor(raidId, last)
	local now = os.time()
	local ok, result = pcall(function(): EscrowRecord?
		if live then
			return Escrow.advance(raidId, store, now)
		end
		return Escrow.recover(raidId, store, now, isHere)
	end)
	if not ok then
		local message = tostring(result)
		if string.find(message, "duplicate", 1, true) then
			warn(`[EscrowService] DUPLICATION ALARM {raidId}: {message}`)
		end
		retry[raidId] = backoff(retry[raidId], from, needFor(last.record, from))
		return "InFlight", message
	end
	local record: EscrowRecord? = result
	if record == nil then
		local cleaned, gone = pcall(indexRemove, from, raidId, os.time() - INDEX_STALE_SECONDS)
		if cleaned and gone then
			retry[raidId] = nil
			return "Refused", "no escrow record"
		end
		retry[raidId] = backoff(retry[raidId], from, from)
		return "InFlight", "no record yet; a create may still be in progress"
	end
	if Escrow.isTerminal(record) then
		retry[raidId] = nil
		task.spawn(closeIndexes, record)
		if record.state == "Voided" then
			return "Refused", "voided: nothing moved"
		end
		return "Committed", nil
	end
	retry[raidId] = backoff(retry[raidId], from, needFor(record, from))
	return "InFlight", `record is {record.state}`
end

local function driveLocked(raidId: string, from: number)
	if busy[raidId] then
		return
	end
	busy[raidId] = true
	local status, reason = drive(raidId, from, false)
	busy[raidId] = nil
	if status == "InFlight" then
		warn(`[EscrowService] {raidId} still in flight: {reason}`)
	end
end

local function recoverUser(userId: number)
	local ok, result = pcall(read, indexKey(userId))
	if not ok or storage() == nil then
		needsIndex[userId] = backoff(needsIndex[userId], userId, userId)
		warn(`[EscrowService] could not read open escrows for {userId}; will retry: {result}`)
		return
	end
	needsIndex[userId] = nil
	local open: EscrowOpenIndex = result or {}
	local profile = DataService.getProfile(userId)
	if profile then
		-- Never prune the idempotency entry of a raid that is still open (docs/contracts.md).
		Escrow.pruneApplied(profile, os.time(), open)
	end
	for raidId in open do
		driveLocked(raidId, userId)
	end
end

local function sweep()
	local clock = os.clock()
	for userId, entry in table.clone(needsIndex) do
		if not isHere(userId) then
			needsIndex[userId] = nil -- their next load reads the index again
		elseif clock >= entry.nextAt then
			recoverUser(userId)
		end
	end
	for raidId, entry in table.clone(retry) do
		if busy[raidId] or clock < entry.nextAt then
			continue
		end
		if not isHere(entry.need) then
			retry[raidId] = nil -- the party it needs settles it from their own index on load
			continue
		end
		driveLocked(raidId, entry.from)
	end
end

-- The ONLY code in this service that reads a kill switch. Recovery never calls it.
function EscrowService.canStartTransfer(kind: TransferKind, isRevenge: boolean?): (boolean, string?)
	return Escrow.canStartTransfer(Config.Flags, kind, isRevenge)
end

local function startOrResume(
	raidId: string,
	raiderUserId: number,
	defenderUserId: number,
	critterUid: string?,
	glowRequested: number,
	isRevenge: boolean,
	liveBaseRate: number?
): (TransferStatus, string?)
	if raiderUserId == defenderUserId then
		return "Refused", "raider and defender are the same player"
	end
	if type(glowRequested) ~= "number" or not (glowRequested >= 0 and glowRequested < math.huge) then
		return "Refused", "glowRequested must be a finite number >= 0"
	end
	local baseOk, baseWhy = Escrow.checkLiveBaseRate("Live", liveBaseRate)
	if not baseOk then
		return "Refused", baseWhy -- before any write; Escrow.create would assert on it
	end
	local now = os.time()
	-- A "Live" record: its debit applies the live loss rules (Escrow.debitDefender, D-031), with
	-- the grab-time base for the day's first live loss (D-034).
	local record = Escrow.create(
		raidId,
		raiderUserId,
		defenderUserId,
		critterUid,
		math.floor(glowRequested),
		isRevenge,
		now,
		"Live",
		liveBaseRate
	)
	-- This call's own create (decideCreate). A retry while this server awaits one for the raid
	-- reuses the first call's nonce, so a create that landed with its response lost stays its own.
	local awaiting = retry[raidId]
	local nonce = if awaiting and awaiting.nonce then awaiting.nonce else HttpService:GenerateGUID(false)
	record.createNonce = nonce

	-- An existing raid is never re-gated: report its true state and finish what can be finished.
	local existing: EscrowRecord? = read(recordKey(raidId))
	if existing then
		if not Escrow.sameTransfer(existing, record) then
			return "Refused", "raidId already used by a different transfer"
		end
		local _, ours = Escrow.decideCreate(existing, record)
		return drive(raidId, raiderUserId, ours)
	end
	if awaiting and not awaiting.nonce then
		return "InFlight", "an earlier attempt's record may still land; recovery decides"
	end

	-- A new raid: the only place a kill switch applies.
	local allowed, why = EscrowService.canStartTransfer("Live", isRevenge)
	if not allowed then
		return "Refused", why
	end
	if not isHere(raiderUserId) or not isHere(defenderUserId) then
		return "Refused", "both profiles must be loaded in this server"
	end

	-- Index both parties first, so recovery can find the record from either side. A failure here
	-- leaves at most index entries, which are dropped once stale: nothing moved.
	local indexed, indexError = pcall(function()
		indexAdd(raiderUserId, raidId, "Raider", now)
		indexAdd(defenderUserId, raidId, "Defender", now)
	end)
	if not indexed then
		return "Refused", `could not start: {indexError}`
	end

	local created, stored, ours = pcall(createRecord, record)
	if not created then
		local entry = backoff(awaiting, raiderUserId, raiderUserId)
		entry.nonce = nonce -- the create may have landed: the retry must still own it
		retry[raidId] = entry
		return "InFlight", `record create not confirmed: {stored}`
	end
	if not Escrow.sameTransfer(stored, record) then
		return "Refused", "raidId already used by a different transfer"
	end
	local status, reason = drive(raidId, raiderUserId, ours)
	local entry = retry[raidId]
	if ours and entry then
		entry.nonce = nonce -- still in flight: the caller's retry continues as this call
	end
	return status, reason
end

function EscrowService.transferLive(
	raidId: string,
	raiderUserId: number,
	defenderUserId: number,
	critterUid: string?,
	glowRequested: number,
	isRevenge: boolean?,
	liveBaseRate: number?
): (TransferStatus, string?)
	if type(raidId) ~= "string" or #raidId == 0 or #raidId > MAX_RAID_ID_LENGTH then
		return "Refused", `raidId must be 1 to {MAX_RAID_ID_LENGTH} characters`
	end
	if busy[raidId] then
		return "InFlight", "already being advanced"
	end
	if storage() == nil then
		return "Refused", "escrow storage not ready" -- no profile can be loaded yet either
	end
	busy[raidId] = true -- held from before the first write until the drive ends
	local ok, status, reason = pcall(
		startOrResume,
		raidId,
		raiderUserId,
		defenderUserId,
		critterUid,
		glowRequested,
		isRevenge == true,
		liveBaseRate
	)
	busy[raidId] = nil
	if not ok then
		return "InFlight", `could not confirm the raid's state; retry with the same raidId: {status}`
	end
	return status, reason
end

-- Why a Studio test profile must not be released yet (an escrow for it is open here), or nil.
-- Test profiles exist only with memory persistence, where this server's Open_ index is the whole
-- truth: an entry is written (with no yield after busy is taken) before the record, and removed
-- only once the record is terminal. Retry entries are checked too, belt and braces. Any other
-- storage mode fails closed: then memory is not the whole truth.
local function openEscrowFor(userId: number): string?
	if storage() ~= "Memory" then
		return "escrow storage is not in memory, so open escrows cannot be ruled out"
	end
	local open = memory[indexKey(userId)]
	local raidId: string? = if open then next(open) else nil
	if raidId == nil then
		for id, entry in retry do
			if entry.from == userId or entry.need == userId then
				raidId = id
				break
			end
		end
	end
	return if raidId then `escrow {raidId} is still open` else nil
end

function EscrowService.start()
	-- Recovery is never behind a flag (docs/contracts.md: Kill switches).
	DataService.onProfileLoaded(function(player: Player)
		recoverUser(player.UserId)
	end)
	DataService.guardTestRelease(openEscrowFor)
	task.spawn(function()
		while true do
			task.wait(SWEEP_SECONDS)
			sweep()
		end
	end)
	game:BindToClose(function()
		local deadline = os.clock() + CLOSE_WAIT_SECONDS
		while next(busy) ~= nil and os.clock() < deadline do
			task.wait(0.5)
		end
	end)
end

return EscrowService
