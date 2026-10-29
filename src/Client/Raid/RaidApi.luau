--!strict
--[[
	RaidApi (owner: ui agent): the one place the raid screens talk to "the server".

	Flip USE_MOCK to false (P1.6) to use the real remotes named in Net.luau. The screens call
	only this module, so they do not change. Shapes are Net.RaidTarget / RaidStart / RaidEnd and
	Types.RaidLogEntry in both modes.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net")) :: any
local RaidMock = require(script.Parent:WaitForChild("RaidMock"))

local USE_MOCK = true

local RaidApi = {}
RaidApi.USE_MOCK = USE_MOCK

local startedEvent = Instance.new("BindableEvent")
local endedEvent = Instance.new("BindableEvent")
-- Fires (raidId, targetUserId, endsAt, gatePosition?) when a raid begins for this player.
RaidApi.raidStarted = startedEvent.Event
-- Fires (RaidEnd) when it ends.
RaidApi.raidEnded = endedEvent.Event

local nameCache: { [number]: string } = {}

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
	nameCache[userId] = if ok then name else "Raider"
	return nameCache[userId]
end

function RaidApi.getTargets(): { any }
	if USE_MOCK then
		return RaidMock.getTargets()
	end
	local result = invoke(Net.Requests.GetRaidTargets)
	return if type(result) == "table" then result else {}
end

-- Returns the RaidStart on success (and announces it), nil if the server refused.
function RaidApi.startRaid(targetUserId: number, revengeRaidId: string?): any?
	local start: any
	local gate: any
	if USE_MOCK then
		start, gate = RaidMock.startRaid(targetUserId, revengeRaidId)
	else
		start = invoke(Net.Requests.StartRaid, targetUserId, revengeRaidId)
		-- Gate position is not in RaidStart yet (handoff). Read it if the server adds one.
		gate = if type(start) == "table" then start.gatePosition else nil
	end
	if type(start) ~= "table" then
		return nil
	end
	startedEvent:Fire(start.raidId, start.targetUserId, start.endsAt, gate)
	return start
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
	})
end

function RaidApi.start()
	if USE_MOCK then
		return
	end
	local folder = ReplicatedStorage:WaitForChild("Remotes")
	local function hook(child: Instance)
		if child.Name == Net.Pushes.RaidEnded and child:IsA("RemoteEvent") then
			child.OnClientEvent:Connect(function(payload: any)
				if type(payload) == "table" then
					endedEvent:Fire(payload)
				end
			end)
		end
	end
	for _, child in folder:GetChildren() do
		hook(child)
	end
	folder.ChildAdded:Connect(hook)
end

return RaidApi
