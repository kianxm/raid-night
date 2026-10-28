--!strict
--[[
	Matchmaking: pure target selection for the Raid Portal.

	The server keeps one MemoryStore sorted map per power band (see `powerBand`). To offer
	targets, it reads the raider's band and its two neighbors, passes the entries here, and
	shows the `candidates` returned. All live checks (raid lock, loss cap) happen again when the
	raid actually starts.
]]

local Types = require("./Types")
local Config = require("./Config")
local Economy = require("./Economy")
local RaidRules = require("./RaidRules")

type PlayerProfile = Types.PlayerProfile
type DenSnapshot = Types.DenSnapshot
type MatchEntry = Types.MatchEntry
type Trap = Types.Trap
type Critter = Types.Critter

local Matchmaking = {}

-- Defense rating: traps by level, plus a flat value per guard. Tune with the economy agent.
function Matchmaking.defenseRating(traps: { Trap }, guardCount: number): number
	local rating = 0
	for _, trap in traps do
		rating += 10 * trap.level
	end
	return rating + 25 * guardCount
end

-- Den power: income at risk plus defenses. Drives which dens you are matched with.
function Matchmaking.denPower(profile: PlayerProfile): number
	local income = 0
	local guards = 0
	for _, critter in profile.critters do
		if critter.placement == "Pad" then
			income += Economy.critterRate(critter, profile.rebirths)
		elseif critter.placement == "Guard" then
			guards += 1
		end
	end
	return math.floor(income * 60 + Matchmaking.defenseRating(profile.traps, guards))
end

-- Bucket index for a MemoryStore sorted map. Bands double in width, so 0-1, 2-3, 4-7, 8-15...
function Matchmaking.powerBand(power: number): number
	if power < 1 then
		return 0
	end
	return math.floor(math.log(power, 2))
end

-- Builds the raidable snapshot of a den. Vault critters are excluded by design.
-- Accrues the profile first, so it updates `stored` and `storedUpdatedAt` on the profile passed in.
function Matchmaking.buildSnapshot(profile: PlayerProfile, now: number): DenSnapshot
	Economy.accrue(profile, now)
	local critters: { Critter } = {}
	local guards = 0
	for _, critter in profile.critters do
		if critter.placement == "Pad" or critter.placement == "Guard" then
			table.insert(critters, table.clone(critter))
			if critter.placement == "Guard" then
				guards += 1
			end
		end
	end
	table.sort(critters, function(a: Critter, b: Critter): boolean
		return a.uid < b.uid
	end)
	return {
		schemaVersion = Config.SCHEMA_VERSION,
		userId = profile.userId,
		takenAt = now,
		power = Matchmaking.denPower(profile),
		defenseRating = Matchmaking.defenseRating(profile.traps, guards),
		denLevel = profile.denLevel,
		critters = critters,
		traps = table.clone(profile.traps),
		storedGlow = math.floor(profile.stored),
		shieldUntil = profile.shieldUntil,
		protectedUntil = RaidRules.protectedUntil(profile),
	}
end

function Matchmaking.toEntry(snapshot: DenSnapshot, lastActiveAt: number, lastRaidedAt: number): MatchEntry
	return {
		userId = snapshot.userId,
		power = snapshot.power,
		lastActiveAt = lastActiveAt,
		lastRaidedAt = lastRaidedAt,
		shieldUntil = snapshot.shieldUntil,
		protectedUntil = snapshot.protectedUntil,
	}
end

--[[
	Picks up to Config.Matchmaking.candidates targets for `raider` from `pool`.
	Filters: not self, not blocked, within power tolerance, not shielded, not protected, not
	raided recently, owner active recently, pair limit not reached. Sorted closest power first.
	`blocked` holds userIds the raider blocked or is blocked by.
]]
function Matchmaking.pickCandidates(
	raider: PlayerProfile,
	raiderPower: number,
	pool: { MatchEntry },
	blocked: { [number]: boolean },
	now: number
): { MatchEntry }
	-- A percentage window collapses for small dens, so it never gets narrower than minWindow.
	local window = math.max(raiderPower * Config.Matchmaking.powerTolerance, Config.Matchmaking.minWindow)
	local low = raiderPower - window
	local high = raiderPower + window

	local eligible: { MatchEntry } = {}
	for _, entry in pool do
		local ok = entry.userId ~= raider.userId
			and not blocked[entry.userId]
			and entry.power >= low
			and entry.power <= high
			and now >= entry.shieldUntil
			and now >= entry.protectedUntil
			and now - entry.lastRaidedAt >= Config.Matchmaking.recentlyRaidedSeconds
			and now - entry.lastActiveAt <= Config.Matchmaking.activeWithinSeconds
			and RaidRules.pairCount(raider, entry.userId, now) < Config.Limits.maxRaidsPerPairPerDay
		if ok then
			table.insert(eligible, entry)
		end
	end

	table.sort(eligible, function(a: MatchEntry, b: MatchEntry): boolean
		local da = math.abs(a.power - raiderPower)
		local db = math.abs(b.power - raiderPower)
		if da == db then
			return a.userId < b.userId
		end
		return da < db
	end)

	local result: { MatchEntry } = {}
	for i = 1, math.min(Config.Matchmaking.candidates, #eligible) do
		table.insert(result, eligible[i])
	end
	return result
end

return Matchmaking
