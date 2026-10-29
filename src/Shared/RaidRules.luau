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
	-- Live stealing (decision D-003)
	SwitchedOff = "SwitchedOff", -- Escrow.canStartTransfer refused (kill switch)
	RaiderNotReady = "RaiderNotReady", -- raider has no den or no loaded profile
	EmptyDen = "EmptyDen", -- nobody owns this den
	OwnDen = "OwnDen", -- you cannot steal from yourself
	OwnerNotReady = "OwnerNotReady", -- the owner's profile is not loaded
	AlreadyCarrying = "AlreadyCarrying",
	NothingOnPad = "NothingOnPad",
	CritterBusy = "CritterBusy", -- already carried (or on its way through escrow)
	OutOfRange = "OutOfRange",
	LockdownActive = "LockdownActive",
	LockdownCooldown = "LockdownCooldown",
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

-- Live stealing (decision D-003) ------------------------------------------------------------------
--[[
	Pure rules for stealing from an online owner's den. RaidService feeds them server-seen
	positions and its own state; nothing here comes from a client. Times are whatever clock the
	caller uses consistently (RaidService passes workspace:GetServerTimeNow() for live raids and
	os.time() for profile reads).
]]

-- Live-raid world constants Config.LiveRaid does not hold. `grabRange` is proposed as
-- Config.LiveRaid.grabRange (a contract change for the data owner).
RaidRules.Live = table.freeze({
	grabRange = 10, -- studs, raider root part to pad centre, checked for the whole hold
	moveTolerance = 2, -- a carrier may cover up to this many times their walk speed per sample...
	moveSlack = 6, -- ...plus this many studs, to absorb replication jitter
})

export type Lockdown = {
	startedAt: number,
	untilAt: number, -- start + lockdownSeconds
	readyAt: number, -- untilAt + lockdownCooldownSeconds (decision D-011)
}

export type LiveGrab = {
	flagsAllow: boolean, -- Escrow.canStartTransfer(Config.Flags, "Live", isRevenge)
	raiderUserId: number,
	raiderReady: boolean, -- raider has a den to escape to and a loaded profile
	ownerUserId: number?, -- the den's owner; nil when nobody owns it
	ownerProfile: PlayerProfile?, -- nil when not loaded
	-- RaidRules.entryBlocked for this raider right now: someone who was not inside when a
	-- Lockdown began cannot grab, even if a teleport put them in range between push-backs.
	lockdownBlocked: boolean,
	padIndex: number,
	carrying: boolean, -- the raider already carries a critter
	isLocked: (uid: string) -> boolean, -- critter already carried or in escrow
	distance: number, -- raider root part to the pad, server positions
	now: number, -- unix seconds, for the owner's daily loss counter
}

export type CarryOutcome = "Continue" | "TooFast" | "Escape" | "Tagged" | "DropAtBorder"

export type CarryStep = {
	moved: number, -- horizontal studs since the last sample
	dt: number, -- seconds since the last sample
	walkSpeed: number, -- the carry walk speed the server set
	insideOwnDen: boolean,
	wasInsideDefenderDen: boolean,
	insideDefenderDen: boolean,
	lockdownActive: boolean, -- the defender's den is locked down right now
	-- The critter's OWNER to the carrier (nobody else can tag); nil when the owner has no character.
	ownerDistance: number?,
}

-- The critter the owner's profile has on this pad, or nil. Models and attributes never decide
-- which critter a pad holds (decision D-014).
function RaidRules.padCritter(profile: PlayerProfile, padIndex: number): Critter?
	for _, critter in profile.critters do
		if critter.placement == "Pad" and critter.padIndex == padIndex then
			return critter
		end
	end
	return nil
end

-- Read-only: critters this profile lost today (no reset is written).
function RaidRules.lossesToday(profile: PlayerProfile, now: number): number
	return if profile.lossDay == RaidRules.dayIndex(now) then profile.lossesToday else 0
end

-- Can this raider grab the critter on this pad? Returns the critter on success.
function RaidRules.canGrabLive(g: LiveGrab): (boolean, string?, Critter?)
	if not g.flagsAllow then
		return false, RaidRules.Reason.SwitchedOff, nil
	end
	if not g.raiderReady then
		return false, RaidRules.Reason.RaiderNotReady, nil
	end
	if g.ownerUserId == nil then
		return false, RaidRules.Reason.EmptyDen, nil
	end
	if g.ownerUserId == g.raiderUserId then
		return false, RaidRules.Reason.OwnDen, nil
	end
	local profile = g.ownerProfile
	if profile == nil or profile.userId ~= g.ownerUserId then
		return false, RaidRules.Reason.OwnerNotReady, nil
	end
	if g.lockdownBlocked then
		return false, RaidRules.Reason.LockdownActive, nil
	end
	if g.carrying then
		return false, RaidRules.Reason.AlreadyCarrying, nil
	end
	local critter = RaidRules.padCritter(profile, g.padIndex)
	if critter == nil then
		return false, RaidRules.Reason.NothingOnPad, nil
	end
	if g.isLocked(critter.uid) then
		return false, RaidRules.Reason.CritterBusy, nil
	end
	if RaidRules.lossesToday(profile, g.now) >= Config.Limits.maxLossesPerDay then
		return false, RaidRules.Reason.DefenderLossCap, nil
	end
	if not (g.distance <= RaidRules.Live.grabRange) then -- also refuses NaN
		return false, RaidRules.Reason.OutOfRange, nil
	end
	return true, nil, critter
end

-- Has a server-timed grab hold lasted long enough?
function RaidRules.grabHoldDone(startedAt: number, now: number): boolean
	return now - startedAt >= Config.LiveRaid.grabHoldSeconds
end

function RaidRules.carryWalkSpeed(baseWalkSpeed: number, weight: Weight): number
	return baseWalkSpeed * RaidRules.carrySpeedMultiplier(weight)
end

-- Could a carrier walking at `walkSpeed` have covered `moved` studs in `dt` seconds?
function RaidRules.carryMoveOk(moved: number, dt: number, walkSpeed: number): boolean
	local limit = walkSpeed * math.max(dt, 0) * RaidRules.Live.moveTolerance + RaidRules.Live.moveSlack
	return moved <= limit -- NaN fails
end

-- One server sample of a carry. First match wins: a teleport never counts as an escape, and a
-- carrier who is home is safe.
function RaidRules.carryStep(s: CarryStep): CarryOutcome
	if not RaidRules.carryMoveOk(s.moved, s.dt, s.walkSpeed) then
		return "TooFast"
	end
	if s.insideOwnDen then
		return "Escape"
	end
	if s.ownerDistance and s.ownerDistance <= Config.LiveRaid.tagRange then
		return "Tagged"
	end
	if s.lockdownActive and s.wasInsideDefenderDen and not s.insideDefenderDen then
		return "DropAtBorder"
	end
	return "Continue"
end

-- Lockdown (decisions D-003, D-011, D-013) ---------------------------------------------------------

function RaidRules.startLockdown(now: number): Lockdown
	local untilAt = now + Config.LiveRaid.lockdownSeconds
	return {
		startedAt = now,
		untilAt = untilAt,
		readyAt = untilAt + Config.LiveRaid.lockdownCooldownSeconds,
	}
end

function RaidRules.lockdownActive(lockdown: Lockdown?, now: number): boolean
	return lockdown ~= nil and now < lockdown.untilAt
end

-- May the owner start a Lockdown now? (Owner-only is the caller's check.)
function RaidRules.canStartLockdown(lockdown: Lockdown?, now: number): (boolean, string?)
	if lockdown == nil then
		return true, nil
	end
	if now < lockdown.untilAt then
		return false, RaidRules.Reason.LockdownActive
	end
	if now < lockdown.readyAt then
		return false, RaidRules.Reason.LockdownCooldown
	end
	return true, nil
end

-- Must this visitor be pushed out of the den? Lockdown blocks ENTRY only: someone already inside
-- at the last sample may stay or leave. The owner is never blocked. Revenge does not bypass a
-- Lockdown (decision D-013), so `isRevenge` is deliberately ignored.
function RaidRules.entryBlocked(
	lockdown: Lockdown?,
	now: number,
	isOwner: boolean,
	_isRevenge: boolean,
	wasInside: boolean,
	isInside: boolean
): boolean
	return isInside and not wasInside and not isOwner and RaidRules.lockdownActive(lockdown, now)
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
