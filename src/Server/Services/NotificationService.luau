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
	                                      Call after the escrow debit has committed, from the
	                                      raider's server, for online and offline defenders.
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
	when (state + rules) and tells the client through `setPromptOptInHook` (a function the ui /
	net owner wires to a RemoteEvent; no new remote is added here, Net.luau is a contract). Until
	a hook is set the decision is made and logged but nothing is shown and the 30-day clock does
	not start.

	Persistence: its own DataStore ("NotificationState_v1", one small record per user, written
	with UpdateAsync) so it works for offline defenders without touching another player's
	profile. If data adds profile fields instead, swap `Store` (get/update) and nothing else.

	Analytics (task P2.9 fills this in): every event goes through `track` below.
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config")) :: any
local Rules = require(Shared:WaitForChild("NotificationRules")) :: any

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
local promptOptInHook: ((player: Player) -> ())? = nil

local function enabled(): boolean
	return Config.Flags.notifications == true
end

-- Single analytics call point (P2.9 wires this to the analytics service).
-- Events: notification_sent, notification_join, optin_prompted, optin_result.
local function track(event: string, fields: { [string]: any })
	-- P2.9: forward to analytics. Until then a debug line only.
	if Config.Flags.notifications then
		print(`[Notifications] {event}`, HttpService:JSONEncode(fields))
	end
end

local function loadState(userId: number): Rules.State
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
			}
		elseif not ok then
			warn(`[Notifications] state read failed for {userId}`)
		end
	end
	cache[userId] = state
	return state
end

local function saveState(userId: number, state: Rules.State)
	cache[userId] = state
	if not store then
		return
	end
	local ok = pcall(function()
		(store :: DataStore):UpdateAsync(tostring(userId), function()
			return {
				lastSentDay = state.lastSentDay,
				glowLossPending = state.glowLossPending,
				promptedAt = state.promptedAt,
			}
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

		local sent = postNotification(userId, "revenge", {
			raider = Rules.cleanParam(report.raiderName) :: string,
			critter = Rules.cleanParam(report.critterName) :: string,
		}, Rules.launchData(report.raidId))
		if sent then
			saveState(userId, Rules.afterSend(state, "revenge", true, now))
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
		local decision =
			Rules.decideStorage(state, stored, capacity, Config.Notifications.storageNearlyFullShare, now, true)
		if decision.action ~= "Send" then
			return
		end
		if postNotification(userId, "storage", {}, nil) then
			saveState(userId, Rules.afterSend(state, "storage", true, now))
			track("notification_sent", { userId = userId, category = "storage" })
		end
	end)
end

-- Wired by the ui / net owner: show ExperienceNotificationService:PromptOptIn on this client.
function NotificationService.setPromptOptInHook(hook: (player: Player) -> ())
	promptOptInHook = hook
end

function NotificationService.onSuccessfulRaid(player: Player, successfulRaids: number)
	if not enabled() then
		return
	end
	task.spawn(withLock, player.UserId, function()
		local now = os.time()
		local state = loadState(player.UserId)
		if not Rules.shouldPromptOptIn(state, successfulRaids, now, true) then
			return
		end
		local hook = promptOptInHook
		if not hook then
			warn("[Notifications] opt-in prompt due but no hook is set")
			return
		end
		hook(player)
		saveState(player.UserId, Rules.afterPrompt(state, now))
		track("optin_prompted", { userId = player.UserId })
	end)
end

-- Called by the client path when PromptOptIn resolves (via the same hook owner), for analytics.
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

function NotificationService.start()
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
	end)
end

return NotificationService
