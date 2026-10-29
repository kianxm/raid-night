--!strict
-- The world-art seam and the part budget (P2.3).
local expect = require("../lib/expect")
local WorldKit = require("../../src/Shared/WorldKit")
local Economy = require("../../src/Shared/Economy")
local Config = require("../../src/Shared/Config")
local Plots = require("../../src/Shared/Plots")
local RaidRules = require("../../src/Shared/RaidRules")

local L = Plots.Layout
local B = WorldKit.Budget
local MAX_LEVEL = Config.Economy.maxDenLevel

-- assets/kit/manifest.json on agent/assets/P2.2 (PR #122), copied by hand: every id must be a
-- kit piece so the manifest maps 1:1.
local MANIFEST = {
	"barrel",
	"bench",
	"crate_stack",
	"den_base",
	"fence_segment",
	"lamp_post",
	"mailbox",
	"pad",
	"plaza",
	"rock_cluster",
	"shrub",
	"trap_alarm_moth",
	"trap_net",
	"trap_slow_puddle",
	"trap_sprinkler",
	"trap_trapdoor",
	"tree_small",
	"vault_door",
	"wheelbarrow",
}

local tests = {}

-- The seam ---------------------------------------------------------------------------------------

tests["every manifest id is a kit piece"] = function()
	for _, id in MANIFEST do
		expect.truthy(WorldKit.Pieces[id], `manifest id {id} has no kit piece`)
	end
end

tests["no art yet: every asset id is 0, so the greybox builds (D-057)"] = function()
	for name, info in WorldKit.Pieces do
		expect.eq(info.assetId, 0, name)
	end
end

tests["pieces are well formed"] = function()
	for name, info in WorldKit.Pieces do
		expect.truthy(info.role == "Anchor" or info.role == "Decor", `{name} role`)
		expect.truthy(info.parts >= 0 and info.parts % 1 == 0, `{name} parts`)
		expect.truthy(info.artParts >= 1 and info.artParts % 1 == 0, `{name} artParts`)
		if info.role == "Anchor" then
			expect.eq(info.parts, 1, `{name}: an Anchor is one placeholder part`)
		else
			expect.falsy(info.keepAnchor, `{name}: only Anchors keep a placeholder`)
		end
		expect.truthy(string.match(name, "^[a-z][a-z_]*$") ~= nil, `{name} is snake_case like the manifest`)
	end
end

tests["every trap kind has its kit piece, named like the manifest"] = function()
	expect.eq(WorldKit.trapPiece("SlowPuddle"), "trap_slow_puddle")
	expect.eq(WorldKit.trapPiece("AlarmMoth"), "trap_alarm_moth")
	expect.eq(WorldKit.trapPiece("Net"), "trap_net")
	expect.eq(#WorldKit.TrapKinds, 5)
	for _, kind in WorldKit.TrapKinds do
		local piece = WorldKit.Pieces[WorldKit.trapPiece(kind)]
		expect.truthy(piece and piece.role == "Anchor", `trap {kind}`)
	end
end

tests["street props are kit pieces and stand clear of dens, the plaza and the lamps"] = function()
	local seen = {}
	for _, spot in WorldKit.PropSpots do
		expect.truthy(WorldKit.Pieces[spot.piece], spot.piece)
		expect.falsy(seen[spot.piece], `{spot.piece} placed twice`)
		seen[spot.piece] = true
		expect.eq(Plots.plotAt(spot.x, spot.z), nil, `{spot.piece} is in a den`)
		for plot = 1, L.plotCount do
			local cx, cz = Plots.center(plot)
			local dx = math.max(math.abs(spot.x - cx) - L.plotSize / 2, 0)
			local dz = math.max(math.abs(spot.z - cz) - L.plotSize / 2, 0)
			expect.truthy(math.sqrt(dx * dx + dz * dz) >= 3, `{spot.piece} crowds den {plot}`)
		end
		expect.truthy(math.sqrt(spot.x ^ 2 + spot.z ^ 2) > L.plazaRadius + 3, `{spot.piece} on the plaza`)
		local lampZ = L.rowOffset - L.plotSize / 2 - 4
		for _, lamp in { { -1, -1 }, { -1, 1 }, { 1, -1 }, { 1, 1 } } do
			local d = math.sqrt((spot.x - lamp[1] * L.plotSpacing) ^ 2 + (spot.z - lamp[2] * lampZ) ^ 2)
			expect.truthy(d > 6, `{spot.piece} on a street lamp`)
		end
		expect.truthy(math.abs(spot.x) <= 156 and math.abs(spot.z) <= 116, `{spot.piece} off the ground`)
	end
	expect.eq(#WorldKit.PropSpots, 9, "the manifest's 10 props: 9 spots + lamp_post (the lamps)")
end

-- Pads follow the den level -------------------------------------------------------------------------

tests["shown pads follow Economy.padCount: 6 at level 1, 30 by the top level"] = function()
	expect.eq(WorldKit.shownPads(1), 6)
	expect.eq(WorldKit.shownPads(MAX_LEVEL), L.maxPads)
	local last = WorldKit.shownPads(1)
	for level = 2, MAX_LEVEL do
		local n = WorldKit.shownPads(level)
		expect.eq(n, Economy.padCount(level), `level {level}`)
		expect.truthy(n >= last and n - last <= 1, `level {level}: at most one new pad per level`)
		last = n
	end
end

tests["the layout has room for every pad Economy can unlock"] = function()
	for level = 1, MAX_LEVEL do
		expect.truthy(Economy.padCount(level) <= L.maxPads, `level {level}`)
		expect.eq(Economy.usablePadCount(level, L.maxPads), WorldKit.shownPads(level), `level {level} usable`)
	end
end

-- Budget -------------------------------------------------------------------------------------------

tests["den world parts: 18 at level 1, 41 at 30 pads (no next-pad marker)"] = function()
	expect.eq(WorldKit.denWorldParts(6), 18)
	expect.eq(WorldKit.denWorldParts(29), 41)
	expect.eq(WorldKit.denWorldParts(30), 41)
end

tests["every den level, full of critters, fits the den and map budgets"] = function()
	for level = 1, MAX_LEVEL do
		local pads = WorldKit.shownPads(level)
		local den = WorldKit.denCost(pads, pads)
		expect.truthy(den.parts <= B.denParts, `level {level}: {den.parts} parts`)
		expect.truthy(den.instances <= B.denInstances, `level {level}: {den.instances} instances`)
		local withArt = WorldKit.denCost(pads, pads, true)
		expect.truthy(withArt.parts <= B.denPartsWithArt, `level {level} with art: {withArt.parts} parts`)
		local map = WorldKit.mapCost(pads, pads)
		expect.truthy(map.parts <= B.mapParts, `level {level}: map {map.parts} parts`)
		expect.truthy(map.instances <= B.mapInstances, `level {level}: map {map.instances} instances`)
		expect.truthy(map.lights <= B.mapLights, `level {level}: map {map.lights} lights`)
		local mapArt = WorldKit.mapCost(pads, pads, true)
		expect.truthy(mapArt.parts <= B.mapPartsWithArt, `level {level}: map with art {mapArt.parts} parts`)
	end
end

tests["the worst case main map: 8 dens at 30 pads, 30 critters each"] = function()
	local map = WorldKit.mapCost(30, 30)
	expect.eq(WorldKit.denCost(30, 30).parts, 105)
	expect.eq(map.parts, 11 + 8 * 105)
	expect.eq(map.lights, 12, "4 street lamps + 8 den lanterns, no pad lights")
	expect.eq(map.guis, 8 * 31, "a sign per den and a name tag per critter")
end

tests["costs clamp silly inputs"] = function()
	expect.eq(WorldKit.denCost(99, 99).parts, WorldKit.denCost(30, 30).parts)
	expect.eq(WorldKit.denCost(6, 50).parts, WorldKit.denCost(6, 6).parts, "no more critters than pads")
	expect.eq(WorldKit.denCost(-1, -1).parts, WorldKit.denCost(0, 0).parts)
end

tests["pocket dens fit their budget at their fullest"] = function()
	local Pk = RaidRules.Pocket
	expect.eq(WorldKit.pocketParts(6, 4, 2), 24, "the example in Pocket.luau")
	expect.eq(WorldKit.pocketParts(Pk.maxPads, Pk.maxTraps, Pk.maxGuards), 82)
	expect.truthy(WorldKit.pocketParts(Pk.maxPads, Pk.maxTraps, Pk.maxGuards) <= B.pocketParts, "greybox")
	local art = WorldKit.pocketParts(Pk.maxPads, Pk.maxTraps, Pk.maxGuards, true)
	expect.truthy(art <= B.pocketPartsWithArt, `with art: {art}`)
	expect.eq(WorldKit.pocketParts(99, 99, 99), 82, "clamped to the rules' maximums")
end

tests["partsOf refuses an unknown piece"] = function()
	expect.throws(function()
		WorldKit.partsOf("not_a_piece")
	end)
end

return tests
