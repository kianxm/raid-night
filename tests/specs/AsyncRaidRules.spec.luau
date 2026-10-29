--!strict
-- Async raids in pocket dens (P1.3): start checks, pocket layout, guards, traps, movement, grabs.
local expect = require("../lib/expect")
local fixtures = require("../lib/fixtures")
local RaidRules = require("../../src/Shared/RaidRules")
local Matchmaking = require("../../src/Shared/Matchmaking")
local Profile = require("../../src/Shared/Profile")
local Config = require("../../src/Shared/Config")
local Types = require("../../src/Shared/Types")

local NOW = 1_800_000_000
local Reason = RaidRules.Reason
local P = RaidRules.Pocket

local function setup()
	local raider = fixtures.veteran(1, NOW)
	local defender = fixtures.veteran(2, NOW)
	fixtures.give(defender, fixtures.critter("pad1", "crescent_fox", "Pad", 1))
	fixtures.give(defender, fixtures.critter("pad2", "dusk_mouse", "Pad", 2))
	fixtures.give(defender, fixtures.critter("vault1", "storm_hare", "Vault"))
	fixtures.give(defender, fixtures.critter("guard1", "dusk_mouse", "Guard"))
	defender.stored = 1000
	local snapshot = Matchmaking.buildSnapshot(defender, NOW)
	return raider, defender, snapshot
end

local function start(raider: Types.PlayerProfile, snapshot: Types.DenSnapshot?, over: { [string]: any }?)
	local a: RaidRules.AsyncStart = {
		flagsAllow = true,
		raider = raider,
		hasDen = true,
		busy = false,
		targetUserId = 2,
		snapshot = snapshot,
		raiderBlocked = nil,
		defenderOnline = false,
		defenderLossesToday = 0,
		revengeRaidId = nil,
		now = NOW,
	}
	for k, v in over or {} do
		(a :: any)[k] = v
	end
	if (a :: any).noRaider then
		a.raider = nil
	end
	return RaidRules.canStartAsync(a)
end

local tests = {}

tests["a normal async raid can start"] = function()
	local raider, _, snapshot = setup()
	local ok, reason, token = start(raider, snapshot)
	expect.truthy(ok, `refused: {reason}`)
	expect.eq(token, nil)
end

tests["start refusals, in order"] = function()
	local raider, _, snapshot = setup()
	expect.eq(select(2, start(raider, snapshot, { flagsAllow = false })), Reason.SwitchedOff)
	expect.eq(select(2, start(raider, snapshot, { noRaider = true })), Reason.RaiderNotReady)
	expect.eq(select(2, start(raider, snapshot, { hasDen = false })), Reason.RaiderNotReady)
	expect.eq(select(2, start(raider, snapshot, { busy = true })), Reason.AlreadyRaiding)
	expect.eq(select(2, start(raider, snapshot, { targetUserId = 1 })), Reason.Self)
	expect.eq(select(2, start(raider, nil)), Reason.NoSnapshot)
	expect.eq(select(2, start(raider, snapshot, { targetUserId = 3 })), Reason.NoSnapshot, "snapshot of someone else")
	expect.eq(select(2, start(raider, snapshot, { defenderOnline = true })), Reason.DefenderOnline)
	expect.eq(
		select(2, start(raider, snapshot, { defenderLossesToday = Config.Limits.maxLossesPerDay })),
		Reason.DefenderLossCap
	)
end

tests["blocks refuse both ways, whatever the target list said"] = function()
	local raider, _, snapshot = setup()
	expect.eq(select(2, start(raider, snapshot, { raiderBlocked = { 2 } })), Reason.Blocked, "raider blocked them")
	snapshot.blockedUserIds = { 1 }
	expect.eq(select(2, start(raider, snapshot)), Reason.Blocked, "they blocked the raider")
end

tests["a revenge id must be the raider's own open token against this target"] = function()
	local raider, _, snapshot = setup()
	snapshot.shieldUntil = NOW + 3600
	expect.eq(select(2, start(raider, snapshot)), Reason.Shielded)
	expect.eq(select(2, start(raider, snapshot, { revengeRaidId = "nope" })), Reason.RevengeExpired)
	raider.revengeTokens.other = { raidId = "other", targetUserId = 9, expiresAt = NOW + 60, shieldBypassUsed = false }
	expect.eq(select(2, start(raider, snapshot, { revengeRaidId = "other" })), Reason.RevengeExpired, "wrong target")
	raider.revengeTokens.old = { raidId = "old", targetUserId = 2, expiresAt = NOW, shieldBypassUsed = false }
	expect.eq(select(2, start(raider, snapshot, { revengeRaidId = "old" })), Reason.RevengeExpired, "expired")
	raider.revengeTokens.r = { raidId = "r", targetUserId = 2, expiresAt = NOW + 60, shieldBypassUsed = false }
	local ok, reason, token = start(raider, snapshot, { revengeRaidId = "r" })
	expect.truthy(ok, `refused: {reason}`)
	expect.eq((token :: any).raidId, "r")
end

tests["a den with nothing on its pads cannot be raided"] = function()
	local raider, defender = setup()
	defender.critters.pad1 = nil
	defender.critters.pad2 = nil
	expect.eq(select(2, start(raider, Matchmaking.buildSnapshot(defender, NOW))), Reason.NothingOnPad)
end

tests["fresh presence means online"] = function()
	expect.truthy(RaidRules.presenceFresh(NOW - 10, NOW))
	expect.falsy(RaidRules.presenceFresh(NOW - P.presenceFreshSeconds, NOW))
	expect.falsy(RaidRules.presenceFresh(nil, NOW))
end

tests["the client view holds pad critters only, with no Glow or block list"] = function()
	local _, _, snapshot = setup()
	snapshot.blockedUserIds = { 77 }
	local view = RaidRules.pocketView(snapshot)
	expect.eq(#view, 2)
	expect.eq(view[1].uid, "pad1")
	expect.eq(view[2].uid, "pad2")
	for _, row in view do
		local keys = 0
		for key in row :: any do
			keys += 1
			expect.truthy(key == "uid" or key == "speciesId" or key == "mutation" or key == "padIndex", key)
		end
		expect.eq(keys, 4)
	end
end

tests["layout: pads, traps clamped onto the floor, one route per guard, capped"] = function()
	local _, defender = setup()
	fixtures.give(defender, fixtures.critter("bad", "dusk_mouse", "Pad", 99))
	fixtures.give(defender, fixtures.critter("zdup", "dusk_mouse", "Pad", 1))
	for i = 1, 6 do
		fixtures.give(defender, fixtures.critter(`g{i}`, "dusk_mouse", "Guard"))
	end
	for i = 1, 20 do
		table.insert(defender.traps, { kind = "Net", level = i, gridX = i - 5, gridY = 100 })
	end
	local snapshot = Matchmaking.buildSnapshot(defender, NOW)
	local layout = RaidRules.pocketLayout(snapshot)
	expect.truthy(layout.pads[1] and layout.pads[2])
	expect.eq(layout.pads[99], nil, "a pad the pocket cannot lay out")
	expect.eq(layout.uids.bad, nil)
	expect.eq(layout.uids.zdup, nil, "a second critter on pad 1 is not grabbable")
	expect.eq(#layout.traps, P.maxTraps)
	for _, trap in layout.traps do
		expect.truthy(math.abs(trap.x) < P.size / 2 and math.abs(trap.z) < P.size / 2)
		expect.truthy(trap.level <= 10)
		expect.truthy(trap.z <= P.spawnZ - 8, "no trap on the spawn")
	end
	expect.eq(#layout.guardRoutes, P.maxGuards)
	for padIndex = 1, P.maxPads do
		local pad = RaidRules.pocketPad(padIndex) :: RaidRules.Point
		expect.truthy(
			math.abs(pad.x) < P.size / 2 and pad.z < P.spawnZ,
			`pad {padIndex} on the floor, behind the spawn`
		)
	end
end

tests["guards patrol, chase what they see, give up, and tag"] = function()
	local route = { { x = -10, z = 0 }, { x = 10, z = 0 } }
	local g = RaidRules.newGuard(route)
	for _ = 1, 40 do
		expect.falsy(RaidRules.guardStep(g, route, nil, nil, 0.1, false))
	end
	expect.truthy(g.x > -10, "walked along its line")
	expect.falsy(g.chasing)
	-- A raider in sight gets chased; far away is forgotten.
	expect.falsy(RaidRules.guardStep(g, route, g.x + P.guardSightRange - 1, 0, 0.1, false))
	expect.truthy(g.chasing)
	RaidRules.guardStep(g, route, g.x + P.guardLoseRange + 5, 0, 0.1, false)
	expect.falsy(g.chasing)
	-- An alert makes it chase from anywhere.
	RaidRules.guardStep(g, route, g.x + 100, 0, 0.1, true)
	expect.truthy(g.chasing)
	-- A standing raider is caught.
	local tagged = false
	local rx, rz = g.x + 10, g.z
	for _ = 1, 100 do
		tagged = RaidRules.guardStep(g, route, rx, rz, 0.1, false) or tagged
		if tagged then
			break
		end
	end
	expect.truthy(tagged)
	expect.truthy(RaidRules.guardStep(RaidRules.newGuard(route), route, -10, 1, 0, false), "in range tags at once")
end

tests["guards outrun a Medium carry and lose to a walker"] = function()
	expect.truthy(P.guardChaseSpeed > 16 * RaidRules.carrySpeedMultiplier("Medium"))
	expect.truthy(P.guardChaseSpeed < 16)
end

tests["trap effects"] = function()
	expect.eq(RaidRules.trapEffect("Net", 4).slow, 0)
	expect.eq(RaidRules.trapEffect("SlowPuddle", 2).seconds, 3)
	expect.truthy(RaidRules.trapEffect("AlarmMoth", 1).alertSeconds > 0)
	expect.truthy(RaidRules.trapEffect("Trapdoor", 1).sendBack)
	local trap: RaidRules.PocketTrap = { kind = "Net", level = 1, x = 0, z = 0 }
	expect.truthy(RaidRules.trapHit(trap, P.trapRadius, 0))
	expect.falsy(RaidRules.trapHit(trap, P.trapRadius + 0.1, 0))
end

local function step(over: { [string]: any })
	local s: RaidRules.PocketStep = {
		x = 0,
		z = 0,
		height = 3,
		moved = 1,
		dt = 0.1,
		walkSpeed = 12,
		budget = RaidRules.carryStartBudget(),
		carrying = true,
	}
	for k, v in over do
		(s :: any)[k] = v
	end
	return RaidRules.pocketStep(s)
end

tests["pocket movement: a carried teleport to the gate never escapes"] = function()
	expect.eq(step({}), "Continue")
	expect.eq(step({ moved = 40, z = P.gateZ }), "TooFast")
	expect.eq(step({ moved = 40, z = P.gateZ, carrying = false }), "AtGate", "nothing carried: no budget")
	expect.eq(step({ moved = 0 / 0 }), "TooFast", "NaN")
	expect.eq(step({ height = P.maxHeight + 1 }), "TooHigh")
	expect.eq(step({ x = P.size / 2 + P.boundsMargin + 1 }), "OutOfBounds")
	expect.eq(step({ z = P.gateZ - P.gateRadius }), "AtGate")
end

tests["async grabs: timer, carry, snapshot, laid out, range"] = function()
	local _, defender = setup()
	fixtures.give(defender, fixtures.critter("zdup", "dusk_mouse", "Pad", 1))
	local snapshot = Matchmaking.buildSnapshot(defender, NOW)
	local layout = RaidRules.pocketLayout(snapshot)
	local function grab(uid: any, carrying: boolean?, distance: number?, now: number?)
		return RaidRules.canGrabAsync(snapshot, layout, uid, carrying == true, distance or 2, now or NOW, NOW + 10)
	end
	local ok, reason, critter = grab("pad1")
	expect.truthy(ok, `refused: {reason}`)
	expect.eq((critter :: any).uid, "pad1")
	expect.eq(select(2, grab("pad1", false, 2, NOW + 10)), Reason.TimeUp)
	expect.eq(select(2, grab(42)), Reason.BadRequest)
	expect.eq(select(2, grab("pad1", true)), Reason.AlreadyCarrying)
	expect.eq(select(2, grab("vault1")), Reason.NotInSnapshot, "vault critters are never in a snapshot")
	expect.eq(select(2, grab("guard1")), Reason.NotStealable)
	expect.eq(select(2, grab("zdup")), Reason.NotStealable, "not laid out")
	expect.eq(select(2, grab("pad1", false, Config.LiveRaid.grabRange + 0.1)), Reason.OutOfRange)
	expect.eq(select(2, grab("pad1", false, 0 / 0)), Reason.OutOfRange)
end

tests["raidLogSeenAt: an old save without it reads as never"] = function()
	local old = Profile.new(5, NOW)
	expect.eq(RaidRules.raidLogSeenAt(Profile.prepare(old, 5, NOW)), 0)
	old.raidLogSeenAt = NOW - 5
	expect.eq(RaidRules.raidLogSeenAt(old), NOW - 5)
end

return tests
