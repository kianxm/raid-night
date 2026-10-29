--!strict
local expect = require("../lib/expect")
local GearMath = require("../../src/Client/Hud/GearMath")
local Strings = require("../../src/Client/Hud/Strings")

local tests = {}

local function slot(id: string, level: number, readyAt: number?, charges: number?, liveOnly: boolean?)
	return { id = id, level = level, readyAt = readyAt or 0, charges = charges, liveOnly = liveOnly == true }
end

tests["remaining counts down to ready and never goes negative"] = function()
	expect.eq(GearMath.remaining(0, 100), 0, "0 = ready")
	expect.eq(GearMath.remaining(95, 100), 0, "past")
	expect.eq(GearMath.remaining(112.5, 100), 12.5, "future")
	expect.eq(GearMath.remaining(0 / 0, 100), 0, "NaN")
end

tests["only owned gear shows, and a lockpick hides in an async raid"] = function()
	local slots = {
		slot("grapple", 1),
		slot("smoke", 0),
		slot("lockpick", 2, 0, nil, true),
	}
	expect.eq(#GearMath.visible(slots), 2, "live: owned two")
	slots[3] = slot("lockpick", 2, 0, 0, true)
	local shown = GearMath.visible(slots)
	expect.eq(#shown, 1, "async: lockpick hidden")
	expect.eq(shown[1].id, "grapple", "grapple stays")
end

tests["state reads the cooldown and the async charges"] = function()
	expect.eq(GearMath.state(slot("grapple", 1), 50), "Ready", "ready")
	expect.eq(GearMath.state(slot("grapple", 1, 60), 50), "Cooling", "cooling")
	expect.eq(GearMath.state(slot("grapple", 1, 0, 0), 50), "Spent", "no charges")
	expect.eq(GearMath.state(slot("grapple", 1, 0, 1), 50), "Ready", "one charge")
end

tests["slots stay thumb-sized and clear of the thumbstick and action column"] = function()
	for width = 320, 1000, 20 do
		for count = 1, 6 do
			local size = GearMath.slotSize(width, count, 190, 150)
			expect.truthy(size >= 44 and size <= 56, `size {size} at {width} x {count}`)
		end
	end
	expect.eq(GearMath.slotSize(900, 5, 190, 150), 56, "roomy")
	expect.eq(GearMath.slotSize(600, 6, 190, 150), 44, "tight")
end

tests["seconds round up and never show zero"] = function()
	expect.eq(GearMath.secondsText(0.2), "1", "tiny")
	expect.eq(GearMath.secondsText(12.1), "13", "rounds up")
end

tests["every refusal reason maps to a real string"] = function()
	for _, reason in
		{
			"Cooldown",
			"NoCharges",
			"Carrying",
			"Trapped",
			"OutOfRange",
			"TooHigh",
			"NoLineOfSight",
			"OutOfBounds",
			"LiveOnly",
			"SwitchedOff",
			"Weird",
		}
	do
		local key = GearMath.reasonKey(reason)
		expect.truthy((Strings :: any)[key] ~= nil, `{reason} -> {key}`)
	end
	expect.eq(GearMath.reasonKey(nil), "gearRefused", "nil")
end

return tests
