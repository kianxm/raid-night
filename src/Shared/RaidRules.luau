--!strict
--[[
	RaidRules: pure eligibility and loot rules for raids. These encode the fairness table in the
	design doc (loss caps, shields, new-player protection, same-pair limits, revenge).

	The server is the only caller that matters: clients may show these results, but every
	decision is re-checked on the server before a raid starts and again before loot is escrowed.
]]

local Types = require("./Types")
local Config = require("./Config")

type PlayerProfile = Types.PlayerProfile
type DenSnapshot = Types.DenSnapshot
type Critter = Types.Critter
type Weight = Types.Weight
type RevengeToken = Types.RevengeToken
type RaidLogEntry = Types.RaidLogEntry

local DAY = 86400

local RaidRules = {}

-- Reasons a raid can be refused. Stable strings: the UI maps them to player-facing copy.
RaidRules.Reason = table.freeze({
	Self = "Self",
	Shielded = "Shielded",
	NewPlayerProtection = "NewPlayerProtection",
	DefenderLossCap = "DefenderLossCap",
	PairLimit = "PairLimit",
	RevengeExpired = "RevengeExpired",
	NotInSnapshot = "NotInSnapshot",
	NotStealable = "NotStealable",
})

function RaidRules.dayIndex(now: number): number
	return math.floor(now / DAY)
end

-- Resets per-day counters when the UTC day has changed. Call on load and before any check.
function RaidRules.resetDailyIfNeeded(profile: PlayerProfile, now: number)
	local today = RaidRules.dayIndex(now)
	if profile.lossDay ~= today then
		profile.lossDay = today
		profile.lossesToday = 0
		profile.pairRaidsToday = {}
	end
end

function RaidRules.protectedUntil(profile: PlayerProfile): number
	return profile.createdAt + Config.Protection.newPlayerSeconds
end

function RaidRules.isProtected(protectedUntil: number, denLevel: number, now: number): boolean
	return now < protectedUntil or denLevel < Config.Protection.minDenLevel
end

function RaidRules.pairCount(profile: PlayerProfile, otherUserId: number, now: number): number
	if profile.lossDay ~= RaidRules.dayIndex(now) then
		return 0
	end
	return profile.pairRaidsToday[tostring(otherUserId)] or 0
end

--[[
	Can `raider` start an async raid on the den in `snapshot`?

	`defenderLossesToday` comes from the defender's live data when available (a lightweight
	read), because a snapshot can be minutes old. `revenge` is the raider's revenge token
	against this defender, if they are raiding back.
]]
function RaidRules.canRaid(
	raider: PlayerProfile,
	snapshot: DenSnapshot,
	defenderLossesToday: number,
	now: number,
	revenge: RevengeToken?
): (boolean, string?)
	if raider.userId == snapshot.userId then
		return false, RaidRules.Reason.Self
	end

	if revenge then
		if revenge.targetUserId ~= snapshot.userId or now >= revenge.expiresAt then
			return false, RaidRules.Reason.RevengeExpired
		end
	end

	-- New-player protection is absolute. Not even revenge breaks it.
	if RaidRules.isProtected(snapshot.protectedUntil, snapshot.denLevel, now) then
		return false, RaidRules.Reason.NewPlayerProtection
	end

	-- Revenge may ignore the target's shield, once per token.
	local bypassShield = revenge ~= nil and not revenge.shieldBypassUsed
	if now < snapshot.shieldUntil and not bypassShield then
		return false, RaidRules.Reason.Shielded
	end

	if defenderLossesToday >= Config.Limits.maxLossesPerDay then
		return false, RaidRules.Reason.DefenderLossCap
	end

	if RaidRules.pairCount(raider, snapshot.userId, now) >= Config.Limits.maxRaidsPerPairPerDay then
		return false, RaidRules.Reason.PairLimit
	end

	return true, nil
end

-- Is this critter in the snapshot and allowed to be stolen? Vault critters are never in a
-- snapshot; Guards defend and cannot be carried off.
function RaidRules.validateGrab(snapshot: DenSnapshot, critterUid: string): (boolean, string?)
	for _, critter in snapshot.critters do
		if critter.uid == critterUid then
			if critter.placement ~= "Pad" then
				return false, RaidRules.Reason.NotStealable
			end
			return true, nil
		end
	end
	return false, RaidRules.Reason.NotInSnapshot
end

-- Glow a successful raid requests from the defender's storage. The escrow debit is capped by
-- what is actually stored when the debit lands, so this is a ceiling, not a promise.
function RaidRules.lootGlow(snapshot: DenSnapshot, isRevenge: boolean): number
	local share = Config.Loot.storedGlowShare
	if isRevenge then
		share *= 1 + Config.Loot.revengeBonus
	end
	return math.floor(snapshot.storedGlow * share)
end

-- Walk-speed multiplier while carrying a critter of this weight.
function RaidRules.carrySpeedMultiplier(weight: Weight): number
	if weight == "Light" then
		return 0.9
	elseif weight == "Medium" then
		return 0.75
	elseif weight == "Heavy" then
		return 0.6
	end
	return 0.45 -- VeryHeavy
end

-- Records the raid on the raider's own profile (pair count and log). Call once per finished
-- raid, success or not, on the raider's server.
function RaidRules.recordOutgoing(
	raider: PlayerProfile,
	raidId: string,
	defenderUserId: number,
	escaped: boolean,
	speciesId: string?,
	glow: number,
	isRevenge: boolean,
	now: number
)
	RaidRules.resetDailyIfNeeded(raider, now)
	local key = tostring(defenderUserId)
	raider.pairRaidsToday[key] = (raider.pairRaidsToday[key] or 0) + 1
	RaidRules.pushLog(raider, {
		raidId = raidId,
		direction = "Outgoing",
		otherUserId = defenderUserId,
		escaped = escaped,
		speciesId = speciesId,
		glow = glow,
		at = now,
		isRevenge = isRevenge,
	})
end

-- Applies the defender-side consequences of a successful raid: loss counter, shield, pair
-- count, log entry and a revenge token. Called when the escrow debit lands on the defender.
function RaidRules.recordIncoming(
	defender: PlayerProfile,
	raidId: string,
	raiderUserId: number,
	speciesId: string?,
	glow: number,
	isRevenge: boolean,
	now: number
)
	RaidRules.resetDailyIfNeeded(defender, now)
	if speciesId then
		defender.lossesToday += 1
	end
	defender.shieldUntil = math.max(defender.shieldUntil, now + Config.Shield.afterSuccessfulRaidSeconds)
	local key = tostring(raiderUserId)
	defender.pairRaidsToday[key] = (defender.pairRaidsToday[key] or 0) + 1
	defender.revengeTokens[raidId] = {
		raidId = raidId,
		targetUserId = raiderUserId,
		expiresAt = now + Config.Revenge.windowSeconds,
		shieldBypassUsed = false,
	}
	RaidRules.pushLog(defender, {
		raidId = raidId,
		direction = "Incoming",
		otherUserId = raiderUserId,
		escaped = true,
		speciesId = speciesId,
		glow = glow,
		at = now,
		isRevenge = isRevenge,
	})
end

-- Newest first, capped at Config.RaidLog.maxEntries.
function RaidRules.pushLog(profile: PlayerProfile, entry: RaidLogEntry)
	table.insert(profile.raidLog, 1, entry)
	while #profile.raidLog > Config.RaidLog.maxEntries do
		table.remove(profile.raidLog)
	end
end

-- Removes expired revenge tokens. Returns how many were removed.
function RaidRules.pruneRevengeTokens(profile: PlayerProfile, now: number): number
	local removed = 0
	for raidId, token in profile.revengeTokens do
		if now >= token.expiresAt then
			profile.revengeTokens[raidId] = nil
			removed += 1
		end
	end
	return removed
end

-- Applies a purchased shield, capped so shields cannot stack past the max.
function RaidRules.applyPurchasedShield(profile: PlayerProfile, now: number)
	local base = math.max(profile.shieldUntil, now)
	profile.shieldUntil = math.min(base + Config.Shield.purchasedSeconds, now + Config.Shield.maxStackSeconds)
end

return RaidRules
