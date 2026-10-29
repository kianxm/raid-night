--!strict
-- Live loss rules (decision D-031): value-based daily protection, post-loss safety and the
-- live same-pair limit, from the grab check through the defender's debit; the base measured at
-- the grab (decision D-034).
local expect = require("../lib/expect")
local fixtures = require("../lib/fixtures")
local source = require("../lib/source")
local RaidRules = require("../../src/Shared/RaidRules")
local Escrow = require("../../src/Shared/Escrow")
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

-- A live steal landing on the defender: the escrow debit of a "Live" record (no Glow, D-015).
-- `grabBase` is the record's liveBaseRate (D-034); nil = a record without one.
local function debit(
	owner: PlayerProfile,
	raiderUserId: number,
	uid: string,
	now: number,
	grabBase: number?
): Types.AppliedTransfer
	raids += 1
	local record = Escrow.create(`raid-{raids}`, raiderUserId, owner.userId, uid, 0, false, now, "Live", grabBase)
	return Escrow.debitDefender(owner, record, now)
end

-- A debit that must take the critter.
local function steal(owner: PlayerProfile, raiderUserId: number, uid: string, now: number, grabBase: number?)
	local applied = debit(owner, raiderUserId, uid, now, grabBase)
	expect.eq(applied.critter and applied.critter.uid, uid, `the debit took {uid}`)
end

-- The owner moves a critter off its pad (as Economy.place would, minus the accrue).
local function move(owner: PlayerProfile, uid: string, placement: Types.Placement)
	owner.critters[uid].placement = placement
	owner.critters[uid].padIndex = nil
end

-- A rich den with one cheap Common: the king (600 Glow/s) on pad 1, a rat (3) on pad 2.
local function kingAndRat(): PlayerProfile
	local owner = fixtures.veteran(2, NOW)
	fixtures.give(owner, fixtures.critter("king", "king_bandit", "Pad", 1))
	fixtures.give(owner, fixtures.critter("rat", "crumb_rat", "Pad", 2))
	expect.eq(Economy.denRate(owner), 603)
	return owner
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

tests["liveProtected counts a NaN base or a NaN loss as protected"] = function()
	local nan = 0 / 0
	-- A small lost value against a large one too: math.max must not drop the NaN (D-036).
	for _, case in { { nan, 10 }, { 100, nan }, { nan, nan }, { nan, 0 }, { 0, nan } } do
		local owner = foxDen()
		owner.liveLossBaseRate, owner.liveLossRateToday = case[1], case[2]
		expect.truthy(RaidRules.liveProtected(owner, NOW), `base {case[1]}, lost {case[2]}`)
		expect.eq(select(2, canGrab(owner, 1, 1, NOW)), Reason.LiveProtected, "grabs refused too")
	end
	local owner = foxDen()
	owner.liveLossBaseRate, owner.liveLossRateToday = nan, nan
	expect.falsy(RaidRules.liveProtected(owner, DAY_START + DAY), "a NaN from yesterday is not today's")
end

tests["a NaN den rate counts as protected too (D-036)"] = function()
	local owner = foxDen()
	owner.liveLossBaseRate, owner.liveLossRateToday = 100, 10
	expect.falsy(RaidRules.liveProtected(owner, NOW), "10 of 100")
	owner.rebirths = 0 / 0 -- every critter's rate, and so the den's, is NaN
	expect.truthy(RaidRules.liveProtected(owner, NOW))
	expect.eq(select(2, canGrab(owner, 1, 1, NOW)), Reason.LiveProtected)
end

tests["a den with no live loss today is not protected, and the check never writes"] = function()
	local owner = foxDen()
	expect.falsy(RaidRules.liveProtected(owner, NOW))
	expect.eq(owner.liveLossBaseRate, nil)
	expect.eq(owner.liveLossRateToday, nil)
end

tests["one field missing means not protected, whatever the den earns (D-036)"] = function()
	for _, case in { { nil, 50 }, { 100, nil } } do
		local owner = foxDen()
		owner.liveLossBaseRate, owner.liveLossRateToday = case[1], case[2]
		for pad = 1, 4 do
			move(owner, `fox{pad}`, "Inventory") -- an empty den: any recorded loss would reach the line
		end
		expect.falsy(RaidRules.liveProtected(owner, NOW), `base {case[1]}, lost {case[2]}`)
	end
end

tests["with no grab-time base, the base is the den's Glow/s just before its first live loss, vault included"] = function()
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
	-- The line moves with the den instead (D-036): 50 of a 100 base, but the den earns 650 now.
	expect.falsy(RaidRules.liveProtected(owner, NOW + 120), "50 lost of a den earning 650")
	move(owner, "king", "Inventory")
	expect.eq(owner.liveLossBaseRate, 100, "a placement never touches the base")
	expect.truthy(RaidRules.liveProtected(owner, NOW + 120), "50 of the 100 base once the king is off")
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

tests["protection starts at exactly protectionLossShare of the base and blocks later grabs and debits"] = function()
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
	-- A grab that slipped through anyway (checked before the line was crossed) takes nothing.
	local slipped = debit(owner, 4, "fox3", later + 3600)
	expect.eq(slipped.critter, nil, "the debit refuses too")
	expect.truthy(owner.critters.fox3, "fox3 stays home")
	expect.eq(owner.liveLossRateToday, 50, "nothing more lost")
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

-- Grab-time base (decision D-034) ------------------------------------------------------------------

tests["moving a high earner off its pad during the carry cannot shrink the base (D-034)"] = function()
	local owner = kingAndRat()
	local grabBase = Economy.denRate(owner) -- RaidService measures it when it accepts the grab
	move(owner, "king", "Inventory") -- alerted, the owner hides the king before the escape lands
	expect.eq(Economy.denRate(owner), 3, "the den now earns only the rat's 3 Glow/s")
	steal(owner, 1, "rat", NOW, grabBase)
	expect.eq(owner.liveLossBaseRate, 603, "measured at the grab, king included")
	expect.falsy(RaidRules.liveProtected(owner, NOW), "3 of 603 Glow/s: one cheap loss buys no protection")
	owner.critters.king.placement, owner.critters.king.padIndex = "Pad", 1 -- the king goes back out
	local ok, reason = canGrab(owner, 3, 1, RaidRules.liveGrabReadyAt(NOW), NOW)
	expect.truthy(ok, `the den is still open: {reason}`)
end

tests["vaulting the den's top earner during the carry cannot shrink the base either"] = function()
	local owner = fixtures.veteran(2, NOW)
	fixtures.give(owner, fixtures.critter("possum", "drama_possum", "Pad", 1)) -- 6 Glow/s
	fixtures.give(owner, fixtures.critter("rat", "crumb_rat", "Pad", 2)) -- 3, a Common
	local grabBase = Economy.denRate(owner)
	move(owner, "possum", "Vault") -- earns half there
	expect.eq(Economy.denRate(owner), 6, "3 of 6 would be exactly the share")
	steal(owner, 1, "rat", NOW, grabBase)
	expect.eq(owner.liveLossBaseRate, 9)
	expect.falsy(RaidRules.liveProtected(owner, NOW), "3 of the grab's 9 Glow/s")
end

tests["a record without a grab-time base measures the den at the debit (older records)"] = function()
	local owner = kingAndRat()
	move(owner, "king", "Inventory")
	steal(owner, 1, "rat", NOW) -- no liveBaseRate: today's behaviour before D-034
	expect.eq(owner.liveLossBaseRate, 3, "the den as it is at the debit")
	expect.truthy(RaidRules.liveProtected(owner, NOW), "which is why RaidService must pass the grab's rate")
end

tests["a record without kind or liveBaseRate still debits like a Phase 0 live steal"] = function()
	local owner = kingAndRat()
	local record = Escrow.create("old-raid", 1, owner.userId, "rat", 0, false, NOW, "Live")
	record.kind = nil -- written before either field existed
	expect.eq(record.liveBaseRate, nil)
	local applied = Escrow.debitDefender(owner, record, NOW)
	expect.eq(applied.critter and applied.critter.uid, "rat")
	expect.eq(owner.liveLossBaseRate, 603, "measured at the debit, the rat still in the den")
	expect.eq(owner.liveLossRateToday, 3)
end

tests["later losses that day never change the base, whatever their record carries"] = function()
	local owner = foxDen()
	steal(owner, 1, "fox1", NOW, 100)
	steal(owner, 3, "fox2", NOW + 60, 10) -- a later grab measured a smaller den
	expect.eq(owner.liveLossBaseRate, 100, "kept")
	expect.truthy(RaidRules.liveProtected(owner, NOW + 60), "50 of 100")
	-- Nor a bigger one. Its grab saw a den of 1,000 Glow/s, so its debit lands (D-037), but the
	-- day's base stays the first loss's.
	local third = debit(owner, 4, "fox3", NOW + 120, 1000)
	expect.eq(third.critter and third.critter.uid, "fox3", "50 of max(100, 50, 1,000): not protected at this debit")
	expect.eq(owner.liveLossBaseRate, 100)
	local fourth = debit(owner, 5, "fox4", NOW + 180, 10)
	expect.eq(fourth.critter, nil, "a smaller grab-time rate never lowers the line: 75 of 100")
	expect.eq(owner.liveLossBaseRate, 100)
end

tests["a new UTC day's first live loss takes its own record's grab-time base"] = function()
	local owner = foxDen()
	steal(owner, 1, "fox1", NOW, 100)
	steal(owner, 3, "fox2", NOW + 60, 75)
	local tomorrow = DAY_START + DAY
	local grabBase = Economy.denRate(owner) -- two foxes left at tomorrow's grab
	move(owner, "fox4", "Inventory") -- then the owner hides one
	steal(owner, 4, "fox3", tomorrow, grabBase)
	expect.eq(owner.liveLossBaseRate, 50, "the record's base, on the new day's first loss")
	expect.eq(owner.liveLossRateToday, 25)
	expect.truthy(RaidRules.liveProtected(owner, tomorrow))
end

tests["recordLiveLoss treats a grab-time base that is not a finite number >= 0 as none"] = function()
	for _, bad in { 0 / 0, -1, math.huge, -math.huge } do
		local owner = kingAndRat()
		RaidRules.recordLiveLoss(owner, owner.critters.rat, NOW, bad)
		expect.eq(owner.liveLossBaseRate, 603, `{bad}: measured instead`)
	end
	local owner = kingAndRat()
	RaidRules.recordLiveLoss(owner, owner.critters.rat, NOW, 0)
	expect.eq(owner.liveLossBaseRate, 0, "0 is a measurement (an empty den), not a missing one")
end

tests["transferLive refuses a bad liveBaseRate before any write and puts it in the Live record"] = function()
	local code = source.codeOnly(source.read("src/Server/Services/EscrowService.luau"))
	local live = source.functionBody(code, "EscrowService.transferLive") or ""
	expect.truthy(string.find(live, "isRevenge: boolean%?,%s*liveBaseRate: number%?%s*%)"), "the trailing parameter")
	expect.truthy(
		string.find(live, "pcall%(%s*startOrResume,[^)]*isRevenge == true,%s*liveBaseRate%s*%)"),
		"transferLive passes it on"
	)
	local start = source.functionBody(code, "startOrResume") or ""
	local checked = string.find(
		start,
		'local baseOk, baseWhy = Escrow%.checkLiveBaseRate%("Live", liveBaseRate%)%s*if not baseOk then%s*return "Refused"'
	)
	local created = string.find(start, 'Escrow%.create%(.-"Live",%s*liveBaseRate%s*%)')
	local firstRead = string.find(start, "read%(recordKey")
	local firstWrite = string.find(start, "indexAdd%(")
	expect.truthy(checked and created and firstRead and firstWrite, "check, create, read and write found")
	expect.truthy((checked :: number) < (created :: number), "checked before Escrow.create (which asserts)")
	expect.truthy((checked :: number) < (firstRead :: number), "and before anything is read or written")
	expect.truthy((created :: number) < (firstWrite :: number), "the record built with it is the one created")
end

-- Protection against max(base, the den's Glow/s now) (decision D-036) ---------------------------------

local PHYSICAL_PADS = 6 -- pads in the den world

-- The owner puts a critter on a pad through the server's own placement rule.
local function refill(owner: PlayerProfile, uid: string, padIndex: number, now: number)
	local ok, why = Economy.place(owner, uid, "Pad", padIndex, PHYSICAL_PADS, now)
	expect.truthy(ok, `placed {uid} on pad {padIndex}: {why}`)
end

-- A den worth stealing from: the king (600) and a hare (380) on pads 1-2, a rat (3, a Common) on 3.
local function richDen(): PlayerProfile
	local owner = fixtures.veteran(2, NOW)
	fixtures.give(owner, fixtures.critter("king", "king_bandit", "Pad", 1))
	fixtures.give(owner, fixtures.critter("hare", "storm_hare", "Pad", 2))
	fixtures.give(owner, fixtures.critter("rat", "crumb_rat", "Pad", 3))
	expect.eq(Economy.denRate(owner), 983)
	return owner
end

tests["a planned shrink buys nothing: empty the den but one Common, lose it, refill (D-036)"] = function()
	local owner = richDen()
	local alt, raider = 7, 8
	-- Before anyone grabs, so even the grab-time base (D-034) is the rat alone.
	move(owner, "king", "Inventory")
	move(owner, "hare", "Inventory")
	local grabBase = Economy.denRate(owner)
	expect.eq(grabBase, 3)
	steal(owner, alt, "rat", NOW, grabBase) -- lost to an alt, or a carry the owner let land
	expect.eq(owner.liveLossBaseRate, 3, "a true measurement: the den really earned 3 Glow/s")
	expect.truthy(RaidRules.liveProtected(owner, NOW), "only while the den stays empty")
	local later = RaidRules.liveGrabReadyAt(NOW)
	refill(owner, "king", 1, later)
	expect.falsy(RaidRules.liveProtected(owner, later), "3 lost of a den earning 600 again")
	refill(owner, "hare", 2, later)
	local ok, reason = canGrab(owner, raider, 1, later, NOW)
	expect.truthy(ok, `a real raider can grab the king: {reason}`)
	steal(owner, raider, "king", later)
	expect.eq(owner.liveLossBaseRate, 3, "the base is still the day's first")
	expect.truthy(RaidRules.liveProtected(owner, later), "a real loss protects: 603 lost, the den earns 380")
end

tests["refilling lifts protection mid-day, and shrinking the den brings it back (D-036)"] = function()
	local owner = foxDen()
	steal(owner, 1, "fox1", NOW, 100)
	steal(owner, 3, "fox2", NOW + 60, 100)
	expect.truthy(RaidRules.liveProtected(owner, NOW + 60), "50 of 100")
	local t = NOW + 600
	fixtures.give(owner, fixtures.critter("king", "king_bandit", "Inventory")) -- a fresh hatch
	expect.truthy(RaidRules.liveProtected(owner, t), "Inventory earns nothing, so it changes nothing")
	refill(owner, "king", 1, t) -- onto the stolen fox's pad
	expect.falsy(RaidRules.liveProtected(owner, t), "50 lost of a den earning 650")
	expect.truthy((canGrab(owner, 4, 3, t, NOW + 60)), "grabs reopen")

	expect.truthy(Economy.place(owner, "king", "Inventory", nil, PHYSICAL_PADS, t + 1))
	expect.truthy(RaidRules.liveProtected(owner, t + 1), "back to 50 of the 100 base")
	expect.eq(select(2, canGrab(owner, 4, 3, t + 1, NOW + 60)), Reason.LiveProtected, "grabs refused again")
	local slipped = debit(owner, 4, "fox3", t + 1) -- a record with no grab-time rate (an older one)
	expect.eq(slipped.critter, nil, "the debit reads the same line: nothing taken")
	expect.truthy(owner.critters.fox3, "fox3 stays home")

	refill(owner, "king", 1, t + 2)
	steal(owner, 4, "fox3", t + 2) -- and lands once the den is refilled
	expect.eq(owner.liveLossBaseRate, 100, "no placement ever moved the base")
	expect.eq(owner.liveLossRateToday, 75)
end

tests["a real loss of the den's top earner protects until the den earns over twice the loss (D-036)"] = function()
	local owner = kingAndRat()
	steal(owner, 1, "king", NOW, Economy.denRate(owner))
	expect.truthy(RaidRules.liveProtected(owner, NOW), "600 lost: the den dropped to 3 with it")
	expect.eq(select(2, canGrab(owner, 3, 2, RaidRules.liveGrabReadyAt(NOW), NOW)), Reason.LiveProtected)
	local t = NOW + 600
	-- The owner hatches replacements, which go straight onto free pads (as Economy.autoPlace does).
	for n, species in { "storm_hare", "king_bandit" } do
		fixtures.give(owner, fixtures.critter(`new{n}`, species, "Inventory"))
		refill(owner, `new{n}`, if n == 1 then 1 else 3, t)
	end
	expect.eq(Economy.denRate(owner), 983)
	expect.truthy(RaidRules.liveProtected(owner, t), "600 of 983 is still over half")
	fixtures.give(owner, fixtures.critter("new3", "storm_hare", "Inventory"))
	refill(owner, "new3", 4, t)
	expect.eq(Economy.denRate(owner), 1363)
	expect.falsy(RaidRules.liveProtected(owner, t), "600 of 1,363: worth stealing from again")
end

tests["once the den earns more than the base, the line is exactly the share of its Glow/s (D-036)"] = function()
	local owner = foxDen()
	steal(owner, 1, "fox1", NOW, 100)
	steal(owner, 3, "fox2", NOW + 60, 100)
	for n = 5, 7 do
		fixtures.give(owner, fixtures.critter(`fox{n}`, "crescent_fox", "Inventory"))
	end
	refill(owner, "fox5", 1, NOW + 60)
	refill(owner, "fox6", 2, NOW + 60)
	expect.eq(Economy.denRate(owner), 100)
	expect.truthy(RaidRules.liveProtected(owner, NOW + 60), "50 of 100: exactly the share")
	refill(owner, "fox7", 5, NOW + 60)
	expect.eq(Economy.denRate(owner), 125)
	expect.falsy(RaidRules.liveProtected(owner, NOW + 60), "50 of 125")
end

tests["the base is a floor: emptying the den after a small loss never protects it (D-036)"] = function()
	local owner = foxDen()
	steal(owner, 1, "fox1", NOW, 100)
	for pad = 2, 4 do
		move(owner, `fox{pad}`, "Inventory")
	end
	expect.eq(Economy.denRate(owner), 0)
	expect.falsy(RaidRules.liveProtected(owner, NOW + 60), "25 of the day's 100 base")
end

tests["the den's rate counts Vault critters at their vault rate, Inventory and Guards not at all (D-036)"] = function()
	local owner = foxDen()
	steal(owner, 1, "fox1", NOW, 100)
	steal(owner, 3, "fox2", NOW + 60, 100)
	local king = fixtures.give(owner, fixtures.critter("king", "king_bandit", "Inventory"))
	expect.truthy(RaidRules.liveProtected(owner, NOW + 60), "Inventory: 50 of 100")
	king.placement = "Guard" -- guards defend and earn nothing
	expect.truthy(RaidRules.liveProtected(owner, NOW + 60), "Guard: 50 of 100")
	expect.truthy(Economy.place(owner, "king", "Vault", nil, PHYSICAL_PADS, NOW + 60))
	expect.eq(Economy.denRate(owner), 50 + 600 * Config.Income.vaultMultiplier)
	expect.falsy(RaidRules.liveProtected(owner, NOW + 60), "Vault: 50 of 350, though the vault is never stolen from")
end

tests["RaidService reads protection only through RaidRules, from the live profile, on every tick (D-036)"] = function()
	local code = source.codeOnly(source.read("src/Server/Services/RaidService.luau"))
	-- No copy of the rule that a change to liveProtected could miss.
	for _, word in { "liveLossBaseRate", "liveLossRateToday", "protectionLossShare" } do
		expect.falsy(string.find(code, word, 1, true), `RaidService reads {word} itself`)
	end
	-- The grab check hands canGrabLive the owner's live profile; the den attribute and the prompt
	-- check call liveProtected on it. ownerOf returns DataService.getProfile's live table.
	local check = string.match(code, "local function checkGrab%(.-\nend\n") or ""
	expect.truthy(string.find(check, "local ownerUserId, ownerProfile = ownerOf%(plot%)"), "checkGrab: live owner")
	expect.truthy(string.find(check, "ownerProfile = ownerProfile,", 1, true), "checkGrab: passed to canGrabLive")
	local refresh = string.match(code, "local function refreshDen%(.-\nend\n") or ""
	expect.truthy(string.find(refresh, "local ownerUserId, ownerProfile = ownerOf%(plot%)"), "refreshDen: live owner")
	expect.truthy(
		string.find(refresh, "RaidRules.liveProtected(ownerProfile, os.time())", 1, true),
		"refreshDen: computed fresh, never cached"
	)
	local closed = string.match(code, "local function denClosed%(.-\nend\n") or ""
	expect.truthy(string.find(closed, "RaidRules.liveProtected(ownerProfile, now)", 1, true), "denClosed")
	-- Both refresh on the 0.5 s prompt tick, so a refill shows within a tick.
	expect.truthy(string.find(code, "local PROMPT_TICK = 0.5", 1, true), "the tick")
	expect.truthy(
		string.find(
			code,
			'if promptClock >= PROMPT_TICK then%s+promptClock = 0%s+guard%("prompts", syncPrompts%)%s+guard%("den attributes", refreshDens%)'
		),
		"syncPrompts and refreshDens run on it"
	)
end

-- The escrow debit also counts the record's grab-time rate (decision D-037) ------------------------

-- Four foxes, two of them stolen (50 of a 100 base: protected), then refilled with a king on pad 1:
-- 650 Glow/s, not protected, so a grab is accepted.
local function refilledFoxDen(t: number): PlayerProfile
	local owner = foxDen()
	steal(owner, 1, "fox1", NOW, 100)
	steal(owner, 3, "fox2", NOW + 60, 100)
	expect.truthy(RaidRules.liveProtected(owner, NOW + 60), "50 of 100")
	fixtures.give(owner, fixtures.critter("king", "king_bandit", "Inventory"))
	refill(owner, "king", 1, t)
	expect.falsy(RaidRules.liveProtected(owner, t), "50 of 650")
	return owner
end

tests["a shrink during the carry cannot make the debit refuse a refilled den's steal (D-037)"] = function()
	local t = NOW + 600
	local owner = refilledFoxDen(t)
	local ok, reason = canGrab(owner, 4, 3, t, NOW + 60)
	expect.truthy(ok, `the grab is accepted: {reason}`)
	local grabRate = Economy.denRate(owner) -- RaidService measures it as it accepts the grab
	expect.eq(grabRate, 650)
	-- Alerted, the owner hides the king before the escape lands.
	expect.truthy(Economy.place(owner, "king", "Inventory", nil, PHYSICAL_PADS, t + 5))
	expect.truthy(RaidRules.liveProtected(owner, t + 5), "the den as it is now: 50 of max(100, 50)")
	expect.falsy(RaidRules.liveProtectedAtDebit(owner, t + 5, grabRate), "50 of max(100, 50, 650)")
	steal(owner, 4, "fox3", t + 5, grabRate) -- the debit lands anyway
	expect.eq(owner.liveLossRateToday, 75)
	expect.eq(owner.liveLossBaseRate, 100, "the base is still the day's first")
	-- Grabs and the den attribute never count a record's rate: the shrunk den is protected now.
	expect.truthy(RaidRules.liveProtected(owner, t + 5), "75 of max(100, 25)")
	local later = RaidRules.liveGrabReadyAt(t + 5)
	expect.eq(select(2, canGrab(owner, 5, 4, later, t + 5)), Reason.LiveProtected, "fox4 cannot be grabbed")
end

tests["a record without a grab-time rate reads the den as it is at the debit (D-037)"] = function()
	local t = NOW + 600
	local owner = refilledFoxDen(t)
	expect.truthy(Economy.place(owner, "king", "Inventory", nil, PHYSICAL_PADS, t + 5))
	local applied = debit(owner, 4, "fox3", t + 5) -- an older record: no liveBaseRate
	expect.eq(applied.critter, nil, "50 of max(100, 50): protected, nothing taken")
	expect.truthy(owner.critters.fox3, "fox3 stays home")
end

tests["the grab-time rate only raises the line; nil or a bad value is ignored (D-037)"] = function()
	local nan = 0 / 0
	local protectedDen = foxDen()
	steal(protectedDen, 1, "fox1", NOW, 100)
	steal(protectedDen, 3, "fox2", NOW + 60, 100) -- 50 of 100, the den earns 50
	local openDen = refilledFoxDen(NOW + 600) -- 50 of 650
	for _, case in { { protectedDen, NOW + 60 }, { openDen, NOW + 600 } } do
		local owner, at = case[1] :: PlayerProfile, case[2] :: number
		local plain = RaidRules.liveProtected(owner, at)
		for _, bad in { nan, -1, math.huge, -math.huge } do
			expect.eq(RaidRules.liveProtectedAtDebit(owner, at, bad), plain, `{bad} is no measurement`)
		end
		expect.eq(RaidRules.liveProtectedAtDebit(owner, at, nil), plain, "nil: the den as it is")
		expect.eq(RaidRules.liveProtectedAtDebit(owner, at, 0), plain, "0 is below every line")
		expect.eq(RaidRules.liveProtectedAtDebit(owner, at, 10), plain, "a smaller grab never lowers the line")
	end
	expect.truthy(RaidRules.liveProtectedAtDebit(protectedDen, NOW + 60, 100), "50 of max(100, 50, 100): the share")
	expect.falsy(RaidRules.liveProtectedAtDebit(protectedDen, NOW + 60, 100.002), "just over the line")
	-- The fields' NaN rule is unchanged at the debit: a NaN loss or base still counts as protected.
	openDen.liveLossRateToday = nan
	expect.truthy(RaidRules.liveProtectedAtDebit(openDen, NOW + 600, 650))
	-- And with no live loss today, a record's rate protects nothing.
	expect.falsy(RaidRules.liveProtectedAtDebit(foxDen(), NOW, 0))
end

tests["only the escrow debit counts the record's rate; RaidService never does (D-037)"] = function()
	local escrow = source.codeOnly(source.read("src/Shared/Escrow.luau"))
	local debitBody = source.functionBody(escrow, "Escrow.debitDefender") or ""
	expect.truthy(
		string.find(debitBody, "RaidRules.liveProtectedAtDebit(defender, now, record.liveBaseRate)", 1, true),
		"debitDefender passes the record's grab-time rate"
	)
	expect.falsy(string.find(escrow, "RaidRules.liveProtected(", 1, true), "and nothing in Escrow reads the den alone")
	local raid = source.codeOnly(source.read("src/Server/Services/RaidService.luau"))
	expect.falsy(string.find(raid, "liveProtectedAtDebit", 1, true), "grabs and the den attribute: the den now")
	local rules = source.codeOnly(source.read("src/Shared/RaidRules.luau"))
	local grab = source.functionBody(rules, "RaidRules.canGrabLive") or ""
	expect.truthy(string.find(grab, "RaidRules.liveProtected(profile, g.now)", 1, true), "canGrabLive is unchanged")
end

return tests
