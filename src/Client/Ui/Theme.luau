--!strict
--[[
	Theme (owner: ui agent): Kian's Raid Night design system (D-071, tokens.json v1) as Luau.
	Every colour, type size, space, radius and stroke lives here; screens and the Ui kit
	(Raid/Ui.luau) read it, so a restyle is a change to this file.

	Font mapping (public Roblox fonts only):
	  Fredoka (display, 600)      -> Enum.Font.FredokaOne   titles, numbers, button labels
	  Nunito (body, 800-900)      -> Enum.Font.BuilderSansBold   body, labels, captions
	  The README suggests GothamBold as the alternative; BuilderSans is rounder, so it sits
	  closer to Nunito. Roblox has no tracking, so the uppercase `label` style is uppercased
	  in text (Theme.upper) and not letter-spaced.

	API (names other agents call):
	  Theme.color.*  Theme.type.*  Theme.space.*  Theme.radius.*  Theme.stroke.*  Theme.size.*
	  Theme.corner / outline / padding / gradient / text / panel / button / chip / bar / orb / scrim
	  Theme.upper(s)
]]

local Theme = {}

local function hex(h: string): Color3
	return Color3.fromHex(h)
end

Theme.color = {
	night950 = hex("070A1A"),
	night900 = hex("0B1026"), -- the world and every outline
	panel = hex("1B1F3B"),
	panelRaised = hex("2E3552"),
	panelSunken = hex("12162E"),
	line = hex("3A4268"),
	ink = hex("FFFFFF"),
	inkDim = hex("B8BEDD"),
	inkMute = hex("9CA3C9"),
	onAccent = hex("0B1026"), -- text on every accent fill
	glow = hex("78E6FF"),
	glowDeep = hex("2BB8DE"),
	go = hex("5BE38A"),
	gold = hex("FFC857"),
	lock = hex("9B7BFF"),
	revenge = hex("FF6B6B"),
	revengeDeep = hex("C93B4E"),
	safe = hex("2E7D5B"),
	disabled = hex("4A5070"),
	onDisabled = hex("C9CEE8"),
	tier = {
		Common = hex("C9CEE8"),
		Uncommon = hex("5BE38A"),
		Rare = hex("4FB3FF"),
		Epic = hex("B88CFF"),
		Legendary = hex("FFC857"),
		Mythic = hex("FF7AB8"),
		Secret = hex("7CFFE4"),
	},
}
Theme.scrimTransparency = 0.28 -- scrim is night-950 at 72% opacity

Theme.display = Enum.Font.FredokaOne
Theme.body = Enum.Font.BuilderSansBold

-- Max text sizes in px (tokens.json type styles). Use with Theme.text.
Theme.type = {
	heroNumber = 56,
	titleLg = 32,
	title = 24,
	buttonText = 22,
	number = 28,
	numberSm = 18,
	body = 16,
	label = 14,
	caption = 12,
}
Theme.MIN_TEXT = 10

Theme.space = { s1 = 4, s2 = 8, s3 = 12, s4 = 16, s6 = 24, s8 = 32 }
Theme.radius = { sm = 8, md = 10, lg = 12, xl = 14, xl2 = 22, full = 999 }
Theme.stroke = { thin = 2, normal = 3, heavy = 4 }
Theme.size = { tapMin = 44, thumbBtn = 64, orb = 28 }

function Theme.upper(s: string): string
	return string.upper(s)
end

function Theme.corner(parent: Instance, radius: number): UICorner
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
	return c
end

function Theme.outline(parent: Instance, thickness: number?, color: Color3?): UIStroke
	local s = Instance.new("UIStroke")
	s.Color = color or Theme.color.night900
	s.Thickness = thickness or Theme.stroke.normal
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
	return s
end

function Theme.padding(parent: Instance, px: number, py: number?): UIPadding
	local p = Instance.new("UIPadding")
	p.PaddingLeft = UDim.new(0, px)
	p.PaddingRight = UDim.new(0, px)
	p.PaddingTop = UDim.new(0, py or px)
	p.PaddingBottom = UDim.new(0, py or px)
	p.Parent = parent
	return p
end

-- Soft top-to-bottom shade used for the toy-like bevel: `lift` lightens the top edge.
function Theme.gradient(parent: Instance, lift: number?): UIGradient
	local g = Instance.new("UIGradient")
	local amount = lift or 0.12
	g.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.new(1 - amount, 1 - amount, 1 - amount))
	g.Rotation = 90
	g.Parent = parent
	return g
end

-- A TextScaled label capped at a style size (README: MaxTextSize = style size, Min 10).
function Theme.text(parent: Instance, size: number, color: Color3?, display: boolean?): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = if display == false then Theme.body else Theme.display
	l.TextColor3 = color or Theme.color.ink
	l.TextScaled = true
	l.Size = UDim2.fromScale(1, 1)
	local limit = Instance.new("UITextSizeConstraint")
	limit.MaxTextSize = size
	limit.MinTextSize = Theme.MIN_TEXT
	limit.Parent = l
	l.Parent = parent
	return l
end

-- Body text: BuilderSans, never below 12 px.
function Theme.bodyText(parent: Instance, size: number, color: Color3?): TextLabel
	return Theme.text(parent, size, color or Theme.color.inkDim, false)
end

-- Panel: indigo fill, 3 px night-900 outline, radius-xl, top bevel.
function Theme.panel(parent: Instance, name: string, size: UDim2, position: UDim2, fill: Color3?): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.Size = size
	f.Position = position
	f.BackgroundColor3 = fill or Theme.color.panel
	f.BorderSizePixel = 0
	Theme.corner(f, Theme.radius.xl)
	Theme.outline(f, Theme.stroke.normal)
	Theme.gradient(f, 0.08)
	f.Parent = parent
	return f
end

-- Chunky button. The face shades top to bottom; the label is navy on any accent fill.
-- Presses shrink the face a hair (no tween, so reduced motion is respected by default).
function Theme.button(parent: Instance, name: string, text: string, fill: Color3, size: UDim2): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.Size = size
	b.BackgroundColor3 = fill
	b.Text = ""
	b.AutoButtonColor = false
	Theme.corner(b, Theme.radius.lg)
	Theme.outline(b, Theme.stroke.normal)
	Theme.gradient(b, 0.14)
	b.Parent = parent
	local t = Theme.text(b, Theme.type.buttonText, Theme.color.onAccent)
	t.Name = "Title"
	t.Text = text
	t.Size = UDim2.new(1, -10, 1, -8)
	t.Position = UDim2.fromOffset(5, 4)
	local scale = Instance.new("UIScale")
	scale.Parent = b
	b.MouseButton1Down:Connect(function()
		scale.Scale = 0.95
	end)
	local function release()
		scale.Scale = 1
	end
	b.MouseButton1Up:Connect(release)
	b.MouseLeave:Connect(release)
	return b
end

-- Pill / chip: night-900 2 px outline, radius-md, text inside. Returns the frame and its label.
function Theme.chip(parent: Instance, name: string, text: string, fill: Color3, textColor: Color3?): (Frame, TextLabel)
	local f = Instance.new("Frame")
	f.Name = name
	f.BackgroundColor3 = fill
	f.BorderSizePixel = 0
	f.Size = UDim2.fromOffset(160, 26)
	Theme.corner(f, Theme.radius.md)
	Theme.outline(f, Theme.stroke.thin)
	Theme.gradient(f, 0.08)
	f.Parent = parent
	local t = Theme.bodyText(f, Theme.type.caption + 2, textColor or Theme.color.ink)
	t.Name = "Text"
	t.Text = text
	t.Size = UDim2.new(1, -12, 1, -4)
	t.Position = UDim2.fromOffset(6, 2)
	return f, t
end

export type Bar = { track: Frame, fill: Frame, set: (share: number, full: boolean) -> () }

-- Progress bar: sunken well, thin outline, glow fill with a deep lower band; `full` turns it gold.
function Theme.bar(parent: Instance, name: string, height: number): Bar
	local track = Instance.new("Frame")
	track.Name = name
	track.Size = UDim2.new(1, 0, 0, height)
	track.BackgroundColor3 = Theme.color.panelSunken
	track.BorderSizePixel = 0
	Theme.corner(track, Theme.radius.sm)
	Theme.outline(track, Theme.stroke.thin)
	track.Parent = parent
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = Theme.color.glow
	fill.BorderSizePixel = 0
	Theme.corner(fill, Theme.radius.sm)
	Theme.gradient(fill, 0.22)
	fill.Parent = track
	return {
		track = track,
		fill = fill,
		set = function(share: number, full: boolean)
			fill.Size = UDim2.fromScale(math.clamp(share, 0, 1), 1)
			fill.BackgroundColor3 = if full then Theme.color.gold else Theme.color.glow
		end,
	}
end

-- The Glow orb: a glow disc with a deep rim, drawn from shapes (no art asset yet).
function Theme.orb(parent: Instance, diameter: number): Frame
	local o = Instance.new("Frame")
	o.Name = "Orb"
	o.Size = UDim2.fromOffset(diameter, diameter)
	o.BackgroundColor3 = Theme.color.glow
	o.BorderSizePixel = 0
	Theme.corner(o, Theme.radius.full)
	Theme.outline(o, Theme.stroke.thin, Theme.color.glowDeep)
	Theme.gradient(o, 0.25)
	o.Parent = parent
	return o
end

-- Full-screen scrim for popups.
function Theme.scrim(parent: Instance, name: string): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.Size = UDim2.fromScale(1, 1)
	f.BackgroundColor3 = Theme.color.night950
	f.BackgroundTransparency = Theme.scrimTransparency
	f.BorderSizePixel = 0
	f.Parent = parent
	return f
end

return Theme
