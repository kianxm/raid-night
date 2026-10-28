--!strict
-- Builders for test data. Keep tests readable: build only what a test cares about.

local Types = require("../../src/Shared/Types")
local Profile = require("../../src/Shared/Profile")
local Config = require("../../src/Shared/Config")
local RaidRules = require("../../src/Shared/RaidRules")

type PlayerProfile = Types.PlayerProfile
type Critter = Types.Critter
type Placement = Types.Placement

local fixtures = {}

-- An established player: past new-player protection and above the minimum raidable den level.
function fixtures.veteran(userId: number, now: number): PlayerProfile
	local profile = Profile.new(userId, now - Config.Protection.newPlayerSeconds - 3600)
	profile.denLevel = Config.Protection.minDenLevel + 5
	profile.storedUpdatedAt = now
	profile.lossDay = RaidRules.dayIndex(now) -- daily counters belong to "today", not signup day
	return profile
end

function fixtures.critter(uid: string, speciesId: string, placement: Placement?, padIndex: number?): Critter
	local where: Placement = placement or "Pad"
	return {
		uid = uid,
		speciesId = speciesId,
		mutation = "None",
		placement = where,
		padIndex = if where == "Pad" then (padIndex or 1) else nil,
		acquiredAt = 0,
		stolenLockUntil = nil,
	}
end

function fixtures.give(profile: PlayerProfile, critter: Critter): Critter
	profile.critters[critter.uid] = critter
	return critter
end

return fixtures
