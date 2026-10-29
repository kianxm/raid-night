--!strict
local expect = require("../lib/expect")
local InventoryMath = require("../../src/Client/Hud/InventoryMath")

local tests = {}

local function critter(uid: string, species: string, placement: string, pad: number?, at: number): any
	return { uid = uid, speciesId = species, mutation = "None", placement = placement, padIndex = pad, acquiredAt = at }
end

local function tierOf(id: string): string?
	return if id == "big" then "Rare" else "Common"
end

tests["bag lists rarest first, then oldest"] = function()
	local list = {
		critter("a", "small", "Inventory", nil, 5),
		critter("b", "big", "Inventory", nil, 9),
		critter("c", "small", "Inventory", nil, 1),
		critter("d", "small", "Pad", 1, 0),
	}
	local bag = InventoryMath.inPlacement(list, "Inventory", tierOf)
	expect.eq(#bag, 3, "only inventory")
	expect.eq(bag[1].uid, "b", "rare first")
	expect.eq(bag[2].uid, "c", "then oldest")
end

tests["pad slots and first free pad"] = function()
	local list = { critter("a", "small", "Pad", 1, 0), critter("b", "small", "Pad", 3, 0) }
	local slots = InventoryMath.padSlots(list, 4)
	expect.eq(#slots, 4, "one slot per usable pad")
	expect.eq((slots[3].critter :: any).uid, "b", "pad 3")
	expect.eq(InventoryMath.firstFreePad(list, 4), 2, "lowest free")
	expect.eq(InventoryMath.firstFreePad(list, 1), nil, "full")
end

tests["a pad index beyond the usable count is ignored"] = function()
	local slots = InventoryMath.padSlots({ critter("a", "small", "Pad", 9, 0) }, 2)
	expect.eq(slots[1].critter, nil, "empty")
	expect.eq(InventoryMath.count({ critter("a", "small", "Vault", nil, 0) }, "Vault"), 1, "count")
end

return tests
