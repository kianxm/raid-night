--!strict
--[[
	RaidLogController (owner: ui agent)

	The raid log is the primary re-engagement surface (notifications only reach some players).
	On login it opens first if anything happened while away: who raided you, what they took, a
	Replay button and a Revenge button while the revenge window is open. A small "Log" button
	reopens it any time. Display only: Revenge just requests StartRaid; the server decides.

	"While away" = Incoming entries newer than the player attribute RaidLogSeenAt (server-written,
	handoff to data). Until it exists we fall back to the last 24 hours.

	TODO (Phase 3): replay viewer, clip export
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config")) :: any
local CritterCatalog = require(Shared:WaitForChild("CritterCatalog")) :: any

local Hud = script.Parent.Parent:WaitForChild("Hud")
local Raid = script.Parent.Parent:WaitForChild("Raid")
local Strings = require(Hud:WaitForChild("Strings"))
local RaidApi = require(Raid:WaitForChild("RaidApi"))
local RaidMath = require(Raid:WaitForChild("RaidMath"))
local Ui = require(Raid:WaitForChild("Ui"))
local RevengeController = require(script.Parent:WaitForChild("RevengeController")) :: any

local COLOR = Ui.COLOR
local ROW_HEIGHT = 78
local FALLBACK_WINDOW = 24 * 3600

local RaidLogController = {}

local player = Players.LocalPlayer
local panel: Frame
local titleLabel: TextLabel
local scroll: ScrollingFrame
local logButton: TextButton
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

local function addRow(entry: any, name: string, order: number, now: number)
	local row = Instance.new("Frame")
	row.Name = "Entry" .. order
	row.LayoutOrder = order
	row.Size = UDim2.new(1, -6, 0, ROW_HEIGHT)
	row.BackgroundColor3 = COLOR.row
	row.BorderSizePixel = 0
	Ui.round(row, 12)
	Ui.outline(row, 3)
	row.Parent = scroll

	local text = Ui.label(row, Ui.DISPLAY, 19)
	text.Text = summary(entry, name)
	text.TextWrapped = true
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.TextYAlignment = Enum.TextYAlignment.Top
	text.Size = UDim2.new(1, -210, 0, 46)
	text.Position = UDim2.fromOffset(10, 6)

	local when = Ui.label(row, Ui.BODY, 14, COLOR.dim)
	when.Text = Strings.format(Strings.logAgo, { time = RaidMath.ago(now - entry.at) })
	when.TextXAlignment = Enum.TextXAlignment.Left
	when.Size = UDim2.new(1, -210, 0, 18)
	when.Position = UDim2.fromOffset(10, 54)

	local canRevenge = entry.direction == "Incoming"
		and entry.escaped
		and RaidMath.revengeOpen(entry.at, now, Config.Revenge.windowSeconds)

	local replay = Ui.button(row, "Replay", Strings.replay, COLOR.gold, UDim2.fromOffset(88, 52))
	replay.AnchorPoint = Vector2.new(1, 0.5)
	replay.Position = UDim2.new(1, if canRevenge then -108 else -8, 0.5, 0)
	replay.Activated:Connect(function()
		task.spawn(function()
			if RaidApi.getReplay(entry.raidId) == nil then
				Ui.setButton(replay, Strings.replayNone, COLOR.gold, false)
				task.wait(2)
				Ui.setButton(replay, Strings.replay, COLOR.gold, true)
			end
		end)
	end)

	if canRevenge then
		local revenge = Ui.button(row, "Revenge", Strings.revenge, COLOR.revenge, UDim2.fromOffset(96, 52))
		revenge.AnchorPoint = Vector2.new(1, 0.5)
		revenge.Position = UDim2.new(1, -8, 0.5, 0)
		revenge.Activated:Connect(function()
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
	end
end

local function render(entries: { any }, title: string)
	rendering += 1
	local token = rendering
	titleLabel.Text = title
	for _, child in scroll:GetChildren() do
		if child:IsA("Frame") or child:IsA("TextLabel") then
			child:Destroy()
		end
	end
	if #entries == 0 then
		local empty = Ui.label(scroll, Ui.BODY, 18, COLOR.dim)
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

-- Incoming raids newer than the last time the player saw the log.
local function unseen(entries: { any }): { any }
	local seenAt = waitSeenAt()
	local since = if seenAt then seenAt else workspace:GetServerTimeNow() - FALLBACK_WINDOW
	local out = {}
	for _, entry in entries do
		if entry.direction == "Incoming" and entry.at > since then
			table.insert(out, entry)
		end
	end
	return out
end

local function openLog(onlyUnseen: boolean)
	task.spawn(function()
		local entries = RaidApi.getRaidLog()
		local shown = if onlyUnseen then unseen(entries) else entries
		if onlyUnseen and #shown == 0 then
			return
		end
		render(shown, if onlyUnseen then Strings.logTitle else Strings.logTitleAll)
		panel.Visible = true
	end)
end

function RaidLogController.start()
	RaidApi.start()
	local gui = Ui.screenGui("RaidLog", 6, player:WaitForChild("PlayerGui"))

	-- Under the Raid button, left edge, above the thumbstick zone.
	logButton = Ui.button(gui, "OpenLog", Strings.logTitleAll, COLOR.gold, UDim2.fromOffset(84, 44))
	logButton.Position = UDim2.new(0, 10, 0.5, -6)
	logButton.Activated:Connect(function()
		openLog(false)
	end)

	panel = Ui.panel(gui, "LogPanel", UDim2.fromScale(0.9, 0.92), UDim2.fromScale(0.5, 0.5))
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Visible = false
	local cap = Instance.new("UISizeConstraint")
	cap.MaxSize = Vector2.new(540, 340)
	cap.Parent = panel

	titleLabel = Ui.label(panel, Ui.DISPLAY, 28, COLOR.revenge)
	titleLabel.Size = UDim2.new(1, -80, 0, 38)
	titleLabel.Position = UDim2.fromOffset(12, 6)
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left

	local x = Ui.button(panel, "Close", "X", COLOR.gold, UDim2.fromOffset(48, 40))
	x.AnchorPoint = Vector2.new(1, 0)
	x.Position = UDim2.new(1, -8, 0, 6)
	x.Activated:Connect(function()
		panel.Visible = false
	end)

	scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Entries"
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 6
	scroll.Size = UDim2.new(1, -20, 1, -58)
	scroll.Position = UDim2.fromOffset(10, 50)
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.CanvasSize = UDim2.new()
	scroll.Parent = panel
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 8)
	layout.Parent = scroll

	RaidApi.raidStarted:Connect(function()
		panel.Visible = false
		logButton.Visible = false
	end)
	RaidApi.raidEnded:Connect(function()
		logButton.Visible = true
	end)

	-- On login: open first if anything happened while away.
	openLog(true)
end

return RaidLogController
