--!strict
local expect = require("../lib/expect")
local Economy = require("../../src/Shared/Economy")
local Config = require("../../src/Shared/Config")
local HudMath = require("../../src/Client/Hud/HudMath")

local tests = {}

local function sum(labels: { string }): number
	local total = 0
	for _, l in labels do
		total += tonumber((string.gsub(l, "%%", ""))) :: number
	end
	return total
end

local function chancesFor(tier: string): { number }
	local chances = {}
	for _, o in Economy.eggTierOdds(tier :: any) do
		table.insert(chances, o.chance)
	end
	return chances
end

tests["launch egg odds show 68.75% and 31.25%"] = function()
	local labels = HudMath.percentLabels(chancesFor(Config.Economy.eggMaxTier))
	expect.eq(labels[1], "68.75%", "common")
	expect.eq(labels[2], "31.25%", "uncommon")
end

tests["rescue odds show 100%"] = function()
	expect.eq(HudMath.percentLabels({ 1 })[1], "100%", "rescue")
end

tests["labels sum to 100 for every cap"] = function()
	for _, tier in { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic" } do
		expect.near(sum(HudMath.percentLabels(chancesFor(tier))), 100, 1e-6, `sum for {tier}`)
	end
	expect.near(sum(HudMath.percentLabels({ 1 / 3, 1 / 3, 1 / 3 })), 100, 1e-6, "thirds")
end

tests["rescue rule needs no critters and low Glow"] = function()
	expect.eq(HudMath.isRescue(0, 0, 0, 100), true, "fresh")
	expect.eq(HudMath.isRescue(1, 0, 0, 100), false, "has critter")
	expect.eq(HudMath.isRescue(0, 90, 10, 100), false, "can afford")
end

return tests
