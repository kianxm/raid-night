--!strict
--[[
	Ui (owner: ui agent): small widget helpers for the raid screens. Same look as HudController
	(chunky rounded panels, thick outlines, Fredoka numbers, Gotham body); one accent per screen.
]]

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

function Ui.screenGui(name: string, order: number, parent: Instance): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.ResetOnSpawn = false
	gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	gui.DisplayOrder = order
	gui.Parent = parent
	return gui
end

return Ui
