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

local Theme = Ui.theme
local C = Theme.color
local URGENT_SECONDS = 30
local RESULT_SECONDS = 5

local RaidHudController = {}

local player = Players.LocalPlayer

function RaidHudController.start()
	local gui = Ui.screenGui("RaidHud", 2, player:WaitForChild("PlayerGui"))

	-- Timer pill, top-center (RaidHud.dc.html): the clock in a night pill, urgent red under 30 s.
	local timerPanel = Theme.panel(gui, "RaidTimer", UDim2.fromOffset(120, 44), UDim2.new(0.5, 0, 0, Theme.space.s2))
	timerPanel.AnchorPoint = Vector2.new(0.5, 0)
	timerPanel.Visible = false
	local clock = Theme.text(timerPanel, Theme.type.number, C.glow)
	clock.Size = UDim2.new(1, -Theme.space.s3, 1, -Theme.space.s1)
	clock.Position = UDim2.fromOffset(Theme.space.s2, 2)

	-- Carried critter / objective line, under the timer.
	local carryChip, carryLine = Theme.chip(gui, "RaidCarry", "", C.panelRaised, C.ink)
	carryChip.AnchorPoint = Vector2.new(0.5, 0)
	carryChip.Size = UDim2.fromOffset(200, 26)
	carryChip.Position = UDim2.new(0.5, 0, 0, 56)
	carryChip.Visible = false

	-- Arrow: a round chip whose caret rotates to point at the gate (top-right).
	local arrowChip = Theme.panel(gui, "GateArrow", UDim2.fromOffset(74, 86), UDim2.new(1, -12, 0, 8))
	arrowChip.AnchorPoint = Vector2.new(1, 0)
	arrowChip.Visible = false
	local arrow = Theme.text(arrowChip, 60, C.go)
	arrow.Text = "^"
	arrow.Size = UDim2.fromOffset(60, 60)
	arrow.AnchorPoint = Vector2.new(0.5, 0)
	arrow.Position = UDim2.new(0.5, 0, 0, 2)
	local dist = Theme.bodyText(arrowChip, Theme.type.label, C.go)
	dist.Size = UDim2.new(1, -8, 0, 18)
	dist.Position = UDim2.fromOffset(4, 64)

	-- Outcome card (RaidEscaped / RaidCaught): popup with a ribbon in the outcome's accent.
	local result = Theme.panel(gui, "RaidResult", UDim2.fromOffset(300, 110), UDim2.fromScale(0.5, 0.3))
	result.AnchorPoint = Vector2.new(0.5, 0.5)
	result.Visible = false
	local resultRim = result:FindFirstChildOfClass("UIStroke") :: UIStroke
	resultRim.Thickness = Theme.stroke.heavy
	local ribbon, ribbonText = Theme.chip(result, "Ribbon", "", C.go, C.onAccent)
	ribbon.AnchorPoint = Vector2.new(0.5, 0.5)
	ribbon.Position = UDim2.fromScale(0.5, 0)
	ribbon.Size = UDim2.fromOffset(150, 26)
	local resultTitle = Theme.text(result, Theme.type.title, C.ink)
	resultTitle.Size = UDim2.new(1, -16, 0, 36)
	resultTitle.Position = UDim2.fromOffset(8, 22)
	local resultSub = Theme.text(result, Theme.type.numberSm + 10, C.go)
	resultSub.Size = UDim2.new(1, -16, 0, 34)
	resultSub.Position = UDim2.fromOffset(8, 62)

	local active: { raidId: string, endsAt: number, gate: Vector3?, critters: number, isRevenge: boolean }? = nil
	local conn: RBXScriptConnection? = nil
	local resultToken = 0

	local function stop()
		active = nil
		if conn then
			conn:Disconnect()
			conn = nil
		end
		timerPanel.Visible = false
		carryChip.Visible = false
		arrowChip.Visible = false
	end

	local function tick()
		local raid = active
		if not raid then
			return
		end
		local left = raid.endsAt - workspace:GetServerTimeNow()
		clock.Text = RaidMath.clock(left)
		clock.TextColor3 = if left <= URGENT_SECONDS then C.revenge else C.glow

		local carrying = player:GetAttribute("CarryingSpecies")
		local species = if type(carrying) == "string" and carrying ~= "" then CritterCatalog.get(carrying) else nil
		carryLine.Text = if species
			then species.name
			elseif raid.isRevenge then Strings.raidRevengeGrab
			elseif raid.critters > 0 then Strings.format(Strings.raidCritters, { n = tostring(raid.critters) })
			else Strings.raidFindCritter
		arrow.TextColor3 = if species then C.go else C.inkDim

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

	RaidApi.raidStarted:Connect(
		function(raidId: string, _target: number, endsAt: number, gate: Vector3?, critters: number, isRevenge: boolean)
			stop()
			result.Visible = false
			-- endsAt is server time; tick() compares it against workspace:GetServerTimeNow().
			active = { raidId = raidId, endsAt = endsAt, gate = gate, critters = critters, isRevenge = isRevenge }
			timerPanel.Visible = true
			carryChip.Visible = true
			conn = RunService.Heartbeat:Connect(tick)
			tick()
		end
	)

	RaidApi.raidEnded:Connect(function(payload: any)
		stop()
		local escaped = payload.escaped == true
		local species = if type(payload.speciesId) == "string" then CritterCatalog.get(payload.speciesId) else nil
		local key = RaidMath.outcomeKey(payload.reason, escaped)
		-- payload.pending is optional (added by the raid agent's contract change); nil means not pending.
		local pending = not escaped and payload.reason == "Escaped" and payload.pending == true
		if pending then
			resultTitle.Text = if species
				then Strings.format(Strings.raidPendingNamed, { name = species.name })
				else Strings.raidPending
		elseif escaped then
			resultTitle.Text = if species
				then Strings.format(Strings.raidEscaped, { name = species.name })
				elseif type(payload.glow) == "number" and payload.glow > 0 then Strings.raidGlowOnly
				else Strings.raidEscapedNone
		else
			resultTitle.Text = (Strings :: any)[key]
		end
		local good = escaped or pending
		local accent = if good then C.go else C.lock
		resultTitle.TextColor3 = C.ink
		resultRim.Color = C.night900
		ribbon.BackgroundColor3 = accent
		ribbonText.Text = Theme.upper(
			if pending then Strings.raidPending elseif escaped then Strings.raidEscapedRibbon else Strings.raidCaught
		)
		resultSub.Text = if type(payload.glow) == "number" and payload.glow > 0
			then Strings.format(Strings.raidGlow, { n = tostring(payload.glow) })
			else ""
		local hasSub = resultSub.Text ~= ""
		resultSub.Visible = hasSub
		result.Size = UDim2.fromOffset(300, if hasSub then 110 else 74)
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
