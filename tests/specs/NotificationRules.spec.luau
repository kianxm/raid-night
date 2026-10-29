--!strict
local expect = require("../lib/expect")
local Rules = require("../../src/Shared/NotificationRules")

local DAY = Rules.SECONDS_PER_DAY
local NOW = 100 * DAY + 5000

local function critterLoss(): Rules.LossEvent
	return { kind = "Critter", raidId = "raid-1", raiderName = "Nox", critterName = "Moth" }
end

local tests = {}

-- The storage category ships off; the storage specs switch it on and restore it.
local function withStorageOn(fn: () -> ())
	Rules.ENABLED_CATEGORIES.storage = true
	local ok, err = pcall(fn)
	Rules.ENABLED_CATEGORIES.storage = false
	if not ok then
		error(err, 0)
	end
end

tests["storage send is refused while its category is off (default)"] = function()
	expect.eq(Rules.ENABLED_CATEGORIES.storage, false)
	local d = Rules.decideStorage({ glowLossPending = true }, 100, 100, 0.9, NOW, true)
	expect.eq(d.action, "Skip")
	expect.eq(d.reason, "CategoryOff")
end

tests["first critter lost sends a revenge notification"] = function()
	local d = Rules.decideLoss({}, critterLoss(), NOW, true)
	expect.eq(d.action, "Send")
	expect.eq(d.category, "revenge")
end

tests["second loss the same day is skipped, next day is free"] = function()
	local state = Rules.afterSend({}, "revenge", true, NOW)
	expect.eq(Rules.decideLoss(state, critterLoss(), NOW + 3600, true).reason, "DailyCapSpent")
	expect.eq(Rules.decideLoss(state, critterLoss(), NOW + DAY, true).action, "Send")
end

tests["a failed send does not spend the daily slot"] = function()
	local state = Rules.afterSend({}, "revenge", false, NOW)
	expect.eq(Rules.decideLoss(state, critterLoss(), NOW, true).action, "Send")
end

tests["flag off skips everything"] = function()
	expect.eq(Rules.decideLoss({}, critterLoss(), NOW, false).action, "Skip")
	expect.eq(Rules.decideStorage({ glowLossPending = true }, 90, 100, 0.9, NOW, false).action, "Skip")
	expect.falsy(Rules.shouldPromptOptIn({}, 1, NOW, false))
end

tests["glow-only loss is held, then one combined send at 90 percent"] = function()
	withStorageOn(function()
		local ev: Rules.LossEvent = { kind = "Glow", raidId = "raid-2" }
		expect.eq(Rules.decideLoss({}, ev, NOW, true).action, "Hold")
		local state = Rules.afterGlowLoss({})
		expect.eq(Rules.decideStorage(state, 89, 100, 0.9, NOW, true).reason, "StorageNotFull")
		local d = Rules.decideStorage(state, 90, 100, 0.9, NOW, true)
		expect.eq(d.action, "Send")
		expect.eq(d.category, "storage")
		local after = Rules.afterSend(state, "storage", true, NOW)
		expect.eq(after.glowLossPending, false)
		expect.eq(Rules.decideStorage(after, 100, 100, 0.9, NOW + DAY, true).reason, "NothingPending")
	end)
end

tests["storage send waits for a free daily slot and keeps the pending flag"] = function()
	withStorageOn(function()
		local state = Rules.afterGlowLoss(Rules.afterSend({}, "revenge", true, NOW))
		expect.eq(Rules.decideStorage(state, 100, 100, 0.9, NOW, true).reason, "DailyCapSpent")
		expect.eq(Rules.decideStorage(state, 100, 100, 0.9, NOW + DAY, true).action, "Send")
	end)
end

tests["storage send does not clear pending when it fails"] = function()
	local state = Rules.afterGlowLoss({})
	expect.eq(Rules.afterSend(state, "storage", false, NOW).glowLossPending, true)
end

tests["opt-in prompt only after the first successful raid, once per 30 days"] = function()
	expect.falsy(Rules.shouldPromptOptIn({}, 0, NOW, true), "never on first join")
	expect.truthy(Rules.shouldPromptOptIn({}, 1, NOW, true))
	expect.falsy(Rules.shouldPromptOptIn({}, 2, NOW, true))
	local prompted = Rules.afterPrompt({}, NOW)
	expect.falsy(Rules.shouldPromptOptIn(prompted, 1, NOW + 29 * DAY, true))
	expect.truthy(Rules.shouldPromptOptIn(prompted, 1, NOW + 30 * DAY, true))
end

tests["copy params are cleaned and missing ones skip the send"] = function()
	expect.eq(Rules.cleanParam("  Nox{}\n "), "Nox")
	expect.eq(Rules.cleanParam("   "), nil)
	expect.eq(#(Rules.cleanParam(string.rep("a", 80)) :: string), Rules.MAX_PARAM_LENGTH)
	local ev = critterLoss()
	ev.raiderName = nil
	expect.eq(Rules.decideLoss({}, ev, NOW, true).reason, "MissingCopyParams")
end

tests["launch data round trips the raidId and rejects other data"] = function()
	expect.eq(Rules.parseLaunchData(Rules.launchData("abc-123_X")), "abc-123_X")
	expect.eq(Rules.parseLaunchData("revenge:"), nil)
	expect.eq(Rules.parseLaunchData("revenge:bad id!"), nil)
	expect.eq(Rules.parseLaunchData("other:abc"), nil)
	expect.eq(Rules.parseLaunchData(42), nil)
	expect.eq(Rules.parseLaunchData("revenge:" .. string.rep("a", 60)), nil)
	expect.truthy(#Rules.launchData(string.rep("a", 43)) <= Rules.MAX_LAUNCH_DATA)
end

return tests
