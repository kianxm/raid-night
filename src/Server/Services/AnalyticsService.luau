--!strict
--[[
	AnalyticsService (owner: data agent; task P2.9, decision D-059)

	The only code that calls Roblox's AnalyticsService. Every event, funnel step and economy event
	is checked against the pure schema in Shared/Analytics.luau first; anything that fails is
	dropped with a warning, never sent.

	Public Roblox APIs used (create.roblox.com/docs, AnalyticsService):
	  LogCustomEvent(player, eventName, value, customFields)
	  LogOnboardingFunnelStepEvent(player, step, stepName, customFields)     Onboarding funnel
	  LogFunnelStepEvent(player, funnelName, funnelSessionId, step, stepName) RaidFlow funnel
	  LogEconomyEvent(player, flowType, currency, amount, endingBalance, transactionType, itemSku)
	Custom fields are keyed Enum.AnalyticsCustomFieldKeys.CustomField01..03 .Name. Roblox records
	events only from servers of a published place, never from Studio.

	Server API (none of these yield or throw; each returns whether it logged):
	  track(who, event, fields)      who: a Player or a userId in THIS server. Fires the event and
	                                 the funnel steps it completes (Analytics.funnelSteps).
	  step(who, funnel, stepName)    a funnel step with no event of its own: RaidFlow TargetPicked.
	  economy(who, flowId, amount, endingBalance)   Analytics.ECONOMY flow ids (Glow, DenGlow).
	  trackNotification(event, fields)
	                                 NotificationService's single `track` call point, as it is
	                                 (fields.userId names the player; raidId and the like dropped).
	  sessionStarted(player, profile, now), sessionEnded(player, now)
	                                 DataService: a profile loaded / the player is leaving.
	                                 sessionEnded logs session_end (length, raids started, critters
	                                 stolen this session) once and forgets the player; this module's
	                                 own PlayerRemoving handler calls it too, so a player whose lock
	                                 was lost mid-session still gets one.

	Budget: Analytics.take per player (a burst of 20, 15 a minute) keeps the server under Roblox's
	experience-wide rate limit; session_end and purchase skip it. A dropped event only counts.

	Studio: nothing is sent unless the ServerStorage attribute StudioAnalyticsLog is true; then
	every accepted call is also printed ("[Analytics] ..."), which is how a playtest checks the
	wiring. Schema refusals warn in Studio and live alike: they are bugs in the caller.

	Never requires DataService or EscrowService (both require this module).
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local RobloxAnalytics = game:GetService("AnalyticsService")

local Analytics = require(ReplicatedStorage.Shared.Analytics)
local Types = require(ReplicatedStorage.Shared.Types)

type PlayerProfile = Types.PlayerProfile

local STUDIO_LOG = "StudioAnalyticsLog"
-- The documented keys are Enum.AnalyticsCustomFieldKeys.CustomField01..03 .Name. Read in pcall
-- with their documented names as the fallback: DataService and EscrowService require this module,
-- so it must never fail to load.
local SLOT_KEYS = { "CustomField01", "CustomField02", "CustomField03" }
pcall(function()
	local keys = Enum.AnalyticsCustomFieldKeys :: any
	SLOT_KEYS = { keys.CustomField01.Name, keys.CustomField02.Name, keys.CustomField03.Name }
end)

local AnalyticsService = {}

type Session = {
	joinedAt: number,
	counts: Analytics.SessionCounts,
	budget: Analytics.Budget,
	started: boolean, -- opened by sessionStarted (a loaded profile); only these log session_end
	onboarding: boolean, -- the account is in the onboarding funnel's window
	funnelDone: { [string]: true }, -- onboarding steps already logged this session
	raidFlow: string?, -- the open RaidFlow funnel session id
}

local sessions: { [number]: Session } = {}
local dropped = 0

-- Studio sends nothing unless asked; a published server always sends.
local function sending(): (boolean, boolean)
	if not RunService:IsStudio() then
		return true, false
	end
	local on = ServerStorage:GetAttribute(STUDIO_LOG) == true
	return on, on
end

local function sessionFor(userId: number): Session
	local session = sessions[userId]
	if session == nil then
		session = {
			joinedAt = os.time(),
			counts = { raids = 0, steals = 0 },
			budget = Analytics.newBudget(os.clock()),
			started = false,
			onboarding = false,
			funnelDone = {},
			raidFlow = nil,
		}
		sessions[userId] = session
	end
	return session :: Session
end

local function playerOf(who: any): Player?
	if typeof(who) == "Instance" and who:IsA("Player") then
		return who :: Player
	elseif type(who) == "number" then
		return Players:GetPlayerByUserId(who)
	end
	return nil
end

-- Runs one Roblox call (or, in Studio without the switch, nothing). Never throws.
local function send(description: string, call: () -> ()): boolean
	local on, echo = sending()
	if not on then
		return false
	end
	if echo then
		print(`[Analytics] {description}`)
	end
	local ok, err = pcall(call)
	if not ok then
		warn(`[Analytics] {description} failed: {err}`)
	end
	return ok
end

local function allowed(session: Session, essential: boolean?): boolean
	if essential or Analytics.take(session.budget, os.clock()) then
		return true
	end
	dropped += 1
	return false
end

local function customFields(slots: { string }): { [string]: string }
	local result = {}
	for index, text in slots do
		result[SLOT_KEYS[index]] = text
	end
	return result
end

-- Whether an onboarding step is still worth sending: in the window and not yet logged this
-- session (Roblox's onboarding funnel keeps only a player's first time at each step anyway).
local function wanted(session: Session, step: Analytics.FunnelStep): boolean
	return step.funnel ~= "Onboarding" or (session.onboarding and not session.funnelDone[step.name])
end

local function logStep(player: Player, session: Session, step: Analytics.FunnelStep): boolean
	if not wanted(session, step) then
		return false
	end
	if step.funnel == "Onboarding" then
		session.funnelDone[step.name] = true
		return send(`funnel Onboarding {step.step} {step.name} for {player.UserId}`, function()
			RobloxAnalytics:LogOnboardingFunnelStepEvent(player, step.step, step.name)
		end)
	end
	local id, open = Analytics.raidFlowSession(session.raidFlow, step.name, HttpService:GenerateGUID(false))
	session.raidFlow = open
	return send(`funnel {step.funnel} {step.step} {step.name} ({id}) for {player.UserId}`, function()
		RobloxAnalytics:LogFunnelStepEvent(player, step.funnel, id, step.step, step.name)
	end)
end

function AnalyticsService.track(who: Player | number, event: string, fields: { [string]: any }): boolean
	local ok, result = pcall(function(): boolean
		local payload, why = Analytics.encode(event, fields)
		if payload == nil then
			warn(`[Analytics] refused {tostring(event)}: {why}`)
			return false
		end
		local player = playerOf(who)
		if player == nil then
			return false -- not in this server: Roblox analytics need the Player
		end
		local session = sessionFor(player.UserId)
		Analytics.countSession(session.counts, event, fields)
		local spec = Analytics.EVENTS[event]
		if not allowed(session, spec.essential) then
			return false
		end
		local slots = customFields(payload.slots)
		local logged = send(
			`{event} {payload.value} {table.concat(payload.slots, " | ")} for {player.UserId}`,
			function()
				RobloxAnalytics:LogCustomEvent(player, event, payload.value, slots)
			end
		)
		for _, step in Analytics.funnelSteps(event, fields) do
			if wanted(session, step) and allowed(session) then
				logStep(player, session, step)
			end
		end
		if Analytics.endsRaidFlow(event) then
			session.raidFlow = nil
		end
		return logged
	end)
	if not ok then
		warn(`[Analytics] track {tostring(event)} errored: {result}`)
		return false
	end
	return result
end

function AnalyticsService.step(who: Player | number, funnel: string, stepName: string): boolean
	local ok, result = pcall(function(): boolean
		local step = Analytics.funnelStep(funnel, stepName)
		if step == nil then
			warn(`[Analytics] refused funnel step {tostring(funnel)}.{tostring(stepName)}`)
			return false
		end
		local player = playerOf(who)
		if player == nil then
			return false
		end
		local session = sessionFor(player.UserId)
		if not wanted(session, step) or not allowed(session) then
			return false
		end
		return logStep(player, session, step)
	end)
	return ok and result
end

function AnalyticsService.economy(who: Player | number, flowId: string, amount: number, endingBalance: number): boolean
	local ok, result = pcall(function(): boolean
		if amount == 0 then
			return false -- nothing moved: not an economy event
		end
		local spec, why = Analytics.economy(flowId, amount, endingBalance)
		if spec == nil then
			warn(`[Analytics] refused economy {tostring(flowId)}: {why}`)
			return false
		end
		local player = playerOf(who)
		if player == nil then
			return false
		end
		if not allowed(sessionFor(player.UserId)) then
			return false
		end
		local flowType = if spec.flow == "Source"
			then Enum.AnalyticsEconomyFlowType.Source
			else Enum.AnalyticsEconomyFlowType.Sink
		local description =
			`economy {spec.flow} {spec.currency} {amount} -> {endingBalance} {spec.transactionType}/{spec.sku} for {player.UserId}`
		return send(description, function()
			RobloxAnalytics:LogEconomyEvent(
				player,
				flowType,
				spec.currency,
				amount,
				endingBalance,
				spec.transactionType,
				spec.sku
			)
		end)
	end)
	return ok and result
end

-- NotificationService's `track(event, fields)` (P2.7), passed straight through.
function AnalyticsService.trackNotification(event: string, fields: { [string]: any }): boolean
	local userId, mapped = Analytics.fromNotification(event, fields)
	if userId == nil or mapped == nil then
		warn(`[Analytics] refused notification event {tostring(event)}`)
		return false
	end
	return AnalyticsService.track(userId, event, mapped)
end

-- DataService: a profile loaded for `player`. Opens the session and, for an account still in the
-- onboarding funnel's window (Analytics.inOnboardingWindow, from createdAt), logs its Join step.
function AnalyticsService.sessionStarted(player: Player, profile: PlayerProfile, now: number)
	local ok, err = pcall(function()
		sessions[player.UserId] = nil
		local session = sessionFor(player.UserId)
		session.joinedAt = now
		session.started = true
		session.onboarding = Analytics.inOnboardingWindow(profile.createdAt, now)
		local join = Analytics.funnelStep("Onboarding", "Join")
		if join and session.onboarding then
			logStep(player, session, join)
		end
	end)
	if not ok then
		warn(`[Analytics] sessionStarted {player.UserId} errored: {err}`)
	end
end

-- `player` is leaving (the Player is still valid): logs session_end once for a session that
-- sessionStarted opened, then forgets them. DataService calls it before EndSession; the
-- PlayerRemoving handler below calls it too (a lock lost mid-session ends DataService's entry
-- first), and whichever runs second finds nothing.
function AnalyticsService.sessionEnded(player: Player, now: number)
	local session = sessions[player.UserId]
	if session == nil then
		return
	end
	if session.started then
		AnalyticsService.track(player, "session_end", {
			sessionSeconds = math.max(0, now - session.joinedAt),
			raids = session.counts.raids,
			steals = session.counts.steals,
		})
	end
	sessions[player.UserId] = nil
end

Players.PlayerRemoving:Connect(function(player: Player)
	AnalyticsService.sessionEnded(player, os.time())
end)

-- Studio playtests: how many events the budget dropped this server.
function AnalyticsService.droppedCount(): number
	return dropped
end

return AnalyticsService
