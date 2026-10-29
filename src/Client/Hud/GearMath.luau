--!strict
--[[
	GearMath (owner: ui agent): pure helpers for the gear bar. Display only: the server decides
	every use, cooldown and charge; these only read what GetGear / UseGear answered. No Roblox
	services, so Lune can test it.
]]

local GearMath = {}

export type Slot = {
	id: string,
	level: number,
	readyAt: number,
	charges: number?,
	liveOnly: boolean,
}

-- Seconds until `readyAt` (server time) against the server clock `now`; 0 = ready.
function GearMath.remaining(readyAt: number, now: number): number
	if readyAt ~= readyAt or readyAt <= 0 then
		return 0
	end
	return math.max(0, readyAt - now)
end

-- The slots to draw: owned ones only, in the server's order. A lockpick is hidden in an async
-- raid (charges present) because the server would refuse it (LiveOnly).
function GearMath.visible(slots: { Slot }): { Slot }
	local out = {}
	for _, slot in slots do
		if slot.level >= 1 and not (slot.liveOnly and slot.charges ~= nil) then
			table.insert(out, slot)
		end
	end
	return out
end

export type State = "Ready" | "Cooling" | "Spent"

function GearMath.state(slot: Slot, now: number): State
	if slot.charges ~= nil and slot.charges < 1 then
		return "Spent"
	end
	if GearMath.remaining(slot.readyAt, now) > 0 then
		return "Cooling"
	end
	return "Ready"
end

-- Button edge for `count` slots in a screen `width` px wide. The bar sits between the thumbstick
-- (`leftKeepClear`) and the action column (`rightKeepClear`); it shrinks to 44 px (thumb size)
-- rather than cross either.
function GearMath.slotSize(width: number, count: number, leftKeepClear: number, rightKeepClear: number): number
	local gap = 6
	local room = width - leftKeepClear - rightKeepClear - gap * math.max(0, count - 1)
	return math.clamp(math.floor(room / math.max(1, count)), 44, 56)
end

-- Seconds as the cooldown shows it: whole seconds, rounded up, never "0".
function GearMath.secondsText(seconds: number): string
	return tostring(math.max(1, math.ceil(seconds)))
end

-- GearRules.Reason -> Strings key. Anything unknown gets the generic line.
local REASON_KEYS: { [string]: string } = {
	Cooldown = "gearCooldown",
	NoCharges = "gearNoCharges",
	Carrying = "gearCarrying",
	Trapped = "gearTrapped",
	OutOfRange = "gearOutOfRange",
	TooHigh = "gearOutOfRange",
	NoLineOfSight = "gearNoSight",
	OutOfBounds = "gearNoSight",
	LiveOnly = "gearLiveOnly",
	SwitchedOff = "gearOff",
}

function GearMath.reasonKey(reason: string?): string
	return REASON_KEYS[reason or ""] or "gearRefused"
end

return GearMath
