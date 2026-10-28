--!strict
--[[
	Economy: pure income, storage, pricing and rebirth math. No Roblox APIs, no I/O, no clock:
	every function takes `now` as an argument so it can be tested and replayed.

	Core invariant: ALWAYS call `accrue(profile, now)` before changing anything that affects the
	den's income rate (placing, moving, removing critters; upgrading the den). Accrual uses the
	current rate for the whole elapsed period, so changing the rate first would pay the new rate
	for time earned at the old one.
]]

local Types = require("./Types")
local Config = require("./Config")
local CritterCatalog = require("./CritterCatalog")

type PlayerProfile = Types.PlayerProfile
type Critter = Types.Critter
type Tier = Types.Tier
type Mutation = Types.Mutation
type CritterSpecies = Types.CritterSpecies

local Economy = {}

function Economy.mutationMultiplier(mutation: Mutation): number
	return (Config.Mutations :: any)[mutation] or 1
end

function Economy.rebirthMultiplier(rebirths: number): number
	return 1 + rebirths * Config.Income.rebirthMultiplierStep
end

-- Glow per second one owned critter contributes, given where it sits.
function Economy.critterRate(critter: Critter, rebirths: number): number
	local species = CritterCatalog.get(critter.speciesId)
	if not species then
		return 0
	end
	local base = species.glowPerSecond * Economy.mutationMultiplier(critter.mutation) * Economy.rebirthMultiplier(rebirths)
	if critter.placement == "Pad" then
		return base
	elseif critter.placement == "Vault" then
		return base * Config.Income.vaultMultiplier
	end
	return 0 -- Guard and Inventory earn nothing
end

-- Total Glow per second for a den.
function Economy.denRate(profile: PlayerProfile): number
	local total = 0
	for _, critter in profile.critters do
		total += Economy.critterRate(critter, profile.rebirths)
	end
	return total
end

-- How many seconds of income the den can hold before it stops filling.
function Economy.storageCapSeconds(denLevel: number): number
	return Config.Income.baseStorageSeconds + (denLevel - 1) * Config.Income.storageSecondsPerLevel
end

-- Number of critter pads unlocked at a den level: 6 at level 1, 30 at level 49+.
function Economy.padCount(denLevel: number): number
	return math.min(30, 6 + math.floor((denLevel - 1) / 2))
end

-- Moves income earned since `storedUpdatedAt` into `stored`, up to the storage cap.
-- Never removes Glow that is already stored, even if the cap shrank. Returns Glow added.
function Economy.accrue(profile: PlayerProfile, now: number): number
	local elapsed = now - profile.storedUpdatedAt
	if elapsed <= 0 then
		return 0
	end
	local rate = Economy.denRate(profile)
	local capAmount = rate * Economy.storageCapSeconds(profile.denLevel)
	local before = profile.stored
	if before < capAmount then
		profile.stored = math.min(capAmount, before + rate * elapsed)
	end
	profile.storedUpdatedAt = now
	return profile.stored - before
end

-- Banks whole Glow from storage into the safe wallet. Returns the amount banked.
function Economy.collect(profile: PlayerProfile, now: number): number
	Economy.accrue(profile, now)
	local amount = math.floor(profile.stored)
	profile.stored -= amount
	profile.glow += amount
	return amount
end

-- Share of the storage cap currently filled, 0..1. Drives the "storage nearly full" notification.
function Economy.storageFillShare(profile: PlayerProfile): number
	local capAmount = Economy.denRate(profile) * Economy.storageCapSeconds(profile.denLevel)
	if capAmount <= 0 then
		return 0
	end
	return math.clamp(profile.stored / capAmount, 0, 1)
end

-- Cost to upgrade from `level` to `level + 1`, or nil at max level.
function Economy.upgradeCost(level: number): number?
	if level >= Config.Economy.maxDenLevel then
		return nil
	end
	return math.floor(Config.Economy.upgradeCostBase * Config.Economy.upgradeCostGrowth ^ (level - 1))
end

function Economy.eggPrice(denLevel: number): number
	return math.floor(Config.Economy.eggPriceBase * Config.Economy.eggPriceGrowth ^ (denLevel - 1))
end

-- Picks an egg tier from a uniform random number in [0, 1).
function Economy.rollTier(roll: number): Tier
	local cumulative = 0
	for _, entry in Config.EggOdds do
		cumulative += entry.weight
		if roll < cumulative then
			return entry.tier :: Tier
		end
	end
	-- Floating-point rounding can leave a sliver at the top; it belongs to the last tier.
	local last = Config.EggOdds[#Config.EggOdds]
	return last.tier :: Tier
end

-- Picks a species uniformly within a tier from a uniform random number in [0, 1).
-- Event-only species are never returned.
function Economy.rollSpecies(tier: Tier, roll: number): CritterSpecies?
	local pool: { CritterSpecies } = {}
	for _, species in CritterCatalog.byTier(tier) do
		if not species.eventOnly then
			table.insert(pool, species)
		end
	end
	if #pool == 0 then
		return nil
	end
	local index = math.clamp(math.floor(roll * #pool) + 1, 1, #pool)
	return pool[index]
end

function Economy.canRebirth(profile: PlayerProfile): boolean
	if profile.denLevel < Config.Economy.maxDenLevel then
		return false
	end
	local minRank = CritterCatalog.tierRank(Config.Economy.rebirthMinTier :: Tier)
	for _, critter in profile.critters do
		local species = CritterCatalog.get(critter.speciesId)
		if species and CritterCatalog.tierRank(species.tier) >= minRank then
			return true
		end
	end
	return false
end

-- Applies a rebirth: Glow and den level reset, critters kept, permanent multiplier and one
-- extra vault slot gained. Critters on pads that no longer exist move to Inventory.
-- Returns false if the profile is not eligible.
function Economy.applyRebirth(profile: PlayerProfile, now: number): boolean
	if not Economy.canRebirth(profile) then
		return false
	end
	profile.glow = 0
	profile.stored = 0
	profile.storedUpdatedAt = now
	profile.denLevel = 1
	profile.rebirths += 1
	profile.vaultSlots += 1
	local pads = Economy.padCount(1)
	for _, critter in profile.critters do
		if critter.placement == "Pad" and (critter.padIndex == nil or critter.padIndex > pads) then
			critter.placement = "Inventory"
			critter.padIndex = nil
		end
	end
	return true
end

return Economy
