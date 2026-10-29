--!strict
--[[
	LogKit (owner: ui agent): the small pieces shared by the raid log, revenge sheets and opt-in
	card (D-071 AwayLog / RevengeSheet / RevengeClosed / OptIn). Everything reads Theme.
]]

local Theme = require(script.Parent:WaitForChild("Theme"))

local LogKit = {}

local C = Theme.color

-- Round badge with the player's first two letters (the design's rn-avatar).
function LogKit.avatar(parent: Instance, name: string, tint: Color3, diameter: number): Frame
	local f = Instance.new("Frame")
	f.Name = "Avatar"
	f.Size = UDim2.fromOffset(diameter, diameter)
	f.BackgroundColor3 = C.panelSunken
	f.BorderSizePixel = 0
	Theme.corner(f, Theme.radius.full)
	Theme.outline(f, Theme.stroke.normal, tint)
	f.Parent = parent
	local t = Theme.text(f, if diameter >= 48 then Theme.type.numberSm else Theme.type.label, C.ink)
	t.Text = string.upper(string.sub(name, 1, 2))
	return f
end

-- Neutral button (design rn-btn--ghost): raised fill, light label.
function LogKit.ghost(parent: Instance, name: string, text: string, size: UDim2): TextButton
	local b = Theme.button(parent, name, text, C.line, size)
	local title = b:FindFirstChild("Title") :: TextLabel
	title.TextColor3 = C.ink
	return b
end

function LogKit.setLabel(b: TextButton, text: string)
	local title = b:FindFirstChild("Title") :: TextLabel
	title.Text = text
end

-- Square close button for a popup corner.
function LogKit.closeX(parent: Instance): TextButton
	local x = LogKit.ghost(parent, "Close", "X", UDim2.fromOffset(Theme.size.tapMin, Theme.size.tapMin))
	x.AnchorPoint = Vector2.new(1, 0)
	x.Position = UDim2.new(1, -Theme.space.s3, 0, Theme.space.s3)
	return x
end

-- Popup: indigo panel, radius-xl2, heavy outline, accent bar across the top. Hidden until shown.
function LogKit.popup(gui: Instance, name: string, accent: Color3, size: UDim2, maxSize: Vector2): Frame
	local f = Theme.panel(gui, name, size, UDim2.fromScale(0.5, 0.5))
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Visible = false
	f.ClipsDescendants = true
	local corner = f:FindFirstChildOfClass("UICorner") :: UICorner
	corner.CornerRadius = UDim.new(0, Theme.radius.xl2)
	local rim = f:FindFirstChildOfClass("UIStroke") :: UIStroke
	rim.Thickness = Theme.stroke.heavy
	local cap = Instance.new("UISizeConstraint")
	cap.MaxSize = maxSize
	cap.Parent = f
	local bar = Instance.new("Frame")
	bar.Name = "AccentBar"
	bar.Size = UDim2.new(1, 0, 0, 6)
	bar.BackgroundColor3 = accent
	bar.BorderSizePixel = 0
	bar.Parent = f
	return f
end

-- Sunken well for secondary content (design .well).
function LogKit.well(parent: Instance, name: string): Frame
	local w = Instance.new("Frame")
	w.Name = name
	w.BackgroundColor3 = C.panelSunken
	w.BorderSizePixel = 0
	Theme.corner(w, Theme.radius.lg)
	Theme.outline(w, Theme.stroke.thin, C.line)
	w.Parent = parent
	return w
end

return LogKit
