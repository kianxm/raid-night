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

-- P0.4c: a placement never moves a carried (locked) critter, directly or as a swap -------------

local function lockedSet(...: string): (string) -> boolean
	local set = {}
	for _, uid in { ... } do
		set[uid] = true
	end
	return function(uid: string): boolean
		return set[uid] == true
	end
end

local function expectSpot(p: Types.PlayerProfile, uid: string, placement: string, padIndex: number?)
	expect.eq(p.critters[uid].placement, placement, `{uid} placement`)
	expect.eq(p.critters[uid].padIndex, padIndex, `{uid} padIndex`)
end

tests["placing onto a pad whose occupant is locked is refused and changes nothing"] = function()
	local p = fixtures.veteran(1, NOW)
	fixtures.give(p, fixtures.critter("x", "dusk_mouse", "Pad", 1)) -- being carried
	fixtures.give(p, fixtures.critter("pad", "crumb_rat", "Pad", 2))
	fixtures.give(p, fixtures.critter("inv", "crumb_rat", "Inventory"))
	fixtures.give(p, fixtures.critter("vault", "crumb_rat", "Vault"))
	local locked = lockedSet("x")
	local later = NOW + 10
	for _, mover in { "inv", "vault", "pad" } do
		local ok, reason = Economy.place(p, mover, "Pad", 1, 6, later, locked)
		expect.falsy(ok, `{mover} onto the carried critter's pad`)
		expect.eq(reason, "pad is busy")
	end
	expectSpot(p, "x", "Pad", 1)
	expectSpot(p, "pad", "Pad", 2)
	expectSpot(p, "inv", "Inventory", nil)
	expectSpot(p, "vault", "Vault", nil)
	expect.eq(p.stored, 0, "refused moves do not accrue")
	expect.eq(p.storedUpdatedAt, NOW, "refused moves do not accrue")
end

tests["moving a locked critter itself is refused"] = function()
	local p = fixtures.veteran(1, NOW)
	fixtures.give(p, fixtures.critter("x", "dusk_mouse", "Pad", 1))
	fixtures.give(p, fixtures.critter("pad", "crumb_rat", "Pad", 2))
	local locked = lockedSet("x")
	local later = NOW + 10
	for _, target in { { "Pad", 3 }, { "Pad", 2 }, { "Pad", 1 }, { "Vault" }, { "Inventory" } } :: { { any } } do
		local ok, reason = Economy.place(p, "x", target[1], target[2], 6, later, locked)
		expect.falsy(ok, `x to {target[1]} {target[2]}`)
		expect.eq(reason, "critter is busy")
	end
	expectSpot(p, "x", "Pad", 1)
	expectSpot(p, "pad", "Pad", 2)
	expect.eq(p.storedUpdatedAt, NOW, "refused moves do not accrue")
end

tests["placement still works around a locked critter"] = function()
	local p = fixtures.veteran(1, NOW)
	fixtures.give(p, fixtures.critter("x", "dusk_mouse", "Pad", 1)) -- being carried
	fixtures.give(p, fixtures.critter("a", "crumb_rat", "Pad", 2))
	fixtures.give(p, fixtures.critter("b", "crumb_rat", "Inventory"))
	local locked = lockedSet("x")
	expect.truthy(Economy.place(p, "b", "Pad", 3, 6, NOW, locked), "free pad")
	expectSpot(p, "b", "Pad", 3)
	expect.truthy(Economy.place(p, "b", "Pad", 2, 6, NOW, locked), "unlocked occupant swaps")
	expectSpot(p, "b", "Pad", 2)
	expectSpot(p, "a", "Pad", 3)
	expect.truthy(Economy.place(p, "a", "Vault", nil, 6, NOW, locked), "to the vault")
	expectSpot(p, "x", "Pad", 1)
end

tests["once the lock lifts the pad can be swapped again"] = function()
	local p = fixtures.veteran(1, NOW)
	fixtures.give(p, fixtures.critter("x", "dusk_mouse", "Pad", 1))
	fixtures.give(p, fixtures.critter("b", "crumb_rat", "Inventory"))
	expect.falsy(Economy.place(p, "b", "Pad", 1, 6, NOW, lockedSet("x")))
	expect.truthy(Economy.place(p, "b", "Pad", 1, 6, NOW, lockedSet()))
	expectSpot(p, "b", "Pad", 1)
	expectSpot(p, "x", "Inventory", nil)
end

-- P0.4d: Phase 0 auto-placement of Inventory critters (D-027) -----------------------------------

local function aged(critter: Types.Critter, acquiredAt: number): Types.Critter
	critter.acquiredAt = acquiredAt
	return critter
end

tests["autoPlace puts a stolen critter on the first free pad and accrues first"] = function()
	local p = fixtures.veteran(1, NOW)
	fixtures.give(p, fixtures.critter("a", "dusk_mouse", "Pad", 1)) -- 1 Glow/s
	fixtures.give(p, fixtures.critter("c", "dusk_mouse", "Pad", 3))
	fixtures.give(p, fixtures.critter("stolen", "crumb_rat", "Inventory"))
	local moved = Economy.autoPlace(p, 6, NOW + 10)
	expect.eq(moved, 1, "moved")
	expectSpot(p, "stolen", "Pad", 2)
	expect.eq(p.stored, 20, "accrued at the old rate (2/s) before the new critter landed")
	expect.eq(p.storedUpdatedAt, NOW + 10)
	expect.eq(Economy.denRate(p), 2 + 3, "the placed critter now earns")
end

tests["autoPlace places the overflow egg once a pad frees up"] = function()
	local p = fixtures.veteran(1, NOW)
	p.denLevel = 1 -- 6 pads
	for pad = 1, 6 do
		fixtures.give(p, fixtures.critter(`p{pad}`, "dusk_mouse", "Pad", pad))
	end
	p.glow = Economy.eggPrice(1)
	local critter = Economy.buyEgg(p, NOW, egg("egg", 0, 0)) :: Types.Critter
	expect.eq(critter.placement, "Inventory", "full pads: the egg waits in Inventory")
	expect.eq(Economy.autoPlace(p, 6, NOW), 0, "no free pad, nothing moves")
	expectSpot(p, "egg", "Inventory", nil)
	expect.truthy(Economy.place(p, "p4", "Vault", nil, 6, NOW))
	expect.eq(Economy.autoPlace(p, 6, NOW + 1), 1)
	expectSpot(p, "egg", "Pad", 4)
	expectSpot(p, "p4", "Vault", nil)
end

tests["autoPlace fills pads oldest first, ties by uid, until pads run out"] = function()
	local p = fixtures.veteran(1, NOW)
	p.denLevel = 1
	for pad = 1, 4 do
		fixtures.give(p, fixtures.critter(`p{pad}`, "dusk_mouse", "Pad", pad))
	end
	fixtures.give(p, aged(fixtures.critter("young", "crumb_rat", "Inventory"), 300))
	fixtures.give(p, aged(fixtures.critter("old-b", "crumb_rat", "Inventory"), 100))
	fixtures.give(p, aged(fixtures.critter("old-a", "crumb_rat", "Inventory"), 100))
	expect.eq(Economy.autoPlace(p, 6, NOW), 2, "two free pads")
	expectSpot(p, "old-a", "Pad", 5)
	expectSpot(p, "old-b", "Pad", 6)
	expectSpot(p, "young", "Inventory", nil)
end

tests["autoPlace never touches Vault or Guard critters and never displaces"] = function()
	local p = fixtures.veteran(1, NOW)
	fixtures.give(p, fixtures.critter("v", "crumb_rat", "Vault"))
	fixtures.give(p, fixtures.critter("g", "crumb_rat", "Guard"))
	fixtures.give(p, fixtures.critter("a", "dusk_mouse", "Pad", 1))
	expect.eq(Economy.autoPlace(p, 6, NOW + 10), 0, "nothing in Inventory")
	expectSpot(p, "v", "Vault", nil)
	expectSpot(p, "g", "Guard", nil)
	expectSpot(p, "a", "Pad", 1)
	expect.eq(p.storedUpdatedAt, NOW, "no move, no accrual")
end

tests["autoPlace never moves a locked critter"] = function()
	local p = fixtures.veteran(1, NOW)
	fixtures.give(p, aged(fixtures.critter("carried", "crumb_rat", "Inventory"), 1))
	fixtures.give(p, aged(fixtures.critter("free", "crumb_rat", "Inventory"), 2))
	expect.eq(Economy.autoPlace(p, 6, NOW, lockedSet("carried")), 1)
	expectSpot(p, "carried", "Inventory", nil)
	expectSpot(p, "free", "Pad", 1)
	expect.eq(Economy.autoPlace(p, 6, NOW + 5, lockedSet("carried")), 0, "still locked")
	expect.eq(Economy.autoPlace(p, 6, NOW + 5, lockedSet()), 1, "placed once the lock lifts")
	expectSpot(p, "carried", "Pad", 2)
end

tests["autoPlace with no free pad changes nothing"] = function()
	local p = fixtures.veteran(1, NOW)
	p.denLevel = 1
	for pad = 1, 6 do
		fixtures.give(p, fixtures.critter(`p{pad}`, "dusk_mouse", "Pad", pad))
	end
	fixtures.give(p, fixtures.critter("inv", "crumb_rat", "Inventory"))
	expect.eq(Economy.autoPlace(p, 6, NOW + 10), 0)
	expectSpot(p, "inv", "Inventory", nil)
	expect.eq(p.stored, 0, "no move, no accrual")
	expect.eq(p.storedUpdatedAt, NOW, "no move, no accrual")
	expect.eq(Economy.autoPlace(p, 0, NOW + 10), 0, "no den world (0 physical pads)")
	expectSpot(p, "inv", "Inventory", nil)
end

tests["autoPlace respects den level and physical pads"] = function()
	local p = fixtures.veteran(1, NOW)
	p.denLevel = 1 -- 6 unlocked
	for i = 1, 10 do
		fixtures.give(p, aged(fixtures.critter(`i{string.format("%02d", i)}`, "crumb_rat", "Inventory"), i))
	end
	expect.eq(Economy.autoPlace(p, 4, NOW), 4, "only 4 pads built")
	expect.eq(Economy.autoPlace(p, 30, NOW), 2, "level 1 unlocks 6 even with 30 built")
	for uid, critter in p.critters do
		if critter.placement == "Pad" then
			expect.truthy((critter.padIndex :: number) <= 6, `{uid} on an unlocked pad`)
		end
	end
	p.denLevel = 3 -- 7 unlocked
	expect.eq(Economy.autoPlace(p, 30, NOW), 1, "an upgrade unlocks one more pad")
	expectSpot(p, "i07", "Pad", 7)
	expectSpot(p, "i08", "Inventory", nil)
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

-- P0.9: egg odds as data for the UI (decision D-028) --------------------------------------------

local GRID = 100_000 -- grid points (i + 0.5) / GRID: each odds boundary misplaces at most 1 point

local function sumChances(odds: { any }): number
	local total = 0
	for _, entry in odds do
		total += entry.chance
	end
	return total
end

tests["egg tier odds sum to 1, run Common up to the cap, and never pass it"] = function()
	for _, maxTier in { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic" } :: { Types.Tier } do
		local odds = Economy.eggTierOdds(maxTier)
		expect.near(sumChances(odds), 1, 1e-9, `{maxTier} sum`)
		expect.eq(odds[1].tier, "Common", `{maxTier} starts at Common`)
		expect.eq(odds[#odds].tier, maxTier, `{maxTier} ends at the cap`)
		expect.eq(#odds, CritterCatalog.tierRank(maxTier), `{maxTier} lists every tier up to the cap`)
		for i, entry in odds do
			expect.truthy(entry.chance > 0, `{maxTier} {entry.tier} chance is positive`)
			expect.eq(CritterCatalog.tierRank(entry.tier), i, `{maxTier} ordered Common upwards`)
		end
	end
	local launch = Economy.eggTierOdds(Config.Economy.eggMaxTier :: Types.Tier)
	expect.eq(#launch, 2, "launch egg is Common and Uncommon")
	expect.near(launch[1].chance, 0.55 / 0.8, 1e-12, "Common 0.6875")
	expect.near(launch[2].chance, 0.25 / 0.8, 1e-12, "Uncommon 0.3125")
	local full = Economy.eggTierOdds("Mythic")
	for i, entry in Config.EggOdds do
		expect.near(full[i].chance, entry.weight, 1e-12, `uncapped {entry.tier} is the published weight`)
	end
end

tests["egg tier odds match rollTierUpTo over a fine roll grid"] = function()
	for _, maxTier in { "Uncommon", "Mythic" } :: { Types.Tier } do
		local counts: { [string]: number } = {}
		for i = 0, GRID - 1 do
			local tier = Economy.rollTierUpTo((i + 0.5) / GRID, maxTier)
			counts[tier] = (counts[tier] or 0) + 1
		end
		local listed: { [string]: boolean } = {}
		for _, entry in Economy.eggTierOdds(maxTier) do
			listed[entry.tier] = true
			expect.near((counts[entry.tier] or 0) / GRID, entry.chance, 1e-3, `{maxTier} {entry.tier}`)
		end
		for tier in counts do
			expect.truthy(listed[tier], `{maxTier} rolled {tier}, which the odds do not list`)
		end
	end
end

tests["the rescue egg's odds are Common, always"] = function()
	local odds = Economy.rescueEggTierOdds()
	expect.eq(#odds, 1)
	expect.eq(odds[1].tier, "Common")
	expect.eq(odds[1].chance, 1)
end

tests["species odds are uniform over the rollSpecies pool and skip event-only species"] = function()
	for _, tier in CritterCatalog.TIER_ORDER do
		local odds = Economy.speciesOdds(tier)
		local eligible = 0
		for _, species in CritterCatalog.byTier(tier) do
			if not species.eventOnly then
				eligible += 1
			end
		end
		expect.eq(#odds, eligible, `{tier} lists every eligible species`)
		if eligible == 0 then
			expect.eq(Economy.rollSpecies(tier, 0.5), nil, `{tier} rolls nothing either`)
			continue
		end
		expect.near(sumChances(odds), 1, 1e-9, `{tier} sum`)
		local listed: { [string]: number } = {}
		for _, entry in odds do
			local species = CritterCatalog.get(entry.speciesId)
			expect.truthy(species and species.tier == tier, `{entry.speciesId} is a {tier}`)
			expect.truthy(species and not species.eventOnly, `{entry.speciesId} is not event-only`)
			expect.near(entry.chance, 1 / eligible, 1e-12, `{entry.speciesId} uniform`)
			listed[entry.speciesId] = entry.chance
		end
		local counts: { [string]: number } = {}
		for i = 0, GRID - 1 do
			local species = Economy.rollSpecies(tier, (i + 0.5) / GRID)
			local id = if species then species.id else "?"
			counts[id] = (counts[id] or 0) + 1
		end
		for id, count in counts do
			local chance = listed[id]
			expect.truthy(chance ~= nil, `{tier} rolled {id}, which the odds do not list`)
			expect.near(count / GRID, chance :: number, 1e-3, `{tier} {id}`)
		end
	end
	expect.eq(#Economy.speciesOdds("Secret"), 0, "Secret is event-only, so no egg odds")
end

tests["next egg odds switch with the rescue rule"] = function()
	local p = fixtures.veteran(1, NOW)
	p.denLevel = 1
	local rescue = Economy.nextEggOdds(p, "Uncommon")
	expect.truthy(rescue.rescue, "no critters, no Glow: rescue egg")
	expect.eq(#rescue.tiers, 1)
	expect.eq(rescue.tiers[1].tier, "Common")
	expect.eq(rescue.tiers[1].chance, 1)
	local mythicCap = Economy.nextEggOdds(p, "Mythic")
	expect.truthy(mythicCap.rescue and #mythicCap.tiers == 1, "the rescue egg ignores the cap")

	p.glow = Economy.eggPrice(1)
	local paid = Economy.nextEggOdds(p, "Uncommon")
	expect.falsy(paid.rescue, "can afford an egg: paid egg")
	expect.eq(#paid.tiers, 2)
	expect.near(paid.tiers[1].chance, 0.6875, 1e-12)

	p.glow = 0
	fixtures.give(p, fixtures.critter("a", "dusk_mouse"))
	local owner = Economy.nextEggOdds(p, "Rare")
	expect.falsy(owner.rescue, "owns a critter: paid egg")
	expect.eq(owner.tiers[#owner.tiers].tier, "Rare")
end

-- P0.12: Robux-linked Glow multipliers (D-030) ---------------------------------------------------

type BoostPair = { vip: boolean, lanternNight: boolean }
type Policy = { paidRandomRestricted: boolean?, purchasesEnabled: boolean }

local NONE: BoostPair = { vip = false, lanternNight = false }
local VIP: BoostPair = { vip = true, lanternNight = false }
local LANTERN: BoostPair = { vip = false, lanternNight = true }
local BOTH: BoostPair = { vip = true, lanternNight = true }
local OPEN: Policy = { paidRandomRestricted = false, purchasesEnabled = true }

-- glowBoostFactor's inputs: the boosts plus a policy, all as named fields.
local function factorFor(boosts: BoostPair, policy: Policy): number
	return Economy.glowBoostFactor({
		vip = boosts.vip,
		lanternNight = boosts.lanternNight,
		paidRandomRestricted = policy.paidRandomRestricted,
		purchasesEnabled = policy.purchasesEnabled,
	})
end

tests["glow boosts never apply to a restricted player"] = function()
	for _, boosts in { NONE, VIP, LANTERN, BOTH } do
		expect.eq(factorFor(boosts, { paidRandomRestricted = true, purchasesEnabled = true }), 1)
	end
end

tests["glow boosts fail closed while the policy is unknown"] = function()
	for _, boosts in { NONE, VIP, LANTERN, BOTH } do
		local unknown: Policy = { paidRandomRestricted = nil, purchasesEnabled = true }
		expect.eq(factorFor(boosts, unknown), 1, "unknown policy counts as restricted")
	end
end

tests["glow boosts are off while purchases are switched off"] = function()
	for _, boosts in { NONE, VIP, LANTERN, BOTH } do
		expect.eq(factorFor(boosts, { paidRandomRestricted = false, purchasesEnabled = false }), 1)
		expect.eq(factorFor(boosts, { paidRandomRestricted = true, purchasesEnabled = false }), 1)
	end
end

tests["glow boosts are off when any field is missing or not a boolean"] = function()
	local full: Economy.GlowBoostInputs =
		{ vip = true, lanternNight = true, paidRandomRestricted = false, purchasesEnabled = true }
	expect.eq(Economy.glowBoostFactor(full), Economy.maxGlowBoostFactor(), "complete inputs boost")
	for _, field in { "vip", "lanternNight", "paidRandomRestricted", "purchasesEnabled" } do
		local missing = table.clone(full) :: any
		missing[field] = nil
		expect.eq(Economy.glowBoostFactor(missing), 1, `{field} missing`)
		local wrong = table.clone(full) :: any
		wrong[field] = 1
		expect.eq(Economy.glowBoostFactor(wrong), 1, `{field} not a boolean`)
	end
	expect.eq((Economy.glowBoostFactor :: any)(nil), 1, "no inputs at all")
end

tests["glow boosts can't be enabled by swapping positional flags"] = function()
	-- The old (boosts, paidRandomRestricted, purchasesEnabled) call shape: the extra arguments are
	-- ignored and the table has no policy fields, so it fails closed instead of boosting.
	local glowBoostFactor = Economy.glowBoostFactor :: any
	expect.eq(glowBoostFactor(BOTH, false, true), 1, "old shape")
	expect.eq(glowBoostFactor(BOTH, true, false), 1, "old shape, swapped")
end

tests["glow boosts stack additively for an unrestricted player"] = function()
	local vipBonus = Config.Boosts.vipGlowBonus
	local lanternBonus = Config.Boosts.lanternNightGlowBonus
	expect.eq(factorFor(NONE, OPEN), 1, "no boosts")
	expect.eq(factorFor(VIP, OPEN), 1 + vipBonus, "VIP (1.5x at launch values)")
	expect.eq(factorFor(LANTERN, OPEN), 1 + lanternBonus, "Lantern Night (1.5x)")
	expect.eq(factorFor(BOTH, OPEN), 1 + vipBonus + lanternBonus, "both (2.0x)")
	expect.eq(factorFor(BOTH, OPEN), Economy.maxGlowBoostFactor(), "both is the maximum")
	if vipBonus > 0 and lanternBonus > 0 then
		local multiplied = (1 + vipBonus) * (1 + lanternBonus)
		expect.truthy(factorFor(BOTH, OPEN) < multiplied, "added, not multiplied")
	end
end

tests["glow boosts at the launch values"] = function()
	-- Pins D-030's launch numbers; update with the Config.Boosts values if they are retuned.
	-- Tests below use factors 1.5 and 2, which accrue accepts only while the maximum is >= 2.
	expect.eq(factorFor(VIP, OPEN), 1.5)
	expect.eq(factorFor(LANTERN, OPEN), 1.5)
	expect.eq(factorFor(BOTH, OPEN), 2.0)
end

tests["accrue with a factor multiplies what is earned over the window"] = function()
	local plain = fixtures.veteran(1, NOW)
	fixtures.give(plain, fixtures.critter("a", "crumb_rat")) -- 3/s
	local boosted = fixtures.veteran(2, NOW)
	fixtures.give(boosted, fixtures.critter("a", "crumb_rat"))
	expect.eq(Economy.accrue(plain, NOW + 100), 300, "factor defaults to 1")
	expect.eq(Economy.accrue(boosted, NOW + 100, 2), 600, "factor 2 doubles it")
	expect.eq(boosted.stored, 2 * plain.stored, "stored doubled")
end

tests["collect passes its factor to accrue"] = function()
	local p = fixtures.veteran(1, NOW)
	fixtures.give(p, fixtures.critter("a", "dusk_mouse")) -- 1/s
	expect.eq(Economy.collect(p, NOW + 10, 1.5), 15, "banked at 1.5x")
	expect.eq(p.glow, 15)
end

tests["the storage cap ignores the factor"] = function()
	local p = fixtures.veteran(1, NOW)
	fixtures.give(p, fixtures.critter("a", "dusk_mouse")) -- 1/s
	local cap = Economy.storageCapSeconds(p.denLevel)
	expect.eq(Economy.storageCap(p), cap, "cap is the unboosted rate x cap seconds")

	-- Boosted, storage fills twice as fast but no deeper.
	Economy.accrue(p, NOW + cap / 2 - 10, 2)
	expect.eq(p.stored, cap - 20, "just under the cap")
	Economy.accrue(p, NOW + cap, 2)
	expect.eq(p.stored, cap, "clamped at the unboosted cap")
	expect.eq(Economy.storageCap(p), cap, "boosting never raised the cap")

	-- The boost ends: stored is not above the cap, so nothing has to be clawed back.
	Economy.accrue(p, NOW + 2 * cap)
	expect.eq(p.stored, cap, "still exactly at the cap")
	expect.eq(Economy.storageFillShare(p), 1)
end

tests["a boost composes with mutation, placement and rebirth"] = function()
	local p = fixtures.veteran(1, NOW)
	fixtures.give(p, fixtures.critter("a", "dusk_mouse")) -- 1/s
	p.rebirths = 1 -- 1.5x at launch values
	local rebirth = Economy.rebirthMultiplier(1)
	expect.eq(Economy.accrue(p, NOW + 100, 1.5), 100 * 1 * rebirth * 1.5, "base x rebirth x factor")
	expect.eq(p.stored, 225, "1 x 1.5 x 1.5 x 100 s at launch values")

	local q = fixtures.veteran(2, NOW)
	local c = fixtures.give(q, fixtures.critter("v", "dusk_mouse", "Vault"))
	c.mutation = "Shiny"
	q.rebirths = 1
	local expected = 1 * Config.Mutations.Shiny * Config.Income.vaultMultiplier * rebirth * 2
	expect.near(Economy.accrue(q, NOW + 1, 2), expected, 1e-12, "base x mutation x placement x rebirth x factor")
end

tests["a factor outside [1, max boost] falls back to 1"] = function()
	local max = Economy.maxGlowBoostFactor()
	for _, bad in { 0, 0.5, 0.999, -1, 0 / 0, math.huge, -math.huge, 1e300, max + 0.001 } do
		local p = fixtures.veteran(1, NOW)
		fixtures.give(p, fixtures.critter("a", "dusk_mouse")) -- 1/s
		expect.eq(Economy.accrue(p, NOW + 10, bad), 10, `factor {bad}`)
	end
	for _, good in { 1, max } do
		local p = fixtures.veteran(1, NOW)
		fixtures.give(p, fixtures.critter("a", "dusk_mouse"))
		expect.eq(Economy.accrue(p, NOW + 10, good), 10 * good, `factor {good} is in range`)
	end
	local p = fixtures.veteran(1, NOW)
	fixtures.give(p, fixtures.critter("a", "dusk_mouse"))
	expect.eq(Economy.collect(p, NOW + 10, 1e300), 10, "collect clamps too")
end

tests["accrue ignores a NaN now"] = function()
	local p = fixtures.veteran(1, NOW)
	fixtures.give(p, fixtures.critter("a", "dusk_mouse"))
	p.stored = 5
	expect.eq(Economy.accrue(p, 0 / 0), 0, "nothing added")
	expect.eq(p.stored, 5, "stored unchanged")
	expect.eq(p.storedUpdatedAt, NOW, "timestamp unchanged")
	expect.eq(Economy.accrue(p, NOW + 10), 10, "later accrues still work")
end

tests["timing rule: accrue at the old factor before Lantern Night starts and ends"] = function()
	local factorOn = factorFor(LANTERN, OPEN)
	local start, finish = NOW + 100, NOW + 100 + Config.Boosts.lanternNightSeconds

	-- Following the rule: accrue at 1 when it starts, at the boost when it ends.
	local p = fixtures.veteran(1, NOW)
	fixtures.give(p, fixtures.critter("a", "dusk_mouse")) -- 1/s
	Economy.accrue(p, start, 1)
	Economy.accrue(p, finish, factorOn)
	Economy.accrue(p, finish + 50, 1)
	local expected = 100 + Config.Boosts.lanternNightSeconds * factorOn + 50
	expect.eq(p.stored, expected, "only the Lantern Night window is boosted")

	-- Breaking it: one late accrue at the new factor boosts the 100 s before the start too.
	local q = fixtures.veteran(2, NOW)
	fixtures.give(q, fixtures.critter("a", "dusk_mouse"))
	Economy.accrue(q, start + 10, factorOn)
	expect.eq(q.stored, 110 * factorOn, "why the rule exists: earlier time got boosted")
end

tests["timing rule: a boosted accrue first makes internal factor-1 accrues a no-op"] = function()
	local p = fixtures.veteran(1, NOW)
	fixtures.give(p, fixtures.critter("a", "dusk_mouse")) -- 1/s
	Economy.accrue(p, NOW + 100, 2)
	local ok = Economy.place(p, "a", "Vault", nil, 6, NOW + 100)
	expect.truthy(ok)
	expect.eq(p.stored, 200, "place's own accrue added nothing at factor 1")
	expect.eq(Economy.collect(p, NOW + 100), 200, "nor did collect's")
end

return tests
