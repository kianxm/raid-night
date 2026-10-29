--!strict
local expect = require("../lib/expect")
local DenStatusMath = require("../../src/Client/Hud/DenStatusMath")
local Strings = require("../../src/Client/Hud/Strings")

local tests = {}

tests["own-den chip copy (D-036) is not a today promise"] = function()
	expect.eq(Strings.protectedOwn, "Protected from steals")
	expect.falsy(string.find(string.lower(Strings.protected .. Strings.protectedOwn), "today", 1, true), "no today")
end

tests["protected wins over the countdown"] = function()
	expect.eq(DenStatusMath.markerText(true, 150, 100), "Protected", "protected")
end

tests["countdown shows while readyAt is in the future"] = function()
	expect.eq(DenStatusMath.markerText(nil, 142, 100), "Safe for 0:42", "future")
	expect.eq(DenStatusMath.markerText(false, 100.2, 100), "Safe for 0:01", "rounds up")
end

tests["hidden when absent, past or malformed"] = function()
	expect.eq(DenStatusMath.markerText(nil, nil, 100), nil, "absent")
	expect.eq(DenStatusMath.markerText(false, 100, 100), nil, "now")
	expect.eq(DenStatusMath.markerText(false, 50, 100), nil, "past")
	expect.eq(DenStatusMath.markerText(false, 0 / 0, 100), nil, "nan")
	expect.eq(DenStatusMath.markerText("yes", "soon", 100), nil, "wrong types")
end

tests["refusal copy"] = function()
	expect.eq(DenStatusMath.refusalText("LiveProtected", nil, 100), "Protected", "protected")
	expect.eq(DenStatusMath.refusalText("PostLossSafety", 165, 100), "Safe for 1:05", "countdown")
	expect.eq(DenStatusMath.refusalText("PostLossSafety", nil, 100), "Someone is already stealing here", "absent")
	expect.eq(DenStatusMath.refusalText("PostLossSafety", 90, 100), "Someone is already stealing here", "past")
	expect.eq(DenStatusMath.refusalText("DefenderLossCap", nil, 100), nil, "other reasons untouched")
end

return tests
