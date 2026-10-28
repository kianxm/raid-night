--!strict
--[[
	CritterCatalog: read-only lookups over Data/Critters.luau, plus catalog validation.
	`validate()` runs in tests and at server start; a broken catalog must never ship.
]]

local Types = require("./Types")
local Config = require("./Config")
local critterList = require("./Data/Critters")

type CritterSpecies = Types.CritterSpecies
type Tier = Types.Tier

local CritterCatalog = {}

CritterCatalog.TIER_ORDER = table.freeze({
	"Common",
	"Uncommon",
	"Rare",
	"Epic",
	"Legendary",
	"Mythic",
	"Secret",
}) :: { Tier }

local tierRank: { [string]: number } = {}
for index, tier in CritterCatalog.TIER_ORDER do
	tierRank[tier] = index
end

-- Inclusive Glow-per-second range allowed for each tier (from the design doc).
CritterCatalog.TIER_GLOW_RANGE = table.freeze({
	Common = { 1, 3 },
	Uncommon = { 5, 10 },
	Rare = { 20, 40 },
	Epic = { 80, 150 },
	Legendary = { 300, 600 },
	Mythic = { 1500, 3000 },
	Secret = { 10000, math.huge },
}) :: { [string]: { number } }

local byId: { [string]: CritterSpecies } = {}
for _, species in critterList do
	byId[species.id] = species
end

function CritterCatalog.get(speciesId: string): CritterSpecies?
	return byId[speciesId]
end

function CritterCatalog.all(): { CritterSpecies }
	return critterList
end

function CritterCatalog.byTier(tier: Tier): { CritterSpecies }
	local result = {}
	for _, species in critterList do
		if species.tier == tier then
			table.insert(result, species)
		end
	end
	return result
end

-- Returns a number you can compare: Common = 1 ... Secret = 7.
function CritterCatalog.tierRank(tier: Tier): number
	return tierRank[tier] or 0
end

-- Checks the catalog against the design rules. Returns a list of problems (empty = valid).
function CritterCatalog.validate(): { string }
	local problems: { string } = {}
	local seen: { [string]: boolean } = {}

	for index, species in critterList do
		local label = `#{index} {species.id}`
		if seen[species.id] then
			table.insert(problems, `{label}: duplicate id`)
		end
		seen[species.id] = true

		if not string.match(species.id, "^[a-z][a-z0-9_]*$") then
			table.insert(problems, `{label}: id must be snake_case`)
		end

		local range = CritterCatalog.TIER_GLOW_RANGE[species.tier]
		if not range then
			table.insert(problems, `{label}: unknown tier {species.tier}`)
		elseif species.glowPerSecond < range[1] or species.glowPerSecond > range[2] then
			table.insert(problems, `{label}: glowPerSecond {species.glowPerSecond} outside {species.tier} range`)
		end

		if species.tier == "Secret" and not species.eventOnly then
			table.insert(problems, `{label}: Secret critters must be eventOnly`)
		end

		if #species.palette < 2 or #species.palette > 4 then
			table.insert(problems, `{label}: palette needs 2-4 colors`)
		end
		for _, color in species.palette do
			if not string.match(color, "^#%x%x%x%x%x%x$") then
				table.insert(problems, `{label}: bad palette color {color}`)
			end
		end

		if #species.look < 20 then
			table.insert(problems, `{label}: look is too short to prompt an artist or model`)
		end
	end

	-- Every egg tier must have at least one species, or egg rolls could land on nothing.
	for _, entry in Config.EggOdds do
		local hasSpecies = false
		for _, species in critterList do
			if species.tier == entry.tier and not species.eventOnly then
				hasSpecies = true
				break
			end
		end
		if not hasSpecies then
			table.insert(problems, `egg tier {entry.tier} has no eligible species`)
		end
	end

	return problems
end

return CritterCatalog
