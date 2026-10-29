--!strict
--[[
	Profile: the default shape of a new player's save, and the migration entry point.

	ProfileStore's template should be `Profile.new(0, 0)`; on load the server calls
	`Profile.migrate` before anything reads the data. Every schema change adds a numbered step
	to `migrations` and bumps Config.SCHEMA_VERSION.
]]

local Types = require("./Types")
local Config = require("./Config")
local RaidRules = require("./RaidRules")

type PlayerProfile = Types.PlayerProfile

local Profile = {}

function Profile.new(userId: number, now: number): PlayerProfile
	return {
		schemaVersion = Config.SCHEMA_VERSION,
		userId = userId,
		createdAt = now,

		glow = 0,
		stored = 0,
		storedUpdatedAt = now,
		denLevel = 1,
		rebirths = 0,
		raiderRank = 0,
		vaultSlots = 1,

		critters = {},
		traps = {},

		shieldUntil = 0,
		lossDay = RaidRules.dayIndex(now),
		lossesToday = 0,
		pairRaidsToday = {},
		-- liveLossBaseRate, liveLossRateToday: absent until the day's first live loss (D-031)

		raidLog = {},
		revengeTokens = {},
		appliedTransfers = {},

		nemesisUserId = nil,
		notificationPromptedAt = nil,
	}
end

-- Ordered migration steps. migrations[n] upgrades a profile from schema n to n + 1.
local migrations: { (profile: any) -> () } = {
	-- [1] = function(profile) profile.newField = default end,
}

-- Upgrades an older save in place. Errors on a save from a newer schema (never downgrade).
function Profile.migrate(profile: any): PlayerProfile
	local version = profile.schemaVersion or 1
	assert(version <= Config.SCHEMA_VERSION, `Profile.migrate: save is schema {version}, game is older`)
	while version < Config.SCHEMA_VERSION do
		local step = migrations[version]
		assert(step, `Profile.migrate: missing migration from schema {version}`)
		step(profile)
		version += 1
		profile.schemaVersion = version
	end
	return profile :: PlayerProfile
end

--[[
	Readies a save the server just loaded, before anything reads it. Runs, in order:
	migrate; stamp a brand-new save (ProfileStore copies the `Profile.new(0, 0)` template, so
	createdAt == 0 AND userId == 0 means "never played"); check the save belongs to `userId`;
	roll the daily counters; drop expired revenge tokens.

	It does NOT prune escrow idempotency entries (appliedTransfers): only EscrowService may, after
	reading the player's open-escrow index, because an open raid's entry must never be dropped.

	Mutates `data` in place and errors on a save it cannot trust (newer schema, wrong owner).
	DataService passes a copy so a failure leaves the loaded save untouched.
]]
function Profile.prepare(data: any, userId: number, now: number): PlayerProfile
	local profile = Profile.migrate(data)
	-- Only a true template copy is stamped. A real save with createdAt 0 keeps its userId, so a
	-- save that belongs to someone else still hits the ownership check below.
	if profile.createdAt == 0 and profile.userId == 0 then
		local fresh = Profile.new(userId, now)
		profile.userId = userId
		profile.createdAt = fresh.createdAt
		profile.storedUpdatedAt = fresh.storedUpdatedAt
		profile.lossDay = fresh.lossDay
	end
	assert(profile.userId == userId, `Profile.prepare: save belongs to {profile.userId}, not {userId}`)
	RaidRules.resetDailyIfNeeded(profile, now)
	RaidRules.pruneRevengeTokens(profile, now)
	return profile
end

--[[
	Studio test ids (decision D-019): whole numbers at or below TEST_USER_ID_MAX. No Roblox account
	has one, and they stay clear of Studio's Local Server test players (Player1 is -1, Player2 is
	-2, ...). DataService holds a test profile only in Studio with memory persistence, so a test id
	never reaches a DataStore.
]]
Profile.TEST_USER_ID_MAX = -1_000_000

function Profile.isTestUserId(userId: number): boolean
	return type(userId) == "number" and userId % 1 == 0 and userId <= Profile.TEST_USER_ID_MAX
end

local function isFinite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

--[[
	Marks the raid log seen at `now`: the server's clock (os.time()), never a client value.
	Forward only: a `now` that is not a finite number, or is earlier than the stored time, is
	ignored. A stored value that is not finite counts as never seen (0), so a bad save cannot pin
	it. The field is optional (missing = never), so it needs no migration. Returns whether it wrote.
]]
function Profile.markRaidLogSeen(profile: PlayerProfile, now: number): boolean
	if not isFinite(now) then
		return false
	end
	local stored = profile.raidLogSeenAt
	if now < (if isFinite(stored) then stored :: number else 0) then
		return false
	end
	profile.raidLogSeenAt = now
	return true
end

--[[
	Whether a critter may leave its owner by trade or gift. Any trading or gifting code must
	refuse a critter this returns false for (the reviewer checks). Raids are not trades: escrow
	moves untradeable critters like any other, and the flag travels with them (decision D-005).
]]
function Profile.isTradeable(critter: Types.Critter, now: number): boolean
	if critter.untradeable then
		return false
	end
	return critter.stolenLockUntil == nil or now >= critter.stolenLockUntil
end

return Profile
