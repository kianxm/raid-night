--!strict
--[[
	RaidEvents (owner: raid agent): what a raid tells other services (P2.6r). Kept out of the raid
	loops so RaidService and AsyncRaid each make one call per moment.

	Analytics (P2.9, schema in Shared/Analytics, sent by AnalyticsService):
	  raid_started     a live carry starts (the grab completed) or an async raid entered its pocket
	  revenge_started  the same moment, when the raid is a revenge (hours since the raid that
	                   granted the token, whether the join came from a revenge notification)
	  raid_ended       every live carry end (drop or escape) and every async raid end
	  RaidFlow TargetPicked  a StartRaid request with a well-formed target (the portal pick)
	The funnel steps that follow from events (RaidStarted, Escaped, Onboarding FirstRaid for an
	async start, FirstSteal for an escape with a critter) are AnalyticsService's, from the events.
	The tutorial den logs no raid event: it is onboarding, not a raid (onboarding_step covers it).

	Successful raids (P2.7 opt-in timing): succeeded(userId) at a live escape that moved the critter
	or an async escape whose loot is credited. The tutorial steal never calls it: the opt-in
	prompt comes after the first REAL raid (Appendix C step 7) and NotificationRules prompts only
	at a lifetime count of exactly 1. The count goes through DataService.countSuccessfulRaid
	(data's API; skipped while it does not exist), then NotificationService.onSuccessfulRaid.

	Nothing here yields, throws, or writes a profile; every other service is reached under pcall.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local CritterCatalog = require(Shared.CritterCatalog)
local Matchmaking = require(Shared.Matchmaking)
local RaidRules = require(Shared.RaidRules)
local Types = require(Shared.Types)
local Services = script.Parent.Parent.Services
local AnalyticsService = require(Services.AnalyticsService) :: any
local DataService = require(Services.DataService) :: any

type PlayerProfile = Types.PlayerProfile
type Mode = "Live" | "Async"

local RaidEvents = {}

local function track(player: Player, event: string, fields: { [string]: any })
	local ok, err = pcall(AnalyticsService.track, player, event, fields)
	if not ok then
		warn(`[RaidEvents] {event} for {player.UserId} failed: {err}`)
	end
end

-- NotificationService, found by name and required in pcall: a broken or missing one never
-- reaches a raid.
local function notifications(): any?
	local module = Services:FindFirstChild("NotificationService")
	if not (module and module:IsA("ModuleScript")) then
		return nil
	end
	local ok, service = pcall(require, module)
	return if ok and type(service) == "table" then service else nil
end

local function tierOf(speciesId: string?): string
	local species = if speciesId then CritterCatalog.get(speciesId) else nil
	return if species then species.tier else "None"
end

local function amount(value: any): number
	return if type(value) == "number" and value == value and value >= 0 and value < math.huge then value else 0
end

-- revenge_started, read from the raider's own revenge token (server state only).
local function revengeStarted(player: Player, revengeRaidId: string, mode: Mode)
	local profile = DataService.getProfile(player.UserId)
	local token = if profile then profile.revengeTokens[revengeRaidId] else nil
	local service = notifications()
	local launched = nil
	if service and type(service.launchRaidId) == "function" then
		local ok, raidId = pcall(service.launchRaidId, player)
		launched = if ok then raidId else nil
	end
	track(player, "revenge_started", {
		hoursSinceRaided = if token then RaidRules.hoursSinceRaided(token, os.time()) else 0,
		fromNotification = launched ~= nil and launched == revengeRaidId,
		mode = mode,
	})
end

local function started(player: Player, mode: Mode, targetPower: number, revengeRaidId: string?)
	track(player, "raid_started", { mode = mode, revenge = revengeRaidId ~= nil, targetPower = amount(targetPower) })
	if revengeRaidId then
		revengeStarted(player, revengeRaidId, mode)
	end
end

-- A live carry started: the grab completed on `ownerProfile`'s den.
function RaidEvents.liveStarted(player: Player, ownerProfile: PlayerProfile?, revengeRaidId: string?)
	pcall(function()
		local power = if ownerProfile then Matchmaking.denPower(ownerProfile) else 0
		started(player, "Live", power, revengeRaidId)
	end)
end

-- A live carry ended: escaped is true only when the critter is in the raider's profile.
function RaidEvents.liveEnded(player: Player, escaped: boolean, speciesId: string, seconds: number)
	pcall(track, player, "raid_ended", {
		mode = "Live",
		escaped = escaped,
		tierTaken = if escaped then tierOf(speciesId) else "None",
		glow = 0, -- live steals take no Glow (D-015)
		durationSeconds = amount(seconds),
	})
end

-- RaidFlow's TargetPicked: a StartRaid request for a well-formed target.
function RaidEvents.targetPicked(player: Player)
	local ok, err = pcall(AnalyticsService.step, player, "RaidFlow", "TargetPicked")
	if not ok then
		warn(`[RaidEvents] TargetPicked for {player.UserId} failed: {err}`)
	end
end

-- An async raid entered its pocket, on a snapshot of `snapshotPower`.
function RaidEvents.asyncStarted(player: Player, snapshotPower: number, revengeRaidId: string?)
	pcall(started, player, "Async", snapshotPower, revengeRaidId)
end

-- An async raid ended. `outcome` is the escape's (nil for every other end): escaped counts the
-- loot credited or still on its way (pending); what was taken is escrow's answer, never the
-- snapshot's.
function RaidEvents.asyncEnded(player: Player, outcome: RaidRules.EscapeOutcome?, seconds: number)
	pcall(function()
		local escaped = outcome ~= nil and (outcome.escaped or outcome.pending == true)
		track(player, "raid_ended", {
			mode = "Async",
			escaped = escaped,
			tierTaken = if escaped and outcome then tierOf(outcome.speciesId) else "None",
			glow = if escaped and outcome then amount(outcome.glow) else 0,
			durationSeconds = amount(seconds),
		})
	end)
end

--[[
	A successful raid by `userId` (a live escape that moved the critter, or a credited async
	escape). Counts it on the raider's loaded profile through DataService (never a write here) and
	gives NotificationService the new lifetime count for the opt-in prompt. Never the tutorial.
]]
function RaidEvents.succeeded(userId: number)
	local count = DataService.countSuccessfulRaid -- data's API (handoff); skipped until it exists
	if type(count) ~= "function" then
		return
	end
	local ok, lifetime = pcall(count, userId)
	if not ok then
		warn(`[RaidEvents] countSuccessfulRaid for {userId} failed: {lifetime}`)
		return
	end
	local player = Players:GetPlayerByUserId(userId)
	local service = notifications()
	if type(lifetime) == "number" and player and service and type(service.onSuccessfulRaid) == "function" then
		local sent, err = pcall(service.onSuccessfulRaid, player, lifetime)
		if not sent then
			warn(`[RaidEvents] onSuccessfulRaid for {userId} failed: {err}`)
		end
	end
end

return RaidEvents
