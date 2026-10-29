--!strict
-- Live loss rules (decision D-031): value-based daily protection, post-loss safety and the
-- live same-pair limit, from the grab check through the defender's debit.
local expect = require("../lib/expect")
local fixtures = require("../lib/fixtures")
local RaidRules = require("../../src/Shared/RaidRules")
local Economy = require("../../src/Shared/Economy")
local Config = require("../../src/Shared/Config")
local Types = require("../../src/Shared/Types")

type PlayerProfile = Types.PlayerProfile

local NOW = 1_800_000_000
local DAY = 86400
local DAY_START = RaidRules.dayIndex(NOW) * DAY
local Reason = RaidRules.Reason
local Live = Config.LiveRaid

local function never(_uid: string): boolean
	return false
end

-- Can `raiderUserId` grab the critter on `padIndex` right now? Everything but the owner's
-- profile and the post-loss window is a pass, so only the live loss rules decide.
local function canGrab(owner: PlayerProfile, raiderUserId: number, padIndex: number, now: number, lastLossAt: number?)
	return RaidRules.canGrabLive({
		flagsAllow = true,
		raiderUserId = raiderUserId,
		raiderReady = true,
		ownerUserId = owner.userId,
		ownerProfile = owner,
		lockdownBlocked = false,
		padIndex = padIndex,
		carrying = false,
		isLocked = never,
		inFlightForOwner = 0,
		inFlightForPair = 0,
		lastLiveLossAt = lastLossAt,
		distance = 1,
		now = now,
	})
end

local raids = 0

-- A live steal landing on the defender, as the escrow debit applies it: value the loss while
-- the critter is still in the den, take it, then the usual incoming consequences.
local function steal(owner: PlayerProfile, raiderUserId: number, uid: string, now: number)
	raids += 1
	local critter = owner.critters[uid]
	assert(critter and critter.placement == "Pad", `{uid} is not on a pad`)
	RaidRules.recordLiveLoss(owner, critter, now)
	owner.critters[uid] = nil
	RaidRules.recordIncoming(owner, `raid-{raids}`, raiderUserId, critter.speciesId, 0, false, now)
end

-- Four Rare foxes (25 Glow/s each) on pads 1-4: 100 Glow/s.
local function foxDen(): PlayerProfile
	local owner = fixtures.veteran(2, NOW)
	for pad = 1, 4 do
		fixtures.give(owner, fixtures.critter(`fox{pad}`, "crescent_fox", "Pad", pad))
	end
	expect.eq(Economy.denRate(owner), 100)
	return owner
end

local tests = {}

tests["protectionLossShare is Kian's 50% (D-031)"] = function()
	expect.eq(Live.protectionLossShare, 0.5)
end

tests["a den with no live loss today is not protected, and the check never writes"] = function()
	local owner = foxDen()
	expect.falsy(RaidRules.liveProtected(owner, NOW))
	expect.eq(owner.liveLossBaseRate, nil)
	expect.eq(owner.liveLossRateToday, nil)
end

tests["the base is the den's Glow/s just before its first live loss, vault included"] = function()
	local owner = foxDen()
	fixtures.give(owner, fixtures.critter("vaulted", "crescent_fox", "Vault")) -- earns half: 12.5
	steal(owner, 1, "fox1", NOW)
	expect.eq(owner.liveLossBaseRate, 112.5, "measured with the stolen fox still in the den")
	expect.eq(owner.liveLossRateToday, 25)
end

tests["the base stays the first loss's, however the den changes later that day"] = function()
	local owner = foxDen()
	steal(owner, 1, "fox1", NOW)
	fixtures.give(owner, fixtures.critter("king", "king_bandit", "Pad", 5)) -- the den now earns 675
	steal(owner, 3, "fox2", NOW + 120)
	expect.eq(owner.liveLossBaseRate, 100, "not re-measured")
	expect.truthy(RaidRules.liveProtected(owner, NOW + 120), "50 of a 100 base, though the den earns 650 now")
end

tests["a loss is the critter's own Glow/s where it sat: mutation and rebirths count"] = function()
	local owner = fixtures.veteran(2, NOW)
	owner.rebirths = 1 -- x1.5
	local shiny = fixtures.give(owner, fixtures.critter("shiny", "crescent_fox", "Pad", 1))
	shiny.mutation = "Shiny" -- x1.5
	fixtures.give(owner, fixtures.critter("plain", "crescent_fox", "Pad", 2))
	steal(owner, 1, "shiny", NOW)
	expect.eq(owner.liveLossRateToday, 25 * 1.5 * 1.5)
	expect.eq(owner.liveLossBaseRate, 25 * 1.5 * 1.5 + 25 * 1.5)
end

tests["recordLiveLoss refuses a critter that already left the den"] = function()
	local owner = foxDen()
	local fox = owner.critters.fox1
	owner.critters.fox1 = nil
	expect.throws(function()
		RaidRules.recordLiveLoss(owner, fox, NOW)
	end, "the base would miss it")
	expect.eq(owner.liveLossBaseRate, nil, "nothing recorded")
end

tests["protection starts at exactly protectionLossShare of the base and blocks every later grab"] = function()
	local owner = foxDen()
	expect.truthy((canGrab(owner, 1, 1, NOW)))
	steal(owner, 1, "fox1", NOW)
	expect.falsy(RaidRules.liveProtected(owner, NOW), "25 of 100")
	local later = RaidRules.liveGrabReadyAt(NOW)
	expect.truthy((canGrab(owner, 3, 2, later, NOW)))
	steal(owner, 3, "fox2", later)
	expect.eq(owner.liveLossRateToday, Live.protectionLossShare * owner.liveLossBaseRate :: number, "exactly 50%")
	expect.truthy(RaidRules.liveProtected(owner, later), "protected at exactly the share")
	local _, reason = canGrab(owner, 4, 3, later + 3600, later)
	expect.eq(reason, Reason.LiveProtected, "a fresh raider, long after the safety window")
	expect.eq(select(2, canGrab(owner, 4, 3, DAY_START + DAY - 1, later)), Reason.LiveProtected, "all day")
end

tests["a new UTC day lifts protection; the next loss measures a new base"] = function()
	local owner = foxDen()
	steal(owner, 1, "fox1", NOW)
	steal(owner, 3, "fox2", NOW + 60)
	expect.truthy(RaidRules.liveProtected(owner, DAY_START + DAY - 1))
	local tomorrow = DAY_START + DAY
	expect.falsy(RaidRules.liveProtected(owner, tomorrow), "read-only: no write needed")
	expect.truthy((canGrab(owner, 4, 3, tomorrow)))
	RaidRules.resetDailyIfNeeded(owner, tomorrow)
	expect.eq(owner.liveLossBaseRate, nil, "reset with the day's counters")
	expect.eq(owner.liveLossRateToday, nil)
	steal(owner, 4, "fox3", tomorrow)
	expect.eq(owner.liveLossBaseRate, 50, "two foxes left")
	expect.eq(owner.liveLossRateToday, 25)
	expect.truthy(RaidRules.liveProtected(owner, tomorrow), "half of today's den")
end

tests["losing the den's best critter protects it at once"] = function()
	local owner = fixtures.veteran(2, NOW)
	fixtures.give(owner, fixtures.critter("king", "king_bandit", "Pad", 1))
	fixtures.give(owner, fixtures.critter("rat", "crumb_rat", "Pad", 2))
	steal(owner, 1, "king", NOW)
	expect.eq(select(2, canGrab(owner, 3, 2, RaidRules.liveGrabReadyAt(NOW), NOW)), Reason.LiveProtected)
end

tests["stealing only Commons from a rich den never triggers protection"] = function()
	local owner = fixtures.veteran(2, NOW)
	owner.denLevel = 30 -- 20 pads
	for pad = 1, 14 do
		fixtures.give(owner, fixtures.critter(`rat{pad}`, "crumb_rat", "Pad", pad)) -- Common, 3 Glow/s
	end
	fixtures.give(owner, fixtures.critter("king", "king_bandit", "Pad", 15)) -- 600
	fixtures.give(owner, fixtures.critter("hare", "storm_hare", "Pad", 16)) -- 380
	expect.eq(Economy.denRate(owner), 1022, "about 1,000 Glow/s")

	-- Seven raiders, two steals each (the live pair limit), every steal after the safety window.
	local now, lastLoss: number?, pad = NOW, nil, 0
	for raider = 101, 107 do
		for _ = 1, Live.maxStealsPerPairPerDay do
			pad += 1
			local ok, reason = canGrab(owner, raider, pad, now, lastLoss)
			expect.truthy(ok, `steal {pad} refused: {reason}`)
			steal(owner, raider, `rat{pad}`, now)
			lastLoss = now
			now = RaidRules.liveGrabReadyAt(now)
		end
		expect.eq(select(2, canGrab(owner, raider, 15, now, lastLoss)), Reason.PairLimit, "the pair is done today")
	end

	expect.eq(owner.lossesToday, 14, "far past the async count cap")
	expect.eq(owner.liveLossRateToday, 42, "14 Commons at 3 Glow/s")
	expect.falsy(RaidRules.liveProtected(owner, now), "42 of 1,022 Glow/s is nowhere near half")
	expect.truthy((canGrab(owner, 108, 15, now, lastLoss)), "the den is still open to a new raider")
end

return tests
