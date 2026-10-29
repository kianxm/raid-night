--!strict
-- P1.2: target selection, pool encoding, raid locks and block lists (Matchmaking.luau).
local expect = require("../lib/expect")
local fixtures = require("../lib/fixtures")
local Matchmaking = require("../../src/Shared/Matchmaking")
local Config = require("../../src/Shared/Config")
local CritterCatalog = require("../../src/Shared/CritterCatalog")
local Types = require("../../src/Shared/Types")

local NOW = 1_800_000_000
local HOUR = 3600

local function entry(userId: number, power: number): Types.MatchEntry
	return {
		userId = userId,
		power = power,
		lastActiveAt = NOW,
		lastRaidedAt = 0,
		shieldUntil = 0,
		protectedUntil = 0,
	}
end

local function token(raidId: string, target: number, expiresAt: number, used: boolean?): Types.RevengeToken
	return { raidId = raidId, targetUserId = target, expiresAt = expiresAt, shieldBypassUsed = used == true }
end

local function speciesOf(tier: Types.Tier): string
	return CritterCatalog.byTier(tier)[1].id
end

local tests = {}

tests["revenge targets come first regardless of power band"] = function()
	local raider = fixtures.veteran(1, NOW)
	raider.revengeTokens.r1 = token("r1", 50, NOW + HOUR)
	local pool = { entry(10, 1000), entry(50, 1000), entry(11, 1010) }
	local rows = Matchmaking.selectTargets(raider, 1000, pool, {}, NOW)
	expect.eq(rows[1].userId, 50, "revenge first")
	expect.truthy(rows[1].isRevenge)
	expect.eq(rows[1].revengeRaidId, "r1")
	expect.eq(rows[1].power, nil, "revenge power comes from the snapshot")
	expect.eq(#rows, 3, "the revenge target is not repeated as a candidate")
	expect.eq(rows[2].userId, 10)
	expect.falsy(rows[2].isRevenge)

	-- A revenge target far outside the window (and absent from the pool) is still offered.
	raider.revengeTokens.r2 = token("r2", 99, NOW + 2 * HOUR)
	rows = Matchmaking.selectTargets(raider, 1000, {}, {}, NOW)
	expect.eq(#rows, 2)
	expect.eq(rows[1].userId, 50, "soonest-expiring first")
	expect.eq(rows[2].userId, 99)
end

tests["revenge skips expired, self, blocked and pairs at the daily limit"] = function()
	local raider = fixtures.veteran(1, NOW)
	raider.revengeTokens.a = token("a", 20, NOW) -- expired exactly now
	raider.revengeTokens.b = token("b", 1, NOW + HOUR) -- self
	raider.revengeTokens.c = token("c", 21, NOW + HOUR) -- blocked
	raider.revengeTokens.d = token("d", 22, NOW + HOUR) -- pair limit
	raider.revengeTokens.e = token("e", 23, NOW + HOUR) -- fine
	raider.pairRaidsToday["22"] = Config.Limits.maxRaidsPerPairPerDay
	local rows = Matchmaking.revengeTargets(raider, { [21] = true }, NOW)
	expect.eq(#rows, 1)
	expect.eq(rows[1].targetUserId, 23)
end

tests["one revenge row per target, preferring a token that can still bypass a shield"] = function()
	local raider = fixtures.veteran(1, NOW)
	raider.revengeTokens.used = token("used", 30, NOW + HOUR, true)
	raider.revengeTokens.fresh = token("fresh", 30, NOW + 5 * HOUR)
	raider.revengeTokens.later = token("later", 30, NOW + 9 * HOUR)
	local rows = Matchmaking.revengeTargets(raider, {}, NOW)
	expect.eq(#rows, 1)
	expect.eq(rows[1].raidId, "fresh")
end

tests["revenge rows are capped"] = function()
	local raider = fixtures.veteran(1, NOW)
	for i = 1, Config.Matchmaking.maxRevengeTargets + 3 do
		raider.revengeTokens[`r{i}`] = token(`r{i}`, 100 + i, NOW + i)
	end
	local rows = Matchmaking.revengeTargets(raider, {}, NOW)
	expect.eq(#rows, Config.Matchmaking.maxRevengeTargets)
	expect.eq(rows[1].targetUserId, 101, "soonest kept")
end

tests["blocked users are excluded from candidates (the caller merges both directions)"] = function()
	local raider = fixtures.veteran(1, NOW)
	local rows = Matchmaking.selectTargets(raider, 1000, { entry(10, 1000), entry(11, 1000) }, { [10] = true }, NOW)
	expect.eq(#rows, 1)
	expect.eq(rows[1].userId, 11)
end

tests["snapshotBlocks reads the owner's block list; old snapshots block nobody"] = function()
	local owner = fixtures.veteran(5, NOW)
	local snapshot = Matchmaking.buildSnapshot(owner, NOW)
	expect.falsy(Matchmaking.snapshotBlocks(snapshot, 1), "no list saved")
	snapshot.blockedUserIds = { 1, 7 }
	expect.truthy(Matchmaking.snapshotBlocks(snapshot, 7))
	expect.falsy(Matchmaking.snapshotBlocks(snapshot, 8))
end

tests["bandsToRead covers the whole power window"] = function()
	for _, power in { 0, 5, 60, 300, 1000, 5000, 123456 } do
		local bands = Matchmaking.bandsToRead(power)
		local window = math.max(power * Config.Matchmaking.powerTolerance, Config.Matchmaking.minWindow)
		for _, edge in { math.max(0, power - window), power, power + window } do
			expect.truthy(table.find(bands, Matchmaking.powerBand(edge)) ~= nil, `power {power} edge {edge}`)
		end
		for i = 2, #bands do
			expect.eq(bands[i], bands[i - 1] + 1, "contiguous")
		end
	end
	expect.truthy(#Matchmaking.bandsToRead(5000) <= 2, "large dens read one or two bands")
end

tests["pool entries round-trip and malformed ones are refused"] = function()
	local e = entry(42, 1234)
	e.lastRaidedAt = NOW - 99
	e.shieldUntil = NOW + 5
	local back = Matchmaking.decodeEntry("42", Matchmaking.encodeEntry(e))
	expect.truthy(back)
	local got = back :: Types.MatchEntry
	expect.eq(got.userId, 42)
	expect.eq(got.power, 1234)
	expect.eq(got.lastRaidedAt, NOW - 99)
	expect.eq(got.shieldUntil, NOW + 5)
	expect.eq(Matchmaking.decodeEntry("x", Matchmaking.encodeEntry(e)), nil, "bad key")
	expect.eq(Matchmaking.decodeEntry("4.5", Matchmaking.encodeEntry(e)), nil, "fractional key")
	expect.eq(Matchmaking.decodeEntry("42", { 1, 2, 3 }), nil, "short")
	expect.eq(Matchmaking.decodeEntry("42", { 0 / 0, 1, 2, 3, 4 }), nil, "NaN")
	expect.eq(Matchmaking.decodeEntry("42", { math.huge, 1, 2, 3, 4 }), nil, "inf")
	expect.eq(Matchmaking.decodeEntry("42", "nope"), nil, "not a table")
end

tests["raid lock: one raider per defender, retries are idempotent, release only by the holder"] = function()
	local lock = Matchmaking.lockAfterAcquire(nil, 1, "raidA")
	expect.truthy(lock, "free lock taken")
	expect.eq(Matchmaking.lockAfterAcquire(lock, 2, "raidB"), nil, "another raider refused")
	expect.eq(Matchmaking.lockAfterAcquire(lock, 1, "raidOther"), nil, "same raider, other raid refused")
	expect.truthy(Matchmaking.lockAfterAcquire(lock, 1, "raidA"), "retry of the same raid keeps it")
	expect.eq(Matchmaking.lockAfterAcquire("garbage", 2, "raidB"), nil, "unreadable lock fails closed")

	expect.eq(Matchmaking.lockAfterRelease(lock, "raidB"), nil, "someone else's raid cannot release it")
	local released = Matchmaking.lockAfterRelease(lock, "raidA")
	expect.truthy(released and released.released, "holder releases")
	expect.eq(Matchmaking.lockAfterRelease(released, "raidA"), nil, "release is a no-op twice")
	expect.truthy(Matchmaking.lockAfterAcquire(released, 2, "raidB"), "a released lock is free")
end

tests["cleanBlockList accepts only distinct positive whole userIds within the cap"] = function()
	local list = Matchmaking.cleanBlockList({ 5, 3, 5, 9 }) :: { number }
	expect.eq(#list, 3)
	expect.eq(list[1], 3)
	expect.eq(list[3], 9)
	expect.eq(#(Matchmaking.cleanBlockList({}) :: { number }), 0, "empty list is a valid report")
	expect.eq(Matchmaking.cleanBlockList("1,2"), nil)
	expect.eq(Matchmaking.cleanBlockList({ 1, -1_000_001 }), nil, "test or negative ids refused")
	expect.eq(Matchmaking.cleanBlockList({ 1.5 }), nil)
	expect.eq(Matchmaking.cleanBlockList({ 0 / 0 }), nil)
	expect.eq(Matchmaking.cleanBlockList({ "7" }), nil)
	local long = {}
	for i = 1, Config.Matchmaking.maxBlockedUserIds + 1 do
		long[i] = i
	end
	expect.eq(Matchmaking.cleanBlockList(long), nil, "over the cap")
end

tests["snapshot never includes vault critters and topTier reads pads only"] = function()
	local owner = fixtures.veteran(5, NOW)
	fixtures.give(owner, fixtures.critter("p1", speciesOf("Common"), "Pad", 1))
	fixtures.give(owner, fixtures.critter("p2", speciesOf("Rare"), "Pad", 2))
	fixtures.give(owner, fixtures.critter("v1", speciesOf("Legendary"), "Vault"))
	fixtures.give(owner, fixtures.critter("g1", speciesOf("Epic"), "Guard"))
	local snapshot = Matchmaking.buildSnapshot(owner, NOW)
	for _, c in snapshot.critters do
		expect.truthy(c.placement ~= "Vault", "no vault critter")
	end
	expect.eq(Matchmaking.topTier(snapshot), "Rare", "guards and vault are not loot")
	expect.eq(Matchmaking.topTier(Matchmaking.buildSnapshot(fixtures.veteran(6, NOW), NOW)), nil)
end

tests["lastRaidedAt is the newest escaped incoming raid"] = function()
	local owner = fixtures.veteran(5, NOW)
	expect.eq(Matchmaking.lastRaidedAt(owner), 0)
	local function log(direction: Types.RaidDirection, escaped: boolean, at: number)
		table.insert(owner.raidLog, {
			raidId = tostring(at),
			direction = direction,
			otherUserId = 9,
			escaped = escaped,
			glow = 0,
			at = at,
			isRevenge = false,
		})
	end
	log("Incoming", true, NOW - 500)
	log("Incoming", false, NOW - 10) -- held: not robbed
	log("Outgoing", true, NOW - 5)
	expect.eq(Matchmaking.lastRaidedAt(owner), NOW - 500)
end

return tests
