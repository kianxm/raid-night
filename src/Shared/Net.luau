--!strict
--[[
	Net: the client <-> server contract. Every RemoteEvent and RemoteFunction name and payload
	shape lives here, so the UI agent and the server agents build against the same thing.

	Rules:
	  - The client only REQUESTS. The server decides and replies. Never trust a client payload.
	  - Every request is rate-limited per player on the server (see Limits below).
	  - Adding a remote is a contract change: update docs/contracts.md.
]]

local Types = require("./Types")

export type DenState = {
	glow: number,
	stored: number,
	storageCap: number,
	ratePerSecond: number,
	denLevel: number,
	rebirths: number,
	shieldUntil: number,
	critters: { Types.Critter },
}

export type RaidTarget = {
	userId: number,
	displayName: string,
	power: number,
	isRevenge: boolean,
	revengeRaidId: string?, -- set on revenge rows; pass it to StartRaid
	topTier: Types.Tier?, -- loot hint: highest tier on the den's pads (nil = none known); never exact Glow
	-- Revenge rows only: true when the raider was seen online in a server of this place (P1.9), so
	-- the UI can offer JoinRevengeServer. A hint: the join re-checks. nil/false = offline or unknown.
	raiderOnline: boolean?,
}

-- Live revenge join (P1.9): the reply to JoinRevengeServer and the RevengeJoinStatus push.
--   Teleporting  the server is teleporting you to the raider's server (wait for the push)
--   Arrived      you are next to the raider's den with the revenge token active (not spent)
--   Failed       `reason` says why; the token is still unused. Offer the async revenge raid
--                (StartRaid(targetUserId, revengeRaidId)) unless reason is SwitchedOff,
--                Invalid, NoToken, Expired, Unavailable or PairLimit.
-- Reasons: "SwitchedOff" | "Invalid" | "NoToken" | "Expired" | "Unavailable" | "PairLimit" |
-- "Busy" | "RaiderOffline" | "ServerFull" | "ServerGone" | "TeleportFailed"
export type RevengeJoinStatus = {
	state: "Teleporting" | "Arrived" | "Failed",
	revengeRaidId: string, -- "" when the request named no valid raid id
	targetUserId: number?, -- the raider, when the token is known
	reason: string?, -- set when state == "Failed"
}

-- One stealable critter in an async raid's pocket den, for display. Pad critters only: never a
-- Vault critter, never Glow, never the owner's block list.
export type PocketCritter = {
	uid: string, -- pass to GrabCritter
	speciesId: string,
	mutation: Types.Mutation,
	padIndex: number,
	position: any, -- Vector3: world position of its pad in the pocket den
}

export type RaidStart = {
	raidId: string,
	targetUserId: number,
	endsAt: number, -- server time (workspace:GetServerTimeNow()) when the raid times out
	gatePosition: any, -- Vector3: world position of the pocket den's escape gate
	critters: { PocketCritter }, -- the pocket den's stealable critters, by padIndex
	isRevenge: boolean,
}

export type RaidEnd = {
	raidId: string,
	escaped: boolean,
	speciesId: string?,
	glow: number,
	-- Async raids only: "Escaped" (reached the gate carrying; `escaped` is true only once the loot
	-- has moved), "Timeout", "Tagged", "Retreat" (gate with nothing), "Left", "Error". nil = live.
	reason: string?,
	-- Async "Escaped" only: true = escrow is still delivering (the den's owner is online in another
	-- server); it lands on its own and DenChanged shows it. speciesId and glow are then estimates.
	-- "Escaped" with escaped false and no pending: nothing moved.
	pending: boolean?,
}

-- GetReplay's answer (docs/contracts.md, Replays). data is a Shared/Replay.encode string in
-- format `version`; decode it with Replay.decode. Positions are relative to the pocket den origin.
export type ReplayPayload = {
	raidId: string,
	version: number,
	raiderUserId: number,
	defenderUserId: number,
	startedAt: number, -- unix seconds; frame i is startedAt + i / Replay.HZ
	data: string,
}

-- Settings (P2.5): GetSettings' answer and SaveSettings' request. Every field is present. The
-- server clamps each volume to 0..1 and rounds it to 0.01 (Profile.cleanSettings).
export type Settings = {
	musicVolume: number, -- 0 to 1; scales the music mix (default 0.6)
	sfxVolume: number, -- 0 to 1; scales sound effects (default 0.8)
	reducedMotion: boolean, -- default false
}

-- Onboarding progress (P2.6, playbook Appendix C): GetOnboarding's answer and the
-- OnboardingChanged push. Steps are Profile.ONBOARDING_STEPS, in order.
export type OnboardingStatus = {
	step: number, -- steps done: 0 to #Profile.ONBOARDING_STEPS (a save from before onboarding: all)
	nextStepId: string?, -- the step to guide next; nil once complete
	complete: boolean, -- finished or skipped (and every save from before onboarding): show none
}

-- Gear (P2.10). UseGear's answer. `readyAt` is server time (workspace:GetServerTimeNow()) when
-- that gear can be used again; `charges` the uses left in the current async raid (nil outside one).
-- `reason` is a GearRules.Reason when refused.
export type GearUseResult = {
	ok: boolean,
	reason: string?,
	readyAt: number?,
	charges: number?,
}

-- GetGear's rows, one per gear id, in Profile.GEAR_IDS order. level 0 = not owned.
export type GearSlot = {
	id: Types.GearId,
	level: number,
	readyAt: number, -- server time; 0 = ready
	charges: number?, -- uses left in the current async raid; nil outside one
	liveOnly: boolean, -- true for the lockpick
}

-- GearUsed push, for effects only (the server already applied everything). Times are server time.
--   Used         grapple (`position` = landing, `from` = take-off), smoke (`position`, `radius`,
--                `endsAt`), decoy (`position` = start, `direction`, `endsAt`), speedCoil
--                (`endsAt`), lockpick (pick started: `plot`, `endsAt` = when it completes)
--   Done         a lockpick finished: the picker may enter `plot` until that Lockdown ends
--   Interrupted  a lockpick broke (`reason`: GearRules.Reason Moved, Caught or NoLockdown)
--   Ended        a decoy was popped early (or a smoke/decoy cleared at a raid's end)
export type GearEvent = {
	userId: number,
	gearId: Types.GearId,
	state: "Used" | "Done" | "Interrupted" | "Ended",
	at: number,
	endsAt: number?,
	position: any?, -- Vector3
	from: any?, -- Vector3
	direction: any?, -- Vector3, unit, on X/Z
	radius: number?,
	plot: number?,
	reason: string?,
}

local Net = {}

-- Client -> server requests (RemoteFunctions unless noted).
Net.Requests = table.freeze({
	GetDenState = "GetDenState", -- () -> DenState
	Collect = "Collect", -- () -> number (Glow banked)
	PlaceCritter = "PlaceCritter", -- (uid, placement, padIndex?) -> boolean
	BuyEgg = "BuyEgg", -- () -> Critter?
	UpgradeDen = "UpgradeDen", -- () -> boolean
	GetRaidTargets = "GetRaidTargets", -- () -> { RaidTarget }, revenge rows first
	-- RemoteEvent: ({ number }) the local player's Roblox block list, sent on join and on every
	-- change. Distinct positive userIds, at most Config.Matchmaking.maxBlockedUserIds, else ignored.
	ReportBlocked = "ReportBlocked",
	-- (targetUserId, revengeRaidId?) -> RaidStart? (nil = refused). Async raids; one at a time.
	StartRaid = "StartRaid",
	-- RemoteEvent: (raidId, critterUid). Async raids: grab a pocket critter (pad prompts do the same).
	GrabCritter = "GrabCritter",
	GetRaidLog = "GetRaidLog", -- () -> { RaidLogEntry }; also marks the log seen (raidLogSeenAt)
	-- (raidId) -> ReplayPayload?; nil when missing, expired (7 days), not yet saved, or the caller
	-- is neither the raider nor the defender of that raid.
	GetReplay = "GetReplay",
	-- (revengeRaidId) -> RevengeJoinStatus. Live revenge (P1.9): join the server of the raider who
	-- robbed you, if they are online. Needs Config.Flags.raids and asyncRaids. Never spends the token.
	JoinRevengeServer = "JoinRevengeServer",
	-- () -> boolean (true if started). Den owner only, live raids only. Blocks entry only: raiders
	-- inside can leave, but a carried critter drops at the border. Server enforces Config.LiveRaid.
	Lockdown = "Lockdown",
	-- () -> Settings?, defaults filled in. Waits (up to 20 s) for the profile to load; nil = it did
	-- not load in time, or the request was refused: keep the client's defaults.
	GetSettings = "GetSettings",
	-- (Settings) -> boolean. A table with all three fields: finite volumes (clamped to 0..1, rounded
	-- to 0.01) and a boolean reducedMotion; extra keys are ignored. false = refused, nothing saved.
	-- true = saved with the profile; past Net.Limits.SaveSettings the latest request is kept and
	-- applied when the limit's window reopens (or on leave), so the last change is never dropped.
	SaveSettings = "SaveSettings",
	-- () -> OnboardingStatus?. Waits (up to 20 s) for the profile to load; nil = not loaded in time.
	GetOnboarding = "GetOnboarding",
	-- (stepId) -> boolean. Client-side acknowledgements only (a "Client" step of
	-- Profile.ONBOARDING_STEPS, e.g. "raidLogTip"), and only the next step. true = recorded now or
	-- already behind the player; false = refused. Every other step advances from server events.
	AckOnboarding = "AckOnboarding",
	-- (gearId, target?) -> GearUseResult. target: a Vector3 aim point for the grapple, ignored by
	-- the rest. The server checks ownership, cooldown, charges, raid kind, range, line of sight and
	-- Lockdown, and moves or spawns everything itself (P2.10).
	UseGear = "UseGear",
	GetGear = "GetGear", -- () -> { GearSlot }
	-- (gearId) -> boolean. Buy (level 0 -> 1) or upgrade one gear item with Glow. Not served yet:
	-- economy owns the Glow spend (handoff, P2.10); clients must not call it until it ships.
	UpgradeGear = "UpgradeGear",
	-- RemoteEvent: ({ shown: boolean, accepted: boolean }). After the client tried
	-- ExperienceNotificationService:PromptOptIn for a PromptNotificationOptIn push. Accepted only
	-- once per push (one pending prompt per player); the 30-day clock starts only when shown = true.
	ReportOptInResult = "ReportOptInResult",
})

-- Server -> client pushes (RemoteEvents).
Net.Pushes = table.freeze({
	DenChanged = "DenChanged", -- (DenState)
	RaidEnded = "RaidEnded", -- (RaidEnd)
	BeingRaidedLive = "BeingRaidedLive", -- (raiderUserId)
	ServerAnnouncement = "ServerAnnouncement", -- (kind, payload) e.g. Mythic stolen
	-- (RevengeJoinStatus) a live revenge join failed after Teleporting, or you arrived (P1.9)
	RevengeJoinStatus = "RevengeJoinStatus",
	-- (OnboardingStatus) after every step the player completes (server event or AckOnboarding)
	OnboardingChanged = "OnboardingChanged",
	-- (GearEvent) gear effects: to every player for the shared world, to the raider for a pocket
	GearUsed = "GearUsed",
	-- () a player's first successful raid landed and the server wants the opt-in prompt shown. The
	-- client checks CanPromptOptInAsync, calls PromptOptIn, then answers with ReportOptInResult.
	PromptNotificationOptIn = "PromptNotificationOptIn",
})

-- Max requests per player per 10 seconds, enforced server-side.
Net.Limits = table.freeze({
	default = 20,
	GrabCritter = 5,
	StartRaid = 3,
	BuyEgg = 10,
	Lockdown = 3,
	GetRaidTargets = 3,
	ReportBlocked = 2,
	JoinRevengeServer = 2,
	GetReplay = 3,
	GetSettings = 3,
	SaveSettings = 3,
	GetOnboarding = 3,
	AckOnboarding = 3,
	UseGear = 6,
	GetGear = 5,
	UpgradeGear = 5,
	ReportOptInResult = 3,
})

--[[
	Replicated attributes: server-written, display-only state on Instances (full list in
	docs/contracts.md, "Replicated attributes"). The server keeps the truth in its own tables and
	never makes a gameplay or data decision from an attribute; clients must never be trusted for
	them.
	  Player:    Plot, CarryingUid ("" = not carrying), CarryingSpecies (species id, "" = none),
	             RaidLogSeenAt (unix seconds the log was last opened before this session; 0 = never)
	  Den Model: Plot, OwnerUserId, LockdownUntil, LockdownReadyAt (workspace:GetServerTimeNow())
	  Pad:       PadIndex
	  Critter:   CritterUid, SpeciesId, Tier, PadIndex, OwnerUserId
]]

return Net
