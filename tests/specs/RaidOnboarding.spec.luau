--!strict
-- Raid's side of onboarding (P2.6r, decisions D-063, D-064): the tutorial den's eligibility and
-- grab rule, the 30-minute new-player shield on live steals, async new-player protection, the
-- tutorial den's placement, and source guards on the server code that uses them.
local expect = require("../lib/expect")
local fixtures = require("../lib/fixtures")
local source = require("../lib/source")
local Config = require("../../src/Shared/Config")
local Economy = require("../../src/Shared/Economy")
local Matchmaking = require("../../src/Shared/Matchmaking")
local Plots = require("../../src/Shared/Plots")
local Profile = require("../../src/Shared/Profile")
local RaidRules = require("../../src/Shared/RaidRules")
local WorldKit = require("../../src/Shared/WorldKit")

local NOW = 1_800_000_000
local Reason = RaidRules.Reason
local L = Plots.Layout
local CLAIM_INDEX = Profile.onboardingStepIndex(Economy.TUTORIAL_CLAIM_STEP) :: number
local SHIELD = Config.Protection.newPlayerLiveShieldSeconds

local tests = {}

-- A brand-new player's save, as DataService readies it on their first load.
local function newPlayer(userId: number?, now: number?): any
	return Profile.prepare(Profile.new(0, 0), userId or 42, now or NOW)
end

-- A new player who has done the first `done` onboarding steps.
local function after(done: number): any
	local p = newPlayer()
	if done > 0 then
		Profile.advanceOnboardingTo(p, Profile.ONBOARDING_STEPS[done].id, NOW)
	end
	return p
end

local function open(p: any): boolean
	return RaidRules.tutorialDenOpen(Profile.onboardingStatus(p))
end

-- IncomeService.tutorialCritterAvailable, as pure logic.
local function available(p: any): boolean
	return not Profile.isOnboardingComplete(p) and Profile.onboardingStep(p) < CLAIM_INDEX
end

local function codeOf(path: string): string
	return source.codeOnly(source.read(path))
end

local function count(code: string, plain: string): number
	local n, from = 0, 1
	while true do
		local first, last = string.find(code, plain, from, true)
		if not first then
			return n
		end
		n += 1
		from = (last :: number) + 1
	end
end

-- Tutorial den eligibility ------------------------------------------------------------------------

tests["the tutorial den opens exactly at the guided steal step"] = function()
	expect.eq(Economy.TUTORIAL_CLAIM_STEP, "stealHome", "the claim step is the steal")
	for done = 0, Profile.ONBOARDING_LAST_STEP do
		local p = after(done)
		expect.eq(open(p), done == CLAIM_INDEX - 1, `after {done} steps`)
		if open(p) then
			expect.truthy(available(p), "open only while the tutorial critter can still be granted")
		end
	end
end

tests["the tutorial den is closed for a missing profile, an old save and a skipped onboarding"] = function()
	expect.falsy(RaidRules.tutorialDenOpen(nil), "not loaded")
	local old = newPlayer()
	old.onboarding = nil -- a save from before onboarding counts as finished
	expect.falsy(open(old), "old save")
	local skipped = after(CLAIM_INDEX - 1)
	Profile.completeOnboarding(skipped, NOW)
	expect.falsy(open(skipped), "skipped at the steal step")
end

tests["once the grant claims the step, the den never opens again (no farming)"] = function()
	local p = after(CLAIM_INDEX - 1)
	expect.truthy(open(p))
	local critter = Economy.grantTutorialCritter(p, NOW, "t1", function(): boolean
		return Profile.advanceOnboardingTo(p, Economy.TUTORIAL_CLAIM_STEP, NOW)
	end)
	expect.truthy(critter, "granted")
	expect.falsy(open(p), "closed after the grant")
	expect.falsy(available(p), "and nothing left to grant")
	-- Every later state stays closed.
	Profile.acknowledgeOnboarding(p, "raidLogTip", NOW)
	expect.falsy(open(p), "after the last step")
end

tests["a tutorial grab: only the den's player, only while open, not busy, in range"] = function()
	local base = { isOwner = true, open = true, raiderReady = true, busy = false, distance = 3 }
	local function with(changes: { [string]: any }): (boolean, string?)
		local t = table.clone(base) :: any
		for k, v in changes do
			t[k] = v
		end
		return RaidRules.canGrabTutorial(t)
	end
	expect.truthy((with({})), "the happy path")
	local cases = {
		{ { isOwner = false }, Reason.NotYourTutorial },
		{ { isOwner = false, open = false }, Reason.NotYourTutorial },
		{ { open = false }, Reason.TutorialClosed },
		{ { raiderReady = false }, Reason.RaiderNotReady },
		{ { busy = true }, Reason.AlreadyCarrying },
		{ { distance = Config.LiveRaid.grabRange + 0.01 }, Reason.OutOfRange },
		{ { distance = 0 / 0 }, Reason.OutOfRange },
		{ { distance = math.huge }, Reason.OutOfRange },
	}
	for i, case in cases do
		local ok, reason = with(case[1])
		expect.falsy(ok, `case {i}`)
		expect.eq(reason, case[2], `case {i}`)
	end
	expect.truthy((with({ distance = Config.LiveRaid.grabRange })), "the range line counts as in range")
end

tests["the tutorial raidId is never a GUID or an escrow raidId"] = function()
	expect.eq(RaidRules.TUTORIAL_RAID_ID, "tutorial")
	expect.falsy(string.find(RaidRules.TUTORIAL_RAID_ID, "-", 1, true), "no GUID shape")
	expect.truthy(RaidRules.TUTORIAL_RAID_ID ~= "", "never the live drop's empty raidId")
end

-- New-player shield (Appendix C step 6, D-063) ----------------------------------------------------

tests["the new-player shield is 30 minutes from the first join"] = function()
	expect.eq(SHIELD, 30 * 60)
	local p = newPlayer(42, NOW)
	expect.eq(RaidRules.newPlayerShieldUntil(p), NOW + SHIELD)
	expect.truthy(RaidRules.newPlayerShielded(p, NOW), "at join")
	expect.truthy(RaidRules.newPlayerShielded(p, NOW + SHIELD - 1), "a second before")
	expect.falsy(RaidRules.newPlayerShielded(p, NOW + SHIELD), "over at the line")
	expect.falsy(RaidRules.newPlayerShielded(p, 0 / 0), "a NaN clock is never shielded")
	expect.falsy(RaidRules.newPlayerShielded(fixtures.veteran(2, NOW), NOW), "an old account")
end

tests["a corrupt createdAt reads as an old account, never a lock-out"] = function()
	for _, bad in { 0 / 0, math.huge, -math.huge, "soon", false } :: { any } do
		local p = newPlayer()
		p.createdAt = bad
		expect.eq(RaidRules.newPlayerShieldUntil(p), 0, tostring(bad))
		expect.falsy(RaidRules.newPlayerShielded(p, NOW), tostring(bad))
	end
end

local function liveGrab(owner: any, now: number): RaidRules.LiveGrab
	return {
		flagsAllow = true,
		raiderUserId = 1,
		raiderReady = true,
		ownerUserId = owner.userId,
		ownerProfile = owner,
		lockdownBlocked = false,
		padIndex = 1,
		carrying = false,
		isLocked = function(_uid: string): boolean
			return false
		end,
		inFlightForOwner = 0,
		inFlightForPair = 0,
		distance = 4,
		now = now,
	}
end

tests["no live steal from a shielded new player, with a reason"] = function()
	local owner = newPlayer(2, NOW)
	fixtures.give(owner, fixtures.critter("pad1", "dusk_mouse", "Pad", 1))
	local ok, reason, critter = RaidRules.canGrabLive(liveGrab(owner, NOW + 60))
	expect.falsy(ok)
	expect.eq(reason, Reason.NewPlayerShield)
	expect.eq(critter, nil)
	-- It comes before the per-grab checks, so the raider sees the reason that matters.
	local g = liveGrab(owner, NOW + 60)
	g.lockdownBlocked = true
	g.carrying = true
	g.distance = 1000
	expect.eq(select(2, RaidRules.canGrabLive(g)), Reason.NewPlayerShield, "before Lockdown, carrying and range")
	expect.truthy((RaidRules.canGrabLive(liveGrab(owner, NOW + SHIELD))), "open once the shield ends")
end

tests["the shield does not stop the new player raiding others"] = function()
	local owner = fixtures.veteran(2, NOW)
	fixtures.give(owner, fixtures.critter("pad1", "dusk_mouse", "Pad", 1))
	local g = liveGrab(owner, NOW)
	g.raiderUserId = 42 -- a brand-new raider
	expect.truthy((RaidRules.canGrabLive(g)))
end

tests["async targeting already keeps new players out for 48 hours (both checks)"] = function()
	local raider = fixtures.veteran(1, NOW)
	local fresh = newPlayer(2, NOW - SHIELD - 60) -- past the live shield, still a new player
	fresh.denLevel = Config.Protection.minDenLevel + 5
	fixtures.give(fresh, fixtures.critter("pad1", "dusk_mouse", "Pad", 1))
	local snapshot = Matchmaking.buildSnapshot(fresh, NOW)
	expect.eq(snapshot.protectedUntil, fresh.createdAt + Config.Protection.newPlayerSeconds)
	-- StartRaid: RaidRules.canRaid inside canStartAsync.
	local ok, reason = RaidRules.canRaid(raider, snapshot, 0, NOW)
	expect.falsy(ok)
	expect.eq(reason, Reason.NewPlayerProtection)
	-- The target list: Matchmaking.pickCandidates drops protected entries.
	local entry = Matchmaking.toEntry(snapshot, NOW, 0)
	local picked = Matchmaking.pickCandidates(raider, snapshot.power, { entry }, {}, NOW)
	expect.eq(#picked, 0, "not offered as a target")
	local later = NOW + Config.Protection.newPlayerSeconds
	expect.truthy((RaidRules.canRaid(raider, Matchmaking.buildSnapshot(fresh, later), 0, later)), "after 48 h")
end

-- Revenge analytics -------------------------------------------------------------------------------

tests["hours since raided comes from the revenge token, never negative"] = function()
	local raidedAt = NOW - 3 * 3600
	local token = {
		raidId = "r",
		targetUserId = 1,
		expiresAt = raidedAt + Config.Revenge.windowSeconds,
		shieldBypassUsed = false,
	}
	expect.near(RaidRules.hoursSinceRaided(token, NOW), 3, 1e-9)
	expect.eq(RaidRules.hoursSinceRaided(token, raidedAt - 100), 0, "clock skew")
	expect.eq(RaidRules.hoursSinceRaided(token, 0 / 0), 0, "NaN")
end

-- Placement ---------------------------------------------------------------------------------------

tests["each den's tutorial den sits on the street in front of it, clear of everything"] = function()
	local street = L.rowOffset - L.plotSize / 2 -- dens start this far from the street's centre line
	local seen = {}
	for plot = 1, L.plotCount do
		local x, z = Plots.tutorialPosition(plot)
		local cx, cz = Plots.center(plot)
		local r = L.tutorialRadius
		expect.eq(Plots.plotAt(x, z), nil, `plot {plot}: on the street`)
		for other = 1, L.plotCount do
			local ox, oz = Plots.center(other)
			local gapX = math.abs(x - ox) - L.plotSize / 2
			local gapZ = math.abs(z - oz) - L.plotSize / 2
			expect.truthy(math.max(gapX, gapZ) >= r + 4, `plot {plot}: its whole disc is clear of den {other}`)
		end
		expect.truthy(math.abs(z) + r < street, `plot {plot}: inside the street`)
		expect.truthy(math.abs(x - cx) < L.plotSize / 2, `plot {plot}: in front of its own den`)
		expect.truthy(math.abs(z - cz) > L.plotSize / 2, `plot {plot}: past its front border`)
		expect.truthy(math.sqrt(x * x + z * z) >= L.plazaRadius + r + 4, `plot {plot}: clear of the plaza`)
		for _, spot in WorldKit.PropSpots do
			local d = math.sqrt((x - spot.x) ^ 2 + (z - spot.z) ^ 2)
			expect.truthy(d >= r + 4, `plot {plot}: clear of the {spot.piece}`)
		end
		local edge = street - 4 -- DenWorldService's street lamps
		for _, sx in { -1, 1 } do
			for _, sz in { -1, 1 } do
				local d = math.sqrt((x - sx * L.plotSpacing) ^ 2 + (z - sz * edge) ^ 2)
				expect.truthy(d >= r + 4, `plot {plot}: clear of a street lamp`)
			end
		end
		for _, other in seen do
			local d = math.sqrt((x - other[1]) ^ 2 + (z - other[2]) ^ 2)
			expect.truthy(d >= 2 * r + 8, `plot {plot}: apart from the other tutorial dens`)
		end
		table.insert(seen, { x, z })
	end
end

-- Source guards -----------------------------------------------------------------------------------

local SERVER = {
	"src/Server/Raid/TutorialDen.luau",
	"src/Server/Raid/RaidEvents.luau",
	"src/Server/Raid/CarryProp.luau",
}

tests["the new raid server files never write a profile, read a flag or an attribute"] = function()
	for _, path in SERVER do
		local code = codeOf(path)
		expect.eq(count(code, "Flags"), 0, `{path}: flags`)
		expect.eq(count(code, "GetAttribute"), 0, `{path}: attributes`)
		expect.eq(count(code, "saveNow"), 0, `{path}: saves`)
		expect.eq(count(code, "EscrowService"), 0, `{path}: escrow`)
		expect.eq(count(code, "Profile.countSuccessfulRaid"), 0, `{path}: counts on a profile directly`)
		expect.eq(count(code, "advanceOnboarding"), 0, `{path}: advances onboarding`)
		expect.falsy(string.find(code, "critters%[[^%]]+%]%s*=[^=]"), `{path}: assigns into a critters table`)
		expect.falsy(string.find(code, "%.placement%s*=[^=]"), `{path}: changes a placement`)
		expect.falsy(string.find(code, "%.padIndex%s*=[^=]"), `{path}: moves a critter to a pad`)
		expect.falsy(string.find(code, "%.successfulRaids%s*=[^=]"), `{path}: writes the raid count`)
		for _, field in { "glow", "stored", "lossesToday" } do
			local assigns = string.find(code, '[%.%["]' .. field .. '["%]]*%s*[%+%-%*/]?=[^=]')
			expect.falsy(assigns, `{path}: assigns {field}`)
		end
	end
end

tests["the tutorial escape only grants, through IncomeService, once per carry home"] = function()
	local code = codeOf("src/Server/Raid/TutorialDen.luau")
	expect.eq(count(code, "IncomeService.grantTutorialCritter"), 1, "one grant call site")
	local escape = source.functionBody(code, "escape") or ""
	expect.truthy(string.find(escape, "pcall(IncomeService.grantTutorialCritter, player)", 1, true), "in escape")
	expect.eq(count(code, "RaidEvents"), 0, "no raid analytics and never a successful raid")
	expect.eq(count(code, "Lockdown"), 0, "no Lockdown")
	local step = source.functionBody(code, "stepCarry") or ""
	expect.truthy(string.find(step, "RaidRules.carryStep({", 1, true), "the live carry rule")
	expect.truthy(string.find(step, "ownerDistance = nil", 1, true), "nobody tags")
	expect.truthy(string.find(step, 'if outcome == "Escape" then', 1, true), "escapes only on the rule's word")
	local checkBody = source.functionBody(code, "check") or ""
	expect.truthy(string.find(checkBody, "RaidRules.canGrabTutorial({", 1, true), "the pure grab rule")
	expect.truthy(string.find(checkBody, "isOwner = player == owner", 1, true), "own den only")
	expect.truthy(string.find(checkBody, "open = den ~= nil and eligible(player)", 1, true), "still open")
	local eligibleBody = source.functionBody(code, "eligible") or ""
	expect.truthy(string.find(eligibleBody, "RaidRules.tutorialDenOpen(status)", 1, true), "at the steal step")
	expect.truthy(
		string.find(eligibleBody, "pcall(IncomeService.tutorialCritterAvailable, player)", 1, true),
		"and the critter still to claim"
	)
	local holdsBody = source.functionBody(code, "stepHolds") or ""
	expect.truthy(string.find(holdsBody, "check(player, player)", 1, true), "every hold tick re-checks")
	expect.truthy(string.find(holdsBody, "RaidRules.grabHoldDone(", 1, true), "server-timed hold")
end

tests["successful raids are counted through data's API, never for the tutorial"] = function()
	local events = codeOf("src/Server/Raid/RaidEvents.luau")
	local succeeded = source.functionBody(events, "RaidEvents.succeeded") or ""
	expect.truthy(string.find(succeeded, "DataService.countSuccessfulRaid", 1, true), "data's API")
	expect.truthy(string.find(succeeded, "pcall(count, userId, raidId)", 1, true), "under pcall, per raidId")
	expect.truthy(string.find(succeeded, "pcall(service.onSuccessfulRaid, player, lifetime)", 1, true), "then notify")
	local service = codeOf("src/Server/Services/RaidService.luau")
	expect.eq(count(service, "RaidEvents.succeeded("), 2, "a live escape and an async escape")
	expect.truthy(
		string.find(service, "if escaped then%s+RaidEvents%.succeeded%(raiderUserId, raidId%)"),
		"live: only when the critter moved"
	)
	expect.truthy(
		string.find(service, "if outcome%.escaped then%s+RaidEvents%.succeeded%(run%.raiderUserId, run%.raidId%)"),
		"async: only when credited"
	)
	expect.eq(count(codeOf("src/Server/Raid/AsyncRaid.luau"), "RaidEvents.succeeded"), 0, "not twice")
	-- The raider's RaidEnded goes out before analytics and data's count, which may yield or throw.
	local pushed = string.find(service, "pcall(sendEnded, player, raidId, escaped, speciesId)", 1, true)
	local counted = string.find(service, "RaidEvents.succeeded(raiderUserId, raidId)", 1, true)
	local logged = string.find(service, "RaidEvents.liveEnded(player, escaped, speciesId", 1, true)
	expect.truthy(pushed and counted and logged, "escape calls found")
	expect.truthy((pushed :: number) < (logged :: number) and (logged :: number) < (counted :: number), "push first")
end

tests["the live grab rule sees a tutorial carry, and the shield hides a den's prompts"] = function()
	local service = codeOf("src/Server/Services/RaidService.luau")
	expect.truthy(
		string.find(service, "carrying = carries[player] ~= nil or TutorialDen.isCarrying(player)", 1, true),
		"one carry at a time"
	)
	local closed = source.functionBody(service, "denClosed") or ""
	expect.truthy(string.find(closed, "RaidRules.newPlayerShielded(ownerProfile, now)", 1, true), "prompts hide")
end

return tests
