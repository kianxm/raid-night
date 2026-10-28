--!strict
local expect = require("../lib/expect")
local fixtures = require("../lib/fixtures")
local rngLib = require("../lib/rng")
local Economy = require("../../src/Shared/Economy")
local Config = require("../../src/Shared/Config")

local NOW = 1_800_000_000

local tests = {}

tests["a pad critter accrues its rate per second"] = function()
	local p = fixtures.veteran(1, NOW)
	fixtures.give(p, fixtures.critter("a", "dusk_mouse")) -- 1 Glow/s
	local added = Economy.accrue(p, NOW + 100)
	expect.eq(added, 100, "added")
	expect.eq(p.stored, 100, "stored")
	expect.eq(p.storedUpdatedAt, NOW + 100, "timestamp moved")
end

tests["vault earns half, guards and inventory earn nothing"] = function()
	local p = fixtures.veteran(1, NOW)
	fixtures.give(p, fixtures.critter("v", "crumb_rat", "Vault")) -- 3/s -> 1.5/s
	fixtures.give(p, fixtures.critter("g", "crumb_rat", "Guard"))
	fixtures.give(p, fixtures.critter("i", "crumb_rat", "Inventory"))
	expect.eq(Economy.denRate(p), 1.5, "rate")
end

tests["mutations and rebirths multiply income"] = function()
	local p = fixtures.veteran(1, NOW)
	local c = fixtures.give(p, fixtures.critter("a", "dusk_mouse"))
	c.mutation = "Golden"
	p.rebirths = 2
	expect.eq(Economy.denRate(p), 1 * 5 * (1 + 2 * Config.Income.rebirthMultiplierStep), "rate")
end

tests["storage stops at the cap"] = function()
	local p = fixtures.veteran(1, NOW)
	fixtures.give(p, fixtures.critter("a", "dusk_mouse"))
	Economy.accrue(p, NOW + 1_000_000)
	expect.eq(p.stored, Economy.storageCapSeconds(p.denLevel), "capped")
end

tests["accrue never removes Glow that is already stored"] = function()
	local p = fixtures.veteran(1, NOW)
	p.stored = 999_999 -- above any cap for an empty den
	Economy.accrue(p, NOW + 10)
	expect.eq(p.stored, 999_999, "stored unchanged")
end

tests["accrue ignores time going backwards"] = function()
	local p = fixtures.veteran(1, NOW)
	fixtures.give(p, fixtures.critter("a", "dusk_mouse"))
	expect.eq(Economy.accrue(p, NOW - 50), 0, "no negative income")
end

tests["collect banks whole Glow and keeps the fraction"] = function()
	local p = fixtures.veteran(1, NOW)
	p.stored = 10.75
	local banked = Economy.collect(p, NOW)
	expect.eq(banked, 10, "banked")
	expect.eq(p.glow, 10, "wallet")
	expect.near(p.stored, 0.75, 1e-9, "fraction stays stored")
end

tests["upgrade cost rises each level and stops at max"] = function()
	local previous = 0
	for level = 1, Config.Economy.maxDenLevel - 1 do
		local cost = Economy.upgradeCost(level)
		expect.truthy(cost and cost > previous, `cost at level {level} should rise`)
		previous = cost :: number
	end
	expect.eq(Economy.upgradeCost(Config.Economy.maxDenLevel), nil, "no upgrade past max")
end

tests["pad count goes from 6 to 30"] = function()
	expect.eq(Economy.padCount(1), 6)
	expect.eq(Economy.padCount(Config.Economy.maxDenLevel), 30)
end

tests["tier rolls hit the exact boundaries"] = function()
	expect.eq(Economy.rollTier(0), "Common")
	expect.eq(Economy.rollTier(0.5499), "Common")
	expect.eq(Economy.rollTier(0.55), "Uncommon")
	expect.eq(Economy.rollTier(0.9999), "Mythic")
end

tests["tier rolls match the published odds over 200,000 rolls"] = function()
	local rng = rngLib.new(42)
	local counts: { [string]: number } = {}
	local n = 200_000
	for _ = 1, n do
		local tier = Economy.rollTier(rng.next())
		counts[tier] = (counts[tier] or 0) + 1
	end
	for _, entry in Config.EggOdds do
		local share = (counts[entry.tier] or 0) / n
		-- Tolerance: 5 standard deviations of a binomial share, so a real bug fails but noise never does.
		local tolerance = 5 * math.sqrt(entry.weight * (1 - entry.weight) / n)
		expect.near(share, entry.weight, tolerance, `{entry.tier} share`)
	end
end

tests["egg rolls never return event-only critters"] = function()
	expect.eq(Economy.rollSpecies("Secret", 0.5), nil, "Secret is event-only")
	for i = 0, 99 do
		local species = Economy.rollSpecies("Mythic", i / 100)
		expect.truthy(species and not species.eventOnly)
	end
end

tests["rebirth needs max level and a Legendary"] = function()
	local p = fixtures.veteran(1, NOW)
	p.denLevel = Config.Economy.maxDenLevel
	fixtures.give(p, fixtures.critter("a", "dusk_mouse"))
	expect.falsy(Economy.canRebirth(p), "no Legendary yet")
	fixtures.give(p, fixtures.critter("b", "storm_hare", "Pad", 20))
	expect.truthy(Economy.canRebirth(p), "now eligible")
end

tests["rebirth resets Glow and level, keeps critters, unseats overflow pads"] = function()
	local p = fixtures.veteran(1, NOW)
	p.denLevel = Config.Economy.maxDenLevel
	p.glow = 1_000_000
	p.stored = 5_000
	fixtures.give(p, fixtures.critter("low", "dusk_mouse", "Pad", 2))
	fixtures.give(p, fixtures.critter("high", "storm_hare", "Pad", 25))
	expect.truthy(Economy.applyRebirth(p, NOW))
	expect.eq(p.glow, 0)
	expect.eq(p.stored, 0)
	expect.eq(p.denLevel, 1)
	expect.eq(p.rebirths, 1)
	expect.eq(p.vaultSlots, 2)
	expect.eq(p.critters["low"].placement, "Pad", "pad 2 still exists")
	expect.eq(p.critters["high"].placement, "Inventory", "pad 25 no longer exists")
end

return tests
