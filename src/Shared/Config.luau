--!strict
--[[
	Config: every tuning knob in one place.

	Values are the launch defaults from the design doc. Later, the server can overlay live
	values from a config DataStore so tuning never needs a publish; pure modules always read
	from this table (or an overlay with the same shape), never from hard-coded numbers.
]]

local HOUR = 3600
local DAY = 86400

local function deepFreeze<T>(t: T): T
	for _, value in t :: any do
		if type(value) == "table" and not table.isfrozen(value) then
			deepFreeze(value)
		end
	end
	return table.freeze(t :: any) :: any
end

local Config = {
	SCHEMA_VERSION = 1,

	-- Kill switches. false turns the feature off everywhere; every service checks its flag
	-- before acting. Defaults: only features that exist are on.
	Flags = {
		raids = true, -- live stealing (Phase 0)
		asyncRaids = false, -- offline raids (Phase 1)
		purchases = false, -- Robux products (Phase 2)
		trading = false, -- trading (post-launch)
		notifications = false, -- experience notifications (Phase 2)
	},

	Loot = {
		maxCrittersPerRaid = 1,
		storedGlowShare = 0.25, -- share of the defender's stored Glow a raid can take
		revengeBonus = 0.10, -- extra share on revenge raids (0.25 * 1.10)
	},

	Shield = {
		afterSuccessfulRaidSeconds = 4 * HOUR,
		purchasedSeconds = 8 * HOUR,
		maxStackSeconds = 24 * HOUR, -- purchased shields cannot extend past now + this
	},

	Protection = {
		newPlayerSeconds = 48 * HOUR,
		minDenLevel = 5, -- dens below this level cannot be raided async
	},

	Limits = {
		-- Critters a player can lose to ASYNC raids per UTC day (every loss counts toward it). Live
		-- steals use LiveRaid's value-based protection instead (decision D-031).
		maxLossesPerDay = 3,
		maxRaidsPerPairPerDay = 2, -- raids between the same two players per UTC day, revenge included
	},

	Revenge = {
		windowSeconds = 24 * HOUR,
	},

	Raid = {
		durationSeconds = 180,
		lockTtlSeconds = 240, -- MemoryStore raid lock expiry; must exceed durationSeconds
		stolenTradeLockSeconds = 24 * HOUR,
	},

	-- Live stealing in a den whose owner is online (decision D-003). Server-enforced.
	LiveRaid = {
		lockdownSeconds = 45, -- a Lockdown blocks new raiders from entering the den this long
		-- Counts from the END of a Lockdown (decision D-011). LockdownUntil = start + lockdownSeconds;
		-- LockdownReadyAt = LockdownUntil + lockdownCooldownSeconds, the earliest the next one can
		-- start. So a den is locked at most 45 s in every 165 s.
		lockdownCooldownSeconds = 120,
		tagRange = 6, -- studs: how close the owner must be to tag a raider
		grabHoldSeconds = 1, -- how long a raider holds the grab to pick a critter up
		-- Studs from the raider's root part to the pad centre: how close a raider must be to start
		-- a grab, and to stay for the whole hold (decision D-018).
		grabRange = 10,
		-- Live loss rules (decision D-031). The next three are launch guesses; tuned in Phase 3 (P3.9).
		-- After a live loss nobody can grab from that den for this long (RaidService memory).
		postLossSafetySeconds = 60,
		-- Live steals between the same two players per UTC day (the shared pairRaidsToday count).
		maxStealsPerPairPerDay = 2,
		-- While today's live losses reach this share of the larger of the day's base (the den's
		-- Glow/s at its first live loss today) and the den's Glow/s now, the den is protected from
		-- live steals (D-036); the escrow debit also counts the grab's rate (D-037).
		protectionLossShare = 0.5,
	},

	Income = {
		baseStorageSeconds = 8 * HOUR, -- storage cap at den level 1, expressed in seconds of income
		storageSecondsPerLevel = 15 * 60, -- +15 min of storage per den level
		vaultMultiplier = 0.5,
		rebirthMultiplierStep = 0.5, -- each rebirth adds +50% Glow
	},

	-- Robux-bought Glow multipliers (decision D-030). They multiply Glow earned in play and never
	-- grant Glow directly. Bonuses stack additively: VIP + Lantern Night = +100%, so 2.0x (not
	-- 1.5 * 1.5). Robux-linked: never applied to a player whose PolicyService info restricts paid
	-- random items (ArePaidRandomItemsRestricted). Fail closed: if PolicyService can't be read
	-- for a player, treat them as restricted. Their Glow stays earn-only, so eggs stay purchasable
	-- for them. Ship only after the P2.8 reviewer policy audit and PolicyService check.
	Boosts = {
		vipGlowBonus = 0.5, -- VIP pass: +50% Glow (1.5x on its own)
		lanternNightGlowBonus = 0.5, -- Lantern Night server boost: +50% Glow for everyone in the server
		lanternNightSeconds = 15 * 60, -- how long one Lantern Night lasts
	},

	Mutations = {
		None = 1,
		Shiny = 1.5,
		Moonlit = 2,
		Haunted = 3,
		Golden = 5,
	},

	-- Base egg odds. Must sum to 1. Secret critters are event-only and never in eggs.
	EggOdds = {
		{ tier = "Common", weight = 0.55 },
		{ tier = "Uncommon", weight = 0.25 },
		{ tier = "Rare", weight = 0.12 },
		{ tier = "Epic", weight = 0.06 },
		{ tier = "Legendary", weight = 0.018 },
		{ tier = "Mythic", weight = 0.002 },
	},

	Economy = {
		maxDenLevel = 50,
		upgradeCostBase = 100,
		upgradeCostGrowth = 1.35, -- cost(level) = base * growth^(level - 1)
		eggPriceBase = 50,
		eggPriceGrowth = 1.12, -- egg price scales with den level
		rebirthMinTier = "Legendary", -- must own at least one critter of this tier or higher
		-- Highest tier a bought egg can hatch. Tiers up to it keep their EggOdds ratios,
		-- renormalized (Economy.rollTierUpTo). Phase 2 raises it to "Mythic" (decision D-003).
		eggMaxTier = "Uncommon",
	},

	Matchmaking = {
		powerTolerance = 0.15, -- targets within +/-15% of the raider's power
		minWindow = 100, -- ...but never a window narrower than +/-100 power
		recentlyRaidedSeconds = 4 * HOUR, -- skip dens raided this recently
		activeWithinSeconds = 7 * DAY, -- only dens whose owner played this recently
		candidates = 3, -- targets offered per Raid Portal visit
	},

	Snapshot = {
		intervalSeconds = 120,
	},

	RaidLog = {
		maxEntries = 30,
	},

	Escrow = {
		appliedTransferRetentionSeconds = 7 * DAY, -- never applied to a raid that is still open
		maxRaidIdLength = 43, -- DataStore keys are at most 50 characters, minus "Escrow_"; a GUID is 36
	},

	Notifications = {
		-- One send per player per day is a platform limit. Spend it on the first critter lost.
		sendOnFirstCritterLost = true,
		storageNearlyFullShare = 0.9,
	},
}

return deepFreeze(Config)
