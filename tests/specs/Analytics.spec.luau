--!strict
-- Analytics schema (P2.9): every Appendix A event, its validation, the funnels, the economy flows
-- and the budget. Roblox limits used below are from the public AnalyticsService docs.
local expect = require("../lib/expect")
local rng = require("../lib/rng")
local source = require("../lib/source")
local Analytics = require("../../src/Shared/Analytics")
local CritterCatalog = require("../../src/Shared/CritterCatalog")
local Profile = require("../../src/Shared/Profile")

local NOW = 1_800_000_000

-- One valid call per event, as a caller would make it.
local EXAMPLES: { [string]: { [string]: any } } = {
	onboarding_step = { step = 2, secondsSinceJoin = 45 },
	egg_bought = { tier = "Uncommon", price = 250, denLevel = 2 },
	critter_placed = { tier = "Common", placement = "Pad" },
	glow_collected = { amount = 120, storageFill = 0.6 },
	raid_portal_opened = { targetsOffered = 4, revengeAvailable = true },
	raid_started = { mode = "Async", revenge = false, targetPower = 340 },
	raid_ended = { mode = "Async", escaped = true, tierTaken = "Rare", glow = 80, durationSeconds = 95 },
	raided_offline = { tierLost = "None", glowLost = 30, revenge = false, attributedTo = "Raider" },
	raid_log_opened = { entriesSinceLastVisit = 3 },
	revenge_started = { hoursSinceRaided = 5.5, fromNotification = true, mode = "Async" },
	notification_sent = { category = "revenge", result = "Sent" },
	notification_join = { category = "revenge" },
	optin_prompted = { trigger = "FirstSuccessfulRaid" },
	optin_result = { accepted = false },
	purchase = { product = "VipPass", price = 399 },
	rebirth = { count = 1, daysSinceJoin = 4.2 },
	session_end = { sessionSeconds = 640, raids = 2, steals = 1 },
}

local function eventNames(): { string }
	local names = {}
	for name in Analytics.EVENTS do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

-- The event names in the playbook's Appendix A table.
local function appendixA(): { [string]: true }
	local text = source.read("docs/playbook.md")
	local first = string.find(text, "# Appendix A: Analytics events", 1, true)
	local last = string.find(text, "Funnels:", first, true)
	expect.truthy(first and last, "Appendix A found")
	local names = {}
	for line in string.gmatch(string.sub(text, first :: number, last :: number), "[^\n]+") do
		local cell = string.match(line, "^| (`[^|]+)|")
		if cell then
			for name in string.gmatch(cell, "`([%w_]+)`") do
				names[name] = true
			end
		end
	end
	return names
end

local function with(base: { [string]: any }, key: string, value: any): { [string]: any }
	local copy = table.clone(base)
	copy[key] = value
	return copy
end

local tests = {}

-- Coverage -------------------------------------------------------------------------------------

tests["the schema has exactly the events in playbook Appendix A"] = function()
	local wanted = appendixA()
	local count = 0
	for name in wanted do
		count += 1
		expect.truthy(Analytics.EVENTS[name], `Appendix A event {name} is in the schema`)
	end
	expect.eq(count, 17, "Appendix A lists 17 event names")
	for name in Analytics.EVENTS do
		expect.truthy(wanted[name], `{name} is an Appendix A event`)
	end
end

tests["every event has a valid example, and every example's event exists"] = function()
	for _, name in eventNames() do
		local example = EXAMPLES[name]
		expect.truthy(example, `example for {name}`)
		local ok, why = Analytics.validate(name, example)
		expect.truthy(ok, `{name} example validates: {why}`)
	end
	for name in EXAMPLES do
		expect.truthy(Analytics.EVENTS[name], `{name} exists`)
	end
end

tests["shared vocabularies match the catalog and the profile"] = function()
	expect.eq(#Analytics.TIERS, #CritterCatalog.TIER_ORDER, "same tier count")
	for index, tier in CritterCatalog.TIER_ORDER do
		expect.eq(Analytics.TIERS[index], tier, "same tier order")
	end
	expect.eq(Analytics.ONBOARDING_LAST_STEP, Profile.ONBOARDING_LAST_STEP, "every onboarding step")
end

tests["onboarding_step takes exactly the profile's onboarding steps, labelled by position and id"] = function()
	local spec = Analytics.EVENTS.onboarding_step
	expect.eq(spec.fields.step.min, 1, "the first step")
	expect.eq(spec.fields.step.max, Profile.ONBOARDING_LAST_STEP, "the last step")
	local slot = spec.slots[1]
	expect.eq(slot.field, "step")
	local bounds, labels = slot.bounds :: { number }, slot.labels :: { string }
	expect.eq(#bounds, #Profile.ONBOARDING_STEPS, "one bucket per step")
	for index, step in Profile.ONBOARDING_STEPS do
		expect.eq(bounds[index], index, `bucket {index} is step {index}`)
		expect.eq(labels[index], `{index} {step.id}`, `step {index} is labelled with its id`)
		local fields = { step = index, secondsSinceJoin = 10 }
		expect.truthy((Analytics.validate("onboarding_step", fields)), `step {index} ({step.id}) validates`)
		local payload = Analytics.encode("onboarding_step", fields) :: Analytics.Payload
		expect.eq(payload.slots[1], `Step - {index} {step.id}`)
	end
end

tests["the onboarding funnel names real onboarding steps, and FirstRaid stays raid-driven"] = function()
	local mapped: { [string]: boolean } = {}
	for id, name in Analytics.ONBOARDING_FUNNEL do
		expect.truthy(Profile.onboardingStepIndex(id), `{id} is a Profile onboarding step`)
		expect.truthy(Analytics.funnelStep("Onboarding", name), `{name} is an Onboarding funnel step`)
		expect.falsy(mapped[name], `{name} comes from one step`)
		mapped[name] = true
	end
	expect.eq(Analytics.ONBOARDING_FUNNEL.hatch, "FirstHatch")
	expect.eq(Analytics.ONBOARDING_FUNNEL.collect, "FirstCollect")
	expect.eq(Analytics.ONBOARDING_FUNNEL.stealHome, "FirstSteal")
	expect.falsy(mapped.FirstRaid, "FirstRaid comes from an async raid_started, not onboarding")
	expect.falsy(mapped.Join, "Join comes from the session start")
end

-- Schema shape (Roblox limits) -----------------------------------------------------------------

tests["event names are short snake_case and within Roblox's 100 custom events"] = function()
	local names = eventNames()
	expect.truthy(#names <= Analytics.MAX_EVENTS, "at most 100 event names")
	for _, name in names do
		expect.truthy(string.match(name, "^%l[%l_]*%l$"), `{name} is snake_case`)
		expect.truthy(#name <= 50, `{name} is short`)
	end
end

tests["every event has at most 3 custom fields, each rendering a declared field"] = function()
	for _, name in eventNames() do
		local spec = Analytics.EVENTS[name]
		expect.truthy(#spec.slots <= Analytics.MAX_SLOTS, `{name}: at most 3 custom fields`)
		local seen: { [string]: boolean } = {}
		for _, slot in spec.slots do
			local field = spec.fields[slot.field]
			expect.truthy(field, `{name}: slot {slot.field} is a field`)
			expect.falsy(seen[slot.label], `{name}: labels differ`)
			seen[slot.label] = true
			if field.kind == "number" then
				expect.truthy(slot.bounds and slot.labels, `{name}: number {slot.field} is bucketed, never raw`)
			else
				expect.falsy(slot.bounds, `{name}: only numbers are bucketed`)
			end
		end
		if spec.value then
			expect.eq(spec.fields[spec.value].kind, "number", `{name}: value is a number field`)
		end
	end
end

tests["buckets ascend from the field's minimum and have one label per bound"] = function()
	for _, name in eventNames() do
		local spec = Analytics.EVENTS[name]
		for _, slot in spec.slots do
			local bounds, labels = slot.bounds, slot.labels
			if bounds and labels then
				expect.eq(#bounds, #labels, `{name}.{slot.field}: one label per bound`)
				expect.eq(bounds[1], spec.fields[slot.field].min or 0, `{name}.{slot.field}: starts at the minimum`)
				for index = 2, #bounds do
					expect.truthy(bounds[index] > bounds[index - 1], `{name}.{slot.field}: ascending`)
				end
				local unique: { [string]: boolean } = {}
				for _, label in labels do
					expect.falsy(unique[label], `{name}.{slot.field}: labels unique`)
					unique[label] = true
				end
			end
		end
	end
end

tests["no event can exceed Roblox's 8,000 custom-field combinations"] = function()
	local PRODUCTS = 50 -- generous: an id field is a server product key
	for _, name in eventNames() do
		local spec = Analytics.EVENTS[name]
		local combinations = 1
		for _, slot in spec.slots do
			local field = spec.fields[slot.field]
			local options = if field.kind == "bool"
				then 2
				elseif field.kind == "enum" then #(field.values :: { string })
				elseif field.kind == "id" then PRODUCTS
				else #(slot.labels :: { string })
			combinations *= options
		end
		expect.truthy(combinations <= Analytics.MAX_COMBINATIONS, `{name}: {combinations} combinations`)
	end
end

tests["no event carries a user id, a name or free text"] = function()
	local forbidden = { "userid", "name", "displayname", "username", "raidername", "text", "message", "raidid" }
	for _, name in eventNames() do
		for field, spec in Analytics.EVENTS[name].fields do
			for _, word in forbidden do
				expect.falsy(string.find(string.lower(field), word, 1, true), `{name}.{field} is not identifying`)
			end
			expect.truthy(
				spec.kind == "enum" or spec.kind == "bool" or spec.kind == "number" or spec.kind == "id",
				`{name}.{field} has a closed kind`
			)
		end
	end
end

-- Validation ---------------------------------------------------------------------------------

tests["validate refuses unknown events, non-tables, unknown and missing fields"] = function()
	expect.falsy((Analytics.validate("not_an_event", {})), "unknown event")
	expect.falsy((Analytics.validate(nil, {})), "nil event")
	expect.falsy((Analytics.validate("optin_result", nil)), "nil fields")
	expect.falsy((Analytics.validate("optin_result", "yes")), "string fields")
	local example = EXAMPLES.raided_offline
	expect.falsy((Analytics.validate("raided_offline", with(example, "userId", 42))), "userId is not a field")
	expect.falsy((Analytics.validate("raided_offline", with(example, "raidId", "abc"))), "raidId is not a field")
	expect.falsy((Analytics.validate("raided_offline", with(example, "tierLost", nil))), "missing field")
	expect.falsy((Analytics.validate("optin_result", { accepted = true, [1] = "x" })), "array key")
end

tests["validate refuses wrong types, bad numbers and values outside an enum"] = function()
	local ended = EXAMPLES.raid_ended
	expect.falsy((Analytics.validate("raid_ended", with(ended, "escaped", "true"))), "bool as string")
	expect.falsy((Analytics.validate("raid_ended", with(ended, "glow", "80"))), "number as string")
	expect.falsy((Analytics.validate("raid_ended", with(ended, "glow", 0 / 0))), "NaN")
	expect.falsy((Analytics.validate("raid_ended", with(ended, "glow", math.huge))), "inf")
	expect.falsy((Analytics.validate("raid_ended", with(ended, "glow", -1))), "negative")
	expect.falsy((Analytics.validate("raid_ended", with(ended, "tierTaken", "rare"))), "case matters")
	expect.falsy((Analytics.validate("raid_ended", with(ended, "tierTaken", "Ultra"))), "not a tier")
	expect.falsy((Analytics.validate("raid_ended", with(ended, "mode", "Solo"))), "not a mode")
	local step = EXAMPLES.onboarding_step
	expect.falsy((Analytics.validate("onboarding_step", with(step, "step", 0))), "below the first step")
	expect.truthy((Analytics.validate("onboarding_step", with(step, "step", 6))), "the last step (raidLogTip)")
	expect.falsy(
		(Analytics.validate("onboarding_step", with(step, "step", Profile.ONBOARDING_LAST_STEP + 1))),
		"past the last step"
	)
	expect.falsy((Analytics.validate("onboarding_step", with(step, "step", 2.5))), "not whole")
	expect.falsy((Analytics.validate("session_end", with(EXAMPLES.session_end, "raids", 1.5))), "count not whole")
	expect.falsy((Analytics.validate("rebirth", with(EXAMPLES.rebirth, "count", 0))), "rebirth count from 1")
	expect.truthy((Analytics.validate("raid_ended", with(ended, "glow", 0))), "zero is fine")
	expect.truthy((Analytics.validate("raid_ended", with(ended, "tierTaken", "None"))), "None is a tier taken")
end

tests["an id field takes only a short server identifier, never player-typed text"] = function()
	local base = EXAMPLES.purchase
	for _, good in { "VipPass", "lantern_night", "Shield24h" } do
		expect.truthy((Analytics.validate("purchase", with(base, "product", good))), good)
	end
	local bad = { "", "Vip Pass", "vip-pass", "1Shield", "hello world!", "<b>x</b>", string.rep("a", 33), 12 }
	for _, value in bad do
		expect.falsy((Analytics.validate("purchase", with(base, "product", value))), `refuses {tostring(value)}`)
	end
end

-- Encoding -------------------------------------------------------------------------------------

tests["encode sends the value field and readable custom fields"] = function()
	local payload = Analytics.encode("raid_ended", EXAMPLES.raid_ended)
	expect.truthy(payload, "encoded")
	local p = payload :: Analytics.Payload
	expect.eq(p.value, 80, "value is the glow")
	expect.eq(#p.slots, 3, "three custom fields")
	expect.eq(p.slots[1], "Escaped - Yes")
	expect.eq(p.slots[2], "Tier taken - Rare")
	expect.eq(p.slots[3], "Duration - 1-2m")
	local counter = Analytics.encode("critter_placed", EXAMPLES.critter_placed) :: Analytics.Payload
	expect.eq(counter.value, 1, "an event without a value counts 1")
	expect.eq(counter.slots[2], "Placement - Pad")
	local refused, why = Analytics.encode("raid_ended", with(EXAMPLES.raid_ended, "glow", -5))
	expect.eq(refused, nil, "invalid input encodes nothing")
	expect.truthy(why, "and says why")
end

tests["buckets put edge values in the right place"] = function()
	local function fill(share: number): string
		local p = Analytics.encode("glow_collected", { amount = 1, storageFill = share }) :: Analytics.Payload
		return p.slots[1]
	end
	expect.eq(fill(0), "Storage - 0-25%")
	expect.eq(fill(0.25), "Storage - 25-50%")
	expect.eq(fill(0.98), "Storage - 75-99%")
	expect.eq(fill(0.99), "Storage - Full")
	expect.eq(fill(1.4), "Storage - Full", "past the cap is Full")
	local function count(n: number): string
		return (Analytics.encode("raid_log_opened", { entriesSinceLastVisit = n }) :: Analytics.Payload).slots[1]
	end
	expect.eq(count(0), "New entries - 0")
	expect.eq(count(1), "New entries - 1")
	expect.eq(count(3), "New entries - 2-3")
	expect.eq(count(4), "New entries - 4-7")
	expect.eq(count(500), "New entries - 16+")
	local step = Analytics.encode("onboarding_step", { step = 5, secondsSinceJoin = 200 }) :: Analytics.Payload
	expect.eq(step.slots[1], "Step - 5 stealHome")
	expect.eq(step.slots[2], "Since join - 3-5m")
	expect.eq(step.value, 200)
end

-- Funnels -------------------------------------------------------------------------------------

tests["the two funnels have the playbook's steps in order"] = function()
	local onboarding = Analytics.FUNNELS.Onboarding
	local raidFlow = Analytics.FUNNELS.RaidFlow
	expect.eq(table.concat(onboarding, ">"), "Join>FirstHatch>FirstCollect>FirstSteal>FirstRaid")
	expect.eq(table.concat(raidFlow, ">"), "Portal>TargetPicked>RaidStarted>Escaped")
	local picked = Analytics.funnelStep("RaidFlow", "TargetPicked") :: Analytics.FunnelStep
	expect.eq(picked.step, 2)
	expect.eq((Analytics.funnelStep("Onboarding", "FirstRaid") :: Analytics.FunnelStep).step, 5)
	expect.eq(Analytics.funnelStep("RaidFlow", "Nope"), nil, "unknown step")
	expect.eq(Analytics.funnelStep("Shop", "Portal"), nil, "unknown funnel")
end

local function stepNames(event: string, fields: { [string]: any }): string
	local names = {}
	for _, step in Analytics.funnelSteps(event, fields) do
		table.insert(names, `{step.funnel}.{step.name}`)
	end
	return table.concat(names, ",")
end

tests["events complete their funnel steps"] = function()
	-- Onboarding steps by id, wherever they sit in Profile.ONBOARDING_STEPS (C6b: 6 steps).
	local expected = {
		hatch = "Onboarding.FirstHatch",
		place = "",
		collect = "Onboarding.FirstCollect",
		buyEgg = "",
		stealHome = "Onboarding.FirstSteal",
		raidLogTip = "",
	}
	for index, step in Profile.ONBOARDING_STEPS do
		local want = expected[step.id]
		expect.truthy(want, `{step.id} has an expected funnel step`)
		local got = stepNames("onboarding_step", { step = index, secondsSinceJoin = 5 })
		expect.eq(got, want, `onboarding step {index} ({step.id})`)
	end
	expect.eq(stepNames("onboarding_step", { step = 1, secondsSinceJoin = 5 }), "Onboarding.FirstHatch")
	expect.eq(stepNames("onboarding_step", { step = 3, secondsSinceJoin = 5 }), "Onboarding.FirstCollect")
	expect.eq(stepNames("onboarding_step", { step = 5, secondsSinceJoin = 5 }), "Onboarding.FirstSteal")
	expect.eq(stepNames("egg_bought", EXAMPLES.egg_bought), "Onboarding.FirstHatch")
	expect.eq(stepNames("glow_collected", EXAMPLES.glow_collected), "Onboarding.FirstCollect")
	expect.eq(stepNames("raid_portal_opened", EXAMPLES.raid_portal_opened), "RaidFlow.Portal")
	expect.eq(stepNames("raid_started", EXAMPLES.raid_started), "RaidFlow.RaidStarted,Onboarding.FirstRaid")
	expect.eq(stepNames("raid_started", with(EXAMPLES.raid_started, "mode", "Live")), "RaidFlow.RaidStarted")
	expect.eq(stepNames("raid_ended", EXAMPLES.raid_ended), "RaidFlow.Escaped,Onboarding.FirstSteal")
	expect.eq(stepNames("raid_ended", with(EXAMPLES.raid_ended, "tierTaken", "None")), "RaidFlow.Escaped")
	expect.eq(stepNames("raid_ended", with(EXAMPLES.raid_ended, "escaped", false)), "", "caught: no step")
	expect.eq(stepNames("session_end", EXAMPLES.session_end), "")
	expect.truthy(Analytics.endsRaidFlow("raid_ended"))
	expect.falsy(Analytics.endsRaidFlow("raid_started"))
end

tests["a RaidFlow session opens at the portal, carries through, and closes at the escape"] = function()
	local id, open = Analytics.raidFlowSession(nil, "Portal", "A")
	expect.eq(id, "A")
	expect.eq(open, "A")
	id, open = Analytics.raidFlowSession(open, "TargetPicked", "B")
	expect.eq(id, "A", "same trip")
	id, open = Analytics.raidFlowSession(open, "RaidStarted", "C")
	expect.eq(id, "A")
	id, open = Analytics.raidFlowSession(open, "Escaped", "D")
	expect.eq(id, "A")
	expect.eq(open, nil, "closed")
	id, open = Analytics.raidFlowSession("A", "Portal", "E")
	expect.eq(id, "E", "a new portal is a new trip")
	id, open = Analytics.raidFlowSession(nil, "RaidStarted", "F")
	expect.eq(id, "F", "no portal (revenge from a notification) opens one")
	expect.eq(open, "F")
end

tests["the onboarding funnel window is the first 7 days after the first join"] = function()
	expect.truthy(Analytics.inOnboardingWindow(NOW, NOW), "the first join")
	expect.truthy(Analytics.inOnboardingWindow(NOW, NOW + 7 * 86400 - 1))
	expect.falsy(Analytics.inOnboardingWindow(NOW, NOW + 7 * 86400), "a week later")
	expect.falsy(Analytics.inOnboardingWindow(NOW, NOW - 10), "a clock before the first join")
	expect.falsy(Analytics.inOnboardingWindow(0 / 0, NOW), "NaN createdAt")
	expect.falsy(Analytics.inOnboardingWindow(nil, NOW), "missing createdAt")
	expect.falsy(Analytics.inOnboardingWindow(NOW, math.huge), "inf now")
end

tests["an advance logs one onboarding_step per step it completed, with seconds since join"] = function()
	local created = NOW - 75
	local one = Analytics.onboardingStepEvents(0, 1, created, NOW)
	expect.eq(#one, 1, "one step")
	expect.eq(one[1].step, 1)
	expect.eq(one[1].secondsSinceJoin, 75)
	local jump = Analytics.onboardingStepEvents(1, 4, created, NOW)
	expect.eq(#jump, 3, "a jump logs every step it passed")
	for offset, fields in jump do
		expect.eq(fields.step, 1 + offset, "in order")
		expect.eq(fields.secondsSinceJoin, 75)
		local ok, why = Analytics.validate("onboarding_step", fields)
		expect.truthy(ok, `step {fields.step} validates: {why}`)
	end
	local last = Profile.ONBOARDING_LAST_STEP
	local finish = Analytics.onboardingStepEvents(last - 1, last, created, NOW)
	expect.eq(#finish, 1)
	expect.eq(finish[1].step, last, "the last step (the client's raid log tip) is logged too")
	expect.eq(Analytics.onboardingStepEvents(0, 1, NOW + 30, NOW)[1].secondsSinceJoin, 0, "a clock behind join")
	-- Nothing moved, or nothing trustworthy: no events.
	expect.eq(#Analytics.onboardingStepEvents(2, 2, created, NOW), 0, "a repeat")
	expect.eq(#Analytics.onboardingStepEvents(3, 2, created, NOW), 0, "backwards")
	expect.eq(#Analytics.onboardingStepEvents(-1, 2, created, NOW), 0, "below zero")
	expect.eq(#Analytics.onboardingStepEvents(0, last + 1, created, NOW), 0, "past the last step")
	expect.eq(#Analytics.onboardingStepEvents(0, 1.5, created, NOW), 0, "not whole")
	expect.eq(#Analytics.onboardingStepEvents(nil, 1, created, NOW), 0, "no step count")
	expect.eq(#Analytics.onboardingStepEvents(0, 1, 0 / 0, NOW), 0, "NaN createdAt")
	expect.eq(#Analytics.onboardingStepEvents(0, 1, nil, NOW), 0, "missing createdAt")
	expect.eq(#Analytics.onboardingStepEvents(0, 1, created, math.huge), 0, "inf now")
end

tests["every onboarding path, step by step or jumping, logs each step exactly once"] = function()
	-- Random server events and acks against the real Profile rules, as DataService drives them.
	local last = Profile.ONBOARDING_LAST_STEP
	for seed = 1, 50 do
		local r = rng.new(seed)
		local profile = Profile.new(seed, NOW)
		local logged: { [number]: number } = {}
		local now = NOW
		for _ = 1, 40 do
			now += r.int(0, 30)
			local step = Profile.ONBOARDING_STEPS[r.int(1, last)]
			local before = Profile.onboardingStep(profile)
			local wrote = if step.by == "Server"
				then Profile.advanceOnboardingTo(profile, step.id, now)
				else Profile.acknowledgeOnboarding(profile, step.id, now) == "Advanced"
			if wrote then
				for _, fields in Analytics.onboardingStepEvents(before, Profile.onboardingStep(profile), NOW, now) do
					logged[fields.step] = (logged[fields.step] or 0) + 1
				end
			end
		end
		for index = 1, Profile.onboardingStep(profile) do
			expect.eq(logged[index], 1, `seed {seed}: step {index} logged once`)
		end
		for index = Profile.onboardingStep(profile) + 1, last do
			expect.eq(logged[index], nil, `seed {seed}: step {index} not reached, not logged`)
		end
	end
end

-- Session, raid log, budget -----------------------------------------------------------------

tests["the session counts raids started and critters stolen"] = function()
	local counts = { raids = 0, steals = 0 }
	Analytics.countSession(counts, "raid_started", EXAMPLES.raid_started)
	Analytics.countSession(counts, "raid_started", with(EXAMPLES.raid_started, "mode", "Live"))
	Analytics.countSession(counts, "raid_ended", EXAMPLES.raid_ended)
	Analytics.countSession(counts, "raid_ended", with(EXAMPLES.raid_ended, "tierTaken", "None"))
	Analytics.countSession(counts, "raid_ended", with(EXAMPLES.raid_ended, "escaped", false))
	Analytics.countSession(counts, "glow_collected", EXAMPLES.glow_collected)
	expect.eq(counts.raids, 2)
	expect.eq(counts.steals, 1, "only escapes that took a critter")
end

tests["raid log entries since the last visit"] = function()
	local log = { { at = NOW - 10 }, { at = NOW - 100 }, { at = NOW - 1000 }, "junk", { at = 0 / 0 } }
	expect.eq(Analytics.entriesSince(log, NOW - 500), 2)
	expect.eq(Analytics.entriesSince(log, NOW - 10), 0, "strictly newer")
	expect.eq(Analytics.entriesSince(log, nil), 3, "never visited: every valid entry")
	expect.eq(Analytics.entriesSince(log, 0 / 0), 3, "a corrupt visit time counts as never")
	expect.eq(Analytics.entriesSince(nil, NOW), 0)
end

tests["the budget allows a burst, then refills at its rate"] = function()
	local budget = Analytics.newBudget(100)
	for i = 1, Analytics.BUDGET_CAPACITY do
		expect.truthy(Analytics.take(budget, 100), `burst {i}`)
	end
	expect.falsy(Analytics.take(budget, 100), "empty")
	local perToken = 60 / Analytics.BUDGET_REFILL_PER_MINUTE
	expect.falsy(Analytics.take(budget, 100 + perToken * 0.5), "half a token is not enough")
	expect.truthy(Analytics.take(budget, 100 + perToken * 1.01), "one token later")
	expect.falsy(Analytics.take(budget, 0 / 0), "NaN refills nothing")
	expect.falsy(Analytics.take(budget, 50), "a backwards clock refills nothing")
	local later = Analytics.newBudget(0)
	later.tokens = 0
	Analytics.take(later, 1e9)
	expect.truthy(later.tokens <= Analytics.BUDGET_CAPACITY, "never past capacity")
	-- 15 a minute per player keeps a server under Roblox's 120 + 20 x CCU per minute.
	expect.truthy(Analytics.BUDGET_REFILL_PER_MINUTE < 20, "steady rate under 20 per player")
end

-- Economy -------------------------------------------------------------------------------------

tests["economy flows stay within Roblox's limits and standard transaction types"] = function()
	local currencies: { [string]: boolean } = {}
	local types: { [string]: boolean } = {}
	local skus: { [string]: boolean } = {}
	local standard = { "IAP", "TimedReward", "Onboarding", "Shop", "Gameplay", "ContextualPurchase" }
	local counted = { currencies = 0, types = 0, skus = 0 }
	for id, flow in Analytics.ECONOMY do
		expect.truthy(flow.flow == "Source" or flow.flow == "Sink", `{id} flow`)
		expect.truthy(flow.currency == "Glow" or flow.currency == "DenGlow", `{id} currency`)
		expect.truthy(table.find(standard, flow.transactionType), `{id} uses a standard transaction type`)
		expect.truthy(string.match(flow.sku, "^%u%w*$"), `{id} sku is an identifier`)
		if not currencies[flow.currency] then
			currencies[flow.currency] = true
			counted.currencies += 1
		end
		if not types[flow.transactionType] then
			types[flow.transactionType] = true
			counted.types += 1
		end
		local key = `{flow.currency}/{flow.sku}`
		expect.falsy(skus[key], `{key} is one flow`)
		skus[key] = true
		counted.skus += 1
	end
	expect.truthy(counted.currencies <= 10, "Roblox: 10 currencies")
	expect.truthy(counted.types <= 20, "Roblox: 20 transaction types before Other")
	expect.truthy(counted.skus <= 100, "Roblox: 100 skus before Other")
	-- A collect moves the same amount out of the den and into the bank.
	expect.eq(Analytics.ECONOMY.Collect.flow, "Source")
	expect.eq(Analytics.ECONOMY.DenCollect.flow, "Sink")
	expect.eq(Analytics.ECONOMY.DenRaided.currency, "DenGlow", "raids take stored Glow, never banked")
end

tests["economy refuses unknown flows, non-positive amounts and bad balances"] = function()
	expect.truthy((Analytics.economy("Egg", 250, 10)), "a valid sink")
	expect.falsy((Analytics.economy("Robux", 250, 10)), "unknown flow")
	expect.falsy((Analytics.economy(nil :: any, 250, 10)), "nil flow")
	expect.falsy((Analytics.economy("Egg", 0, 10)), "zero")
	expect.falsy((Analytics.economy("Egg", -250, 10)), "negative: Roblox wants positive amounts")
	expect.falsy((Analytics.economy("Egg", 0 / 0, 10)), "NaN amount")
	expect.falsy((Analytics.economy("Egg", 250, -1)), "negative balance")
	expect.falsy((Analytics.economy("Egg", 250, math.huge)), "inf balance")
end

-- NotificationService (P2.7) ---------------------------------------------------------------------

tests["NotificationService's track calls map onto the schema, dropping raidId"] = function()
	-- The calls exactly as PR #118 makes them.
	local calls: { { any } } = {
		{ "notification_sent", { userId = 7, category = "revenge", raidId = "r1" } },
		{ "notification_sent", { userId = 7, category = "storage" } },
		{ "notification_join", { userId = 7, raidId = "r1" } },
		{ "optin_prompted", { userId = 7 } },
		{ "optin_result", { userId = 7, accepted = true } },
	}
	for _, call in calls do
		local userId, fields = Analytics.fromNotification(call[1], call[2])
		expect.eq(userId, 7, `{call[1]} names its player`)
		expect.truthy(fields, `{call[1]} mapped`)
		expect.eq((fields :: any).raidId, nil, "raidId never reaches analytics")
		expect.eq((fields :: any).userId, nil, "userId is the Player, not a field")
		local ok, why = Analytics.validate(call[1], fields)
		expect.truthy(ok, `{call[1]} validates: {why}`)
	end
	local _, throttled =
		Analytics.fromNotification("notification_sent", { userId = 7, category = "revenge", result = "Throttled" })
	expect.eq((throttled :: any).result, "Throttled", "a throttled send keeps its result")
	expect.eq((Analytics.fromNotification("raid_started", { userId = 7 })), nil, "only its four events")
	expect.eq((Analytics.fromNotification("optin_result", { accepted = true })), nil, "no userId")
	expect.eq((Analytics.fromNotification("optin_result", { userId = 0 / 0 })), nil, "NaN userId")
	expect.eq((Analytics.fromNotification("optin_result", nil)), nil, "no fields")
	local _, bad = Analytics.fromNotification("notification_sent", { userId = 7, category = "hi there" })
	expect.falsy((Analytics.validate("notification_sent", bad)), "a bad category still fails validation")
end

return tests
