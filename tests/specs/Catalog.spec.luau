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

-- A copy of the real catalog with one species changed, for checking that validate() rejects it.
local function withChange(change: (any) -> ()): { any }
	local list = table.clone(CritterCatalog.all())
	local species = table.clone(list[1])
	change(species)
	list[1] = species
	return list
end

local function problemsMention(list: { any }, needle: string): boolean
	for _, problem in CritterCatalog.validate(list) do
		if string.find(problem, needle, 1, true) then
			return true
		end
	end
	return false
end

tests["validate rejects a malformed personality"] = function()
	for _, bad in { "", "Smug", "very regal indeed", "-", "a-", "a--b", " smug", "smug ", "a  b" } do
		local list = withChange(function(species)
			species.personality = bad
		end)
		expect.truthy(problemsMention(list, "personality must be"), `"{bad}" accepted`)
	end
	for _, good in { "smug", "all-knowing", "quietly smug" } do
		local list = withChange(function(species)
			species.personality = good
		end)
		expect.falsy(problemsMention(list, "personality must be"), `"{good}" rejected`)
	end
end

tests["validate rejects distressed personalities and idles"] = function()
	for _, bad in { "sad", "very sad", "startled", "scaredy-cat" } do
		local list = withChange(function(species)
			species.personality = bad
		end)
		expect.truthy(problemsMention(list, "is distressed"), `"{bad}" accepted`)
	end
	local list = withChange(function(species)
		species.idle = "drops its crumb and panics"
	end)
	expect.truthy(problemsMention(list, "idle shows distress"), "panicking idle accepted")
end

tests["validate caps how many critters share a personality"] = function()
	local list = table.clone(CritterCatalog.all())
	local function shareFirst(count: number)
		for i = 1, count do
			local species = table.clone(list[i])
			species.personality = "cheerful-test"
			list[i] = species
		end
	end
	shareFirst(CritterCatalog.MAX_SHARED_PERSONALITY)
	expect.falsy(problemsMention(list, "cheerful-test"), "cap itself rejected")
	shareFirst(CritterCatalog.MAX_SHARED_PERSONALITY + 1)
	expect.truthy(problemsMention(list, "cheerful-test"), "cap + 1 accepted")
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
