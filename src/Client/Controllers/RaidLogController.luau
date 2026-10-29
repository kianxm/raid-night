--!strict
--[[
	RaidLogController (owner: ui agent)

	The raid log is the primary re-engagement surface (notifications only reach some players).
	On login it opens first if anything happened while away: who raided you, what they took, a
	Replay button, a Report button and a Revenge button while the revenge window is open. A small
	"Log" button reopens it any time (phone); on PC a compact "Recent raids" panel sits top-right
	and opens the full log. Display only: Revenge just requests StartRaid; the server decides.
	Look: D-071 AwayLog / DeskAwayLog.

	"While away" = Incoming entries newer than the player attribute RaidLogSeenAt (server-written,
	handoff to data). Until it exists we fall back to the last 24 hours.

	TODO (Phase 3): replay viewer, clip export
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config")) :: any
local CritterCatalog = require(Shared:WaitForChild("CritterCatalog")) :: any

local Client = script.Parent.Parent
local Hud = Client:WaitForChild("Hud")
local Raid = Client:WaitForChild("Raid")
local Strings = require(Hud:WaitForChild("Strings"))
local HudLayout = require(Hud:WaitForChild("HudLayout"))
local RaidApi = require(Raid:WaitForChild("RaidApi"))
local RaidMath = require(Raid:WaitForChild("RaidMath"))
local Toast = require(Raid:WaitForChild("Toast"))
local Ui = require(Raid:WaitForChild("Ui"))
local Theme = require(Client:WaitForChild("Ui"):WaitForChild("Theme"))
local LogKit = require(Client:WaitForChild("Ui"):WaitForChild("LogKit"))
local RevengeController = require(script.Parent:WaitForChild("RevengeController")) :: any

local C = Theme.color
local DESKTOP = HudLayout.mode(UserInputService.TouchEnabled, UserInputService.KeyboardEnabled) == "desktop"
local ROW_HEIGHT = 64
local AVATAR = 44
local FEED_ROWS = 4
local FALLBACK_WINDOW = 24 * 3600

local RaidLogController = {}

local player = Players.LocalPlayer
local panel: Frame
local titleLabel: TextLabel
local subLabel: TextLabel
local scroll: ScrollingFrame
local logButton: TextButton?
local feed: Frame?
local feedRows: Frame?
local latest: { any } = {}
local rendering = 0

local function critterName(speciesId: string?): string
	local species = if speciesId then CritterCatalog.get(speciesId) else nil
	return if species then species.name else "?"
end

local function summary(entry: any, name: string): string
	if entry.direction == "Incoming" then
		if not entry.escaped then
			return Strings.format(Strings.logHeld, { name = name })
		end
		local vars = { name = name, critter = critterName(entry.speciesId), n = tostring(math.floor(entry.glow)) }
		return Strings.format(if entry.glow > 0 then Strings.logTookGlow else Strings.logTookFrom, vars)
	end
	if entry.escaped then
		return Strings.format(Strings.logYouTook, { name = name, critter = critterName(entry.speciesId) })
	end
	return Strings.format(Strings.logYouFailed, { name = name })
end

local function lostToRaider(entry: any): boolean
	return entry.direction == "Incoming" and entry.escaped == true
end

local function rowTint(entry: any): Color3
	if entry.direction ~= "Incoming" then
		return C.night900
	end
	return if entry.escaped then C.revenge else C.lock
end

local function addRow(entry: any, name: string, order: number, now: number)
	local tint = rowTint(entry)
	local row = Instance.new("Frame")
	row.Name = "Entry" .. order
	row.LayoutOrder = order
	row.Size = UDim2.new(1, -6, 0, ROW_HEIGHT)
	row.BackgroundColor3 = C.panelRaised
	row.BorderSizePixel = 0
	Theme.corner(row, Theme.radius.lg)
	Theme.outline(row, Theme.stroke.normal, tint)
	row.Parent = scroll

	local avatar = LogKit.avatar(row, name, if tint == C.night900 then C.line else tint, AVATAR)
	avatar.AnchorPoint = Vector2.new(0, 0.5)
	avatar.Position = UDim2.new(0, Theme.space.s2, 0.5, 0)

	local canRevenge = lostToRaider(entry) and RaidMath.revengeOpen(entry.at, now, Config.Revenge.windowSeconds)
	local late = lostToRaider(entry) and not canRevenge
	local held = entry.direction == "Incoming" and not entry.escaped

	-- Right side, placed right to left: action (Revenge / Held), Report, Replay.
	local x = -Theme.space.s2
	local function place(b: GuiObject, width: number)
		b.AnchorPoint = Vector2.new(1, 0.5)
		b.Position = UDim2.new(1, x, 0.5, 0)
		x -= width + Theme.space.s2
	end

	if canRevenge or late then
		local size = UDim2.fromOffset(92, Theme.size.tapMin)
		local b = if canRevenge
			then Ui.button(row, "Revenge", Strings.revenge, C.revenge, size)
			else LogKit.ghost(row, "Revenge", Strings.revenge, size)
		place(b, 92)
		b.Activated:Connect(function()
			if late then
				RevengeController.showClosed(entry.otherUserId)
				return
			end
			task.spawn(function()
				-- raiderOnline lives on the revenge row of GetRaidTargets (cached in RaidApi).
				local online = false
				for _, target in RaidApi.getTargets() do
					if target.revengeRaidId == entry.raidId then
						online = target.raiderOnline == true
					end
				end
				panel.Visible = false
				RevengeController.begin(entry.otherUserId, entry.raidId, online)
			end)
		end)
	elseif held then
		local pill = Theme.chip(row, "Held", Strings.logHeldPill, C.lock, C.onAccent)
		pill.Size = UDim2.fromOffset(64, 28)
		place(pill, 64)
	end

	local report = LogKit.ghost(row, "Report", Strings.report, UDim2.fromOffset(72, Theme.size.tapMin))
	place(report, 72)
	report.Activated:Connect(function()
		Toast.show(Strings.reportHint)
	end)

	local replay = Ui.button(row, "Replay", Strings.replay, C.gold, UDim2.fromOffset(84, Theme.size.tapMin))
	place(replay, 84)
	replay.Activated:Connect(function()
		task.spawn(function()
			if RaidApi.getReplay(entry.raidId) == nil then
				Ui.setButton(replay, Strings.replayNone, C.gold, false)
				task.wait(2)
				Ui.setButton(replay, Strings.replay, C.gold, true)
			end
		end)
	end)

	local textLeft = AVATAR + Theme.space.s2 * 2
	local main = Instance.new("Frame")
	main.Name = "Main"
	main.BackgroundTransparency = 1
	main.Position = UDim2.fromOffset(textLeft, 0)
	main.Size = UDim2.new(1, -(textLeft - x + Theme.space.s2), 1, 0)
	main.Parent = row

	local text = Ui.label(main, Ui.BODY, Theme.type.body + 2, C.ink)
	text.Text = summary(entry, name)
	text.TextWrapped = true
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.Size = UDim2.fromScale(1, 0.55)
	text.Position = UDim2.fromScale(0, 0.06)

	local caption = Strings.format(Strings.logAgo, { time = RaidMath.ago(now - entry.at) })
	if canRevenge then
		local left = Config.Revenge.windowSeconds - (now - entry.at)
		caption ..= " · " .. Strings.format(Strings.logRevengeOpen, { time = RaidMath.ago(left) })
	elseif held then
		caption ..= " · " .. Strings.logHeldPill
	elseif entry.direction == "Incoming" and not entry.speciesId then
		caption ..= " · " .. Strings.logNoLoss
	end
	local when = Ui.label(main, Ui.BODY, Theme.type.caption, C.inkMute)
	when.Text = caption
	when.TextXAlignment = Enum.TextXAlignment.Left
	when.Size = UDim2.fromScale(1, 0.3)
	when.Position = UDim2.fromScale(0, 0.64)
end

-- PC panel, top-right: the latest few entries from the data the log already fetched.
local function renderFeed()
	local box, rows = feed, feedRows
	if not box or not rows then
		return
	end
	for _, child in rows:GetChildren() do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end
	local now = workspace:GetServerTimeNow()
	local shown = 0
	for i, entry in latest do
		if shown >= FEED_ROWS then
			break
		end
		local line = Ui.label(rows, Ui.BODY, Theme.type.label, if lostToRaider(entry) then C.revenge else C.inkDim)
		line.Name = "Feed" .. i
		line.LayoutOrder = i
		line.Size = UDim2.new(1, 0, 0, 22)
		line.TextXAlignment = Enum.TextXAlignment.Left
		line.TextTruncate = Enum.TextTruncate.AtEnd
		line.Text = `{RaidMath.ago(now - entry.at)}  {summary(entry, RaidApi.nameFor(entry.otherUserId))}`
		shown += 1
	end
	box.Visible = shown > 0
	box.Size = UDim2.fromOffset(250, 38 + shown * 24)
end

local function render(entries: { any }, title: string, away: number?)
	rendering += 1
	local token = rendering
	titleLabel.Text = title
	subLabel.Text = if away then Strings.format(Strings.logAway, { time = RaidMath.ago(away) }) else ""
	for _, child in scroll:GetChildren() do
		if child:IsA("Frame") or child:IsA("TextLabel") then
			child:Destroy()
		end
	end
	if #entries == 0 then
		local empty = Ui.label(scroll, Ui.BODY, 18, C.inkDim)
		empty.Text = Strings.logEmpty
		empty.Size = UDim2.new(1, 0, 0, 40)
		return
	end
	local now = workspace:GetServerTimeNow()
	for i, entry in entries do
		local name = RaidApi.nameFor(entry.otherUserId)
		if token ~= rendering then
			return
		end
		addRow(entry, name, i, now)
	end
end

-- RaidLogSeenAt is written by the server a moment after join (0 = never opened). Wait briefly
-- for it so "while you were away" is exact; fall back to the last day if it never arrives.
local function waitSeenAt(): number?
	if type(player:GetAttribute("RaidLogSeenAt")) ~= "number" then
		local arrived = false
		local conn = player:GetAttributeChangedSignal("RaidLogSeenAt"):Connect(function()
			arrived = true
		end)
		local deadline = os.clock() + 5
		while not arrived and os.clock() < deadline do
			task.wait(0.1)
		end
		conn:Disconnect()
	end
	local seenAt = player:GetAttribute("RaidLogSeenAt")
	return if type(seenAt) == "number" then seenAt else nil
end

-- Incoming raids newer than the last time the player saw the log, and how long they were away.
local function unseen(entries: { any }): ({ any }, number?)
	local seenAt = waitSeenAt()
	local now = workspace:GetServerTimeNow()
	local since = if seenAt then seenAt else now - FALLBACK_WINDOW
	local out = {}
	for _, entry in entries do
		if entry.direction == "Incoming" and entry.at > since then
			table.insert(out, entry)
		end
	end
	return out, if seenAt and seenAt > 0 then now - seenAt else nil
end

local function openLog(onlyUnseen: boolean)
	task.spawn(function()
		latest = RaidApi.getRaidLog()
		renderFeed()
		local shown: { any } = latest
		local away: number? = nil
		if onlyUnseen then
			shown, away = unseen(latest)
			if #shown == 0 then
				return
			end
		end
		render(shown, if onlyUnseen then Strings.logTitle else Strings.logTitleAll, away)
		panel.Visible = true
		Ui.pop(panel)
	end)
end

local function buildFeed(gui: ScreenGui)
	local box = Theme.panel(gui, "RaidFeed", UDim2.fromOffset(250, 38), UDim2.new(1, -16, 0, 16))
	box.AnchorPoint = Vector2.new(1, 0)
	box.Visible = false
	local head = Theme.bodyText(box, Theme.type.caption, C.inkMute)
	head.Text = Theme.upper(Strings.logRecent)
	head.TextXAlignment = Enum.TextXAlignment.Left
	head.Size = UDim2.new(1, -24, 0, 18)
	head.Position = UDim2.fromOffset(12, 8)
	local rows = Instance.new("Frame")
	rows.Name = "Rows"
	rows.BackgroundTransparency = 1
	rows.Size = UDim2.new(1, -24, 1, -34)
	rows.Position = UDim2.fromOffset(12, 28)
	rows.Parent = box
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 2)
	list.Parent = rows
	local open = Instance.new("TextButton")
	open.Name = "Open"
	open.BackgroundTransparency = 1
	open.Text = ""
	open.Size = UDim2.fromScale(1, 1)
	open.Parent = box
	open.Activated:Connect(function()
		openLog(false)
	end)
	feed, feedRows = box, rows
end

function RaidLogController.start()
	RaidApi.start()
	local gui = Ui.screenGui("RaidLog", 6, player:WaitForChild("PlayerGui"))

	if DESKTOP then
		buildFeed(gui)
	else
		-- Under the Raid button, left edge, above the thumbstick zone.
		local b = Ui.button(gui, "OpenLog", Strings.logTitleAll, C.gold, UDim2.fromOffset(84, Theme.size.tapMin))
		b.Position = UDim2.new(0, 10, 0.5, -6)
		b.Activated:Connect(function()
			openLog(false)
		end)
		logButton = b
	end

	local maxSize = if DESKTOP then Vector2.new(760, 600) else Vector2.new(620, 360)
	panel = LogKit.popup(gui, "LogPanel", C.revenge, UDim2.fromScale(0.92, 0.92), maxSize)

	titleLabel = Theme.text(panel, Theme.type.title + 4, C.revenge)
	titleLabel.Size = UDim2.new(1, -80, 0, 34)
	titleLabel.Position = UDim2.fromOffset(16, 14)
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left

	subLabel = Theme.bodyText(panel, Theme.type.label, C.inkDim)
	subLabel.Size = UDim2.new(1, -80, 0, 18)
	subLabel.Position = UDim2.fromOffset(16, 48)
	subLabel.TextXAlignment = Enum.TextXAlignment.Left

	local x = LogKit.closeX(panel)
	x.Activated:Connect(function()
		panel.Visible = false
	end)

	scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Entries"
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 6
	scroll.Size = UDim2.new(1, -24, 1, -140)
	scroll.Position = UDim2.fromOffset(12, 72)
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.CanvasSize = UDim2.new()
	scroll.Parent = panel
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, Theme.space.s2)
	layout.Parent = scroll

	local den = LogKit.ghost(panel, "ToMyDen", Strings.toMyDen, UDim2.fromOffset(140, Theme.size.tapMin))
	den.AnchorPoint = Vector2.new(1, 1)
	den.Position = UDim2.new(1, -Theme.space.s3, 1, -Theme.space.s3)
	den.Activated:Connect(function()
		panel.Visible = false
	end)

	UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and input.KeyCode == Enum.KeyCode.Escape and panel.Visible then
			panel.Visible = false
		end
	end)

	RaidApi.raidStarted:Connect(function()
		panel.Visible = false
		if logButton then
			logButton.Visible = false
		end
		if feed then
			feed.Visible = false
		end
	end)
	RaidApi.raidEnded:Connect(function()
		if logButton then
			logButton.Visible = true
		end
		renderFeed()
	end)

	-- On login: open first if anything happened while away.
	openLog(true)
end

return RaidLogController
