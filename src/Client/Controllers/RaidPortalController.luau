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

local Hud = script.Parent.Parent:WaitForChild("Hud")
local Raid = script.Parent.Parent:WaitForChild("Raid")
local Strings = require(Hud:WaitForChild("Strings"))
local HudMath = require(Hud:WaitForChild("HudMath"))
local RaidApi = require(Raid:WaitForChild("RaidApi"))
local RaidMath = require(Raid:WaitForChild("RaidMath"))
local Toast = require(Raid:WaitForChild("Toast"))
local Ui = require(Raid:WaitForChild("Ui"))
local RevengeController = require(script.Parent:WaitForChild("RevengeController")) :: any

local COLOR = Ui.COLOR
local ROW_HEIGHT = 62

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
	local row = Instance.new("Frame")
	row.Name = "Target" .. order
	row.LayoutOrder = order
	row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	row.BackgroundColor3 = COLOR.row
	row.BorderSizePixel = 0
	Ui.round(row, 12)
	Ui.outline(row, if isRevenge then 4 else 3)
	if isRevenge then
		(row:FindFirstChildOfClass("UIStroke") :: UIStroke).Color = COLOR.revenge
	end
	row.Parent = list

	local name = Ui.label(row, Ui.DISPLAY, 22)
	name.Text = target.displayName
	name.Size = UDim2.new(0.5, -8, 0, 28)
	name.Position = UDim2.fromOffset(10, 5)
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.TextTruncate = Enum.TextTruncate.AtEnd

	local hint = Ui.label(row, Ui.BODY, 15, COLOR.dim)
	hint.Text = (Strings :: any)[RaidMath.hintKey(target.topTier)]
	hint.Size = UDim2.new(0.5, -8, 0, 20)
	hint.Position = UDim2.fromOffset(10, 35)
	hint.TextXAlignment = Enum.TextXAlignment.Left

	local power = Ui.label(row, Ui.DISPLAY, 18, COLOR.glow)
	power.Text = Strings.format(Strings.power, { n = HudMath.abbreviate(target.power) })
	power.Size = UDim2.new(0.22, 0, 0, 28)
	power.Position = UDim2.new(0.5, 0, 0, 5)

	if isRevenge then
		local tag = Ui.label(row, Ui.DISPLAY, 14, COLOR.outline)
		tag.Text = Strings.revengeTag
		tag.BackgroundTransparency = 0
		tag.BackgroundColor3 = COLOR.revenge
		tag.Size = UDim2.new(0.2, 0, 0, 20)
		tag.Position = UDim2.new(0.51, 0, 0, 35)
		Ui.round(tag, 8)
	end

	local go = Ui.button(
		row,
		"Go",
		if isRevenge then Strings.revenge else Strings.raid,
		if isRevenge then COLOR.revenge else COLOR.go,
		UDim2.new(0.26, 0, 1, -12)
	)
	go.AnchorPoint = Vector2.new(1, 0.5)
	go.Position = UDim2.new(1, -8, 0.5, 0)
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

	-- Left edge, vertically centered: out of the thumbstick zone (bottom-left), the Glow panel
	-- (top-left) and the den chip (y 88-114).
	openButton = Ui.button(gui, "OpenPortal", Strings.raid, COLOR.go, UDim2.fromOffset(84, 52))
	openButton.Position = UDim2.new(0, 10, 0.5, -64)

	portal = Ui.panel(gui, "Portal", UDim2.fromScale(0.86, 0.9), UDim2.fromScale(0.5, 0.5))
	portal.AnchorPoint = Vector2.new(0.5, 0.5)
	portal.Visible = false
	local cap = Instance.new("UISizeConstraint")
	cap.MaxSize = Vector2.new(480, 330)
	cap.Parent = portal

	local title = Ui.label(portal, Ui.DISPLAY, 28, COLOR.glow)
	title.Text = Strings.portalTitle
	title.Size = UDim2.new(1, -176, 0, 38)
	title.Position = UDim2.fromOffset(12, 6)
	title.TextXAlignment = Enum.TextXAlignment.Left

	local x = Ui.button(portal, "Close", "X", COLOR.gold, UDim2.fromOffset(48, 40))
	x.AnchorPoint = Vector2.new(1, 0)
	x.Position = UDim2.new(1, -8, 0, 6)
	x.Activated:Connect(close)

	local again = Ui.button(portal, "Refresh", Strings.portalRefresh, COLOR.glow, UDim2.fromOffset(96, 40))
	again.AnchorPoint = Vector2.new(1, 0)
	again.Position = UDim2.new(1, -64, 0, 6)
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
	list.Size = UDim2.new(1, -20, 1, -62)
	list.Position = UDim2.fromOffset(10, 52)
	list.Parent = portal
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 8)
	layout.Parent = list

	message = Ui.label(portal, Ui.BODY, 18, COLOR.gold)
	message.Size = UDim2.new(1, -20, 0, 26)
	message.Position = UDim2.new(0, 10, 1, -34)
	message.Visible = false

	openButton.Activated:Connect(open)

	RaidApi.raidStarted:Connect(function()
		inRaid = true
		close()
		openButton.Visible = false
	end)
	RaidApi.raidEnded:Connect(function()
		inRaid = false
		openButton.Visible = true
	end)
end

return RaidPortalController
