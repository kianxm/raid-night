--!strict
--[[
	CritterIdleController (owner: ui agent): the placeholder idle for den critters (P2.4 #124).
	Pad critters are server models (Critters/Critter, attributes CritterUid and Tier). Their bob
	and sway are drawn here, on the client only, from the tested CritterVisuals.idleOffset, so
	the server never replicates motion. Off entirely under Reduced motion. A real model that
	brings its own animation (idleFor says bob 0 and sway 0) is left alone. Only critters near
	the camera are moved. `critterIdle` sound cues play at most once per critter per spawn; the
	cue id is empty until audio exists, so nothing plays yet.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CritterVisuals = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CritterVisuals")) :: any
local Client = script.Parent.Parent
local SettingsState = require(Client:WaitForChild("Hud"):WaitForChild("SettingsState"))
local Audio = require(Client:WaitForChild("Sound"):WaitForChild("Audio"))

local NEAR = 70 -- studs from the camera
local MOVED = 0.05 -- studs: the server (or a carrier) moved it, so re-read its base

local CritterIdleController = {}

type Tracked = {
	model: Model,
	idle: any,
	phase: number,
	base: CFrame,
	applied: CFrame,
	hasModelAnim: boolean,
}
local tracked: { [Model]: Tracked } = {}
local cueDone: { [Model]: boolean } = {}

local function consider(model: Model)
	if tracked[model] or model.Name ~= "Critter" or not model.Parent or model.Parent.Name ~= "Critters" then
		return
	end
	local uid, tier = model:GetAttribute("CritterUid"), model:GetAttribute("Tier")
	if type(uid) ~= "string" or type(tier) ~= "string" then
		return
	end
	local hasAnim = model:FindFirstChildWhichIsA("Animator", true) ~= nil
	local ok, idle = pcall(CritterVisuals.idleFor, tier, hasAnim)
	if not ok or (idle.bobStuds == 0 and idle.swayDegrees == 0) then
		return
	end
	local pivot = model:GetPivot()
	tracked[model] = {
		model = model,
		idle = idle,
		phase = CritterVisuals.phaseFor(uid),
		base = pivot,
		applied = pivot,
		hasModelAnim = hasAnim,
	}
end

local function forget(model: Instance)
	if model:IsA("Model") and tracked[model] then
		tracked[model] = nil
		cueDone[model] = nil
	end
end

local function rest(entry: Tracked)
	if entry.model:GetPivot() ~= entry.base then
		entry.model:PivotTo(entry.base)
		entry.applied = entry.base
	end
end

function CritterIdleController.start()
	for _, d in workspace:GetDescendants() do
		if d:IsA("Model") then
			consider(d)
		end
	end
	workspace.DescendantAdded:Connect(function(d)
		if d:IsA("Model") and d.Name == "Critter" then
			-- Attributes and parenting can land a frame apart; look again next frame.
			task.defer(consider, d)
		end
	end)
	workspace.DescendantRemoving:Connect(forget)

	RunService.RenderStepped:Connect(function()
		local reduced = SettingsState.get().reducedMotion
		local camera = workspace.CurrentCamera
		local t = os.clock()
		for model, entry in tracked do
			if not model:IsDescendantOf(workspace) then
				tracked[model] = nil
			elseif reduced then
				-- Back to the resting pose once, then leave the model alone.
				if entry.applied ~= entry.base and model:GetPivot() == entry.applied then
					rest(entry)
				end
			else
				local current = model:GetPivot()
				if (current.Position - entry.applied.Position).Magnitude > MOVED then
					entry.base = current -- the server moved it; this is the new rest pose
				end
				local near = camera ~= nil and (entry.base.Position - camera.CFrame.Position).Magnitude <= NEAR
				if near then
					local lift, yaw = CritterVisuals.idleOffset(t, entry.idle, entry.phase, false)
					entry.applied = entry.base * CFrame.Angles(0, yaw, 0) + Vector3.new(0, lift, 0)
					model:PivotTo(entry.applied)
					if not cueDone[model] then
						cueDone[model] = true
						Audio.play("critterIdle") -- silent while the cue id is empty
					end
				elseif entry.applied ~= entry.base then
					rest(entry)
				end
			end
		end
	end)
end

return CritterIdleController
