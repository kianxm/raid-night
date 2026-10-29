--!strict
local expect = require("../lib/expect")
local Config = require("../../src/Shared/Config")
local Economy = require("../../src/Shared/Economy")
local CritterCatalog = require("../../src/Shared/CritterCatalog")
local Types = require("../../src/Shared/Types")

local tests = {}

-- The approved kill-switch contract (docs/contracts.md). Changing it is a contract change.
local EXPECTED_FLAGS = {
	raids = true,
	asyncRaids = false,
	purchases = false,
	trading = false,
	notifications = false,
}

tests["every kill switch exists with its launch default"] = function()
	for name, default in EXPECTED_FLAGS do
		expect.eq((Config.Flags :: any)[name], default, `Flags.{name}`)
	end
end

tests["no unlisted flags and every flag is a boolean"] = function()
	for name, value in Config.Flags :: any do
		expect.truthy(EXPECTED_FLAGS[name] ~= nil, `unexpected flag {name}`)
		expect.eq(type(value), "boolean", `Flags.{name}`)
	end
end

tests["flags are frozen so no service can flip one at runtime"] = function()
	expect.truthy(table.isfrozen(Config.Flags), "Config.Flags is frozen")
	expect.throws(function()
		(Config.Flags :: any).raids = false
	end)
end

-- Boosts: Robux-bought Glow multipliers (decision D-030) ----------------------------------------

-- The approved Config.Boosts keys (docs/contracts.md). Adding or removing one is a contract change.
local BOOST_KEYS = { "vipGlowBonus", "lanternNightGlowBonus", "lanternNightSeconds" }

tests["every boost value is present, finite and non-negative"] = function()
	for _, key in BOOST_KEYS do
		local value = (Config.Boosts :: any)[key]
		expect.eq(type(value), "number", `Boosts.{key}`)
		expect.truthy(value >= 0 and value < math.huge, `Boosts.{key} is finite and non-negative, got {value}`)
	end
end

tests["no unlisted boost keys"] = function()
	for key in Config.Boosts :: any do
		expect.truthy(table.find(BOOST_KEYS, key) ~= nil, `unexpected key Boosts.{key}`)
	end
end

tests["a Lantern Night lasts 15 minutes"] = function()
	expect.eq(Config.Boosts.lanternNightSeconds, 900, "Boosts.lanternNightSeconds")
end

tests["boosts are frozen so no service can change one at runtime"] = function()
	expect.truthy(table.isfrozen(Config.Boosts), "Config.Boosts is frozen")
	expect.throws(function()
		(Config.Boosts :: any).vipGlowBonus = 10
	end)
end

-- Economy.eggMaxTier (decision D-003) -----------------------------------------------------------

tests["eggMaxTier is a tier eggs can hatch"] = function()
	local found = false
	for _, entry in Config.EggOdds do
		found = found or entry.tier == Config.Economy.eggMaxTier
	end
	expect.truthy(found, `eggMaxTier {Config.Economy.eggMaxTier} is in EggOdds`)
end

tests["eggMaxTier is Mythic from Phase 2 and Secret never hatches from an egg"] = function()
	expect.eq(Config.Economy.eggMaxTier, "Mythic", "Phase 2 raised the cap (D-003, P2.4)")
	for _, entry in Config.EggOdds do
		expect.truthy(entry.tier ~= "Secret", "Secret critters are event-only, never in EggOdds")
	end
end

-- Rolls `cap` over a fine grid and checks every tier against `expected` (and nothing above the cap).
local function checkCappedOdds(cap: Types.Tier, expected: { [string]: number })
	local capRank = CritterCatalog.tierRank(cap)
	local steps = 100_000
	local counts: { [string]: number } = {}
	for i = 0, steps - 1 do
		local tier = Economy.rollTierUpTo((i + 0.5) / steps, cap)
		counts[tier] = (counts[tier] or 0) + 1
	end
	for _, roll in { 0, 1 - 1e-12 } do
		expect.truthy(CritterCatalog.tierRank(Economy.rollTierUpTo(roll, cap)) <= capRank, `roll {roll}`)
	end
	for tier in counts do
		expect.truthy(CritterCatalog.tierRank(tier :: Types.Tier) <= capRank, `{tier} is above the cap`)
	end
	for tier, share in expected do
		expect.near((counts[tier] or 0) / steps, share, 1e-3, tier)
	end
end

tests["the Config cap hatches at the published EggOdds weights and never above Mythic"] = function()
	local expected: { [string]: number } = {}
	for _, entry in Config.EggOdds do
		expected[entry.tier] = entry.weight
	end
	checkCappedOdds(Config.Economy.eggMaxTier :: Types.Tier, expected)
end

tests["an Uncommon cap still renormalizes to Common 0.6875 / Uncommon 0.3125"] = function()
	checkCappedOdds("Uncommon", { Common = 0.6875, Uncommon = 0.3125 })
end

return tests
