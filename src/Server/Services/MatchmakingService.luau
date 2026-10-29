--!strict
--[[
	MatchmakingService (owner: matchmaking agent)

	MemoryStore I/O for matchmaking. Every selection rule is pure, in Shared/Matchmaking.luau.

	Pools: one sorted map per power band, `Pool_<band>`. Key = userId, value =
	Matchmaking.encodeEntry, sortKey = lastActiveAt, TTL Config.Matchmaking.activeWithinSeconds.
	Only offline dens are listed: an entry is published when a leave snapshot is saved
	(SnapshotService.onSaved "Leave") and withdrawn when that player's profile loads again. Reads
	take the newest POOL_READ_COUNT items of each band in the raider's window
	(Matchmaking.bandsToRead), cached per server for POOL_CACHE_SECONDS.

	Raid locks: hash map `RaidLocks`, key = defender userId, TTL Config.Raid.lockTtlSeconds (longer
	than a raid). Acquire and release are one UpdateAsync each (Matchmaking.lockAfterAcquire,
	lockAfterRelease), so two servers can never both hold a defender. A lost release waits out the TTL.

	Presence: hash map `Presence`, key = userId, value { jobId, placeId, at }, written on load and
	every Config.Matchmaking.presenceRefreshSeconds, TTL Matchmaking.presenceTtlSeconds. Not removed on leave:
	a server hop rewrites it from the new server, and a quit expires within the TTL.

	Budget: after any MemoryStore error, calls back off (1 s doubling to 60 s). During a backoff,
	acquireLock fails closed ("Busy"); releaseLock still tries. Storage follows
	DataService.persistence(): "Memory" keeps all of this in tables here (Studio, D-019), so a test
	id never reaches a real pool; nil = not decided, nothing is read or written.

	Remotes (ReplicatedStorage.Remotes):
	  GetRaidTargets (RemoteFunction) () -> { Net.RaidTarget }. Net.Limits.GetRaidTargets, one call
	    at a time per player. {} unless Config.Flags.raids and asyncRaids (D-002). Revenge rows
	    first. Blocked both ways: the raider's reported list and each target's snapshot list.
	    Each answer (after the gates, even an empty one) tracks `raid_portal_opened`
	    (Matchmaking.portalOpenedFields) through AnalyticsService, which also logs RaidFlow.Portal.
	  ReportBlocked (RemoteEvent) ({ number }). Net.Limits.ReportBlocked; Matchmaking.cleanBlockList
	    or ignored.
	  JoinRevengeServer (RemoteFunction) (revengeRaidId) -> Net.RevengeJoinStatus. Live revenge,
	    P1.9: Net.Limits.JoinRevengeServer, one at a time, one teleport in flight per player.
	  RevengeJoinStatus (RemoteEvent push): a teleport that failed after "Teleporting", or arrival.

	Live revenge (P1.9). Never spends a token: it is spent only when a revenge raid starts.
	  Ask     The token must be in the caller's own profile (Matchmaking.liveRevengeToken: unexpired,
	          live pair limit not reached), Config.Flags.raids and asyncRaids on (via
	          Escrow.canStartTransfer "Live", isRevenge), and no block either way (session report,
	          else the last snapshot's list; unreadable refuses). Raider in this server: land now.
	          Else presence (Matchmaking.presenceRoute) -> TeleportService:TeleportAsync with
	          TeleportOptions.ServerInstanceId and teleport data naming only the token id.
	  Fail    No presence, server full or gone, teleport error: "Failed" with a reason; the token
	          is untouched, so the UI offers the async revenge raid instead.
	  Arrive  Teleport data is a hint only (clients can forge it): after the profile loads, the
	          landing server runs the same checks on the arriving player's own profile and needs
	          the raider in THIS server with a den. Then the character lands on the street in
	          front of that den (Matchmaking.revengeLanding, outside it, so a Lockdown still blocks
	          entry, D-013) and the revenge is active in server memory.
	  Use     getLiveRevenge(player) re-checks all of it (no yield) on every call. RaidService runs
	          the raid itself: Lockdown and the live loss rules apply unchanged.

	Server API:
	  acquireLock(defenderUserId, raiderUserId, raidId) -> (boolean, reason?)
	      reasons "SwitchedOff" | "Invalid" | "Locked" | "Busy". Call it in StartRaid (P1.3).
	  releaseLock(defenderUserId, raidId) -> boolean   on raid end
	  noteRaided(defenderUserId, power, at, shieldUntil)  after an async debit, so the pool stops
	      offering the shielded den (P1.3)
	  getPresence(userId) -> { jobId: string, placeId: number, at: number }?   (P1.9)
	  getLiveRevenge(player) -> { raidId: string, targetUserId: number }?   the live revenge this
	      player may use in this server now, re-verified; nil = none. Never spends the token.
	Studio only: ServerStorage.MatchmakingTestHook, see the end of this file.
]]

local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local TeleportService = game:GetService("TeleportService")
local UserService = game:GetService("UserService")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local CritterCatalog = require(Shared.CritterCatalog)
local Escrow = require(Shared.Escrow)
local Matchmaking = require(Shared.Matchmaking)
local Net = require(Shared.Net)
local Plots = require(Shared.Plots)
local Profile = require(Shared.Profile)
local Types = require(Shared.Types)
local DataService = require(script.Parent.DataService) :: any
local DenWorldService = require(script.Parent.DenWorldService) :: any
local SnapshotService = require(script.Parent.SnapshotService)
local AnalyticsService = require(script.Parent.AnalyticsService) -- requires no service: no cycle

type DenSnapshot = Types.DenSnapshot
type MatchEntry = Types.MatchEntry
type PlayerProfile = Types.PlayerProfile
type RaidTarget = Net.RaidTarget
type Presence = Matchmaking.Presence
type RevengeToken = Types.RevengeToken
type Status = Net.RevengeJoinStatus
type Revenge = { raidId: string, targetUserId: number }

local LIMIT_WINDOW_SECONDS = 10
local POOL_READ_COUNT = 20 -- items per band per read; a read costs one request unit per item
local POOL_CACHE_SECONDS = 60
local MAX_BACKOFF_SECONDS = 60
local RELEASED_TTL_SECONDS = 10
local PRESENCE_CACHE_SECONDS = 15 -- raiderOnline on Raid Portal revenge rows
local PENDING_SECONDS = 30 -- one teleport in flight per player; TeleportInitFailed clears it sooner
local ARRIVAL_WAIT_SECONDS = 20 -- how long an arriving revenge raider's character may take
local MAX_BLOCK_PASSES = 3 -- re-picks after a target turns out to block the raider
local MAX_NAMES = 2000

local MatchmakingService = {}

type Item = { value: any, expiresAt: number, sortKey: number? }
local memoryMaps: { [string]: { [string]: Item } } = {}
local realMaps: { [string]: any } = {}
local mode: ("DataStore" | "Memory")? = nil
local backoffUntil, backoffSeconds = 0, 0
local poolCache: { [number]: { at: number, entries: { MatchEntry } } } = {}
local names: { [number]: string } = {}
local nameCount = 0
local windows: { [Player]: { [string]: { start: number, count: number } } } = {}
local busy: { [Player]: true } = {}
local joining: { [Player]: true } = {}
local pending: { [Player]: { untilClock: number, raidId: string, targetUserId: number } } = {}
local active: { [Player]: Revenge } = {} -- live revenges landed in this server (re-verified on use)
local hints: { [Player]: string } = {} -- a teleport data hint, held until the profile loads
local presenceCache: { [number]: { at: number, value: Presence? } } = {}
local presenceCount = 0
local testDens: { [number]: number } = {} -- Studio hook only: stand-in den owner -> plot
local statusPush: RemoteEvent? = nil

-- Storage --------------------------------------------------------------------------------------

local function storage(): ("DataStore" | "Memory")?
	if mode == nil then
		mode = DataService.persistence()
	end
	return mode
end

local function memMap(name: string): { [string]: Item }
	local map = memoryMaps[name]
	if not map then
		map = {}
		memoryMaps[name] = map
	end
	return map
end

local function liveItem(map: { [string]: Item }, key: string): Item?
	local item = map[key]
	if item and os.clock() >= item.expiresAt then
		map[key] = nil
		return nil
	end
	return item
end

local function realMap(name: string, sorted: boolean): any
	local map = realMaps[name]
	if not map then
		map = if sorted then MemoryStoreService:GetSortedMap(name) else MemoryStoreService:GetHashMap(name)
		realMaps[name] = map
	end
	return map
end

-- One MemoryStore call with backoff: (ok, result). `essential` calls ignore a backoff.
local function call(what: string, essential: boolean, fn: () -> any): (boolean, any)
	if not essential and os.clock() < backoffUntil then
		return false, nil
	end
	local ok, result = pcall(fn)
	if ok then
		backoffSeconds = 0
		return true, result
	end
	backoffSeconds = math.min(math.max(backoffSeconds * 2, 1), MAX_BACKOFF_SECONDS)
	backoffUntil = os.clock() + backoffSeconds
	warn(`[MatchmakingService] {what} failed, backing off {backoffSeconds} s: {result}`)
	return false, nil
end

local function mapUpdate(name: string, sorted: boolean, key: string, fn: (any) -> any, ttl: number, essential: boolean)
	local where = storage()
	if where == "Memory" then
		local map = memMap(name)
		local item = liveItem(map, key)
		local new = fn(if item then item.value else nil)
		if new ~= nil then
			map[key] = { value = new, expiresAt = os.clock() + ttl, sortKey = if item then item.sortKey else nil }
		end
		return true, new
	elseif where == nil then
		return false, nil
	end
	return call(`{name} update`, essential, function(): any
		local map = realMap(name, sorted)
		if sorted then
			return map:UpdateAsync(key, function(old: any, sortKey: any): (any, any)
				local new = fn(old)
				if new == nil then
					return nil, nil
				end
				return new, sortKey
			end, ttl)
		end
		return map:UpdateAsync(key, fn, ttl)
	end)
end

local function mapSet(name: string, sorted: boolean, key: string, value: any, ttl: number, sortKey: number?): boolean
	local where = storage()
	if where == "Memory" then
		memMap(name)[key] = { value = value, expiresAt = os.clock() + ttl, sortKey = sortKey }
		return true
	end
	return where ~= nil
		and (
			call(`{name} set`, false, function(): any
				local map = realMap(name, sorted)
				return if sorted then map:SetAsync(key, value, ttl, sortKey) else map:SetAsync(key, value, ttl)
			end)
		)
end

local function mapRemove(name: string, sorted: boolean, key: string)
	local where = storage()
	if where == "Memory" then
		memMap(name)[key] = nil
	elseif where ~= nil then
		call(`{name} remove`, false, function(): any
			return realMap(name, sorted):RemoveAsync(key)
		end)
	end
end

-- Pools ------------------------------------------------------------------------------------------

local function poolName(band: number): string
	return `Pool_{band}`
end

-- Real pools and presence only ever hold real accounts.
local function listable(userId: number): boolean
	return storage() == "Memory" or userId > 0
end

local function publish(snapshot: DenSnapshot, reason: SnapshotService.Reason, lastRaidedAt: number)
	if (reason ~= "Leave" and reason ~= "Test") or not listable(snapshot.userId) then
		return
	end
	local entry = Matchmaking.toEntry(snapshot, snapshot.takenAt, lastRaidedAt)
	local band = Matchmaking.powerBand(entry.power)
	local ttl = Config.Matchmaking.activeWithinSeconds
	if
		mapSet(poolName(band), true, tostring(entry.userId), Matchmaking.encodeEntry(entry), ttl, entry.lastActiveAt)
	then
		poolCache[band] = nil
	end
end

-- An online player is not an async target: drop them from the bands around their power.
local function withdraw(userId: number, power: number)
	local band = Matchmaking.powerBand(power)
	for b = math.max(0, band - 1), band + 1 do
		mapRemove(poolName(b), true, tostring(userId))
		poolCache[b] = nil
	end
end

local function readBand(band: number): { MatchEntry }
	local hit = poolCache[band]
	if hit and os.clock() - hit.at < POOL_CACHE_SECONDS then
		return hit.entries
	end
	local raw: { { key: string, value: any } } = {}
	local where = storage()
	if where == "Memory" then
		local list = {}
		local map = memMap(poolName(band))
		for key, item in map do
			if liveItem(map, key) then
				table.insert(list, { key = key, value = item.value, sortKey = item.sortKey or 0 })
			end
		end
		table.sort(list, function(a, b)
			return a.sortKey > b.sortKey
		end)
		for i = 1, math.min(POOL_READ_COUNT, #list) do
			table.insert(raw, list[i])
		end
	elseif where ~= nil then
		local ok, items = call(`{poolName(band)} read`, false, function(): any
			return realMap(poolName(band), true):GetRangeAsync(Enum.SortDirection.Descending, POOL_READ_COUNT)
		end)
		if not ok then
			return if hit then hit.entries else {}
		end
		raw = items
	end
	local entries: { MatchEntry } = {}
	for _, item in raw do
		local entry = Matchmaking.decodeEntry(item.key, item.value)
		if entry then
			table.insert(entries, entry)
		end
	end
	poolCache[band] = { at = os.clock(), entries = entries }
	return entries
end

-- The plot of `userId`'s den in this server: a player here with a loaded profile and a den.
local function denPlot(userId: number): number?
	local target = Players:GetPlayerByUserId(userId)
	if target then
		return if DataService.getProfile(userId) then DenWorldService.getPlot(target) else nil
	end
	return testDens[userId]
end

-- Revenge rows: is the raider online here or in a server we can join? Presence cached briefly.
local function seenOnline(userId: number): boolean
	if denPlot(userId) then
		return true
	end
	local hit = presenceCache[userId]
	if not hit or os.clock() - hit.at >= PRESENCE_CACHE_SECONDS then
		if presenceCount > MAX_NAMES then
			presenceCache, presenceCount = {}, 0
		end
		local fresh = { at = os.clock(), value = MatchmakingService.getPresence(userId) }
		presenceCache[userId] = fresh
		presenceCount += 1
		hit = fresh
	end
	local value = if hit then hit.value else nil
	return Matchmaking.presenceRoute(value, game.JobId, game.PlaceId, os.time()) == "Teleport"
end

-- Targets ----------------------------------------------------------------------------------------

local function fillNames(rows: { RaidTarget })
	local missing: { number } = {}
	for _, row in rows do
		if names[row.userId] == nil and row.userId > 0 then
			table.insert(missing, row.userId)
		end
	end
	if #missing > 0 then
		local ok, infos = pcall(function(): any
			return UserService:GetUserInfosByUserIdsAsync(missing)
		end)
		if ok and type(infos) == "table" then
			if nameCount > MAX_NAMES then
				names, nameCount = {}, 0
			end
			for _, info in infos do
				names[info.Id] = info.DisplayName
				nameCount += 1
			end
		end
	end
	for _, row in rows do
		row.displayName = names[row.userId] or if row.userId <= 0 then `Test {row.userId}` else "Raider"
	end
end

local function computeTargets(userId: number): { RaidTarget }
	local profile: PlayerProfile? = DataService.getProfile(userId)
	if profile == nil then
		return {}
	end
	local power = Matchmaking.denPower(profile)
	local pool: { MatchEntry } = {}
	for _, band in Matchmaking.bandsToRead(power) do
		for _, entry in readBand(band) do
			table.insert(pool, entry)
		end
	end
	local blocked: { [number]: boolean } = {}
	for _, id in SnapshotService.blockedBy(userId) or {} do
		blocked[id] = true
	end
	local rows: { RaidTarget } = {}
	for _ = 1, MAX_BLOCK_PASSES do
		profile = DataService.getProfile(userId) -- re-read after every yield
		if profile == nil then
			return {}
		end
		local refused = false
		rows = {}
		for _, pick in Matchmaking.selectTargets(profile, power, pool, blocked, os.time()) do
			local snapshot = SnapshotService.get(pick.userId)
			if snapshot then
				if Matchmaking.snapshotBlocks(snapshot, userId) then
					blocked[pick.userId], refused = true, true
				else
					table.insert(rows, {
						userId = pick.userId,
						displayName = "",
						power = snapshot.power,
						isRevenge = pick.isRevenge,
						revengeRaidId = pick.revengeRaidId,
						topTier = Matchmaking.topTier(snapshot),
					})
				end
			elseif snapshot == false and pick.isRevenge then
				-- No snapshot yet: still offered first (live revenge, P1.9); StartRaid decides.
				table.insert(rows, {
					userId = pick.userId,
					displayName = "",
					power = 0,
					isRevenge = true,
					revengeRaidId = pick.revengeRaidId,
				})
			else
				-- Unreadable (cannot check its block list) or gone: never shown.
				blocked[pick.userId], refused = true, true
			end
		end
		if not refused then
			break
		end
	end
	for _, row in rows do
		if row.isRevenge then
			row.raiderOnline = seenOnline(row.userId)
		end
	end
	fillNames(rows)
	return rows
end

local function allow(player: Player, name: string): boolean
	local limit = (Net.Limits :: any)[name] or Net.Limits.default
	local now = os.clock()
	local perPlayer = windows[player]
	if not perPlayer then
		perPlayer = {}
		windows[player] = perPlayer
	end
	local window = perPlayer[name]
	if not window or now - window.start >= LIMIT_WINDOW_SECONDS then
		window = { start = now, count = 0 }
		perPlayer[name] = window
	end
	window.count += 1
	return window.count <= limit
end

local function onGetRaidTargets(player: Player): { RaidTarget }
	if not allow(player, "GetRaidTargets") or busy[player] then
		return {}
	end
	if not (Config.Flags.raids and Config.Flags.asyncRaids) then
		return {}
	end
	busy[player] = true
	local ok, rows = pcall(computeTargets, player.UserId)
	busy[player] = nil
	if not ok then
		warn(`[MatchmakingService] GetRaidTargets for {player.UserId} failed: {rows}`)
		return {}
	end
	-- P2.9: one event per answered portal visit; it also opens a RaidFlow funnel session (Portal).
	-- Never yields or throws.
	AnalyticsService.track(player, "raid_portal_opened", Matchmaking.portalOpenedFields(rows))
	return rows
end

-- Locks and presence -----------------------------------------------------------------------------

function MatchmakingService.acquireLock(
	defenderUserId: number,
	raiderUserId: number,
	raidId: string
): (boolean, string?)
	if not Config.Flags.raids then
		return false, "SwitchedOff"
	end
	if type(raidId) ~= "string" or raidId == "" or defenderUserId == raiderUserId then
		return false, "Invalid"
	end
	local ok, lock = mapUpdate("RaidLocks", false, tostring(defenderUserId), function(current: any): any
		return Matchmaking.lockAfterAcquire(current, raiderUserId, raidId)
	end, Config.Raid.lockTtlSeconds, false)
	if not ok then
		return false, "Busy"
	end
	return lock ~= nil, if lock == nil then "Locked" else nil
end

function MatchmakingService.releaseLock(defenderUserId: number, raidId: string): boolean
	local ok = mapUpdate("RaidLocks", false, tostring(defenderUserId), function(current: any): any
		return Matchmaking.lockAfterRelease(current, raidId)
	end, RELEASED_TTL_SECONDS, true)
	return ok
end

function MatchmakingService.noteRaided(defenderUserId: number, power: number, at: number, shieldUntil: number)
	local key = tostring(defenderUserId)
	local band = Matchmaking.powerBand(power)
	mapUpdate(poolName(band), true, key, function(old: any): any
		local entry = Matchmaking.decodeEntry(key, old)
		if entry == nil then
			return nil
		end
		entry.lastRaidedAt = math.max(entry.lastRaidedAt, at)
		entry.shieldUntil = math.max(entry.shieldUntil, shieldUntil)
		return Matchmaking.encodeEntry(entry)
	end, Config.Matchmaking.activeWithinSeconds, false)
	poolCache[band] = nil
end

local function writePresence(userId: number)
	if listable(userId) then
		local value = { jobId = game.JobId, placeId = game.PlaceId, at = os.time() }
		mapSet("Presence", false, tostring(userId), value, Matchmaking.presenceTtlSeconds, nil)
	end
end

function MatchmakingService.getPresence(userId: number): Presence?
	local where = storage()
	local value: any = nil
	if where == "Memory" then
		local item = liveItem(memMap("Presence"), tostring(userId))
		value = item and item.value
	elseif where ~= nil then
		local _, result = call("Presence get", false, function(): any
			return realMap("Presence", false):GetAsync(tostring(userId))
		end)
		value = result
	end
	if type(value) == "table" and type(value.jobId) == "string" and type(value.placeId) == "number" then
		return value
	end
	return nil
end

-- Live revenge (P1.9) ------------------------------------------------------------------------------

local function failed(raidId: any, reason: string, targetUserId: number?): Status
	local id = if type(raidId) == "string" and #raidId <= Config.Escrow.maxRaidIdLength then raidId else ""
	return { state = "Failed", revengeRaidId = id, targetUserId = targetUserId, reason = reason }
end

local function push(player: Player, status: Status)
	if statusPush and player.Parent then
		statusPush:FireClient(player, status)
	end
end

-- Does `userId`'s block list name `other`? Their session report, else (only when `mayYield`) their
-- last snapshot's list. nil = cannot tell. No report and `mayYield` false: no new block known.
local function listBlocks(userId: number, other: number, mayYield: boolean): boolean?
	local list = SnapshotService.blockedBy(userId)
	if list then
		return table.find(list, other) ~= nil
	elseif not mayYield then
		return false
	end
	local snapshot = SnapshotService.get(userId)
	if snapshot == nil then
		return nil
	end
	return snapshot ~= false and Matchmaking.snapshotBlocks(snapshot, other)
end

-- Everything a live revenge needs, read now: the gate, the token in the player's OWN profile (never
-- teleport data) and no block either way. Returns the token, or nil and a reason.
local function check(player: Player, raidId: any, skipAsyncGate: boolean, mayYield: boolean): (RevengeToken?, string?)
	local flags: Escrow.KillSwitches = if skipAsyncGate
		then { raids = Config.Flags.raids, asyncRaids = true }
		else Config.Flags
	if not Escrow.canStartTransfer(flags, "Live", true) then
		return nil, "SwitchedOff"
	end
	local profile: PlayerProfile? = DataService.getProfile(player.UserId)
	if profile == nil then
		return nil, "Busy"
	end
	local token, why = Matchmaking.liveRevengeToken(profile, raidId, {}, os.time())
	if token == nil then
		return nil, why
	end
	local target = token.targetUserId
	local mine = listBlocks(player.UserId, target, mayYield)
	local theirs = listBlocks(target, player.UserId, mayYield)
	if mine == nil or theirs == nil then
		return nil, "Busy"
	end
	profile = DataService.getProfile(player.UserId) -- re-read after a yield
	if profile == nil then
		return nil, "Busy"
	end
	local blocked = if mine or theirs then { [target] = true } else {}
	return Matchmaking.liveRevengeToken(profile, raidId, blocked, os.time())
end

-- Puts the player on the street in front of the raider's den here, facing it, and marks the
-- revenge active. Never inside the den, so a Lockdown still blocks entry (D-013).
local function land(player: Player, token: RevengeToken): Status
	local plot = denPlot(token.targetUserId)
	local character = player.Character
	if plot == nil then
		return failed(token.raidId, "RaiderOffline", token.targetUserId)
	elseif not (character and character:FindFirstChild("HumanoidRootPart")) then
		return failed(token.raidId, "Busy", token.targetUserId)
	end
	local x, z = Matchmaking.revengeLanding(plot)
	local cx, cz = Plots.center(plot)
	local y = DenWorldService.getSpawnCFrame(plot).Position.Y
	character:PivotTo(CFrame.lookAt(Vector3.new(x, y, z), Vector3.new(cx, y, cz)))
	active[player] = { raidId = token.raidId, targetUserId = token.targetUserId }
	return { state = "Arrived", revengeRaidId = token.raidId, targetUserId = token.targetUserId }
end

local function join(player: Player, raidId: any, skipAsyncGate: boolean): Status
	local inFlight = pending[player]
	if inFlight and os.clock() < inFlight.untilClock then
		return failed(raidId, "Busy", inFlight.targetUserId)
	end
	local token, why = check(player, raidId, skipAsyncGate, true)
	if token == nil then
		return failed(raidId, why or "Invalid", nil)
	end
	local target = token.targetUserId
	if denPlot(target) then
		return land(player, token)
	end
	local presence = MatchmakingService.getPresence(target)
	if presence == nil or Matchmaking.presenceRoute(presence, game.JobId, game.PlaceId, os.time()) ~= "Teleport" then
		return failed(token.raidId, "RaiderOffline", target)
	end
	token, why = check(player, raidId, skipAsyncGate, false) -- re-read after the presence read
	if token == nil or token.targetUserId ~= target then
		return failed(raidId, why or "NoToken", nil)
	end
	local options = Instance.new("TeleportOptions")
	options.ServerInstanceId = presence.jobId
	options:SetTeleportData(Matchmaking.revengeTeleportData(token.raidId))
	pending[player] = { untilClock = os.clock() + PENDING_SECONDS, raidId = token.raidId, targetUserId = target }
	local ok, err = pcall(function(): any
		return TeleportService:TeleportAsync(presence.placeId, { player }, options)
	end)
	if not ok then
		pending[player] = nil
		warn(`[MatchmakingService] revenge teleport for {player.UserId} failed: {err}`)
		return failed(token.raidId, "TeleportFailed", target)
	end
	return { state = "Teleporting", revengeRaidId = token.raidId, targetUserId = target }
end

-- The landing server's side. `raidId` came from teleport data, so everything is checked again.
local function arrive(player: Player, raidId: string, skipAsyncGate: boolean): Status
	local deadline = os.clock() + ARRIVAL_WAIT_SECONDS
	while player.Parent and os.clock() < deadline do
		local character = player.Character
		if character and character:FindFirstChild("HumanoidRootPart") then
			task.wait(0.2) -- lets DenWorldService's own spawn move into the home den run first
			break
		end
		task.wait(0.2)
	end
	local token, why = check(player, raidId, skipAsyncGate, true)
	if token == nil then
		return failed(raidId, why or "Invalid", nil)
	end
	return land(player, token)
end

local function liveRevengeOf(player: Player, skipAsyncGate: boolean): Revenge?
	local entry = active[player]
	if entry == nil then
		return nil
	end
	local token = check(player, entry.raidId, skipAsyncGate, false)
	if token == nil or token.targetUserId ~= entry.targetUserId or denPlot(entry.targetUserId) == nil then
		return nil
	end
	return { raidId = entry.raidId, targetUserId = entry.targetUserId }
end

function MatchmakingService.getLiveRevenge(player: Player): Revenge?
	return liveRevengeOf(player, false)
end

local function onJoinRevenge(player: Player, raidId: any): Status
	if not allow(player, "JoinRevengeServer") or joining[player] then
		return failed(raidId, "Busy", nil)
	end
	joining[player] = true
	local ok, status = pcall(join, player, raidId, false)
	joining[player] = nil
	if not ok then
		warn(`[MatchmakingService] JoinRevengeServer for {player.UserId} failed: {status}`)
		return failed(raidId, "Busy", nil)
	end
	return status
end

local function readHint(player: Player)
	local ok, data = pcall(function(): any
		return player:GetJoinData()
	end)
	local hint = if ok and type(data) == "table" then Matchmaking.readRevengeHint(data.TeleportData) else nil
	if hint then
		hints[player] = hint
	end
end

local function onArrival(player: Player)
	local hint = hints[player]
	hints[player] = nil
	if hint then
		local ok, status = pcall(arrive, player, hint, false)
		push(player, if ok then status else failed(hint, "Busy", nil))
	end
end

-- Studio test hook (D-019) -----------------------------------------------------------------------
--[[
	Studio + Memory persistence only (set ServerStorage.StudioMemoryProfiles = true before Play).
	From the server command bar during Play:
	  local hook = game:GetService("ServerStorage"):WaitForChild("MatchmakingTestHook")
	  hook:Invoke("seed")     two test dens: -1000101 near your power, and -1000102 far above it
	                          with a revenge token on YOUR profile (memory only)
	  hook:Invoke("targets")  what GetRaidTargets computes for you (skips only the asyncRaids gate)
	  hook:Invoke("block", "raider" | "defender")  you block -1000101, or it blocks you
	  hook:Invoke("unblock")
	  hook:Invoke("lock")     acquire/contend/release a lock on -1000101
	  hook:Invoke("presence") your presence row
	  hook:Invoke("clear")    remove both test dens and the revenge tokens
	Live revenge (P1.9), against RaidTestHook's stand-in den (-1000001); these skip only the
	asyncRaids gate:
	  hook:Invoke("revenge", plot)  a live revenge token vs the stand-in; plot = RaidTestHook seed's
	  hook:Invoke("join", "here" | "away" | "offline")  JoinRevengeServer as you: stand-in here
	                          (you land), in another server (the teleport fails in Studio), or gone
	  hook:Invoke("arrive", raidId?)  the landing server's re-check with that teleport hint
	                          (default the real token; any other id is a forged hint)
	  hook:Invoke("live")     getLiveRevenge for you
]]
local TEST_TARGET, TEST_REVENGE, TEST_RAID = -1_000_101, -1_000_102, "studio-revenge"
local TEST_STAND_IN, TEST_LIVE = -1_000_001, "studio-live-revenge"
local seeded: { [number]: PlayerProfile } = {}
local testPlot: number? = nil

local function describe(player: Player, me: PlayerProfile, status: Status): string
	local kept = me.revengeTokens[TEST_LIVE] ~= nil
	return `{status.state} {status.reason or ""}; token kept {kept}; active {active[player] ~= nil}`
end

local function setTestPresence(jobId: string?)
	if jobId == nil then
		mapRemove("Presence", false, tostring(TEST_STAND_IN))
	else
		local row = { jobId = jobId, placeId = game.PlaceId, at = os.time() }
		mapSet("Presence", false, tostring(TEST_STAND_IN), row, Matchmaking.presenceTtlSeconds, nil)
	end
end

local function testDen(userId: number, power: number): PlayerProfile
	local now = os.time()
	local den = Profile.new(userId, now - Config.Protection.newPlayerSeconds - 3600)
	den.denLevel = Config.Protection.minDenLevel + 5
	local uid = HttpService:GenerateGUID(false)
	den.critters[uid] = {
		uid = uid,
		speciesId = CritterCatalog.byTier("Common")[1].id,
		mutation = "None",
		placement = "Pad",
		padIndex = 1,
		acquiredAt = now,
	}
	local gap = power - Matchmaking.denPower(den)
	if gap > 0 then
		table.insert(den.traps, { kind = "SlowPuddle", level = math.ceil(gap / 10), gridX = 1, gridY = 1 })
	end
	return den
end

local function hook(command: string, arg: any): string
	local player = Players:GetPlayers()[1]
	local me: PlayerProfile? = player and DataService.getProfile(player.UserId)
	if not player or not me then
		return "no client profile loaded yet"
	elseif DataService.persistence() ~= "Memory" then
		return "needs ServerStorage.StudioMemoryProfiles = true before Play"
	end
	local myPower = Matchmaking.denPower(me)
	if command == "seed" then
		local out = {}
		for userId, power in { [TEST_TARGET] = myPower, [TEST_REVENGE] = myPower * 4 + 1000 } do
			local den = seeded[userId] or testDen(userId, power)
			local ok, why = DataService.loadTestProfile(userId, den)
			if ok then
				seeded[userId] = den
				table.insert(out, `{userId} power {Matchmaking.denPower(den)} saved {SnapshotService.saveTest(den)}`)
			else
				table.insert(out, `{userId} refused: {why}`)
			end
		end
		me.revengeTokens[TEST_RAID] = {
			raidId = TEST_RAID,
			targetUserId = TEST_REVENGE,
			expiresAt = os.time() + Config.Revenge.windowSeconds,
			shieldBypassUsed = false,
		}
		return `your power {myPower}; ` .. table.concat(out, "; ")
	elseif command == "targets" then
		local rows = {}
		for _, row in computeTargets(player.UserId) do
			local tag = if row.isRevenge then ` revenge {row.revengeRaidId}` else ""
			table.insert(rows, `{row.displayName} ({row.userId}) power {row.power} top {row.topTier}{tag}`)
		end
		return `{#rows} target(s): ` .. table.concat(rows, " | ")
	elseif command == "block" or command == "unblock" then
		local den = seeded[TEST_TARGET]
		SnapshotService.setBlocked(player.UserId, if arg == "raider" then { TEST_TARGET } else {})
		if den then
			SnapshotService.saveTest(den, if arg == "defender" then { player.UserId } else {})
		end
		return `{command} {arg or ""} done`
	elseif command == "lock" then
		local a = table.pack(MatchmakingService.acquireLock(TEST_TARGET, player.UserId, "studio-lock"))
		local b = table.pack(MatchmakingService.acquireLock(TEST_TARGET, TEST_REVENGE, "studio-other"))
		local released = MatchmakingService.releaseLock(TEST_TARGET, "studio-lock")
		local c = table.pack(MatchmakingService.acquireLock(TEST_TARGET, TEST_REVENGE, "studio-other"))
		MatchmakingService.releaseLock(TEST_TARGET, "studio-other")
		return `first {a[1]}; contender {b[1]} {b[2]}; released {released}; contender after {c[1]}`
	elseif command == "presence" then
		local row = MatchmakingService.getPresence(player.UserId)
		return if row then `{row.jobId} place {row.placeId} at {row.at}` else "none"
	elseif command == "revenge" then
		if type(arg) ~= "number" or arg < 1 or arg > Plots.Layout.plotCount or arg % 1 ~= 0 then
			return "pass the stand-in den's plot (RaidTestHook seed returns it)"
		end
		testPlot = arg
		me.revengeTokens[TEST_LIVE] = {
			raidId = TEST_LIVE,
			targetUserId = TEST_STAND_IN,
			expiresAt = os.time() + Config.Revenge.windowSeconds,
			shieldBypassUsed = false,
		}
		return `token {TEST_LIVE} vs {TEST_STAND_IN} on plot {arg}`
	elseif command == "join" then
		local where = if arg == "away" or arg == "offline" then arg else "here"
		testDens[TEST_STAND_IN] = if where == "here" then testPlot else nil
		setTestPresence(
			if where == "offline" then nil elseif where == "away" then "studio-other-server" else game.JobId
		)
		active[player], pending[player] = nil, nil
		return describe(player, me, join(player, TEST_LIVE, true))
	elseif command == "arrive" then
		testDens[TEST_STAND_IN] = testPlot
		active[player] = nil
		local status = arrive(player, if type(arg) == "string" then arg else TEST_LIVE, true)
		push(player, status)
		return describe(player, me, status)
	elseif command == "live" then
		local live = liveRevengeOf(player, true)
		return if live then `active vs {live.targetUserId} ({live.raidId})` else "none"
	elseif command == "clear" then
		me.revengeTokens[TEST_LIVE] = nil
		testDens[TEST_STAND_IN], testPlot, active[player] = nil, nil, nil
		setTestPresence(nil)
		me.revengeTokens[TEST_RAID] = nil
		SnapshotService.setBlocked(player.UserId, {})
		for userId, den in seeded do
			withdraw(userId, Matchmaking.denPower(den))
			SnapshotService.forgetTest(userId)
			DataService.releaseTestProfile(userId)
			seeded[userId] = nil
		end
		return "cleared"
	end
	return `unknown command {command}`
end

-- Lifecycle --------------------------------------------------------------------------------------

function MatchmakingService.start()
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not (remotes and remotes:IsA("Folder")) then
		remotes = Instance.new("Folder")
		remotes.Name = "Remotes"
		remotes.Parent = ReplicatedStorage
	end
	local targets = Instance.new("RemoteFunction")
	targets.Name = Net.Requests.GetRaidTargets
	targets.OnServerInvoke = onGetRaidTargets
	targets.Parent = remotes
	local report = Instance.new("RemoteEvent")
	report.Name = Net.Requests.ReportBlocked
	report.OnServerEvent:Connect(function(player: Player, payload: any)
		if allow(player, "ReportBlocked") then
			local list = Matchmaking.cleanBlockList(payload)
			if list then
				SnapshotService.setBlocked(player.UserId, list)
			end
		end
	end)
	report.Parent = remotes
	local joinRemote = Instance.new("RemoteFunction")
	joinRemote.Name = Net.Requests.JoinRevengeServer
	joinRemote.OnServerInvoke = onJoinRevenge
	joinRemote.Parent = remotes
	local status = Instance.new("RemoteEvent")
	status.Name = Net.Pushes.RevengeJoinStatus
	status.Parent = remotes
	statusPush = status

	TeleportService.TeleportInitFailed:Connect(function(player: Player, result: Enum.TeleportResult)
		local inFlight = pending[player]
		if inFlight then
			pending[player] = nil
			push(player, failed(inFlight.raidId, Matchmaking.teleportFailReason(result.Name), inFlight.targetUserId))
		end
	end)
	-- Join hints first: onProfileLoaded below also runs at once for profiles already loaded.
	Players.PlayerAdded:Connect(readHint)
	for _, player in Players:GetPlayers() do
		readHint(player)
	end

	SnapshotService.onSaved(publish)
	DataService.onProfileLoaded(function(player: Player, profile: PlayerProfile)
		writePresence(player.UserId)
		withdraw(player.UserId, Matchmaking.denPower(profile))
		if hints[player] then
			task.spawn(onArrival, player)
		end
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		windows[player] = nil
		busy[player] = nil
		joining[player], pending[player], active[player], hints[player] = nil, nil, nil, nil
	end)
	task.spawn(function()
		while true do
			task.wait(Config.Matchmaking.presenceRefreshSeconds)
			for _, player in Players:GetPlayers() do
				if DataService.getProfile(player.UserId) then
					writePresence(player.UserId)
				end
			end
		end
	end)

	if RunService:IsStudio() then
		local bindable = Instance.new("BindableFunction")
		bindable.Name = "MatchmakingTestHook"
		bindable.OnInvoke = function(command: string, arg: any): string
			local ok, result = pcall(hook, command, arg)
			return if ok then result else `error: {result}`
		end
		bindable.Parent = ServerStorage
	end
end

return MatchmakingService
