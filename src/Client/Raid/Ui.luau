--!strict
--[[
	Ui (owner: ui agent): small widget helpers for the raid screens. Same look as HudController
	(chunky rounded panels, thick outlines, Fredoka numbers, Gotham body); one accent per screen.
]]

local TweenService = game:GetService("TweenService")

local SettingsState = require(script.Parent.Parent:WaitForChild("Hud"):WaitForChild("SettingsState"))

local Ui = {}

Ui.COLOR = {
	panel = Color3.fromHex("1B1F3B"),
	row = Color3.fromHex("2E3552"),
	outline = Color3.fromHex("0B1026"),
	text = Color3.fromHex("FFFFFF"),
	dim = Color3.fromHex("B8BEDD"),
	glow = Color3.fromHex("78E6FF"),
	go = Color3.fromHex("5BE38A"),
	revenge = Color3.fromHex("FF6B6B"),
	gold = Color3.fromHex("FFC857"),
	disabled = Color3.fromHex("4A5070"),
}
Ui.DISPLAY = Enum.Font.FredokaOne
Ui.BODY = Enum.Font.GothamBold

function Ui.round(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
end

function Ui.outline(parent: Instance, thickness: number)
	local s = Instance.new("UIStroke")
	s.Color = Ui.COLOR.outline
	s.Thickness = thickness
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
end

function Ui.label(parent: Instance, font: Enum.Font, maxSize: number, color: Color3?): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = font
	l.TextColor3 = color or Ui.COLOR.text
	l.TextScaled = true
	l.Size = UDim2.fromScale(1, 1)
	local limit = Instance.new("UITextSizeConstraint")
	limit.MaxTextSize = maxSize
	limit.MinTextSize = 10
	limit.Parent = l
	l.Parent = parent
	return l
end

function Ui.panel(parent: Instance, name: string, size: UDim2, position: UDim2): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.Size = size
	f.Position = position
	f.BackgroundColor3 = Ui.COLOR.panel
	f.BorderSizePixel = 0
	Ui.round(f, 14)
	Ui.outline(f, 3)
	f.Parent = parent
	return f
end

-- Chunky button with one big title. Callers keep height >= 44 px for thumbs.
function Ui.button(parent: Instance, name: string, text: string, color: Color3, size: UDim2): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.Size = size
	b.BackgroundColor3 = color
	b.Text = ""
	b.AutoButtonColor = true
	Ui.round(b, 12)
	Ui.outline(b, 3)
	b.Parent = parent
	local t = Ui.label(b, Ui.DISPLAY, 22, Ui.COLOR.outline)
	t.Name = "Title"
	t.Text = text
	t.Size = UDim2.new(1, -10, 1, -8)
	t.Position = UDim2.fromOffset(5, 4)
	return b
end

function Ui.setButton(b: TextButton, text: string, color: Color3, enabled: boolean)
	local title = b:FindFirstChild("Title") :: TextLabel
	title.Text = text
	b.BackgroundColor3 = if enabled then color else Ui.COLOR.disabled
	b.Active = enabled
end

-- Centered modal for menu screens: title bar, scrolling body, big Close button. Phone first
-- (90% of the screen), capped so a desktop window does not stretch it. Hidden until opened.
-- Returns the frame, the scrolling body (vertical list layout) and the close button.
function Ui.modal(gui: Instance, name: string, title: string, accent: Color3): (Frame, ScrollingFrame, TextButton)
	local f = Ui.panel(gui, name, UDim2.fromScale(0.92, 0.9), UDim2.fromScale(0.5, 0.5))
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Visible = false
	f.ZIndex = 8
	local cap = Instance.new("UISizeConstraint")
	cap.MaxSize = Vector2.new(480, 560)
	cap.Parent = f
	local bar = Instance.new("Frame")
	bar.Name = "AccentBar"
	bar.Size = UDim2.new(1, 0, 0, 6)
	bar.BackgroundColor3 = accent
	bar.BorderSizePixel = 0
	bar.ZIndex = 9
	bar.Parent = f
	local t = Ui.label(f, Ui.DISPLAY, 26, accent)
	t.Name = "Title"
	t.Text = title
	t.Size = UDim2.new(1, -16, 0, 34)
	t.Position = UDim2.fromOffset(8, 12)
	t.ZIndex = 9
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Body"
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.Size = UDim2.new(1, -16, 1, -116)
	scroll.Position = UDim2.fromOffset(8, 52)
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollBarThickness = 6
	scroll.ZIndex = 9
	scroll.Parent = f
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 8)
	list.Parent = scroll
	local close = Ui.button(f, "Close", "", accent, UDim2.new(1, -16, 0, 48))
	close.AnchorPoint = Vector2.new(0.5, 1)
	close.Position = UDim2.new(0.5, 0, 1, -8)
	close.ZIndex = 9
	return f, scroll, close
end

-- A row card for a modal body: dark row color, rounded, fixed height.
function Ui.card(parent: Instance, name: string, order: number, height: number): Frame
	local c = Instance.new("Frame")
	c.Name = name
	c.LayoutOrder = order
	c.Size = UDim2.new(1, -8, 0, height)
	c.BackgroundColor3 = Ui.COLOR.row
	c.BorderSizePixel = 0
	c.ZIndex = 9
	Ui.round(c, 12)
	Ui.outline(c, 2)
	c.Parent = parent
	return c
end

-- Short pop-in for a screen that just opened. Skipped entirely under Reduced motion.
function Ui.pop(frame: GuiObject)
	if SettingsState.get().reducedMotion then
		return
	end
	local scale = frame:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	scale.Scale = 0.92
	scale.Parent = frame
	TweenService:Create(scale, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 1 })
		:Play()
end

function Ui.screenGui(name: string, order: number, parent: Instance): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling -- children always draw above their parent
	gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	gui.DisplayOrder = order
	gui.Parent = parent
	return gui
end

return Ui
