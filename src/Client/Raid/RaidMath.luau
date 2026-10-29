--!strict
--[[
	RaidMath (owner: ui agent): pure display helpers for the raid screens. Nothing here decides
	an outcome; the server owns every real value.
]]

local RaidMath = {}

-- Power buckets for the "what is inside" hint. Placeholder until RaidTarget carries real loot
-- info (see PR handoff). Thresholds are display-only.
function RaidMath.hintKey(power: number): string
	if power >= 5000 then
		return "hintRich"
	elseif power >= 1000 then
		return "hintSolid"
	end
	return "hintSmall"
end

-- 125 -> "2:05". Never negative.
function RaidMath.clock(seconds: number): string
	local s = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", s // 60, s % 60)
end

-- "5m", "3h", "2d" for how long ago something happened.
function RaidMath.ago(seconds: number): string
	local s = math.max(0, seconds)
	if s < 3600 then
		return `{math.max(1, math.floor(s / 60))}m`
	elseif s < 86400 then
		return `{math.floor(s / 3600)}h`
	end
	return `{math.floor(s / 86400)}d`
end

-- Degrees to rotate an up-pointing arrow so it points at `to` as seen from a camera looking
-- along `look`. Flattened to the ground plane. 0 = straight ahead, positive = clockwise (right).
function RaidMath.arrowDegrees(look: Vector3, from: Vector3, to: Vector3): number
	local fx, fz = look.X, look.Z
	local dx, dz = to.X - from.X, to.Z - from.Z
	if (fx == 0 and fz == 0) or (dx == 0 and dz == 0) then
		return 0
	end
	-- Camera right on the ground plane is (-fz, fx) for a Y-up right-handed world.
	local forward = fx * dx + fz * dz
	local right = -fz * dx + fx * dz
	return math.deg(math.atan2(right, forward))
end

-- Revenge stays on offer while the token window is open (Config.Revenge.windowSeconds).
function RaidMath.revengeOpen(at: number, now: number, windowSeconds: number): boolean
	return now - at < windowSeconds
end

return RaidMath
