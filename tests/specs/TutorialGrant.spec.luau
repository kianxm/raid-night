--!strict
-- The tutorial den critter (P2.6e, decision D-064): Economy.grantTutorialCritter, keyed on the
-- onboarding step through `claim`, and IncomeService's onboarding call points.
local expect = require("../lib/expect")
local source = require("../lib/source")
local rng = require("../lib/rng")
local Economy = require("../../src/Shared/Economy")
local Profile = require("../../src/Shared/Profile")
local CritterCatalog = require("../../src/Shared/CritterCatalog")

local NOW = 1_800_000_000
local CLAIM_INDEX = Profile.onboardingStepIndex(Economy.TUTORIAL_CLAIM_STEP) :: number

local tests = {}

-- A brand-new player's save, as DataService readies it on their first load.
local function newPlayer(): any
	return Profile.prepare(Profile.new(0, 0), 42, NOW)
end

-- The claim the server passes: DataService.advanceOnboarding(userId, TUTORIAL_CLAIM_STEP) is
-- Profile.advanceOnboardingTo on the loaded profile with the server's now (plus a push).
local function claimFor(profile: any, now: number): () -> boolean
	return function(): boolean
		return Profile.advanceOnboardingTo(profile, Economy.TUTORIAL_CLAIM_STEP, now)
	end
end

local function grant(profile: any, uid: string, now: number?): (any, string?)
	local at = now or NOW
	return Economy.grantTutorialCritter(profile, at, uid, claimFor(profile, at))
end

local function count(profile: any): number
	local n = 0
	for _ in profile.critters do
		n += 1
	end
	return n
end

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in value do
		copy[k] = deepCopy(v)
	end
	return copy
end

-- A rejoin: the profile as saved, loaded again on another server.
local function rejoin(profile: any, now: number): any
	return Profile.prepare(deepCopy(profile), 42, now)
end

tests["the tutorial critter is a fixed, non-event Common and the claim is a server step"] = function()
	local species = CritterCatalog.get(Economy.TUTORIAL_CRITTER_SPECIES)
	expect.truthy(species, "species exists")
	expect.eq((species :: any).tier, "Common", "tier")
	expect.eq((species :: any).eventOnly, false, "not an event critter")
	expect.truthy(CLAIM_INDEX, "claim step is an onboarding step")
	expect.eq(Profile.ONBOARDING_STEPS[CLAIM_INDEX].by, "Server", "only the server can reach it")
end

tests["a new player gets one untradeable tutorial critter in Inventory"] = function()
	local p = newPlayer()
	local critter, reason = grant(p, "tut-1")
	expect.truthy(critter, `granted ({reason})`)
	expect.eq(critter.uid, "tut-1", "uid")
	expect.eq(critter.speciesId, Economy.TUTORIAL_CRITTER_SPECIES, "species")
	expect.eq(critter.mutation, "None", "mutation")
	expect.eq(critter.placement, "Inventory", "lands like a stolen critter")
	expect.eq(critter.padIndex, nil, "no pad")
	expect.eq(critter.acquiredAt, NOW, "acquiredAt")
	expect.eq(critter.untradeable, true, "untradeable")
	expect.falsy(Profile.isTradeable(critter, NOW + 10 * 86400), "never tradeable")
	expect.eq(p.critters["tut-1"], critter, "in the profile")
	expect.eq(Profile.onboardingStep(p), CLAIM_INDEX, "onboarding moved to the claim step")
	expect.eq(p.glow, 0, "no Glow granted")
end

tests["idempotent: a retry, a second uid or a rejoin never grants twice"] = function()
	local p = newPlayer()
	expect.truthy(grant(p, "tut-1"), "first grant")
	expect.eq(grant(p, "tut-1"), nil, "same uid retry")
	local again, reason = grant(p, "tut-2")
	expect.eq(again, nil, "fresh uid retry")
	expect.eq(reason, "already granted", "reason")
	expect.eq(count(p), 1, "one critter")

	local later = rejoin(p, NOW + 3600)
	expect.eq(grant(later, "tut-3", NOW + 3600), nil, "after a rejoin")
	expect.eq(count(later), 1, "still one critter")
	expect.eq(later.critters["tut-1"].untradeable, true, "flag survived the save")
end

tests["a player past the claim step, an old save or a skipped onboarding gets nothing"] = function()
	local stole = newPlayer()
	expect.truthy(Profile.advanceOnboardingTo(stole, "stealHome", NOW), "a real steal got home first")
	expect.eq(grant(stole, "a"), nil, "past the step")

	local done = newPlayer()
	Profile.advanceOnboardingTo(done, "stealHome", NOW)
	expect.eq(Profile.acknowledgeOnboarding(done, "raidLogTip", NOW), "Advanced", "finished")
	expect.eq(grant(done, "b"), nil, "finished onboarding")

	local saved: any = Profile.new(42, NOW - 86400)
	saved.onboarding = nil
	local old = Profile.prepare(saved, 42, NOW)
	expect.eq(grant(old, "c"), nil, "save from before onboarding")
	expect.eq(old.onboarding, nil, "old save untouched")

	local skipped = newPlayer()
	expect.truthy(Profile.completeOnboarding(skipped, NOW), "skipped")
	expect.eq(grant(skipped, "d"), nil, "skipped onboarding")

	for _, p in { stole, done, old, skipped } do
		expect.eq(count(p), 0, "nothing written")
	end
end

tests["the grant can come at any point before the claim step"] = function()
	for done = 0, CLAIM_INDEX - 1 do
		local p = newPlayer()
		if done > 0 then
			Profile.advanceOnboardingTo(p, Profile.ONBOARDING_STEPS[done].id, NOW)
		end
		expect.truthy(grant(p, "t"), `after {done} steps`)
		expect.eq(Profile.onboardingStep(p), CLAIM_INDEX, `step after {done}`)
	end
end

tests["a refused grant never spends the claim"] = function()
	local p = newPlayer()
	p.critters["taken"] = {
		uid = "taken",
		speciesId = "dusk_mouse",
		mutation = "None",
		placement = "Pad",
		padIndex = 1,
		acquiredAt = 0,
	}
	local calls = 0
	local function counting(): boolean
		calls += 1
		return Profile.advanceOnboardingTo(p, Economy.TUTORIAL_CLAIM_STEP, NOW)
	end
	local cases: { { now: any, uid: any, why: string } } = {
		{ now = NOW, uid = "taken", why = "uid already exists" },
		{ now = NOW, uid = "", why = "bad uid" },
		{ now = NOW, uid = 7, why = "bad uid" },
		{ now = 0 / 0, uid = "x", why = "bad time" },
		{ now = math.huge, uid = "x", why = "bad time" },
		{ now = "soon", uid = "x", why = "bad time" },
	}
	for _, case in cases do
		local critter, reason = Economy.grantTutorialCritter(p, case.now, case.uid, counting)
		expect.eq(critter, nil, case.why)
		expect.eq(reason, case.why, "reason")
	end
	expect.eq(calls, 0, "claim never asked")
	expect.eq(Profile.onboardingStep(p), 0, "step untouched")
	expect.eq(p.critters["taken"].placement, "Pad", "existing critter untouched")
	expect.eq(count(p), 1, "nothing added")
	expect.truthy(Economy.grantTutorialCritter(p, NOW, "x", counting), "a good request still grants")
	expect.eq(calls, 1, "claimed once")
end

tests["a claim that says no writes nothing"] = function()
	local p = newPlayer()
	local critter, reason = Economy.grantTutorialCritter(p, NOW, "x", function(): boolean
		return false
	end)
	expect.eq(critter, nil, "refused")
	expect.eq(reason, "already granted", "reason")
	expect.eq(count(p), 0, "no critter")
end

tests["the granted critter is auto-placed and earns like any Common"] = function()
	local p = newPlayer()
	local critter = grant(p, "tut")
	expect.eq(Economy.denRate(p), 0, "Inventory earns nothing")
	expect.eq(Economy.autoPlace(p, 6, NOW), 1, "auto-placed")
	expect.eq(critter.placement, "Pad", "on a pad")
	local species = CritterCatalog.get(Economy.TUTORIAL_CRITTER_SPECIES) :: any
	expect.eq(Economy.denRate(p), species.glowPerSecond, "earns its rate")
end

tests["randomized: retries, rejoins and other steps grant at most one tutorial critter"] = function()
	local events = { "grant", "grant", "rejoin", "step", "ack", "skip" }
	local seedsGranted = 0
	for seed = 1, 40 do
		local r = rng.new(seed)
		local p = newPlayer()
		local now = NOW
		local granted = 0
		for i = 1, 120 do
			now += r.int(0, 600)
			local event = events[r.int(1, #events)]
			if event == "grant" then
				if grant(p, `s{seed}-{i}`, now) then
					granted += 1
				end
			elseif event == "rejoin" then
				p = rejoin(p, now)
			elseif event == "step" then
				local step = Profile.ONBOARDING_STEPS[r.int(1, CLAIM_INDEX - 1)]
				Profile.advanceOnboardingTo(p, step.id, now)
			elseif event == "ack" then
				Profile.acknowledgeOnboarding(p, "raidLogTip", now)
			elseif r.chance(0.1) then
				Profile.completeOnboarding(p, now)
			end
		end
		expect.truthy(granted <= 1, `seed {seed}: granted {granted} times`)
		local tutorial = 0
		for _, c in p.critters do
			if c.speciesId == Economy.TUTORIAL_CRITTER_SPECIES and c.untradeable then
				tutorial += 1
			end
		end
		expect.eq(tutorial, granted, `seed {seed}: critters match grants`)
		seedsGranted += granted
	end
	expect.truthy(seedsGranted >= 30, `the run exercised real grants ({seedsGranted} of 40 seeds)`)
end

-- IncomeService (server code Lune cannot run) ---------------------------------------------------

local INCOME = source.codeOnly(source.read("src/Server/Services/IncomeService.luau"))

local function body(name: string): string
	local found = source.functionBody(INCOME, name)
	assert(found, `IncomeService has no {name}`)
	return found
end

tests["IncomeService: the tutorial grant claims through advanceOnboarding and never yields"] = function()
	local fn = body("IncomeService.grantTutorialCritter")
	expect.truthy(string.find(fn, "Economy.grantTutorialCritter(", 1, true), "uses the pure grant")
	expect.truthy(
		string.find(fn, "DataService.advanceOnboarding(userId, Economy.TUTORIAL_CLAIM_STEP)", 1, true),
		"claims with the onboarding step"
	)
	expect.truthy(string.find(fn, "os.time()", 1, true), "server time")
	expect.truthy(string.find(fn, "GenerateGUID", 1, true), "fresh uid")
	for _, yielding in { "saveNow", "task.wait", ":Wait(", "wait(", "InvokeClient", "updateOffline" } do
		expect.falsy(string.find(fn, yielding, 1, true), `no {yielding}`)
	end
	-- Only the claim callback may advance onboarding here, never ahead of the grant.
	local _, advances = string.gsub(fn, "advanceOnboarding", "")
	expect.eq(advances, 1, "one advanceOnboarding, inside the claim")
	expect.falsy(string.find(fn, "Escrow", 1, true), "a grant, not an escrow move")
end

tests["IncomeService: onboarding steps are reported after the economy call succeeds"] = function()
	local collect = body("collect")
	expect.truthy(string.find(collect, 'if banked > 0 then%s+onboard%(player, "collect"%)'), "collect > 0")

	local buy = body("buyEgg")
	expect.truthy(string.find(buy, 'onboard%(player, "hatch"%)'), "hatch")
	expect.truthy(string.find(buy, 'onboard%(player, "buyEgg"%)'), "buyEgg")
	expect.truthy(string.find(buy, "if critter.untradeable then", 1, true), "free egg is the hatch")
	local guard = string.find(buy, "if critter then", 1, true) :: number
	expect.truthy(guard and guard < (string.find(buy, "onboard(", 1, true) :: number), "only once hatched")

	local place = body("placeCritter")
	expect.truthy(string.find(place, 'if placement == "Pad" then%s+onboard%(player, "place"%)'), "place on a pad")
	expect.truthy(
		(string.find(place, "if ok then", 1, true) :: number) < (string.find(place, "onboard(", 1, true) :: number),
		"only once placed"
	)

	-- Every step this service reports is a Server step.
	for stepId in string.gmatch(INCOME, 'onboard%(player, "(%w+)"%)') do
		local index = Profile.onboardingStepIndex(stepId)
		expect.truthy(index, `{stepId} is a step`)
		expect.eq(Profile.ONBOARDING_STEPS[index :: number].by, "Server", `{stepId} is a server step`)
	end
end

return tests
