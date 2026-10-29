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

tests["personalities vary: every critter has one and at most 6 share one"] = function()
	local counts: { [string]: number } = {}
	local distinct = 0
	for _, species in CritterCatalog.all() do
		expect.truthy(type(species.personality) == "string" and #species.personality > 0, `{species.id} personality`)
		if not counts[species.personality] then
			distinct += 1
		end
		counts[species.personality] = (counts[species.personality] or 0) + 1
	end
	for personality, count in counts do
		expect.truthy(count <= CritterCatalog.MAX_SHARED_PERSONALITY, `"{personality}" shared by {count}`)
	end
	expect.truthy(distinct >= math.ceil(40 / CritterCatalog.MAX_SHARED_PERSONALITY), "distinct personalities")
end

tests["no personality is distressed"] = function()
	for _, species in CritterCatalog.all() do
		for word in string.gmatch(species.personality, "[a-z]+") do
			expect.falsy(CritterCatalog.FORBIDDEN_PERSONALITY_WORDS[word], `{species.id} is "{species.personality}"`)
		end
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
