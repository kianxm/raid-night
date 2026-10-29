--!strict
--[[
	HudMath (owner: ui agent): tiny pure helpers for the HUD. Display only. The server decides
	every real value; these just format and predict between DenChanged pushes.
]]

local HudMath = {}

-- Predicted stored Glow for display: min(cap, stored + rate * elapsed). Snap to the server
-- value on each push (reset `elapsed` to 0).
function HudMath.predictStored(stored: number, cap: number, rate: number, elapsed: number): number
	return math.min(cap, stored + rate * math.max(0, elapsed))
end

local UNITS: { { any } } = { { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }

-- 1234 -> "1.2K", 15300000 -> "15.3M". Floors, so we never show Glow the player lacks.
function HudMath.abbreviate(n: number): string
	n = math.floor(math.max(0, n))
	for _, unit in UNITS do
		local size = unit[1] :: number
		if n >= size then
			local v = math.floor(n / size * 10) / 10
			local s = if v == math.floor(v) then tostring(math.floor(v)) else string.format("%.1f", v)
			return s .. (unit[2] :: string)
		end
	end
	return tostring(n)
end

-- Seconds -> "m:ss" (or "h:mm:ss").
function HudMath.clock(seconds: number): string
	local s = math.max(0, math.ceil(seconds))
	local h, m = s // 3600, (s % 3600) // 60
	if h > 0 then
		return string.format("%d:%02d:%02d", h, m, s % 60)
	end
	return string.format("%d:%02d", m, s % 60)
end

return HudMath
