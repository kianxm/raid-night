--!strict
local expect = require("../lib/expect")
local fixtures = require("../lib/fixtures")
local rngLib = require("../lib/rng")
local Economy = require("../../src/Shared/Economy")
local Config = require("../../src/Shared/Config")
local Types = require("../../src/Shared/Types")

local NOW = 1_800_000_000

local tests = {}

tests["a pad critter accrues its rate per second"] = function()
	local p = fixtures.veteran(1, NOW)
	fixtures.give(p, fixtures.critter("a", "dusk_mouse")) -- 1 Glow/s
	local added = Economy.accrue(p, NOW + 100)
	expect.eq(added, 100, "added")
	expect.eq(p.stored, 100, "stored")
	expect.eq(p.storedUpdatedAt, NOW + 100, "timestamp moved")
end

tests["vault earns half, guards and inventory earn nothing"] = function()
	local p = fixtures.veteran(1, NOW)
	fixtures.give(p, fixtures.critter("v", "crumb_rat", "Vault")) -- 3/s -> 1.5/s
	fixtures.give(p, fixtures.critter("g", "crumb_rat", "Guard"))
	fixtures.give(p, fixtures.critter("i", "crumb_rat", "Inventory"))
	expect.eq(Economy.denRate(p), 1.5, "rate")
end

tests["mutations and rebirths multiply income"] = function()
	local p = fixtures.veteran(1, NOW)
	local c = fixtures.give(p, fixtures.critter("a", "dusk_mouse"))
	c.mutation = "Golden"
	p.rebirths = 2
	expect.eq(Economy.denRate(p), 1 * 5 * (1 + 2 * Config.Income.rebirthMultiplierStep), "rate")
end

tests["storage stops at the cap"] = function()
	local p = fixtures.veteran(1, NOW)
	fixtures.give(p, fixtures.critter("a", "dusk_mouse"))
	Economy.accrue(p, NOW + 1_000_000)
	expect.eq(p.stored, Economy.storageCapSeconds(p.denLevel), "capped")
end

tests["accrue never removes Glow that is already stored"] = function()
	local p = fixtures.veteran(1, NOW)
	p.stored = 999_999 -- above any cap for an empty den
	Economy.accrue(p, NOW + 10)
	expect.eq(p.stored, 999_999, "stored unchanged")
end

tests["accrue ignores time going backwards"] = function()
	local p = fixtures.veteran(1, NOW)
	fixtures.give(p, fixtures.critter("a", "dusk_mouse"))
	expect.eq(Economy.accrue(p, NOW - 50), 0, "no negative income")
end

tests["collect banks whole Glow and keeps the fraction"] = function()
	local p = fixtures.veteran(1, NOW)
	p.stored = 10.75
	local banked = Economy.collect(p, NOW)
	expect.eq(banked, 10, "banked")
	expect.eq(p.glow, 10, "wallet")
	expect.near(p.stored, 0.75, 1e-9, "fraction stays stored")
end

tests["upgrade cost rises each level and stops at max"] = function()
	local previous = 0
	for level = 1, Config.Economy.maxDenLevel - 1 do
		local cost = Economy.upgradeCost(level)
		expect.truthy(cost and cost > previous, `cost at level {level} should rise`)
		previous = cost :: number
	end
	expect.eq(Economy.upgradeCost(Config.Economy.maxDenLevel), nil, "no upgrade past max")
end

tests["pad count goes from 6 to 30"] = function()
	expect.eq(Economy.padCount(1), 6)
	expect.eq(Economy.padCount(Config.Economy.maxDenLevel), 30)
end

tests["tier rolls hit the exact boundaries"] = function()
	expect.eq(Economy.rollTier(0), "Common")
	expect.eq(Economy.rollTier(0.5499), "Common")
	expect.eq(Economy.rollTier(0.55), "Uncommon")
	expect.eq(Economy.rollTier(0.9999), "Mythic")
end

tests["tier rolls match the published odds over 200,000 rolls"] = function()
	local rng = rngLib.new(42)
	local counts: { [string]: number } = {}
	local n = 200_000
	for _ = 1, n do
		local tier = Economy.rollTier(rng.next())
		counts[tier] = (counts[tier] or 0) + 1
	end
	for _, entry in Config.EggOdds do
		local share = (counts[entry.tier] or 0) / n
		-- Tolerance: 5 standard deviations of a binomial share, so a real bug fails but noise never does.
		local tolerance = 5 * math.sqrt(entry.weight * (1 - entry.weight) / n)
		expect.near(share, entry.weight, tolerance, `{entry.tier} share`)
	end
end

tests["egg rolls never return event-only critters"] = function()
	expect.eq(Economy.rollSpecies("Secret", 0.5), nil, "Secret is event-only")
	for i = 0, 99 do
		local species = Economy.rollSpecies("Mythic", i / 100)
		expect.truthy(species and not species.eventOnly)
	end
end

tests["rebirth needs max level and a Legendary"] = function()
	local p = fixtures.veteran(1, NOW)
	p.denLevel = Config.Economy.maxDenLevel
	fixtures.give(p, fixtures.critter("a", "dusk_mouse"))
	expect.falsy(Economy.canRebirth(p), "no Legendary yet")
	fixtures.give(p, fixtures.critter("b", "storm_hare", "Pad", 20))
	expect.truthy(Economy.canRebirth(p), "now eligible")
end

tests["rebirth resets Glow and level, keeps critters, unseats overflow pads"] = function()
	local p = fixtures.veteran(1, NOW)
	p.denLevel = Config.Economy.maxDenLevel
	p.glow = 1_000_000
	p.stored = 5_000
	fixtures.give(p, fixtures.critter("low", "dusk_mouse", "Pad", 2))
	fixtures.give(p, fixtures.critter("high", "storm_hare", "Pad", 25))
	expect.truthy(Economy.applyRebirth(p, NOW))
	expect.eq(p.glow, 0)
	expect.eq(p.stored, 0)
	expect.eq(p.denLevel, 1)
	expect.eq(p.rebirths, 1)
	expect.eq(p.vaultSlots, 2)
	expect.eq(p.critters["low"].placement, "Pad", "pad 2 still exists")
	expect.eq(p.critters["high"].placement, "Inventory", "pad 25 no longer exists")
end

-- P0.4: capped egg rolls, placement, upgrades, egg purchases, DenState ------------------------

local CritterCatalog = require("../../src/Shared/CritterCatalog")

local function egg(uid: string, tierRoll: number?, speciesRoll: number?): Economy.EggRoll
	return {
		tierRoll = tierRoll or 0,
		speciesRoll = speciesRoll or 0,
		uid = uid,
		maxTier = "Uncommon",
		physicalPads = 6,
	}
end

local function tierOf(speciesId: string): string
	local species = CritterCatalog.get(speciesId)
	return if species then species.tier else "?"
end

tests["capped tier rolls renormalise Common and Uncommon"] = function()
	local commonShare = 0.55 / (0.55 + 0.25)
	expect.eq(Economy.rollTierUpTo(0, "Uncommon"), "Common")
	expect.eq(Economy.rollTierUpTo(commonShare - 1e-9, "Uncommon"), "Common")
	expect.eq(Economy.rollTierUpTo(commonShare, "Uncommon"), "Uncommon")
	expect.eq(Economy.rollTierUpTo(0.999999, "Uncommon"), "Uncommon")
	expect.eq(Economy.rollTierUpTo(1, "Uncommon"), "Uncommon", "rounding sliver")
	expect.eq(Economy.rollTierUpTo(0.99, "Common"), "Common")
	expect.eq(Economy.rollTierUpTo(0.9999, "Mythic"), "Mythic", "uncapped matches rollTier")
end

tests["capped eggs never hatch above the cap over 100,000 rolls"] = function()
	local rng = rngLib.new(7)
	local n = 100_000
	local commons = 0
	for _ = 1, n do
		local tier = Economy.rollTierUpTo(rng.next(), "Uncommon")
		expect.truthy(tier == "Common" or tier == "Uncommon", `got {tier}`)
		if tier == "Common" then
			commons += 1
		end
	end
	local p = 0.55 / 0.8
	expect.near(commons / n, p, 5 * math.sqrt(p * (1 - p) / n), "Common share")
end

tests["usable pads are capped by the pads built in the world"] = function()
	expect.eq(Economy.usablePadCount(1, 6), 6)
	expect.eq(Economy.usablePadCount(20, 6), 6, "level unlocks more than exist")
	expect.eq(Economy.usablePadCount(1, 4), 4)
end

tests["placing on a pad accrues first, then moves"] = function()
	local p = fixtures.veteran(1, NOW)
	fixtures.give(p, fixtures.critter("a", "dusk_mouse", "Pad", 1)) -- 1/s
	fixtures.give(p, fixtures.critter("b", "crumb_rat", "Inventory")) -- 3/s once placed
	local ok = Economy.place(p, "b", "Pad", 2, 6, NOW + 10)
	expect.truthy(ok)
	expect.eq(p.stored, 10, "the 10 s before the move paid the old rate")
	expect.eq(p.critters["b"].padIndex, 2)
	expect.eq(Economy.denRate(p), 4)
end

tests["placing on an occupied pad swaps the two critters"] = function()
	local p = fixtures.veteran(1, NOW)
	fixtures.give(p, fixtures.critter("a", "dusk_mouse", "Pad", 1))
	fixtures.give(p, fixtures.critter("b", "crumb_rat", "Pad", 3))
	fixtures.give(p, fixtures.critter("c", "pebble_toad", "Inventory"))
	expect.truthy(Economy.place(p, "b", "Pad", 1, 6, NOW))
	expect.eq(p.critters["a"].padIndex, 3, "occupant took the mover's pad")
	expect.truthy(Economy.place(p, "c", "Pad", 1, 6, NOW))
	expect.eq(p.critters["b"].placement, "Inventory", "occupant took the mover's Inventory spot")
	expect.eq(p.critters["b"].padIndex, nil)
end

tests["placement rejects bad pads, foreign uids, full vaults and guards"] = function()
	local p = fixtures.veteran(1, NOW)
	p.denLevel = 1
	fixtures.give(p, fixtures.critter("a", "dusk_mouse", "Inventory"))
	fixtures.give(p, fixtures.critter("v", "dusk_mouse", "Vault"))
	local later = NOW + 10
	for _, pad in { 0, 7, 1.5, -1 } do
		expect.falsy(Economy.place(p, "a", "Pad", pad, 6, later), `pad {pad}`)
	end
	expect.falsy(Economy.place(p, "a", "Pad", nil, 6, later), "missing pad")
	expect.falsy(Economy.place(p, "nope", "Pad", 1, 6, later), "not owned")
	expect.falsy(Economy.place(p, "a", "Vault", nil, 6, later), "vault has 1 slot, already used")
	expect.falsy(Economy.place(p, "a", "Guard", nil, 6, later), "no guard slots yet")
	expect.falsy(Economy.place(p, "a", "Nonsense" :: any, nil, 6, later))
	expect.eq(p.critters["a"].placement, "Inventory", "nothing changed")
	expect.eq(p.storedUpdatedAt, NOW, "rejected moves do not accrue")
	expect.truthy(Economy.place(p, "v", "Vault", nil, 6, later), "re-placing in the vault is fine")
end

tests["upgrading spends banked Glow and accrues at the old level first"] = function()
	local p = fixtures.veteran(1, NOW)
	p.denLevel = 1
	fixtures.give(p, fixtures.critter("a", "dusk_mouse"))
	local cost = Economy.upgradeCost(1) :: number
	p.glow = cost - 1
	expect.falsy(Economy.upgradeDen(p, NOW + 5), "short by 1")
	expect.eq(p.denLevel, 1)
	p.glow = cost + 7
	expect.truthy(Economy.upgradeDen(p, NOW + 5))
	expect.eq(p.denLevel, 2)
	expect.eq(p.glow, 7)
	expect.eq(p.stored, 5, "accrued before the level changed")
	p.denLevel = Config.Economy.maxDenLevel
	p.glow = math.huge
	expect.falsy(Economy.upgradeDen(p, NOW + 5), "max level")
end

tests["a player with nothing gets a free rescue egg, and only then"] = function()
	local p = fixtures.veteran(1, NOW)
	p.denLevel = 1
	expect.truthy(Economy.isRescueEgg(p), "no critters, no Glow")
	expect.eq(Economy.eggCost(p), 0)
	local critter = Economy.buyEgg(p, NOW, egg("first"))
	expect.truthy(critter, "free egg hatched")
	expect.eq(p.glow, 0)
	expect.falsy(Economy.isRescueEgg(p), "owns a critter now")
	expect.eq(Economy.eggCost(p), Economy.eggPrice(1))
	expect.falsy(Economy.buyEgg(p, NOW, egg("second")), "second egg is not free")

	local rich = fixtures.veteran(2, NOW)
	rich.denLevel = 1
	rich.stored = Economy.eggPrice(1) -- can afford it after collecting
	expect.falsy(Economy.isRescueEgg(rich), "collect first instead")
end

tests["buying an egg pays, hatches a capped critter and fills the first free pad"] = function()
	local p = fixtures.veteran(1, NOW)
	p.denLevel = 1
	fixtures.give(p, fixtures.critter("a", "dusk_mouse", "Pad", 1))
	local price = Economy.eggPrice(1)
	p.glow = price * 2
	local critter = Economy.buyEgg(p, NOW + 3, egg("new", 0.99, 0.99)) :: Types.Critter
	expect.eq(p.glow, price)
	expect.eq(tierOf(critter.speciesId), "Uncommon", "top roll is capped at Uncommon")
	expect.eq(critter.placement, "Pad")
	expect.eq(critter.padIndex, 2)
	expect.eq(critter.acquiredAt, NOW + 3)
	expect.eq(critter.mutation, "None")
	expect.eq(p.stored, 3, "accrued before the rate changed")
	expect.eq(p.critters["new"], critter)
	expect.falsy(Economy.buyEgg(p, NOW, egg("new")), "duplicate uid is refused")
	expect.eq(p.glow, price, "refusal charged nothing")
end

tests["eggs go to Inventory once every usable pad is taken"] = function()
	local p = fixtures.veteran(1, NOW)
	p.denLevel = 1
	p.glow = 1_000_000
	for i = 1, 7 do
		local critter = Economy.buyEgg(p, NOW, egg(`e{i}`, i / 10, i / 10)) :: Types.Critter
		local tier = tierOf(critter.speciesId)
		expect.truthy(tier == "Common" or tier == "Uncommon", `egg {i} tier {tier}`)
		if i <= 6 then
			expect.eq(critter.padIndex, i)
		else
			expect.eq(critter.placement, "Inventory")
			expect.eq(critter.padIndex, nil)
		end
	end
	expect.eq(Economy.firstFreePad(p, 6), nil)
end

-- P0.4b: rescue-egg guards (decisions D-004, D-005) ----------------------------------------------

local Profile = require("../../src/Shared/Profile")

local function eggUpTo(uid: string, maxTier: Types.Tier, tierRoll: number, speciesRoll: number): Economy.EggRoll
	local roll = egg(uid, tierRoll, speciesRoll)
	roll.maxTier = maxTier
	return roll
end

tests["a rescue egg hatches Common only, whatever eggMaxTier allows"] = function()
	for i = 0, 19 do
		local p = fixtures.veteran(1, NOW)
		p.denLevel = 1
		local roll = (i + 0.5) / 20
		local critter = Economy.buyEgg(p, NOW, eggUpTo(`r{i}`, "Mythic", 0.9999, roll)) :: Types.Critter
		expect.eq(tierOf(critter.speciesId), "Common", `rescue egg with species roll {roll}`)
	end
end

tests["a paid egg still rolls up to eggMaxTier"] = function()
	local p = fixtures.veteran(1, NOW)
	p.denLevel = 1
	fixtures.give(p, fixtures.critter("a", "dusk_mouse", "Pad", 1))
	p.glow = Economy.eggPrice(1) * 2
	local mythic = Economy.buyEgg(p, NOW, eggUpTo("m", "Mythic", 0.9999, 0)) :: Types.Critter
	expect.eq(tierOf(mythic.speciesId), "Mythic", "uncapped top roll")
	local capped = Economy.buyEgg(p, NOW, eggUpTo("u", "Uncommon", 0.9999, 0)) :: Types.Critter
	expect.eq(tierOf(capped.speciesId), "Uncommon", "capped top roll")
end

tests["a rescue critter is untradeable and a paid one is not flagged"] = function()
	local p = fixtures.veteran(1, NOW)
	p.denLevel = 1
	local rescued = Economy.buyEgg(p, NOW, egg("rescued")) :: Types.Critter
	expect.eq(rescued.untradeable, true, "rescue flag")
	expect.falsy(Profile.isTradeable(rescued, NOW + 10 * 86400), "never tradeable")

	p.glow = Economy.eggPrice(1)
	local paid = Economy.buyEgg(p, NOW, egg("paid")) :: Types.Critter
	expect.eq(paid.untradeable, nil, "paid eggs carry no flag")
	expect.truthy(Profile.isTradeable(paid, NOW), "paid critter is tradeable")
end

tests["stored Glow counts as affordable, so it never buys a free egg"] = function()
	local price = Economy.eggPrice(1)

	-- Glow already in storage, nothing banked: the player must collect, not get a free egg.
	local p = fixtures.veteran(1, NOW)
	p.denLevel = 1
	p.stored = price
	expect.falsy(Economy.isRescueEgg(p))
	expect.eq(Economy.eggCost(p), price)
	expect.eq(Economy.denState(p).stored, price, "DenState shows the Glow the cost is judged against")
	local critter, reason = Economy.buyEgg(p, NOW + 5, egg("x"))
	expect.eq(critter, nil, "no free egg")
	expect.eq(reason, "not enough Glow")
	expect.eq(next(p.critters), nil, "nothing hatched")
	expect.eq(p.stored, price, "nothing spent")
	Economy.collect(p, NOW + 5)
	expect.truthy(Economy.buyEgg(p, NOW + 5, egg("x")), "buys once collected")
	expect.eq(p.glow, 0, "paid full price")

	-- Stale accrual timestamp: buyEgg accrues first and still judges banked + stored.
	local stale = fixtures.veteran(2, NOW)
	stale.denLevel = 1
	stale.stored = price - 1
	stale.glow = 1
	stale.storedUpdatedAt = NOW - 86400
	expect.falsy(Economy.buyEgg(stale, NOW, egg("y")), "banked + stored reaches the price")
	expect.eq(stale.storedUpdatedAt, NOW, "accrued before judging")
	expect.eq(stale.glow, 1, "nothing spent")
	stale.glow = 0
	expect.truthy(Economy.buyEgg(stale, NOW, egg("y")), "one Glow short is a rescue")
	expect.eq(stale.stored, price - 1, "a rescue egg leaves stored Glow alone")
end

tests["DenState reflects the profile with a stable, copied critter list"] = function()
	local p = fixtures.veteran(1, NOW)
	p.denLevel = 2
	p.glow = 12
	p.stored = 3.5
	local b = fixtures.give(p, fixtures.critter("b", "crumb_rat"))
	local a = fixtures.give(p, fixtures.critter("a", "dusk_mouse", "Pad", 2))
	b.acquiredAt, a.acquiredAt = 5, 5
	local state = Economy.denState(p)
	expect.eq(state.glow, 12)
	expect.eq(state.stored, 3.5)
	expect.eq(state.ratePerSecond, 4)
	expect.eq(state.storageCap, 4 * Economy.storageCapSeconds(2))
	expect.eq(state.denLevel, 2)
	expect.eq(#state.critters, 2)
	expect.eq(state.critters[1].uid, "a", "same time: ordered by uid")
	state.critters[1].padIndex = 99
	expect.eq(a.padIndex, 2, "the client copy cannot change the profile")
end

return tests
