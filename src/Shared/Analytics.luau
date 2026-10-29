--!strict
--[[
	Analytics (owner: data agent; task P2.9, decision D-059): the event schema, its validation and
	the funnel definitions, as pure data and pure functions. Server/Services/AnalyticsService.luau
	is the only code that hands the result to Roblox's AnalyticsService.

	Why a schema: Roblox's public analytics take, per event, one number (`value`) and at most three
	custom fields whose values are strings, and group anything past 8,000 combinations of those
	strings as "Other". So every event here names exactly which input becomes the value and how
	each of its (at most three) custom fields is rendered: an enum value, Yes/No, or a fixed bucket
	of a number. No field ever carries free text, a player name or a user id (the Player the event is
	logged for is the only identity), so nothing typed by a player can reach analytics.

	Rules every caller can rely on:
	  - validate(event, fields) refuses an unknown event, an unknown or missing field, a wrong
	    type, a string outside its enum (or, for an id field, not a short server identifier), and a
	    number that is NaN, infinite, negative, out of range or not whole where it must be.
	  - encode(event, fields) is validate plus the payload: { value, slots = { "Tier - Rare", ... } }.
	  - funnelSteps(event, fields) derives the funnel steps an event completes, so callers only
	    fire events (plus `RaidFlow.TargetPicked`, which has no event of its own).
	  - Budget: a per-player token bucket that keeps a server well under Roblox's documented
	    experience-wide limit of 120 + 20 x CCU analytics calls per minute.

	Pure: no Roblox services, no clock, no randomness (callers pass `now` and fresh ids in).
]]

local CritterCatalog = require("./CritterCatalog")

local Analytics = {}

-- Field kinds ------------------------------------------------------------------------------------

export type FieldSpec = {
	kind: "enum" | "bool" | "number" | "id",
	values: { string }?, -- enum: the allowed strings
	min: number?, -- number: smallest allowed (default 0)
	max: number?, -- number: largest allowed (default none)
	whole: boolean?, -- number: must be a whole number
}

-- A custom field: which input it shows, its dashboard label, and for a number the buckets.
-- `bounds[i]` is the smallest value shown as `labels[i]`; bounds ascend and start at the field's min.
export type Slot = {
	field: string,
	label: string,
	bounds: { number }?,
	labels: { string }?,
}

export type EventSpec = {
	fields: { [string]: FieldSpec },
	value: string?, -- the number input sent as the event's value; nil = a counter (value 1)
	slots: { Slot }, -- at most 3, in CustomField01..03 order
	essential: boolean?, -- logged even when the player's budget is spent (once-per-session events)
}

export type Payload = { value: number, slots: { string } }

export type FunnelStep = { funnel: string, step: number, name: string }

-- Shared vocabularies ------------------------------------------------------------------------------

local TIERS: { string } = table.clone(CritterCatalog.TIER_ORDER) :: any
local TIER_OR_NONE: { string } = table.clone(TIERS)
table.insert(TIER_OR_NONE, "None")

Analytics.TIERS = table.freeze(TIERS)
Analytics.MAX_SLOTS = 3
Analytics.MAX_EVENTS = 100 -- Roblox: custom event names per experience
Analytics.MAX_COMBINATIONS = 8000 -- Roblox: unique custom-field combinations before "Other"
Analytics.MAX_ID_LENGTH = 32
Analytics.ONBOARDING_STEPS = 5 -- Appendix C steps 1-5 (Profile.ONBOARDING_LAST_STEP)

local MODES = { "Async", "Live" }

-- Buckets ----------------------------------------------------------------------------------------

local COUNT_BOUNDS = { 0, 1, 2, 4, 8, 16 }
local COUNT_LABELS = { "0", "1", "2-3", "4-7", "8-15", "16+" }

local function bucketed(field: string, label: string, bounds: { number }, labels: { string }): Slot
	return { field = field, label = label, bounds = bounds, labels = labels }
end

local function counted(field: string, label: string): Slot
	return bucketed(field, label, COUNT_BOUNDS, COUNT_LABELS)
end

local function shown(field: string, label: string): Slot
	return { field = field, label = label }
end

local function enum(values: { string }): FieldSpec
	return { kind = "enum", values = values }
end

local BOOL: FieldSpec = { kind = "bool" }
local AMOUNT: FieldSpec = { kind = "number" }
local COUNT: FieldSpec = { kind = "number", whole = true }

-- The events (playbook Appendix A) ------------------------------------------------------------------

local EVENTS: { [string]: EventSpec } = {
	onboarding_step = {
		fields = {
			step = { kind = "number", whole = true, min = 1, max = Analytics.ONBOARDING_STEPS },
			secondsSinceJoin = AMOUNT, -- since the account's first join (profile.createdAt)
		},
		value = "secondsSinceJoin",
		slots = {
			bucketed("step", "Step", { 1, 2, 3, 4, 5 }, { "1", "2", "3", "4", "5" }),
			bucketed(
				"secondsSinceJoin",
				"Since join",
				{ 0, 30, 60, 90, 180, 300, 3600 },
				{ "0-30s", "30-60s", "60-90s", "90s-3m", "3-5m", "5-60m", "1h+" }
			),
		},
	},
	egg_bought = {
		fields = { tier = enum(TIERS), price = AMOUNT, denLevel = COUNT },
		value = "price",
		slots = {
			shown("tier", "Tier"),
			bucketed("denLevel", "Den level", { 0, 2, 3, 4, 5, 6, 8, 11 }, {
				"1",
				"2",
				"3",
				"4",
				"5",
				"6-7",
				"8-10",
				"11+",
			}),
		},
	},
	critter_placed = {
		fields = { tier = enum(TIERS), placement = enum({ "Pad", "Vault", "Guard", "Inventory" }) },
		slots = { shown("tier", "Tier"), shown("placement", "Placement") },
	},
	glow_collected = {
		-- storageFill: stored / storage cap just before the collect (may pass 1 if the cap shrank)
		fields = { amount = AMOUNT, storageFill = AMOUNT },
		value = "amount",
		slots = {
			bucketed(
				"storageFill",
				"Storage",
				{ 0, 0.25, 0.5, 0.75, 0.99 },
				{ "0-25%", "25-50%", "50-75%", "75-99%", "Full" }
			),
		},
	},
	raid_portal_opened = {
		fields = { targetsOffered = COUNT, revengeAvailable = BOOL },
		value = "targetsOffered",
		slots = { shown("revengeAvailable", "Revenge available"), counted("targetsOffered", "Targets") },
	},
	raid_started = {
		fields = { mode = enum(MODES), revenge = BOOL, targetPower = AMOUNT },
		value = "targetPower",
		slots = {
			shown("mode", "Mode"),
			shown("revenge", "Revenge"),
			bucketed(
				"targetPower",
				"Power",
				{ 0, 10, 100, 1000, 10000, 100000 },
				{ "0-9", "10-99", "100-999", "1k-10k", "10k-100k", "100k+" }
			),
		},
	},
	raid_ended = {
		-- mode is validated and drives the funnels; the dashboard shows the other three.
		fields = {
			mode = enum(MODES),
			escaped = BOOL,
			tierTaken = enum(TIER_OR_NONE),
			glow = AMOUNT,
			durationSeconds = AMOUNT,
		},
		value = "glow",
		slots = {
			shown("escaped", "Escaped"),
			shown("tierTaken", "Tier taken"),
			bucketed(
				"durationSeconds",
				"Duration",
				{ 0, 30, 60, 120, 180 },
				{ "0-30s", "30-60s", "1-2m", "2-3m", "3m+" }
			),
		},
	},
	raided_offline = {
		-- attributedTo: whose Player the event is logged on. Roblox analytics need a Player in the
		-- server, so a debit written to a profile no server holds is logged on the raider.
		fields = {
			tierLost = enum(TIER_OR_NONE),
			glowLost = AMOUNT,
			revenge = BOOL,
			attributedTo = enum({ "Defender", "Raider" }),
		},
		value = "glowLost",
		slots = { shown("tierLost", "Tier lost"), shown("revenge", "Revenge"), shown("attributedTo", "Logged on") },
	},
	raid_log_opened = {
		fields = { entriesSinceLastVisit = COUNT },
		value = "entriesSinceLastVisit",
		slots = { counted("entriesSinceLastVisit", "New entries") },
	},
	revenge_started = {
		fields = { hoursSinceRaided = AMOUNT, fromNotification = BOOL, mode = enum(MODES) },
		value = "hoursSinceRaided",
		slots = {
			shown("fromNotification", "From notification"),
			shown("mode", "Mode"),
			bucketed(
				"hoursSinceRaided",
				"Since raided",
				{ 0, 1, 6, 24, 72 },
				{ "0-1h", "1-6h", "6-24h", "1-3d", "3d+" }
			),
		},
	},
	notification_sent = {
		fields = { category = enum({ "revenge", "storage", "event" }), result = enum({ "Sent", "Throttled" }) },
		slots = { shown("category", "Category"), shown("result", "Result") },
	},
	notification_join = {
		fields = { category = enum({ "revenge", "storage", "event" }) },
		slots = { shown("category", "Category") },
	},
	optin_prompted = {
		fields = { trigger = enum({ "FirstSuccessfulRaid", "SuccessfulRaid" }) },
		slots = { shown("trigger", "Trigger") },
	},
	optin_result = {
		fields = { accepted = BOOL },
		slots = { shown("accepted", "Accepted") },
	},
	purchase = {
		-- product: the server's own product key (e.g. "VipPass"), never a name from a player.
		fields = { product = { kind = "id" }, price = AMOUNT },
		value = "price",
		slots = { shown("product", "Product") },
		essential = true,
	},
	rebirth = {
		fields = { count = { kind = "number", whole = true, min = 1 }, daysSinceJoin = AMOUNT },
		value = "count",
		slots = {
			bucketed("count", "Rebirth", { 1, 2, 3, 4, 6, 10 }, { "1", "2", "3", "4-5", "6-9", "10+" }),
			bucketed(
				"daysSinceJoin",
				"Since join",
				{ 0, 1, 3, 7, 14, 30 },
				{ "0-1d", "1-3d", "3-7d", "7-14d", "14-30d", "30d+" }
			),
		},
	},
	session_end = {
		fields = { sessionSeconds = AMOUNT, raids = COUNT, steals = COUNT },
		value = "sessionSeconds",
		slots = {
			bucketed(
				"sessionSeconds",
				"Length",
				{ 0, 60, 300, 900, 1800, 3600 },
				{ "0-1m", "1-5m", "5-15m", "15-30m", "30-60m", "60m+" }
			),
			counted("raids", "Raids"),
			counted("steals", "Steals"),
		},
		essential = true,
	},
}
Analytics.EVENTS = EVENTS

-- Funnels ----------------------------------------------------------------------------------------

-- Onboarding is Roblox's one-time onboarding funnel (LogOnboardingFunnelStepEvent: the first time a
-- player reaches each step counts). RaidFlow is a recurring funnel (LogFunnelStepEvent) with one
-- funnel session per trip through the portal.
Analytics.FUNNELS = table.freeze({
	Onboarding = table.freeze({ "Join", "FirstHatch", "FirstCollect", "FirstSteal", "FirstRaid" }),
	RaidFlow = table.freeze({ "Portal", "TargetPicked", "RaidStarted", "Escaped" }),
})

-- An account is in the onboarding funnel for this long after its first join (profile.createdAt).
Analytics.ONBOARDING_FUNNEL_SECONDS = 7 * 24 * 60 * 60

-- The step's number in its funnel (1-based), or nil for an unknown funnel or step.
function Analytics.funnelStep(funnel: string, name: string): FunnelStep?
	local steps: { string }? = (Analytics.FUNNELS :: any)[funnel]
	if steps == nil then
		return nil
	end
	local index = table.find(steps, name)
	return if index then { funnel = funnel, step = index, name = name } else nil
end

-- Economy (Roblox economy events: sources and sinks) -----------------------------------------------

-- Two currencies: Glow (banked, never stealable) and DenGlow (stored in the den, stealable). A
-- collect is a DenGlow sink and a Glow source of the same amount. transactionType uses Roblox's
-- standard Enum.AnalyticsEconomyTransactionType names; sku says which source or sink.
export type EconomyFlow = {
	flow: "Source" | "Sink",
	currency: "Glow" | "DenGlow",
	transactionType: string,
	sku: string,
}

local function flow(
	kind: "Source" | "Sink",
	currency: "Glow" | "DenGlow",
	transactionType: string,
	sku: string
): EconomyFlow
	return { flow = kind, currency = currency, transactionType = transactionType, sku = sku }
end

Analytics.ECONOMY = table.freeze({
	-- Glow (banked)
	Collect = flow("Source", "Glow", "Gameplay", "Collect"),
	RaidLoot = flow("Source", "Glow", "Gameplay", "RaidLoot"),
	OnboardingGift = flow("Source", "Glow", "Onboarding", "OnboardingGift"),
	Egg = flow("Sink", "Glow", "Shop", "Egg"),
	DenUpgrade = flow("Sink", "Glow", "Shop", "DenUpgrade"),
	Trap = flow("Sink", "Glow", "Shop", "Trap"),
	GearUpgrade = flow("Sink", "Glow", "Shop", "GearUpgrade"),
	Rebirth = flow("Sink", "Glow", "Gameplay", "Rebirth"),
	-- DenGlow (stored in the den)
	DenIncome = flow("Source", "DenGlow", "Gameplay", "Income"),
	DenOfflineIncome = flow("Source", "DenGlow", "TimedReward", "OfflineIncome"),
	DenCollect = flow("Sink", "DenGlow", "Gameplay", "Collect"),
	DenRaided = flow("Sink", "DenGlow", "Gameplay", "Raided"),
}) :: { [string]: EconomyFlow }

local function isFinite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- The flow for an economy event, or (nil, why). amount must be a finite number > 0 (Roblox wants
-- positive amounts for sources and sinks alike); endingBalance a finite number >= 0.
function Analytics.economy(flowId: string, amount: any, endingBalance: any): (EconomyFlow?, string?)
	local spec = (Analytics.ECONOMY :: any)[flowId]
	if type(flowId) ~= "string" or spec == nil then
		return nil, `unknown economy flow {tostring(flowId)}`
	end
	if not isFinite(amount) or amount <= 0 then
		return nil, "amount must be a finite number > 0"
	end
	if not isFinite(endingBalance) or endingBalance < 0 then
		return nil, "endingBalance must be a finite number >= 0"
	end
	return spec, nil
end

-- Validation and encoding ------------------------------------------------------------------------

local function checkField(name: string, spec: FieldSpec, value: any): string?
	if value == nil then
		return `missing field {name}`
	end
	if spec.kind == "bool" then
		return if type(value) == "boolean" then nil else `{name} must be a boolean`
	elseif spec.kind == "enum" then
		if type(value) ~= "string" or not table.find(spec.values :: { string }, value) then
			return `{name} is not one of its allowed values`
		end
		return nil
	elseif spec.kind == "id" then
		-- A short server identifier: a letter, then letters, digits or underscores. Never spaces or
		-- punctuation, so free text cannot pass.
		if type(value) ~= "string" or #value > Analytics.MAX_ID_LENGTH or not string.match(value, "^%a[%w_]*$") then
			return `{name} must be a server identifier of at most {Analytics.MAX_ID_LENGTH} characters`
		end
		return nil
	end
	if not isFinite(value) then
		return `{name} must be a finite number`
	end
	if value < (spec.min or 0) then
		return `{name} must be at least {spec.min or 0}`
	end
	if spec.max and value > spec.max then
		return `{name} must be at most {spec.max}`
	end
	if spec.whole and value % 1 ~= 0 then
		return `{name} must be a whole number`
	end
	return nil
end

-- Whether `fields` is exactly what `event` takes: every field present and valid, nothing else.
function Analytics.validate(event: any, fields: any): (boolean, string?)
	local spec = if type(event) == "string" then EVENTS[event] else nil
	if spec == nil then
		return false, `unknown event {tostring(event)}`
	end
	if type(fields) ~= "table" then
		return false, "fields must be a table"
	end
	for key in fields do
		if type(key) ~= "string" or spec.fields[key] == nil then
			return false, `{event} has no field {tostring(key)}`
		end
	end
	for name, fieldSpec in spec.fields do
		local why = checkField(name, fieldSpec, fields[name])
		if why then
			return false, `{event}: {why}`
		end
	end
	return true, nil
end

-- The label of the bucket `value` falls in (bounds ascend; the field's own range check ran first).
function Analytics.bucket(bounds: { number }, labels: { string }, value: number): string
	local label = labels[1]
	for index, bound in bounds do
		if value >= bound then
			label = labels[index]
		end
	end
	return label
end

local function render(slot: Slot, value: any): string
	local shownValue: string
	if type(value) == "boolean" then
		shownValue = if value then "Yes" else "No"
	elseif slot.bounds and slot.labels then
		shownValue = Analytics.bucket(slot.bounds, slot.labels, value)
	else
		shownValue = tostring(value)
	end
	return `{slot.label} - {shownValue}`
end

-- validate, then the payload: the event's value (1 for a counter) and its custom-field strings.
function Analytics.encode(event: string, fields: { [string]: any }): (Payload?, string?)
	local ok, why = Analytics.validate(event, fields)
	if not ok then
		return nil, why
	end
	local spec = EVENTS[event]
	local slots = {}
	for _, slot in spec.slots do
		table.insert(slots, render(slot, fields[slot.field]))
	end
	local value = if spec.value then fields[spec.value] :: number else 1
	return { value = value, slots = slots }, nil
end

-- The funnel steps an event completes (callers fire only the event). Empty for most events.
-- Onboarding: Appendix C step 1 (the free hatch) or an egg -> FirstHatch; step 2 or a collect ->
-- FirstCollect; step 4 (the guided steal) or any escape with a critter -> FirstSteal; an async
-- raid starting -> FirstRaid. RaidFlow: portal -> Portal, raid_started -> RaidStarted, an escape ->
-- Escaped. RaidFlow.TargetPicked has no event: the raid owner logs it as a step directly.
function Analytics.funnelSteps(event: string, fields: { [string]: any }): { FunnelStep }
	local names: { { string } } = {}
	if event == "onboarding_step" then
		local byStep = { [1] = "FirstHatch", [2] = "FirstCollect", [4] = "FirstSteal" }
		local name = byStep[fields.step]
		if name then
			table.insert(names, { "Onboarding", name })
		end
	elseif event == "egg_bought" then
		table.insert(names, { "Onboarding", "FirstHatch" })
	elseif event == "glow_collected" then
		table.insert(names, { "Onboarding", "FirstCollect" })
	elseif event == "raid_portal_opened" then
		table.insert(names, { "RaidFlow", "Portal" })
	elseif event == "raid_started" then
		table.insert(names, { "RaidFlow", "RaidStarted" })
		if fields.mode == "Async" then
			table.insert(names, { "Onboarding", "FirstRaid" })
		end
	elseif event == "raid_ended" and fields.escaped == true then
		table.insert(names, { "RaidFlow", "Escaped" })
		if fields.tierTaken ~= "None" then
			table.insert(names, { "Onboarding", "FirstSteal" })
		end
	end
	local steps = {}
	for _, pair in names do
		table.insert(steps, Analytics.funnelStep(pair[1], pair[2]) :: FunnelStep)
	end
	return steps
end

--[[
	The RaidFlow funnel session for a step. `current` is the player's open session id (nil = none),
	`freshId` a new unique id the caller made. Portal always opens a new session; any other step
	joins the open one, or opens one if there is none (a revenge from a notification skips the
	portal). Returns the id to log the step under and the session left open afterwards: Escaped
	closes it.
]]
function Analytics.raidFlowSession(current: string?, stepName: string, freshId: string): (string, string?)
	local use = if stepName == "Portal" or current == nil then freshId else current
	return use, if stepName == "Escaped" then nil else use
end

-- Whether an event ends the player's open RaidFlow session (a raid that ended either way).
function Analytics.endsRaidFlow(event: string): boolean
	return event == "raid_ended"
end

-- Whether an account first seen at `createdAt` is still in the onboarding funnel at `now`.
function Analytics.inOnboardingWindow(createdAt: any, now: any): boolean
	if not isFinite(createdAt) or not isFinite(now) then
		return false
	end
	local age = now - createdAt
	return age >= 0 and age < Analytics.ONBOARDING_FUNNEL_SECONDS
end

-- Session counters for session_end ----------------------------------------------------------------

export type SessionCounts = { raids: number, steals: number }

-- Counts a validated event into the session: raids started, and escapes that took a critter.
function Analytics.countSession(counts: SessionCounts, event: string, fields: { [string]: any })
	if event == "raid_started" then
		counts.raids += 1
	elseif event == "raid_ended" and fields.escaped == true and fields.tierTaken ~= "None" then
		counts.steals += 1
	end
end

-- Raid log entries newer than the last visit (`seenAt`; nil or not finite = never visited).
function Analytics.entriesSince(raidLog: any, seenAt: any): number
	if type(raidLog) ~= "table" then
		return 0
	end
	local since = if isFinite(seenAt) then seenAt else -math.huge
	local count = 0
	for _, entry in raidLog do
		if type(entry) == "table" and isFinite(entry.at) and entry.at > since then
			count += 1
		end
	end
	return count
end

-- Budget ----------------------------------------------------------------------------------------

-- Per player: a burst of CAPACITY events, refilled at REFILL_PER_MINUTE. Roblox documents one
-- experience-wide limit of 120 + 20 x CCU calls per minute, so 15 per player per minute (steady)
-- keeps every server under it with room for the essential events, which skip the budget.
Analytics.BUDGET_CAPACITY = 20
Analytics.BUDGET_REFILL_PER_MINUTE = 15

export type Budget = { tokens: number, at: number }

function Analytics.newBudget(now: number): Budget
	return { tokens = Analytics.BUDGET_CAPACITY, at = if isFinite(now) then now else 0 }
end

-- Refills by the time since the last call (`now` in seconds, any monotonic clock), then spends one
-- token if there is one. A NaN, infinite or backwards `now` refills nothing.
function Analytics.take(budget: Budget, now: number): boolean
	if isFinite(now) and now > budget.at then
		local refill = (now - budget.at) * Analytics.BUDGET_REFILL_PER_MINUTE / 60
		budget.tokens = math.min(Analytics.BUDGET_CAPACITY, budget.tokens + refill)
		budget.at = now
	end
	if budget.tokens >= 1 then
		budget.tokens -= 1
		return true
	end
	return false
end

-- NotificationService's analytics call point ------------------------------------------------------

--[[
	Maps a NotificationService `track(event, fields)` call (P2.7, its one analytics call point) to
	this schema. Its fields carry `userId` (the Player to log on), and extra keys such as `raidId`
	that analytics never keeps (high cardinality). Returns (userId, fields) or nil for anything that
	is not one of its four events or has no usable userId. Validation still runs on the result.
]]
function Analytics.fromNotification(event: any, fields: any): (number?, { [string]: any }?)
	if type(fields) ~= "table" or not isFinite(fields.userId) then
		return nil, nil
	end
	local userId = fields.userId :: number
	if event == "notification_sent" then
		return userId, { category = fields.category, result = fields.result or "Sent" }
	elseif event == "notification_join" then
		-- Launch data carries only revenge raids today.
		return userId, { category = fields.category or "revenge" }
	elseif event == "optin_prompted" then
		return userId, { trigger = fields.trigger or "FirstSuccessfulRaid" }
	elseif event == "optin_result" then
		return userId, { accepted = fields.accepted }
	end
	return nil, nil
end

return Analytics
