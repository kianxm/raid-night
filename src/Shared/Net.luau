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
}

export type RaidStart = {
	raidId: string,
	targetUserId: number,
	endsAt: number,
}

export type RaidEnd = {
	raidId: string,
	escaped: boolean,
	speciesId: string?,
	glow: number,
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
	StartRaid = "StartRaid", -- (targetUserId, revengeRaidId?) -> RaidStart?
	GrabCritter = "GrabCritter", -- RemoteEvent: (raidId, critterUid)
	GetRaidLog = "GetRaidLog", -- () -> { RaidLogEntry }
	GetReplay = "GetReplay", -- (raidId) -> compressed replay frames
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
})

--[[
	Replicated attributes: server-written, display-only state on Instances (full list in
	docs/contracts.md, "Replicated attributes"). The server keeps the truth in its own tables and
	never makes a gameplay or data decision from an attribute; clients must never be trusted for
	them.
	  Player:    Plot, CarryingUid ("" = not carrying), CarryingSpecies (species id, "" = none)
	  Den Model: Plot, OwnerUserId, LockdownUntil, LockdownReadyAt (workspace:GetServerTimeNow())
	  Pad:       PadIndex
	  Critter:   CritterUid, SpeciesId, Tier, PadIndex, OwnerUserId
]]

return Net
