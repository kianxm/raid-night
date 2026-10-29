--!strict
--[[
	InventoryMath (owner: ui agent): pure helpers for the Bag and Den screens. Works on the
	critter lists the server already sent (Net.DenState.critters). Display only; the server
	re-checks every placement. No Roblox services, so Lune can test it.
]]

local InventoryMath = {}

local TIER_RANK: { [string]: number } = {
	Common = 1,
	Uncommon = 2,
	Rare = 3,
	Epic = 4,
	Legendary = 5,
	Mythic = 6,
	Secret = 7,
}

export type Critter = {
	uid: string,
	speciesId: string,
	mutation: string,
	placement: string,
	padIndex: number?,
	acquiredAt: number,
}

export type Slot = { index: number, critter: Critter? }

-- Critters in one placement, rarest first, then oldest, then uid so the order never jumps.
-- `tierOf` maps a species id to its tier name (the controller passes CritterCatalog).
function InventoryMath.inPlacement(critters: { Critter }, placement: string, tierOf: (string) -> string?): { Critter }
	local out = {}
	for _, c in critters do
		if c.placement == placement then
			table.insert(out, c)
		end
	end
	table.sort(out, function(a: Critter, b: Critter): boolean
		local ra = TIER_RANK[tierOf(a.speciesId) or ""] or 0
		local rb = TIER_RANK[tierOf(b.speciesId) or ""] or 0
		if ra ~= rb then
			return ra > rb
		end
		if a.acquiredAt ~= b.acquiredAt then
			return a.acquiredAt < b.acquiredAt
		end
		return a.uid < b.uid
	end)
	return out
end

-- One slot per usable pad (1..usable), with whoever stands on it.
function InventoryMath.padSlots(critters: { Critter }, usable: number): { Slot }
	local slots: { Slot } = {}
	for i = 1, usable do
		slots[i] = { index = i, critter = nil }
	end
	for _, c in critters do
		local pad = c.padIndex
		if c.placement == "Pad" and pad ~= nil and slots[pad] ~= nil then
			slots[pad].critter = c
		end
	end
	return slots
end

function InventoryMath.firstFreePad(critters: { Critter }, usable: number): number?
	for _, slot in InventoryMath.padSlots(critters, usable) do
		if slot.critter == nil then
			return slot.index
		end
	end
	return nil
end

function InventoryMath.count(critters: { Critter }, placement: string): number
	local n = 0
	for _, c in critters do
		if c.placement == placement then
			n += 1
		end
	end
	return n
end

return InventoryMath
