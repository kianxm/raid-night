--!strict
--[[
	RaidApi (owner: ui agent): the one place the raid screens talk to "the server".

	Real remotes (Net.luau) by default. Set USE_MOCK to true for offline UI work with no server.
	The screens call only this module, so they do not change. Shapes are Net.RaidTarget /
	RaidStart / RaidEnd / RevengeJoinStatus and Types.RaidLogEntry in both modes.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net")) :: any
local Config = require(Shared:WaitForChild("Config")) :: any
local RaidMock = require(script.Parent:WaitForChild("RaidMock"))
local Strings = require(script.Parent.Parent:WaitForChild("Hud"):WaitForChild("Strings"))

local USE_MOCK = false
local TARGETS_TTL = 8 -- GetRaidTargets is limited to 3 per 10 s; screens share one answer

local RaidApi = {}
RaidApi.USE_MOCK = USE_MOCK

local startedEvent = Instance.new("BindableEvent")
local endedEvent = Instance.new("BindableEvent")
local revengeEvent = Instance.new("BindableEvent")
-- Fires (raidId, targetUserId, endsAt, gatePosition?, critterCount, isRevenge) when a raid begins.
-- endsAt is server time: compare with workspace:GetServerTimeNow().
RaidApi.raidStarted = startedEvent.Event
-- Fires (RaidEnd) when it ends.
RaidApi.raidEnded = endedEvent.Event
-- Fires (RevengeJoinStatus) for the JoinRevengeServer reply and the RevengeJoinStatus push.
RaidApi.revengeStatus = revengeEvent.Event

local nameCache: { [number]: string } = {}
local targetsCache: { at: number, list: { any } }? = nil
local started = false

local function invoke(name: string, ...: any): any?
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	local r = folder and folder:FindFirstChild(name)
	if not r or not r:IsA("RemoteFunction") then
		return nil
	end
	local ok, result = pcall(r.InvokeServer, r, ...)
	return if ok then result else nil
end

function RaidApi.nameFor(userId: number): string
	if USE_MOCK then
		return RaidMock.nameFor(userId)
	end
	local cached = nameCache[userId]
	if cached then
		return cached
	end
	local ok, name = pcall(Players.GetNameFromUserIdAsync, Players, userId)
	nameCache[userId] = if ok then name else Strings.raiderFallback
	return nameCache[userId]
end

function RaidApi.getTargets(): { any }
	if USE_MOCK then
		return RaidMock.getTargets()
	end
	local cache = targetsCache
	if cache and os.clock() - cache.at < TARGETS_TTL then
		return table.clone(cache.list)
	end
	local result = invoke(Net.Requests.GetRaidTargets)
	local list = if type(result) == "table" then result else {}
	targetsCache = { at = os.clock(), list = list }
	return table.clone(list)
end

-- Returns the RaidStart on success (and announces it), nil if the server refused (flags off,
-- locked target, one raid at a time, rate limit...). The caller shows a toast; never an error.
function RaidApi.startRaid(targetUserId: number, revengeRaidId: string?): any?
	local start: any
	local gate: any
	if USE_MOCK then
		start, gate = RaidMock.startRaid(targetUserId, revengeRaidId)
	else
		start = invoke(Net.Requests.StartRaid, targetUserId, revengeRaidId)
		gate = if type(start) == "table" then start.gatePosition else nil
	end
	targetsCache = nil
	if type(start) ~= "table" or type(start.raidId) ~= "string" then
		return nil
	end
	local critters = if type(start.critters) == "table" then #start.critters else 0
	startedEvent:Fire(start.raidId, start.targetUserId, start.endsAt, gate, critters, start.isRevenge == true)
	return start
end

-- Live revenge join. Returns the RevengeJoinStatus reply (also fired on revengeStatus), or nil
-- when the call failed outright (the screen treats nil as "TeleportFailed").
function RaidApi.joinRevengeServer(revengeRaidId: string): any?
	if USE_MOCK then
		return nil
	end
	local status = invoke(Net.Requests.JoinRevengeServer, revengeRaidId)
	if type(status) == "table" and type(status.state) == "string" then
		revengeEvent:Fire(status)
		return status
	end
	return nil
end

function RaidApi.getRaidLog(): { any }
	if USE_MOCK then
		return RaidMock.getRaidLog()
	end
	local result = invoke(Net.Requests.GetRaidLog)
	return if type(result) == "table" then result else {}
end

function RaidApi.getReplay(raidId: string): any?
	if USE_MOCK then
		return RaidMock.getReplay(raidId)
	end
	return invoke(Net.Requests.GetReplay, raidId)
end

-- Mock mode has no server to end the raid, so the HUD asks us to simulate it.
function RaidApi.mockEnd(raidId: string, escaped: boolean)
	endedEvent:Fire({
		raidId = raidId,
		escaped = escaped,
		speciesId = if escaped then "dusk_mouse" else nil,
		glow = 0,
		reason = if escaped then "Escaped" else "Timeout",
	})
end

-- Sends the player's Roblox block list once on join, and again when it changes. The public
-- client route is StarterGui:GetCore("GetBlockedUserIds") plus the PlayerBlockedEvent /
-- PlayerUnblockedEvent core events. Nothing gates on it: a failure just skips the report.
local function reportBlocked(remote: RemoteEvent)
	local ok, ids = false, nil
	for _ = 1, 10 do -- the core script registers it a moment after join
		ok, ids = pcall(StarterGui.GetCore, StarterGui, "GetBlockedUserIds")
		if ok and type(ids) == "table" then
			break
		end
		task.wait(1)
	end
	if not ok or type(ids) ~= "table" then
		return
	end
	local list = {}
	for _, id in ids do
		if type(id) == "number" and id > 0 and id % 1 == 0 and #list < Config.Matchmaking.maxBlockedUserIds then
			table.insert(list, id)
		end
	end
	remote:FireServer(list)
end

local function watchBlocked(remote: RemoteEvent)
	task.spawn(reportBlocked, remote)
	local pending = false
	local function changed()
		if pending then
			return
		end
		pending = true
		task.delay(6, function() -- the server allows 2 reports per 10 s
			pending = false
			reportBlocked(remote)
		end)
	end
	for _, eventName in { "PlayerBlockedEvent", "PlayerUnblockedEvent" } do
		local ok, event = pcall(StarterGui.GetCore, StarterGui, eventName)
		if ok and typeof(event) == "Instance" and event:IsA("BindableEvent") then
			event.Event:Connect(changed)
		end
	end
end

local function hookRemotes(folder: Instance)
	local function hook(child: Instance)
		if not child:IsA("RemoteEvent") then
			return
		end
		if child.Name == Net.Pushes.RaidEnded then
			child.OnClientEvent:Connect(function(payload: any)
				-- Live carries have no reason; HudController toasts those.
				if type(payload) == "table" and payload.reason ~= nil then
					endedEvent:Fire(payload)
				end
			end)
		elseif child.Name == Net.Pushes.RevengeJoinStatus then
			child.OnClientEvent:Connect(function(payload: any)
				if type(payload) == "table" and type(payload.state) == "string" then
					revengeEvent:Fire(payload)
				end
			end)
		elseif child.Name == Net.Requests.ReportBlocked then
			watchBlocked(child)
		end
	end
	for _, child in folder:GetChildren() do
		hook(child)
	end
	folder.ChildAdded:Connect(hook)
end

-- Safe to call more than once; the first call wires the pushes.
function RaidApi.start()
	if started or USE_MOCK then
		return
	end
	started = true
	task.spawn(function() -- never block client startup waiting for the server's remotes
		hookRemotes(ReplicatedStorage:WaitForChild("Remotes"))
	end)
end

return RaidApi
