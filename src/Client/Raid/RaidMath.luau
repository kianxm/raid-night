--!strict
--[[
	RaidMath (owner: ui agent): pure display helpers for the raid screens. Nothing here decides
	an outcome; the server owns every real value.
]]

local RaidMath = {}

-- Loot hint from RaidTarget.topTier (highest tier on the den's pads). nil = nothing known.
-- Never an exact Glow number.
function RaidMath.hintKey(topTier: string?): string
	if topTier == nil then
		return "hintUnknown"
	elseif topTier == "Common" or topTier == "Uncommon" then
		return "hintSmall"
	elseif topTier == "Rare" or topTier == "Epic" then
		return "hintSolid"
	end
	return "hintRich"
end

-- Why a live revenge join failed: the Strings key, and whether the async revenge raid is still
-- on offer (Net.luau: not for SwitchedOff, Invalid, NoToken, Expired, Unavailable, PairLimit).
local NO_FALLBACK: { [string]: boolean } =
	{ SwitchedOff = true, Invalid = true, NoToken = true, Expired = true, Unavailable = true, PairLimit = true }
local FAIL_KEYS: { [string]: string } = {
	SwitchedOff = "failSwitchedOff",
	Invalid = "failInvalid",
	NoToken = "failNoToken",
	Expired = "failExpired",
	Unavailable = "failUnavailable",
	PairLimit = "failPairLimit",
	Busy = "failBusy",
	RaiderOffline = "failRaiderOffline",
	ServerFull = "failServerFull",
	ServerGone = "failServerGone",
	TeleportFailed = "failTeleport",
}

function RaidMath.failKey(reason: string?): string
	return FAIL_KEYS[reason or ""] or "failTeleport"
end

function RaidMath.fallbackOffered(reason: string?): boolean
	return NO_FALLBACK[reason or ""] ~= true
end

-- Outcome card title key for RaidEnd. `escaped` is true only once the loot has moved.
function RaidMath.outcomeKey(reason: string?, escaped: boolean): string
	if escaped then
		return "raidEscaped"
	elseif reason == "Timeout" then
		return "raidTimeout"
	elseif reason == "Retreat" then
		return "raidRetreat"
	elseif reason == "Left" then
		return "raidLeft"
	elseif reason == "Error" then
		return "raidError"
	elseif reason == "Escaped" then
		return "stealUnconfirmed" -- reached the gate but the move is not confirmed
	end
	return "raidCaught" -- Tagged, or anything unknown
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
