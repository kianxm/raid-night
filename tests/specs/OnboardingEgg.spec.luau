--!strict
-- Onboarding's second egg (P2.6f, decision D-070, issue #146): Economy.paidEggPrice, its use in
-- eggCost and buyEgg, and IncomeService's call points.
local expect = require("../lib/expect")
local source = require("../lib/source")
local Economy = require("../../src/Shared/Economy")
local Profile = require("../../src/Shared/Profile")
local Config = require("../../src/Shared/Config")
local Net = require("../../src/Shared/Net")

local NOW = 1_800_000_000
local DISCOUNT = Config.Onboarding.buyEggPrice
local NORMAL = Economy.eggPrice(1)

local tests = {}

-- A brand-new player's save, as DataService readies it on their first load.
local function newPlayer(): any
	return Profile.prepare(Profile.new(0, 0), 42, NOW)
end

-- A new player who hatched, placed and collected: their next step is "buyEgg".
local function atBuyEgg(): any
	local p = newPlayer()
	p.storedUpdatedAt = NOW
	p.critters.free = {
		uid = "free",
		speciesId = "dusk_mouse",
		mutation = "None",
		placement = "Pad",
		padIndex = 1,
		acquiredAt = NOW,
		untradeable = true,
	}
	assert(Profile.advanceOnboardingTo(p, "collect", NOW), "reached collect")
	return p
end

local function egg(uid: string): Economy.EggRoll
	return { tierRoll = 0, speciesRoll = 0, uid = uid, maxTier = "Mythic", physicalPads = 6 }
end

local function status(step: any, nextStepId: any, complete: any): Net.OnboardingStatus
	return ({ step = step, nextStepId = nextStepId, complete = complete } :: any) :: Net.OnboardingStatus
end

tests["the onboarding price is a whole number below a starter egg's"] = function()
	expect.eq(type(DISCOUNT), "number")
	expect.truthy(DISCOUNT >= 0 and DISCOUNT == math.floor(DISCOUNT), `whole and non-negative, got {DISCOUNT}`)
	expect.truthy(DISCOUNT < NORMAL, "cheaper than the normal first paid egg")
	expect.truthy(table.isfrozen(Config.Onboarding), "frozen")
end

tests["a player whose next step is buyEgg pays the onboarding price"] = function()
	local p = atBuyEgg()
	local s = Profile.onboardingStatus(p)
	expect.eq(s.nextStepId, "buyEgg")
	expect.eq(Economy.paidEggPrice(1, s), DISCOUNT)
	expect.eq(Economy.eggCost(p, s), DISCOUNT)
	-- Still the discount at a higher den level (it never raises the price either way).
	expect.eq(Economy.paidEggPrice(3, s), DISCOUNT)
end

tests["finished, skipped, old saves and every other step pay the normal price"] = function()
	expect.eq(Economy.paidEggPrice(1, nil), NORMAL, "no status")

	local old = newPlayer()
	old.onboarding = nil -- a save from before onboarding: complete
	expect.eq(Economy.paidEggPrice(1, Profile.onboardingStatus(old)), NORMAL, "old save")

	local skipped = atBuyEgg()
	assert(Profile.completeOnboarding(skipped, NOW))
	expect.eq(Economy.paidEggPrice(1, Profile.onboardingStatus(skipped)), NORMAL, "skipped at buyEgg")

	for index, step in Profile.ONBOARDING_STEPS do
		local p = newPlayer()
		p.onboarding = { step = index - 1 }
		local s = Profile.onboardingStatus(p)
		expect.eq(s.nextStepId, step.id)
		local want = if step.id == "buyEgg" then DISCOUNT else NORMAL
		expect.eq(Economy.paidEggPrice(1, s), want, `next step {step.id}`)
	end
	local done = newPlayer()
	done.onboarding = { step = Profile.ONBOARDING_LAST_STEP, completedAt = NOW }
	expect.eq(Economy.paidEggPrice(1, Profile.onboardingStatus(done)), NORMAL, "finished")
	expect.eq(Economy.paidEggPrice(4, Profile.onboardingStatus(done)), Economy.eggPrice(4), "finished, level 4")
end

tests["a malformed or NaN status pays the normal price"] = function()
	local nan = 0 / 0
	local p = newPlayer()
	p.onboarding = { step = nan }
	expect.eq(Economy.paidEggPrice(1, Profile.onboardingStatus(p)), NORMAL, "NaN step saved")
	expect.eq(Economy.paidEggPrice(1, status(nan, "buyEgg", false)), NORMAL, "NaN step in the status")
	expect.eq(Economy.paidEggPrice(1, status(3, "buyEgg", true)), NORMAL, "complete")
	expect.eq(Economy.paidEggPrice(1, status(3, "buyEgg", nil)), NORMAL, "complete missing")
	expect.eq(Economy.paidEggPrice(1, status(3, "buyEgg", "no")), NORMAL, "complete not a boolean")
	expect.eq(Economy.paidEggPrice(1, status(nil, "buyEgg", false)), NORMAL, "step missing")
	expect.eq(Economy.paidEggPrice(1, status(3, 4, false)), NORMAL, "nextStepId not a string")
	expect.eq(Economy.paidEggPrice(1, ("buyEgg" :: any) :: Net.OnboardingStatus), NORMAL, "not a table")
	expect.eq(Economy.paidEggPrice(1, status(3, "buyEgg", false)), DISCOUNT, "well formed")
end

tests["buyEgg charges the onboarding price once, then the normal price"] = function()
	local p = atBuyEgg()
	p.glow = DISCOUNT
	local critter = Economy.buyEgg(p, NOW, egg("second"), Profile.onboardingStatus(p))
	expect.truthy(critter, "bought at the onboarding price")
	expect.eq(p.glow, 0)
	expect.eq((critter :: any).untradeable, nil, "a normal paid egg critter")
	-- IncomeService completes the step right after; the next egg pays the normal price.
	expect.truthy(Profile.advanceOnboardingTo(p, "buyEgg", NOW))
	p.glow = NORMAL - 1
	expect.eq(Economy.eggCost(p, Profile.onboardingStatus(p)), NORMAL)
	expect.falsy(Economy.buyEgg(p, NOW, egg("third"), Profile.onboardingStatus(p)), "normal price now")
	p.glow = NORMAL
	expect.truthy(Economy.buyEgg(p, NOW, egg("third"), Profile.onboardingStatus(p)))
	expect.eq(p.glow, 0)
end

tests["buyEgg at the buyEgg step refuses below the onboarding price and spends nothing"] = function()
	local p = atBuyEgg()
	p.glow = DISCOUNT - 1
	local critter, reason = Economy.buyEgg(p, NOW, egg("second"), Profile.onboardingStatus(p))
	expect.eq(critter, nil)
	expect.eq(reason, "not enough Glow")
	expect.eq(p.glow, DISCOUNT - 1)
	expect.eq(p.critters.second, nil)
end

tests["buyEgg without a status pays the normal price"] = function()
	local p = atBuyEgg()
	p.glow = NORMAL - 1
	expect.falsy(Economy.buyEgg(p, NOW, egg("second")), "no status: normal price")
	expect.eq(p.glow, NORMAL - 1)
end

tests["the rescue egg is unchanged by the onboarding price"] = function()
	local p = atBuyEgg()
	p.critters = {}
	p.glow = DISCOUNT -- affords the onboarding egg, not a normal one: still a rescue
	local s = Profile.onboardingStatus(p)
	expect.truthy(Economy.isRescueEgg(p), "the rescue check uses the normal price")
	expect.eq(Economy.eggCost(p, s), 0)
	local critter = Economy.buyEgg(p, NOW, egg("rescue"), s) :: any
	expect.truthy(critter and critter.untradeable, "a rescue critter")
	expect.eq(p.glow, DISCOUNT, "free")
	expect.eq(Economy.nextEggOdds(p, "Mythic").rescue, false)
end

tests["a NaN den level never sells an egg"] = function()
	local p = atBuyEgg()
	p.denLevel = 0 / 0
	p.glow = 1e9
	local critter = Economy.buyEgg(p, NOW, egg("nan"), Profile.onboardingStatus(p))
	expect.eq(critter, nil)
	expect.eq(p.glow, 1e9)
end

-- IncomeService (server code Lune cannot run) ---------------------------------------------------

local INCOME = source.codeOnly(source.read("src/Server/Services/IncomeService.luau"))

tests["IncomeService prices eggs with the player's onboarding status and ends the discount first"] = function()
	local buy = source.functionBody(INCOME, "buyEgg") :: string
	expect.truthy(buy, "buyEgg exists")
	expect.truthy(string.find(buy, "local onboarding = Profile.onboardingStatus(profile)", 1, true), "status read once")
	expect.truthy(string.find(buy, "Economy.eggCost(profile, onboarding)", 1, true), "logged price")
	expect.truthy(string.find(buy, "}, onboarding)", 1, true), "buyEgg gets the same status")
	local stepAt = string.find(buy, 'onboard(player, "buyEgg")', 1, true) :: number
	expect.truthy(stepAt, "the buyEgg step is reported")
	for _, later in { "AnalyticsService.", "push(player)" } do
		local at = string.find(buy, later, 1, true) :: number
		expect.truthy(at and stepAt < at, `the step is completed before {later}`)
	end
	local station = source.functionBody(INCOME, "updateStation") :: string
	expect.truthy(
		string.find(station, "Economy.eggCost(profile, Profile.onboardingStatus(profile))", 1, true),
		"the station label shows the onboarding price"
	)
	-- Every egg price the server shows or charges goes through the onboarding-aware helpers.
	expect.falsy(string.find(INCOME, "Economy.eggPrice(", 1, true), "no raw eggPrice")
	expect.falsy(string.find(INCOME, "Economy.eggCost(profile)", 1, true), "no eggCost without a status")
end

return tests
