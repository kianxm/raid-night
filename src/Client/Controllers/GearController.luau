--!strict
--[[
	GearController (owner: ui agent): the raid gear bar (P2.10, docs/contracts.md "Gear").
	Owned gear only, from GetGear; tapping a slot asks UseGear and the server decides. The bar
	sits bottom-right, left of the action column and clear of the thumbstick, and shows nothing
	until the player owns gear. Cooldown and charges are read from the server's answers (server
	time), never invented here. A "Gear" button opens the list with a disabled Upgrade (the
	purchase remote, UpgradeGear, is not served yet). GearUsed pushes draw placeholder effects.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net")) :: any
local GearRules = require(Shared:WaitForChild("GearRules")) :: any

local Client = script.Parent.Parent
local Hud = Client:WaitForChild("Hud")
local Raid = Client:WaitForChild("Raid")
local Strings = require(Hud:WaitForChild("Strings"))
local GearMath = require(Hud:WaitForChild("GearMath"))
local Request = require(Client:WaitForChild("Request"))
local Ui = require(Raid:WaitForChild("Ui"))
local Toast = require(Raid:WaitForChild("Toast"))
local GearFx = require(Raid:WaitForChild("GearFx"))
local RaidApi = require(Raid:WaitForChild("RaidApi"))

local COLOR = Ui.COLOR
local FETCH_GAP = 2.5 -- GetGear allows 5 per 10 s
local LEFT_CLEAR = 190 -- thumbstick
local RIGHT_CLEAR = 150 -- action column (130) + margins
local AIM_RANGE = 300

local GearController = {}

local NAME_KEYS: { [string]: string } = {
	grapple = "gearGrapple",
	smoke = "gearSmoke",
	decoy = "gearDecoy",
	speedCoil = "gearSpeedCoil",
	lockpick = "gearLockpick",
}
local ACCENT: { [string]: Color3 } = {
	grapple = COLOR.glow,
	smoke = COLOR.dim,
	decoy = COLOR.gold,
	speedCoil = COLOR.go,
	lockpick = COLOR.revenge,
}

local player = Players.LocalPlayer
local gui: ScreenGui
local bar: Frame
local reticle: Frame
local pickChip: TextLabel
local slots: { GearMath.Slot } = {}
local buttons: { [string]: { button: TextButton, shade: Frame, secs: TextLabel, badge: TextLabel } } = {}
local lastFetch = -math.huge
local pickEndsAt = 0
local refreshPanel: () -> () = function() end

local function nameOf(id: string): string
	return (Strings :: any)[NAME_KEYS[id] or ""] or id
end

local function serverNow(): number
	return workspace:GetServerTimeNow()
end

local function relayout()
	local shown = GearMath.visible(slots)
	local width = gui.AbsoluteSize.X
	local size = GearMath.slotSize(width, #shown + 1, LEFT_CLEAR, RIGHT_CLEAR)
	for _, entry in buttons do
		entry.button:Destroy()
	end
	table.clear(buttons)
	bar.Visible = #shown > 0
	for i, slot in shown do
		local b = Ui.button(bar, slot.id, nameOf(slot.id), ACCENT[slot.id] or COLOR.go, UDim2.fromOffset(size, size))
		b.LayoutOrder = i
		local title = b:FindFirstChild("Title") :: TextLabel
		title.Position = UDim2.fromOffset(2, size - 24)
		title.Size = UDim2.new(1, -4, 0, 18)
		local shade = Instance.new("Frame")
		shade.Name = "Shade"
		shade.BackgroundColor3 = COLOR.outline
		shade.BackgroundTransparency = 0.35
		shade.BorderSizePixel = 0
		shade.AnchorPoint = Vector2.new(0, 1)
		shade.Position = UDim2.fromScale(0, 1)
		shade.Size = UDim2.fromScale(1, 0)
		shade.ZIndex = 3
		Ui.round(shade, 10)
		shade.Parent = b
		local secs = Ui.label(b, Ui.DISPLAY, 22)
		secs.Size = UDim2.new(1, 0, 0, 26)
		secs.Position = UDim2.fromOffset(0, 6)
		secs.ZIndex = 4
		secs.Text = ""
		local badge = Ui.label(b, Ui.DISPLAY, 14, COLOR.outline)
		badge.Size = UDim2.fromOffset(24, 18)
		badge.Position = UDim2.new(1, -26, 0, 2)
		badge.ZIndex = 4
		badge.Text = ""
		buttons[slot.id] = { button = b, shade = shade, secs = secs, badge = badge }
		b.Activated:Connect(function()
			GearController.use(slot.id)
		end)
	end
	local info = bar:FindFirstChild("Info") :: TextButton
	info.Size = UDim2.fromOffset(size, size)
	info.LayoutOrder = 99
	info.Visible = #shown > 0
end

local function fetch(force: boolean)
	if not force and os.clock() - lastFetch < FETCH_GAP then
		return
	end
	lastFetch = os.clock()
	Request.invoke(Net.Requests.GetGear, function(ok, result)
		if ok and type(result) == "table" then
			slots = result
			relayout()
			refreshPanel()
		end
	end)
end

-- The ground point the camera centre looks at: the grapple's aim. The server validates it.
local function aimPoint(): Vector3?
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end
	local size = camera.ViewportSize
	local ray = camera:ViewportPointToRay(size.X / 2, size.Y / 2)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character }
	local hit = workspace:Raycast(ray.Origin, ray.Direction * AIM_RANGE, params)
	return if hit then hit.Position else nil
end

function GearController.use(id: string)
	local slot
	for _, s in slots do
		if s.id == id then
			slot = s
		end
	end
	if not slot then
		return
	end
	local state = GearMath.state(slot, serverNow())
	if state ~= "Ready" then
		Toast.show(if state == "Spent" then Strings.gearNoCharges else Strings.gearCooldown)
		return
	end
	local target: Vector3? = nil
	if id == "grapple" then
		target = aimPoint()
		if not target then
			Toast.show(Strings.gearNoAim)
			return
		end
	end
	Request.invoke(Net.Requests.UseGear, function(ok, result)
		if not (ok and type(result) == "table") then
			Toast.show(Strings.gearRefused)
			return
		end
		if result.ok == true then
			if type(result.readyAt) == "number" then
				slot.readyAt = result.readyAt
			end
			slot.charges = result.charges
		else
			if type(result.readyAt) == "number" then
				slot.readyAt = result.readyAt
			end
			Toast.show((Strings :: any)[GearMath.reasonKey(result.reason)])
			fetch(false) -- our view was out of date
		end
	end, id, target)
end

local function onGearUsed(event: any)
	GearFx.handle(event)
	if type(event) ~= "table" or event.userId ~= player.UserId or event.gearId ~= "lockpick" then
		return
	end
	if event.state == "Used" and type(event.endsAt) == "number" then
		pickEndsAt = event.endsAt
	elseif event.state == "Done" then
		pickEndsAt = 0
		Toast.show(Strings.gearPickDone)
	elseif event.state == "Interrupted" then
		pickEndsAt = 0
		Toast.show(Strings.gearPickBroke)
	end
end

local function buildPanel()
	local frame, body, closeButton = Ui.modal(gui, "GearPanel", Strings.gearTitle, COLOR.glow)
	Ui.setButton(closeButton, Strings.close, COLOR.glow, true)
	closeButton.Activated:Connect(function()
		frame.Visible = false
	end)
	local info = Ui.button(bar, "Info", Strings.gearButton, COLOR.panel, UDim2.fromOffset(48, 48))
	info.Visible = false
	info.Activated:Connect(function()
		fetch(true)
		refreshPanel()
		frame.Visible = true
		Ui.pop(frame)
	end)
	refreshPanel = function()
		for _, child in body:GetChildren() do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end
		local shown = GearMath.visible(slots)
		for i, slot in shown do
			local card = Ui.card(body, slot.id, i, 84)
			local name = Ui.label(card, Ui.DISPLAY, 22, ACCENT[slot.id])
			name.Text = `{nameOf(slot.id)}  {Strings.format(Strings.gearLevel, { n = tostring(slot.level) })}`
			name.Size = UDim2.new(0.55, 0, 0, 28)
			name.Position = UDim2.fromOffset(8, 6)
			name.TextXAlignment = Enum.TextXAlignment.Left
			name.ZIndex = 10
			local cd = Ui.label(card, Ui.BODY, 15, COLOR.dim)
			local seconds = GearRules.cooldownSeconds(slot.id, slot.level)
			cd.Text = Strings.format(Strings.gearCooldownInfo, { s = tostring(math.ceil(seconds)) })
			cd.Size = UDim2.new(0.55, 0, 0, 22)
			cd.Position = UDim2.fromOffset(8, 44)
			cd.TextXAlignment = Enum.TextXAlignment.Left
			cd.ZIndex = 10
			-- Disabled until economy serves UpgradeGear (P2.8c). No price to show yet.
			local upgrade = Ui.button(card, "Upgrade", Strings.gearUpgrade, COLOR.disabled, UDim2.new(0.38, 0, 0, 52))
			upgrade.AnchorPoint = Vector2.new(1, 0.5)
			upgrade.Position = UDim2.new(1, -8, 0.5, -6)
			upgrade.Active = false
			upgrade.ZIndex = 10
			local soon = Ui.label(card, Ui.BODY, 12, COLOR.dim)
			soon.Text = Strings.gearComingSoon
			soon.Size = UDim2.new(0.38, 0, 0, 14)
			soon.AnchorPoint = Vector2.new(1, 1)
			soon.Position = UDim2.new(1, -8, 1, -4)
			soon.ZIndex = 10
		end
		if #shown == 0 then
			local card = Ui.card(body, "None", 1, 56)
			local none = Ui.label(card, Ui.DISPLAY, 20, COLOR.dim)
			none.Text = Strings.gearNone
			none.ZIndex = 10
		end
	end
end

function GearController.start()
	gui = Ui.screenGui("Gear", 2, player:WaitForChild("PlayerGui"))

	bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.BackgroundTransparency = 1
	bar.AnchorPoint = Vector2.new(1, 1)
	bar.Position = UDim2.new(1, -RIGHT_CLEAR, 1, -12)
	bar.Size = UDim2.fromOffset(0, 0)
	bar.AutomaticSize = Enum.AutomaticSize.XY
	bar.Visible = false
	bar.Parent = gui
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.HorizontalAlignment = Enum.HorizontalAlignment.Right
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 6)
	list.Parent = bar

	reticle = Instance.new("Frame")
	reticle.Name = "Reticle"
	reticle.AnchorPoint = Vector2.new(0.5, 0.5)
	reticle.Position = UDim2.fromScale(0.5, 0.5)
	reticle.Size = UDim2.fromOffset(10, 10)
	reticle.BackgroundColor3 = COLOR.glow
	reticle.Visible = false
	Ui.round(reticle, 5)
	Ui.outline(reticle, 2)
	reticle.Parent = gui

	pickChip = Ui.label(gui, Ui.DISPLAY, 22, COLOR.revenge)
	pickChip.Name = "PickChip"
	pickChip.AnchorPoint = Vector2.new(0.5, 1)
	pickChip.Position = UDim2.new(0.5, 0, 1, -80)
	pickChip.Size = UDim2.fromOffset(220, 30)
	pickChip.Visible = false

	buildPanel()
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayout)

	-- Cooldown shade, seconds and charges follow the server clock; ~10 updates a second.
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator < 0.1 then
			return
		end
		accumulator = 0
		local t = serverNow()
		for _, slot in GearMath.visible(slots) do
			local entry = buttons[slot.id]
			if entry then
				local left = GearMath.remaining(slot.readyAt, t)
				local total = math.max(1, GearRules.cooldownSeconds(slot.id, slot.level))
				local state = GearMath.state(slot, t)
				entry.shade.Size = UDim2.fromScale(1, if state == "Spent" then 1 else math.clamp(left / total, 0, 1))
				entry.secs.Text = if state == "Cooling" then GearMath.secondsText(left) else ""
				entry.badge.Text = if slot.charges then `x{slot.charges}` else ""
				entry.badge.BackgroundTransparency = if slot.charges then 0 else 1
				entry.badge.BackgroundColor3 = COLOR.gold
			end
		end
		local grapple = buttons.grapple
		reticle.Visible = grapple ~= nil and grapple.secs.Text == ""
		pickChip.Visible = pickEndsAt > t
		if pickChip.Visible then
			pickChip.Text = `{Strings.gearPicking} {GearMath.secondsText(pickEndsAt - t)}`
		end
	end)

	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("Remotes")
		local push = remotes:WaitForChild(Net.Pushes.GearUsed, 30)
		if push and push:IsA("RemoteEvent") then
			push.OnClientEvent:Connect(onGearUsed)
		end
	end)

	-- Owned gear and charges change with raids; GetGear is cheap and limited, so only these moments.
	RaidApi.raidStarted:Connect(function()
		fetch(false)
	end)
	RaidApi.raidEnded:Connect(function()
		GearFx.clear()
		fetch(false)
	end)
	task.spawn(function()
		local attempt = 0
		while #slots == 0 and attempt < 4 do
			fetch(true)
			attempt += 1
			task.wait(5 * attempt)
		end
	end)
end

return GearController
