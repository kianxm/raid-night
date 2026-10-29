--!strict
-- Onboarding by step id (P2.6, C6b): the step list, server events, client acknowledgements, the
-- status the client sees, and the DataService handlers.
local expect = require("../lib/expect")
local source = require("../lib/source")
local rng = require("../lib/rng")
local Profile = require("../../src/Shared/Profile")
local Net = require("../../src/Shared/Net")

local NOW = 1_800_000_000
local STEPS = Profile.ONBOARDING_STEPS
local LAST = Profile.ONBOARDING_LAST_STEP

local tests = {}

-- A brand-new player's save, as DataService readies it on their first load.
local function newPlayer(): any
	return Profile.prepare(Profile.new(0, 0), 42, NOW)
end

-- A save from before onboarding existed: no onboarding field.
local function oldSave(): any
	local saved: any = Profile.new(42, NOW - 86400)
	saved.onboarding = nil
	return Profile.prepare(saved, 42, NOW)
end

tests["the steps follow Appendix C in order, with stable ids"] = function()
	local ids = {}
	for i, step in STEPS do
		ids[i] = step.id
	end
	expect.eq(
		table.concat(ids, ","),
		"hatch,place,collect,buyEgg,stealHome,raidLogTip",
		"persisted meaning: append only once shipped"
	)
	expect.eq(LAST, #STEPS)
	expect.truthy(table.isfrozen(STEPS :: any), "the list is frozen")
	local covered: { [number]: boolean } = {}
	local previous = 0
	for i, step in STEPS do
		expect.truthy(table.isfrozen(step :: any), `{step.id} is frozen`)
		expect.truthy(step.by == "Server" or step.by == "Client", `{step.id} has a kind`)
		expect.truthy(step.appendix >= previous, "Appendix C order")
		previous = step.appendix
		covered[step.appendix] = true
		expect.eq(Profile.onboardingStepIndex(step.id), i)
	end
	for line = 1, 5 do
		expect.truthy(covered[line], `Appendix C line {line} has a step (6 is a shield, 7 is not onboarding)`)
	end
	expect.falsy(covered[6] or covered[7])
	expect.eq(STEPS[#STEPS].by, "Client", "the raid log line is the client's to acknowledge")
	for i = 1, #STEPS - 1 do
		expect.eq(STEPS[i].by, "Server", `{STEPS[i].id} advances from a real server event`)
	end
	for _, bad in { nil, 1, "", "HATCH", "hatch ", {}, true } :: { any } do
		expect.eq(Profile.onboardingStepIndex(bad), nil, `{bad} is not a step`)
	end
end

tests["a new save starts at the first step"] = function()
	local status = Profile.onboardingStatus(newPlayer())
	expect.eq(status.step, 0)
	expect.eq(status.nextStepId, "hatch")
	expect.eq(status.complete, false)
end

tests["server events move onboarding forward only, and may jump over earlier steps"] = function()
	local p = newPlayer()
	expect.truthy(Profile.advanceOnboardingTo(p, "hatch", NOW + 10))
	expect.eq(Profile.onboardingStep(p), 1)
	expect.falsy(Profile.advanceOnboardingTo(p, "hatch", NOW + 11), "a repeat changes nothing")
	expect.truthy(Profile.advanceOnboardingTo(p, "collect", NOW + 20), "place was skipped (auto-placed)")
	expect.eq(Profile.onboardingStep(p), 3)
	expect.falsy(Profile.advanceOnboardingTo(p, "place", NOW + 21), "a late earlier event never goes back")
	expect.eq(Profile.onboardingStep(p), 3)
	expect.truthy(Profile.advanceOnboardingTo(p, "buyEgg", NOW + 30))
	expect.truthy(Profile.advanceOnboardingTo(p, "stealHome", NOW + 40))
	expect.eq(Profile.onboardingStep(p), 5)
	expect.falsy(Profile.isOnboardingComplete(p), "the raid log line is still to come")
	local status = Profile.onboardingStatus(p)
	expect.eq(status.nextStepId, "raidLogTip")
	expect.eq(status.complete, false)
end

tests["a server event cannot complete a client step, nor a client ack a server step"] = function()
	local p = newPlayer()
	Profile.advanceOnboardingTo(p, "stealHome", NOW)
	expect.falsy(Profile.advanceOnboardingTo(p, "raidLogTip", NOW), "client steps are the client's")
	expect.eq(Profile.onboardingStep(p), 5)
	local q = newPlayer()
	for _, id in { "hatch", "place", "collect", "buyEgg", "stealHome" } do
		expect.eq(Profile.acknowledgeOnboarding(q, id, NOW), "Refused", `the client cannot claim {id}`)
	end
	expect.eq(Profile.onboardingStep(q), 0, "nothing written")
end

tests["a client ack is accepted only as the very next step, and a repeat is harmless"] = function()
	local p = newPlayer()
	expect.eq(Profile.acknowledgeOnboarding(p, "raidLogTip", NOW), "Refused", "cannot skip ahead from step 0")
	Profile.advanceOnboardingTo(p, "buyEgg", NOW)
	expect.eq(Profile.acknowledgeOnboarding(p, "raidLogTip", NOW), "Refused", "still not the next step")
	expect.eq(Profile.onboardingStep(p), 4)
	Profile.advanceOnboardingTo(p, "stealHome", NOW + 5)
	expect.eq(Profile.acknowledgeOnboarding(p, "raidLogTip", NOW + 9), "Advanced")
	expect.truthy(Profile.isOnboardingComplete(p), "the last step finishes onboarding")
	expect.eq(p.onboarding.step, LAST)
	expect.eq(p.onboarding.completedAt, NOW + 9)
	expect.eq(Profile.acknowledgeOnboarding(p, "raidLogTip", NOW + 20), "AlreadyDone")
	expect.eq(p.onboarding.completedAt, NOW + 9, "the first finish time is kept")
	local status = Profile.onboardingStatus(p)
	expect.eq(status.step, LAST)
	expect.eq(status.nextStepId, nil)
	expect.eq(status.complete, true)
end

tests["unknown or malformed ids are refused, writing nothing"] = function()
	local p = newPlayer()
	for _, bad in { nil, 1, 0 / 0, "", "HATCH", "raidLogTip ", {}, true } :: { any } do
		expect.falsy(Profile.advanceOnboardingTo(p, bad, NOW), `server {bad}`)
		expect.eq(Profile.acknowledgeOnboarding(p, bad, NOW), "Refused", `client {bad}`)
	end
	expect.eq(p.onboarding.step, 0)
	expect.eq(p.onboarding.completedAt, nil)
end

tests["a NaN or infinite server time is refused"] = function()
	local p = newPlayer()
	expect.falsy(Profile.advanceOnboardingTo(p, "hatch", 0 / 0))
	expect.falsy(Profile.advanceOnboardingTo(p, "hatch", math.huge))
	Profile.advanceOnboardingTo(p, "stealHome", NOW)
	expect.eq(Profile.acknowledgeOnboarding(p, "raidLogTip", 0 / 0), "Refused")
	expect.eq(Profile.onboardingStep(p), 5)
	expect.eq(p.onboarding.completedAt, nil)
end

tests["a save from before onboarding stays finished, whatever happens"] = function()
	local p = oldSave()
	for _, step in STEPS do
		expect.falsy(Profile.advanceOnboardingTo(p, step.id, NOW), `{step.id} does not restart it`)
		local ack = Profile.acknowledgeOnboarding(p, step.id, NOW)
		expect.eq(ack, if step.by == "Client" then "AlreadyDone" else "Refused", `ack {step.id}`)
	end
	expect.eq(p.onboarding, nil, "nothing was written")
	local status = Profile.onboardingStatus(p)
	expect.eq(status.step, LAST)
	expect.eq(status.nextStepId, nil)
	expect.eq(status.complete, true)
end

tests["after a skip no step advances and the client sees it complete"] = function()
	local p = newPlayer()
	Profile.advanceOnboardingTo(p, "place", NOW)
	expect.truthy(Profile.completeOnboarding(p, NOW + 5))
	expect.falsy(Profile.advanceOnboardingTo(p, "collect", NOW + 6))
	expect.eq(Profile.acknowledgeOnboarding(p, "raidLogTip", NOW + 6), "AlreadyDone")
	local status = Profile.onboardingStatus(p)
	expect.eq(status.step, 2, "analytics still sees where they left")
	expect.eq(status.nextStepId, nil)
	expect.eq(status.complete, true)
end

tests["steps never go backwards: random server events, acks, skips and junk, many seeds"] = function()
	local ids: { any } = { "hatch", "place", "collect", "buyEgg", "stealHome", "raidLogTip", "nope", 3, nil }
	for seed = 1, 40 do
		local r = rng.new(seed)
		local p = if r.chance(0.1) then oldSave() else newPlayer()
		local lastStep = Profile.onboardingStep(p)
		local wasComplete = Profile.isOnboardingComplete(p)
		local finishedAt = if p.onboarding then p.onboarding.completedAt else nil
		for i = 1, 200 do
			local now = if r.chance(0.05) then 0 / 0 else NOW + i
			local id = ids[r.int(1, #ids)]
			local roll = r.next()
			if roll < 0.55 then
				Profile.advanceOnboardingTo(p, id, now)
			elseif roll < 0.95 then
				Profile.acknowledgeOnboarding(p, id, now)
			elseif roll < 0.97 then
				Profile.completeOnboarding(p, now)
			else
				Profile.advanceOnboarding(p, r.int(-1, LAST + 1), now)
			end
			local step = Profile.onboardingStep(p)
			local complete = Profile.isOnboardingComplete(p)
			local where = `seed {seed} op {i}`
			expect.truthy(step >= lastStep, `{where}: the step went back from {lastStep} to {step}`)
			expect.truthy(step >= 0 and step <= LAST and step % 1 == 0, `{where}: step {step} out of range`)
			expect.truthy(complete or not wasComplete, `{where}: a finished onboarding restarted`)
			if finishedAt ~= nil then
				expect.eq(p.onboarding.completedAt, finishedAt, `{where}: the finish time changed`)
			elseif p.onboarding and p.onboarding.completedAt ~= nil then
				finishedAt = p.onboarding.completedAt
				expect.truthy(finishedAt == finishedAt, `{where}: a NaN finish time was saved`)
			end
			local status = Profile.onboardingStatus(p)
			expect.eq(status.step, step)
			expect.eq(status.complete, complete)
			expect.eq(status.nextStepId, if complete then nil else STEPS[step + 1].id, `{where}: next step`)
			lastStep, wasComplete = step, complete
		end
	end
end

-- Server handlers (DataService, which Lune cannot run): source guards ----------------------------

local function dataServiceCode(): string
	return source.codeOnly(source.read("src/Server/Services/DataService.luau"))
end

local function body(code: string, name: string): string
	local found = source.functionBody(code, name)
	assert(found, `{name} not found in DataService.luau`)
	return found
end

local function has(text: string, needle: string, message: string)
	expect.truthy(string.find(text, needle, 1, true), message)
end

local function hasNot(text: string, needle: string, message: string)
	expect.eq(string.find(text, needle, 1, true), nil, message)
end

tests["the onboarding remotes are named in Net"] = function()
	expect.eq(Net.Requests.GetOnboarding, "GetOnboarding")
	expect.eq(Net.Requests.AckOnboarding, "AckOnboarding")
	expect.eq(Net.Pushes.OnboardingChanged, "OnboardingChanged")
end

tests["DataService.advanceOnboarding takes server steps on the server's clock, never yields or saves"] = function()
	local advance = body(dataServiceCode(), "DataService.advanceOnboarding")
	has(advance, "Profile.advanceOnboardingTo(profile, stepId, os.time())", "server steps only, server time")
	has(advance, "pushOnboarding(userId, profile)", "the client hears about it")
	for _, banned in { "task.wait", "task.delay", "saveNow", ":Wait(", "coroutine.yield" } do
		hasNot(advance, banned, `no {banned}`)
	end
	local push = body(dataServiceCode(), "pushOnboarding")
	has(push, "pcall(remote.FireClient", "a failed push never errors into the caller's event")
end

tests["AckOnboarding is rate-limited and accepts only the pure rule's next client step"] = function()
	local ack = body(dataServiceCode(), "onAckOnboarding")
	has(ack, "take(player, Net.Requests.AckOnboarding, Net.Limits.AckOnboarding)", "rate-limited")
	has(ack, "Profile.acknowledgeOnboarding(profile, stepId, os.time())", "server time, pure rule")
	hasNot(ack, "Profile.advanceOnboarding(", "never the unchecked numeric advance")
	hasNot(ack, "advanceOnboardingTo", "never a server step")
	hasNot(ack, "saveNow", "never forces a save")
end

tests["GetOnboarding is rate-limited and waits a bounded time for the profile"] = function()
	local get = body(dataServiceCode(), "onGetOnboarding")
	has(get, "take(player, Net.Requests.GetOnboarding, Net.Limits.GetOnboarding)", "rate-limited")
	has(get, "awaitProfile(player, Net.Requests.GetOnboarding)", "bounded wait")
	has(get, "Profile.onboardingStatus(profile)", "the status the push also sends")
end

return tests
