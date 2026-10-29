--!strict
--[[
	RaidRules: pure eligibility and loot rules for raids. These encode the fairness table in the
	design doc (loss caps, shields, new-player protection, same-pair limits, revenge).

	The server is the only caller that matters: clients may show these results, but every
	decision is re-checked on the server before a raid starts and again before loot is escrowed.
]]

local Types = require("./Types")
local Config = require("./Config")
local Economy = require("./Economy")

type PlayerProfile = Types.PlayerProfile
type DenSnapshot = Types.DenSnapshot
type Critter = Types.Critter
type Weight = Types.Weight
type RevengeToken = Types.RevengeToken
type RaidLogEntry = Types.RaidLogEntry
type Trap = Types.Trap
type TrapKind = Types.TrapKind
type Mutation = Types.Mutation
type AppliedTransfer = Types.AppliedTransfer

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
	-- Live loss rules (decision D-031)
	LiveProtected = "LiveProtected", -- the den lost enough Glow/s to live steals today
	PostLossSafety = "PostLossSafety", -- a live loss just landed (or a carry from the den is under way)
	-- Async raids (P1.3)
	BadRequest = "BadRequest", -- malformed client arguments
	AlreadyRaiding = "AlreadyRaiding", -- the raider is in a raid, starting one, or carrying live
	NoSnapshot = "NoSnapshot", -- no snapshot saved, or it could not be read
	Blocked = "Blocked", -- one of the two blocked the other
	DefenderOnline = "DefenderOnline", -- the owner is online: raided live, never async (D-043)
	PresenceUnknown = "PresenceUnknown", -- the presence read failed: they may be online (fail closed)
	Locked = "Locked", -- another raider holds the defender's raid lock
	NoPocket = "NoPocket", -- no free pocket den in this server
	TimeUp = "TimeUp", -- the raid timer has run out
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
		profile.liveLossBaseRate = nil
		profile.liveLossRateToday = nil
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

-- Live-raid tuning Config.LiveRaid does not hold yet. These stay here for Phase 0 and move to
-- Config in the next contract batch (decision D-021). The grab range is Config.LiveRaid.grabRange
-- (decision D-018).
RaidRules.Live = table.freeze({
	-- Movement budget (see carryStep). It refills at moveRefill x the carry walk speed and holds
	-- at most budgetSeconds of walking plus budgetSlack studs. A carry starts with the slack only,
	-- so a speed hack fails quickly (1.5x within a second, 1.15x within 40 / walkSpeed s), while a
	-- lag freeze of up to budgetSeconds (no samples, then one catch-up jump) still passes: the
	-- budget refills during the freeze.
	moveRefill = 1.1,
	budgetSeconds = 1,
	budgetSlack = 2,
	maxCarryHeight = 16, -- studs of root part above the den floor (a jump off the den station fits)
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
	-- Steals from this den already under way (carried, or in escrow and not settled). Any at all
	-- refuses the grab (PostLossSafety): each may land as a loss, and a crowd must not beat the
	-- post-loss safety window or the protection check by grabbing together (decision D-031).
	inFlightForOwner: number,
	-- Of those, the ones by this raider: they count against the pair's daily limit once they land.
	inFlightForPair: number,
	-- When this den last lost a critter to a live steal, on the same clock as `now`. Server memory
	-- (RaidService), never persisted: live steals are same-server. nil = none this server session.
	lastLiveLossAt: number?,
	distance: number, -- raider root part to the pad, server positions
	now: number, -- unix seconds: the owner's daily counters and the post-loss safety window
}

export type CarryOutcome = "Continue" | "TooFast" | "TooHigh" | "SkippedStreet" | "Escape" | "Tagged" | "DropAtBorder"

export type CarryStep = {
	moved: number, -- horizontal (X/Z) studs since the last sample
	dt: number, -- seconds since the last sample
	walkSpeed: number, -- the carry walk speed the server set
	budget: number, -- movement budget left after the last sample (carryStartBudget at the grab)
	height: number, -- carrier root part above the den floor, studs
	insideOwnDen: boolean,
	wasInsideDefenderDen: boolean,
	insideDefenderDen: boolean,
	-- An earlier sample was outside both dens, with no return into the owner's den since.
	crossedStreet: boolean,
	lockdownActive: boolean, -- the defender's den is locked down right now
	-- The critter's OWNER to the carrier on X/Z only (height never dodges a tag; nobody else can
	-- tag); nil when the owner has no character.
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

-- Read-only: padIndex -> the critter padCritter(profile, padIndex) would return, for every pad
-- at once (one pass over the critters instead of one per pad).
function RaidRules.padCritters(profile: PlayerProfile): { [number]: Critter }
	local byPad: { [number]: Critter } = {}
	for _, critter in profile.critters do
		local pad = critter.padIndex
		if critter.placement == "Pad" and pad ~= nil and byPad[pad] == nil then
			byPad[pad] = critter
		end
	end
	return byPad
end

-- Read-only: critters this profile lost today (no reset is written).
function RaidRules.lossesToday(profile: PlayerProfile, now: number): number
	return if profile.lossDay == RaidRules.dayIndex(now) then profile.lossesToday else 0
end

--[[
	Live loss rules (decision D-031). Live steals only; async raids keep maxLossesPerDay.
	  - A den's live losses are valued in Glow/s: each stolen critter's Economy.critterRate at the
	    debit (mutation, rebirths, its placement before the steal).
	  - The base is Economy.denRate of the den for its first live loss of the UTC day, measured when
	    that steal's grab was accepted, before the owner was alerted (decision D-034): the record's
	    liveBaseRate. An owner who moves high earners off their pads during the carry cannot
	    shrink it. A record without one falls back to denRate just before the debit.
	  - The den is protected from live steals while today's losses reach
	    Config.LiveRaid.protectionLossShare of the larger of the base and the den's Glow/s right
	    now (decision D-036). The base is a floor: shrinking the den never lowers the line below
	    it. The den's rate lifts it: an owner who emptied the den before the grab (so the base
	    itself is small), lost one cheap critter and refilled is not protected, and neither is a
	    den refilled after a real loss. A real loss keeps protecting, since the den's rate drops
	    with the stolen critter. The debit that crosses the line lands; nothing after it does
	    while the line holds (canGrabLive refuses, and Escrow.debitDefender takes nothing).
	  - At the escrow debit the line also counts the record's grab-time rate (decision D-037,
	    liveProtectedAtDebit), so an owner alerted by the grab cannot shrink the den during the
	    carry to make the debit refuse it. canGrabLive needs nothing more: there, the den's rate
	    now is the grab-time rate.
	  - After any live loss nobody can grab from the den for postLossSafetySeconds.
	Both fields live on the profile, belong to lossDay and reset with it, so stealing a few cheap
	critters from a rich den never protects it, and losing the den's best critter does.
]]

-- A grab-time rate (EscrowRecord.liveBaseRate) a check may use: a finite number >= 0, else none.
local function measuredRate(rate: number?): number?
	if type(rate) == "number" and rate >= 0 and rate < math.huge then
		return rate
	end
	return nil
end

-- Shared by liveProtected and liveProtectedAtDebit: `grabRate` (already checked) raises the line.
local function protectedAgainst(profile: PlayerProfile, now: number, grabRate: number?): boolean
	local base, lost = profile.liveLossBaseRate, profile.liveLossRateToday
	if profile.lossDay ~= RaidRules.dayIndex(now) or base == nil or lost == nil then
		return false
	end
	local rate = Economy.denRate(profile)
	if base ~= base or lost ~= lost or rate ~= rate then
		return true -- math.max would drop a NaN depending on argument order, so decide it here
	end
	return lost >= Config.LiveRaid.protectionLossShare * math.max(base, rate, grabRate or 0)
end

--[[
	Read-only: is this den protected from live steals right now (decision D-036)? True while
	today's live losses reach protectionLossShare x max(liveLossBaseRate, Economy.denRate(profile)),
	so it can turn off and on again during the day as the owner refills or shrinks the den.
	A profile without the fields (no live loss today, or a save from before D-031) is not
	protected. A NaN in either field, or in the den's rate, counts as protected.
	canGrabLive, RaidService's den attribute and its steal prompts read this.
]]
function RaidRules.liveProtected(profile: PlayerProfile, now: number): boolean
	return protectedAgainst(profile, now, nil)
end

--[[
	Read-only: the same check at a live escrow debit (decision D-037), which also counts the
	record's grab-time rate (`grabRate`, EscrowRecord.liveBaseRate): the line is
	protectionLossShare x max(liveLossBaseRate, Economy.denRate(profile), grabRate). The grab was
	accepted only while the den was not protected against the den as it was then, so an owner
	alerted by the grab who shrinks the den during the carry cannot make the debit refuse the
	steal. The grab-time rate only ever raises the line. nil, or anything but a finite number >= 0,
	means none (Escrow.create refuses those anyway): the check is then liveProtected's. Only
	Escrow.debitDefender calls it.
]]
function RaidRules.liveProtectedAtDebit(profile: PlayerProfile, now: number, grabRate: number?): boolean
	return protectedAgainst(profile, now, measuredRate(grabRate))
end

--[[
	Records one live loss on the defender: the base on the day's first, and the critter's Glow/s.
	Call it from the escrow debit BEFORE the critter leaves the profile, so its rate is the one it
	earned where it sat (and a fallback base still counts it). Errors if the critter is already gone.
	`grabBaseRate` is the record's liveBaseRate (D-034): the base when this is the day's first live
	loss. nil, or anything but a finite number >= 0, means none: denRate is measured now instead.
	Later losses that day never change the base.
]]
function RaidRules.recordLiveLoss(defender: PlayerProfile, critter: Critter, now: number, grabBaseRate: number?)
	assert(defender.critters[critter.uid] ~= nil, "recordLiveLoss: call before the critter leaves the profile")
	RaidRules.resetDailyIfNeeded(defender, now)
	if defender.liveLossBaseRate == nil then
		defender.liveLossBaseRate = measuredRate(grabBaseRate) or Economy.denRate(defender)
	end
	defender.liveLossRateToday = (defender.liveLossRateToday or 0) + Economy.critterRate(critter, defender.rebirths)
end

-- When grabs from a den reopen after a live loss at `lastLiveLossAt` (any clock; the answer is on
-- the same one). RaidService also shows it as the den's LiveGrabReadyAt attribute.
function RaidRules.liveGrabReadyAt(lastLiveLossAt: number): number
	return lastLiveLossAt + Config.LiveRaid.postLossSafetySeconds
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
	-- Live loss rules (decision D-031): no daily count cap for live steals. The longest-lasting
	-- refusal comes first, so the raider sees the reason that matters.
	if RaidRules.liveProtected(profile, g.now) then
		return false, RaidRules.Reason.LiveProtected, nil
	end
	-- Same-pair daily limit (decisions D-022, D-031), read from the owner's counters for this raider.
	local pairRaids = RaidRules.pairCount(profile, g.raiderUserId, g.now) + g.inFlightForPair
	if pairRaids >= Config.LiveRaid.maxStealsPerPairPerDay then
		return false, RaidRules.Reason.PairLimit, nil
	end
	local lastLoss = g.lastLiveLossAt
	if g.inFlightForOwner > 0 or (lastLoss ~= nil and not (g.now >= RaidRules.liveGrabReadyAt(lastLoss))) then
		return false, RaidRules.Reason.PostLossSafety, nil -- `not >=` also refuses NaN
	end
	if not (g.distance <= Config.LiveRaid.grabRange) then -- also refuses NaN
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

-- The most movement budget a carrier at `walkSpeed` can bank.
function RaidRules.carryBudgetCap(walkSpeed: number): number
	return walkSpeed * RaidRules.Live.budgetSeconds + RaidRules.Live.budgetSlack
end

-- The budget a carry starts with: the slack only, nothing banked.
function RaidRules.carryStartBudget(): number
	return RaidRules.Live.budgetSlack
end

--[[
	One server sample of a carry. Returns the outcome, the budget left, and whether the carrier
	has now been seen on the street. First match wins:
	  TooFast        the budget went negative: sustained speed, or a jump bigger than ~1 s of
	                 walking. The budget refills at moveRefill x walkSpeed, capped, then pays for
	                 the X/Z distance moved.
	  TooHigh        root part more than maxCarryHeight above the den floor (flying)
	  DropAtBorder   left the owner's den during a Lockdown (checked before an escape, so no jump
	                 out of a locked den lands as one)
	  SkippedStreet  reached your own den without being seen outside both dens since last leaving
	                 the owner's den: a hop across the gap between neighbouring dens never escapes
	                 (the critter drops)
	  Escape         inside your own den; home is safe even with the owner close behind
	  Tagged         the owner within tagRange on X/Z
]]
function RaidRules.carryStep(s: CarryStep): (CarryOutcome, number, boolean)
	local refill = RaidRules.Live.moveRefill * s.walkSpeed * math.max(s.dt, 0)
	local budget = math.min(RaidRules.carryBudgetCap(s.walkSpeed), s.budget + refill) - s.moved
	-- Going back into the owner's den forgets the street: a carrier cannot step out once, come
	-- back, bank budget and then hop the gap into their own den.
	local outsideBoth = not s.insideDefenderDen and not s.insideOwnDen
	local crossedStreet = (s.crossedStreet and not s.insideDefenderDen) or outsideBoth
	if not (budget >= 0) then -- NaN fails too
		return "TooFast", budget, crossedStreet
	end
	if not (s.height <= RaidRules.Live.maxCarryHeight) then
		return "TooHigh", budget, crossedStreet
	end
	if s.lockdownActive and s.wasInsideDefenderDen and not s.insideDefenderDen then
		return "DropAtBorder", budget, crossedStreet
	end
	if s.insideOwnDen then
		return if crossedStreet then "Escape" else "SkippedStreet", budget, crossedStreet
	end
	if s.ownerDistance and s.ownerDistance <= Config.LiveRaid.tagRange then
		return "Tagged", budget, crossedStreet
	end
	return "Continue", budget, crossedStreet
end

-- Live revenge (P1.9b) ----------------------------------------------------------------------------

-- What MatchmakingService.getLiveRevenge returns: server state only, never client data.
export type LiveRevenge = { raidId: string, targetUserId: number }

--[[
	A live grab is a revenge transfer only when the grabbing player's active live revenge is
	against THIS den's owner. Returns the revenge token's raidId, or nil (a plain live steal).
	Revenge changes nothing at the grab: Lockdown still blocks (D-013) and the live loss rules
	apply unchanged; only the kill switch also needs `asyncRaids`.
]]
function RaidRules.liveRevengeAgainst(revenge: LiveRevenge?, ownerUserId: number?): string?
	if revenge == nil or ownerUserId == nil or revenge.targetUserId ~= ownerUserId then
		return nil
	end
	if type(revenge.raidId) ~= "string" or revenge.raidId == "" then
		return nil
	end
	return revenge.raidId
end

--[[
	At the escape, before the first transferLive call (retries reuse the answer): still a revenge
	only when the revenge the carry started with is still active, against the same defender. If it
	lapsed during the carry (token expired or spent, switched off, raider gone) the steal goes on as
	a plain live steal, which needs no more than the grab already passed. A carry that started
	plain never becomes a revenge.
]]
function RaidRules.liveRevengeAtEscape(grabbed: string?, current: LiveRevenge?, defenderUserId: number): string?
	if grabbed == nil then
		return nil
	end
	return if RaidRules.liveRevengeAgainst(current, defenderUserId) == grabbed then grabbed else nil
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

-- Async raids in pocket dens (P1.3) ------------------------------------------------------------
--[[
	Pure rules for raiding an offline den rebuilt from its snapshot. Positions are pocket-local
	studs on the ground plane (x, z): the pocket's centre is (0, 0), the escape gate is at +z and
	the pads run from the back wall (-z) toward it. AsyncRaid turns them into world positions and
	feeds back server-seen positions; nothing here comes from a client.
	Pocket tuning stays here until the next Config contract batch, like RaidRules.Live (D-021).
]]
RaidRules.Pocket = table.freeze({
	size = 72, -- square floor, studs
	padColumns = 6,
	padSpacing = 10,
	padBackZ = -28, -- local z of the first pad row (pads 1-6); later rows step toward the gate
	maxPads = 30,
	gateZ = 32, -- local z of the escape gate (entrance and exit)
	spawnZ = 20, -- where the raider lands
	gateRadius = 5,
	trapGrid = 8, -- Trap.gridX / gridY are cells 0..trapGrid-1 across the floor (clamped)
	trapRadius = 3,
	trapRearmSeconds = 6,
	maxTraps = 12,
	maxGuards = 4,
	guardPatrolSpeed = 8,
	guardChaseSpeed = 13, -- faster than a Medium carry (16 x 0.75), slower than walking (16)
	guardSightRange = 12, -- the nearest patrol line is 14 studs from the spawn
	guardLoseRange = 24,
	guardTagRange = 4,
	alertSeconds = 6, -- AlarmMoth: every guard chases this long, plus its level
	maxHeight = 16, -- root part above the floor
	boundsMargin = 6, -- this far past the walls = left the pocket
	-- Presence written this recently means the owner is online somewhere (D-043): 2 refreshes.
	presenceFreshSeconds = 2 * Config.Matchmaking.presenceRefreshSeconds,
})

local P = RaidRules.Pocket

export type Point = { x: number, z: number }
export type PocketTrap = { kind: TrapKind, level: number, x: number, z: number }
export type PocketLayout = {
	pads: { [number]: Point }, -- padIndex -> position, for the snapshot's laid-out Pad critters
	uids: { [string]: number }, -- uid -> padIndex of those critters: the only grabbable ones
	traps: { PocketTrap },
	guardRoutes: { { Point } }, -- one patrol line per guard critter (at most maxGuards)
	gate: Point,
	spawn: Point,
}
-- What the raider's client may see of a pocket critter: never Glow, never the block list.
export type PocketCritterView = { uid: string, speciesId: string, mutation: Mutation, padIndex: number }
export type GuardState = { x: number, z: number, chasing: boolean, leg: number }
export type TrapEffect = { slow: number, seconds: number, alertSeconds: number, sendBack: boolean }
export type PocketOutcome = "Continue" | "TooFast" | "TooHigh" | "OutOfBounds" | "AtGate"
export type PocketStep = {
	x: number, -- raider root part, pocket-local
	z: number,
	height: number, -- root part above the floor
	moved: number, -- X/Z studs since the last sample
	dt: number,
	walkSpeed: number, -- what the server set
	budget: number, -- movement budget left (carryStartBudget at the grab)
	carrying: boolean,
}

export type AsyncStart = {
	flagsAllow: boolean, -- Escrow.canStartTransfer(Config.Flags, "Async", isRevenge)
	raider: PlayerProfile?,
	hasDen: boolean, -- the raider has a den to return to
	busy: boolean, -- already raiding, starting a raid, or carrying live
	targetUserId: number,
	snapshot: DenSnapshot?, -- nil = none saved or unreadable
	raiderBlocked: { number }?, -- the raider's reported Roblox block list
	defenderOnline: boolean, -- a player in this server, or fresh presence anywhere
	defenderLossesToday: number, -- from the live profile when this server has it, else 0
	revengeRaidId: string?,
	now: number,
}

local function isWhole(value: any, low: number, high: number): boolean
	return type(value) == "number" and value == value and value % 1 == 0 and value >= low and value <= high
end

local function dist(ax: number, az: number, bx: number, bz: number): number
	return math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2)
end

function RaidRules.presenceFresh(presenceAt: number?, now: number): boolean
	return presenceAt ~= nil and now - presenceAt < P.presenceFreshSeconds
end

-- Pocket-local position of a pad: padColumns per row, the first row at the back wall.
function RaidRules.pocketPad(padIndex: number): Point?
	if not isWhole(padIndex, 1, P.maxPads) then
		return nil
	end
	local col = (padIndex - 1) % P.padColumns
	local row = (padIndex - 1) // P.padColumns
	return { x = (col - (P.padColumns - 1) / 2) * P.padSpacing, z = P.padBackZ + row * P.padSpacing }
end

-- The snapshot's stealable critters as the raider's client may see them, by pad. A Pad critter
-- whose pad cannot be laid out (or a second one on the same pad) is left out, and so cannot be
-- grabbed either. Guards and Vault critters never appear.
function RaidRules.pocketView(snapshot: DenSnapshot): { PocketCritterView }
	local seen: { [number]: boolean } = {}
	local list: { PocketCritterView } = {}
	for _, critter in snapshot.critters do
		local pad = critter.padIndex
		if critter.placement == "Pad" and pad and RaidRules.pocketPad(pad) and not seen[pad] then
			seen[pad] = true
			table.insert(
				list,
				{ uid = critter.uid, speciesId = critter.speciesId, mutation = critter.mutation, padIndex = pad }
			)
		end
	end
	table.sort(list, function(a: PocketCritterView, b: PocketCritterView): boolean
		return a.padIndex < b.padIndex
	end)
	return list
end

--[[
	May this raider start an async raid on targetUserId? On success also returns the revenge token
	the raid uses (nil for a normal raid). Taking the raid lock is the caller's next step. A revenge
	id must name a token in the raider's OWN profile against this target (canRaid checks expiry).
]]
function RaidRules.canStartAsync(a: AsyncStart): (boolean, string?, RevengeToken?)
	if not a.flagsAllow then
		return false, RaidRules.Reason.SwitchedOff, nil
	end
	local raider = a.raider
	if raider == nil or not a.hasDen then
		return false, RaidRules.Reason.RaiderNotReady, nil
	end
	if a.busy then
		return false, RaidRules.Reason.AlreadyRaiding, nil
	end
	if a.targetUserId == raider.userId then
		return false, RaidRules.Reason.Self, nil
	end
	local snapshot = a.snapshot
	if snapshot == nil or snapshot.userId ~= a.targetUserId then
		return false, RaidRules.Reason.NoSnapshot, nil
	end
	local theyBlock = snapshot.blockedUserIds ~= nil and table.find(snapshot.blockedUserIds, raider.userId) ~= nil
	local iBlock = a.raiderBlocked ~= nil and table.find(a.raiderBlocked, a.targetUserId) ~= nil
	if theyBlock or iBlock then
		return false, RaidRules.Reason.Blocked, nil
	end
	if a.defenderOnline then
		return false, RaidRules.Reason.DefenderOnline, nil
	end
	local token: RevengeToken? = nil
	if a.revengeRaidId ~= nil then
		token = raider.revengeTokens[a.revengeRaidId]
		if token == nil or token.targetUserId ~= a.targetUserId then
			return false, RaidRules.Reason.RevengeExpired, nil
		end
	end
	local ok, reason = RaidRules.canRaid(raider, snapshot, a.defenderLossesToday, a.now, token)
	if not ok then
		return false, reason, nil
	end
	if #RaidRules.pocketView(snapshot) == 0 then
		return false, RaidRules.Reason.NothingOnPad, nil
	end
	return true, nil, token
end

-- Builds the pocket from a snapshot: pads, traps (grid cells clamped onto the floor and short of
-- the spawn, at most maxTraps), one patrol line per guard (at most maxGuards, in snapshot order),
-- gate and spawn.
function RaidRules.pocketLayout(snapshot: DenSnapshot): PocketLayout
	local pads: { [number]: Point } = {}
	local uids: { [string]: number } = {}
	for _, view in RaidRules.pocketView(snapshot) do
		pads[view.padIndex] = RaidRules.pocketPad(view.padIndex) :: Point
		uids[view.uid] = view.padIndex
	end
	local cell = P.size / P.trapGrid
	local function cellCentre(index: any): number
		local i = if type(index) == "number" and index == index then index else 0
		return (math.clamp(math.floor(i), 0, P.trapGrid - 1) + 0.5) * cell - P.size / 2
	end
	local traps: { PocketTrap } = {}
	for _, trap in snapshot.traps do
		if #traps < P.maxTraps then
			local level = if isWhole(trap.level, 1, math.huge) then math.min(trap.level, 10) else 1
			table.insert(traps, {
				kind = trap.kind,
				level = level,
				x = cellCentre(trap.gridX),
				z = math.min(cellCentre(trap.gridY), P.spawnZ - 8),
			})
		end
	end
	local routes: { { Point } } = {}
	local half = P.size / 2 - 6
	for _, critter in snapshot.critters do
		if critter.placement == "Guard" and #routes < P.maxGuards then
			local z = P.spawnZ - 14 - #routes * 10 -- between the spawn and the pads
			local flip = if #routes % 2 == 0 then 1 else -1
			table.insert(routes, { { x = -half * flip, z = z }, { x = half * flip, z = z } })
		end
	end
	return {
		pads = pads,
		uids = uids,
		traps = traps,
		guardRoutes = routes,
		gate = { x = 0, z = P.gateZ },
		spawn = { x = 0, z = P.spawnZ },
	}
end

function RaidRules.newGuard(route: { Point }): GuardState
	return { x = route[1].x, z = route[1].z, chasing = false, leg = 2 }
end

--[[
	One server tick of a guard (mutates `g`). It patrols its line, chases a raider it sees (or
	while an AlarmMoth alert is on), gives up past guardLoseRange, and tags within guardTagRange.
	`rx`/`rz` nil = no raider to see. Returns true when the raider is tagged.
]]
function RaidRules.guardStep(
	g: GuardState,
	route: { Point },
	rx: number?,
	rz: number?,
	dt: number,
	alerted: boolean
): boolean
	local d = if rx and rz then dist(g.x, g.z, rx, rz) else math.huge
	if d <= P.guardTagRange then
		return true
	end
	g.chasing = alerted or d <= (if g.chasing then P.guardLoseRange else P.guardSightRange)
	local tx, tz, speed
	if g.chasing and rx and rz then
		tx, tz, speed = rx, rz, P.guardChaseSpeed
	else
		local point = route[g.leg] or route[1]
		if dist(g.x, g.z, point.x, point.z) < 0.5 then
			g.leg = g.leg % #route + 1
			point = route[g.leg]
		end
		tx, tz, speed = point.x, point.z, P.guardPatrolSpeed
	end
	local gap = dist(g.x, g.z, tx, tz)
	local step = math.min(gap, speed * math.max(dt, 0))
	if gap > 0 then
		g.x += (tx - g.x) / gap * step
		g.z += (tz - g.z) / gap * step
	end
	return rx ~= nil and rz ~= nil and dist(g.x, g.z, rx, rz) <= P.guardTagRange
end

-- What a trap does to the raider who steps in it: `slow` multiplies walk speed for `seconds`.
function RaidRules.trapEffect(kind: TrapKind, level: number): TrapEffect
	if kind == "SlowPuddle" then
		return { slow = 0.5, seconds = 2 + 0.5 * level, alertSeconds = 0, sendBack = false }
	elseif kind == "Net" then
		return { slow = 0, seconds = 1 + 0.25 * level, alertSeconds = 0, sendBack = false }
	elseif kind == "Sprinkler" then
		return { slow = 0.7, seconds = 3, alertSeconds = 0, sendBack = false }
	elseif kind == "AlarmMoth" then
		return { slow = 1, seconds = 0, alertSeconds = P.alertSeconds + level, sendBack = false }
	end
	-- Trapdoor: back to the spawn; a carried critter goes back to its pad.
	return { slow = 1, seconds = 0, alertSeconds = 0, sendBack = true }
end

function RaidRules.trapHit(trap: PocketTrap, x: number, z: number): boolean
	return dist(trap.x, trap.z, x, z) <= P.trapRadius
end

--[[
	One server sample of the raider in the pocket: the outcome and the budget left. First match
	wins: TooFast (carrying only; RaidRules.Live's movement budget, so a teleport to the gate never
	escapes), TooHigh, OutOfBounds (left the pocket), AtGate, Continue.
]]
function RaidRules.pocketStep(s: PocketStep): (PocketOutcome, number)
	local budget = s.budget
	if s.carrying then
		local refill = RaidRules.Live.moveRefill * s.walkSpeed * math.max(s.dt, 0)
		budget = math.min(RaidRules.carryBudgetCap(s.walkSpeed), budget + refill) - s.moved
		if not (budget >= 0) then -- NaN fails too
			return "TooFast", budget
		end
	end
	if not (s.height <= P.maxHeight) then
		return "TooHigh", budget
	end
	local edge = P.size / 2 + P.boundsMargin
	if not (math.abs(s.x) <= edge and math.abs(s.z) <= edge) then
		return "OutOfBounds", budget
	end
	if dist(s.x, s.z, 0, P.gateZ) <= P.gateRadius then
		return "AtGate", budget
	end
	return "Continue", budget
end

-- May the raider grab this critter now? `snapshot` and `layout` are the raid's own, kept in
-- server memory from the start; `distance` is root part to the pad, server positions.
function RaidRules.canGrabAsync(
	snapshot: DenSnapshot,
	layout: PocketLayout,
	critterUid: any,
	carrying: boolean,
	distance: number,
	now: number,
	endsAt: number
): (boolean, string?, Critter?)
	if not (now < endsAt) then
		return false, RaidRules.Reason.TimeUp, nil
	end
	if type(critterUid) ~= "string" then
		return false, RaidRules.Reason.BadRequest, nil
	end
	if carrying then
		return false, RaidRules.Reason.AlreadyCarrying, nil
	end
	local ok, reason = RaidRules.validateGrab(snapshot, critterUid)
	if not ok then
		return false, reason, nil
	end
	if layout.uids[critterUid] == nil then
		return false, RaidRules.Reason.NotStealable, nil -- a Pad critter the pocket could not lay out
	end
	if not (distance <= Config.LiveRaid.grabRange) then -- also refuses NaN
		return false, RaidRules.Reason.OutOfRange, nil
	end
	for _, critter in snapshot.critters do
		if critter.uid == critterUid then
			return true, nil, critter
		end
	end
	return false, RaidRules.Reason.NotInSnapshot, nil
end

export type EscapeOutcome = {
	escaped: boolean, -- loot (a critter or Glow) is in the raider's profile
	pending: boolean, -- escrow is still delivering (InFlight): it lands on its own, never voided
	speciesId: string?, -- what moved, or what is on its way; on a refusal, what was carried
	glow: number, -- Glow credited; the estimate while pending; 0 when refused
	shieldUntil: number, -- the defender's new shield for the matchmaking pool; 0 = none
}

--[[
	What an async escape's EscrowService.transferAsync result means for the raider (P1.3b).
	`credit` is the raider profile's appliedTransfers entry for the raid, read after the call:
	the real outcome, never the snapshot. The escrow debit may land Glow only (the critter left
	its pad, or the den hit its daily loss cap) or nothing. An Async debit always records the
	defender's shield, revenge token and log (Escrow.debitDefender), so Committed and InFlight
	both shield the den. "Refused" (or anything else) moved nothing.
]]
function RaidRules.asyncEscapeOutcome(
	status: string,
	credit: AppliedTransfer?,
	carriedSpeciesId: string,
	glowEstimate: number,
	now: number
): EscapeOutcome
	local shield = now + Config.Shield.afterSuccessfulRaidSeconds
	local estimate = if glowEstimate == glowEstimate then math.max(0, math.floor(glowEstimate)) else 0
	if status == "Committed" and credit and credit.role == "Credit" then
		local speciesId = if credit.critter then credit.critter.speciesId else nil
		return {
			escaped = speciesId ~= nil or credit.glow > 0,
			pending = false,
			speciesId = speciesId,
			glow = credit.glow,
			shieldUntil = shield,
		}
	elseif status == "Committed" or status == "InFlight" then
		-- Committed without a readable credit (the raider's profile just left): it is there, so
		-- say it is on its way; DenChanged and the inventory show the truth.
		return { escaped = false, pending = true, speciesId = carriedSpeciesId, glow = estimate, shieldUntil = shield }
	end
	return { escaped = false, pending = false, speciesId = carriedSpeciesId, glow = 0, shieldUntil = 0 }
end

-- The replay event (Shared/Replay) that closes a raid ended for `reason` (P1.4b), or nil when the
-- end leaves no mark: Retreat, Left and Error show as the track simply stopping.
function RaidRules.replayEndEvent(reason: string): ("Escape" | "Timeout" | "Tag")?
	if reason == "Escaped" then
		return "Escape"
	elseif reason == "Timeout" then
		return "Timeout"
	elseif reason == "Tagged" then
		return "Tag"
	end
	return nil
end

-- When the player last opened their raid log (unix seconds); 0 = never or an old save (D-005).
function RaidRules.raidLogSeenAt(profile: PlayerProfile): number
	local at = profile.raidLogSeenAt
	return if type(at) == "number" and at == at then at else 0
end

return RaidRules
