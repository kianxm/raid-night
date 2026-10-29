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

-- Economy.eggMaxTier (decision D-003) -----------------------------------------------------------

tests["eggMaxTier is a tier eggs can hatch"] = function()
	local found = false
	for _, entry in Config.EggOdds do
		found = found or entry.tier == Config.Economy.eggMaxTier
	end
	expect.truthy(found, `eggMaxTier {Config.Economy.eggMaxTier} is in EggOdds`)
end

tests["capped egg odds renormalize to Common 0.6875 / Uncommon 0.3125 and never exceed the cap"] = function()
	local cap = Config.Economy.eggMaxTier :: Types.Tier
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
	expect.near((counts.Common or 0) / steps, 0.6875, 1e-3, "Common")
	expect.near((counts.Uncommon or 0) / steps, 0.3125, 1e-3, "Uncommon")
end

return tests
