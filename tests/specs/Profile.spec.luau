--!strict
local expect = require("../lib/expect")
local Profile = require("../../src/Shared/Profile")
local Config = require("../../src/Shared/Config")

local NOW = 1_800_000_000

local tests = {}

tests["a new profile starts at the current schema with safe defaults"] = function()
	local p = Profile.new(42, NOW)
	expect.eq(p.schemaVersion, Config.SCHEMA_VERSION)
	expect.eq(p.userId, 42)
	expect.eq(p.glow, 0)
	expect.eq(p.stored, 0)
	expect.eq(p.denLevel, 1)
	expect.eq(p.vaultSlots, 1)
	expect.eq(next(p.critters), nil, "no critters")
end

tests["migrating a current profile changes nothing"] = function()
	local p = Profile.new(1, NOW)
	local migrated = Profile.migrate(p)
	expect.eq(migrated.schemaVersion, Config.SCHEMA_VERSION)
end

tests["a save from a newer game version is refused, never downgraded"] = function()
	local p: any = Profile.new(1, NOW)
	p.schemaVersion = Config.SCHEMA_VERSION + 1
	expect.throws(function()
		Profile.migrate(p)
	end)
end

-- What ProfileStore hands DataService for a key that was never saved: a copy of the template.
local function templateCopy(): any
	return Profile.new(0, 0)
end

tests["prepare stamps a brand-new save with the player and the load time"] = function()
	local p = Profile.prepare(templateCopy(), 42, NOW)
	expect.eq(p.userId, 42)
	expect.eq(p.createdAt, NOW, "new-player protection starts now, not in 1970")
	expect.eq(p.storedUpdatedAt, NOW, "no income accrued since 1970")
	expect.eq(p.lossDay, math.floor(NOW / 86400))
end

tests["prepare keeps a returning player's history"] = function()
	local saved: any = Profile.new(42, NOW - 1000)
	saved.glow = 500
	local p = Profile.prepare(saved, 42, NOW)
	expect.eq(p.createdAt, NOW - 1000)
	expect.eq(p.storedUpdatedAt, NOW - 1000, "offline time still accrues")
	expect.eq(p.glow, 500)
end

tests["prepare refuses a save that belongs to someone else"] = function()
	expect.throws(function()
		Profile.prepare(Profile.new(7, NOW), 42, NOW)
	end)
end

tests["prepare refuses a save from a newer game version"] = function()
	local saved: any = Profile.new(42, NOW)
	saved.schemaVersion = Config.SCHEMA_VERSION + 1
	expect.throws(function()
		Profile.prepare(saved, 42, NOW)
	end)
end

tests["prepare rolls the day and prunes expired tokens and transfers"] = function()
	local saved: any = Profile.new(42, NOW - 3 * 86400)
	saved.lossesToday = 3
	saved.pairRaidsToday["7"] = 2
	saved.revengeTokens.old = { raidId = "old", targetUserId = 7, expiresAt = NOW - 1, shieldBypassUsed = false }
	saved.revengeTokens.live = { raidId = "live", targetUserId = 7, expiresAt = NOW + 60, shieldBypassUsed = false }
	local retention = Config.Escrow.appliedTransferRetentionSeconds
	saved.appliedTransfers.old = { role = "Debit", at = NOW - retention - 1, glow = 1 }
	saved.appliedTransfers.recent = { role = "Credit", at = NOW - 60, glow = 1 }

	local p = Profile.prepare(saved, 42, NOW)
	expect.eq(p.lossesToday, 0)
	expect.eq(next(p.pairRaidsToday), nil)
	expect.eq(p.revengeTokens.old, nil)
	expect.truthy(p.revengeTokens.live, "unexpired token kept")
	expect.eq(p.appliedTransfers.old, nil)
	expect.truthy(p.appliedTransfers.recent, "idempotency entry inside the window kept")
end

return tests
