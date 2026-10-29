--!strict
local expect = require("../lib/expect")
local CritterCatalog = require("../../src/Shared/CritterCatalog")
local Prompts = require("../../tools/assets/Prompts")

local tests = {}

tests["every critter has a known body plan, and no art entry is orphaned"] = function()
	local ids = {}
	for _, species in CritterCatalog.all() do
		ids[species.id] = true
		local art = Prompts.ART[species.id]
		expect.truthy(art, `{species.id} has no Prompts.ART entry`)
		expect.truthy(Prompts.BODY_PLANS[art.bodyPlan], `{species.id} has unknown body plan {art.bodyPlan}`)
		expect.truthy(type(art.glow) == "string" and art.glow ~= "", `{species.id} names no glowing feature`)
	end
	for id in Prompts.ART do
		expect.truthy(ids[id], `Prompts.ART has {id}, which is not in the catalog`)
	end
end

tests["prompts never contain hex codes, and always name the body and a single glow"] = function()
	for _, species in CritterCatalog.all() do
		for _, prompt in { Prompts.view(species, "Front"), Prompts.icon(species) } do
			expect.falsy(string.find(prompt, "#", 1, true), `{species.id} prompt contains a hex code`)
			expect.truthy(string.find(prompt, "Body: ", 1, true), `{species.id} prompt names no body plan`)
			expect.truthy(string.find(prompt, "no other glowing parts", 1, true), `{species.id} glow line missing`)
		end
	end
end

tests["rarity raises the wow: Commons get no tier line, every tier from Rare up gets its own"] = function()
	for _, species in CritterCatalog.all() do
		local prompt = Prompts.view(species, "Front")
		if species.tier == "Common" or species.tier == "Uncommon" then
			expect.falsy(string.find(prompt, " tier: ", 1, true), `{species.id} has a tier line`)
		else
			expect.truthy(string.find(prompt, `{species.tier} tier: `, 1, true), `{species.id} lacks its tier line`)
		end
	end
end

tests["the icon prompt never asks for an icon frame"] = function()
	local prompt = Prompts.icon(CritterCatalog.all()[1])
	expect.falsy(string.find(string.lower(prompt), "inventory icon", 1, true), "icon prompt says inventory icon")
end

tests["colorName gives plain words for representative colors"] = function()
	local cases = {
		["#FFFFFF"] = "white",
		["#000000"] = "black",
		["#5B6478"] = "grey",
		["#7FE7FF"] = "light cyan",
		["#0B1026"] = "midnight navy",
		["#E9846A"] = "coral",
		["#8A6A4A"] = "brown",
		["#2A0A3D"] = "deep purple",
		["#EADBC8"] = "cream",
	}
	for hex, name in cases do
		expect.eq(Prompts.colorName(hex), name, hex)
	end
end

return tests
