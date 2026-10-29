--!strict
--[[
	OnboardingController (owner: ui agent): the first-5-minutes hints (Appendix C).
	One short hint at a time under the top toast, from GetOnboarding / OnboardingChanged. The
	server decides every step; this only shows the next one. The steal step adds an arrow to
	the tutorial den (player attribute TutorialDenPosition), the last step ("raidLogTip") is the
	only one the client acknowledges (AckOnboarding). Players with no onboarding see nothing.
	Also hides tutorial StealPrompts that belong to another player.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Client = script.Parent.Parent
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net")) :: any
local Ui = require(Client:WaitForChild("Raid"):WaitForChild("Ui"))
local Strings = require(Client:WaitForChild("Hud"):WaitForChild("Strings")) :: any
local OnboardingMath = require(Client:WaitForChild("Hud"):WaitForChild("OnboardingMath"))
local SettingsState = require(Client:WaitForChild("Hud"):WaitForChild("SettingsState"))
local Request = require(Client:WaitForChild("Request"))

local TUTORIAL_RAID_ID = "tutorial"
local CELEBRATE_SECONDS = 4
local LOAD_TRIES = 6

local OnboardingController = {}

local localPlayer = Players.LocalPlayer
local status: any = nil
local celebrateUntil = 0
local banner: Frame
local text: TextLabel
local gotIt: TextButton
local arrow: TextLabel
local current: string? = nil -- text/arrow state last rendered, to skip no-op updates

local function render()
	local hint = OnboardingMath.hintFor(status)
	local celebrating = os.clock() < celebrateUntil
	if not hint and not celebrating then
		banner.Visible = false
		arrow.Visible = false
		current = nil
		return
	end
	local message = if celebrating
		then Strings.obStealDone
		else Strings[(hint :: OnboardingMath.Hint).stringKey] :: string
	local ack = hint ~= nil and hint.ack and not celebrating
	local key = message .. (if ack then "#ack" else "")
	text.Text = message
	text.Size = if ack then UDim2.new(1, -112, 1, -8) else UDim2.new(1, -16, 1, -8)
	gotIt.Visible = ack
	if key ~= current then
		current = key
		banner.Visible = true
		Ui.pop(banner)
	end
	banner.Visible = true
end

local function setStatus(next: any)
	if type(next) ~= "table" then
		return
	end
	status = next
	render()
end

-- The last OnboardingStatus (nil before the first answer), for price labels.
function OnboardingController.getStatus(): any
	return status
end

local function tutorialDenPosition(): Vector3?
	local pos = localPlayer:GetAttribute("TutorialDenPosition")
	return if typeof(pos) == "Vector3" then pos else nil
end

-- Points the arrow at the tutorial den while the steal step is on (and not mid-celebration).
local function updateArrow()
	local hint = OnboardingMath.hintFor(status)
	local pos = tutorialDenPosition()
	local camera = workspace.CurrentCamera
	local root = localPlayer.Character and localPlayer.Character:FindFirstChild("HumanoidRootPart")
	if
		not (hint and hint.arrow and pos and camera and root and root:IsA("BasePart"))
		or os.clock() < celebrateUntil
	then
		arrow.Visible = false
		return
	end
	local offset = pos - root.Position
	local look = camera.CFrame.LookVector
	local degrees = OnboardingMath.arrowDegrees(look.X, look.Z, offset.X, offset.Z)
	local studs = OnboardingMath.roundedDistance(offset.X, offset.Z)
	arrow.Visible = true
	arrow.Rotation = degrees
	local distance = arrow:FindFirstChild("Distance") :: TextLabel?
	if distance then
		distance.Text = Strings.format(Strings.obDistance, { n = tostring(studs) })
	end
end

local function build()
	local gui = Ui.screenGui("Onboarding", 8, localPlayer:WaitForChild("PlayerGui"))
	banner = Ui.panel(gui, "Hint", UDim2.new(0.9, 0, 0, 60), UDim2.new(0.5, 0, 0, 60))
	banner.AnchorPoint = Vector2.new(0.5, 0)
	banner.Visible = false
	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(420, 60)
	limit.Parent = banner
	text = Ui.label(banner, Ui.DISPLAY, 20, Ui.COLOR.gold)
	text.Position = UDim2.fromOffset(8, 4)
	text.TextWrapped = true
	gotIt = Ui.button(banner, "GotIt", Strings.obGotIt, Ui.COLOR.go, UDim2.fromOffset(96, 44))
	gotIt.AnchorPoint = Vector2.new(1, 0.5)
	gotIt.Position = UDim2.new(1, -8, 0.5, 0)
	gotIt.Visible = false

	-- The arrow sits above the bottom thumb area, centered, so it never covers the thumbstick.
	arrow = Ui.label(gui, Ui.DISPLAY, 56, Ui.COLOR.gold)
	arrow.Name = "Arrow"
	arrow.Text = "^"
	arrow.AnchorPoint = Vector2.new(0.5, 0.5)
	arrow.Size = UDim2.fromOffset(64, 64)
	arrow.Position = UDim2.fromScale(0.5, 0.6)
	arrow.Visible = false
	local distance = Ui.label(arrow, Ui.BODY, 16, Ui.COLOR.text)
	distance.Name = "Distance"
	distance.Size = UDim2.fromOffset(80, 20)
	distance.AnchorPoint = Vector2.new(0.5, 0)
	distance.Position = UDim2.fromScale(0.5, 1)
	distance.Rotation = 0

	gotIt.Activated:Connect(function()
		local hint = OnboardingMath.hintFor(status)
		if not hint or not hint.ack then
			return
		end
		Request.invoke(Net.Requests.AckOnboarding, function(ok, result)
			if ok and result == true then
				-- The server pushes OnboardingChanged too; hide now so a slow push never leaves it up.
				setStatus({ step = 6, complete = true })
			end
		end, hint.stepId)
	end)
end

-- Tutorial dens are per player; only the owner may see and use the prompt. The server already
-- refuses anyone else; this just removes the prompt from view.
local function hideForeignPrompt(prompt: ProximityPrompt)
	local function apply()
		local model = prompt:FindFirstAncestorWhichIsA("Model")
		local owner = if model then model:GetAttribute("OwnerUserId") else nil
		if type(owner) == "number" and owner ~= localPlayer.UserId and prompt.Enabled then
			prompt.Enabled = false
		end
	end
	apply()
	prompt:GetPropertyChangedSignal("Enabled"):Connect(apply)
end

local function watchTutorialDens(folder: Instance)
	for _, d in folder:GetDescendants() do
		if d:IsA("ProximityPrompt") and d.Name == "StealPrompt" then
			hideForeignPrompt(d)
		end
	end
	folder.DescendantAdded:Connect(function(d)
		if d:IsA("ProximityPrompt") and d.Name == "StealPrompt" then
			task.defer(hideForeignPrompt, d)
		end
	end)
end

function OnboardingController.start()
	build()
	local remotes = ReplicatedStorage:WaitForChild("Remotes")

	local changed = remotes:WaitForChild(Net.Pushes.OnboardingChanged) :: RemoteEvent
	changed.OnClientEvent:Connect(setStatus)

	local ended = remotes:WaitForChild(Net.Pushes.RaidEnded) :: RemoteEvent
	ended.OnClientEvent:Connect(function(payload: any)
		if type(payload) == "table" and payload.raidId == TUTORIAL_RAID_ID and payload.escaped == true then
			celebrateUntil = os.clock() + CELEBRATE_SECONDS
			render()
			task.delay(CELEBRATE_SECONDS, render)
		end
	end)

	task.spawn(function()
		for attempt = 1, LOAD_TRIES do
			local done = false
			Request.invoke(Net.Requests.GetOnboarding, function(ok, result)
				if ok and type(result) == "table" then
					if status == nil then -- a push that already arrived is newer
						setStatus(result)
					end
					done = true
				end
			end)
			-- Request.invoke answers on its own thread; wait for it (the server waits up to 20 s).
			local waited = 0
			while not done and waited < 25 and Request.isBusy(Net.Requests.GetOnboarding) do
				task.wait(0.25)
				waited += 0.25
			end
			if done or status ~= nil then
				return
			end
			task.wait(SettingsState.retryDelay(attempt))
		end
	end)

	RunService.RenderStepped:Connect(updateArrow)

	task.spawn(function()
		local dens = workspace:WaitForChild("TutorialDens", 60)
		if dens then
			watchTutorialDens(dens)
		end
	end)
end

return OnboardingController
