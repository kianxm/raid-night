--!strict
--[[
	Ui (owner: ui agent): small widget helpers for the raid screens. Same look as HudController
	(chunky rounded panels, thick outlines, Fredoka numbers); a thin layer over Ui/Theme.luau.
]]

local TweenService = game:GetService("TweenService")

local SettingsState = require(script.Parent.Parent:WaitForChild("Hud"):WaitForChild("SettingsState"))

local Theme = require(script.Parent.Parent:WaitForChild("Ui"):WaitForChild("Theme"))

local Ui = {}

Ui.theme = Theme

-- Legacy names kept so every screen restyles from the theme without edits.
Ui.COLOR = {
	panel = Theme.color.panel,
	row = Theme.color.panelRaised,
	outline = Theme.color.night900,
	text = Theme.color.ink,
	dim = Theme.color.inkDim,
	glow = Theme.color.glow,
	go = Theme.color.go,
	revenge = Theme.color.revenge,
	gold = Theme.color.gold,
	lock = Theme.color.lock,
	safe = Theme.color.safe,
	disabled = Theme.color.disabled,
}
Ui.DISPLAY = Theme.display
Ui.BODY = Theme.body

function Ui.round(parent: Instance, radius: number)
	Theme.corner(parent, radius)
end

function Ui.outline(parent: Instance, thickness: number)
	Theme.outline(parent, thickness)
end

function Ui.label(parent: Instance, font: Enum.Font, maxSize: number, color: Color3?): TextLabel
	local l = Theme.text(parent, maxSize, color, true)
	l.Font = font
	return l
end

function Ui.panel(parent: Instance, name: string, size: UDim2, position: UDim2): Frame
	return Theme.panel(parent, name, size, position)
end

-- Chunky button with one big title. Callers keep height >= 44 px for thumbs.
function Ui.button(parent: Instance, name: string, text: string, color: Color3, size: UDim2): TextButton
	return Theme.button(parent, name, text, color, size)
end

function Ui.setButton(b: TextButton, text: string, color: Color3, enabled: boolean)
	local title = b:FindFirstChild("Title") :: TextLabel
	title.Text = text
	title.TextColor3 = if enabled then Theme.color.onAccent else Theme.color.onDisabled
	b.BackgroundColor3 = if enabled then color else Theme.color.disabled
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
	local corner = f:FindFirstChildOfClass("UICorner")
	if corner then
		corner.CornerRadius = UDim.new(0, Theme.radius.xl2)
	end
	local rim = f:FindFirstChildOfClass("UIStroke")
	if rim then
		rim.Thickness = Theme.stroke.heavy
	end
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
	c.BackgroundColor3 = Theme.color.panelRaised
	c.BorderSizePixel = 0
	c.ZIndex = 9
	Theme.corner(c, Theme.radius.lg)
	Theme.outline(c, Theme.stroke.thin)
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

-- PC key hint: a small raised cap ("Enter", "Esc", "1") for buttons and cards.
function Ui.keycap(parent: Instance, text: string): Frame
	local cap, label = Theme.chip(parent, "Keycap", text, Theme.color.panelSunken, Theme.color.ink)
	local width = 24 + 8 * #text
	cap.Size = UDim2.fromOffset(width, 24)
	label.Font = Theme.display
	return cap
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
