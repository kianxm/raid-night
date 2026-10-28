--!strict
local expect = require("../lib/expect")
local fixtures = require("../lib/fixtures")
local RaidRules = require("../../src/Shared/RaidRules")
local Matchmaking = require("../../src/Shared/Matchmaking")
local Profile = require("../../src/Shared/Profile")
local Config = require("../../src/Shared/Config")

local NOW = 1_800_000_000
local Reason = RaidRules.Reason

local function setup()
	local raider = fixtures.veteran(1, NOW)
	local defender = fixtures.veteran(2, NOW)
	fixtures.give(defender, fixtures.critter("pad1", "crescent_fox", "Pad", 1))
	fixtures.give(defender, fixtures.critter("vault1", "storm_hare", "Vault"))
	fixtures.give(defender, fixtures.critter("guard1", "dusk_mouse", "Guard"))
	defender.stored = 1000
	return raider, defender
end

local tests = {}

tests["a normal raid is allowed"] = function()
	local raider, defender = setup()
	local ok, reason = RaidRules.canRaid(raider, Matchmaking.buildSnapshot(defender, NOW), 0, NOW, nil)
	expect.truthy(ok, `refused: {reason}`)
end

tests["you cannot raid yourself"] = function()
	local raider = setup()
	local _, reason = RaidRules.canRaid(raider, Matchmaking.buildSnapshot(raider, NOW), 0, NOW, nil)
	expect.eq(reason, Reason.Self)
end

tests["new players are protected for 48 hours"] = function()
	local raider = setup()
	local newbie = Profile.new(3, NOW - 3600)
	newbie.denLevel = 20
	local _, reason = RaidRules.canRaid(raider, Matchmaking.buildSnapshot(newbie, NOW), 0, NOW, nil)
	expect.eq(reason, Reason.NewPlayerProtection)
end

tests["dens under the minimum level are protected"] = function()
	local raider, defender = setup()
	defender.denLevel = Config.Protection.minDenLevel - 1
	local _, reason = RaidRules.canRaid(raider, Matchmaking.buildSnapshot(defender, NOW), 0, NOW, nil)
	expect.eq(reason, Reason.NewPlayerProtection)
end

tests["shields block raids"] = function()
	local raider, defender = setup()
	defender.shieldUntil = NOW + 60
	local _, reason = RaidRules.canRaid(raider, Matchmaking.buildSnapshot(defender, NOW), 0, NOW, nil)
	expect.eq(reason, Reason.Shielded)
end

tests["revenge ignores a shield once"] = function()
	local raider, defender = setup()
	defender.shieldUntil = NOW + 60
	local snapshot = Matchmaking.buildSnapshot(defender, NOW)
	local token = { raidId = "r1", targetUserId = defender.userId, expiresAt = NOW + 100, shieldBypassUsed = false }
	expect.truthy(RaidRules.canRaid(raider, snapshot, 0, NOW, token), "first revenge bypasses")
	token.shieldBypassUsed = true
	local _, reason = RaidRules.canRaid(raider, snapshot, 0, NOW, token)
	expect.eq(reason, Reason.Shielded, "second time it does not")
end

tests["revenge never breaks new-player protection"] = function()
	local raider = setup()
	local newbie = Profile.new(3, NOW - 3600)
	newbie.denLevel = 20
	local token = { raidId = "r1", targetUserId = 3, expiresAt = NOW + 100, shieldBypassUsed = false }
	local _, reason = RaidRules.canRaid(raider, Matchmaking.buildSnapshot(newbie, NOW), 0, NOW, token)
	expect.eq(reason, Reason.NewPlayerProtection)
end

tests["expired or mismatched revenge tokens are refused"] = function()
	local raider, defender = setup()
	local snapshot = Matchmaking.buildSnapshot(defender, NOW)
	local expired = { raidId = "r1", targetUserId = defender.userId, expiresAt = NOW - 1, shieldBypassUsed = false }
	local _, reason = RaidRules.canRaid(raider, snapshot, 0, NOW, expired)
	expect.eq(reason, Reason.RevengeExpired)
	local wrongTarget = { raidId = "r1", targetUserId = 999, expiresAt = NOW + 100, shieldBypassUsed = false }
	_, reason = RaidRules.canRaid(raider, snapshot, 0, NOW, wrongTarget)
	expect.eq(reason, Reason.RevengeExpired)
end

tests["defenders at the daily loss cap cannot be raided"] = function()
	local raider, defender = setup()
	local snapshot = Matchmaking.buildSnapshot(defender, NOW)
	local _, reason = RaidRules.canRaid(raider, snapshot, Config.Limits.maxLossesPerDay, NOW, nil)
	expect.eq(reason, Reason.DefenderLossCap)
end

tests["the same pair can raid each other at most twice a day"] = function()
	local raider, defender = setup()
	local snapshot = Matchmaking.buildSnapshot(defender, NOW)
	for i = 1, Config.Limits.maxRaidsPerPairPerDay do
		RaidRules.recordOutgoing(raider, `r{i}`, defender.userId, false, nil, 0, false, NOW)
	end
	local _, reason = RaidRules.canRaid(raider, snapshot, 0, NOW, nil)
	expect.eq(reason, Reason.PairLimit)
	-- Next UTC day the limit resets.
	expect.truthy(RaidRules.canRaid(raider, snapshot, 0, NOW + 86400, nil), "resets next day")
end

tests["daily reset clears loss and pair counters"] = function()
	local _, defender = setup()
	defender.lossesToday = 3
	defender.pairRaidsToday["1"] = 2
	RaidRules.resetDailyIfNeeded(defender, NOW + 86400)
	expect.eq(defender.lossesToday, 0)
	expect.eq(defender.pairRaidsToday["1"], nil)
end

tests["snapshots never include vault critters"] = function()
	local _, defender = setup()
	local snapshot = Matchmaking.buildSnapshot(defender, NOW)
	for _, critter in snapshot.critters do
		expect.truthy(critter.placement ~= "Vault", "vault critter leaked into snapshot")
	end
	expect.eq(#snapshot.critters, 2, "pad + guard")
end

tests["only pad critters can be grabbed"] = function()
	local _, defender = setup()
	local snapshot = Matchmaking.buildSnapshot(defender, NOW)
	expect.truthy(RaidRules.validateGrab(snapshot, "pad1"))
	local _, reasonGuard = RaidRules.validateGrab(snapshot, "guard1")
	expect.eq(reasonGuard, Reason.NotStealable)
	local _, reasonVault = RaidRules.validateGrab(snapshot, "vault1")
	expect.eq(reasonVault, Reason.NotInSnapshot)
end

tests["loot is 25% of stored Glow, 27.5% on revenge"] = function()
	local _, defender = setup()
	local snapshot = Matchmaking.buildSnapshot(defender, NOW)
	expect.eq(RaidRules.lootGlow(snapshot, false), 250)
	expect.eq(RaidRules.lootGlow(snapshot, true), 275)
end

tests["heavier critters slow the carrier more"] = function()
	expect.truthy(RaidRules.carrySpeedMultiplier("Light") > RaidRules.carrySpeedMultiplier("VeryHeavy"))
end

tests["purchased shields cap at 24 hours from now"] = function()
	local _, defender = setup()
	for _ = 1, 10 do
		RaidRules.applyPurchasedShield(defender, NOW)
	end
	expect.eq(defender.shieldUntil, NOW + Config.Shield.maxStackSeconds)
end

tests["raid log keeps the newest entries up to the cap"] = function()
	local raider, defender = setup()
	for i = 1, Config.RaidLog.maxEntries + 5 do
		RaidRules.recordOutgoing(raider, `r{i}`, defender.userId, true, nil, i, false, NOW + i)
	end
	expect.eq(#raider.raidLog, Config.RaidLog.maxEntries)
	expect.eq(raider.raidLog[1].raidId, `r{Config.RaidLog.maxEntries + 5}`, "newest first")
end

tests["matchmaking offers the closest eligible dens only"] = function()
	local raider = setup()
	local pool = {}
	local function entry(userId: number, power: number, overrides: { [string]: any }?)
		local e: any = {
			userId = userId,
			power = power,
			lastActiveAt = NOW - 60,
			lastRaidedAt = 0,
			shieldUntil = 0,
			protectedUntil = 0,
		}
		for k, v in overrides or {} do
			e[k] = v
		end
		table.insert(pool, e)
	end
	entry(10, 1000)
	entry(11, 1050)
	entry(12, 980)
	entry(13, 1100)
	entry(14, 2000) -- too strong
	entry(15, 1001, { shieldUntil = NOW + 10 })
	entry(16, 1002, { lastRaidedAt = NOW - 60 }) -- raided recently
	entry(17, 1003, { lastActiveAt = NOW - 30 * 86400 }) -- inactive
	entry(18, 1004, { protectedUntil = NOW + 10 })
	entry(19, 1005)
	entry(1, 1000) -- the raider themself

	local picks = Matchmaking.pickCandidates(raider, 1000, pool, { [19] = true }, NOW)
	expect.eq(#picks, Config.Matchmaking.candidates)
	expect.eq(picks[1].userId, 10, "closest first")
	expect.eq(picks[2].userId, 12)
	expect.eq(picks[3].userId, 11)
end

tests["small dens still find targets thanks to the minimum window"] = function()
	local raider = setup()
	local pool = {
		{ userId = 10, power = 40, lastActiveAt = NOW, lastRaidedAt = 0, shieldUntil = 0, protectedUntil = 0 },
	}
	expect.eq(#Matchmaking.pickCandidates(raider, 5, pool, {}, NOW), 1)
end

return tests
