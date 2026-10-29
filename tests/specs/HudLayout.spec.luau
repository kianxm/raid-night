--!strict
local expect = require("../lib/expect")
local HudLayout = require("../../src/Client/Hud/HudLayout")

local tests = {}

tests["touch devices always get the phone layout"] = function()
	expect.eq(HudLayout.mode(true, false), "phone", "phone")
	expect.eq(HudLayout.mode(true, true), "phone", "touch laptop")
	expect.eq(HudLayout.mode(false, false), "phone", "gamepad only")
	expect.eq(HudLayout.mode(false, true), "desktop", "pc")
end

tests["hotbar has keys 1-6 then Q set apart"] = function()
	expect.eq(#HudLayout.SLOTS, 7, "seven slots")
	for i = 1, 6 do
		expect.eq(HudLayout.SLOTS[i].keyLabel, tostring(i), `key {i}`)
		expect.eq(HudLayout.SLOTS[i].apart, false, `slot {i} together`)
	end
	expect.eq(HudLayout.SLOTS[7].keyLabel, "Q", "last key")
	expect.eq(HudLayout.SLOTS[7].action, "lockdown", "lockdown on Q")
	expect.eq(HudLayout.SLOTS[7].apart, true, "Q apart")
end

tests["hotbar is centered and Q has the wider gap on the PC canvas"] = function()
	local bar = HudLayout.hotbar(1440)
	expect.eq(bar.slotSize, HudLayout.HOTBAR_MAX, "full size at 1440")
	expect.eq(bar.left + bar.width + bar.left, 1440, "centered")
	expect.eq(bar.xs[2] - bar.xs[1], bar.slotSize + bar.gap, "normal gap")
	expect.eq(bar.xs[7] - bar.xs[6], bar.slotSize + bar.apartGap, "Q gap")
	expect.eq(bar.xs[7] + bar.slotSize, bar.left + bar.width, "bar ends at Q")
end

tests["hotbar shrinks to fit a narrow window but never below the floor"] = function()
	local narrow = HudLayout.hotbar(1100)
	expect.truthy(narrow.slotSize < HudLayout.HOTBAR_MAX, "shrinks")
	expect.truthy(narrow.slotSize >= HudLayout.HOTBAR_MIN, "floor")
	expect.truthy(narrow.left >= 0, "on screen")
	expect.eq(HudLayout.hotbar(600).slotSize, HudLayout.HOTBAR_MIN, "floor at tiny widths")
end

tests["storage bar is gold only when full"] = function()
	expect.eq(HudLayout.storageTone(0.99), "normal", "almost")
	expect.eq(HudLayout.storageTone(1), "full", "full")
end

return tests
