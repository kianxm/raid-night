--!strict
--[[
	Matchmaking: pure target selection for the Raid Portal.

	The server keeps one MemoryStore sorted map per power band (see `powerBand`). To offer
	targets, it reads every band the raider's power window touches (`bandsToRead`), decodes the
	entries (`decodeEntry`), and shows what `selectTargets` returns: revenge targets first, then
	`pickCandidates`. All live checks (raid lock, loss cap) happen again when the raid starts.
]]

local Types = require("./Types")
local Config = require("./Config")
local Economy = require("./Economy")
local RaidRules = require("./RaidRules")
local CritterCatalog = require("./CritterCatalog")

type PlayerProfile = Types.PlayerProfile
type DenSnapshot = Types.DenSnapshot
type MatchEntry = Types.MatchEntry
type Trap = Types.Trap
type Critter = Types.Critter
type Tier = Types.Tier
type RevengeToken = Types.RevengeToken

-- One row of the Raid Portal before names are looked up. `power` is nil on revenge rows (the
-- target may sit in any band); the server fills it from the target's snapshot.
export type Target = { userId: number, isRevenge: boolean, revengeRaidId: string?, power: number? }

-- [MemoryStore, not persisted] A raid lock on one defender. `released` marks a lock given back.
export type RaidLock = { raiderUserId: number, raidId: string, released: boolean? }

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

-- How far from the raider's power a target may be. A percentage window collapses for small dens,
-- so it never gets narrower than minWindow.
local function powerWindow(power: number): number
	return math.max(power * Config.Matchmaking.powerTolerance, Config.Matchmaking.minWindow)
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
	-- P2.8: accrues at factor 1. The Glow-multiplier helper must pass the owner's boost factor here
	-- before Config.Flags.purchases turns on (contracts.md, P2.8 gate).
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
	local window = powerWindow(raiderPower)
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

-- Every band the raider's power window touches, lowest first: usually the band and a neighbor,
-- more for small dens (minWindow is wide next to their power).
function Matchmaking.bandsToRead(power: number): { number }
	local window = powerWindow(power)
	local bands = {}
	for band = Matchmaking.powerBand(math.max(0, power - window)), Matchmaking.powerBand(power + window) do
		table.insert(bands, band)
	end
	return bands
end

-- When the owner was last robbed (newest Incoming log entry that escaped), or 0.
function Matchmaking.lastRaidedAt(profile: PlayerProfile): number
	local latest = 0
	for _, entry in profile.raidLog do
		if entry.direction == "Incoming" and entry.escaped and entry.at > latest then
			latest = entry.at
		end
	end
	return latest
end

-- Highest tier on the den's pads: the Raid Portal's loot hint (never exact Glow). nil = none.
function Matchmaking.topTier(snapshot: DenSnapshot): Tier?
	local best: Tier? = nil
	for _, critter in snapshot.critters do
		local species = CritterCatalog.get(critter.speciesId)
		if
			critter.placement == "Pad"
			and species
			and (best == nil or CritterCatalog.tierRank(species.tier) > CritterCatalog.tierRank(best))
		then
			best = species.tier
		end
	end
	return best
end

-- Did the owner of `snapshot` block `userId`? Snapshots saved before block lists existed block nobody.
function Matchmaking.snapshotBlocks(snapshot: DenSnapshot, userId: number): boolean
	return snapshot.blockedUserIds ~= nil and table.find(snapshot.blockedUserIds, userId) ~= nil
end

local function isWhole(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) < 2 ^ 53 and value % 1 == 0
end

local function isFinite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) ~= math.huge
end

-- A client's block list (untrusted): distinct positive whole userIds, sorted. nil if it is not a
-- list of them or holds more than Config.Matchmaking.maxBlockedUserIds.
function Matchmaking.cleanBlockList(payload: any): { number }?
	if type(payload) ~= "table" then
		return nil
	end
	local seen: { [number]: boolean } = {}
	local list: { number } = {}
	local count = 0
	for _, value in payload do
		count += 1
		if count > Config.Matchmaking.maxBlockedUserIds or not isWhole(value) or value <= 0 then
			return nil
		end
		if not seen[value] then
			seen[value] = true
			table.insert(list, value)
		end
	end
	table.sort(list)
	return list
end

-- Pool values are compact arrays, because MemoryStore memory is the scarce budget:
-- { power, lastActiveAt, lastRaidedAt, shieldUntil, protectedUntil }. The key is the userId.
function Matchmaking.encodeEntry(entry: MatchEntry): { number }
	return { entry.power, entry.lastActiveAt, entry.lastRaidedAt, entry.shieldUntil, entry.protectedUntil }
end

-- Reads a pool item back. nil for anything malformed (an older server, a bad write).
function Matchmaking.decodeEntry(key: any, value: any): MatchEntry?
	local userId = tonumber(key)
	if not isWhole(userId) or type(value) ~= "table" then
		return nil
	end
	for i = 1, 5 do
		if not isFinite(value[i]) then
			return nil
		end
	end
	return {
		userId = userId :: number,
		power = value[1],
		lastActiveAt = value[2],
		lastRaidedAt = value[3],
		shieldUntil = value[4],
		protectedUntil = value[5],
	}
end

--[[
	The raider's revenge targets, one row per target, soonest-expiring first, at most
	Config.Matchmaking.maxRevengeTargets. Power band never matters. Skips self, blocked, expired
	tokens and pairs at the daily limit (revenge counts toward it). For each target it picks the
	token that can still bypass a shield, then the one expiring soonest.
]]
function Matchmaking.revengeTargets(
	raider: PlayerProfile,
	blocked: { [number]: boolean },
	now: number
): { RevengeToken }
	local best: { [number]: RevengeToken } = {}
	for _, token in raider.revengeTokens do
		local target = token.targetUserId
		local ok = target ~= raider.userId
			and not blocked[target]
			and now < token.expiresAt
			and RaidRules.pairCount(raider, target, now) < Config.Limits.maxRaidsPerPairPerDay
		local current = best[target]
		if ok and current then
			if token.shieldBypassUsed ~= current.shieldBypassUsed then
				ok = not token.shieldBypassUsed
			elseif token.expiresAt ~= current.expiresAt then
				ok = token.expiresAt < current.expiresAt
			else
				ok = token.raidId < current.raidId
			end
		end
		if ok then
			best[target] = token
		end
	end
	local list: { RevengeToken } = {}
	for _, token in best do
		table.insert(list, token)
	end
	table.sort(list, function(a: RevengeToken, b: RevengeToken): boolean
		if a.expiresAt == b.expiresAt then
			return a.targetUserId < b.targetUserId
		end
		return a.expiresAt < b.expiresAt
	end)
	while #list > Config.Matchmaking.maxRevengeTargets do
		table.remove(list)
	end
	return list
end

-- The Raid Portal rows: revenge targets first, then pickCandidates (never repeating a revenge
-- target). `blocked` holds userIds the raider blocked or is blocked by.
function Matchmaking.selectTargets(
	raider: PlayerProfile,
	raiderPower: number,
	pool: { MatchEntry },
	blocked: { [number]: boolean },
	now: number
): { Target }
	local result: { Target } = {}
	local skip = table.clone(blocked)
	for _, token in Matchmaking.revengeTargets(raider, blocked, now) do
		table.insert(result, { userId = token.targetUserId, isRevenge = true, revengeRaidId = token.raidId })
		skip[token.targetUserId] = true
	end
	for _, entry in Matchmaking.pickCandidates(raider, raiderPower, pool, skip, now) do
		table.insert(result, { userId = entry.userId, isRevenge = false, power = entry.power })
	end
	return result
end

-- Raid locks: what UpdateAsync writes. `current` is the stored value (untrusted shape).
-- Acquire: free (nothing, or released) or already ours for this raid -> our lock; else nil (refuse).
function Matchmaking.lockAfterAcquire(current: any, raiderUserId: number, raidId: string): RaidLock?
	local free = current == nil or (type(current) == "table" and current.released == true)
	local ours = type(current) == "table" and current.raiderUserId == raiderUserId and current.raidId == raidId
	if free or ours then
		return { raiderUserId = raiderUserId, raidId = raidId }
	end
	return nil
end

-- Release: only the lock this raid holds becomes `released`; anyone else's stays (nil = no write).
function Matchmaking.lockAfterRelease(current: any, raidId: string): RaidLock?
	if type(current) == "table" and current.raidId == raidId and current.released ~= true then
		return { raiderUserId = current.raiderUserId, raidId = raidId, released = true }
	end
	return nil
end

return Matchmaking
