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
				-- P2.9: raid_log_opened (AnalyticsService.track never yields), read before the mark.
				.. '%s*AnalyticsService%.track%(userId, "raid_log_opened", {'
				.. "%s*entriesSinceLastVisit = Analytics%.entriesSince%(profile%.raidLog, profile%.raidLogSeenAt%),"
				.. "%s*}%)"
				.. "%s*return Profile%.markRaidLogSeen%(profile, now%)%s*end\n$"
		),
		"loaded profiles only, its analytics event, then the pure forward-only rule, and nothing else"
	)
	expect.eq(select(2, string.gsub(code, "raidLogSeenAt%s*=", "")), 0, "DataService never assigns the field itself")
end

-- Phase 2 fields (decision D-059) ------------------------------------------------------------------

local PHASE2_FIELDS = { "settings", "onboarding", "successfulRaids", "gear", "receipts", "eventPasses", "accessories" }

-- A save written before Phase 2: today's Profile.new without any Phase 2 field.
local function prePhase2Save(userId: number, createdAt: number): any
	local saved: any = Profile.new(userId, createdAt)
	for _, field in PHASE2_FIELDS do
		saved[field] = nil
	end
	return saved
end

tests["a save from before Phase 2 loads unchanged, with no migration, and reads every default"] = function()
	local p: any = Profile.prepare(prePhase2Save(42, NOW - 5 * 86400), 42, NOW)
	expect.eq(Config.SCHEMA_VERSION, 1, "optional fields need no SCHEMA_VERSION bump")
	expect.eq(p.schemaVersion, Config.SCHEMA_VERSION)
	for _, field in PHASE2_FIELDS do
		expect.eq(p[field], nil, `{field} stays absent until first written`)
	end
	local settings = Profile.settingsOf(p)
	expect.eq(settings.musicVolume, Profile.SETTINGS_DEFAULTS.musicVolume)
	expect.eq(settings.sfxVolume, Profile.SETTINGS_DEFAULTS.sfxVolume)
	expect.eq(settings.reducedMotion, Profile.SETTINGS_DEFAULTS.reducedMotion)
	expect.truthy(Profile.isOnboardingComplete(p), "an existing player is never sent through onboarding")
	expect.eq(Profile.onboardingStep(p), Profile.ONBOARDING_LAST_STEP)
	expect.falsy(Profile.advanceOnboarding(p, 1, NOW), "and cannot be put back into it")
	expect.falsy(Profile.completeOnboarding(p, NOW))
	expect.eq(p.onboarding, nil, "nothing was written")
	expect.eq(Profile.successfulRaids(p), 0)
	for _, id in Profile.GEAR_IDS do
		expect.eq(Profile.gearLevel(p, id), 0, `{id} not owned`)
	end
	expect.falsy(Profile.hasReceipt(p, "purchase-1"))
	expect.falsy(Profile.hasEventPass(p, "event-1"))
	expect.eq(Profile.accessoryCount(p, "hat"), 0)
end

tests["a new save starts onboarding and leaves every other Phase 2 field absent"] = function()
	local template = Profile.new(0, 0)
	local p: any = Profile.prepare(template, 42, NOW)
	expect.eq(p.onboarding.step, 0)
	expect.eq(p.onboarding.completedAt, nil)
	expect.falsy(Profile.isOnboardingComplete(p))
	expect.eq(Profile.onboardingStep(p), 0)
	for _, field in PHASE2_FIELDS do
		if field ~= "onboarding" then
			expect.eq(p[field], nil, `{field} absent`)
		end
	end
	local other: any = Profile.new(0, 0)
	p.onboarding.step = 3
	expect.eq(other.onboarding.step, 0, "every template has its own onboarding table")
end

tests["DataService never reconciles the template into an existing save"] = function()
	-- Reconcile would add Profile.new's { step = 0 } to old saves and send existing players
	-- through onboarding.
	local code = source.codeOnly(source.read("src/Server/Services/DataService.luau"))
	expect.eq(string.find(code, "Reconcile", 1, true), nil)
end

-- Settings (P2.5): tests/specs/Settings.spec.luau. Onboarding by step id: Onboarding.spec.luau.

-- Onboarding (P2.6)

tests["onboarding moves forward only and finishes at the last step"] = function()
	local p: any = Profile.prepare(Profile.new(0, 0), 42, NOW)
	expect.truthy(Profile.advanceOnboarding(p, 1, NOW + 10))
	expect.eq(Profile.onboardingStep(p), 1)
	expect.falsy(Profile.advanceOnboarding(p, 1, NOW + 20), "a repeat changes nothing")
	expect.falsy(Profile.advanceOnboarding(p, 0, NOW + 20), "never backwards")
	for _, bad in { 1.5, -1, Profile.ONBOARDING_LAST_STEP + 1, 0 / 0, math.huge, "2" :: any } do
		expect.falsy(Profile.advanceOnboarding(p, bad, NOW + 20), `step {bad} refused`)
	end
	expect.falsy(Profile.advanceOnboarding(p, 2, 0 / 0), "a NaN time is refused")
	expect.eq(Profile.onboardingStep(p), 1, "nothing above wrote")
	expect.truthy(Profile.advanceOnboarding(p, 3, NOW + 30), "a step may be jumped over")
	expect.falsy(Profile.isOnboardingComplete(p))
	expect.eq(p.onboarding.completedAt, nil)
	expect.truthy(Profile.advanceOnboarding(p, Profile.ONBOARDING_LAST_STEP, NOW + 40))
	expect.truthy(Profile.isOnboardingComplete(p))
	expect.eq(p.onboarding.completedAt, NOW + 40)
	expect.falsy(Profile.completeOnboarding(p, NOW + 50), "already over")
	expect.eq(p.onboarding.completedAt, NOW + 40, "the first finish time is kept")
end

tests["skipping onboarding keeps the step reached and ends it once"] = function()
	local p: any = Profile.prepare(Profile.new(0, 0), 42, NOW)
	expect.truthy(Profile.advanceOnboarding(p, 2, NOW + 10))
	expect.falsy(Profile.completeOnboarding(p, math.huge), "an infinite time is refused")
	expect.truthy(Profile.completeOnboarding(p, NOW + 20))
	expect.truthy(Profile.isOnboardingComplete(p))
	expect.eq(Profile.onboardingStep(p), 2, "analytics still sees where they left")
	expect.eq(p.onboarding.completedAt, NOW + 20)
	expect.falsy(Profile.advanceOnboarding(p, 3, NOW + 30), "no steps after a skip")
	expect.falsy(Profile.completeOnboarding(p, NOW + 30))
end

tests["a corrupt onboarding state counts as complete, so nobody is stuck in it"] = function()
	for _, corrupt in { "x", { step = 1.5 }, { step = -1 }, { step = 0 / 0 }, { step = 99 }, {} } :: { any } do
		local p: any = Profile.new(1, NOW)
		p.onboarding = corrupt
		expect.truthy(Profile.isOnboardingComplete(p))
		expect.eq(Profile.onboardingStep(p), Profile.ONBOARDING_LAST_STEP)
		expect.falsy(Profile.advanceOnboarding(p, 1, NOW))
		expect.falsy(Profile.completeOnboarding(p, NOW))
	end
end

-- Successful raids (P2.7 opt-in, P2.9)

tests["successful raids count up from 0 and a corrupt count starts again"] = function()
	local p: any = Profile.new(1, NOW)
	expect.eq(Profile.successfulRaids(p), 0)
	expect.eq(Profile.countSuccessfulRaid(p), 1, "the first: the opt-in prompt's trigger")
	expect.eq(Profile.countSuccessfulRaid(p), 2)
	expect.eq(p.successfulRaids, 2)
	for _, corrupt in { 0 / 0, -3, 1.5, math.huge, "4" :: any } do
		p.successfulRaids = corrupt
		expect.eq(Profile.successfulRaids(p), 0, `{corrupt} reads as 0`)
		expect.eq(Profile.countSuccessfulRaid(p), 1)
	end
end

-- Once per raidId (C6c): DataService.countSuccessfulRaid, through countSuccessfulRaidOnce.

tests["a successful raid counts once per raidId, so a retried escape never counts twice"] = function()
	local counted = Profile.newCountedRaids()
	local p: any = Profile.new(1, NOW)
	expect.eq(Profile.countSuccessfulRaidOnce(counted, p, "raid-a"), 1, "the first: the opt-in prompt's trigger")
	expect.eq(Profile.countSuccessfulRaidOnce(counted, p, "raid-a"), nil, "a retry counts nothing and returns nil")
	expect.eq(p.successfulRaids, 1)
	expect.eq(Profile.countSuccessfulRaidOnce(counted, p, "raid-b"), 2, "another raid counts")
	for _ = 1, 3 do
		expect.eq(Profile.countSuccessfulRaidOnce(counted, p, "raid-a"), nil)
		expect.eq(Profile.countSuccessfulRaidOnce(counted, p, "raid-b"), nil)
	end
	expect.eq(Profile.successfulRaids(p), 2)

	-- Another raider's profile keeps its own list; a profile loaded again is a new table and starts
	-- a new list (the session that counted the raid is over).
	local other: any = Profile.new(2, NOW)
	expect.eq(Profile.countSuccessfulRaidOnce(counted, other, "raid-a"), 1)
	expect.eq(Profile.successfulRaids(p), 2, "the first raider's count is untouched")
	local reloaded: any = table.clone(p)
	expect.eq(Profile.countSuccessfulRaidOnce(counted, reloaded, "raid-c"), 3)
	expect.eq(Profile.countSuccessfulRaidOnce(counted, reloaded, "raid-c"), nil)

	-- A saved count it starts from, corrupt or not, is read the same way as countSuccessfulRaid's.
	local corrupt: any = Profile.new(3, NOW)
	corrupt.successfulRaids = 0 / 0
	expect.eq(Profile.countSuccessfulRaidOnce(counted, corrupt, "raid-a"), 1)
end

tests["a successful raid on a profile not loaded here counts nothing"] = function()
	local counted = Profile.newCountedRaids()
	expect.eq(Profile.countSuccessfulRaidOnce(counted, nil, "raid-a"), nil, "DataService.getProfile returned nil")
	expect.eq(next(counted), nil, "nothing remembered")
	local p: any = Profile.new(1, NOW)
	expect.eq(Profile.countSuccessfulRaidOnce(counted, p, "raid-a"), 1, "the raid still counts once it is loaded")
end

tests["a successful raid with a bad raidId counts nothing and remembers nothing"] = function()
	local counted = Profile.newCountedRaids()
	local p: any = Profile.new(1, NOW)
	local tooLong = string.rep("x", Config.Escrow.maxRaidIdLength + 1)
	expect.eq(Profile.countSuccessfulRaidOnce(counted, p, nil), nil, "no raidId (the old one-argument call) refused")
	for _, bad in { "", tooLong, 42, true, {}, 0 / 0 } :: { any } do
		expect.eq(Profile.countSuccessfulRaidOnce(counted, p, bad), nil, `{tostring(bad)} refused`)
	end
	expect.eq(p.successfulRaids, nil, "nothing written")
	expect.eq(next(counted), nil, "nothing remembered")
	local longest = string.rep("x", Config.Escrow.maxRaidIdLength)
	expect.eq(Profile.countSuccessfulRaidOnce(counted, p, longest), 1, "a raidId of the longest length counts")
end

tests["the counted raid ids are bounded per profile, keeping the newest"] = function()
	local counted = Profile.newCountedRaids()
	local p: any = Profile.new(1, NOW)
	local max = Profile.COUNTED_RAIDS_MAX
	expect.truthy(max >= 8 and max <= 64, "small, but far above the raids between an escape and its retry")
	local total = max * 3 + 5
	for i = 1, total do
		expect.eq(Profile.countSuccessfulRaidOnce(counted, p, `raid-{i}`), i)
		expect.truthy(#counted[p] <= max, `never more than {max} ids kept`)
	end
	expect.eq(#counted[p], max)
	expect.eq(p.successfulRaids, total)
	-- The newest max are still remembered: retrying any of them counts nothing.
	for i = total - max + 1, total do
		expect.eq(Profile.countSuccessfulRaidOnce(counted, p, `raid-{i}`), nil, `raid-{i} is remembered`)
	end
	expect.eq(p.successfulRaids, total)
	expect.eq(#counted[p], max, "a retry adds nothing")
	-- The oldest are forgotten (the bound's one cost): only a raid that ended max raids ago.
	expect.eq(Profile.countSuccessfulRaidOnce(counted, p, "raid-1"), total + 1)
	expect.eq(#counted[p], max)
end

tests["DataService.countSuccessfulRaid counts a loaded profile once per raidId, through the pure rule"] = function()
	local code = source.codeOnly(source.read("src/Server/Services/DataService.luau"))
	local body = source.functionBody(code, "DataService.countSuccessfulRaid")
	expect.truthy(body, "countSuccessfulRaid found")
	expect.truthy(
		string.find(
			body :: string,
			"^function DataService%.countSuccessfulRaid%(userId: number, raidId: string%): number%?\n"
				.. "%s*return Profile%.countSuccessfulRaidOnce%(countedRaids, DataService%.getProfile%(userId%), raidId%)"
				.. "%s*end\n$"
		),
		"the loaded profile (nil when not loaded) and the pure once-per-raidId rule, and nothing else"
	)
	expect.eq(
		select(2, string.gsub(code, "local countedRaids = Profile%.newCountedRaids%(%)", "")),
		1,
		"one module-level list of counted raids"
	)
	expect.eq(select(2, string.gsub(code, "countedRaids%s*=", "")), 1, "never replaced")
	expect.eq(select(2, string.gsub(code, "successfulRaids%s*=", "")), 0, "DataService never assigns the count itself")
	expect.eq(select(2, string.gsub(code, "Profile%.countSuccessfulRaid%(", "")), 0, "never the un-keyed count")
end

-- Gear (P2.10)

tests["gear ids are the five P2.10 items and are frozen"] = function()
	local ids: { [string]: boolean } = {}
	for _, id in Profile.GEAR_IDS do
		ids[id] = true
		expect.truthy(Profile.isGearId(id))
	end
	for _, id in { "grapple", "smoke", "decoy", "speedCoil", "lockpick" } do
		expect.truthy(ids[id], `{id} listed`)
	end
	expect.eq(#Profile.GEAR_IDS, 5)
	expect.truthy(table.isfrozen(Profile.GEAR_IDS :: any))
	expect.falsy(Profile.isGearId("jetpack"))
	expect.falsy(Profile.isGearId(1))
end

tests["gear levels default to 0, take whole levels only, and 0 removes the entry"] = function()
	local p: any = Profile.new(1, NOW)
	expect.falsy(Profile.setGearLevel(p, "grapple", 0), "0 on a missing table is no change")
	expect.eq(p.gear, nil)
	expect.truthy(Profile.setGearLevel(p, "grapple", 3))
	expect.eq(Profile.gearLevel(p, "grapple"), 3)
	expect.eq(Profile.gearLevel(p, "smoke"), 0, "other gear untouched")
	expect.falsy(Profile.setGearLevel(p, "grapple", 3), "the same level changes nothing")
	for _, bad in { -1, 1.5, 0 / 0, math.huge, "2" :: any } do
		expect.falsy(Profile.setGearLevel(p, "grapple", bad), `level {bad} refused`)
	end
	expect.falsy(Profile.setGearLevel(p, "jetpack" :: any, 1), "unknown id refused")
	expect.eq(p.gear.jetpack, nil)
	expect.eq(Profile.gearLevel(p, "grapple"), 3, "nothing above wrote")
	expect.truthy(Profile.setGearLevel(p, "grapple", 0))
	expect.eq(p.gear.grapple, nil, "level 0 is stored as missing")

	p.gear = { smoke = 0 / 0, decoy = -2, lockpick = "5", speedCoil = 2.5 }
	for _, id in Profile.GEAR_IDS do
		expect.eq(Profile.gearLevel(p, id), 0, `corrupt {id} reads as 0`)
	end
	p.gear = "corrupt"
	expect.eq(Profile.gearLevel(p, "grapple"), 0)
	expect.truthy(Profile.setGearLevel(p, "decoy", 1), "a corrupt table is replaced")
	expect.eq(Profile.gearLevel(p, "decoy"), 1)
end

-- Purchases (P2.8)

tests["a receipt is recorded once, so a redelivered purchase grants nothing"] = function()
	local p: any = Profile.new(1, NOW)
	expect.falsy(Profile.hasReceipt(p, "abc"))
	expect.truthy(Profile.recordReceipt(p, "abc", 123, NOW))
	expect.truthy(Profile.hasReceipt(p, "abc"))
	expect.falsy(Profile.recordReceipt(p, "abc", 123, NOW + 60), "a redelivery is refused")
	expect.eq(p.receipts.abc.at, NOW, "and leaves the first grant as it was")
	expect.eq(p.receipts.abc.productId, 123)
	local bad: { { any } } = {
		{ "", 123, NOW },
		{ string.rep("x", 101), 123, NOW },
		{ 42, 123, NOW },
		{ "d", 0, NOW },
		{ "d", -5, NOW },
		{ "d", 1.5, NOW },
		{ "d", 0 / 0, NOW },
		{ "d", 123, 0 / 0 },
		{ "d", 123, math.huge },
	}
	for i, args in bad do
		expect.falsy(Profile.recordReceipt(p, args[1], args[2], args[3]), `bad receipt {i} refused`)
	end
	expect.falsy(Profile.hasReceipt(p, "d"))
	expect.truthy(Profile.recordReceipt(p, string.rep("x", 100), 123, NOW), "100 characters is allowed")
end

tests["receipts keep the newest MAX_RECEIPTS and never drop the one just recorded"] = function()
	local p: any = Profile.new(1, NOW)
	local extra = 5
	for i = 1, Profile.MAX_RECEIPTS + extra do
		expect.truthy(Profile.recordReceipt(p, `p{i}`, 1, NOW + i))
	end
	local count = 0
	for _ in p.receipts do
		count += 1
	end
	expect.eq(count, Profile.MAX_RECEIPTS)
	for i = 1, extra do
		expect.falsy(Profile.hasReceipt(p, `p{i}`), `oldest p{i} dropped`)
	end
	expect.truthy(Profile.hasReceipt(p, `p{extra + 1}`), "the rest kept")
	expect.truthy(Profile.hasReceipt(p, `p{Profile.MAX_RECEIPTS + extra}`))

	-- A clock behind every saved receipt (another server's) must not drop the purchase it records.
	expect.truthy(Profile.recordReceipt(p, "late", 1, NOW - 1000))
	expect.truthy(Profile.hasReceipt(p, "late"), "kept although it is the oldest")
	expect.falsy(Profile.hasReceipt(p, `p{extra + 1}`), "the oldest other one went instead")

	-- A corrupt entry goes first.
	p.receipts[`p{extra + 2}`] = "corrupt"
	expect.truthy(Profile.recordReceipt(p, "next", 1, NOW + 10_000))
	expect.eq(p.receipts[`p{extra + 2}`], nil, "the corrupt entry was dropped")
	expect.truthy(Profile.hasReceipt(p, `p{extra + 3}`), "not a good one")
end

tests["a corrupt receipts table is replaced by the next record"] = function()
	local p: any = Profile.new(1, NOW)
	p.receipts = "corrupt"
	expect.falsy(Profile.hasReceipt(p, "abc"))
	expect.truthy(Profile.recordReceipt(p, "abc", 1, NOW))
	expect.truthy(Profile.hasReceipt(p, "abc"))
end

tests["an event pass is granted once per event"] = function()
	local p: any = Profile.new(1, NOW)
	expect.truthy(Profile.grantEventPass(p, "blood_moon_1", NOW))
	expect.truthy(Profile.hasEventPass(p, "blood_moon_1"))
	expect.falsy(Profile.hasEventPass(p, "blood_moon_2"))
	expect.falsy(Profile.grantEventPass(p, "blood_moon_1", NOW + 60), "already owned")
	expect.eq(p.eventPasses.blood_moon_1, NOW, "the first grant time is kept")
	expect.falsy(Profile.grantEventPass(p, "", NOW))
	expect.falsy(Profile.grantEventPass(p, 7 :: any, NOW))
	expect.falsy(Profile.grantEventPass(p, "e", 0 / 0))
	expect.eq(p.eventPasses.e, nil)
end

tests["accessories count up per id and a corrupt count starts again"] = function()
	local p: any = Profile.new(1, NOW)
	expect.eq(Profile.accessoryCount(p, "moon_hat"), 0)
	expect.truthy(Profile.grantAccessory(p, "moon_hat"))
	expect.truthy(Profile.grantAccessory(p, "moon_hat"))
	expect.eq(Profile.accessoryCount(p, "moon_hat"), 2)
	expect.eq(Profile.accessoryCount(p, "scarf"), 0)
	expect.falsy(Profile.grantAccessory(p, ""))
	expect.falsy(Profile.grantAccessory(p, nil :: any))
	p.accessories.scarf = 0 / 0
	expect.eq(Profile.accessoryCount(p, "scarf"), 0)
	expect.truthy(Profile.grantAccessory(p, "scarf"))
	expect.eq(Profile.accessoryCount(p, "scarf"), 1)
end

return tests
