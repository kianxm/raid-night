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
	every Config.Matchmaking.presenceRefreshSeconds, TTL PRESENCE_TTL_SECONDS. Not removed on leave:
	a server hop rewrites it from the new server, and a quit expires within the TTL.

	Budget: after any MemoryStore error, calls back off (1 s doubling to 60 s). During a backoff,
	acquireLock fails closed ("Busy"); releaseLock still tries. Storage follows
	DataService.persistence(): "Memory" keeps all of this in tables here (Studio, D-019), so a test
	id never reaches a real pool; nil = not decided, nothing is read or written.

	Remotes (ReplicatedStorage.Remotes):
	  GetRaidTargets (RemoteFunction) () -> { Net.RaidTarget }. Net.Limits.GetRaidTargets, one call
	    at a time per player. {} unless Config.Flags.raids and asyncRaids (D-002). Revenge rows
	    first. Blocked both ways: the raider's reported list and each target's snapshot list.
	  ReportBlocked (RemoteEvent) ({ number }). Net.Limits.ReportBlocked; Matchmaking.cleanBlockList
	    or ignored.

	Server API:
	  acquireLock(defenderUserId, raiderUserId, raidId) -> (boolean, reason?)
	      reasons "SwitchedOff" | "Invalid" | "Locked" | "Busy". Call it in StartRaid (P1.3).
	  releaseLock(defenderUserId, raidId) -> boolean   on raid end
	  noteRaided(defenderUserId, power, at, shieldUntil)  after an async debit, so the pool stops
	      offering the shielded den (P1.3)
	  getPresence(userId) -> { jobId: string, placeId: number, at: number }?   (P1.9)
	Studio only: ServerStorage.MatchmakingTestHook, see the end of this file.
]]

local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local UserService = game:GetService("UserService")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local CritterCatalog = require(Shared.CritterCatalog)
local Matchmaking = require(Shared.Matchmaking)
local Net = require(Shared.Net)
local Profile = require(Shared.Profile)
local Types = require(Shared.Types)
local DataService = require(script.Parent.DataService) :: any
local SnapshotService = require(script.Parent.SnapshotService)

type DenSnapshot = Types.DenSnapshot
type MatchEntry = Types.MatchEntry
type PlayerProfile = Types.PlayerProfile
type RaidTarget = Net.RaidTarget
type Presence = { jobId: string, placeId: number, at: number }

local LIMIT_WINDOW_SECONDS = 10
local POOL_READ_COUNT = 20 -- items per band per read; a read costs one request unit per item
local POOL_CACHE_SECONDS = 60
local MAX_BACKOFF_SECONDS = 60
local RELEASED_TTL_SECONDS = 10
local PRESENCE_TTL_SECONDS = math.floor(Config.Matchmaking.presenceRefreshSeconds * 2.5)
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
		mapSet("Presence", false, tostring(userId), value, PRESENCE_TTL_SECONDS, nil)
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
	  hook:Invoke("clear")    remove both test dens and the revenge token
]]
local TEST_TARGET, TEST_REVENGE, TEST_RAID = -1_000_101, -1_000_102, "studio-revenge"
local seeded: { [number]: PlayerProfile } = {}

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
	elseif command == "clear" then
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

	SnapshotService.onSaved(publish)
	DataService.onProfileLoaded(function(player: Player, profile: PlayerProfile)
		writePresence(player.UserId)
		withdraw(player.UserId, Matchmaking.denPower(profile))
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		windows[player] = nil
		busy[player] = nil
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
