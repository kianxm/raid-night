--!strict
--[[
	RaidHudController (owner: ui agent)

	In-raid HUD, shown from RaidApi.raidStarted until the raid ends: a 3-minute countdown (from
	the server's endsAt, read against workspace:GetServerTimeNow()), what you are carrying, and
	an arrow to the escape gate. When the raid ends it shows the outcome card.

	Layout (landscape phone): top-right under the Roblox top bar, clear of the Glow panel
	(top-left), the carried pill and toast (top-center) and the action column (bottom-right).
	Display only: the server owns the timer, the gate and the outcome.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CritterCatalog = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CritterCatalog")) :: any

local Hud = script.Parent.Parent:WaitForChild("Hud")
local Raid = script.Parent.Parent:WaitForChild("Raid")
local Strings = require(Hud:WaitForChild("Strings"))
local RaidApi = require(Raid:WaitForChild("RaidApi"))
local RaidMath = require(Raid:WaitForChild("RaidMath"))
local Ui = require(Raid:WaitForChild("Ui"))

local COLOR = Ui.COLOR
local URGENT_SECONDS = 30
local RESULT_SECONDS = 5

local RaidHudController = {}

local player = Players.LocalPlayer

function RaidHudController.start()
	local gui = Ui.screenGui("RaidHud", 2, player:WaitForChild("PlayerGui"))

	local timerPanel = Ui.panel(gui, "RaidTimer", UDim2.fromOffset(150, 62), UDim2.new(1, -12, 0, 8))
	timerPanel.AnchorPoint = Vector2.new(1, 0)
	timerPanel.Visible = false
	local clock = Ui.label(timerPanel, Ui.DISPLAY, 34, COLOR.glow)
	clock.Size = UDim2.new(1, -12, 0, 38)
	clock.Position = UDim2.fromOffset(6, 2)
	local carryLine = Ui.label(timerPanel, Ui.BODY, 14, COLOR.dim)
	carryLine.Size = UDim2.new(1, -12, 0, 18)
	carryLine.Position = UDim2.fromOffset(6, 40)

	-- Arrow: a round chip whose caret rotates to point at the gate.
	local arrowChip = Ui.panel(gui, "GateArrow", UDim2.fromOffset(74, 86), UDim2.new(1, -12, 0, 78))
	arrowChip.AnchorPoint = Vector2.new(1, 0)
	arrowChip.Visible = false
	local arrow = Ui.label(arrowChip, Ui.DISPLAY, 60, COLOR.go)
	arrow.Text = "^"
	arrow.Size = UDim2.fromOffset(60, 60)
	arrow.AnchorPoint = Vector2.new(0.5, 0)
	arrow.Position = UDim2.new(0.5, 0, 0, 2)
	local dist = Ui.label(arrowChip, Ui.BODY, 14)
	dist.Size = UDim2.new(1, -8, 0, 18)
	dist.Position = UDim2.fromOffset(4, 64)

	local result = Ui.panel(gui, "RaidResult", UDim2.fromOffset(280, 76), UDim2.fromScale(0.5, 0.3))
	result.AnchorPoint = Vector2.new(0.5, 0.5)
	result.Visible = false
	local resultTitle = Ui.label(result, Ui.DISPLAY, 28)
	resultTitle.Size = UDim2.new(1, -16, 0, 40)
	resultTitle.Position = UDim2.fromOffset(8, 6)
	local resultSub = Ui.label(result, Ui.DISPLAY, 20, COLOR.glow)
	resultSub.Size = UDim2.new(1, -16, 0, 24)
	resultSub.Position = UDim2.fromOffset(8, 46)

	local active: { raidId: string, endsAt: number, gate: Vector3? }? = nil
	local conn: RBXScriptConnection? = nil
	local resultToken = 0

	local function stop()
		active = nil
		if conn then
			conn:Disconnect()
			conn = nil
		end
		timerPanel.Visible = false
		arrowChip.Visible = false
	end

	local function tick()
		local raid = active
		if not raid then
			return
		end
		local left = raid.endsAt - workspace:GetServerTimeNow()
		clock.Text = RaidMath.clock(left)
		clock.TextColor3 = if left <= URGENT_SECONDS then COLOR.revenge else COLOR.glow

		local carrying = player:GetAttribute("CarryingSpecies")
		local species = if type(carrying) == "string" and carrying ~= "" then CritterCatalog.get(carrying) else nil
		carryLine.Text = if species then species.name else Strings.raidFindCritter
		arrow.TextColor3 = if species then COLOR.go else COLOR.dim

		local gate = raid.gate
		local camera = workspace.CurrentCamera
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if gate and camera and root and root:IsA("BasePart") then
			arrowChip.Visible = true
			local look = camera.CFrame.LookVector
			arrow.Rotation = RaidMath.arrowDegrees(look, root.Position, gate)
			local studs = (Vector3.new(gate.X, 0, gate.Z) - Vector3.new(root.Position.X, 0, root.Position.Z)).Magnitude
			dist.Text = Strings.format(Strings.gate, { dist = tostring(math.floor(studs)) })
		else
			arrowChip.Visible = false
		end

		-- Mock mode has no server to end the raid; the real server pushes RaidEnded.
		if left <= 0 and RaidApi.USE_MOCK then
			local id = raid.raidId
			stop()
			RaidApi.mockEnd(id, species ~= nil)
		end
	end

	RaidApi.raidStarted:Connect(function(raidId: string, _target: number, endsAt: number, gate: Vector3?)
		stop()
		result.Visible = false
		active = { raidId = raidId, endsAt = endsAt, gate = gate }
		timerPanel.Visible = true
		conn = RunService.Heartbeat:Connect(tick)
		tick()
	end)

	RaidApi.raidEnded:Connect(function(payload: any)
		stop()
		local escaped = payload.escaped == true
		local species = if type(payload.speciesId) == "string" then CritterCatalog.get(payload.speciesId) else nil
		if escaped then
			resultTitle.Text = if species
				then Strings.format(Strings.raidEscaped, { name = species.name })
				else Strings.raidEscapedNone
			resultTitle.TextColor3 = COLOR.go
		else
			resultTitle.Text = Strings.raidCaught
			resultTitle.TextColor3 = COLOR.revenge
		end
		resultSub.Text = if payload.glow > 0
			then Strings.format(Strings.raidGlow, { n = tostring(payload.glow) })
			else ""
		result.Visible = true
		resultToken += 1
		local token = resultToken
		task.delay(RESULT_SECONDS, function()
			if token == resultToken then
				result.Visible = false
			end
		end)
	end)
end

return RaidHudController
