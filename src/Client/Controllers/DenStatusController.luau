--!strict
--[[
	DenStatusController (owner: ui agent)

	Shows live protection and the post-loss countdown (D-031) from the Den Model attributes
	`LiveProtected` and `LiveGrabReadyAt` (server time). Display only: the server decides every
	grab. On another player's den a small billboard floats over it; on my own den a short
	"Protected today" chip sits under the Glow panel. Attribute changes redraw at once; a 4 Hz
	tick only advances countdown text, and only assigns Text when the string changed.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Hud = script.Parent.Parent:WaitForChild("Hud")
local Strings = require(Hud:WaitForChild("Strings"))
local DenStatusMath = require(Hud:WaitForChild("DenStatusMath")) :: any

local DenStatusController = {}

local player = Players.LocalPlayer
local TICK_SECONDS = 0.25
local FONT = Enum.Font.GothamBold

type Marker = { den: Instance, gui: BillboardGui, text: TextLabel, shown: string }

local markers: { [Instance]: Marker } = {}
local ownChip: Frame
local ownChipText: TextLabel
local ownShown = ""
local ownDen: Instance? = nil

local function styleLabel(l: TextLabel)
	l.BackgroundTransparency = 1
	l.Font = FONT
	l.TextColor3 = Color3.fromHex("FFFFFF")
	l.TextScaled = true
	l.Size = UDim2.fromScale(1, 1)
end

local function pill(parent: Instance, color: Color3): TextLabel
	local frame = Instance.new("Frame")
	frame.Name = "Pill"
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = color
	frame.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromHex("0B1026")
	stroke.Thickness = 2
	stroke.Parent = frame
	frame.Parent = parent
	local text = Instance.new("TextLabel")
	text.Name = "Text"
	styleLabel(text)
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 8)
	pad.PaddingTop = UDim.new(0, 3)
	pad.PaddingBottom = UDim.new(0, 3)
	pad.Parent = text
	text.Parent = frame
	return text
end

local function buildOwnChip()
	local gui = Instance.new("ScreenGui")
	gui.Name = "DenStatus"
	gui.ResetOnSpawn = false
	gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	gui.DisplayOrder = 1
	gui.Parent = player:WaitForChild("PlayerGui")
	local holder = Instance.new("Frame")
	holder.Name = "OwnProtected"
	holder.BackgroundTransparency = 1
	-- Under the Glow panel (top-left, 74 px tall at y = 8), left edge clear of the thumbstick.
	holder.Position = UDim2.fromOffset(10, 88)
	holder.Size = UDim2.fromOffset(150, 26)
	holder.Visible = false
	holder.Parent = gui
	ownChip = holder
	ownChipText = pill(holder, Color3.fromHex("2E7D5B"))
end

local function anchorFor(den: Instance): BasePart?
	if den:IsA("Model") and den.PrimaryPart then
		return den.PrimaryPart
	end
	return den:FindFirstChildWhichIsA("BasePart", true)
end

local function makeMarker(den: Instance): Marker?
	local anchor = anchorFor(den)
	if not anchor then
		return nil
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "DenStatusMarker"
	gui.Adornee = anchor
	gui.Size = UDim2.fromOffset(150, 28)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 14, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 120
	gui.Enabled = false
	gui.Parent = anchor
	local text = pill(gui, Color3.fromHex("1B1F3B"))
	return { den = den, gui = gui, text = text, shown = "" }
end

-- Redraw one den from its attributes. Cheap: reads two attributes, assigns only on change.
local function refresh(den: Instance, now: number)
	local protected = den:GetAttribute("LiveProtected")
	local readyAt = den:GetAttribute("LiveGrabReadyAt")
	if den:GetAttribute("OwnerUserId") == player.UserId then
		ownDen = den
		local mine = if DenStatusMath.isProtected(protected) then Strings.protectedToday else ""
		if mine ~= ownShown then
			ownShown = mine
			ownChipText.Text = mine
			ownChip.Visible = mine ~= ""
		end
		local marker = markers[den]
		if marker and marker.gui.Enabled then
			marker.gui.Enabled = false
			marker.shown = ""
		end
		return
	end
	if ownDen == den then
		ownDen = nil
		ownShown = ""
		ownChipText.Text = ""
		ownChip.Visible = false
	end
	local marker = markers[den]
	if not marker then
		marker = makeMarker(den)
		if not marker then
			return
		end
		markers[den] = marker
	end
	local text = DenStatusMath.markerText(protected, readyAt, now) or ""
	if text ~= marker.shown then
		marker.shown = text
		marker.text.Text = text
		marker.gui.Enabled = text ~= ""
	end
end

local function watchDen(den: Instance)
	local function onChange()
		refresh(den, workspace:GetServerTimeNow())
	end
	for _, attr in { "OwnerUserId", "LiveProtected", "LiveGrabReadyAt" } do
		den:GetAttributeChangedSignal(attr):Connect(onChange)
	end
	den.Destroying:Connect(function()
		local marker = markers[den]
		if marker then
			marker.gui:Destroy()
			markers[den] = nil
		end
	end)
	task.defer(onChange)
end

function DenStatusController.start()
	buildOwnChip()
	local watched: { [Instance]: boolean } = {}
	local function track(den: Instance)
		if watched[den] then
			return
		end
		watched[den] = true
		watchDen(den)
	end
	task.spawn(function()
		local dens = workspace:WaitForChild("World"):WaitForChild("Dens")
		for _, den in dens:GetChildren() do
			track(den)
		end
		dens.ChildAdded:Connect(track)
		dens.ChildRemoved:Connect(function(den)
			watched[den] = nil
		end)
	end)

	-- Countdown tick for dens that show text; nothing to do when every marker is hidden.
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < TICK_SECONDS then
			return
		end
		acc = 0
		local now = workspace:GetServerTimeNow()
		for den, marker in markers do
			if marker.shown ~= "" or den:GetAttribute("LiveGrabReadyAt") ~= nil then
				refresh(den, now)
			end
		end
	end)
end

return DenStatusController
