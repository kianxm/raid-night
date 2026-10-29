--!strict
local expect = require("../lib/expect")
local Profile = require("../../src/Shared/Profile")
local OnboardingMath = require("../../src/Client/Hud/OnboardingMath")

local tests = {}

tests["every server onboarding step has exactly one hint"] = function()
	for _, step in Profile.ONBOARDING_STEPS do
		local hint = OnboardingMath.hintFor({ step = 0, nextStepId = step.id, complete = false })
		expect.truthy(hint, `hint for {step.id}`)
		expect.eq((hint :: any).stepId, step.id, "same id")
	end
end

tests["only the client step has a Got it button, only the steal step an arrow"] = function()
	local function h(id: string): any
		return OnboardingMath.hintFor({ step = 1, nextStepId = id, complete = false })
	end
	expect.eq(h("raidLogTip").ack, true, "tip acks")
	expect.eq(h("hatch").ack, false, "hatch is server-decided")
	expect.eq(h("stealHome").arrow, true, "arrow on steal")
	expect.eq(h("buyEgg").arrow, false, "no arrow on buy")
end

tests["no hint for finished, old-save, unknown or malformed status"] = function()
	expect.eq(OnboardingMath.hintFor({ step = 6, complete = true }), nil, "complete")
	expect.eq(OnboardingMath.hintFor({ step = 3, nextStepId = "buyEgg", complete = true }), nil, "complete wins")
	expect.eq(OnboardingMath.hintFor({ step = 2, nextStepId = "newThing", complete = false }), nil, "unknown id")
	expect.eq(OnboardingMath.hintFor({ step = 2, complete = false }), nil, "no next id")
	expect.eq(OnboardingMath.hintFor(nil), nil, "nil")
	expect.eq(OnboardingMath.hintFor("x"), nil, "string")
end

tests["arrow points ahead, left, right and behind relative to the camera"] = function()
	-- Camera looks down +Z: +X is on the left.
	expect.near(OnboardingMath.arrowDegrees(0, 1, 0, 10), 0, 0.001, "ahead")
	expect.near(OnboardingMath.arrowDegrees(0, 1, 10, 0), -90, 0.001, "left")
	expect.near(OnboardingMath.arrowDegrees(0, 1, -10, 0), 90, 0.001, "right")
	expect.near(math.abs(OnboardingMath.arrowDegrees(0, 1, 0, -10)), 180, 0.001, "behind")
	-- Camera looks down -Z (Roblox default): +X is on the right.
	expect.near(OnboardingMath.arrowDegrees(0, -1, 10, 0), 90, 0.001, "+X is right when looking -Z")
end

tests["arrow handles zero offset and zero look"] = function()
	expect.eq(OnboardingMath.arrowDegrees(0, 1, 0, 0), 0, "on top of it")
	expect.eq(OnboardingMath.arrowDegrees(0, 0, 5, 5), 0, "looking straight down")
end

tests["distance rounds to 5 studs"] = function()
	expect.eq(OnboardingMath.roundedDistance(3, 4), 5, "5")
	expect.eq(OnboardingMath.roundedDistance(0, 12), 10, "12 -> 10")
	expect.eq(OnboardingMath.roundedDistance(0, 13), 15, "13 -> 15")
	expect.eq(OnboardingMath.roundedDistance(0, 1), 0, "near")
end

return tests
