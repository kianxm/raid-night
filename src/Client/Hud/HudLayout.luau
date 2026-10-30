--!strict
--[[
	HudLayout (owner: ui agent): pure layout math for the redesigned den HUD (P2.13a). No Roblox
	APIs, so it is tested in Lune. Phone landscape (Main.dc.html, 932x430) vs PC (DeskMain.dc.html,
	1440x900) is chosen from input devices, never from screen size alone: a tablet with touch is a
	phone layout, a small PC window is still the PC layout (just a tighter hotbar).
]]

local HudLayout = {}

export type Mode = "phone" | "desktop"

-- Hotbar actions in slot order. Keys 1-5 are the den actions (Collect is the in-world prompt, per the PC canvas note); Lockdown sits apart on Q.
export type Slot = { action: string, keyName: string, keyLabel: string, apart: boolean }

HudLayout.SLOTS = {
	{ action = "eggs", keyName = "One", keyLabel = "1", apart = false },
	{ action = "raid", keyName = "Two", keyLabel = "2", apart = false },
	{ action = "shop", keyName = "Three", keyLabel = "3", apart = false },
	{ action = "critters", keyName = "Four", keyLabel = "4", apart = false },
	{ action = "defenses", keyName = "Five", keyLabel = "5", apart = false },
	{ action = "lockdown", keyName = "Q", keyLabel = "Q", apart = true },
} :: { Slot }

-- Any touch device gets the phone layout; the PC hotbar and its keybinds need a keyboard and no touch.
function HudLayout.mode(touchEnabled: boolean, keyboardEnabled: boolean): Mode
	if keyboardEnabled and not touchEnabled then
		return "desktop"
	end
	return "phone"
end

HudLayout.PHONE = {
	inset = 10, -- screen-edge inset; tighter than space-4 so the thumb zones stay free on 852 px phones
	glowHeight = 92,
	glowMinWidth = 190,
	glowMaxWidth = 280,
	chipY = 106, -- protection chip, under the Glow panel
	stripY = 138, -- menu strip, under the chip
}

HudLayout.DESKTOP = {
	inset = 16,
	glowHeight = 104,
	glowWidth = 300,
	hotbarBottom = 16,
	hintReserve = 230, -- right side kept for the Space/Shift hint
}

export type Hotbar = {
	slotSize: number,
	gap: number,
	apartGap: number,
	width: number,
	left: number, -- x of the first slot from the left edge (bar is centered)
	xs: { number }, -- left x of each slot, parallel to SLOTS
}

HudLayout.HOTBAR_MAX = 76
HudLayout.HOTBAR_MIN = 48

-- Slots are square, centered, and shrink until the bar fits between the Glow counter (bottom-left)
-- and the key hints (bottom-right). The Q slot gets a wider gap so it reads as separate.
function HudLayout.hotbar(viewWidth: number): Hotbar
	local side = math.max(HudLayout.DESKTOP.inset + HudLayout.DESKTOP.glowWidth, HudLayout.DESKTOP.hintReserve)
	local available = math.max(0, viewWidth - 2 * side)
	local count = #HudLayout.SLOTS
	local gap, apartGap = 8, 22
	local size = HudLayout.HOTBAR_MAX
	local function total(s: number): number
		return count * s + (count - 2) * gap + apartGap
	end
	while size > HudLayout.HOTBAR_MIN and total(size) > available do
		size -= 2
	end
	local width = total(size)
	local left = math.floor((viewWidth - width) / 2)
	local xs: { number } = {}
	local x = left
	for i = 1, count do
		xs[i] = x
		local nextApart = i < count and HudLayout.SLOTS[i + 1].apart
		x += size + (if nextApart then apartGap else gap)
	end
	return { slotSize = size, gap = gap, apartGap = apartGap, width = width, left = left, xs = xs }
end

-- The storage bar turns gold when full (StorageFull.dc.html); otherwise Glow-cyan.
function HudLayout.storageTone(share: number): "full" | "normal"
	return if share >= 1 then "full" else "normal"
end

return HudLayout
