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
local Net = require("./Net")

type PlayerProfile = Types.PlayerProfile
type Critter = Types.Critter
type Tier = Types.Tier
type Mutation = Types.Mutation
type Placement = Types.Placement
type CritterSpecies = Types.CritterSpecies

-- Everything an egg purchase needs from outside the pure world. The server fills it from a
-- server Random and HttpService; tests fill it by hand.
export type EggRoll = {
	tierRoll: number, -- uniform in [0, 1)
	speciesRoll: number, -- uniform in [0, 1)
	uid: string, -- fresh globally unique id for the new critter
	maxTier: Tier, -- highest tier a paid egg can hatch (Config.Economy.eggMaxTier); rescue eggs ignore it
	physicalPads: number, -- pads that exist in the den world (6)
}

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
	local base = species.glowPerSecond
		* Economy.mutationMultiplier(critter.mutation)
		* Economy.rebirthMultiplier(rebirths)
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

-- Like rollTier, but only tiers up to `maxTier` can hatch. Their weights keep their published
-- ratios (renormalised to sum to 1), so the capped egg is the launch egg minus the top tiers.
function Economy.rollTierUpTo(roll: number, maxTier: Tier): Tier
	local maxRank = CritterCatalog.tierRank(maxTier)
	local total = 0
	for _, entry in Config.EggOdds do
		if CritterCatalog.tierRank(entry.tier :: Tier) <= maxRank then
			total += entry.weight
		end
	end
	local cumulative = 0
	local last: Tier = "Common"
	for _, entry in Config.EggOdds do
		local tier = entry.tier :: Tier
		if CritterCatalog.tierRank(tier) <= maxRank then
			cumulative += entry.weight / total
			last = tier
			if roll < cumulative then
				return tier
			end
		end
	end
	return last -- rounding sliver at the top
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

-- Storage cap in Glow (not seconds) at the den's current rate and level.
function Economy.storageCap(profile: PlayerProfile): number
	return Economy.denRate(profile) * Economy.storageCapSeconds(profile.denLevel)
end

-- Pads a player can actually use: unlocked by level AND built in the world.
function Economy.usablePadCount(denLevel: number, physicalPads: number): number
	return math.max(0, math.min(Economy.padCount(denLevel), physicalPads))
end

function Economy.padOccupant(profile: PlayerProfile, padIndex: number): Critter?
	for _, critter in profile.critters do
		if critter.placement == "Pad" and critter.padIndex == padIndex then
			return critter
		end
	end
	return nil
end

-- Lowest usable pad with nothing on it, or nil when every usable pad is taken.
function Economy.firstFreePad(profile: PlayerProfile, physicalPads: number): number?
	for pad = 1, Economy.usablePadCount(profile.denLevel, physicalPads) do
		if not Economy.padOccupant(profile, pad) then
			return pad
		end
	end
	return nil
end

function Economy.vaultCount(profile: PlayerProfile): number
	local count = 0
	for _, critter in profile.critters do
		if critter.placement == "Vault" then
			count += 1
		end
	end
	return count
end

--[[
	Moves an owned critter to a Pad (with `padIndex`), the Vault or Inventory. A critter moved
	onto an occupied pad swaps with the occupant, which takes the mover's old spot, so no slot
	limit can be broken by a swap. Guard placement is not available yet (no guard slots exist).
	Accrues first. Returns false and a reason, without changing anything, if the move is invalid.
]]
function Economy.place(
	profile: PlayerProfile,
	uid: string,
	placement: Placement,
	padIndex: number?,
	physicalPads: number,
	now: number
): (boolean, string?)
	local critter = profile.critters[uid]
	if not critter then
		return false, "not your critter"
	end
	local occupant: Critter? = nil
	if placement == "Pad" then
		local usable = Economy.usablePadCount(profile.denLevel, physicalPads)
		if type(padIndex) ~= "number" or padIndex % 1 ~= 0 or padIndex < 1 or padIndex > usable then
			return false, "pad is locked or does not exist"
		end
		occupant = Economy.padOccupant(profile, padIndex)
	elseif placement == "Vault" then
		if critter.placement ~= "Vault" and Economy.vaultCount(profile) >= profile.vaultSlots then
			return false, "vault is full"
		end
	elseif placement ~= "Inventory" then
		return false, "placement not available"
	end

	Economy.accrue(profile, now)
	if occupant and occupant ~= critter then
		occupant.placement = critter.placement
		occupant.padIndex = critter.padIndex
	end
	critter.placement = placement
	critter.padIndex = if placement == "Pad" then padIndex else nil
	return true, nil
end

-- Spends banked Glow to raise the den one level. Accrues first so the old storage cap applies
-- to time already earned.
function Economy.upgradeDen(profile: PlayerProfile, now: number): (boolean, string?)
	local cost = Economy.upgradeCost(profile.denLevel)
	if cost == nil then
		return false, "den is at max level"
	end
	if profile.glow < cost then
		return false, "not enough Glow"
	end
	Economy.accrue(profile, now)
	profile.glow -= cost
	profile.denLevel += 1
	return true, nil
end

--[[
	Rescue egg (decision D-004): a player with no critters at all and not enough Glow (banked plus
	stored) for an egg gets their next egg free. This is how a new player starts (Profile.new gives
	0 Glow and no critters), and it means nobody can be raided into a dead end. It cannot be
	farmed: nothing sells critters, so the only way back to zero critters is losing them all.

	It hatches from its own fixed table (RESCUE_EGG_TIER, Common only), whatever eggMaxTier says,
	and the critter it hatches is never tradeable (decision D-005).

	`stored` must be current: call accrue(profile, now) first (buyEgg, IncomeService's push and its
	GetDenState handler all do), so Glow earned but not yet accrued counts as affordable.
]]
local RESCUE_EGG_TIER: Tier = "Common"

function Economy.isRescueEgg(profile: PlayerProfile): boolean
	return next(profile.critters) == nil
		and math.floor(profile.glow + profile.stored) < Economy.eggPrice(profile.denLevel)
end

-- What the next egg costs this player in banked Glow (0 for a rescue egg). Accrue first.
function Economy.eggCost(profile: PlayerProfile): number
	return if Economy.isRescueEgg(profile) then 0 else Economy.eggPrice(profile.denLevel)
end

--[[
	Buys and hatches one egg. Accrues first, so the rescue check sees every Glow earned so far.
	A paid egg costs eggPrice from banked Glow and rolls a tier capped at roll.maxTier; a rescue
	egg is free, rolls Common only and is marked untradeable. Either way a species is rolled within
	the tier and the critter goes on the first free usable pad, or in Inventory if none.
	Returns the new critter, or nil and a reason with no Glow spent and no critter added (storage
	may have been accrued, which changes no balance).
]]
function Economy.buyEgg(profile: PlayerProfile, now: number, roll: EggRoll): (Critter?, string?)
	Economy.accrue(profile, now)
	local rescue = Economy.isRescueEgg(profile)
	local cost = if rescue then 0 else Economy.eggPrice(profile.denLevel)
	if profile.glow < cost then
		return nil, "not enough Glow"
	end
	if profile.critters[roll.uid] ~= nil then
		return nil, "uid already exists" -- never overwrite a critter
	end
	local tier = if rescue then RESCUE_EGG_TIER else Economy.rollTierUpTo(roll.tierRoll, roll.maxTier)
	local species = Economy.rollSpecies(tier, roll.speciesRoll)
	if not species then
		return nil, "no species for that tier"
	end

	profile.glow -= cost
	local pad = Economy.firstFreePad(profile, roll.physicalPads)
	local critter: Critter = {
		uid = roll.uid,
		speciesId = species.id,
		mutation = "None",
		placement = if pad then "Pad" else "Inventory",
		padIndex = pad,
		acquiredAt = now,
		stolenLockUntil = nil,
		untradeable = if rescue then true else nil,
	}
	profile.critters[critter.uid] = critter
	return critter, nil
end

-- The client's view of a den. Call accrue first so `stored` is current. Critters are copies,
-- ordered oldest first (then by uid) so the client gets a stable list.
function Economy.denState(profile: PlayerProfile): Net.DenState
	local critters: { Critter } = {}
	for _, critter in profile.critters do
		table.insert(critters, table.clone(critter))
	end
	table.sort(critters, function(a: Critter, b: Critter): boolean
		if a.acquiredAt ~= b.acquiredAt then
			return a.acquiredAt < b.acquiredAt
		end
		return a.uid < b.uid
	end)
	return {
		glow = profile.glow,
		stored = profile.stored,
		storageCap = Economy.storageCap(profile),
		ratePerSecond = Economy.denRate(profile),
		denLevel = profile.denLevel,
		rebirths = profile.rebirths,
		shieldUntil = profile.shieldUntil,
		critters = critters,
	}
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
