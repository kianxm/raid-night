--!strict
--[[
	CritterVisuals (owner: economy agent): pure rules for how a critter looks in the world.
	No Roblox APIs: the server builder (Server/Economy/CritterView) and a client idle animator read
	these tables and turn them into instances, so every choice here is tested under Lune.

	  source(ids)                    which body to draw: "model", "mesh" or "placeholder"
	  tierLook(tier)                 size, glow light, particles and aura for a tier (style bible:
	                                 glow and particles scale with tier; Common soft glow and no
	                                 particles, Rare a few motes, Legendary+ an aura, Secret unique)
	  mutationLook(mutation)         the in-engine mutation effect (style bible): Shiny sparkle
	                                 overlay, Moonlit pale blue rim light, Haunted translucent with
	                                 green wisps, Golden gold material swap
	  effects(tier, mutation)        the named effects the builder adds, in build order
	  idleFor(tier, hasAnimation)    the den idle: a gentle bob and sway, none when the real model
	                                 brings its own idle animation
	  idleOffset(t, idle, phase, reducedMotion)
	                                 (lift studs, yaw radians) at time t; (0, 0) with reduced motion
	  phaseFor(uid)                  a stable phase so neighbours never bob in sync

	Effects apply to either body, so a real model drops in with no code change. Colors are hex
	strings ("#RRGGBB"); the builder turns them into Color3.
]]

local Types = require("./Types")
local Config = require("./Config")
local CritterModels = require("./Data/CritterModels")

type Tier = Types.Tier
type Mutation = Types.Mutation
type CritterSpecies = Types.CritterSpecies
export type ModelIds = CritterModels.ModelIds

export type Source = "model" | "mesh" | "placeholder"
export type Aura = "none" | "aura" | "secret"

export type TierLook = {
	height: number, -- studs: a real model is scaled to this height (pipeline: 2-4 studs by tier)
	placeholderSize: number, -- studs: the placeholder body's diameter
	placeholderShape: "Ball" | "Block",
	lightBrightness: number, -- PointLight in the glow color
	lightRange: number,
	moteRate: number, -- glow motes per second; 0 = no particles
	aura: Aura,
}

export type MutationLook = {
	multiplier: number, -- Config.Mutations, shown on the name tag (income reads Config, not this)
	sparkleColor: string?, -- Shiny: sparkle overlay color
	rimColor: string?, -- Moonlit: rim shell and light color
	transparency: number, -- Haunted: body transparency (glow parts get half); 0 = opaque
	wispColor: string?, -- Haunted: rising wisps color
	goldColor: string?, -- Golden: color of the material swap
	goldMaterial: string?, -- Golden: Enum.Material name of the swap
}

export type Idle = {
	bobStuds: number, -- how high the critter lifts at the top of a bob (never below its pad)
	bobSeconds: number, -- one full bob
	swayDegrees: number, -- yaw either side of its facing
	swaySeconds: number, -- one full sway
}

local CritterVisuals = {}

-- Ordered like CritterCatalog.TIER_ORDER. Glow, particles and size never shrink with tier.
local TIER_LOOKS: { [Tier]: TierLook } = {
	Common = {
		height = 2,
		placeholderSize = 1.8,
		placeholderShape = "Ball",
		lightBrightness = 0.6,
		lightRange = 6,
		moteRate = 0,
		aura = "none",
	},
	Uncommon = {
		height = 2.4,
		placeholderSize = 2.4,
		placeholderShape = "Block", -- tells Common and Uncommon placeholders apart at a glance
		lightBrightness = 0.9,
		lightRange = 7,
		moteRate = 0,
		aura = "none",
	},
	Rare = {
		height = 2.8,
		placeholderSize = 3,
		placeholderShape = "Ball",
		lightBrightness = 1.4,
		lightRange = 9,
		moteRate = 3,
		aura = "none",
	},
	Epic = {
		height = 3.2,
		placeholderSize = 3.6,
		placeholderShape = "Ball",
		lightBrightness = 2,
		lightRange = 11,
		moteRate = 6,
		aura = "none",
	},
	Legendary = {
		height = 3.6,
		placeholderSize = 4.4,
		placeholderShape = "Ball",
		lightBrightness = 3,
		lightRange = 14,
		moteRate = 8,
		aura = "aura",
	},
	Mythic = {
		height = 4,
		placeholderSize = 5.2,
		placeholderShape = "Ball",
		lightBrightness = 4,
		lightRange = 16,
		moteRate = 12,
		aura = "aura",
	},
	Secret = {
		height = 4,
		placeholderSize = 6,
		placeholderShape = "Ball",
		lightBrightness = 5,
		lightRange = 18,
		moteRate = 16,
		aura = "secret",
	},
}

local MOONLIT_BLUE = "#BFE3FF"
local HAUNTED_GREEN = "#7CFFB2"
local GOLD = "#FFC93C"
local SPARKLE_WHITE = "#FFF6D8"

local function mutationMultiplier(mutation: Mutation): number
	return (Config.Mutations :: any)[mutation] or 1
end

local MUTATION_LOOKS: { [Mutation]: MutationLook } = {
	None = { multiplier = mutationMultiplier("None"), transparency = 0 },
	Shiny = { multiplier = mutationMultiplier("Shiny"), sparkleColor = SPARKLE_WHITE, transparency = 0 },
	Moonlit = { multiplier = mutationMultiplier("Moonlit"), rimColor = MOONLIT_BLUE, transparency = 0 },
	Haunted = { multiplier = mutationMultiplier("Haunted"), wispColor = HAUNTED_GREEN, transparency = 0.45 },
	Golden = {
		multiplier = mutationMultiplier("Golden"),
		goldColor = GOLD,
		goldMaterial = "Foil",
		transparency = 0,
	},
}

-- Effects a mutation adds, in build order. Material effects (fade, swap) change the body's parts;
-- the rest are instances added to it.
local MUTATION_EFFECTS: { [Mutation]: { string } } = {
	None = {},
	Shiny = { "ShinySparkles" },
	Moonlit = { "MoonlitRim", "MoonlitLight" },
	Haunted = { "HauntedFade", "HauntedWisps" },
	Golden = { "GoldenSwap" },
}

for _, look in TIER_LOOKS do
	table.freeze(look)
end
for _, look in MUTATION_LOOKS do
	table.freeze(look)
end
for _, list in MUTATION_EFFECTS do
	table.freeze(list)
end

-- Which body to draw for a species' imported ids: a packaged model wins, then a bare mesh, else
-- the procedural placeholder. An id must be a positive whole number to count.
local function validId(id: number?): boolean
	return type(id) == "number" and id > 0 and id == math.floor(id) and id < math.huge
end

function CritterVisuals.source(ids: ModelIds?): Source
	if ids == nil then
		return "placeholder"
	end
	if validId(ids.model) then
		return "model"
	end
	if validId(ids.mesh) then
		return "mesh"
	end
	return "placeholder"
end

-- The imported ids for a species, or nil (it draws as a placeholder).
function CritterVisuals.idsFor(speciesId: string): ModelIds?
	return CritterModels[speciesId]
end

-- An unknown tier draws like Common, so a bad row never breaks a den.
function CritterVisuals.tierLook(tier: Tier): TierLook
	return TIER_LOOKS[tier] or TIER_LOOKS.Common
end

-- An unknown mutation draws like None.
function CritterVisuals.mutationLook(mutation: Mutation): MutationLook
	return MUTATION_LOOKS[mutation] or MUTATION_LOOKS.None
end

-- Every named effect for this tier and mutation, in build order: the tier's glow light, motes
-- and aura first, then the mutation's.
function CritterVisuals.effects(tier: Tier, mutation: Mutation): { string }
	local look = CritterVisuals.tierLook(tier)
	local list = { "TierLight" }
	if look.moteRate > 0 then
		table.insert(list, "TierMotes")
	end
	if look.aura == "aura" then
		table.insert(list, "TierAura")
	elseif look.aura == "secret" then
		table.insert(list, "SecretAura")
	end
	for _, name in MUTATION_EFFECTS[mutation] or MUTATION_EFFECTS.None do
		table.insert(list, name)
	end
	return list
end

-- Scale that fits a model `currentHeight` studs tall to its tier's height. 1 when the height is
-- unusable (zero, negative, NaN or infinite), so a broken import is drawn as-is, not crushed.
function CritterVisuals.fitScale(currentHeight: number, tier: Tier): number
	if not (currentHeight > 0 and currentHeight < math.huge) then
		return 1
	end
	return CritterVisuals.tierLook(tier).height / currentHeight
end

-- The ONE glowing feature (style bible): the placeholder's "Glow" part, or a real model's part
-- named "<id>_glow" (pipeline naming). Mutations keep it glowing: Golden skips it, Haunted fades
-- it only half as much.
function CritterVisuals.isGlowPartName(name: string): boolean
	local lower = string.lower(name)
	return lower == "glow" or string.sub(lower, -5) == "_glow"
end

-- Body transparency for a part under this mutation.
function CritterVisuals.partTransparency(mutation: Mutation, isGlow: boolean): number
	local t = CritterVisuals.mutationLook(mutation).transparency
	return if isGlow then t / 2 else t
end

-- Name tag text: "<Mutation> <Name>" on top (just the name without one), tier and multiplier
-- below. Multipliers show as "×1.5"; whole ones drop the decimal.
function CritterVisuals.labelText(species: CritterSpecies, mutation: Mutation): string
	local look = CritterVisuals.mutationLook(mutation)
	if mutation == "None" or look.multiplier == 1 then
		return `{species.name}\n{species.tier}`
	end
	local m = look.multiplier
	local shown = if m == math.floor(m) then tostring(math.floor(m)) else string.format("%.1f", m)
	return `{mutation} {species.name}\n{species.tier} · ×{shown}`
end

-- Idle --------------------------------------------------------------------------------------------

local BOB_SECONDS = 2.4
local SWAY_SECONDS = 5

-- Bigger critters bob a little more. A real model with its own idle animation gets no extra
-- motion (its animation is the idle).
function CritterVisuals.idleFor(tier: Tier, hasAnimation: boolean): Idle
	if hasAnimation then
		return { bobStuds = 0, bobSeconds = BOB_SECONDS, swayDegrees = 0, swaySeconds = SWAY_SECONDS }
	end
	local height = CritterVisuals.tierLook(tier).height
	return {
		bobStuds = 0.15 * height,
		bobSeconds = BOB_SECONDS,
		swayDegrees = 12,
		swaySeconds = SWAY_SECONDS,
	}
end

-- (lift, yaw) at time `t` seconds. Lift runs 0..bobStuds (never into the pad); yaw runs
-- -sway..+sway in radians. Reduced motion (or a zero idle) holds still at (0, 0).
function CritterVisuals.idleOffset(t: number, idle: Idle, phase: number, reducedMotion: boolean): (number, number)
	if reducedMotion then
		return 0, 0
	end
	local lift = 0
	if idle.bobStuds > 0 and idle.bobSeconds > 0 then
		lift = idle.bobStuds * (1 - math.cos(2 * math.pi * t / idle.bobSeconds + phase)) / 2
	end
	local yaw = 0
	if idle.swayDegrees ~= 0 and idle.swaySeconds > 0 then
		yaw = math.rad(idle.swayDegrees) * math.sin(2 * math.pi * t / idle.swaySeconds + phase)
	end
	return lift, yaw
end

-- A stable phase in [0, 2*pi) from a critter uid (FNV-1a), so the same critter always idles the
-- same way and a row of critters never bobs in sync.
function CritterVisuals.phaseFor(uid: string): number
	local hash = 2166136261
	for i = 1, #uid do
		hash = bit32.bxor(hash, string.byte(uid, i))
		-- hash * 16777619 mod 2^32, split (16777619 = 2^24 + 403) so no step passes 2^53.
		hash = (bit32.lshift(hash, 24) + hash * 403) % 4294967296
	end
	return (hash % 3600) / 3600 * 2 * math.pi
end

return CritterVisuals
