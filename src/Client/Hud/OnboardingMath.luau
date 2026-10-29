--!strict
--[[
	OnboardingMath (owner: ui agent): pure helpers for the first-5-minutes hints (Appendix C).
	Maps the server's onboarding step to one hint and aims the guidance arrow. No Roblox
	services, so Lune can test it. The server decides progress; this only picks what to show.
]]

local OnboardingMath = {}

export type Hint = {
	stepId: string,
	stringKey: string, -- key into Strings
	arrow: boolean, -- point at the tutorial den
	ack: boolean, -- show a "Got it" button that sends AckOnboarding (client-only step)
}

-- One hint per step id (Profile.ONBOARDING_STEPS). Unknown ids show nothing, so a step added
-- later on the server never breaks an older client.
local HINTS: { [string]: Hint } = {
	hatch = { stepId = "hatch", stringKey = "obHatch", arrow = false, ack = false },
	place = { stepId = "place", stringKey = "obPlace", arrow = false, ack = false },
	collect = { stepId = "collect", stringKey = "obCollect", arrow = false, ack = false },
	buyEgg = { stepId = "buyEgg", stringKey = "obBuyEgg", arrow = false, ack = false },
	stealHome = { stepId = "stealHome", stringKey = "obSteal", arrow = true, ack = false },
	raidLogTip = { stepId = "raidLogTip", stringKey = "obRaidLog", arrow = false, ack = true },
}

-- The hint for an OnboardingStatus, or nil when none should show (old player, finished, bad data).
function OnboardingMath.hintFor(status: any): Hint?
	if type(status) ~= "table" or status.complete ~= false then
		return nil
	end
	local id = status.nextStepId
	if type(id) ~= "string" then
		return nil
	end
	return HINTS[id]
end

-- Clockwise screen rotation in degrees for an arrow that points at a target. `look` is the
-- camera's horizontal look direction, `dx`/`dz` the offset to the target. 0 = straight ahead,
-- 90 = to the right, 180 = behind. An offset of zero points ahead.
function OnboardingMath.arrowDegrees(lookX: number, lookZ: number, dx: number, dz: number): number
	local len = math.sqrt(lookX * lookX + lookZ * lookZ)
	if len < 1e-6 or (dx == 0 and dz == 0) then
		return 0
	end
	local fx, fz = lookX / len, lookZ / len
	local ahead = dx * fx + dz * fz
	local right = dx * -fz + dz * fx -- the camera's right is look x up = (-fz, fx)
	return math.deg(math.atan2(right, ahead))
end

-- Distance in studs rounded to the nearest 5, for "12 studs" style text (never below 0).
function OnboardingMath.roundedDistance(dx: number, dz: number): number
	local d = math.sqrt(dx * dx + dz * dz)
	return math.floor(d / 5 + 0.5) * 5
end

return OnboardingMath
