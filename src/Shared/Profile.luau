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
local Escrow = require("./Escrow")

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
	createdAt == 0 means "never played"); check the save belongs to `userId`; roll the daily
	counters; drop expired revenge tokens and old escrow idempotency entries.

	Mutates `data` in place and errors on a save it cannot trust (newer schema, wrong owner).
	DataService passes a copy so a failure leaves the loaded save untouched.
]]
function Profile.prepare(data: any, userId: number, now: number): PlayerProfile
	local profile = Profile.migrate(data)
	if profile.createdAt == 0 then
		local fresh = Profile.new(userId, now)
		profile.userId = userId
		profile.createdAt = fresh.createdAt
		profile.storedUpdatedAt = fresh.storedUpdatedAt
		profile.lossDay = fresh.lossDay
	end
	assert(profile.userId == userId, `Profile.prepare: save belongs to {profile.userId}, not {userId}`)
	RaidRules.resetDailyIfNeeded(profile, now)
	RaidRules.pruneRevengeTokens(profile, now)
	Escrow.pruneApplied(profile, now)
	return profile
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
