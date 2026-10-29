--!strict
--[[
	DenController (owner: ui agent)

	Holds the latest server DenState (pushed via DenChanged, fetched once with GetDenState) for
	other controllers, and hides the greybox station ProximityPrompts in dens you do not own.
	Hiding is cosmetic; the server already enforces ownership.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Net")) :: any

local DenController = {}

local state: any = nil
local receivedAt = 0 -- os.clock() when `state` arrived
local listeners: { (any) -> () } = {}

function DenController.getState(): (any, number)
	return state, receivedAt
end

-- Calls `fn` on every new state (and immediately if we already have one).
function DenController.onChanged(fn: (any) -> ())
	table.insert(listeners, fn)
	if state then
		fn(state)
	end
end

local function setState(new: any)
	state = new
	receivedAt = os.clock()
	for _, fn in listeners do
		task.spawn(fn, new)
	end
end

local function refreshPrompts(denModel: Instance)
	local mine = denModel:GetAttribute("OwnerUserId") == Players.LocalPlayer.UserId
	for _, d in denModel:GetDescendants() do
		if d:IsA("ProximityPrompt") and d:FindFirstAncestor("EconomyStation") then
			d.Enabled = mine
		end
	end
end

local function watchDen(denModel: Instance)
	refreshPrompts(denModel)
	denModel:GetAttributeChangedSignal("OwnerUserId"):Connect(function()
		refreshPrompts(denModel)
	end)
	-- The station is built after the den model exists.
	denModel.DescendantAdded:Connect(function(d)
		if d:IsA("ProximityPrompt") then
			task.defer(refreshPrompts, denModel)
		end
	end)
end

function DenController.start()
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local pushed = remotes:WaitForChild(Net.Pushes.DenChanged) :: RemoteEvent
	pushed.OnClientEvent:Connect(setState)
	task.spawn(function()
		local getState = remotes:WaitForChild(Net.Requests.GetDenState) :: RemoteFunction
		local ok, result = pcall(function()
			return getState:InvokeServer()
		end)
		if ok and result and not state then
			setState(result)
		end
	end)

	task.spawn(function()
		local world = workspace:WaitForChild("World")
		local dens = world:WaitForChild("Dens")
		for _, den in dens:GetChildren() do
			watchDen(den)
		end
		dens.ChildAdded:Connect(watchDen)
	end)
end

return DenController
