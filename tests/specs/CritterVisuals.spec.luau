--!strict
--[[
	CritterVisuals and Data/CritterModels (P2.4): body source selection, tier and mutation looks,
	effect selection, idle motion, and the ids.json mirror.
]]

local fs = require("@lune/fs")
local serde = require("@lune/serde")

local expect = require("../lib/expect")
local Types = require("../../src/Shared/Types")
local Config = require("../../src/Shared/Config")
local CritterCatalog = require("../../src/Shared/CritterCatalog")
local CritterModels = require("../../src/Shared/Data/CritterModels")
local CritterVisuals = require("../../src/Shared/CritterVisuals")

type Tier = Types.Tier
type Mutation = Types.Mutation

local MUTATIONS: { Mutation } = { "None", "Shiny", "Moonlit", "Haunted", "Golden" }
local ID_FIELDS = { "model", "mesh", "texture", "icon", "animation" }
local CLEAN = "assets/clean"

local function has(list: { string }, name: string): boolean
	return table.find(list, name) ~= nil
end

local tests = {}

-- Body source (the real-model seam) -------------------------------------------------------------

tests["no ids, or no usable id, draws the placeholder"] = function()
	expect.eq(CritterVisuals.source(nil), "placeholder", "nil")
	expect.eq(CritterVisuals.source({}), "placeholder", "empty")
	expect.eq(CritterVisuals.source({ icon = 5, texture = 6, animation = 7 }), "placeholder", "no body id")
	for _, bad in { 0, -3, 1.5, math.huge, 0 / 0 } do
		expect.eq(CritterVisuals.source({ mesh = bad }), "placeholder", `mesh {bad}`)
		expect.eq(CritterVisuals.source({ model = bad }), "placeholder", `model {bad}`)
	end
end

tests["a packaged model wins over a mesh, and a mesh over the placeholder"] = function()
	expect.eq(CritterVisuals.source({ mesh = 11 }), "mesh", "mesh only")
	expect.eq(CritterVisuals.source({ mesh = 11, texture = 12 }), "mesh", "mesh + texture")
	expect.eq(CritterVisuals.source({ model = 21 }), "model", "model only")
	expect.eq(CritterVisuals.source({ model = 21, mesh = 11 }), "model", "both")
	expect.eq(CritterVisuals.source({ model = -1, mesh = 11 }), "mesh", "bad model falls back to mesh")
end

tests["every species without ids draws as a placeholder tonight"] = function()
	for _, species in CritterCatalog.all() do
		local ids = CritterVisuals.idsFor(species.id)
		if ids == nil then
			expect.eq(CritterVisuals.source(ids), "placeholder", species.id)
		end
	end
end

tests["CritterModels keys are catalog species and ids are positive whole numbers"] = function()
	expect.truthy(table.isfrozen(CritterModels), "frozen")
	for speciesId, ids in CritterModels do
		expect.truthy(CritterCatalog.get(speciesId) ~= nil, `{speciesId} is a catalog species`)
		for key, value in ids :: any do
			expect.truthy(table.find(ID_FIELDS, key) ~= nil, `{speciesId}: unknown field {key}`)
			expect.truthy(type(value) == "number" and value > 0 and value == math.floor(value), `{speciesId}.{key}`)
		end
		expect.truthy(CritterVisuals.source(ids) ~= "placeholder", `{speciesId} has a model or mesh id`)
	end
end

-- Every assets/clean/<id>/ids.json is mirrored exactly in CritterModels, and every entry has one.
tests["CritterModels mirrors assets/clean/<id>/ids.json"] = function()
	local mirrored: { [string]: boolean } = {}
	if fs.isDir(CLEAN) then
		for _, name in fs.readDir(CLEAN) do
			local path = `{CLEAN}/{name}/ids.json`
			if fs.isDir(`{CLEAN}/{name}`) and fs.isFile(path) then
				mirrored[name] = true
				local decoded = serde.decode("json", fs.readFile(path)) :: { [string]: any }
				local entry = CritterModels[name] :: any
				expect.truthy(entry ~= nil, `{path} exists but CritterModels has no {name} entry`)
				if entry then
					for _, key in ID_FIELDS do
						local fileValue = decoded[key]
						if fileValue ~= nil then
							fileValue = tonumber(fileValue)
						end
						expect.eq(entry[key], fileValue, `{name}.{key} matches ids.json`)
					end
				end
			end
		end
	end
	for speciesId in CritterModels do
		expect.truthy(mirrored[speciesId], `CritterModels.{speciesId} has no {CLEAN}/{speciesId}/ids.json`)
	end
end

-- Tier looks --------------------------------------------------------------------------------------

tests["glow, particles and size never shrink as the tier rises"] = function()
	local previous: CritterVisuals.TierLook? = nil
	for _, tier in CritterCatalog.TIER_ORDER do
		local look = CritterVisuals.tierLook(tier)
		expect.truthy(look.height >= 2 and look.height <= 4, `{tier} height within the pipeline's 2-4 studs`)
		if previous then
			expect.truthy(look.height >= previous.height, `{tier} height`)
			expect.truthy(look.placeholderSize > previous.placeholderSize, `{tier} placeholder size grows`)
			expect.truthy(look.lightBrightness > previous.lightBrightness, `{tier} glow brighter`)
			expect.truthy(look.lightRange >= previous.lightRange, `{tier} light range`)
			expect.truthy(look.moteRate >= previous.moteRate, `{tier} motes`)
		end
		previous = look
	end
end

tests["Common has soft glow and no particles; Rare gets motes; Legendary+ an aura; Secret its own"] = function()
	for _, tier in { "Common", "Uncommon" } :: { Tier } do
		local fx = CritterVisuals.effects(tier, "None")
		expect.eq(#fx, 1, `{tier} has only its glow light`)
		expect.eq(fx[1], "TierLight", tier)
	end
	for _, tier in { "Rare", "Epic" } :: { Tier } do
		local fx = CritterVisuals.effects(tier, "None")
		expect.truthy(has(fx, "TierMotes"), `{tier} motes`)
		expect.falsy(has(fx, "TierAura") or has(fx, "SecretAura"), `{tier} has no aura`)
	end
	for _, tier in { "Legendary", "Mythic" } :: { Tier } do
		local fx = CritterVisuals.effects(tier, "None")
		expect.truthy(has(fx, "TierMotes") and has(fx, "TierAura"), `{tier} motes and aura`)
		expect.falsy(has(fx, "SecretAura"), `{tier} is not Secret`)
	end
	local secret = CritterVisuals.effects("Secret", "None")
	expect.truthy(has(secret, "SecretAura"), "Secret aura")
	expect.falsy(has(secret, "TierAura"), "Secret's aura is unique, not the shared one")
end

tests["an unknown tier or mutation draws like Common / None"] = function()
	expect.eq(CritterVisuals.tierLook("Nope" :: any), CritterVisuals.tierLook("Common"), "tier")
	expect.eq(CritterVisuals.mutationLook("Nope" :: any), CritterVisuals.mutationLook("None"), "mutation")
	local fx = CritterVisuals.effects("Nope" :: any, "Nope" :: any)
	expect.eq(#fx, 1, "only the glow light")
end

-- Mutations ---------------------------------------------------------------------------------------

tests["every mutation in Config has a look, with the design's multiplier"] = function()
	local want = { None = 1, Shiny = 1.5, Moonlit = 2, Haunted = 3, Golden = 5 }
	for _, mutation in MUTATIONS do
		expect.eq((Config.Mutations :: any)[mutation], want[mutation], `Config {mutation}`)
		expect.eq(CritterVisuals.mutationLook(mutation).multiplier, want[mutation], `look {mutation}`)
	end
	for mutation in Config.Mutations do
		expect.truthy(table.find(MUTATIONS, mutation :: any) ~= nil, `{mutation} is drawn`)
	end
end

tests["each mutation adds exactly its style-bible effect, on every tier"] = function()
	local own: { [Mutation]: { string } } = {
		None = {},
		Shiny = { "ShinySparkles" },
		Moonlit = { "MoonlitRim", "MoonlitLight" },
		Haunted = { "HauntedFade", "HauntedWisps" },
		Golden = { "GoldenSwap" },
	}
	local allMutationEffects: { string } = {}
	for _, list in own do
		for _, name in list do
			table.insert(allMutationEffects, name)
		end
	end
	for _, tier in CritterCatalog.TIER_ORDER do
		local base = CritterVisuals.effects(tier, "None")
		for _, mutation in MUTATIONS do
			local fx = CritterVisuals.effects(tier, mutation)
			expect.eq(#fx, #base + #own[mutation], `{tier} {mutation} count`)
			for i, name in base do
				expect.eq(fx[i], name, `{tier} {mutation}: tier effects come first`)
			end
			for i, name in own[mutation] do
				expect.eq(fx[#base + i], name, `{tier} {mutation} effect {i}`)
			end
			for _, name in allMutationEffects do
				if not has(own[mutation], name) then
					expect.falsy(has(fx, name), `{tier} {mutation} must not have {name}`)
				end
			end
		end
	end
end

tests["mutation looks: sparkle, pale blue rim, translucent green, gold swap"] = function()
	local shiny = CritterVisuals.mutationLook("Shiny")
	expect.truthy(shiny.sparkleColor ~= nil and shiny.transparency == 0, "Shiny sparkles, opaque")
	local moonlit = CritterVisuals.mutationLook("Moonlit")
	expect.eq(moonlit.rimColor, "#BFE3FF", "Moonlit pale blue")
	local haunted = CritterVisuals.mutationLook("Haunted")
	expect.truthy(haunted.transparency > 0 and haunted.transparency < 1, "Haunted is see-through but visible")
	expect.eq(haunted.wispColor, "#7CFFB2", "Haunted green wisps")
	local golden = CritterVisuals.mutationLook("Golden")
	expect.eq(golden.goldColor, "#FFC93C", "gold")
	expect.eq(golden.goldMaterial, "Foil", "gold material")
	for _, mutation in MUTATIONS do
		local look = CritterVisuals.mutationLook(mutation)
		for _, color in { look.sparkleColor, look.rimColor, look.wispColor, look.goldColor } do
			expect.truthy(string.match(color :: string, "^#%x%x%x%x%x%x$") ~= nil, `{mutation} color {color}`)
		end
		expect.truthy(table.isfrozen(look), `{mutation} look is frozen`)
	end
end

tests["the glow feature keeps glowing: found by name, faded half as much"] = function()
	for _, name in { "Glow", "glow", "dusk_mouse_glow", "Dusk_Mouse_GLOW" } do
		expect.truthy(CritterVisuals.isGlowPartName(name), name)
	end
	for _, name in { "Body", "dusk_mouse_mesh", "glowing_ears", "Glow2" } do
		expect.falsy(CritterVisuals.isGlowPartName(name), name)
	end
	expect.eq(CritterVisuals.partTransparency("Haunted", false), 0.45, "Haunted body")
	expect.eq(CritterVisuals.partTransparency("Haunted", true), 0.225, "Haunted glow")
	for _, mutation in { "None", "Shiny", "Moonlit", "Golden" } :: { Mutation } do
		expect.eq(CritterVisuals.partTransparency(mutation, false), 0, `{mutation} opaque`)
	end
end

tests["name tags show the mutation and its multiplier"] = function()
	local species = CritterCatalog.get("dusk_mouse") :: Types.CritterSpecies
	expect.eq(CritterVisuals.labelText(species, "None"), "Dusk Mouse\nCommon", "none")
	expect.eq(CritterVisuals.labelText(species, "Shiny"), "Shiny Dusk Mouse\nCommon · ×1.5", "shiny")
	expect.eq(CritterVisuals.labelText(species, "Moonlit"), "Moonlit Dusk Mouse\nCommon · ×2", "moonlit")
	expect.eq(CritterVisuals.labelText(species, "Haunted"), "Haunted Dusk Mouse\nCommon · ×3", "haunted")
	expect.eq(CritterVisuals.labelText(species, "Golden"), "Golden Dusk Mouse\nCommon · ×5", "golden")
end

-- Real-model fit ----------------------------------------------------------------------------------

tests["a real model is scaled to its tier height; unusable heights are left alone"] = function()
	expect.near(CritterVisuals.fitScale(4, "Common"), 0.5, 1e-12, "4 studs -> 2")
	expect.near(CritterVisuals.fitScale(2, "Mythic"), 2, 1e-12, "2 studs -> 4")
	for _, bad in { 0, -1, 0 / 0, math.huge } do
		expect.eq(CritterVisuals.fitScale(bad, "Rare"), 1, `height {bad}`)
	end
end

-- Idle --------------------------------------------------------------------------------------------

tests["idle bobs above the pad and sways both ways, and holds still with reduced motion"] = function()
	for _, tier in CritterCatalog.TIER_ORDER do
		local idle = CritterVisuals.idleFor(tier, false)
		expect.truthy(idle.bobStuds > 0 and idle.swayDegrees > 0, `{tier} moves`)
		local minLift, maxLift, minYaw, maxYaw = math.huge, -math.huge, math.huge, -math.huge
		for i = 0, 999 do
			local t = i / 1000 * 30
			local lift, yaw = CritterVisuals.idleOffset(t, idle, 1.3, false)
			minLift, maxLift = math.min(minLift, lift), math.max(maxLift, lift)
			minYaw, maxYaw = math.min(minYaw, yaw), math.max(maxYaw, yaw)
			local stillLift, stillYaw = CritterVisuals.idleOffset(t, idle, 1.3, true)
			expect.eq(stillLift, 0, "reduced motion lift")
			expect.eq(stillYaw, 0, "reduced motion yaw")
		end
		expect.truthy(minLift >= 0, `{tier} never sinks into the pad ({minLift})`)
		expect.truthy(maxLift <= idle.bobStuds + 1e-9, `{tier} lift capped`)
		expect.near(maxLift, idle.bobStuds, 0.01, `{tier} reaches the top of the bob`)
		expect.truthy(minYaw < 0 and maxYaw > 0, `{tier} sways both ways`)
		expect.truthy(maxYaw <= math.rad(idle.swayDegrees) + 1e-9, `{tier} sway capped`)
	end
end

tests["a real model with its own idle animation gets no extra bob or sway"] = function()
	local idle = CritterVisuals.idleFor("Mythic", true)
	for _, t in { 0, 0.7, 1.9, 12.5 } do
		local lift, yaw = CritterVisuals.idleOffset(t, idle, 2, false)
		expect.eq(lift, 0, `lift at {t}`)
		expect.eq(yaw, 0, `yaw at {t}`)
	end
end

tests["idle loops on its period and phase is stable per uid"] = function()
	local idle = CritterVisuals.idleFor("Rare", false)
	local a1 = CritterVisuals.idleOffset(0.4, idle, 0.5, false)
	local a2 = CritterVisuals.idleOffset(0.4 + idle.bobSeconds, idle, 0.5, false)
	expect.near(a1, a2, 1e-9, "bob loops")
	local p = CritterVisuals.phaseFor("ABCDEF-1234")
	expect.eq(CritterVisuals.phaseFor("ABCDEF-1234"), p, "same uid, same phase")
	local distinct: { [number]: boolean } = {}
	local count = 0
	for i = 1, 200 do
		local phase = CritterVisuals.phaseFor(`uid-{i}`)
		expect.truthy(phase >= 0 and phase < 2 * math.pi, `phase {phase} in range`)
		if not distinct[phase] then
			distinct[phase] = true
			count += 1
		end
	end
	expect.truthy(count >= 180, `phases spread out ({count} distinct of 200)`)
	expect.truthy(CritterVisuals.phaseFor("") >= 0, "empty uid")
end

return tests
