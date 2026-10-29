--!strict
--[[
	EscrowService (owner: data agent; every change reviewed by the reviewer agent)

	Turns a successful raid into a safe transfer using Shared/Escrow.luau, and finishes any
	transfer that a crash or an unconfirmed save left in flight.

	Public API (everything else is private):
	  canStartTransfer(kind, isRevenge?)  may a NEW transfer start? Escrow.canStartTransfer with
	                          Config.Flags: `raids` is the master switch; "Async" and revenge also
	                          need `asyncRaids`; unknown kinds are refused
	  transferLive(raidId, raiderUserId, defenderUserId, critterUid, glowRequested, isRevenge?)
	                          same-server live steal; both profiles must be loaded HERE. Yields
	                          (seconds normally, about 2 minutes worst case). Returns (status, reason):
	                            "Committed"  the critter and Glow moved, both saves confirmed
	                            "InFlight"   started but not finished; recovery finishes it
	                            "Refused"    nothing moved (switch off, bad input, not loaded)
	                          raidId: 1 to 43 characters (a GUID fits), unique per raid.

	Storage, DataStore "EscrowRecords" (memory instead when DataService.persistence() is "Memory"):
	  Escrow_<raidId>   EscrowRecord. Created once (UpdateAsync keeps an existing record), then
	                    only moved forward (Escrow.canReplace runs inside every UpdateAsync).
	  Open_<raiderId>   { [raidId]: createdAt } of the raider's unfinished transfers. Written BEFORE
	                    the record, removed after it is terminal, so recovery never scans.
	Every DataStore call: 4 attempts, 1 s / 2 s / 4 s backoff. Each transform is idempotent, so
	retrying a call that did land is harmless.

	transferLive order (each step is durable before the next starts):
	  1. index add   2. record create   3. debit defender, saveNow confirmed   4. record Debited
	  5. credit raider, saveNow confirmed   6. record Committed   7. index remove (background)
	Profiles are read fresh from DataService.getProfile at each step; no references are kept.

	Recovery: on every profile load (raider join) read Open_<userId> and advance each record; every
	60 s retry anything this server left in flight while its raider is still here. Recovery never
	reads Config.Flags: only canStartTransfer does, and only transferLive calls it.

	TODO (Phase 1): advance a Pending record whose defender is not in this server (ProfileStore
	message or offline load); until then it waits, safely, for both to share a server.
]]

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Escrow = require(ReplicatedStorage.Shared.Escrow)
local Types = require(ReplicatedStorage.Shared.Types)
local DataService = require(script.Parent.DataService)

type EscrowRecord = Types.EscrowRecord
type PlayerProfile = Types.PlayerProfile

export type TransferKind = "Live" | "Async"
export type TransferStatus = "Committed" | "InFlight" | "Refused"

local STORE_NAME = "EscrowRecords"
local MAX_RAID_ID_LENGTH = 43 -- DataStore keys are at most 50 characters, minus "Escrow_"
local RETRY_DELAYS = { 1, 2, 4 }
local SWEEP_SECONDS = 60

local EscrowService = {}

local mode: ("DataStore" | "Memory")? = nil
local dataStore: DataStore? = nil
local memory: { [string]: any } = {}
local getOptions = Instance.new("DataStoreGetOptions")
getOptions.UseCache = false -- recovery must see the latest record, not a 4 s cached copy

local busy: { [string]: true } = {} -- raidIds being driven right now in this server
local retry: { [string]: number } = {} -- raidId -> raider userId, left in flight here
local needsIndex: { [number]: true } = {} -- joined players whose index read failed

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

local function storage(): ("DataStore" | "Memory")?
	if mode == nil then
		mode = DataService.persistence()
		if mode == "DataStore" then
			dataStore = DataStoreService:GetDataStore(STORE_NAME)
		elseif mode == "Memory" then
			warn("[EscrowService] no DataStore access: escrow records live in memory for this session")
		end
	end
	return mode
end

local function withRetries<T>(what: string, fn: () -> T): T
	local lastError: any = nil
	for attempt = 1, #RETRY_DELAYS + 1 do
		local ok, result = pcall(fn)
		if ok then
			return result
		end
		lastError = result
		if attempt <= #RETRY_DELAYS then
			task.wait(RETRY_DELAYS[attempt])
		end
	end
	error(`{what} failed after {#RETRY_DELAYS + 1} attempts: {lastError}`, 0)
end

local function read(key: string): any
	if storage() == "Memory" then
		return deepCopy(memory[key])
	end
	local store = assert(dataStore, "escrow storage not ready")
	return withRetries(`read {key}`, function()
		return (store:GetAsync(key, getOptions))
	end)
end

-- transform(stored) returns the new value, or nil to leave the key unchanged.
local function update(key: string, transform: (any) -> any)
	if storage() == "Memory" then
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

-- Write-once: returns the record that is stored (an existing one wins).
local function createRecord(record: EscrowRecord): EscrowRecord
	local existing: EscrowRecord? = nil
	update(recordKey(record.raidId), function(stored)
		existing = stored
		return if stored == nil then record else nil
	end)
	return existing or record
end

local function indexAdd(userId: number, raidId: string, at: number)
	update(indexKey(userId), function(open)
		open = open or {}
		if open[raidId] then
			return nil
		end
		open[raidId] = at
		return open
	end)
end

local function indexRemove(userId: number, raidId: string)
	update(indexKey(userId), function(open)
		if open == nil or open[raidId] == nil then
			return nil
		end
		open[raidId] = nil
		return open
	end)
end

-- Escrow.Store for one raid. Profiles come fresh from DataService each time; a profile save
-- counts only when the written data holds this raid's appliedTransfers entry.
local function storeFor(raidId: string): Escrow.Store
	local function hasThisRaid(saved: any): boolean
		return type(saved) == "table"
			and type(saved.appliedTransfers) == "table"
			and saved.appliedTransfers[raidId] ~= nil
	end
	return {
		loadRecord = function(id: string): EscrowRecord?
			return read(recordKey(id))
		end,
		saveRecord = saveRecord,
		loadProfile = function(userId: number): PlayerProfile
			local profile = DataService.getProfile(userId)
			if not profile then
				error(`profile {userId} is not loaded in this server`, 0)
			end
			return profile
		end,
		saveProfile = function(profile: PlayerProfile)
			if DataService.getProfile(profile.userId) ~= profile then
				error(`profile {profile.userId} changed session before its save`, 0)
			end
			local ok, why = DataService.saveNow(profile.userId, hasThisRaid)
			if not ok then
				error(`save not confirmed: {why}`, 0)
			end
		end,
	}
end

-- Advances one record as far as it can go. Never reads a kill switch.
local function drive(raidId: string, raiderUserId: number): (TransferStatus, string?)
	if busy[raidId] then
		return "InFlight", "already being advanced"
	end
	busy[raidId] = true
	local ok, result = pcall(Escrow.advance, raidId, storeFor(raidId), os.time())
	busy[raidId] = nil
	if not ok then
		retry[raidId] = raiderUserId
		local message = tostring(result)
		if string.find(message, "duplicate", 1, true) then
			warn(`[EscrowService] DUPLICATION ALARM {raidId}: {message}`)
		end
		return "InFlight", message
	end
	local record: EscrowRecord? = result
	if record and not Escrow.isTerminal(record) then
		retry[raidId] = raiderUserId
		return "InFlight", `record is {record.state}`
	end
	retry[raidId] = nil
	task.spawn(function()
		local removed, err = pcall(indexRemove, raiderUserId, raidId)
		if not removed then
			warn(`[EscrowService] index cleanup for {raidId} failed (retried on next join): {err}`)
		end
	end)
	if record == nil then
		return "Refused", "no escrow record"
	elseif record.state == "Voided" then
		return "Refused", "voided"
	end
	return "Committed", nil
end

local function recoverPlayer(userId: number)
	if storage() == nil then
		needsIndex[userId] = true
		return
	end
	local ok, open = pcall(read, indexKey(userId))
	if not ok then
		needsIndex[userId] = true
		warn(`[EscrowService] could not read open transfers for {userId}; retrying: {open}`)
		return
	end
	needsIndex[userId] = nil
	for raidId in (open or {}) :: { [string]: number } do
		local status, reason = drive(raidId, userId)
		if status == "InFlight" then
			warn(`[EscrowService] recovery of {raidId} still in flight: {reason}`)
		end
	end
end

-- The ONLY place a kill switch is read. Recovery never calls it.
function EscrowService.canStartTransfer(kind: TransferKind, isRevenge: boolean?): (boolean, string?)
	return Escrow.canStartTransfer(Config.Flags, kind, isRevenge)
end

function EscrowService.transferLive(
	raidId: string,
	raiderUserId: number,
	defenderUserId: number,
	critterUid: string?,
	glowRequested: number,
	isRevenge: boolean?
): (TransferStatus, string?)
	local allowed, why = EscrowService.canStartTransfer("Live", isRevenge)
	if not allowed then
		return "Refused", why
	end
	if type(raidId) ~= "string" or #raidId == 0 or #raidId > MAX_RAID_ID_LENGTH then
		return "Refused", `raidId must be 1 to {MAX_RAID_ID_LENGTH} characters`
	end
	if raiderUserId == defenderUserId then
		return "Refused", "raider and defender are the same player"
	end
	if type(glowRequested) ~= "number" or glowRequested ~= glowRequested or glowRequested < 0 then
		return "Refused", "glowRequested must be a number >= 0"
	end
	if glowRequested == math.huge then
		return "Refused", "glowRequested must be finite"
	end
	if not DataService.getProfile(raiderUserId) or not DataService.getProfile(defenderUserId) then
		return "Refused", "both profiles must be loaded in this server"
	end
	if storage() == nil then
		return "Refused", "escrow storage not ready"
	end
	if busy[raidId] then
		return "InFlight", "already being advanced"
	end

	local now = os.time()
	local record = Escrow.create(
		raidId,
		raiderUserId,
		defenderUserId,
		critterUid,
		math.floor(glowRequested),
		isRevenge == true,
		now
	)
	-- 1. Index first: any record that exists is then findable by the raider's recovery.
	local indexed, indexError = pcall(indexAdd, raiderUserId, raidId, now)
	if not indexed then
		return "Refused", `could not start: {indexError}`
	end
	-- 2. Write-once create. If this fails the create may still have landed; recovery decides.
	local created, stored = pcall(createRecord, record)
	if not created then
		retry[raidId] = raiderUserId
		return "InFlight", `record create not confirmed: {stored}`
	end
	if not Escrow.sameTransfer(stored, record) then
		return "Refused", "raidId already used by a different transfer"
	end
	-- 3-7. Debit, record, credit, record; each save confirmed before the next step.
	return drive(raidId, raiderUserId)
end

function EscrowService.start()
	-- Recovery is never behind a flag (docs/contracts.md: Kill switches).
	DataService.onProfileLoaded(function(player: Player)
		recoverPlayer(player.UserId)
	end)
	task.spawn(function()
		while true do
			task.wait(SWEEP_SECONDS)
			for userId in table.clone(needsIndex) do
				if DataService.getProfile(userId) then
					recoverPlayer(userId)
				else
					needsIndex[userId] = nil -- their next join reads the index again
				end
			end
			for raidId, raiderUserId in table.clone(retry) do
				if DataService.getProfile(raiderUserId) then
					drive(raidId, raiderUserId)
				else
					retry[raidId] = nil -- the raider's next join, in any server, recovers it
				end
			end
		end
	end)
end

return EscrowService
