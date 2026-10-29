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

tests["each label shows the true rounded value (#55)"] = function()
	expect.eq(HudMath.eachLabel(9), "11.11%", "nine")
	expect.eq(HudMath.eachLabel(10), "10%", "ten")
	expect.eq(HudMath.eachLabel(3), "33.33%", "three")
	expect.eq(HudMath.eachLabel(1), "100%", "one")
end

tests["actions column fits phone landscape and portrait (#54)"] = function()
	-- 852x393 landscape minus 36 px top bar = 357 usable.
	local land = HudMath.columnLayout(357)
	expect.eq(land.name, "compact", "landscape layout")
	expect.eq(HudMath.columnHeight(land), 192, "landscape column height")
	expect.eq(HudMath.columnTop(357, land), 45, "landscape top")
	expect.truthy(HudMath.columnTop(357, land) >= HudMath.COLUMN_TOP_MARGIN, "clear of top bar")
	-- Portrait (~393x852, ~760 usable) and default Studio (854) get the roomy layout.
	for _, h in { 760, 854 } do
		local layout = HudMath.columnLayout(h)
		expect.eq(layout.name, "full", `full at {h}`)
		expect.eq(HudMath.columnHeight(layout), 252, "full height")
		expect.truthy(HudMath.columnTop(h, layout) >= HudMath.COLUMN_TOP_MARGIN, `fits at {h}`)
	end
	-- Every height from 320 up fits (compact floor needs 320).
	for h = 320, 900 do
		local layout = HudMath.columnLayout(h)
		expect.truthy(HudMath.columnTop(h, layout) >= HudMath.COLUMN_TOP_MARGIN, `fits at {h}`)
	end
	-- Buttons stay thumb-sized and text readable.
	expect.truthy(land.button >= 44, "compact button >= 44")
end

tests["rescue rule needs no critters and low Glow"] = function()
	expect.eq(HudMath.isRescue(0, 0, 0, 100), true, "fresh")
	expect.eq(HudMath.isRescue(1, 0, 0, 100), false, "has critter")
	expect.eq(HudMath.isRescue(0, 90, 10, 100), false, "can afford")
end

return tests
