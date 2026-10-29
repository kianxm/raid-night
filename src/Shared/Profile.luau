--!strict
--[[
	Profile: the default shape of a new player's save, and the migration entry point.

	ProfileStore's template should be `Profile.new(0, 0)`; on load the server calls
	`Profile.migrate` before anything reads the data. Every schema change adds a numbered step
	to `migrations` and bumps Config.SCHEMA_VERSION.

	The template only fills a key that was never saved: DataService never reconciles it into an
	existing save (ProfileStore's Reconcile). Optional fields rely on that, `onboarding` most of
	all: reconciled into an old save, it would send an existing player through onboarding.
]]

local Types = require("./Types")
local Config = require("./Config")
local RaidRules = require("./RaidRules")

type PlayerProfile = Types.PlayerProfile
type GearId = Types.GearId

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

		-- Phase 2 (D-059). Only onboarding is set here: a new save starts it, while a save without
		-- the field predates onboarding and counts as complete. The rest stay absent until first
		-- written (missing = default): settings, successfulRaids, gear, receipts, eventPasses,
		-- accessories.
		onboarding = { step = 0 },
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
	-2, ...). DataService holds a test profile only in Studio with memory persistence. A test id
	reaches the place's DataStores only through a Studio test session (DataService.loadTestSession,
	D-056), behind Studio, the StudioTestSessions switch and DataStore persistence.
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

-- Phase 2 fields (decision D-059) ----------------------------------------------------------------
--[[
	Every Phase 2 field is optional: missing means the default here, so a save from before Phase 2
	loads unchanged (no migration, no SCHEMA_VERSION bump). Readers turn a corrupt saved value into
	its default; writers refuse bad input, write nothing then, and return whether they wrote. `now`
	is always the server's os.time(), never a client value. Nothing here yields.
]]

local MAX_KEY_LENGTH = 100

local function isWhole(value: any): boolean
	return isFinite(value) and value % 1 == 0
end

-- An id saved as a table key: a string of 1 to MAX_KEY_LENGTH characters.
local function isKey(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= MAX_KEY_LENGTH
end

-- Settings (P2.5) ---------------------------------------------------------------------------------

export type ResolvedSettings = {
	musicVolume: number,
	sfxVolume: number,
	reducedMotion: boolean,
}

-- What a missing setting means. A volume scales the audio mix: 1 plays it as mixed.
Profile.SETTINGS_DEFAULTS = table.freeze({
	musicVolume = 1,
	sfxVolume = 1,
	reducedMotion = false,
}) :: ResolvedSettings

-- A volume as saved: a finite number clamped to 0..1 and rounded to 0.01; nil for anything else.
local function cleanVolume(value: any): number?
	if not isFinite(value) then
		return nil
	end
	return math.round(math.clamp(value, 0, 1) * 100) / 100
end

-- The player's settings with every default filled in. A saved volume out of range reads clamped;
-- a saved value of the wrong type (or a NaN or infinite volume) reads as its default.
function Profile.settingsOf(profile: PlayerProfile): ResolvedSettings
	local saved: any = profile.settings
	if type(saved) ~= "table" then
		saved = {}
	end
	local defaults = Profile.SETTINGS_DEFAULTS
	local reducedMotion = saved.reducedMotion
	return {
		musicVolume = cleanVolume(saved.musicVolume) or defaults.musicVolume,
		sfxVolume = cleanVolume(saved.sfxVolume) or defaults.sfxVolume,
		reducedMotion = if type(reducedMotion) == "boolean" then reducedMotion else defaults.reducedMotion,
	}
end

--[[
	Applies a settings change the client asked for. `request` is untrusted: a table holding any of
	musicVolume (number), sfxVolume (number) and reducedMotion (boolean), and nothing else. Volumes
	must be finite; they are clamped to 0..1 and rounded to 0.01. Any other key, a wrong type or a
	NaN or infinite volume refuses the whole request. Keys left out keep their saved value. Returns
	whether anything changed.
]]
function Profile.applySettings(profile: PlayerProfile, request: any): boolean
	if type(request) ~= "table" then
		return false
	end
	local changes: { [string]: number | boolean } = {}
	for key, value in next, request do
		if key == "musicVolume" or key == "sfxVolume" then
			local volume = cleanVolume(value)
			if volume == nil then
				return false
			end
			changes[key] = volume
		elseif key == "reducedMotion" and type(value) == "boolean" then
			changes[key] = value
		else
			return false
		end
	end
	local saved: any = profile.settings
	if type(saved) ~= "table" then
		saved = {}
	end
	local wrote = false
	for key, value in changes do
		if saved[key] ~= value then
			saved[key] = value
			wrote = true
		end
	end
	if wrote then
		profile.settings = saved
	end
	return wrote
end

-- Onboarding (P2.6, playbook Appendix C) -----------------------------------------------------------

-- Appendix C steps 1-5 are the player's: hatch, place and collect, second egg, first steal, home.
-- Step 6's 30-minute shield needs no saved state (it counts from createdAt), and step 7 (the
-- notification opt-in) is not part of onboarding.
Profile.ONBOARDING_LAST_STEP = 5

-- The saved state when it is usable: a table whose step is a whole number 0..ONBOARDING_LAST_STEP.
local function onboardingState(profile: PlayerProfile): Types.OnboardingState?
	local state: any = profile.onboarding
	if type(state) ~= "table" or not isWhole(state.step) then
		return nil
	end
	if state.step < 0 or state.step > Profile.ONBOARDING_LAST_STEP then
		return nil
	end
	return state
end

-- Whether onboarding is over (finished or skipped). No state counts as over: the save predates
-- onboarding, and an existing player is never sent through it. A corrupt state counts as over too.
function Profile.isOnboardingComplete(profile: PlayerProfile): boolean
	local state = onboardingState(profile)
	return state == nil or state.completedAt ~= nil or state.step >= Profile.ONBOARDING_LAST_STEP
end

-- The last step completed, for resuming and for analytics. ONBOARDING_LAST_STEP when there is no
-- usable state (a save from before onboarding).
function Profile.onboardingStep(profile: PlayerProfile): number
	local state = onboardingState(profile)
	return if state then state.step else Profile.ONBOARDING_LAST_STEP
end

--[[
	Records that the player completed onboarding step `step`. Forward only, and a step may be jumped
	over. Reaching ONBOARDING_LAST_STEP finishes onboarding at `now`. Refuses, writing nothing, once
	onboarding is over, for a step that is not a whole number above the current one and at most
	ONBOARDING_LAST_STEP, or for a NaN or infinite `now`. Returns whether it wrote.
]]
function Profile.advanceOnboarding(profile: PlayerProfile, step: number, now: number): boolean
	if not isFinite(now) or not isWhole(step) or Profile.isOnboardingComplete(profile) then
		return false
	end
	local state = onboardingState(profile) :: Types.OnboardingState -- usable, since not over
	if step <= state.step or step > Profile.ONBOARDING_LAST_STEP then
		return false
	end
	state.step = step
	if step == Profile.ONBOARDING_LAST_STEP then
		state.completedAt = now
	end
	return true
end

-- Ends onboarding at `now` without the remaining steps (a skip). Refuses once it is over, or for a
-- NaN or infinite `now`. Returns whether it wrote.
function Profile.completeOnboarding(profile: PlayerProfile, now: number): boolean
	if not isFinite(now) or Profile.isOnboardingComplete(profile) then
		return false
	end
	local state = onboardingState(profile) :: Types.OnboardingState
	state.completedAt = now
	return true
end

-- Successful raids (P2.7 opt-in timing, P2.9 analytics) ----------------------------------------------

-- Lifetime raids and live steals the player escaped from. Missing or corrupt = 0.
function Profile.successfulRaids(profile: PlayerProfile): number
	local count: any = profile.successfulRaids
	return if isWhole(count) and count > 0 then count else 0
end

-- Counts one successful raid on the raider's own loaded profile and returns the new lifetime
-- count (1 = their first). Call it once per raid. A corrupt count starts again from 0.
function Profile.countSuccessfulRaid(profile: PlayerProfile): number
	local count = Profile.successfulRaids(profile) + 1
	profile.successfulRaids = count
	return count
end

-- Gear (P2.10) --------------------------------------------------------------------------------------

local GEAR_IDS: { GearId } = { "grapple", "smoke", "decoy", "speedCoil", "lockpick" }
Profile.GEAR_IDS = table.freeze(GEAR_IDS)

local GEAR_ID_SET: { [string]: boolean } = {}
for _, id in GEAR_IDS do
	GEAR_ID_SET[id] = true
end

function Profile.isGearId(value: any): boolean
	return type(value) == "string" and GEAR_ID_SET[value] == true
end

-- The player's level of one gear item: 0 = not owned. An unknown id, a missing table or entry, or
-- a saved level that is not a whole number above 0 reads as 0.
function Profile.gearLevel(profile: PlayerProfile, gearId: GearId): number
	local gear: any = profile.gear
	if not Profile.isGearId(gearId) or type(gear) ~= "table" then
		return 0
	end
	local level = gear[gearId]
	return if isWhole(level) and level > 0 then level else 0
end

--[[
	Sets one gear item's level. P2.10 owns the rules (cost, maximum, upgrade only); this only keeps
	the save well-formed: it refuses an unknown id or a level that is not a whole number >= 0, and
	level 0 removes the entry. Returns whether it wrote.
]]
function Profile.setGearLevel(profile: PlayerProfile, gearId: GearId, level: number): boolean
	if not Profile.isGearId(gearId) or not isWhole(level) or level < 0 then
		return false
	end
	local gear: any = profile.gear
	if type(gear) ~= "table" then
		if level == 0 then
			return false -- already reads as 0
		end
		gear = {}
		profile.gear = gear
	end
	local value = if level == 0 then nil else level
	if gear[gearId] == value then
		return false
	end
	gear[gearId] = value
	return true
end

-- Purchases (P2.8) -----------------------------------------------------------------------------------

-- Receipts kept per profile. Roblox redelivers an ungranted receipt later or when the player
-- rejoins, with no documented time limit, so the bound is a count of the newest, never an age.
Profile.MAX_RECEIPTS = 100

-- Whether this profile already granted developer-product purchase `purchaseId`.
function Profile.hasReceipt(profile: PlayerProfile, purchaseId: string): boolean
	local receipts: any = profile.receipts
	return isKey(purchaseId) and type(receipts) == "table" and receipts[purchaseId] ~= nil
end

--[[
	Records ProcessReceipt's `purchaseId` for `productId` as granted at `now`: the idempotency rule
	for developer products (P2.8). Grant only when this returns true, in the same step with no
	yield between, then confirm the save (DataService.saveNow) before returning PurchaseGranted.
	false writes nothing: the purchase is already recorded (a redelivery: grant nothing, confirm the
	save, return PurchaseGranted), or the input is bad (purchaseId not a 1-100 character string,
	productId not a whole number above 0, `now` NaN or infinite). Past MAX_RECEIPTS it drops the
	oldest entries (by `at`, then PurchaseId), never the one it just recorded.
]]
function Profile.recordReceipt(profile: PlayerProfile, purchaseId: string, productId: number, now: number): boolean
	if not isKey(purchaseId) or not isWhole(productId) or productId <= 0 or not isFinite(now) then
		return false
	end
	local receipts: any = profile.receipts
	if type(receipts) ~= "table" then
		receipts = {}
		profile.receipts = receipts
	elseif receipts[purchaseId] ~= nil then
		return false
	end
	receipts[purchaseId] = { productId = productId, at = now }

	local count = 0
	for _ in receipts do
		count += 1
	end
	while count > Profile.MAX_RECEIPTS do
		local oldestId: any, oldestAt = nil, 0
		for id, receipt in receipts do
			if id ~= purchaseId then
				-- A corrupt entry has no usable time and goes first.
				local at = if type(receipt) == "table" and isFinite(receipt.at) then receipt.at else -math.huge
				if oldestId == nil or at < oldestAt or (at == oldestAt and tostring(id) < tostring(oldestId)) then
					oldestId, oldestAt = id, at
				end
			end
		end
		if oldestId == nil then
			break -- only the new receipt is left
		end
		receipts[oldestId] = nil
		count -= 1
	end
	return true
end

-- Whether the player owns the event pass for `eventId`.
function Profile.hasEventPass(profile: PlayerProfile, eventId: string): boolean
	local passes: any = profile.eventPasses
	return isKey(eventId) and type(passes) == "table" and passes[eventId] ~= nil
end

-- Grants the event pass for `eventId` at `now`. Refuses, writing nothing, when it is already
-- owned, for an id that is not a 1-100 character string, or for a NaN or infinite `now`. Returns
-- whether it wrote.
function Profile.grantEventPass(profile: PlayerProfile, eventId: string, now: number): boolean
	if not isKey(eventId) or not isFinite(now) or Profile.hasEventPass(profile, eventId) then
		return false
	end
	local passes: any = profile.eventPasses
	if type(passes) ~= "table" then
		passes = {}
		profile.eventPasses = passes
	end
	passes[eventId] = now
	return true
end

-- How many of critter accessory `accessoryId` the player owns. Missing or corrupt = 0.
function Profile.accessoryCount(profile: PlayerProfile, accessoryId: string): number
	local owned: any = profile.accessories
	if not isKey(accessoryId) or type(owned) ~= "table" then
		return 0
	end
	local count = owned[accessoryId]
	return if isWhole(count) and count > 0 then count else 0
end

-- Adds one critter accessory `accessoryId` (cosmetic only). Refuses an id that is not a 1-100
-- character string. Returns whether it wrote.
function Profile.grantAccessory(profile: PlayerProfile, accessoryId: string): boolean
	if not isKey(accessoryId) then
		return false
	end
	local owned: any = profile.accessories
	if type(owned) ~= "table" then
		owned = {}
		profile.accessories = owned
	end
	owned[accessoryId] = Profile.accessoryCount(profile, accessoryId) + 1
	return true
end

return Profile
