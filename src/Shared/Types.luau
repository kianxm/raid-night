--!strict
--[[
	Types: the shared contracts for Raid Night.

	Every service, every agent and every test builds against these types. Changing anything in
	this file is a contract change:
	  1. Update docs/contracts.md in the same commit.
	  2. Bump SCHEMA_VERSION in Config.luau if a persisted shape changed, and add a migration.
	  3. Get a review from the `reviewer` agent before merging.

	Persisted types (saved to DataStore) are marked [persisted]. Never remove or rename a field on
	a persisted type without a migration. An optional field whose absence means the old behavior
	needs no migration or SCHEMA_VERSION bump, but needs an old-save test (D-005).
]]

-- Critter catalog -------------------------------------------------------------------------------

export type Tier = "Common" | "Uncommon" | "Rare" | "Epic" | "Legendary" | "Mythic" | "Secret"

export type Mutation = "None" | "Shiny" | "Moonlit" | "Haunted" | "Golden"

-- Weight slows the player carrying a stolen critter. Heavier = rarer = riskier to grab.
export type Weight = "Light" | "Medium" | "Heavy" | "VeryHeavy"

-- A species is static design data from Data/Critters.luau. Never persisted.
export type CritterSpecies = {
	id: string, -- stable snake_case id; never reuse or rename once shipped
	name: string, -- display name
	tier: Tier,
	glowPerSecond: number, -- base income before mutation and rebirth multipliers
	weight: Weight,
	look: string, -- one-line visual description; feeds asset prompts (tools/assets)
	idle: string, -- the funny idle animation, one line; feeds animation briefs
	personality: string, -- one or two words, e.g. "smug"; the face in every prompt (style bible)
	palette: { string }, -- 2-4 hex colors; first is the glow color
	eventOnly: boolean, -- true = never in eggs; only from events
}

-- Owned critters ----------------------------------------------------------------------------------

-- Where an owned critter sits. Pad earns and can be stolen. Vault earns half and is never
-- stealable in async raids. Guard earns nothing and defends. Inventory is unplaced.
export type Placement = "Pad" | "Vault" | "Guard" | "Inventory"

-- [persisted] One owned critter. `uid` is globally unique and is the anti-duplication key:
-- a uid must exist in exactly one place at any moment (one profile, or one in-flight escrow).
export type Critter = {
	uid: string,
	speciesId: string,
	mutation: Mutation,
	placement: Placement,
	padIndex: number?, -- set only when placement == "Pad"
	acquiredAt: number, -- unix seconds
	stolenLockUntil: number?, -- untradeable until this time (set when stolen)
	-- Never tradeable or giftable (e.g. rescue-egg critters). Missing = tradeable, so no
	-- migration. Survives escrow. Check with Profile.isTradeable (decision D-005).
	untradeable: boolean?,
}

-- Den defenses --------------------------------------------------------------------------------

export type TrapKind = "SlowPuddle" | "Net" | "Sprinkler" | "AlarmMoth" | "Trapdoor"

-- [persisted]
export type Trap = {
	kind: TrapKind,
	level: number,
	gridX: number,
	gridY: number,
}

-- Raids, revenge, logs ---------------------------------------------------------------------------

-- [persisted] A revenge right granted to a defender after a successful raid on them.
export type RevengeToken = {
	raidId: string, -- the raid that created this token
	targetUserId: number, -- the raider, who becomes the revenge target
	expiresAt: number,
	shieldBypassUsed: boolean, -- revenge may ignore the target's shield once
}

export type RaidDirection = "Incoming" | "Outgoing"

-- [persisted] One line in a player's raid log (newest first, capped by Config.RaidLog.maxEntries).
export type RaidLogEntry = {
	raidId: string,
	direction: RaidDirection,
	otherUserId: number,
	escaped: boolean, -- for Incoming: true = you were robbed; false = you held
	speciesId: string?, -- critter taken, if any
	glow: number,
	at: number,
	isRevenge: boolean,
}

-- [persisted, inside PlayerProfile.appliedTransfers] What a profile applied for one raid.
-- Kept so a retried transfer returns the same answer instead of applying twice.
export type AppliedTransfer = {
	role: "Debit" | "Credit",
	at: number,
	critter: Critter?, -- the exact critter debited or credited, if any
	glow: number,
}

-- Player profile --------------------------------------------------------------------------------

-- [persisted] The whole saved state for one player. One DataStore key per user, session-locked
-- by ProfileStore. Other servers never write it directly: they send messages (see Escrow.luau).
export type PlayerProfile = {
	schemaVersion: number,
	userId: number,
	createdAt: number,

	-- Economy
	glow: number, -- banked Glow: safe, never stealable
	stored: number, -- unbanked Glow sitting in the den: stealable (share capped per raid)
	storedUpdatedAt: number, -- last time `stored` was accrued
	denLevel: number,
	rebirths: number,
	raiderRank: number,
	vaultSlots: number,

	-- Collection and defenses
	critters: { [string]: Critter }, -- keyed by uid
	traps: { Trap },

	-- Raid safety state
	shieldUntil: number,
	lossDay: number, -- UTC day index the daily counters belong to
	-- Critters lost today, live and async. Async raids stop at Config.Limits.maxLossesPerDay; live
	-- steals use the value rule below instead (decision D-031).
	lossesToday: number,
	pairRaidsToday: { [string]: number }, -- other userId (as string) -> raids and live steals between you today
	-- Live loss rules (decision D-031). Both belong to lossDay and go back to nil when the day rolls
	-- (RaidRules.resetDailyIfNeeded). Missing = no live loss today, so no migration.
	-- The den's Glow/s for today's first live loss: at its grab (EscrowRecord.liveBaseRate, D-034),
	-- or just before its debit when the record has no grab-time base.
	liveLossBaseRate: number?,
	liveLossRateToday: number?, -- Glow/s of the critters lost to live steals today, summed

	-- Raid history and idempotency
	raidLog: { RaidLogEntry },
	revengeTokens: { [string]: RevengeToken }, -- keyed by raidId
	appliedTransfers: { [string]: AppliedTransfer }, -- keyed by raidId; pruned after 7 days

	-- Social and notifications
	nemesisUserId: number?,
	notificationPromptedAt: number?,
	-- When the player last opened their raid log (unix seconds), set server-side on GetRaidLog.
	-- Missing = never (old saves), so no migration (D-005).
	raidLogSeenAt: number?,
}

-- Snapshots and matchmaking ---------------------------------------------------------------------

-- [persisted, separate key] The raidable picture of a den, saved on leave and every
-- Config.Snapshot.intervalSeconds while online. Async raids are built from this, never from
-- the live profile.
export type DenSnapshot = {
	schemaVersion: number,
	userId: number,
	takenAt: number,
	power: number,
	defenseRating: number,
	denLevel: number,
	critters: { Critter }, -- Pad and Guard critters only. Vault critters are never included.
	traps: { Trap },
	storedGlow: number, -- `stored` accrued at snapshot time
	shieldUntil: number,
	protectedUntil: number, -- new-player protection end
	-- userIds the owner blocked on Roblox, as their client last reported (Net.Requests.ReportBlocked).
	-- Missing = blocks nobody (snapshots saved before it existed, or no report yet); no migration.
	blockedUserIds: { number }?,
}

-- [MemoryStore, not persisted] One entry in a matchmaking pool.
export type MatchEntry = {
	userId: number,
	power: number,
	lastActiveAt: number,
	lastRaidedAt: number,
	shieldUntil: number,
	protectedUntil: number,
}

-- Escrow ----------------------------------------------------------------------------------------

-- Pending: created by the raider's server when a raid ends in an escape.
-- Debited: the defender's profile has given up the loot; the loot lives only in this record.
-- Committed: the raider's profile has received the loot. Terminal.
-- Voided: cancelled before any debit (cheat detected, raid invalid). Terminal.
export type EscrowState = "Pending" | "Debited" | "Committed" | "Voided"

-- Live: a steal between two players in one server (EscrowService.transferLive). Async: a raid on
-- an offline den (Phase 1). The kind decides which daily loss rule the debit applies (D-031).
export type TransferKind = "Live" | "Async"

-- [persisted, separate key per raidId] The record that makes a cross-profile transfer safe.
export type EscrowRecord = {
	raidId: string,
	raiderUserId: number,
	defenderUserId: number,
	critterUid: string?, -- the critter the raider grabbed, if any
	-- Loot Glow computed from the snapshot. Live: the most the debit takes. Async: only the raid's
	-- estimate; the debit takes its share of what is stored when it lands (P1.1).
	glowRequested: number,
	state: EscrowState,
	critter: Critter?, -- filled at Debited: the exact critter taken (nil if it was gone)
	glow: number, -- filled at Debited: Glow actually taken (Live: <= glowRequested; Async: its share of stored at the debit)
	isRevenge: boolean,
	createdAt: number,
	updatedAt: number,
	-- A unique id (GUID) set by the call that creates the record and never changed, so that call
	-- recognises its own create when the write landed but the response was lost. Missing on
	-- records written before it existed; no migration (they are simply never "ours").
	createNonce: string?,
	-- Set at create and never changed (Escrow.canReplace). Missing = "Live": every record written
	-- before it existed is a Phase 0 live steal, so no migration (decision D-031).
	kind: TransferKind?,
	-- Live only (decision D-034): the defender den's Glow/s (Economy.denRate) when the raider's
	-- grab was accepted, before the owner could react. The base for the day's first live loss,
	-- and a floor of the protection line at this record's own debit (decision D-037), so a shrink
	-- during the carry cannot refuse it. Set by Escrow.create (checked by Escrow.checkLiveBaseRate, rounded to 0.001 Glow/s) and never
	-- changed; part of the transfer's identity (Escrow.sameTransfer). Missing = no grab-time
	-- measurement (records written before it existed, Async): the debit measures the den instead.
	-- No migration.
	liveBaseRate: number?,
	-- Async revenge only (P1.3d): the raider's revenge token this raid uses (its key in the
	-- raider's revengeTokens: the raidId of the raid on them that granted it), from the raid's
	-- start. A credit that moved something removes that token (D-054). Set by Escrow.create (checked by
	-- Escrow.checkRevengeRaidId) and never changed; part of the transfer's identity
	-- (Escrow.sameTransfer). Missing = no token named (records written before it existed,
	-- non-revenge, Live): the credit spends none. No migration.
	revengeRaidId: string?,
}

-- [persisted, inside EscrowOpenIndex] One open escrow a player is a party to.
export type EscrowOpenEntry = {
	role: "Raider" | "Defender",
	createdAt: number, -- when the raid's transfer started (unix seconds)
}

-- [persisted, separate key per user: `Open_<userId>`] Open escrows a player is a party to, keyed
-- by raidId. Written for BOTH parties before the record is created; removed once the record is
-- terminal. Recovery reads it on every load, and appliedTransfers entries for raidIds listed
-- here are never pruned.
export type EscrowOpenIndex = { [string]: EscrowOpenEntry }

-- Results ------------------------------------------------------------------------------------

export type Result<T> = { ok: true, value: T } | { ok: false, reason: string }

return {}
