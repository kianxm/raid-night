--!strict
local expect = require("../lib/expect")
local CritterCatalog = require("../../src/Shared/CritterCatalog")
local Config = require("../../src/Shared/Config")

local tests = {}

tests["catalog passes every design rule"] = function()
	local problems = CritterCatalog.validate()
	expect.eq(#problems, 0, `catalog problems: {table.concat(problems, "; ")}`)
end

tests["launch mix is 40 critters in the planned tier counts"] = function()
	expect.eq(#CritterCatalog.all(), 40, "total critters")
	local expected = { Common = 10, Uncommon = 9, Rare = 8, Epic = 6, Legendary = 4, Mythic = 2, Secret = 1 }
	for tier, count in expected do
		expect.eq(#CritterCatalog.byTier(tier :: any), count, `{tier} count`)
	end
end

tests["egg odds sum to exactly 1"] = function()
	local total = 0
	for _, entry in Config.EggOdds do
		total += entry.weight
	end
	expect.near(total, 1, 1e-9, "egg odds total")
end

tests["tier rank orders Common below Secret"] = function()
	expect.truthy(CritterCatalog.tierRank("Common") < CritterCatalog.tierRank("Secret"))
	expect.truthy(CritterCatalog.tierRank("Legendary") < CritterCatalog.tierRank("Mythic"))
end

return tests
