--!strict
--[[
	SnapshotService (owner: matchmaking agent)

	Saves each den's raidable snapshot (Matchmaking.buildSnapshot) to DataStore `DenSnapshots`, key
	`Snapshot_<userId>`. Async raids are built from it, never from the live profile. Vault
	critters are never in it. It is built from a shallow copy of the profile. Glow factor (P2.8,
	D-030/D-032): when the profile is the one loaded here (interval, a loaded test session), it
	first accrues through IncomeService.accrue, the Glow-factor helper, so the snapshot's stored
	Glow includes the owner's boost and Matchmaking.buildSnapshot's factor-1 accrue covers no
	time. That accrue is the only change made to the live profile here. A leave snapshot is built
	after getProfile is already nil, so it never accrues the live profile: IncomeService's own
	releasing listener makes the final accrue at the factor.
	  interval  every Config.Snapshot.intervalSeconds while the profile is loaded (the first one
	            right after load). Skipped while the server's UpdateAsync budget is low; the next
	            tick retries.
	  leave     built inside DataService.onProfileReleasing (no yield), written right after.
	            BindToClose waits for these writes.
	After each save, onSaved listeners run: MatchmakingService lists the den in its power band's
	pool on "Leave" (only offline dens are async targets).

	Block lists: setBlocked(userId, list) holds the player's reported Roblox block list for this
	session, and every snapshot carries it as blockedUserIds. Before the client's first report the
	previous snapshot's list is kept (UpdateAsync carries it forward).

	Storage follows DataService.persistence(): "Memory" keeps snapshots in this server's memory
	(Studio, D-019); nil means not decided yet, so nothing is read or written. In "DataStore" mode
	ids <= 0 (test profiles, Local Server players) are never written or read.

	Server API:
	  get(userId) -> (DenSnapshot | false)?  cached CACHE_SECONDS; false = none saved, nil = could not read
	  blockedBy(userId) -> { number }?        the session's reported block list
	  setBlocked(userId, list)                list already cleaned (Matchmaking.cleanBlockList)
	  onSaved(fn(snapshot, reason, lastRaidedAt))  reason "Interval" | "Leave" | "Test"
	  saveTest(profile, blockedUserIds?) -> boolean   Studio + Memory only: snapshot a test profile
	  forgetTest(userId)                              Studio test cleanup
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Matchmaking = require(Shared.Matchmaking)
local Profile = require(Shared.Profile)
local Types = require(Shared.Types)
local DataService = require(script.Parent.DataService) :: any
-- No cycle: IncomeService requires DataService, DenWorldService and Economy/CritterView only.
local IncomeService = require(script.Parent.IncomeService) :: any

type DenSnapshot = Types.DenSnapshot
type PlayerProfile = Types.PlayerProfile
export type Reason = "Interval" | "Leave" | "Test"
type Listener = (DenSnapshot, Reason, number) -> ()

local STORE_NAME = "DenSnapshots"
local TICK_SECONDS = 10
local CACHE_SECONDS = 60
local MIN_WRITE_BUDGET = 10 -- interval writes yield to leave writes when the budget runs low
local MIN_READ_BUDGET = 5
local CLOSE_WAIT_SECONDS = 20

local SnapshotService = {}

local store: DataStore? = nil
local mode: ("DataStore" | "Memory")? = nil
local memory: { [number]: DenSnapshot } = {}
local cache: { [number]: { at: number, value: DenSnapshot | false } } = {}
local blocks: { [number]: { number } } = {}
local lastSaved: { [number]: number } = {} -- os.clock() of the last interval save
local listeners: { Listener } = {}
local pending = 0

local function storage(): ("DataStore" | "Memory")?
	if mode == nil then
		mode = DataService.persistence()
		if mode == "DataStore" then
			store = DataStoreService:GetDataStore(STORE_NAME)
		end
	end
	return mode
end

local function build(profile: PlayerProfile, now: number): DenSnapshot
	if DataService.getProfile(profile.userId) == profile then
		IncomeService.accrue(profile, now) -- at the owner's Glow factor, before the copy
	end
	local snapshot = Matchmaking.buildSnapshot(table.clone(profile), now)
	snapshot.blockedUserIds = blocks[profile.userId]
	return snapshot
end

local function write(snapshot: DenSnapshot, reason: Reason, lastRaidedAt: number): boolean
	local where = storage()
	local userId = snapshot.userId
	if where == nil or (where == "DataStore" and userId <= 0) then
		return false
	end
	if where == "Memory" then
		local old = memory[userId]
		if snapshot.blockedUserIds == nil and old then
			snapshot.blockedUserIds = old.blockedUserIds
		end
		memory[userId] = snapshot
	else
		local budget = DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync)
		if reason == "Interval" and budget < MIN_WRITE_BUDGET then
			return false
		end
		local ok, err = pcall(function()
			(store :: DataStore):UpdateAsync(`Snapshot_{userId}`, function(old: any): any
				if snapshot.blockedUserIds == nil and type(old) == "table" and type(old.blockedUserIds) == "table" then
					snapshot.blockedUserIds = old.blockedUserIds
				end
				return snapshot
			end)
		end)
		if not ok then
			warn(`[SnapshotService] {reason} snapshot for {userId} failed: {err}`)
			return false
		end
	end
	cache[userId] = { at = os.clock(), value = snapshot }
	for _, fn in listeners do
		task.spawn(fn, snapshot, reason, lastRaidedAt)
	end
	return true
end

function SnapshotService.get(userId: number): (DenSnapshot | false)?
	local hit = cache[userId]
	if hit and os.clock() - hit.at < CACHE_SECONDS then
		return hit.value
	end
	local where = storage()
	local value: any = nil
	if where == "Memory" then
		value = memory[userId]
	elseif where == "DataStore" and userId > 0 then
		if DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.GetAsync) < MIN_READ_BUDGET then
			return nil
		end
		local ok, result = pcall(function(): any
			return (store :: DataStore):GetAsync(`Snapshot_{userId}`)
		end)
		if not ok then
			warn(`[SnapshotService] reading snapshot {userId} failed: {result}`)
			return nil
		end
		value = result
	else
		return nil
	end
	local found: DenSnapshot | false = false
	if type(value) == "table" and value.userId == userId and type(value.power) == "number" then
		found = value
	end
	cache[userId] = { at = os.clock(), value = found }
	return found
end

function SnapshotService.blockedBy(userId: number): { number }?
	return blocks[userId]
end

function SnapshotService.setBlocked(userId: number, list: { number })
	blocks[userId] = list
end

function SnapshotService.onSaved(fn: Listener)
	table.insert(listeners, fn)
end

function SnapshotService.saveTest(profile: PlayerProfile, blockedUserIds: { number }?): boolean
	if not RunService:IsStudio() or storage() ~= "Memory" or not Profile.isTestUserId(profile.userId) then
		return false
	end
	local snapshot = build(profile, os.time())
	snapshot.blockedUserIds = blockedUserIds or {}
	return write(snapshot, "Test", Matchmaking.lastRaidedAt(profile))
end

function SnapshotService.forgetTest(userId: number)
	if Profile.isTestUserId(userId) then
		memory[userId] = nil
		cache[userId] = nil
	end
end

local function tick()
	local now = os.clock()
	for userId, hit in cache do
		if now - hit.at >= CACHE_SECONDS then
			cache[userId] = nil
		end
	end
	for _, player in Players:GetPlayers() do
		local userId = player.UserId
		local profile = DataService.getProfile(userId)
		local last = lastSaved[userId]
		if profile and (last == nil or now - last >= Config.Snapshot.intervalSeconds) then
			lastSaved[userId] = now
			write(build(profile, os.time()), "Interval", Matchmaking.lastRaidedAt(profile))
		end
	end
end

function SnapshotService.start()
	DataService.onProfileReleasing(function(userId: number, profile: PlayerProfile)
		lastSaved[userId] = nil
		if Profile.isTestUserId(userId) then
			return -- test snapshots come only from saveTest
		end
		local snapshot = build(profile, os.time())
		local lastRaidedAt = Matchmaking.lastRaidedAt(profile)
		blocks[userId] = nil
		pending += 1
		task.spawn(function()
			local ok, err = pcall(write, snapshot, "Leave", lastRaidedAt)
			if not ok then
				warn(`[SnapshotService] leave snapshot for {userId} errored: {err}`)
			end
			pending -= 1
		end)
	end)
	game:BindToClose(function()
		local deadline = os.clock() + CLOSE_WAIT_SECONDS
		task.wait(2) -- ProfileStore's own BindToClose runs the releasing listeners first
		while pending > 0 and os.clock() < deadline do
			task.wait(0.5)
		end
	end)
	task.spawn(function()
		while true do
			local ok, err = pcall(tick)
			if not ok then
				warn(`[SnapshotService] tick failed: {err}`)
			end
			task.wait(TICK_SECONDS)
		end
	end)
end

return SnapshotService
