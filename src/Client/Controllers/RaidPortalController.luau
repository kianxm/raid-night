--!strict
--[[
	RaidPortalController (owner: ui agent)

	GetRaidTargets is asked only when the portal opens or the player taps Refresh (each call
	counts as a portal open in analytics): never on a timer or to redraw an open portal.

	A "Raid" button (left edge, clear of the thumbstick and the right action column) opens the
	Raid Portal: up to 3 targets, revenge targets on top and marked. Tapping Raid / Revenge
	requests StartRaid via RaidApi; the server decides if it happens. Display only.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local Hud = script.Parent.Parent:WaitForChild("Hud")
local Raid = script.Parent.Parent:WaitForChild("Raid")
local Strings = require(Hud:WaitForChild("Strings"))
local HudMath = require(Hud:WaitForChild("HudMath"))
local RaidApi = require(Raid:WaitForChild("RaidApi"))
local RaidMath = require(Raid:WaitForChild("RaidMath"))
local Toast = require(Raid:WaitForChild("Toast"))
local Ui = require(Raid:WaitForChild("Ui"))
local HudLayout = require(Hud:WaitForChild("HudLayout"))
local RevengeController = require(script.Parent:WaitForChild("RevengeController")) :: any

local Theme = Ui.theme
local C = Theme.color

local RaidPortalController = {}

local portal: Frame
local list: Frame
local message: TextLabel
local openButton: TextButton
local busy = false
local inRaid = false
local REFRESH_GAP = 4 -- seconds between explicit refreshes (GetRaidTargets: 3 per 10 s)
local lastRefresh = -math.huge

local function close()
	portal.Visible = false
end

local function setMessage(text: string)
	message.Text = text
	message.Visible = text ~= ""
end

local function tryRaid(target: any)
	if busy then
		return
	end
	setMessage("")
	local revengeId = if target.isRevenge then target.revengeRaidId else nil
	if revengeId then
		-- Revenge rows go through the shared flow (join their server, or the async revenge raid).
		close()
		RevengeController.begin(target.userId, revengeId, target.raiderOnline)
		return
	end
	busy = true
	task.spawn(function()
		local start = RaidApi.startRaid(target.userId, nil)
		busy = false
		if start then
			close()
		else
			Toast.show(Strings.portalRefused)
		end
	end)
end

local function addRow(target: any, order: number)
	local isRevenge = target.isRevenge == true
	local accent = if isRevenge then C.revenge else C.go
	local card = Instance.new("Frame")
	card.Name = "Target" .. order
	card.LayoutOrder = order
	card.Size = UDim2.new(1 / 3, -Theme.space.s2, 1, 0)
	card.BackgroundColor3 = C.panelRaised
	card.BorderSizePixel = 0
	Theme.corner(card, Theme.radius.lg)
	Theme.outline(
		card,
		if isRevenge then Theme.stroke.heavy else Theme.stroke.normal,
		if isRevenge then C.revenge else nil
	)
	card.Parent = list

	local avatar = Theme.orb(card, 36)
	avatar.BackgroundColor3 = C.panelSunken
	avatar.Position = UDim2.fromOffset(Theme.space.s2, Theme.space.s2)
	local initials = Theme.text(avatar, Theme.type.label, C.glow)
	initials.Text = string.upper(string.sub(tostring(target.displayName), 1, 2))

	local name = Theme.text(card, Theme.type.body, C.ink)
	name.Text = target.displayName
	name.Size = UDim2.new(1, -56, 0, 22)
	name.Position = UDim2.fromOffset(52, Theme.space.s2)
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.TextTruncate = Enum.TextTruncate.AtEnd

	local power = Theme.bodyText(card, Theme.type.label, C.inkDim)
	power.Text = Strings.format(Strings.power, { n = HudMath.abbreviate(target.power) })
	power.Size = UDim2.new(1, -56, 0, 16)
	power.Position = UDim2.fromOffset(52, 30)
	power.TextXAlignment = Enum.TextXAlignment.Left

	-- Tier chip in the top tier's color (the loot hint; never an exact Glow number).
	local tierColor = if target.topTier then C.tier[target.topTier] else nil
	local chip = Theme.chip(
		card,
		"Hint",
		(Strings :: any)[RaidMath.hintKey(target.topTier)],
		tierColor or C.panelSunken,
		C.onAccent
	)
	chip.Size = UDim2.new(1, -Theme.space.s4, 0, 24)
	chip.Position = UDim2.fromOffset(Theme.space.s2, 56)
	if tierColor == nil then
		local hintText = chip:FindFirstChild("Text") :: TextLabel
		hintText.TextColor3 = C.inkDim
	end

	if isRevenge then
		local tag = Theme.chip(card, "RevengeTag", Strings.revengeTag, C.revenge, C.onAccent)
		tag.AnchorPoint = Vector2.new(1, 0)
		tag.Size = UDim2.fromOffset(72, 20)
		tag.Position = UDim2.new(1, -Theme.space.s2, 0, Theme.space.s2 + 22)
	end

	local go = Theme.button(
		card,
		"Go",
		if isRevenge then Strings.revenge else Strings.raid,
		accent,
		UDim2.new(1, -Theme.space.s4, 0, Theme.size.tapMin)
	)
	go.AnchorPoint = Vector2.new(0.5, 1)
	go.Position = UDim2.new(0.5, 0, 1, -Theme.space.s2)
	go.Activated:Connect(function()
		tryRaid(target)
	end)
end

local function refresh(fresh: boolean?)
	for _, child in list:GetChildren() do
		if child:IsA("Frame") or child:IsA("TextLabel") then
			child:Destroy()
		end
	end
	setMessage("")
	task.spawn(function()
		local targets = RaidApi.getTargets(fresh)
		-- Revenge rows first, then the order the server gave. Max 3 shown.
		table.sort(targets, function(a: any, b: any)
			return a.isRevenge and not b.isRevenge
		end)
		if #targets == 0 then
			setMessage(Strings.portalEmpty)
		end
		for i = 1, math.min(3, #targets) do
			addRow(targets[i], i)
		end
	end)
end

local function open()
	if inRaid then
		return
	end
	if portal.Visible then
		return -- already open: its list is current until the player asks again
	end
	portal.Visible = true
	lastRefresh = os.clock()
	refresh(false)
end

function RaidPortalController.open()
	open()
end

function RaidPortalController.start()
	local gui = Ui.screenGui("RaidPortal", 3, Players.LocalPlayer:WaitForChild("PlayerGui"))
	local desktop = HudLayout.mode(UserInputService.TouchEnabled, UserInputService.KeyboardEnabled) == "desktop"

	-- Left edge, vertically centered: out of the thumbstick zone (bottom-left), the Glow panel
	-- (top-left) and the den chip. On PC the hotbar's slot 3 opens the portal, so no button.
	openButton = Theme.button(gui, "OpenPortal", Strings.raid, C.go, UDim2.fromOffset(84, 52))
	openButton.Position = UDim2.new(0, 10, 0.5, -64)
	openButton.Visible = not desktop

	portal = Theme.panel(gui, "Portal", UDim2.fromScale(0.92, 0.92), UDim2.fromScale(0.5, 0.5))
	portal.AnchorPoint = Vector2.new(0.5, 0.5)
	portal.Visible = false
	local rim = portal:FindFirstChildOfClass("UIStroke")
	if rim then
		rim.Thickness = Theme.stroke.heavy
	end
	local cap = Instance.new("UISizeConstraint")
	cap.MaxSize = Vector2.new(700, 340)
	cap.Parent = portal

	local ribbon = Theme.chip(portal, "Ribbon", Theme.upper(Strings.portalRibbon), C.glow, C.onAccent)
	ribbon.AnchorPoint = Vector2.new(0.5, 0.5)
	ribbon.Position = UDim2.fromScale(0.5, 0)
	ribbon.Size = UDim2.fromOffset(160, 26)

	local title = Theme.text(portal, Theme.type.title, C.ink)
	title.Text = Strings.portalTitle
	title.Size = UDim2.new(1, -176, 0, 32)
	title.Position = UDim2.fromOffset(Theme.space.s3, 18)
	title.TextXAlignment = Enum.TextXAlignment.Left

	local sub = Theme.bodyText(portal, Theme.type.label, C.inkDim)
	sub.Text = Strings.portalSub
	sub.Size = UDim2.new(1, -176, 0, 18)
	sub.Position = UDim2.fromOffset(Theme.space.s3, 50)
	sub.TextXAlignment = Enum.TextXAlignment.Left

	local x = Theme.button(portal, "Close", "X", C.gold, UDim2.fromOffset(Theme.size.tapMin, Theme.size.tapMin))
	x.AnchorPoint = Vector2.new(1, 0)
	x.Position = UDim2.new(1, -Theme.space.s2, 0, Theme.space.s2)
	x.Activated:Connect(close)

	local again =
		Theme.button(portal, "Refresh", Strings.portalRefresh, C.panelRaised, UDim2.fromOffset(96, Theme.size.tapMin))
	again.AnchorPoint = Vector2.new(1, 0)
	again.Position = UDim2.new(1, -Theme.size.tapMin - Theme.space.s4, 0, Theme.space.s2)
	local againTitle = again:FindFirstChild("Title") :: TextLabel
	againTitle.TextColor3 = C.ink
	again.Activated:Connect(function()
		if os.clock() - lastRefresh < REFRESH_GAP then
			return
		end
		lastRefresh = os.clock()
		refresh(true)
	end)

	list = Instance.new("Frame")
	list.Name = "List"
	list.BackgroundTransparency = 1
	list.Size = UDim2.new(1, -Theme.space.s4, 1, -80)
	list.Position = UDim2.fromOffset(Theme.space.s2, 72)
	list.Parent = portal
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, Theme.space.s2)
	layout.Parent = list

	message = Theme.bodyText(portal, Theme.type.body, C.gold)
	message.Size = UDim2.new(1, -20, 0, 26)
	message.Position = UDim2.new(0, 10, 0.5, 0)
	message.Visible = false

	openButton.Activated:Connect(open)

	RaidApi.raidStarted:Connect(function()
		inRaid = true
		close()
		openButton.Visible = false
	end)
	RaidApi.raidEnded:Connect(function()
		inRaid = false
		openButton.Visible = not desktop
	end)
end

return RaidPortalController
