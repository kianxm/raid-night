--!strict
local expect = require("../lib/expect")
local fixtures = require("../lib/fixtures")
local source = require("../lib/source")
local Profile = require("../../src/Shared/Profile")
local Config = require("../../src/Shared/Config")
local Escrow = require("../../src/Shared/Escrow")
local RaidRules = require("../../src/Shared/RaidRules")

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

tests["prepare stamps only a true template: someone else's save with createdAt 0 is refused"] = function()
	local saved: any = Profile.new(7, 0) -- a real save (userId 7) that happens to have createdAt 0
	expect.throws(function()
		Profile.prepare(saved, 42, NOW)
	end, "never re-stamped as player 42's")
	expect.eq(saved.userId, 7, "the ownership check ran before anything rewrote the owner")
	local own = Profile.prepare(Profile.new(42, 0), 42, NOW)
	expect.eq(own.createdAt, 0, "a player's own save is not treated as brand new")
end

tests["prepare refuses a save from a newer game version"] = function()
	local saved: any = Profile.new(42, NOW)
	saved.schemaVersion = Config.SCHEMA_VERSION + 1
	expect.throws(function()
		Profile.prepare(saved, 42, NOW)
	end)
end

tests["prepare rolls the day and prunes expired tokens, but never escrow entries"] = function()
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
	-- Only EscrowService prunes appliedTransfers, after reading the open-escrow index.
	expect.truthy(p.appliedTransfers.old, "old entry kept: its raid may still be open")
	expect.truthy(p.appliedTransfers.recent, "idempotency entry inside the window kept")
end

-- Live loss fields (decision D-031) --------------------------------------------------------------

tests["a save from before the live loss fields loads unprotected, with no migration"] = function()
	local saved: any = Profile.new(42, NOW - 1000)
	saved.liveLossBaseRate, saved.liveLossRateToday = nil, nil -- never written by older servers
	local p = Profile.prepare(saved, 42, NOW)
	expect.eq(p.schemaVersion, Config.SCHEMA_VERSION)
	expect.eq(Config.SCHEMA_VERSION, 1, "an optional field needs no SCHEMA_VERSION bump")
	expect.eq(p.liveLossBaseRate, nil, "fields stay absent")
	expect.eq(p.liveLossRateToday, nil)
	expect.falsy(RaidRules.liveProtected(p, NOW))
end

tests["prepare clears yesterday's live loss fields and keeps today's"] = function()
	local saved: any = Profile.new(42, NOW - 3 * 86400)
	saved.lossDay = RaidRules.dayIndex(NOW) - 1
	saved.liveLossBaseRate, saved.liveLossRateToday = 100, 60
	local p = Profile.prepare(saved, 42, NOW)
	expect.eq(p.liveLossBaseRate, nil, "a new day")
	expect.eq(p.liveLossRateToday, nil)
	local today: any = Profile.new(42, NOW - 3 * 86400)
	today.lossDay = RaidRules.dayIndex(NOW)
	today.liveLossBaseRate, today.liveLossRateToday = 100, 60
	local kept = Profile.prepare(today, 42, NOW)
	expect.eq(kept.liveLossBaseRate, 100, "a rejoin the same day keeps its protection")
	expect.truthy(RaidRules.liveProtected(kept, NOW))
end

-- Critter.untradeable (decision D-005) ---------------------------------------------------------

tests["a critter saved before untradeable existed loads as tradeable, with no migration"] = function()
	local saved: any = Profile.new(42, NOW - 1000)
	saved.critters.old =
		{ uid = "old", speciesId = "crescent_fox", mutation = "None", placement = "Inventory", acquiredAt = 0 }
	local p = Profile.prepare(saved, 42, NOW)
	expect.eq(p.schemaVersion, Config.SCHEMA_VERSION)
	expect.eq(p.critters.old.untradeable, nil, "field stays absent")
	expect.truthy(Profile.isTradeable(p.critters.old, NOW))
end

tests["a stolen critter is tradeable only once its stolen lock ends"] = function()
	local critter = fixtures.critter("c", "crescent_fox", "Inventory")
	critter.stolenLockUntil = NOW + 60
	expect.falsy(Profile.isTradeable(critter, NOW))
	expect.truthy(Profile.isTradeable(critter, NOW + 60))
end

tests["an untradeable critter is never tradeable, whatever the time"] = function()
	local critter = fixtures.critter("c", "crescent_fox", "Inventory")
	critter.untradeable = true
	expect.falsy(Profile.isTradeable(critter, NOW))
	expect.falsy(Profile.isTradeable(critter, NOW + 10 * 365 * 86400))
	critter.stolenLockUntil = NOW - 1
	expect.falsy(Profile.isTradeable(critter, NOW), "an expired stolen lock does not lift it")
end

-- DataStore-like: every load is a copy and nothing persists until saved.
local function memoryStore(profiles: { [number]: any }, records: { [string]: any }): Escrow.Store
	local function copy(value: any): any
		if type(value) ~= "table" then
			return value
		end
		local out = {}
		for k, v in value do
			out[k] = copy(v)
		end
		return out
	end
	return {
		loadRecord = function(raidId)
			return copy(records[raidId])
		end,
		saveRecord = function(record)
			records[record.raidId] = copy(record)
		end,
		loadProfile = function(userId)
			return copy(profiles[userId])
		end,
		saveProfile = function(profile)
			profiles[profile.userId] = copy(profile)
		end,
	}
end

tests["the untradeable flag survives an escrow transfer"] = function()
	local raider = fixtures.veteran(1, NOW)
	local defender = fixtures.veteran(2, NOW)
	local rescued = fixtures.give(defender, fixtures.critter("rescued", "crescent_fox", "Pad", 1))
	rescued.untradeable = true
	local profiles = { [1] = raider, [2] = defender }
	local records = { ["raid-1"] = Escrow.create("raid-1", 1, 2, "rescued", 0, false, NOW, "Live") }

	local record = Escrow.advance("raid-1", memoryStore(profiles, records), NOW)

	expect.eq(record and record.state, "Committed")
	expect.eq(profiles[2].critters.rescued, nil, "the defender no longer has it")
	local stolen = profiles[1].critters.rescued
	expect.truthy(stolen, "the raider has it")
	expect.eq(stolen.untradeable, true, "the raider's saved copy keeps the flag")
	local escrowed = records["raid-1"].critter :: any
	expect.eq(escrowed and escrowed.untradeable, true, "so does the escrow record")
	local afterLock = NOW + Config.Raid.stolenTradeLockSeconds + 1
	expect.falsy(Profile.isTradeable(stolen, afterLock), "still untradeable after the stolen lock")
end

tests["markRaidLogSeen moves forward only and ignores non-finite times"] = function()
	local p: any = Profile.new(7, NOW)
	expect.eq(p.raidLogSeenAt, nil, "a new profile has never seen its log")
	expect.truthy(Profile.markRaidLogSeen(p, NOW), "first open writes")
	expect.eq(p.raidLogSeenAt, NOW)
	expect.truthy(Profile.markRaidLogSeen(p, NOW), "the same time again is a harmless repeat")
	expect.falsy(Profile.markRaidLogSeen(p, NOW - 1), "an earlier time is ignored")
	for _, bad in { 0 / 0, math.huge, -math.huge, "1900000000" :: any } do
		expect.falsy(Profile.markRaidLogSeen(p, bad), `{bad} is ignored`)
	end
	expect.falsy(Profile.markRaidLogSeen(p, nil :: any), "nil is ignored")
	expect.eq(p.raidLogSeenAt, NOW, "nothing above moved it")
	expect.truthy(Profile.markRaidLogSeen(p, NOW + 60), "a later open writes")
	expect.eq(RaidRules.raidLogSeenAt(p), NOW + 60)

	local never: any = Profile.new(8, NOW)
	expect.falsy(Profile.markRaidLogSeen(never, -1), "earlier than never (0) is ignored")
	expect.eq(never.raidLogSeenAt, nil)
	for _, corrupt in { 0 / 0, math.huge } do
		never.raidLogSeenAt = corrupt
		expect.truthy(Profile.markRaidLogSeen(never, NOW), `a stored {corrupt} counts as never and is replaced`)
		expect.eq(never.raidLogSeenAt, NOW)
	end
end

tests["DataService.markRaidLogSeen writes only a loaded profile, through the pure rule"] = function()
	local code = source.codeOnly(source.read("src/Server/Services/DataService.luau"))
	local body = source.functionBody(code, "DataService.markRaidLogSeen")
	expect.truthy(body, "markRaidLogSeen found")
	expect.truthy(
		string.find(
			body :: string,
			"^function DataService%.markRaidLogSeen%(userId: number, now: number%): boolean\n"
				.. "%s*local profile = DataService%.getProfile%(userId%)"
				.. "%s*if profile == nil then%s*return false%s*end"
				.. "%s*return Profile%.markRaidLogSeen%(profile, now%)%s*end\n$"
		),
		"loaded profiles only, then the pure forward-only rule, and nothing else (no yield, no attribute)"
	)
	expect.eq(select(2, string.gsub(code, "raidLogSeenAt%s*=", "")), 0, "DataService never assigns the field itself")
end

return tests
