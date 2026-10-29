--!strict
--[[
	GearRules (owner: raid agent): pure rules for raider gear (P2.10). Raid/Gear.luau feeds them
	server state (positions, its own cooldown and charge tables, the profile's gear levels) and
	applies the result; nothing here comes from a client unchecked. Times are on whatever clock the
	caller uses consistently (Raid/Gear.luau passes workspace:GetServerTimeNow()).

	The five items (tuning: Config.Gear; a level is Profile.gearLevel, 0 = not owned):
	  grapple    Zip to a point in sight, up to `range` studs away and at most `maxRise` above.
	             Never while carrying (the carry is the defender's chance to tag, and the movement
	             budget only ever pays for walking), never while a trap holds you, never into a den
	             whose Lockdown would push you out.
	  smoke      A cloud where you stand. Live: a carrier inside any cloud is tagged only at
	             tagRangeShare of Config.LiveRaid.tagRange. Async: guards cannot see a raider
	             inside one (they still tag one they walk into).
	  decoy      A fake raider that runs straight ahead. Live: display only, popped by any other
	             player within tagRange. Async: a guard that sees it chases it instead of you.
	  speedCoil  Walk speed x (1 + speedBonus) for a few seconds. A carrier is never sped past the
	             normal walk speed, so an owner on foot can always close in. The carry speed checks
	             use the coil's speed until coilGraceSeconds after it ends. Not while trapped.
	  lockpick   Live raids only. Stand within `range` of a locked-down den's border, outside it,
	             for pickSeconds; then that Lockdown lets you in. It never opens the way out: a
	             critter carried across the border during the Lockdown still drops. Moving, the
	             owner coming within tagRange, or the Lockdown ending breaks the pick.

	Async raids (offline defender): grapple, smoke, decoy and the coil work, each limited to its
	asyncCharges per raid on top of its cooldown. The lockpick does not: an async den has no
	Lockdown to pick, and the offline owner cannot answer anything else it could open.
]]

local Config = require("./Config")
local Types = require("./Types")
local Profile = require("./Profile")
local Plots = require("./Plots")
local RaidRules = require("./RaidRules")

type GearId = Types.GearId
type TransferKind = Types.TransferKind

local G = Config.Gear
local P = RaidRules.Pocket

local GearRules = {}

-- Reasons a gear use is refused. Stable strings: the UI maps them to player-facing copy.
GearRules.Reason = table.freeze({
	BadRequest = "BadRequest", -- unknown gear id or a malformed target
	NotOwned = "NotOwned", -- level 0
	LiveOnly = "LiveOnly", -- the lockpick in an async raid
	Busy = "Busy", -- a lockpick is under way
	Cooldown = "Cooldown",
	NoCharges = "NoCharges", -- this async raid's uses are spent
	Carrying = "Carrying", -- grapple and lockpick need free hands
	Trapped = "Trapped", -- a trap's slow is on: no grapple, no coil
	OutOfRange = "OutOfRange",
	TooHigh = "TooHigh", -- grapple landing too far above the take-off
	NoLineOfSight = "NoLineOfSight", -- server raycast blocked, or no ground under the landing
	OutOfBounds = "OutOfBounds", -- grapple landing off the pocket floor
	LockdownBlocked = "LockdownBlocked", -- grapple into a den whose Lockdown would push you out
	NoLockdown = "NoLockdown", -- lockpick: no active Lockdown on that den
	NotNearDen = "NotNearDen", -- lockpick: not within range of a den's border
	OwnDen = "OwnDen", -- lockpick: your own den
	AlreadyInside = "AlreadyInside", -- lockpick: you are inside that den already
	AlreadyPicked = "AlreadyPicked", -- lockpick: you already hold this Lockdown's pass
	NotReady = "NotReady", -- no character, no loaded profile
	SwitchedOff = "SwitchedOff", -- raids are switched off (Config.Flags.raids)
	RateLimited = "RateLimited",
	-- A pick that stops before it is done
	Moved = "Moved",
	Caught = "Caught",
})

local LIVE_ONLY: { [string]: boolean } = { lockpick = true }
local NOT_WHILE_CARRYING: { [string]: boolean } = { grapple = true, lockpick = true }
local NOT_WHILE_TRAPPED: { [string]: boolean } = { grapple = true, speedCoil = true }
GearRules.LIVE_ONLY = table.freeze(LIVE_ONLY)

export type Point = { x: number, z: number }
export type Point3 = { x: number, y: number, z: number }

local function finite(value: any): boolean
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function dist(ax: number, az: number, bx: number, bz: number): number
	return math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2)
end

function GearRules.isGearId(value: any): boolean
	return Profile.isGearId(value)
end

-- Does this gear work in this kind of raid? ("Live" = the shared world, "Async" = a pocket den.)
function GearRules.worksIn(gearId: GearId, kind: TransferKind): boolean
	return GearRules.isGearId(gearId) and (kind == "Live" or (kind == "Async" and not LIVE_ONLY[gearId]))
end

-- An item's tuning value at a level: key + keyPerLevel x (level - 1), level clamped to 1..maxLevel.
function GearRules.value(gearId: GearId, key: string, level: number): number
	local item = (G.items :: any)[gearId]
	assert(item ~= nil and type(item[key]) == "number", `GearRules.value: no {key} for {gearId}`)
	local per = item[key .. "PerLevel"]
	local l = if finite(level) then math.clamp(math.floor(level), 1, G.maxLevel) else 1
	return item[key] + (if type(per) == "number" then per else 0) * (l - 1)
end

function GearRules.cooldownSeconds(gearId: GearId, level: number): number
	return GearRules.value(gearId, "cooldownSeconds", level)
end

-- Uses per async raid (0 for live-only gear).
function GearRules.asyncCharges(gearId: GearId, level: number): number
	if LIVE_ONLY[gearId] then
		return 0
	end
	return math.floor(GearRules.value(gearId, "asyncCharges", level))
end

--[[
	Glow to go from `level` to level + 1 (level 0 = buying it). nil at maxLevel, for an unknown id
	or a level that is not a whole number >= 0. The spend itself is economy's (handoff, P2.10): it
	must check, spend and write the level in one non-yielding step.
]]
function GearRules.upgradeCost(gearId: any, level: any): number?
	if not GearRules.isGearId(gearId) or not finite(level) or level % 1 ~= 0 or level < 0 or level >= G.maxLevel then
		return nil
	end
	local price = (G.items :: any)[gearId].price
	return math.floor(price * G.upgradeCostGrowth ^ level + 0.5)
end

-- Using gear ------------------------------------------------------------------------------------

export type Use = {
	gearId: any, -- from the client: checked here
	level: number, -- Profile.gearLevel of the user's own loaded profile
	kind: TransferKind, -- "Async" while in a pocket raid, else "Live"
	now: number,
	readyAt: number?, -- server memory: when this gear is ready again; nil = never used
	charges: number?, -- async raids: uses left this raid (server memory)
	carrying: boolean,
	trapped: boolean, -- a trap's slow is on (async)
	picking: boolean, -- a lockpick is under way
}

-- May this gear be used now? First match wins, so the UI shows the reason that matters.
function GearRules.canUse(u: Use): (boolean, string?)
	local id = u.gearId
	if not GearRules.isGearId(id) then
		return false, GearRules.Reason.BadRequest
	end
	if not (finite(u.level) and u.level >= 1) then
		return false, GearRules.Reason.NotOwned
	end
	if not GearRules.worksIn(id, u.kind) then
		return false, GearRules.Reason.LiveOnly
	end
	if u.picking then
		return false, GearRules.Reason.Busy
	end
	local readyAt = u.readyAt
	if readyAt ~= nil and not (u.now >= readyAt) then -- `not >=` also refuses NaN
		return false, GearRules.Reason.Cooldown
	end
	if u.kind == "Async" and not ((u.charges or 0) >= 1) then
		return false, GearRules.Reason.NoCharges
	end
	if u.carrying and NOT_WHILE_CARRYING[id] then
		return false, GearRules.Reason.Carrying
	end
	if u.trapped and NOT_WHILE_TRAPPED[id] then
		return false, GearRules.Reason.Trapped
	end
	return true, nil
end

-- When the gear is ready again after a use at `now`.
function GearRules.readyAfter(gearId: GearId, level: number, now: number): number
	return now + GearRules.cooldownSeconds(gearId, level)
end

-- Grapple ---------------------------------------------------------------------------------------

--[[
	Is a landing at `target` within the grapple's reach from `from` (both server positions)?
	Range is horizontal; the landing may sit at most maxRise above the take-off. Line of sight and
	ground are the server's raycasts; bounds and Lockdown are separate checks.
]]
function GearRules.checkGrapple(level: number, from: Point3, target: Point3): (boolean, string?)
	if not (finite(from.x) and finite(from.y) and finite(from.z)) then
		return false, GearRules.Reason.BadRequest
	end
	if not (finite(target.x) and finite(target.y) and finite(target.z)) then
		return false, GearRules.Reason.BadRequest
	end
	local horizontal = dist(from.x, from.z, target.x, target.z)
	if horizontal < 1 then
		return false, GearRules.Reason.BadRequest -- nowhere to go
	end
	if horizontal > GearRules.value("grapple", "range", level) then
		return false, GearRules.Reason.OutOfRange
	end
	if target.y - from.y > G.items.grapple.maxRise then
		return false, GearRules.Reason.TooHigh
	end
	return true, nil
end

-- Is a pocket-local landing on the floor, clear of the walls?
function GearRules.pocketLandingOk(x: number, z: number): boolean
	local edge = P.size / 2 - 2
	return finite(x) and finite(z) and math.abs(x) <= edge and math.abs(z) <= edge
end

-- Smoke -----------------------------------------------------------------------------------------

export type Cloud = { x: number, z: number, radius: number, endsAt: number }

function GearRules.newSmoke(level: number, x: number, z: number, now: number): Cloud
	return {
		x = x,
		z = z,
		radius = GearRules.value("smoke", "radius", level),
		endsAt = now + GearRules.value("smoke", "seconds", level),
	}
end

function GearRules.inSmoke(clouds: { Cloud }, x: number, z: number, now: number): boolean
	for _, cloud in clouds do
		if now < cloud.endsAt and dist(cloud.x, cloud.z, x, z) <= cloud.radius then
			return true
		end
	end
	return false
end

-- How close the owner must come to tag a live carrier (RaidRules.CarryStep.tagRange).
function GearRules.carrierTagRange(inSmoke: boolean): number
	local range = Config.LiveRaid.tagRange
	return if inSmoke then range * G.items.smoke.tagRangeShare else range
end

-- Decoy -----------------------------------------------------------------------------------------

export type Decoy = {
	x: number, -- where it started
	z: number,
	dirX: number, -- unit direction on X/Z
	dirZ: number,
	speed: number,
	startedAt: number,
	endsAt: number,
}

-- A decoy starting at (x, z), running along (dirX, dirZ). A direction without length (or not
-- finite) runs along -z, toward the back of a pocket and away from its gate.
function GearRules.newDecoy(level: number, x: number, z: number, dirX: number, dirZ: number, now: number): Decoy
	local length = math.sqrt(dirX * dirX + dirZ * dirZ)
	local ux, uz = 0, -1
	if finite(length) and length > 1e-6 then
		ux, uz = dirX / length, dirZ / length
	end
	return {
		x = x,
		z = z,
		dirX = ux,
		dirZ = uz,
		speed = G.items.decoy.speed,
		startedAt = now,
		endsAt = now + GearRules.value("decoy", "seconds", level),
	}
end

function GearRules.decoyActive(decoy: Decoy?, now: number): boolean
	return decoy ~= nil and now < decoy.endsAt
end

-- Where the decoy is at `now` (it stops where it ended). `bound`: keep |x| and |z| within it.
function GearRules.decoyAt(decoy: Decoy, now: number, bound: number?): Point
	local t = math.clamp(now, decoy.startedAt, decoy.endsAt) - decoy.startedAt
	local x = decoy.x + decoy.dirX * decoy.speed * t
	local z = decoy.z + decoy.dirZ * decoy.speed * t
	if bound then
		return { x = math.clamp(x, -bound, bound), z = math.clamp(z, -bound, bound) }
	end
	return { x = x, z = z }
end

-- Speed coil ------------------------------------------------------------------------------------

export type Coil = { factor: number, endsAt: number }

function GearRules.newCoil(level: number, now: number): Coil
	return {
		factor = 1 + GearRules.value("speedCoil", "speedBonus", level),
		endsAt = now + GearRules.value("speedCoil", "seconds", level),
	}
end

-- The factor to set on the humanoid now: 1 without a running coil.
function GearRules.coilFactor(coil: Coil?, now: number): number
	return if coil and now < coil.endsAt then coil.factor else 1
end

-- The factor the speed checks allow now: the coil's until coilGraceSeconds after it ends.
function GearRules.coilAllowedFactor(coil: Coil?, now: number): number
	return if coil and now < coil.endsAt + G.coilGraceSeconds then coil.factor else 1
end

--[[
	Walk speed with a coil factor. `current` is the speed without gear (base walking, or the carry
	speed). A carrier is never sped past max(base, current): the owner on foot can always close in.
]]
function GearRules.walkSpeed(base: number, current: number, carrying: boolean, factor: number): number
	local f = if finite(factor) and factor >= 1 then factor else 1
	local boosted = current * f
	return if carrying then math.min(boosted, math.max(base, current)) else boosted
end

-- Lockpick --------------------------------------------------------------------------------------

-- X/Z studs from (x, z) to a den's footprint: 0 on or inside it.
function GearRules.borderDistance(plot: number, x: number, z: number): number
	local cx, cz = Plots.center(plot)
	local half = Plots.Layout.plotSize / 2
	local dx = math.max(math.abs(x - cx) - half, 0)
	local dz = math.max(math.abs(z - cz) - half, 0)
	return math.sqrt(dx * dx + dz * dz)
end

-- The pass a finished pick gives: entry into that den for that one Lockdown.
export type Pass = { ownerUserId: number, lockdownStartedAt: number }

function GearRules.passValid(pass: Pass?, ownerUserId: number?, lockdown: RaidRules.Lockdown?): boolean
	return pass ~= nil
		and ownerUserId ~= nil
		and lockdown ~= nil
		and pass.ownerUserId == ownerUserId
		and pass.lockdownStartedAt == lockdown.startedAt
end

export type PickStart = {
	lockdown: RaidRules.Lockdown?, -- the den's current Lockdown state (server memory)
	now: number, -- same clock as the Lockdown
	isOwner: boolean,
	inside: boolean, -- the picker stands in that den now
	borderDistance: number,
	pass: Pass?, -- the picker's current pass, if any
	ownerUserId: number,
}

function GearRules.canStartPick(p: PickStart): (boolean, string?)
	if p.isOwner then
		return false, GearRules.Reason.OwnDen
	end
	if not RaidRules.lockdownActive(p.lockdown, p.now) then
		return false, GearRules.Reason.NoLockdown
	end
	if p.inside then
		return false, GearRules.Reason.AlreadyInside
	end
	if GearRules.passValid(p.pass, p.ownerUserId, p.lockdown) then
		return false, GearRules.Reason.AlreadyPicked
	end
	if not (p.borderDistance <= G.items.lockpick.range) then
		return false, GearRules.Reason.NotNearDen
	end
	return true, nil
end

export type Pick = {
	plot: number,
	ownerUserId: number,
	lockdownStartedAt: number,
	x: number, -- where the picker stood at the start
	z: number,
	startedAt: number,
	doneAt: number,
}

function GearRules.newPick(
	level: number,
	plot: number,
	ownerUserId: number,
	lockdown: RaidRules.Lockdown,
	x: number,
	z: number,
	now: number
): Pick
	return {
		plot = plot,
		ownerUserId = ownerUserId,
		lockdownStartedAt = lockdown.startedAt,
		x = x,
		z = z,
		startedAt = now,
		doneAt = now + GearRules.value("lockpick", "pickSeconds", level),
	}
end

export type PickOutcome = "Continue" | "Done" | "Interrupted"
export type PickStep = {
	now: number,
	x: number, -- picker root part, server position
	z: number,
	ownerUserId: number?, -- the den's owner now
	lockdown: RaidRules.Lockdown?, -- the den's Lockdown now
	ownerDistance: number?, -- owner to the picker on X/Z; nil = owner has no character
	carrying: boolean,
}

-- One server sample of a pick. First match wins: the Lockdown (or owner) changed or ended, the
-- picker moved or picked something up, the owner caught them, then done.
function GearRules.pickStep(pick: Pick, s: PickStep): (PickOutcome, string?)
	local lockdown = s.lockdown
	if
		s.ownerUserId ~= pick.ownerUserId
		or lockdown == nil
		or lockdown.startedAt ~= pick.lockdownStartedAt
		or not RaidRules.lockdownActive(lockdown, s.now)
	then
		return "Interrupted", GearRules.Reason.NoLockdown
	end
	if s.carrying or not (dist(pick.x, pick.z, s.x, s.z) <= G.items.lockpick.moveTolerance) then
		return "Interrupted", GearRules.Reason.Moved
	end
	if s.ownerDistance and s.ownerDistance <= Config.LiveRaid.tagRange then
		return "Interrupted", GearRules.Reason.Caught
	end
	if s.now >= pick.doneAt then
		return "Done", nil
	end
	return "Continue", nil
end

-- Pocket guards ---------------------------------------------------------------------------------

--[[
	One guard tick with gear in play (mutates `g`, like RaidRules.guardStep). `raider` is the
	raider's pocket-local position (nil = none), `hidden` whether they stand in smoke, `decoy`
	the decoy's position (nil = none running).
	  - A guard that sees the decoy (guardSightRange, or guardLoseRange while chasing) chases it.
	  - Otherwise a hidden raider is unseen: the guard patrols and an alert does not lead it.
	  - Otherwise RaidRules.guardStep as before.
	A guard always tags a raider within guardTagRange, hidden or not. Returns (raider tagged,
	decoy reached): the caller pops a reached decoy.
]]
function GearRules.pocketGuardStep(
	g: RaidRules.GuardState,
	route: { RaidRules.Point },
	raider: Point?,
	hidden: boolean,
	decoy: Point?,
	dt: number,
	alerted: boolean
): (boolean, boolean)
	local function touching(): boolean
		return raider ~= nil and dist(g.x, g.z, raider.x, raider.z) <= P.guardTagRange
	end
	if touching() then
		return true, false
	end
	if decoy then
		local d = dist(g.x, g.z, decoy.x, decoy.z)
		if d <= (if g.chasing then P.guardLoseRange else P.guardSightRange) then
			local reached = RaidRules.guardStep(g, route, decoy.x, decoy.z, dt, false)
			return touching(), reached
		end
	end
	if raider and not hidden then
		return RaidRules.guardStep(g, route, raider.x, raider.z, dt, alerted), false
	end
	RaidRules.guardStep(g, route, nil, nil, dt, false)
	return touching(), false
end

return GearRules
