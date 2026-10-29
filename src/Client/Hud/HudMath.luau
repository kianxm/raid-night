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

-- The rescue-egg rule, in one place so the "Free" label and the odds line cannot disagree.
-- Mirrors Economy.isRescueEgg from DenState: no critters and Glow (incl. predicted stored)
-- below the egg price. Display only; the server decides the real egg.
function HudMath.isRescue(critterCount: number, glow: number, stored: number, price: number): boolean
	return critterCount == 0 and math.floor(glow + stored) < price
end

-- Actions column fit (#54). The column is 3 buttons + the odds chip + 3 gaps, anchored above
-- the jump button (`reserve` px kept clear at the bottom) and must stay below the top inset
-- (`topMargin`). `height` is the usable ScreenGui height (CoreUISafeInsets already removes the
-- Roblox top bar). Layouts go from roomiest to most compact; the last is the floor.
export type ColumnLayout = {
	name: string,
	button: number,
	chip: number,
	gap: number,
	reserve: number,
	compact: boolean,
	chipText: number, -- odds chip text size
}

HudMath.COLUMN_TOP_MARGIN = 8

local COLUMN_LAYOUTS: { ColumnLayout } = {
	-- The odds chip lists up to 6 tiers (Common to Mythic): full = a title + 6 lines, compact = 3
	-- rows of two tiers, tight = the same in 11 px text for the shortest phone screens.
	{ name = "full", button = 58, chip = 132, gap = 8, reserve = 150, compact = false, chipText = 14 },
	{ name = "compact", button = 46, chip = 50, gap = 6, reserve = 120, compact = true, chipText = 12 },
	{ name = "tight", button = 44, chip = 44, gap = 4, reserve = 100, compact = true, chipText = 11 },
}

function HudMath.columnHeight(layout: ColumnLayout): number
	return layout.button * 3 + layout.chip + layout.gap * 3
end

-- First layout whose column (plus reserve and top margin) fits `height`; else the compact floor.
function HudMath.columnLayout(height: number): ColumnLayout
	for _, layout in COLUMN_LAYOUTS do
		if HudMath.columnHeight(layout) + layout.reserve + HudMath.COLUMN_TOP_MARGIN <= height then
			return layout
		end
	end
	return COLUMN_LAYOUTS[#COLUMN_LAYOUTS]
end

-- Odds chip text for compact layouts: entries ("C 55%") packed `perRow` to a line, so six tiers
-- take three short lines instead of one that truncates.
function HudMath.chipRows(entries: { string }, perRow: number): string
	local rows: { string } = {}
	for i = 1, #entries, perRow do
		table.insert(rows, table.concat(entries, "  ", i, math.min(i + perRow - 1, #entries)))
	end
	return table.concat(rows, "\n")
end

-- Top edge of the column from the top of the usable area (negative = overflows).
function HudMath.columnTop(height: number, layout: ColumnLayout): number
	return height - layout.reserve - HudMath.columnHeight(layout)
end

-- "Each" line for n equally likely species: the true value rounded to 2 decimals, never forced
-- to sum to 100 (#55). 9 -> "11.11%", 10 -> "10%", 3 -> "33.33%".
function HudMath.eachLabel(n: number): string
	local text = string.format("%.2f", 100 / math.max(1, n))
	text = string.gsub(text, "0+$", "")
	text = string.gsub(text, "%.$", "")
	return text .. "%"
end

-- Chances (0..1, summing to 1) -> percent strings that visibly sum to 100%.
-- Rounding: work in hundredths of a percent, floor each, then give the leftover hundredths
-- to the largest remainders (ties to the earlier entry). Trailing zeros are trimmed, so
-- 0.6875 -> "68.75%", 0.5 -> "50%", 1 -> "100%". Pure; inputs are the Economy odds helpers.
function HudMath.percentLabels(chances: { number }): { string }
	local units: { number } = {}
	local remainders: { number } = {}
	local used = 0
	for i, c in chances do
		local exact = c * 10000
		local floored = math.floor(exact + 1e-9)
		units[i] = floored
		remainders[i] = exact - floored
		used += floored
	end
	local leftover = 10000 - used
	while leftover > 0 and #chances > 0 do
		local best = 1
		for i = 2, #chances do
			if remainders[i] > remainders[best] then
				best = i
			end
		end
		units[best] += 1
		remainders[best] = -1
		leftover -= 1
	end
	local labels: { string } = {}
	for i, u in units do
		local text = string.format("%.2f", u / 100)
		if string.find(text, ".", 1, true) then
			text = string.gsub(text, "0+$", "")
			text = string.gsub(text, "%.$", "")
		end
		labels[i] = text .. "%"
	end
	return labels
end

return HudMath
