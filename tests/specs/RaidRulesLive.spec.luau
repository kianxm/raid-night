--!strict
-- Live stealing and Lockdown rules (P0.5, decisions D-002, D-003, D-011, D-013, D-014).
local expect = require("../lib/expect")
local fixtures = require("../lib/fixtures")
local RaidRules = require("../../src/Shared/RaidRules")
local Config = require("../../src/Shared/Config")
local Plots = require("../../src/Shared/Plots")

local NOW = 1_800_000_000
local Reason = RaidRules.Reason
local Live = Config.LiveRaid
local NIL = table.freeze({}) -- an override that means "set this field to nil"

local function never(_uid: string): boolean
	return false
end

local function den()
	local owner = fixtures.veteran(2, NOW)
	fixtures.give(owner, fixtures.critter("pad1", "crescent_fox", "Pad", 1))
	fixtures.give(owner, fixtures.critter("pad3", "dusk_mouse", "Pad", 3))
	fixtures.give(owner, fixtures.critter("vault1", "storm_hare", "Vault"))
	fixtures.give(owner, fixtures.critter("guard1", "dusk_mouse", "Guard"))
	fixtures.give(owner, fixtures.critter("inv1", "dusk_mouse", "Inventory"))
	return owner
end

local function grab(overrides: { [string]: any }?): RaidRules.LiveGrab
	local owner = den()
	local g: RaidRules.LiveGrab = {
		flagsAllow = true,
		raiderUserId = 1,
		raiderReady = true,
		ownerUserId = 2,
		ownerProfile = owner,
		lockdownBlocked = false,
		padIndex = 1,
		carrying = false,
		isLocked = never,
		distance = 4,
		now = NOW,
	}
	for key, value in overrides or {} do
		(g :: any)[key] = if value == NIL then nil else value
	end
	return g
end

local function step(overrides: { [string]: any }?): RaidRules.CarryStep
	local s: RaidRules.CarryStep = {
		moved = 1,
		dt = 0.1,
		walkSpeed = 12,
		insideOwnDen = false,
		wasInsideDefenderDen = true,
		insideDefenderDen = true,
		lockdownActive = false,
		ownerDistance = nil,
	}
	for key, value in overrides or {} do
		(s :: any)[key] = value
	end
	return s
end

local tests = {}

-- Grab --------------------------------------------------------------------------------------------

tests["padCritter reads the pad from the profile"] = function()
	local owner = den()
	expect.eq((RaidRules.padCritter(owner, 1) :: any).uid, "pad1")
	expect.eq((RaidRules.padCritter(owner, 3) :: any).uid, "pad3")
	expect.eq(RaidRules.padCritter(owner, 2), nil, "empty pad")
end

tests["padCritter ignores vault, guard and inventory critters even with a stale padIndex"] = function()
	local owner = fixtures.veteran(2, NOW)
	local vault = fixtures.give(owner, fixtures.critter("v", "storm_hare", "Vault"))
	vault.padIndex = 2 -- a stale index must not make it stealable
	expect.eq(RaidRules.padCritter(owner, 2), nil)
end

tests["a valid live grab returns the pad critter"] = function()
	local ok, reason, critter = RaidRules.canGrabLive(grab())
	expect.truthy(ok, `refused: {reason}`)
	expect.eq((critter :: any).uid, "pad1")
end

tests["the kill switch refuses grabs first"] = function()
	local _, reason = RaidRules.canGrabLive(grab({ flagsAllow = false, ownerUserId = 1 }))
	expect.eq(reason, Reason.SwitchedOff)
end

tests["a raider without a den or loaded profile cannot grab"] = function()
	local _, reason = RaidRules.canGrabLive(grab({ raiderReady = false }))
	expect.eq(reason, Reason.RaiderNotReady)
end

tests["empty dens and your own den are refused"] = function()
	local _, empty = RaidRules.canGrabLive(grab({ ownerUserId = NIL }))
	expect.eq(empty, Reason.EmptyDen)
	local _, own = RaidRules.canGrabLive(grab({ raiderUserId = 2 }))
	expect.eq(own, Reason.OwnDen)
end

tests["the owner's profile must be loaded and belong to the owner"] = function()
	local _, missing = RaidRules.canGrabLive(grab({ ownerProfile = NIL }))
	expect.eq(missing, Reason.OwnerNotReady)
	local _, wrong = RaidRules.canGrabLive(grab({ ownerProfile = fixtures.veteran(3, NOW) }))
	expect.eq(wrong, Reason.OwnerNotReady)
end

tests["a raider shut out by a Lockdown cannot grab, even in range"] = function()
	local _, reason = RaidRules.canGrabLive(grab({ lockdownBlocked = true, distance = 1 }))
	expect.eq(reason, Reason.LockdownActive)
end

tests["one carry at a time"] = function()
	local _, reason = RaidRules.canGrabLive(grab({ carrying = true }))
	expect.eq(reason, Reason.AlreadyCarrying)
end

tests["empty pads have nothing to grab; vault critters are never on a pad"] = function()
	local _, reason = RaidRules.canGrabLive(grab({ padIndex = 2 }))
	expect.eq(reason, Reason.NothingOnPad)
	local _, outOfRangePad = RaidRules.canGrabLive(grab({ padIndex = 99 }))
	expect.eq(outOfRangePad, Reason.NothingOnPad)
end

tests["a critter already carried or in escrow is busy"] = function()
	local _, reason = RaidRules.canGrabLive(grab({
		isLocked = function(uid: string)
			return uid == "pad1"
		end,
	}))
	expect.eq(reason, Reason.CritterBusy)
end

tests["owners at today's loss cap cannot be robbed; yesterday's losses do not count"] = function()
	local g = grab()
	local owner = g.ownerProfile :: any
	owner.lossesToday = Config.Limits.maxLossesPerDay
	local _, reason = RaidRules.canGrabLive(g)
	expect.eq(reason, Reason.DefenderLossCap)
	owner.lossDay = RaidRules.dayIndex(NOW) - 1
	expect.truthy((RaidRules.canGrabLive(g)))
	expect.eq(owner.lossesToday, Config.Limits.maxLossesPerDay, "the check never writes the profile")
end

tests["grab range is checked on server distance, inclusive, and NaN is refused"] = function()
	expect.truthy((RaidRules.canGrabLive(grab({ distance = RaidRules.Live.grabRange }))))
	local _, far = RaidRules.canGrabLive(grab({ distance = RaidRules.Live.grabRange + 0.01 }))
	expect.eq(far, Reason.OutOfRange)
	local _, nan = RaidRules.canGrabLive(grab({ distance = 0 / 0 }))
	expect.eq(nan, Reason.OutOfRange)
end

tests["the grab hold is timed by the server"] = function()
	expect.falsy(RaidRules.grabHoldDone(100, 100 + Live.grabHoldSeconds - 0.01))
	expect.truthy(RaidRules.grabHoldDone(100, 100 + Live.grabHoldSeconds))
end

tests["no pad is within grab range of a den edge, so nobody grabs from outside"] = function()
	local L = Plots.Layout
	local half = L.plotSize / 2
	for pad = 1, L.padsPerPlot do
		local x, z = Plots.padLocal(pad)
		local edge = math.min(half - math.abs(x), half - math.abs(z))
		expect.truthy(edge > RaidRules.Live.grabRange, `pad {pad} is {edge} studs from an edge`)
	end
end

-- Carry -------------------------------------------------------------------------------------------

tests["carry speed follows the critter's weight"] = function()
	expect.eq(RaidRules.carryWalkSpeed(16, "Light"), 16 * RaidRules.carrySpeedMultiplier("Light"))
	expect.truthy(RaidRules.carryWalkSpeed(16, "VeryHeavy") < RaidRules.carryWalkSpeed(16, "Heavy"))
	expect.truthy(RaidRules.carryWalkSpeed(16, "Heavy") < RaidRules.carryWalkSpeed(16, "Medium"))
	expect.truthy(RaidRules.carryWalkSpeed(16, "Medium") < RaidRules.carryWalkSpeed(16, "Light"))
end

tests["walking is fine; a teleport is not"] = function()
	expect.truthy(RaidRules.carryMoveOk(12 * 0.1, 0.1, 12))
	expect.truthy(RaidRules.carryMoveOk(8, 0.1, 12), "replication jitter is absorbed")
	expect.falsy(RaidRules.carryMoveOk(20, 0.1, 12), "a 12-stud den gap cannot be skipped")
	expect.falsy(RaidRules.carryMoveOk(0 / 0, 0.1, 12))
end

tests["crossing into your own den is an escape"] = function()
	expect.eq(RaidRules.carryStep(step({ insideOwnDen = true, insideDefenderDen = false })), "Escape")
end

tests["a teleport home is refused before the escape counts"] = function()
	expect.eq(RaidRules.carryStep(step({ insideOwnDen = true, moved = 60 })), "TooFast")
end

tests["the owner within tagRange makes the carrier drop"] = function()
	expect.eq(RaidRules.carryStep(step({ ownerDistance = Live.tagRange })), "Tagged")
	expect.eq(RaidRules.carryStep(step({ ownerDistance = Live.tagRange + 1 })), "Continue")
end

tests["home is safe even with the owner close behind"] = function()
	expect.eq(RaidRules.carryStep(step({ insideOwnDen = true, ownerDistance = 1 })), "Escape")
end

tests["leaving the den during a Lockdown drops the critter at the border"] = function()
	local crossing = { wasInsideDefenderDen = true, insideDefenderDen = false }
	expect.eq(RaidRules.carryStep(step(crossing)), "Continue", "no Lockdown")
	local locked = { wasInsideDefenderDen = true, insideDefenderDen = false, lockdownActive = true }
	expect.eq(RaidRules.carryStep(step(locked)), "DropAtBorder")
	local alreadyOut = { wasInsideDefenderDen = false, insideDefenderDen = false, lockdownActive = true }
	expect.eq(RaidRules.carryStep(step(alreadyOut)), "Continue", "already on the street")
end

-- Lockdown ----------------------------------------------------------------------------------------

tests["a Lockdown lasts lockdownSeconds and the cooldown counts from its end"] = function()
	local l = RaidRules.startLockdown(NOW)
	expect.eq(l.untilAt, NOW + Live.lockdownSeconds)
	expect.eq(l.readyAt, NOW + Live.lockdownSeconds + Live.lockdownCooldownSeconds)
	expect.eq(l.readyAt - NOW, 165, "45 s locked + 120 s cooldown")
end

tests["Lockdown is refused while active and before ReadyAt"] = function()
	expect.truthy((RaidRules.canStartLockdown(nil, NOW)), "the first one is free")
	local l = RaidRules.startLockdown(NOW)
	expect.truthy(RaidRules.lockdownActive(l, l.untilAt - 0.01))
	expect.falsy(RaidRules.lockdownActive(l, l.untilAt))
	expect.falsy(RaidRules.lockdownActive(nil, NOW))
	expect.eq(select(2, RaidRules.canStartLockdown(l, NOW + 1)), Reason.LockdownActive)
	expect.eq(select(2, RaidRules.canStartLockdown(l, l.untilAt)), Reason.LockdownCooldown)
	expect.eq(select(2, RaidRules.canStartLockdown(l, l.readyAt - 0.01)), Reason.LockdownCooldown)
	expect.truthy((RaidRules.canStartLockdown(l, l.readyAt)))
end

tests["an owner spamming Lockdown is locked at most 45 s in any 165 s"] = function()
	local locks: { RaidRules.Lockdown } = {}
	local current: RaidRules.Lockdown? = nil
	for t = 0, 2000, 0.25 do
		if RaidRules.canStartLockdown(current, t) then
			current = RaidRules.startLockdown(t)
			table.insert(locks, current :: RaidRules.Lockdown)
		end
	end
	expect.truthy(#locks >= 12, "spam still gets regular lockdowns")
	for w = 0, 2000, 0.25 do
		local locked = 0
		for _, l in locks do
			locked += math.max(0, math.min(l.untilAt, w + 165) - math.max(l.startedAt, w))
		end
		expect.truthy(locked <= 45 + 1e-9, `window at {w} locked {locked} s`)
	end
end

tests["Lockdown blocks entry for every raider, revenge included, but not the owner"] = function()
	local l = RaidRules.startLockdown(NOW)
	local t = NOW + 1
	expect.truthy(RaidRules.entryBlocked(l, t, false, false, false, true), "a raider walking in")
	expect.truthy(RaidRules.entryBlocked(l, t, false, true, false, true), "revenge does not bypass (D-013)")
	expect.falsy(RaidRules.entryBlocked(l, t, true, false, false, true), "the owner walks in")
	expect.falsy(RaidRules.entryBlocked(nil, t, false, false, false, true), "no Lockdown")
	expect.falsy(RaidRules.entryBlocked(l, l.untilAt, false, false, false, true), "Lockdown over")
end

tests["raiders already inside may stay and leave; leaving and coming back is blocked"] = function()
	local l = RaidRules.startLockdown(NOW)
	local t = NOW + 1
	expect.falsy(RaidRules.entryBlocked(l, t, false, false, true, true), "inside at the last sample")
	expect.falsy(RaidRules.entryBlocked(l, t, false, false, true, false), "walking out")
	expect.truthy(RaidRules.entryBlocked(l, t + 1, false, false, false, true), "walking back in")
end

return tests
