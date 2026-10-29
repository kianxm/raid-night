--!strict
-- Raider gear rules (P2.10): ownership, raid kind, cooldowns, charges, range, smoke, decoy, coil,
-- lockpick and the guard changes, with the exploit cases a client could try.
local expect = require("../lib/expect")
local GearRules = require("../../src/Shared/GearRules")
local RaidRules = require("../../src/Shared/RaidRules")
local Config = require("../../src/Shared/Config")
local Profile = require("../../src/Shared/Profile")
local Plots = require("../../src/Shared/Plots")

local NOW = 1_800_000_000
local Reason = GearRules.Reason
local G = Config.Gear
local P = RaidRules.Pocket
local NIL = table.freeze({}) -- an override that means "set this field to nil"

local function use(overrides: { [string]: any }?): GearRules.Use
	local u: GearRules.Use = {
		gearId = "smoke",
		level = 1,
		kind = "Live",
		now = NOW,
		readyAt = nil,
		charges = nil,
		carrying = false,
		trapped = false,
		picking = false,
	}
	for key, value in overrides or {} do
		(u :: any)[key] = if value == NIL then nil else value
	end
	return u
end

local function refused(u: GearRules.Use, reason: string, message: string)
	local ok, why = GearRules.canUse(u)
	expect.falsy(ok, message)
	expect.eq(why, reason, message)
end

local tests = {}

-- Config shape ------------------------------------------------------------------------------------

tests["every gear id has a Config item, and every value is positive at every level"] = function()
	for _, id in Profile.GEAR_IDS do
		local item = (G.items :: any)[id]
		expect.truthy(item, `Config.Gear.items.{id}`)
		expect.truthy(item.price > 0, `{id} price`)
		for level = 1, G.maxLevel do
			expect.truthy(GearRules.cooldownSeconds(id, level) > 0, `{id} cooldown at {level}`)
			for key, value in item do
				if type(value) == "number" and not string.find(key, "PerLevel$") and key ~= "asyncCharges" then
					expect.truthy(GearRules.value(id, key, level) > 0, `{id}.{key} at level {level}`)
				end
			end
		end
	end
	for id in G.items :: any do
		expect.truthy(Profile.isGearId(id), `no Config item without a gear id ({id})`)
	end
end

tests["no effect outlasts its own cooldown, so one player never has two of a kind running"] = function()
	for level = 1, G.maxLevel do
		for _, pair in
			{
				{ "smoke", "seconds" },
				{ "decoy", "seconds" },
				{ "speedCoil", "seconds" },
				{ "lockpick", "pickSeconds" },
			}
		do
			local id, key = pair[1] :: any, pair[2]
			expect.truthy(
				GearRules.value(id, key, level) + G.coilGraceSeconds < GearRules.cooldownSeconds(id, level),
				`{id} at {level}`
			)
		end
	end
end

tests["gear tuning is frozen"] = function()
	expect.truthy(table.isfrozen(G.items.grapple))
	expect.throws(function()
		(G.items.grapple :: any).range = 999
	end)
end

tests["levels clamp to 1..maxLevel; a corrupt level reads as 1"] = function()
	expect.eq(GearRules.value("grapple", "range", 1), 24)
	expect.eq(GearRules.value("grapple", "range", 3), 30)
	expect.eq(GearRules.value("grapple", "range", 99), GearRules.value("grapple", "range", G.maxLevel))
	expect.eq(GearRules.value("grapple", "range", 0 / 0), 24)
	expect.eq(GearRules.value("grapple", "range", -4), 24)
	expect.eq(GearRules.value("grapple", "range", 2.7), 27)
end

-- Upgrade costs (the spend itself is economy's) ------------------------------------------------------

tests["upgrade cost: price to buy, growing per level, nil at max or for bad input"] = function()
	expect.eq(GearRules.upgradeCost("smoke", 0), G.items.smoke.price)
	expect.eq(GearRules.upgradeCost("smoke", 1), math.floor(G.items.smoke.price * G.upgradeCostGrowth + 0.5))
	local last = 0
	for level = 0, G.maxLevel - 1 do
		local cost = GearRules.upgradeCost("lockpick", level) :: number
		expect.truthy(cost > last, `cost rises at {level}`)
		last = cost
	end
	expect.eq(GearRules.upgradeCost("smoke", G.maxLevel), nil, "max level")
	expect.eq(GearRules.upgradeCost("jetpack", 0), nil, "unknown id")
	expect.eq(GearRules.upgradeCost("smoke", -1), nil, "negative")
	expect.eq(GearRules.upgradeCost("smoke", 1.5), nil, "fraction")
	expect.eq(GearRules.upgradeCost("smoke", 0 / 0), nil, "NaN")
	expect.eq(GearRules.upgradeCost("smoke", "1"), nil, "string")
end

-- Using gear ------------------------------------------------------------------------------------

tests["an owned item off cooldown can be used"] = function()
	expect.truthy((GearRules.canUse(use())))
	expect.truthy((GearRules.canUse(use({ gearId = "lockpick" }))), "lockpick in the live world")
	expect.truthy((GearRules.canUse(use({ kind = "Async", charges = 1 }))), "smoke in a pocket")
end

tests["exploit: unknown or malformed gear ids are refused"] = function()
	for _, id in { "jetpack", "", 5, true, {}, "Smoke", "lockpick ", NIL } do
		refused(use({ gearId = id }), Reason.BadRequest, `gear id {tostring(id)}`)
	end
end

tests["exploit: gear not owned (level 0 or corrupt) is refused"] = function()
	refused(use({ level = 0 }), Reason.NotOwned, "level 0")
	refused(use({ level = 0 / 0 }), Reason.NotOwned, "NaN level")
	refused(use({ level = -1 }), Reason.NotOwned, "negative level")
	-- Through the profile helper, as the server reads it.
	local profile: any = { gear = { smoke = 2, grapple = "9", decoy = 0.5 } }
	expect.eq(Profile.gearLevel(profile, "smoke"), 2)
	refused(use({ gearId = "grapple", level = Profile.gearLevel(profile, "grapple") }), Reason.NotOwned, "string level")
	refused(use({ gearId = "decoy", level = Profile.gearLevel(profile, "decoy") }), Reason.NotOwned, "fraction")
	refused(use({ gearId = "lockpick", level = Profile.gearLevel(profile, "lockpick") }), Reason.NotOwned, "missing")
end

tests["exploit: the lockpick in an async raid is refused (live raids only)"] = function()
	refused(use({ gearId = "lockpick", kind = "Async", charges = 5 }), Reason.LiveOnly, "pocket")
	expect.falsy(GearRules.worksIn("lockpick", "Async"))
	expect.truthy(GearRules.worksIn("lockpick", "Live"))
	expect.eq(GearRules.asyncCharges("lockpick", G.maxLevel), 0)
	for _, id in { "grapple", "smoke", "decoy", "speedCoil" } do
		expect.truthy(GearRules.worksIn(id :: any, "Async"), id)
		expect.truthy(GearRules.worksIn(id :: any, "Live"), id)
	end
	expect.falsy(GearRules.worksIn("smoke", "Trade" :: any), "unknown raid kind")
end

tests["exploit: spam inside the cooldown is refused, and works again right at readyAt"] = function()
	local readyAt = GearRules.readyAfter("smoke", 1, NOW)
	expect.eq(readyAt, NOW + G.items.smoke.cooldownSeconds)
	refused(use({ now = NOW, readyAt = readyAt }), Reason.Cooldown, "same instant")
	refused(use({ now = readyAt - 0.01, readyAt = readyAt }), Reason.Cooldown, "just before")
	refused(use({ now = NOW, readyAt = 0 / 0 }), Reason.Cooldown, "NaN readyAt refuses")
	refused(use({ now = 0 / 0, readyAt = readyAt }), Reason.Cooldown, "NaN now refuses")
	expect.truthy((GearRules.canUse(use({ now = readyAt, readyAt = readyAt }))), "at readyAt")
	expect.truthy(GearRules.readyAfter("smoke", G.maxLevel, NOW) < readyAt, "upgrades shorten it")
end

tests["exploit: async charges run out, and a missing count means none"] = function()
	refused(use({ kind = "Async", charges = 0 }), Reason.NoCharges, "spent")
	refused(use({ kind = "Async", charges = NIL }), Reason.NoCharges, "no count")
	refused(use({ kind = "Async", charges = 0 / 0 }), Reason.NoCharges, "NaN")
	expect.eq(GearRules.asyncCharges("smoke", 1), 1)
	expect.eq(GearRules.asyncCharges("smoke", G.maxLevel), 2)
	expect.truthy((GearRules.canUse(use({ charges = 0 }))), "live use ignores charges")
end

tests["grapple and lockpick need free hands; grapple and coil are refused while a trap holds you"] = function()
	refused(use({ gearId = "grapple", carrying = true }), Reason.Carrying, "grapple carrying")
	refused(use({ gearId = "lockpick", carrying = true }), Reason.Carrying, "lockpick carrying")
	expect.truthy((GearRules.canUse(use({ gearId = "speedCoil", carrying = true }))), "coil while carrying")
	expect.truthy((GearRules.canUse(use({ gearId = "smoke", carrying = true }))), "smoke while carrying")
	expect.truthy((GearRules.canUse(use({ gearId = "decoy", carrying = true }))), "decoy while carrying")
	refused(
		use({ gearId = "grapple", kind = "Async", charges = 1, trapped = true }),
		Reason.Trapped,
		"grapple out of a Net"
	)
	refused(use({ gearId = "speedCoil", kind = "Async", charges = 1, trapped = true }), Reason.Trapped, "coil")
	expect.truthy((GearRules.canUse(use({ kind = "Async", charges = 1, trapped = true }))), "smoke while trapped")
	refused(use({ picking = true }), Reason.Busy, "nothing else while picking")
end

-- Grapple ---------------------------------------------------------------------------------------

local ORIGIN = { x = 0, y = 3, z = 0 }

tests["grapple: in range lands; out of range, too high, NaN or no distance are refused"] = function()
	expect.truthy((GearRules.checkGrapple(1, ORIGIN, { x = 20, y = 3, z = 10 })))
	local ok, why = GearRules.checkGrapple(1, ORIGIN, { x = 24.5, y = 3, z = 0 })
	expect.falsy(ok)
	expect.eq(why, Reason.OutOfRange)
	expect.truthy((GearRules.checkGrapple(G.maxLevel, ORIGIN, { x = 24.5, y = 3, z = 0 })), "range grows")
	ok, why = GearRules.checkGrapple(G.maxLevel, ORIGIN, { x = 10, y = 3 + G.items.grapple.maxRise + 0.1, z = 0 })
	expect.eq(why, Reason.TooHigh, "no roofs")
	expect.truthy((GearRules.checkGrapple(1, ORIGIN, { x = 10, y = -20, z = 0 })), "down is fine")
	for _, bad in { { x = 0 / 0, y = 3, z = 0 }, { x = math.huge, y = 3, z = 0 }, { x = 5, y = 0 / 0, z = 0 } } do
		ok, why = GearRules.checkGrapple(1, ORIGIN, bad)
		expect.eq(why, Reason.BadRequest, "non-finite target")
	end
	ok, why = GearRules.checkGrapple(1, ORIGIN, { x = 0.2, y = 3, z = 0.2 })
	expect.eq(why, Reason.BadRequest, "no distance")
	ok, why = GearRules.checkGrapple(1, { x = 0 / 0, y = 0, z = 0 }, { x = 1, y = 0, z = 5 })
	expect.eq(why, Reason.BadRequest, "non-finite origin")
end

tests["grapple in a pocket must land on the floor"] = function()
	expect.truthy(GearRules.pocketLandingOk(0, 0))
	expect.truthy(GearRules.pocketLandingOk(P.size / 2 - 2, -(P.size / 2 - 2)))
	expect.falsy(GearRules.pocketLandingOk(P.size / 2, 0), "the wall")
	expect.falsy(GearRules.pocketLandingOk(0, P.size), "outside")
	expect.falsy(GearRules.pocketLandingOk(0 / 0, 0), "NaN")
end

-- Smoke -----------------------------------------------------------------------------------------

tests["smoke: covers its radius until it ends; a live carrier inside is tagged at the shrunken range"] = function()
	local cloud = GearRules.newSmoke(1, 10, 10, NOW)
	expect.eq(cloud.radius, 8)
	expect.eq(cloud.endsAt, NOW + 5)
	expect.truthy(GearRules.inSmoke({ cloud }, 15, 10, NOW + 1))
	expect.falsy(GearRules.inSmoke({ cloud }, 19, 10, NOW + 1), "outside the radius")
	expect.falsy(GearRules.inSmoke({ cloud }, 10, 10, NOW + 5), "ended")
	expect.falsy(GearRules.inSmoke({}, 10, 10, NOW), "no clouds")
	expect.eq(GearRules.carrierTagRange(false), Config.LiveRaid.tagRange)
	local shrunk = GearRules.carrierTagRange(true)
	expect.eq(shrunk, Config.LiveRaid.tagRange * G.items.smoke.tagRangeShare)
	expect.truthy(shrunk > 0, "smoke never makes a carrier untaggable")
end

tests["smoke reaches the carry tag check through CarryStep.tagRange"] = function()
	local function at(distance: number, range: number?): string
		local outcome = RaidRules.carryStep({
			moved = 1,
			dt = 0.1,
			walkSpeed = 12,
			budget = RaidRules.carryStartBudget(),
			height = 3,
			insideOwnDen = false,
			wasInsideDefenderDen = false,
			insideDefenderDen = false,
			crossedStreet = true,
			lockdownActive = false,
			ownerDistance = distance,
			tagRange = range,
		})
		return outcome
	end
	expect.eq(at(5, nil), "Tagged", "no smoke: the usual range")
	expect.eq(at(5, GearRules.carrierTagRange(true)), "Continue", "smoke: 5 studs is too far")
	expect.eq(at(2, GearRules.carrierTagRange(true)), "Tagged", "smoke: close enough still tags")
end

-- Decoy -----------------------------------------------------------------------------------------

tests["decoy: runs straight at its speed, stops when it ends, and stays in bounds"] = function()
	local decoy = GearRules.newDecoy(1, 0, 0, 3, 4, NOW)
	expect.near(decoy.dirX, 0.6, 1e-9)
	expect.near(decoy.dirZ, 0.8, 1e-9)
	local p = GearRules.decoyAt(decoy, NOW + 1)
	expect.near(p.x, 0.6 * G.items.decoy.speed, 1e-9)
	expect.near(p.z, 0.8 * G.items.decoy.speed, 1e-9)
	local last = GearRules.decoyAt(decoy, decoy.endsAt + 100)
	local stop = GearRules.decoyAt(decoy, decoy.endsAt)
	expect.eq(last.x, stop.x, "stops at the end")
	local early = GearRules.decoyAt(decoy, NOW - 50)
	expect.eq(early.x, 0, "never before its start")
	local bounded = GearRules.decoyAt(decoy, decoy.endsAt, 10)
	expect.truthy(bounded.x <= 10 and bounded.z <= 10, "clamped to the pocket")
	expect.truthy(GearRules.decoyActive(decoy, NOW + 1))
	expect.falsy(GearRules.decoyActive(decoy, decoy.endsAt))
	expect.falsy(GearRules.decoyActive(nil, NOW))
	local still = GearRules.newDecoy(1, 0, 0, 0, 0, NOW)
	expect.eq(still.dirZ, -1, "no direction: runs along -z")
	local nan = GearRules.newDecoy(1, 0, 0, 0 / 0, 1, NOW)
	expect.eq(nan.dirZ, -1, "NaN direction too")
end

-- Speed coil ------------------------------------------------------------------------------------

tests["coil: boosts while it runs; the speed checks allow it for the grace after"] = function()
	local coil = GearRules.newCoil(1, NOW)
	expect.near(coil.factor, 1 + G.items.speedCoil.speedBonus, 1e-9)
	expect.eq(GearRules.coilFactor(coil, NOW + 1), coil.factor)
	expect.eq(GearRules.coilFactor(coil, coil.endsAt), 1, "set speed drops at the end")
	expect.eq(GearRules.coilAllowedFactor(coil, coil.endsAt), coil.factor, "checks still allow it")
	expect.eq(GearRules.coilAllowedFactor(coil, coil.endsAt + G.coilGraceSeconds), 1, "until the grace ends")
	expect.eq(GearRules.coilFactor(nil, NOW), 1)
	expect.eq(GearRules.coilAllowedFactor(nil, NOW), 1)
end

tests["coil: a carrier is never sped past normal walking; free movement is boosted fully"] = function()
	local base = 16
	local factor = GearRules.newCoil(G.maxLevel, NOW).factor
	expect.near(GearRules.walkSpeed(base, base, false, factor), base * factor, 1e-9, "not carrying")
	local light = RaidRules.carryWalkSpeed(base, "Light") -- 14.4
	expect.eq(GearRules.walkSpeed(base, light, true, factor), base, "Light carry capped at walking")
	local heavy = RaidRules.carryWalkSpeed(base, "VeryHeavy") -- 7.2
	expect.near(GearRules.walkSpeed(base, heavy, true, factor), heavy * factor, 1e-9, "slow carries gain")
	expect.eq(GearRules.walkSpeed(base, heavy, true, 0 / 0), heavy, "a NaN factor is none")
	expect.eq(GearRules.walkSpeed(base, heavy, true, 0.2), heavy, "a coil never slows")
end

tests["exploit: a coil-speed carry passes the budget, and the same pace without a coil fails"] = function()
	local base = 16
	local carry = RaidRules.carryWalkSpeed(base, "Heavy") -- 9.6
	local coil = GearRules.newCoil(1, 0)
	local boosted = GearRules.walkSpeed(base, carry, true, coil.factor)
	local function run(allowedSpeed: number, seconds: number): string
		local budget = RaidRules.carryStartBudget()
		local outcome = "Continue"
		for _ = 1, math.floor(seconds / 0.1) do
			outcome, budget = RaidRules.carryStep({
				moved = boosted * 0.1,
				dt = 0.1,
				walkSpeed = allowedSpeed,
				budget = budget,
				height = 3,
				insideOwnDen = false,
				wasInsideDefenderDen = false,
				insideDefenderDen = false,
				crossedStreet = true,
				lockdownActive = false,
				ownerDistance = nil,
			})
			if outcome ~= "Continue" then
				break
			end
		end
		return outcome
	end
	expect.eq(run(boosted, 8), "Continue", "the checks know the coil")
	expect.eq(run(carry, 8), "TooFast", "without it the same pace is a speed hack")
end

-- Lockpick --------------------------------------------------------------------------------------

local function lockdownAt(start: number): RaidRules.Lockdown
	return RaidRules.startLockdown(start)
end

local function pickStart(overrides: { [string]: any }?): GearRules.PickStart
	local p: GearRules.PickStart = {
		lockdown = lockdownAt(NOW - 5),
		now = NOW,
		isOwner = false,
		inside = false,
		borderDistance = 3,
		pass = nil,
		ownerUserId = 2,
	}
	for key, value in overrides or {} do
		(p :: any)[key] = if value == NIL then nil else value
	end
	return p
end

tests["lockpick start: only outside a locked-down den, near its border, once per Lockdown"] = function()
	expect.truthy((GearRules.canStartPick(pickStart())))
	local cases: { { any } } = {
		{ { isOwner = true }, Reason.OwnDen },
		{ { lockdown = NIL }, Reason.NoLockdown },
		{ { lockdown = lockdownAt(NOW - Config.LiveRaid.lockdownSeconds) }, Reason.NoLockdown },
		{ { inside = true }, Reason.AlreadyInside },
		{ { pass = { ownerUserId = 2, lockdownStartedAt = NOW - 5 } }, Reason.AlreadyPicked },
		{ { borderDistance = G.items.lockpick.range + 0.1 }, Reason.NotNearDen },
		{ { borderDistance = 0 / 0 }, Reason.NotNearDen },
	}
	for i, case in cases do
		local ok, why = GearRules.canStartPick(pickStart(case[1]))
		expect.falsy(ok, `case {i}`)
		expect.eq(why, case[2], `case {i}`)
	end
	local stale = pickStart({ pass = { ownerUserId = 2, lockdownStartedAt = NOW - 500 } })
	expect.truthy((GearRules.canStartPick(stale)), "an old Lockdown's pass does not count")
end

tests["lockpick: completes after pickSeconds unless moved, caught, carrying or the Lockdown ends"] = function()
	local lockdown = lockdownAt(NOW - 5)
	local pick = GearRules.newPick(1, 3, 2, lockdown, 10, 10, NOW)
	expect.eq(pick.doneAt, NOW + G.items.lockpick.pickSeconds)
	expect.truthy(GearRules.newPick(G.maxLevel, 3, 2, lockdown, 0, 0, NOW).doneAt < pick.doneAt, "faster upgraded")
	local function stepWith(overrides: { [string]: any }): (string, string?)
		local s: GearRules.PickStep = {
			now = NOW + 1,
			x = 10,
			z = 10,
			ownerUserId = 2,
			lockdown = lockdown,
			ownerDistance = 30,
			carrying = false,
		}
		for key, value in overrides do
			(s :: any)[key] = if value == NIL then nil else value
		end
		return GearRules.pickStep(pick, s)
	end
	expect.eq(stepWith({}), "Continue")
	expect.eq(stepWith({ now = pick.doneAt }), "Done")
	expect.eq(select(2, stepWith({ x = 13 })), Reason.Moved)
	expect.eq(select(2, stepWith({ x = 0 / 0 })), Reason.Moved, "NaN position")
	expect.eq(select(2, stepWith({ carrying = true })), Reason.Moved)
	expect.eq(select(2, stepWith({ ownerDistance = Config.LiveRaid.tagRange })), Reason.Caught)
	expect.eq(stepWith({ ownerDistance = NIL }), "Continue", "an owner without a character catches nobody")
	expect.eq(select(2, stepWith({ lockdown = NIL })), Reason.NoLockdown)
	expect.eq(select(2, stepWith({ ownerUserId = 9 })), Reason.NoLockdown, "the den changed hands")
	expect.eq(select(2, stepWith({ lockdown = lockdownAt(NOW) })), Reason.NoLockdown, "a new Lockdown")
	local ended = NOW - 5 + Config.LiveRaid.lockdownSeconds
	expect.eq(select(2, stepWith({ now = ended })), Reason.NoLockdown, "Lockdown over")
	expect.eq(select(1, stepWith({ now = pick.doneAt, ownerDistance = 1 })), "Interrupted", "caught at the end")
end

tests["lockpick pass: valid for that den's Lockdown only"] = function()
	local lockdown = lockdownAt(NOW)
	local pass = { ownerUserId = 2, lockdownStartedAt = NOW }
	expect.truthy(GearRules.passValid(pass, 2, lockdown))
	expect.falsy(GearRules.passValid(pass, 3, lockdown), "another den")
	expect.falsy(GearRules.passValid(pass, 2, lockdownAt(NOW + 200)), "the next Lockdown")
	expect.falsy(GearRules.passValid(nil, 2, lockdown))
	expect.falsy(GearRules.passValid(pass, nil, lockdown))
	expect.falsy(GearRules.passValid(pass, 2, nil))
	-- A pass lets the picker in: Lockdown's entry check with the pass counted as the owner's.
	expect.truthy(RaidRules.entryBlocked(lockdown, NOW + 1, false, false, false, true), "no pass: pushed out")
	local exempt = GearRules.passValid(pass, 2, lockdown)
	expect.falsy(RaidRules.entryBlocked(lockdown, NOW + 1, exempt, false, false, true), "pass: let in")
end

tests["a pass never opens the way out: a carry across the border during the Lockdown drops"] = function()
	local outcome = RaidRules.carryStep({
		moved = 1,
		dt = 0.1,
		walkSpeed = 12,
		budget = RaidRules.carryStartBudget(),
		height = 3,
		insideOwnDen = false,
		wasInsideDefenderDen = true,
		insideDefenderDen = false,
		crossedStreet = false,
		lockdownActive = true,
		ownerDistance = nil,
	})
	expect.eq(outcome, "DropAtBorder")
end

tests["border distance: 0 inside, straight out from an edge, diagonal at a corner"] = function()
	local cx, cz = Plots.center(1)
	local half = Plots.Layout.plotSize / 2
	expect.eq(GearRules.borderDistance(1, cx, cz), 0)
	expect.eq(GearRules.borderDistance(1, cx + half, cz), 0, "on the border")
	expect.near(GearRules.borderDistance(1, cx + half + 4, cz), 4, 1e-9)
	expect.near(GearRules.borderDistance(1, cx + half + 3, cz + half + 4), 5, 1e-9)
end

-- Pocket guards ---------------------------------------------------------------------------------

local ROUTE = { { x = -20, z = 0 }, { x = 20, z = 0 } }

local function guardAt(x: number, z: number, chasing: boolean?): RaidRules.GuardState
	return { x = x, z = z, chasing = chasing or false, leg = 2 }
end

tests["guards: without gear they behave exactly like RaidRules.guardStep"] = function()
	local a, b = guardAt(0, 0), guardAt(0, 0)
	local tagged = GearRules.pocketGuardStep(a, ROUTE, { x = 0, z = 10 }, false, nil, 0.1, false)
	local plain = RaidRules.guardStep(b, ROUTE, 0, 10, 0.1, false)
	expect.eq(tagged, plain)
	expect.eq(a.x, b.x)
	expect.eq(a.z, b.z)
	expect.eq(a.chasing, b.chasing)
end

tests["guards: smoke hides the raider (even from an alert), but walking into them still tags"] = function()
	local g = guardAt(0, 0, true)
	local tagged = GearRules.pocketGuardStep(g, ROUTE, { x = 0, z = 8 }, true, nil, 0.1, true)
	expect.falsy(tagged)
	expect.falsy(g.chasing, "lost the raider")
	expect.eq(g.z, 0, "patrols its line instead of closing in")
	local close = guardAt(0, 0)
	expect.truthy((GearRules.pocketGuardStep(close, ROUTE, { x = 0, z = 3 }, true, nil, 0.1, false)), "touching")
end

tests["guards: a visible decoy pulls a guard off the raider, and reaching it pops it"] = function()
	local g = guardAt(0, 0, true)
	local tagged, reached = GearRules.pocketGuardStep(g, ROUTE, { x = 0, z = 8 }, false, { x = 0, z = -8 }, 0.1, false)
	expect.falsy(tagged)
	expect.falsy(reached)
	expect.truthy(g.z < 0, "heads for the decoy")
	local near = guardAt(0, 0)
	local _, popped = GearRules.pocketGuardStep(near, ROUTE, { x = 0, z = 20 }, false, { x = 0, z = 1 }, 0.1, false)
	expect.truthy(popped, "decoy reached")
	local far = guardAt(0, 0)
	GearRules.pocketGuardStep(far, ROUTE, { x = 0, z = 8 }, false, { x = 0, z = -40 }, 0.1, false)
	expect.truthy(far.z > 0, "a decoy out of sight changes nothing")
	local busy = guardAt(0, 0, true)
	local caught = GearRules.pocketGuardStep(busy, ROUTE, { x = 0, z = 2 }, false, { x = 0, z = -8 }, 0.1, false)
	expect.truthy(caught, "a raider standing next to the guard is still tagged")
end

return tests
