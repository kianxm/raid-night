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
	GetReplay = "GetReplay", -- (raidId) -> compressed replay frames
	-- (revengeRaidId) -> RevengeJoinStatus. Live revenge (P1.9): join the server of the raider who
	-- robbed you, if they are online. Needs Config.Flags.raids and asyncRaids. Never spends the token.
	JoinRevengeServer = "JoinRevengeServer",
	-- () -> boolean (true if started). Den owner only, live raids only. Blocks entry only: raiders
	-- inside can leave, but a carried critter drops at the border. Server enforces Config.LiveRaid.
	Lockdown = "Lockdown",
})

-- Server -> client pushes (RemoteEvents).
Net.Pushes = table.freeze({
	DenChanged = "DenChanged", -- (DenState)
	RaidEnded = "RaidEnded", -- (RaidEnd)
	BeingRaidedLive = "BeingRaidedLive", -- (raiderUserId)
	ServerAnnouncement = "ServerAnnouncement", -- (kind, payload) e.g. Mythic stolen
	-- (RevengeJoinStatus) a live revenge join failed after Teleporting, or you arrived (P1.9)
	RevengeJoinStatus = "RevengeJoinStatus",
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
