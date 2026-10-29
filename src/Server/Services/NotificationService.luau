--!strict
--[[
	NotificationService (owner: notifications agent)

	Experience notifications through the public Open Cloud user-notification API, plus the
	opt-in timing. All WHEN/WHAT rules are pure and tested in Shared/NotificationRules.luau; this
	file is the Roblox glue. Everything is behind Config.Flags.notifications (default off).

	Platform limits: opted-in users 13+ only (the platform rejects anyone else, we log and move
	on); one notification per user per day per experience; opt-in prompt once per 30 days.

	Secret (name only; the value lives in Studio Secrets, never in code):
	  NotificationsApiKey        Open Cloud key with the user-notification write scope
	Message ids of the Creator Dashboard strings go in MESSAGE_IDS below (see the PR description).

	Server API (called by other services; none of these may throw):
	  onLoss(event)                       a defender lost something in a raid (see LossReport).
	                                      raiderName is the Roblox DisplayName/username, never
	                                      player-typed text.
	                                      Call after the escrow debit has committed. It can run on
	                                      either server: the raider's, or the defender's (message
	                                      path), so two servers may report the same loss. Deduped
	                                      by raidId in the NotificationState_v1 record, so a loss
	                                      is handled once. Works for online and offline defenders.
	  onStorageSample(userId, stored, capacity)
	                                      owner of storage numbers calls this (login, collect,
	                                      periodic); sends the combined Glow-loss notification.
	  onSuccessfulRaid(player, successfulRaids)
	                                      raider just finished a successful raid; successfulRaids
	                                      is their lifetime count including this one.
	  launchRaidId(player) -> string?     raidId carried by the join's launch data, if any
	                                      (Player:GetJoinData().LaunchData). Untrusted: the revenge
	                                      screen must still verify the revenge token for it.

	Opt-in prompt: ExperienceNotificationService:PromptOptIn is client-only. The server decides
	when (state + rules) and pushes Net.Pushes.PromptNotificationOptIn (no payload) to that player;
	one prompt may be pending per player. The client checks CanPromptOptInAsync, prompts, then
	sends Net.Requests.ReportOptInResult ({ shown, accepted }). The server accepts it only while a
	prompt is pending (cleared on use or leave), validates the types
	(Rules.cleanOptInReport) and rate-limits it (Net.Limits.ReportOptInResult). promptedAt (the
	30-day clock) is saved only when shown = true. optin_prompted is tracked at the push,
	optin_result when the client reports shown = true.

	Persistence: its own DataStore ("NotificationState_v1", one small record per user, written
	with UpdateAsync) so it works for offline defenders without touching another player's
	profile. If data adds profile fields instead, swap `Store` (get/update) and nothing else.

	Analytics: every event goes through `track` below, which forwards to
	AnalyticsService.trackNotification (notification_sent incl. result Throttled,
	notification_join, optin_prompted, optin_result).
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net")) :: any
local RateLimit = require(Shared:WaitForChild("RateLimit")) :: any
local Config = require(Shared:WaitForChild("Config")) :: any
local Rules = require(Shared:WaitForChild("NotificationRules")) :: any
local AnalyticsService = require(script.Parent:WaitForChild("AnalyticsService")) :: any

local SECRET_API_KEY = "NotificationsApiKey"
-- Message ids are not secret (they only name a dashboard string). Kian pastes them here after
-- creating the strings; an empty id means "not created yet" and that category never sends.
local MESSAGE_IDS: { [string]: string } = {
	revenge = "",
	storage = "",
}
local ENDPOINT = "https://apis.roblox.com/cloud/v2/users/%d/notifications"

export type LossReport = {
	defenderUserId: number,
	raidId: string,
	raiderName: string,
	-- "Critter" when a critter was taken (critterName set), "Glow" when only Glow was taken.
	kind: "Critter" | "Glow",
	critterName: string?, -- display name from the catalog, never a player-typed string
}

local NotificationService = {}

local store: DataStore? = nil
local cache: { [number]: Rules.State } = {}
local busy: { [number]: boolean } = {} -- one in-flight decision per user; drops overlaps
local promptEvent: RemoteEvent? = nil
local pendingPrompt: { [number]: boolean } = {} -- pushed, not yet answered
local reportLimits: { [number]: any } = {} -- RateLimit state per user

local function enabled(): boolean
	return Config.Flags.notifications == true
end

-- Single analytics call point: forwards to AnalyticsService, which maps and validates the fields.
-- Events: notification_sent, notification_join, optin_prompted, optin_result. Never throws.
local function track(event: string, fields: { [string]: any })
	local ok, err = pcall(AnalyticsService.trackNotification, event, fields)
	if not ok then
		warn(`[Notifications] analytics {event} errored: {err}`)
	end
end

-- nil = the stored state could not be read: callers fail closed (no send).
local function loadState(userId: number): Rules.State?
	local cached = cache[userId]
	if cached then
		return cached
	end
	local state: Rules.State = {}
	if store then
		local ok, value = pcall(function()
			return (store :: DataStore):GetAsync(tostring(userId))
		end)
		if ok and type(value) == "table" then
			state = {
				lastSentDay = if type(value.lastSentDay) == "number" then value.lastSentDay else nil,
				glowLossPending = value.glowLossPending == true,
				promptedAt = if type(value.promptedAt) == "number" then value.promptedAt else nil,
				seenRaids = if type(value.seenRaids) == "table" then value.seenRaids else nil,
			}
		elseif not ok then
			warn(`[Notifications] state read failed for {userId}; skipping`)
			return nil
		end
	end
	cache[userId] = state
	return state
end

-- Claims today's send slot in the store before the POST so two servers cannot both send.
-- The transform re-reads the stored record (never the local cache) and aborts if today is taken.
-- Returns true plus the previous lastSentDay (for release), or false when not claimed.
local function claimDay(userId: number, now: number): (boolean, number?)
	local today = Rules.dayOf(now)
	if not store then
		local cached = cache[userId] or {}
		if cached.lastSentDay == today then
			return false, nil
		end
		local previous = cached.lastSentDay
		cached.lastSentDay = today
		cache[userId] = cached
		return true, previous
	end
	local previous: number? = nil
	local ok, result = pcall(function()
		return (store :: DataStore):UpdateAsync(tostring(userId), function(old)
			local record: { [string]: any } = if type(old) == "table" then old else {}
			if record.lastSentDay == today then
				return nil -- abort: already claimed today
			end
			previous = if type(record.lastSentDay) == "number" then record.lastSentDay else nil
			return {
				lastSentDay = today,
				glowLossPending = record.glowLossPending == true,
				promptedAt = if type(record.promptedAt) == "number" then record.promptedAt else nil,
				seenRaids = record.seenRaids,
			}
		end)
	end)
	if not ok then
		warn(`[Notifications] claim failed for {userId}; skipping`)
		return false, nil
	end
	-- UpdateAsync returns nil when the transform aborted.
	return result ~= nil, previous
end

-- Marks a raidId handled in the stored record (inside UpdateAsync, so two servers cannot both
-- pass). Returns true when this call is the first to see it; false for a duplicate or when the
-- store could not be reached (fail closed: no send).
local function claimRaid(userId: number, raidId: string): boolean
	if not store then
		local cached = cache[userId] or {}
		local list, isNew = Rules.noteRaid(cached.seenRaids, raidId)
		cached.seenRaids = list
		cache[userId] = cached
		return isNew
	end
	local ok, result = pcall(function()
		return (store :: DataStore):UpdateAsync(tostring(userId), function(old)
			local record: { [string]: any } = if type(old) == "table" then old else {}
			local list, isNew = Rules.noteRaid(record.seenRaids, raidId)
			if not isNew then
				return nil -- abort: another server already handled this raid
			end
			record.seenRaids = list
			return record
		end)
	end)
	if not ok then
		warn(`[Notifications] raid dedupe failed for {userId}; skipping`)
		return false
	end
	if result ~= nil and type(result.seenRaids) == "table" then
		local cached = cache[userId]
		if cached then
			cached.seenRaids = result.seenRaids
		end
	end
	return result ~= nil
end

-- Gives the slot back after a failed POST (best effort; only if it is still our claim).
local function releaseDay(userId: number, now: number, previous: number?)
	local today = Rules.dayOf(now)
	local cached = cache[userId]
	if cached and cached.lastSentDay == today then
		cached.lastSentDay = previous
	end
	if not store then
		return
	end
	pcall(function()
		(store :: DataStore):UpdateAsync(tostring(userId), function(old)
			if type(old) ~= "table" or old.lastSentDay ~= today then
				return nil
			end
			old.lastSentDay = previous
			return old
		end)
	end)
end

local function saveState(userId: number, state: Rules.State)
	cache[userId] = state
	if not store then
		return
	end
	local ok = pcall(function()
		(store :: DataStore):UpdateAsync(tostring(userId), function(old)
			-- Merge into the stored record; never lower lastSentDay (another server may have
			-- claimed a later day).
			local record: { [string]: any } = if type(old) == "table" then old else {}
			local storedDay = if type(record.lastSentDay) == "number" then record.lastSentDay else nil
			local day = state.lastSentDay
			if storedDay ~= nil and (day == nil or storedDay > day) then
				day = storedDay
			end
			record.lastSentDay = day
			record.glowLossPending = state.glowLossPending
			if state.promptedAt ~= nil then
				record.promptedAt = state.promptedAt
			end
			return record
		end)
	end)
	if not ok then
		warn(`[Notifications] state write failed for {userId}`)
	end
end

-- One POST. Returns true only when the platform accepted it. Throttled (429), not-opted-in,
-- under-13 and every other failure are normal: log and return false, never retry.
local function postNotification(
	userId: number,
	category: string,
	parameters: { [string]: string },
	launchData: string?
): boolean
	local messageId = MESSAGE_IDS[category]
	if messageId == nil or messageId == "" then
		warn(`[Notifications] no message id for {category}; not sending`)
		return false
	end
	local okKey, apiKey = pcall(HttpService.GetSecret, HttpService, SECRET_API_KEY)
	if not okKey then
		warn("[Notifications] API key secret missing; not sending")
		return false
	end

	local apiParameters = {}
	for key, value in parameters do
		apiParameters[key] = { stringValue = value }
	end
	local payload: { [string]: any } = {
		messageId = messageId,
		type = "MOVE_TO_EXPERIENCE",
		parameters = apiParameters,
		analyticsData = { category = category },
	}
	if launchData then
		payload.joinExperience = { launchData = launchData }
	end
	local body = {
		source = { universe = `universes/{game.GameId}` },
		payload = payload,
	}

	local ok, response = pcall(function()
		return HttpService:RequestAsync({
			Url = string.format(ENDPOINT, userId),
			Method = "POST",
			Headers = {
				["Content-Type"] = "application/json",
				["x-api-key"] = apiKey,
			},
			Body = HttpService:JSONEncode(body),
		})
	end)
	if not ok then
		warn(`[Notifications] request failed for {category}`)
		return false
	end
	if response.Success then
		return true
	end
	if response.StatusCode == 429 then
		warn(`[Notifications] throttled ({category}); not retrying`)
	else
		warn(`[Notifications] not sent ({category}) status {response.StatusCode}`)
	end
	return false
end

local function withLock(userId: number, fn: () -> ())
	if busy[userId] then
		return -- an overlapping event for the same user: the daily cap would drop it anyway
	end
	busy[userId] = true
	local ok, err = pcall(fn)
	busy[userId] = nil
	if not Players:GetPlayerByUserId(userId) then
		cache[userId] = nil -- offline defenders are not kept in memory
	end
	if not ok then
		warn(`[Notifications] error: {err}`)
	end
end

function NotificationService.onLoss(report: LossReport)
	if not enabled() then
		return
	end
	task.spawn(withLock, report.defenderUserId, function()
		local userId = report.defenderUserId
		local now = os.time()
		local state = loadState(userId)
		if not state then
			return
		end
		if not claimRaid(userId, report.raidId) then
			return -- duplicate report (both servers saved Debited) or store unreachable
		end
		local event: Rules.LossEvent = {
			kind = report.kind,
			raidId = report.raidId,
			raiderName = report.raiderName,
			critterName = report.critterName,
		}
		local decision = Rules.decideLoss(state, event, now, Config.Notifications.sendOnFirstCritterLost)
		if decision.action == "Hold" then
			saveState(userId, Rules.afterGlowLoss(state))
			return
		elseif decision.action ~= "Send" then
			return
		end

		local claimed, previous = claimDay(userId, now)
		if not claimed then
			track("notification_sent", { userId = userId, category = "revenge", result = "Throttled" })
			return
		end
		local sent = postNotification(userId, "revenge", {
			raider = Rules.cleanParam(report.raiderName) :: string,
			critter = Rules.cleanParam(report.critterName) :: string,
		}, Rules.launchData(report.raidId))
		if not sent then
			releaseDay(userId, now, previous)
		else
			cache[userId] = Rules.afterSend(state, "revenge", true, now)
			track("notification_sent", { userId = userId, category = "revenge", raidId = report.raidId })
		end
	end)
end

function NotificationService.onStorageSample(userId: number, stored: number, capacity: number)
	if not enabled() then
		return
	end
	task.spawn(withLock, userId, function()
		local now = os.time()
		local state = loadState(userId)
		if not state then
			return
		end
		local decision =
			Rules.decideStorage(state, stored, capacity, Config.Notifications.storageNearlyFullShare, now, true)
		if decision.action ~= "Send" then
			return
		end
		local claimed, previous = claimDay(userId, now)
		if not claimed then
			track("notification_sent", { userId = userId, category = "storage", result = "Throttled" })
			return
		end
		if not postNotification(userId, "storage", {}, nil) then
			releaseDay(userId, now, previous)
		else
			saveState(userId, Rules.afterSend(state, "storage", true, now))
			track("notification_sent", { userId = userId, category = "storage" })
		end
	end)
end

function NotificationService.onSuccessfulRaid(player: Player, successfulRaids: number)
	if not enabled() then
		return
	end
	task.spawn(withLock, player.UserId, function()
		local now = os.time()
		local state = loadState(player.UserId)
		if not state then
			return
		end
		if not Rules.shouldPromptOptIn(state, successfulRaids, now, true) then
			return
		end
		local event = promptEvent
		if not event or pendingPrompt[player.UserId] then
			return
		end
		pendingPrompt[player.UserId] = true
		local ok, err = pcall(function()
			event:FireClient(player)
		end)
		if not ok then
			pendingPrompt[player.UserId] = nil
			warn(`[Notifications] opt-in push failed: {err}`)
			return
		end
		track("optin_prompted", { userId = player.UserId })
	end)
end

-- The client's answer to a push. Not saved unless the prompt was actually shown.
local function onReportOptInResult(player: Player, payload: any)
	local userId = player.UserId
	if not enabled() then
		return
	end
	local state = reportLimits[userId]
	if not state then
		state = {}
		reportLimits[userId] = state
	end
	if not RateLimit.take(state, "ReportOptInResult", Net.Limits.ReportOptInResult, os.clock()) then
		return
	end
	if not pendingPrompt[userId] then
		return -- nothing was pushed to this player
	end
	local report = Rules.cleanOptInReport(payload)
	if not report then
		return -- malformed: the prompt stays pending
	end
	pendingPrompt[userId] = nil
	if not report.shown then
		return -- never reached the player (can't prompt, dismissed early): no clock, no event
	end
	NotificationService.recordOptInResult(player, report.accepted)
	task.spawn(withLock, userId, function()
		local current = loadState(userId)
		if current then
			saveState(userId, Rules.afterPrompt(current, os.time()))
		end
	end)
end

function NotificationService.recordOptInResult(player: Player, accepted: boolean)
	track("optin_result", { userId = player.UserId, accepted = accepted })
end

function NotificationService.launchRaidId(player: Player): string?
	local ok, joinData = pcall(function()
		return player:GetJoinData()
	end)
	if not ok or type(joinData) ~= "table" then
		return nil
	end
	local raidId = Rules.parseLaunchData((joinData :: any).LaunchData)
	if raidId then
		track("notification_join", { userId = player.UserId, raidId = raidId })
	end
	return raidId
end

local function installRemotes()
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		remotes = Instance.new("Folder")
		remotes.Name = "Remotes"
		remotes.Parent = ReplicatedStorage
	end
	local push = Instance.new("RemoteEvent")
	push.Name = Net.Pushes.PromptNotificationOptIn
	push.Parent = remotes
	promptEvent = push
	local report = Instance.new("RemoteEvent")
	report.Name = Net.Requests.ReportOptInResult
	report.OnServerEvent:Connect(function(player: Player, payload: any)
		local ok, err = pcall(onReportOptInResult, player, payload)
		if not ok then
			warn(`[Notifications] ReportOptInResult failed: {err}`)
		end
	end)
	report.Parent = remotes
end

function NotificationService.start()
	installRemotes() -- created even when the flag is off, so clients can WaitForChild safely
	if not enabled() then
		return
	end
	local ok, ds = pcall(function()
		return DataStoreService:GetDataStore("NotificationState_v1")
	end)
	if ok then
		store = ds
	else
		warn("[Notifications] no DataStore; daily cap is per server only")
	end
	Players.PlayerRemoving:Connect(function(player)
		cache[player.UserId] = nil
		pendingPrompt[player.UserId] = nil
		reportLimits[player.UserId] = nil
	end)
end

return NotificationService
