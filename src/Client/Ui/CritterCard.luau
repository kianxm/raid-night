--!strict
--[[
	CritterCard (owner: ui agent): the collection card from Collection.dc.html as shapes, shared by
	the Bag and Den screens. Portrait disc in the tier colour, name, tier tag, one caption line.
	Pure drawing from Theme: no requests, no state.
]]

local Theme = require(script.Parent:WaitForChild("Theme"))

local CritterCard = {}

export type Info = {
	name: string,
	tier: string?, -- nil draws the empty-pad look
	caption: string,
}

CritterCard.WIDTH = 104
CritterCard.HEIGHT = 108

local function tierColor(tier: string?): Color3
	return if tier then Theme.color.tier[tier] or Theme.color.tier.Common else Theme.color.line
end

local function text(parent: Instance, size: number, color: Color3, y: number, h: number): TextLabel
	local l = Theme.bodyText(parent, size, color)
	l.Size = UDim2.new(1, -8, 0, h)
	l.Position = UDim2.fromOffset(4, y)
	l.ZIndex = 10
	return l
end

-- The tier-coloured silhouette disc on a sunken tile (the design's `rn-portrait` placeholder).
function CritterCard.portrait(parent: Instance, tier: string?, diameter: number): Frame
	local tile = Instance.new("Frame")
	tile.Name = "Portrait"
	tile.Size = UDim2.fromOffset(diameter, diameter)
	tile.BackgroundColor3 = Theme.color.panelSunken
	tile.BorderSizePixel = 0
	tile.ZIndex = 10
	Theme.corner(tile, Theme.radius.lg)
	Theme.outline(tile, Theme.stroke.thin)
	local disc = Instance.new("Frame")
	disc.Name = "Disc"
	disc.AnchorPoint = Vector2.new(0.5, 0.5)
	disc.Position = UDim2.fromScale(0.5, 0.58)
	disc.Size = UDim2.fromScale(0.6, 0.6)
	disc.BackgroundColor3 = tierColor(tier)
	disc.BorderSizePixel = 0
	disc.ZIndex = 11
	Theme.corner(disc, Theme.radius.full)
	disc.Parent = tile
	tile.Parent = parent
	return tile
end

-- Uppercase tier tag: tier fill, navy text, small radius.
function CritterCard.tag(parent: Instance, tier: string, width: number): Frame
	local f, t = Theme.chip(parent, "Tag", Theme.upper(tier), tierColor(tier), Theme.color.onAccent)
	f.Size = UDim2.fromOffset(width, 18)
	f.ZIndex = 10
	t.ZIndex = 11
	return f
end

-- A tappable card. `selected` swaps the rim to white and thickens it; an empty card (no tier)
-- is sunken with a dim name.
function CritterCard.button(parent: Instance, order: number, info: Info, selected: boolean): TextButton
	local b = Instance.new("TextButton")
	b.Name = "Card"
	b.LayoutOrder = order
	b.Text = ""
	b.AutoButtonColor = false
	b.BackgroundColor3 = if info.tier then Theme.color.panelRaised else Theme.color.panelSunken
	b.BorderSizePixel = 0
	b.ZIndex = 9
	Theme.corner(b, Theme.radius.lg)
	Theme.outline(
		b,
		if selected then Theme.stroke.heavy else Theme.stroke.normal,
		if selected then Theme.color.ink else tierColor(info.tier)
	)
	if info.tier then
		CritterCard.portrait(b, info.tier, 40).Position = UDim2.new(0.5, -20, 0, 6)
		text(b, Theme.type.label, Theme.color.ink, 48, 16).Text = info.name
		local tag = CritterCard.tag(b, info.tier, 72)
		tag.Position = UDim2.new(0.5, -36, 0, 66)
		text(b, Theme.type.caption, Theme.color.inkMute, 88, 14).Text = info.caption
	else
		text(b, Theme.type.label, Theme.color.inkMute, 44, 18).Text = info.name
	end
	b.Parent = parent
	return b
end

return CritterCard
