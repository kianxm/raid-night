--!strict
--[[
	EscrowService (owner: data agent; every change reviewed by the reviewer agent)

	Turns a successful raid into a safe transfer using Shared/Escrow.luau, and finishes any
	transfer that a crash, an unconfirmed save or an absent party left in flight.

	Public API (everything else is private):
	  canStartTransfer(kind, isRevenge?)  may a NEW transfer start? Escrow.canStartTransfer with
	                          Config.Flags: `raids` is the master switch; "Async" and revenge also
	                          need `asyncRaids`; unknown kinds are refused. The only code here that
	                          reads a flag (a Lune test guards this). Studio only: the ServerStorage
	                          attribute StudioAsyncRaids = true counts asyncRaids as on (never read
	                          in a live server), so async raids can be playtested before they ship.
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
	  transferAsync(raidId, raiderUserId, defenderUserId, critterUid, glowRequested, isRevenge?,
	                revengeRaidId?)
	                          an async raid's escape (P1.3), from the snapshot the raid was built
	                          on. The raider must be loaded here; the defender may be offline,
	                          online in another server, or here. Yields (seconds normally, about 2
	                          minutes worst case). Returns (status, reason):
	                            "Committed"  the loot moved; both sides saved
	                            "InFlight"   started, or may have; it finishes without the caller.
	                                         Usually the defender is online elsewhere: their
	                                         server applies the debit, then this server credits
	                                         the raider and pushes DenChanged. A retry with
	                                         IDENTICAL arguments is safe, never needed
	                            "Refused"    nothing moved: switch off, bad input, the raider not
	                                         loaded here, or the raidId used by another transfer
	                          Once created it is never voided. The debit runs when it lands: it
	                          accrues the defender's offline income to then and takes the raid's
	                          share of that stored Glow (RaidRules.lootGlow's share, capped by what
	                          is there), and the critter only if it is still on its pad and the den
	                          is under maxLossesPerDay (D-031). glowRequested (the snapshot's
	                          RaidRules.lootGlow) is only the estimate the raid showed. Read the
	                          outcome from the raider's profile (the credit is exactly what was
	                          debited), never from the snapshot. critterUid, glowRequested and
	                          isRevenge come from server state, never from a remote. Refresh the
	                          raider after it, as for transferLive; a later commit is pushed from
	                          here.
	                          The credit also records the raid on the raider (P1.3d, in the same
	                          save as the credit, once per raidId; only when something moved):
	                          their Outgoing raid-log entry, the pair count canRaid's limit reads
	                          and, for revenge, the named token removed (D-054: one revenge
	                          raid per token; a failed or empty one keeps it).
	                          revengeRaidId: the raider's revenge token the raid started with (its
	                          key in their revengeTokens), from server state; only with isRevenge.
	                          nil = none named (no token is spent). Anything else that is not a
	                          raidId-shaped string: "Refused" before any write. Part of the
	                          transfer: a retry must pass the same one.
	  studioRecord(raidId)    Studio only: the stored record, read-only (playtests)

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
	Each DataStore call: 4 attempts, 1/2/4 s backoff. Every transform is idempotent and stores
	the userIds the key is about (both parties for a record, the owner for an index; D-008).

	New raid: busy lock -> start checks -> index both parties -> create record (with a per-call
	createNonce, so an attempt that landed but errored is still this call's own) -> Escrow.advance
	(debit + saveNow, record Debited, credit + saveNow, record Committed) -> index cleanup in the
	background. Profiles come fresh from DataService.getProfile, accrued first through the
	Glow-factor helper (IncomeService.accrue: the player's own factor, P2.8b), and a profile save
	counts only when the written data holds this raid's exact appliedTransfers entry.

	Async raid: the same lock, checks (asyncRaids) and indexes, then Escrow.recover, which never
	voids an Async record and delivers its debit: on the defender's profile when it is loaded here
	(saveNow); otherwise DataService.updateOffline, one atomic write that lands only while no
	server holds the profile; or, when a server does, an "EscrowDebit" message (just the raidId),
	whose listener in that server runs the same recovery with the defender loaded. This server
	keeps retrying while the raider is here and credits once the record is Debited.

	Recovery never reads a flag. On every profile load: read Open_<userId>, prune
	appliedTransfers except open raids, then Escrow.recover each open raid (Live, Pending with the
	defender here: their saved debit -> Debited; none -> a confirmed save by this session without
	the entry, then Voided; Async, Pending: deliver the debit; Debited with the raider here: credit
	and commit). A sweep every 15 s retries what this server left in flight, with per-raid
	backoff, while a party the record needs is here (Pending: the defender, or for Async the
	raider; Debited: the raider); otherwise that party's next load picks it up. Every 60 s it
	reads every loaded player's Open_ index again (raids other servers opened, lost messages),
	leaving raids under backoff or waiting for an absent party alone. A drive that is not the
	transfer call itself pushes DenChanged to each party here whose profile it changed (D-026).

	Duplication alarm: a step that refuses a second copy of a critter, or two different loots for
	one raid, stops that raid in this server (never retried here; record and profiles stay as
	they are for a human) and raises an error so it shows in the error report.

	Studio playtests (ServerStorage attributes, never read in a live server): StudioAsyncRaids
	(above), and StudioEscrowPause = "<checkpoint>" (an Escrow checkpoint name, e.g.
	"deliveredDebit"): any drive reaching it waits there, so the server can be stopped
	mid-transfer to test recovery on rejoin. Clearing the attribute resumes the drive; a server
	close (BindToClose) or 2 minutes stops it by an error instead, so the paused step never runs
	from here and recovery finishes it on the next load (#114: a pause that ignored the close kept
	busy[raidId], so BindToClose waited its full 25 s and Studio's play session hung after Stop).

	Studio test profiles (DataService.loadTestProfile, decision D-019) have no load to recover
	from, so DataService refuses to release one while an escrow for it is open here.
	Studio test sessions (DataService.loadTestSession, P1.10d) are real DataStore sessions for
	test ids: recovered on their load (onTestSessionLoaded) and swept like players
	(testSessionIds), so a forced stop mid-transfer is recovered as for a player. A test id is
	not an account, so DataStore writes name only positive user ids (accountIds).

	Live loss rules (decision D-031): transferLive creates "Live" records, whose debit takes no
	critter from a den that is live-protected at the debit (Escrow.debitDefender; measured
	against the largest of the day's base, the den's Glow/s then (D-036) and the record's
	liveBaseRate (D-037), so a shrink during the carry cannot refuse it), measures the day's
	first live loss against the record's liveBaseRate when it has one (D-034), and grants the
	defender nothing when it takes nothing (D-033). Live steals stay on this same-server path, on
	the two profiles loaded here; only async debits cross servers (D-012 closed: no Async record is
	ever voided, so no late debit can race a void).

	After a step lands (P2.9): once this server has SAVED a record as Debited, it announces the
	loss, deferred on its own thread inside pcall (never part of the transfer): any debit that took
	Glow, Live or Async, logs a DenGlow "DenRaided" economy sink with the defender here (P2.9b); an
	Async debit also logs raided_offline (on the defender when they are here, else on the raider);
	any debit that moved something calls
	NotificationService.onLoss({ defenderUserId, raidId, raiderName, kind, critterName }) when that
	service exists and has onLoss (PR #118; looked up by name, so this works without it).
	raiderName is the raider's DisplayName if they are here, else their Roblox username; critterName
	is the catalog name. Once saved Committed, a raider here gets a Glow "RaidLoot" economy source.
	Escrow.luau and every step's behavior are unchanged.

	TODO (when rebirth is wired; D-026): applyRebirth must skip or refuse critters that are
	locked (carried, or in an open escrow).
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local CritterCatalog = require(ReplicatedStorage.Shared.CritterCatalog)
local Escrow = require(ReplicatedStorage.Shared.Escrow)
local Types = require(ReplicatedStorage.Shared.Types)
local AnalyticsService = require(script.Parent.AnalyticsService)
local DataService = require(script.Parent.DataService)
local IncomeService = require(script.Parent.IncomeService) :: any

type EscrowRecord = Types.EscrowRecord
type EscrowOpenIndex = Types.EscrowOpenIndex
type PlayerProfile = Types.PlayerProfile
type AppliedTransfer = Types.AppliedTransfer

export type TransferKind = Types.TransferKind
export type TransferStatus = "Committed" | "InFlight" | "Refused"

local STORE_NAME = "EscrowRecords"
local MAX_RAID_ID_LENGTH = Config.Escrow.maxRaidIdLength
local CALL_RETRY_DELAYS = { 1, 2, 4 } -- seconds between DataStore attempts
local INDEX_STALE_SECONDS = 15 * 60 -- a record-less index entry younger than this may be mid-create
local SWEEP_SECONDS = 15
local RESCAN_SECONDS = 60 -- every loaded player's open index is read again this often
local RETRY_FIRST_SECONDS = 30
local RETRY_MAX_SECONDS = 30 * 60
local CLOSE_WAIT_SECONDS = 25
local MAX_CRITTER_UID_LENGTH = 64
local DEBIT_TOPIC = "EscrowDebit" -- DataService message { raidId }: an async debit for a profile held there
-- The words in a drive's error that mean a step refused a second copy, or two loots met.
local ALARM_SIGNS = { "duplicate", "conflicting loot", "already used for a" }
-- Studio only (ServerStorage attributes, read only when RunService:IsStudio()).
local STUDIO_ASYNC = "StudioAsyncRaids"
local STUDIO_PAUSE = "StudioEscrowPause"
local STUDIO_PAUSE_SECONDS = 120

local EscrowService = {}

-- `nonce`: the creating call's createNonce, kept for that call's retry (startOrResume).
type Retry = { from: number, need: number, delay: number, nextAt: number, nonce: string? }

local mode: ("DataStore" | "Memory")? = nil
local dataStore: DataStore? = nil
local memory: { [string]: any } = {}
local getOptions = Instance.new("DataStoreGetOptions")
getOptions.UseCache = false -- recovery must see the latest record, not a 4 s cached copy

local busy: { [string]: true } = {} -- raidIds being driven right now in this server
local closing = false -- set first thing in BindToClose; only the Studio pause reads it
local retry: { [string]: Retry } = {} -- raids this server left in flight
local needsIndex: { [number]: Retry } = {} -- loaded players whose index read failed
local parked: { [string]: number } = {} -- raids left for an absent party's load: raidId -> that party
local alarmed: { [string]: true } = {} -- raids that raised the duplication alarm: not driven here again
local nextRescanAt = 0

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
		error("escrow storage not ready: DataService not started (or still checking DataStore access)", 0)
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

-- The user ids a DataStore write names: accounts only. A Studio test id (P1.10d) or Local Server
-- player is negative and not an account, so it is left off, as ProfileStore's AddUserId does.
-- Every live userId is positive, so a live write names exactly the ids it was given.
local function accountIds(userIds: { number }): { number }
	local accounts = {}
	for _, userId in userIds do
		if userId > 0 then
			table.insert(accounts, userId)
		end
	end
	return accounts
end

-- transform(stored) returns the new value, or nil to leave the key unchanged. `userIds`: the
-- players the key is about, stored with each write for GDPR erasure tooling (decision D-008).
local function update(key: string, userIds: { number }, transform: (any) -> any)
	if backend() == "Memory" then
		local result = transform(deepCopy(memory[key]))
		if result ~= nil then
			memory[key] = deepCopy(result)
		end
		return
	end
	local store = assert(dataStore, "escrow storage not ready")
	local accounts = accountIds(userIds)
	withRetries(`update {key}`, function()
		store:UpdateAsync(key, function(stored: any)
			local value = transform(stored)
			if value == nil then
				return nil
			end
			return value, accounts
		end)
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
	update(recordKey(record.raidId), { record.raiderUserId, record.defenderUserId }, function(stored)
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
	update(recordKey(record.raidId), { record.raiderUserId, record.defenderUserId }, function(stored: EscrowRecord?)
		local toWrite, isOurs = Escrow.decideCreate(stored, record)
		existing, ours = stored, isOurs
		return toWrite
	end)
	return existing or record, ours
end

local function indexAdd(userId: number, raidId: string, role: "Raider" | "Defender", createdAt: number)
	update(indexKey(userId), { userId }, function(stored: EscrowOpenIndex?)
		return Escrow.indexAdd(stored, raidId, role, createdAt)
	end)
end

-- Removes one entry; returns true once it is gone. With `staleBefore`, keeps an entry created at
-- or after that time (its record may still be being created). Decided inside the transform.
local function indexRemove(userId: number, raidId: string, staleBefore: number?): boolean
	local gone = false
	update(indexKey(userId), { userId }, function(stored: EscrowOpenIndex?)
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

-- After a step lands (P2.9) ------------------------------------------------------------------------
-- Analytics and the loss notification, announced once this server has SAVED a record step. They
-- run deferred on their own thread, inside pcall, after the drive has moved on: they never yield,
-- block or fail a transfer, and they read only the saved record (a copy) and profiles loaded here.
-- Two servers that both save the same step (a rare race Escrow.canReplace allows) both announce it.

local NAME_LOOKUP_DELAYS = { 1, 2 } -- seconds between Players:GetNameFromUserIdAsync attempts
local notificationService: any = nil -- NotificationService, once found with an onLoss
local notificationsChecked = false

-- NotificationService.onLoss (P2.7, PR #118) when that service is present and has it; nil until
-- then, so this file works with or without #118. Looked up once, on first use.
local function notifications(): any
	if notificationsChecked then
		return notificationService
	end
	notificationsChecked = true
	local module = script.Parent:FindFirstChild("NotificationService")
	if module and module:IsA("ModuleScript") then
		local ok, service = pcall(require, module)
		if ok and type(service) == "table" and type((service :: any).onLoss) == "function" then
			notificationService = service
		end
	end
	return notificationService
end

-- The raider's Roblox DisplayName when they are here, else their username (a bounded lookup).
local function raiderName(userId: number): string?
	local player = Players:GetPlayerByUserId(userId)
	if player then
		return player.DisplayName
	end
	for attempt = 1, #NAME_LOOKUP_DELAYS + 1 do
		local ok, name = pcall(function()
			return Players:GetNameFromUserIdAsync(userId)
		end)
		if ok and type(name) == "string" then
			return name
		end
		if attempt <= #NAME_LOOKUP_DELAYS then
			task.wait(NAME_LOOKUP_DELAYS[attempt])
		end
	end
	return nil
end

local function tierOf(critter: Types.Critter?): string
	local species = if critter then CritterCatalog.get(critter.speciesId) else nil
	return if species then species.tier else "None"
end

-- The defender gave up the loot (the record is saved Debited).
local function announceDebit(record: EscrowRecord)
	local moved = record.critter ~= nil or record.glow > 0
	local defender = Players:GetPlayerByUserId(record.defenderUserId)
	-- DenRaided: the den Glow the debit took, Live or Async (P2.9b), on the defender when here. It
	-- balances the raider's RaidLoot source (announceCredit) for the same record.glow.
	local profile = DataService.getProfile(record.defenderUserId)
	if defender and profile and record.glow > 0 then
		AnalyticsService.economy(defender, "DenRaided", record.glow, math.max(0, math.floor(profile.stored)))
	end
	if Escrow.kindOf(record) == "Async" then
		-- raided_offline: Roblox analytics need a Player in this server, so a debit written to a
		-- profile no server holds is logged on the raider (whose server delivered it).
		local raider = Players:GetPlayerByUserId(record.raiderUserId)
		local on = defender or raider
		if on then
			AnalyticsService.track(on, "raided_offline", {
				tierLost = tierOf(record.critter),
				glowLost = record.glow,
				revenge = record.isRevenge,
				attributedTo = if defender then "Defender" else "Raider",
			})
		end
	end
	local service = notifications()
	if not moved or service == nil or record.defenderUserId <= 0 or record.raiderUserId <= 0 then
		return -- nothing lost, no NotificationService yet, or a Studio test id (no account)
	end
	local name = raiderName(record.raiderUserId)
	if name == nil then
		warn(`[EscrowService] no loss notification for {record.raidId}: the raider's name could not be read`)
		return
	end
	local species = if record.critter then CritterCatalog.get(record.critter.speciesId) else nil
	service.onLoss({
		defenderUserId = record.defenderUserId,
		raidId = record.raidId,
		raiderName = name,
		kind = if record.critter then "Critter" else "Glow",
		critterName = if species then species.name else nil,
	})
end

-- The raider received the loot (the record is saved Committed).
local function announceCredit(record: EscrowRecord)
	local raider = Players:GetPlayerByUserId(record.raiderUserId)
	local profile = DataService.getProfile(record.raiderUserId)
	if raider and profile and record.glow > 0 then
		AnalyticsService.economy(raider, "RaidLoot", record.glow, math.max(0, math.floor(profile.glow)))
	end
end

-- Called by the store right after a record write landed, with the state it moved from.
local function announce(record: EscrowRecord, before: string?)
	local saved: EscrowRecord = deepCopy(record)
	local announcer = if before == "Pending" and saved.state == "Debited"
		then announceDebit
		elseif before == "Debited" and saved.state == "Committed" then announceCredit
		else nil
	if announcer == nil then
		return
	end
	task.defer(function()
		local ok, err = pcall(announcer, saved)
		if not ok then
			warn(`[EscrowService] announcing {saved.raidId} ({saved.state}) failed: {err}`)
		end
	end)
end

-- What one drive saw: `record`, a copy of the record as last read or confirmed written (so a
-- drive that errors part-way still knows which party it needs next), and `touched`, the parties
-- loaded here whose live profile it changed (refreshed after a late drive, D-026).
type Seen = { record: EscrowRecord?, touched: { [number]: true } }

-- Escrow.Store for one raid. Profiles come fresh from DataService each time.
local function storeFor(raidId: string, last: Seen): Escrow.Store
	return {
		loadRecord = function(id: string): EscrowRecord?
			local record: EscrowRecord? = read(recordKey(id))
			last.record = if record then table.clone(record) else nil
			return record
		end,
		saveRecord = function(record: EscrowRecord)
			local before = if last.record then last.record.state else nil
			saveRecord(record)
			last.record = table.clone(record)
			announce(record, before) -- deferred: analytics and the loss notification (P2.9)
		end,
		loadProfile = function(userId: number): PlayerProfile
			local profile = DataService.getProfile(userId)
			if not profile then
				error(`profile {userId} is not loaded in this server`, 0)
			end
			last.touched[userId] = true
			-- Money model: accrue before `stored` changes, through the Glow-factor helper (P2.8b,
			-- D-032). A profile loaded here is online, so it accrues at the player's own factor,
			-- which only IncomeService.setGlowInputs changes (accruing at the old factor first); a
			-- repeat in the same second adds nothing. An Async debit takes its share of `stored` as
			-- accrued here, to the debit. A defender no server holds goes through debitAbsent below
			-- instead, at factor 1: offline income is unboosted (VIP is online-only, D-061).
			IncomeService.accrue(profile, os.time())
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
			-- The exact entry the record will carry (loot included), so another server's save of a
			-- different debit for this raid never confirms this one (Escrow.sameApplied).
			local expected = deepCopy(entry)
			local ok, why = DataService.saveNow(profile.userId, function(saved: any): boolean
				local applied = type(saved) == "table"
					and type(saved.appliedTransfers) == "table"
					and saved.appliedTransfers[raidId]
				return Escrow.sameApplied(expected, applied)
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
		-- Known window (#25 review; Live records only, since an Async record is never voided):
		-- saveNow accepts any OnAfterSave while the session is active, including an autosave whose
		-- UpdateAsync was already in flight: its transform ran while we held the lock, then another
		-- server took the lock (about 40 s with no release from us) and its creating live call
		-- debited, and only then did the autosave's response arrive. That save "proves" a void the
		-- new owner contradicts. Accepted (it needs a DataStore call hanging for over 40 s); the
		-- fix, a tombstone written inside this proof save that debitDefender refuses, is on the
		-- hardening backlog.
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
		-- Async only: the debit for a defender not loaded here. One atomic write to their saved
		-- profile while no server holds it (debitDefender is idempotent, so a repeat writes
		-- nothing and returns the saved entry); held by a server: a message it delivers.
		debitAbsent = function(record: EscrowRecord, now: number): AppliedTransfer?
			assert(record.raidId == raidId, "escrow store used for another raid")
			local defenderId = record.defenderUserId
			-- Accrues the den to the debit, then debits, inside the one write (a repeat writes nothing).
			local outcome, result = DataService.updateOffline(defenderId, function(profile: PlayerProfile)
				return Escrow.debitAbsentProfile(profile, record, now)
			end)
			if outcome == "done" then
				return result
			elseif outcome == "held" then
				local sent, why = DataService.sendMessage(defenderId, DEBIT_TOPIC, { raidId = raidId })
				if not sent then
					error(`debit message to {defenderId} not confirmed: {why}`, 0)
				end
				return nil -- the server that holds the defender delivers it
			end
			error(`defender {defenderId} cannot be debited offline ({outcome}): {result}`, 0)
		end,
	}
end

-- The party a record needs next: Pending settles where the defender is loaded (an Async one
-- also from the raider's server, which delivers the debit and waits for it), Debited where the
-- raider is. With no record seen, `from` (whose index led here).
local function needFor(record: EscrowRecord?, from: number): number
	if record and record.state == "Pending" then
		if Escrow.kindOf(record) == "Async" and not isHere(record.defenderUserId) then
			return record.raiderUserId
		end
		return record.defenderUserId
	elseif record and record.state == "Debited" then
		return record.raiderUserId
	end
	return from
end

-- Studio only: the StudioEscrowPause checkpoint, so a playtest can stop the server mid-transfer.
local function studioCheckpoint(raidId: string): ((string) -> ())?
	if not RunService:IsStudio() then
		return nil
	end
	return function(name: string)
		if ServerStorage:GetAttribute(STUDIO_PAUSE) ~= name then
			return
		end
		warn(`[EscrowService] Studio pause: {raidId} waits at {name} for up to {STUDIO_PAUSE_SECONDS} s; stop now`)
		local deadline = os.clock() + STUDIO_PAUSE_SECONDS
		while ServerStorage:GetAttribute(STUDIO_PAUSE) == name do
			if closing or os.clock() >= deadline then
				-- Never finish the paused step from here: the drive's pcall catches this, the record
				-- stays as saved, and busy[raidId] is let go so BindToClose is not held (#114).
				error(
					`Studio pause at {name} stopped ({if closing then "server closing" else "timed out"}); recovery finishes it on the next load`,
					0
				)
			end
			task.wait(0.5)
		end
	end
end

-- Pushes DenChanged (IncomeService.refresh) to each party here whose live profile a late drive
-- changed: a commit the raider's raid call gave up on, or a debit by message (D-026).
local function refresh(touched: { [number]: true })
	for userId in touched do
		local player = Players:GetPlayerByUserId(userId)
		if player and DataService.getProfile(userId) then
			task.spawn(function()
				local ok, err = pcall(IncomeService.refresh, player)
				if not ok then
					warn(`[EscrowService] could not refresh {userId}: {err}`)
				end
			end)
		end
	end
end

-- A step refused a second copy of a critter, or met two loots for one raid. Stops the raid in
-- this server (record and profiles stay as they are, for a human) and reports it as an error.
local function raiseAlarm(raidId: string, message: string)
	alarmed[raidId] = true
	retry[raidId] = nil
	warn(`[EscrowService] DUPLICATION ALARM {raidId}: {message}`)
	task.spawn(error, `[EscrowService] DUPLICATION ALARM {raidId}: {message}`, 0)
end

-- Advances one raid as far as it can go. The caller holds busy[raidId]. `live` only for the call
-- that created a Live record; every other path (an async transfer too) recovers. `from` is whose
-- index led here. `late`: not the transfer call itself, so changed parties are refreshed here.
-- Never reads a kill switch.
local function drive(raidId: string, from: number, live: boolean, late: boolean): (TransferStatus, string?)
	if alarmed[raidId] then
		return "InFlight", "stopped by a duplication alarm in this server"
	end
	local last: Seen = { touched = {} }
	local store = storeFor(raidId, last)
	local now = os.time()
	local checkpoint = studioCheckpoint(raidId)
	local ok, result = pcall(function(): EscrowRecord?
		if live then
			return Escrow.advance(raidId, store, now, checkpoint)
		end
		return Escrow.recover(raidId, store, now, isHere, checkpoint)
	end)
	if late then
		refresh(last.touched)
	end
	if not ok then
		local message = tostring(result)
		for _, sign in ALARM_SIGNS do
			if string.find(message, sign, 1, true) then
				raiseAlarm(raidId, message)
				return "InFlight", message
			end
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
		parked[raidId] = nil
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
	local status, reason = drive(raidId, from, false, true)
	busy[raidId] = nil
	if status == "InFlight" then
		warn(`[EscrowService] {raidId} still in flight: {reason}`)
	end
end

-- Reads a loaded player's open index and drives each raid in it. A `rescan` (the 60 s sweep)
-- leaves raids under their own backoff here, and raids parked for an absent party, alone.
local function recoverUser(userId: number, rescan: boolean?)
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
		local waitingFor = parked[raidId]
		if rescan and (retry[raidId] or (waitingFor and not isHere(waitingFor))) then
			continue
		end
		parked[raidId] = nil
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
			parked[raidId] = entry.need
			continue
		end
		driveLocked(raidId, entry.from)
	end
	if clock >= nextRescanAt then
		nextRescanAt = clock + RESCAN_SECONDS
		for _, player in Players:GetPlayers() do
			local userId = player.UserId
			if isHere(userId) and needsIndex[userId] == nil then
				task.spawn(recoverUser, userId, true) -- one player's error never stops the rest
			end
		end
		-- Studio test sessions (P1.10d) are rescanned like players. Always none in a live server.
		for _, userId in DataService.testSessionIds() do
			if isHere(userId) and needsIndex[userId] == nil then
				task.spawn(recoverUser, userId, true)
			end
		end
	end
end

-- The ONLY code in this service that reads a kill switch. Recovery never calls it.
function EscrowService.canStartTransfer(kind: TransferKind, isRevenge: boolean?): (boolean, string?)
	local switches: Escrow.KillSwitches = Config.Flags
	if RunService:IsStudio() and ServerStorage:GetAttribute(STUDIO_ASYNC) == true then
		-- Studio playtests only: asyncRaids counts as on; the master switch still applies.
		switches = { raids = Config.Flags.raids, asyncRaids = true }
	end
	return Escrow.canStartTransfer(switches, kind, isRevenge)
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
		return drive(raidId, raiderUserId, ours, false)
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
	local status, reason = drive(raidId, raiderUserId, ours, false)
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
	-- Undecided (DataService not started, or ProfileStore still checking), or storage() failed:
	-- refuse before any write (D-026).
	local ready, decided = pcall(storage)
	if not ready or decided == nil then
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

-- An async raid's escape (transferAsync). An existing record for the raidId is driven, never
-- re-gated. A new one: kill switch, raider here, both indexes, the record, then recovery, which
-- delivers the debit wherever the defender is and never voids an Async record.
local function startAsync(
	raidId: string,
	raiderUserId: number,
	defenderUserId: number,
	critterUid: string?,
	glowRequested: number,
	isRevenge: boolean,
	revengeRaidId: string?
): (TransferStatus, string?)
	if type(raiderUserId) ~= "number" or type(defenderUserId) ~= "number" or raiderUserId == defenderUserId then
		return "Refused", "raider and defender must be two different players"
	end
	if
		critterUid ~= nil and (type(critterUid) ~= "string" or #critterUid == 0 or #critterUid > MAX_CRITTER_UID_LENGTH)
	then
		return "Refused", "critterUid must be nil or a critter uid"
	end
	if type(glowRequested) ~= "number" or not (glowRequested >= 0 and glowRequested < math.huge) then
		return "Refused", "glowRequested must be a finite number >= 0"
	end
	local revengeOk, revengeWhy = Escrow.checkRevengeRaidId("Async", isRevenge, revengeRaidId)
	if not revengeOk then
		return "Refused", revengeWhy -- before any write; Escrow.create would assert on it
	end
	local now = os.time()
	-- The raider's revenge token (P1.3d) rides on the record; its credit removes it (D-054).
	local record = Escrow.create(
		raidId,
		raiderUserId,
		defenderUserId,
		critterUid,
		math.floor(glowRequested),
		isRevenge,
		now,
		"Async",
		nil,
		revengeRaidId
	)
	record.createNonce = HttpService:GenerateGUID(false)

	-- Nothing is written before this read; unless an earlier call for the raid is still awaited
	-- here, a failed read moved nothing.
	local readOk, existing = pcall(read, recordKey(raidId))
	if not readOk then
		local earlier = retry[raidId] ~= nil or parked[raidId] ~= nil
		return if earlier then "InFlight" else "Refused", `could not read the raid's record: {existing}`
	end
	if existing then
		if not Escrow.sameTransfer(existing, record) then
			return "Refused", "raidId already used by a different transfer"
		end
		return drive(raidId, raiderUserId, false, false)
	end

	-- A new raid: the only place a kill switch applies.
	local allowed, why = EscrowService.canStartTransfer("Async", isRevenge)
	if not allowed then
		return "Refused", why
	end
	if not isHere(raiderUserId) then
		return "Refused", "the raider must be loaded in this server"
	end
	local indexed, indexError = pcall(function()
		indexAdd(raiderUserId, raidId, "Raider", now)
		indexAdd(defenderUserId, raidId, "Defender", now)
	end)
	if not indexed then
		return "Refused", `could not start: {indexError}`
	end
	local created, stored = pcall(createRecord, record)
	if not created then
		retry[raidId] = backoff(retry[raidId], raiderUserId, raiderUserId)
		return "InFlight", `record create not confirmed: {stored}`
	end
	if not Escrow.sameTransfer(stored, record) then
		return "Refused", "raidId already used by a different transfer"
	end
	return drive(raidId, raiderUserId, false, false)
end

function EscrowService.transferAsync(
	raidId: string,
	raiderUserId: number,
	defenderUserId: number,
	critterUid: string?,
	glowRequested: number,
	isRevenge: boolean?,
	revengeRaidId: string?
): (TransferStatus, string?)
	if type(raidId) ~= "string" or #raidId == 0 or #raidId > MAX_RAID_ID_LENGTH then
		return "Refused", `raidId must be 1 to {MAX_RAID_ID_LENGTH} characters`
	end
	if busy[raidId] then
		return "InFlight", "already being advanced"
	end
	local ready, decided = pcall(storage)
	if not ready or decided == nil then
		return "Refused", "escrow storage not ready"
	end
	busy[raidId] = true
	local ok, status, reason = pcall(
		startAsync,
		raidId,
		raiderUserId,
		defenderUserId,
		critterUid,
		glowRequested,
		isRevenge == true,
		revengeRaidId
	)
	busy[raidId] = nil
	if not ok then
		return "InFlight", `could not confirm the raid's state; retry with the same raidId: {status}`
	end
	return status, reason
end

-- Studio only: the stored record for a raid, read-only (playtest checks).
function EscrowService.studioRecord(raidId: string): EscrowRecord?
	if not RunService:IsStudio() then
		error("EscrowService.studioRecord is Studio-only")
	end
	return read(recordKey(raidId))
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
	-- A Studio test session (P1.10d) has no Player, so it is recovered on its own load signal.
	DataService.onTestSessionLoaded(function(userId: number)
		recoverUser(userId)
	end)
	-- An async debit for a profile loaded here, from the raider's server. Only a wake-up: the
	-- record decides, so a repeat, a late one, or one for a settled raid changes nothing.
	DataService.onMessage(DEBIT_TOPIC, function(userId: number, data: any)
		local raidId = if type(data) == "table" then data.raidId else nil
		if type(raidId) ~= "string" or #raidId == 0 or #raidId > MAX_RAID_ID_LENGTH then
			warn(`[EscrowService] ignoring a malformed debit message for {userId}`)
			return
		end
		task.spawn(driveLocked, raidId, userId)
	end)
	DataService.guardTestRelease(openEscrowFor)
	-- DataService's Studio seed accrues through the Glow-factor helper too (P2.8b). DataService
	-- cannot require IncomeService (IncomeService requires DataService), so it is handed over here.
	DataService.setGlowAccrue(IncomeService.accrue)
	task.spawn(function()
		while true do
			task.wait(SWEEP_SECONDS)
			local ok, err = pcall(sweep) -- an error never stops recovery on this server
			if not ok then
				warn(`[EscrowService] sweep failed; retrying next tick: {err}`)
			end
		end
	end)
	game:BindToClose(function()
		closing = true -- a Studio pause lets go now (studioCheckpoint)
		local deadline = os.clock() + CLOSE_WAIT_SECONDS
		while next(busy) ~= nil and os.clock() < deadline do
			task.wait(0.5)
		end
	end)
end

return EscrowService
