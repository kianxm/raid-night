--!strict
--[[
	ReplayStore (owner: raid agent): saves raid replays (Shared/Replay.encode strings) per raidId
	and serves Net.Requests.GetReplay. Fail safe: nothing here can change a raid's result. save()
	runs on its own thread inside pcall and only warns; every store call is pcall'd.

	Storage and lifetime: docs/contracts.md, Replays. DataStore `RaidReplays`, keys
	Replay_<raidId> (StoredReplay) and Index_<raiderUserId> (Replay.ReplayIndex), in memory under
	"Memory" persistence (D-019). Served for 7 days after savedAt. Lazy per-raider sweep: a save
	updates the raider's index first (a failure skips the replay, so every replay is indexed),
	then writes the replay, then deletes what Replay.indexAfterSave dropped.

	Who may fetch: only the raider and the defender named in the stored record. The server writes
	both from its own raid state at save time; a client only ever sends a raidId, which is
	validated and never trusted for ownership.

	API:
	  start(remotes)   create the GetReplay RemoteFunction in `remotes` (idempotent); in Studio
	                   also ServerStorage.ReplayTestHook (below). RaidService.start calls this.
	  save(raidId, raiderUserId, defenderUserId, startedAt, data)   fire and forget, never errors
	  saveNow(...same) -> (ok, reason?)    yields; what save() runs
	  fetch(userId, raidId) -> Net.ReplayPayload?   yields; nil unless userId is a party

	Studio only (single client): during Play, from the command bar (server side):
	  local hook = game:GetService("ServerStorage"):WaitForChild("ReplayTestHook")
	  hook:Invoke("synthetic")             --> raidId, bytes  (raider = first player, 3-min raid)
	  hook:Invoke("fetch", userId, raidId) --> summary string, or nil
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage.Shared
local Net = require(Shared.Net)
local Replay = require(Shared.Replay)
local DataService = require(script.Parent.Parent.Services.DataService)

type StoredReplay = {
	v: number, -- Replay format version of data
	raidId: string,
	raiderUserId: number,
	defenderUserId: number,
	startedAt: number,
	savedAt: number,
	data: string,
}

local STORE_NAME = "RaidReplays"
local LIMIT_WINDOW_SECONDS = 10
local MIN_BUDGET = 10 -- skip a call rather than spend the server's last DataStore requests
local TEST_DEFENDER = -1_000_002 -- reserved test id (Profile.isTestUserId)

local ReplayStore = {}

local mode: ("DataStore" | "Memory")? = nil
local dataStore: DataStore? = nil
local memory: { [string]: any } = {}
local windows: { [Player]: { start: number, count: number } } = {}
local busy: { [Player]: boolean } = {}
local started = false

-- The profiles' mode (D-019), taken once from a non-nil DataService.persistence().
local function storage(): ("DataStore" | "Memory")?
	if mode == nil then
		local decided = DataService.persistence()
		if decided == "DataStore" then
			dataStore = DataStoreService:GetDataStore(STORE_NAME)
		end
		mode = decided
	end
	return mode
end

local function hasBudget(kind: Enum.DataStoreRequestType): boolean
	return DataStoreService:GetRequestBudgetForRequestType(kind) >= MIN_BUDGET
end

local function isUserId(v: any): boolean
	return type(v) == "number" and v == math.floor(v) and v ~= 0 and math.abs(v) < 2 ^ 53
end

local function asRecord(raw: any, raidId: string): StoredReplay?
	if
		type(raw) ~= "table"
		or raw.raidId ~= raidId
		or type(raw.v) ~= "number"
		or not isUserId(raw.raiderUserId)
		or not isUserId(raw.defenderUserId)
		or type(raw.startedAt) ~= "number"
		or type(raw.savedAt) ~= "number"
		or type(raw.data) ~= "string"
	then
		return nil
	end
	return raw
end

local function remove(key: string)
	if mode == "Memory" then
		memory[key] = nil
		return
	end
	local store = dataStore :: DataStore
	local ok, err = pcall(function()
		store:RemoveAsync(key)
	end)
	if not ok then
		warn(`[ReplayStore] remove {key} failed: {err}`)
	end
end

function ReplayStore.saveNow(
	raidId: string,
	raiderUserId: number,
	defenderUserId: number,
	startedAt: number,
	data: string
): (boolean, string?)
	if not Replay.isRaidId(raidId) or not isUserId(raiderUserId) or not isUserId(defenderUserId) then
		return false, "BadArguments"
	end
	if raiderUserId == defenderUserId or type(startedAt) ~= "number" or Replay.decode(data) == nil then
		return false, "BadArguments"
	end
	local backend = storage()
	if backend == nil then
		return false, "NotReady"
	end
	local savedAt = os.time()
	local record: StoredReplay = {
		v = Replay.VERSION,
		raidId = raidId,
		raiderUserId = raiderUserId,
		defenderUserId = defenderUserId,
		startedAt = startedAt,
		savedAt = savedAt,
		data = data,
	}
	local indexKey, key = `Index_{raiderUserId}`, `Replay_{raidId}`
	local dropped: { string } = {}
	if backend == "Memory" then
		memory[indexKey], dropped = Replay.indexAfterSave(memory[indexKey], raidId, savedAt)
		memory[key] = table.clone(record)
	else
		local store = dataStore :: DataStore
		if
			not hasBudget(Enum.DataStoreRequestType.UpdateAsync)
			or not hasBudget(Enum.DataStoreRequestType.SetIncrementAsync)
		then
			return false, "NoBudget"
		end
		-- The index first, so every stored replay is one a later sweep can delete.
		local indexed, indexErr = pcall(function()
			store:UpdateAsync(indexKey, function(old: any): any
				local kept
				kept, dropped = Replay.indexAfterSave(old, raidId, savedAt)
				return kept
			end)
		end)
		if not indexed then
			return false, `index UpdateAsync failed: {indexErr}`
		end
		local ok, err = pcall(function()
			store:SetAsync(key, record, { raiderUserId, defenderUserId })
		end)
		if not ok then
			return false, `SetAsync failed: {err}`
		end
	end
	for _, id in dropped do
		remove(`Replay_{id}`)
	end
	return true, nil
end

function ReplayStore.save(raidId: string, raiderUserId: number, defenderUserId: number, startedAt: number, data: string)
	task.spawn(function()
		local ran, ok, reason = pcall(ReplayStore.saveNow, raidId, raiderUserId, defenderUserId, startedAt, data)
		if not ran or not ok then
			warn(`[ReplayStore] replay {raidId} not saved: {if ran then reason else ok}`)
		end
	end)
end

function ReplayStore.fetch(userId: number, raidId: any): Net.ReplayPayload?
	if not Replay.isRaidId(raidId) then
		return nil
	end
	local id = raidId :: string
	local key = `Replay_{id}`
	local backend = storage()
	local record: StoredReplay? = nil
	if backend == "Memory" then
		record = asRecord(memory[key], id)
	elseif backend == "DataStore" and hasBudget(Enum.DataStoreRequestType.GetAsync) then
		local store = dataStore :: DataStore
		local ok, raw = pcall(function(): any
			return (store:GetAsync(key))
		end)
		record = if ok then asRecord(raw, id) else nil
	end
	if record == nil then
		return nil
	end
	if Replay.isExpired(record.savedAt, os.time()) then
		task.spawn(remove, key)
		return nil
	end
	if userId ~= record.raiderUserId and userId ~= record.defenderUserId then
		return nil
	end
	return {
		raidId = record.raidId,
		version = record.v,
		raiderUserId = record.raiderUserId,
		defenderUserId = record.defenderUserId,
		startedAt = record.startedAt,
		data = record.data,
	}
end

local function allow(player: Player): boolean
	local clock = os.clock()
	local window = windows[player]
	if not window or clock - window.start >= LIMIT_WINDOW_SECONDS then
		window = { start = clock, count = 0 }
		windows[player] = window
	end
	window.count += 1
	return window.count <= Net.Limits.GetReplay
end

local function onGetReplay(player: Player, raidId: any): Net.ReplayPayload?
	if busy[player] or not allow(player) then
		return nil
	end
	busy[player] = true
	local ok, payload = pcall(ReplayStore.fetch, player.UserId, raidId)
	busy[player] = nil
	return if ok then payload else nil
end

-- Studio only: a synthetic 3-minute raid in a circle with every event kind, saved for `raider`.
local function saveSynthetic(raider: number): (string?, number | string)
	local startedAt = os.time()
	local rec = Replay.newRecorder(startedAt, 50000, 200, -50000)
	for i = 0, 899 do
		local a = i / 60
		Replay.recordFrame(rec, startedAt + i / Replay.HZ, 50000 + 40 * math.cos(a), 203, -50000 + 40 * math.sin(a))
	end
	local kinds: { Replay.EventKind } = { "Grab", "Trap", "Tag", "Drop", "Timeout", "Escape" }
	for i, kind in kinds do
		Replay.recordEvent(rec, startedAt + i * 25, kind, if kind == "Grab" then "test_critter" else nil)
	end
	local raidId = HttpService:GenerateGUID(false)
	local data = Replay.encode(rec)
	local ok, reason = ReplayStore.saveNow(raidId, raider, TEST_DEFENDER, startedAt, data)
	return if ok then raidId else nil, if ok then #data else reason :: string
end

local function installTestHook()
	local hook = Instance.new("BindableFunction")
	hook.Name = "ReplayTestHook"
	hook.OnInvoke = function(command: string, a: any, b: any): ...any
		if command == "synthetic" then
			local player = Players:GetPlayers()[1]
			return saveSynthetic(if type(a) == "number" then a elseif player then player.UserId else -1)
		elseif command == "fetch" then
			local payload = ReplayStore.fetch(a, b)
			local decoded = payload and Replay.decode(payload.data)
			if payload == nil or decoded == nil then
				return nil
			end
			return `v{payload.version} raider {payload.raiderUserId} defender {payload.defenderUserId}: {#payload.data} bytes, {#decoded.frames} frames, {#decoded.events} events`
		end
		return nil
	end
	hook.Parent = ServerStorage
end

function ReplayStore.start(remotes: Instance)
	if started then
		return
	end
	started = true
	local existing = remotes:FindFirstChild(Net.Requests.GetReplay)
	local remote: RemoteFunction
	if existing and existing:IsA("RemoteFunction") then
		remote = existing
	else
		remote = Instance.new("RemoteFunction")
		remote.Name = Net.Requests.GetReplay
		remote.Parent = remotes
	end
	remote.OnServerInvoke = onGetReplay
	Players.PlayerRemoving:Connect(function(player: Player)
		windows[player] = nil
		busy[player] = nil
	end)
	if RunService:IsStudio() then
		installTestHook()
	end
end

return ReplayStore
