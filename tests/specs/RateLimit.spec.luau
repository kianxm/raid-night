--!strict
-- RateLimit: the fixed-window per-player request limits behind Net.Limits (C6b).
local expect = require("../lib/expect")
local RateLimit = require("../../src/Shared/RateLimit")
local Net = require("../../src/Shared/Net")

local T0 = 5_000 -- an os.clock() reading
local WINDOW = RateLimit.WINDOW_SECONDS

local tests = {}

tests["the window is Net.Limits' 10 seconds"] = function()
	expect.eq(WINDOW, 10)
end

tests["allows `limit` requests in a window, then refuses until it runs out"] = function()
	local state: RateLimit.State = {}
	for i = 1, 3 do
		expect.truthy(RateLimit.take(state, "SaveSettings", 3, T0 + i), `request {i} passes`)
	end
	expect.falsy(RateLimit.take(state, "SaveSettings", 3, T0 + 4), "the 4th in the window is refused")
	expect.falsy(RateLimit.take(state, "SaveSettings", 3, T0 + 1 + WINDOW - 0.001), "still refused just before the end")
	expect.truthy(RateLimit.take(state, "SaveSettings", 3, T0 + 1 + WINDOW), "a new window opens at the end")
	expect.truthy(RateLimit.take(state, "SaveSettings", 3, T0 + 1 + WINDOW + 1))
	expect.truthy(RateLimit.take(state, "SaveSettings", 3, T0 + 1 + WINDOW + 2))
	expect.falsy(RateLimit.take(state, "SaveSettings", 3, T0 + 1 + WINDOW + 3), "and it holds 3 again")
end

tests["a flood of refused requests never opens the window early or keeps it shut longer"] = function()
	local state: RateLimit.State = {}
	expect.truthy(RateLimit.take(state, "AckOnboarding", 3, T0))
	local passed = 1
	for i = 1, 1000 do
		if RateLimit.take(state, "AckOnboarding", 3, T0 + i * 0.005) then
			passed += 1
		end
	end
	expect.eq(passed, 3, "1001 requests in 5 s: exactly 3 pass")
	expect.truthy(RateLimit.take(state, "AckOnboarding", 3, T0 + WINDOW), "the window still ends on time")
end

tests["each request name has its own window"] = function()
	local state: RateLimit.State = {}
	for _ = 1, 3 do
		RateLimit.take(state, "SaveSettings", 3, T0)
	end
	expect.falsy(RateLimit.take(state, "SaveSettings", 3, T0))
	expect.truthy(RateLimit.take(state, "GetSettings", 3, T0), "another remote is unaffected")
	expect.truthy(RateLimit.take(state, "AckOnboarding", 3, T0))
end

tests["a limit of 0 refuses everything"] = function()
	local state: RateLimit.State = {}
	expect.falsy(RateLimit.take(state, "X", 0, T0))
	expect.falsy(RateLimit.take(state, "X", 0, T0 + 2 * WINDOW))
end

tests["a bad clock or limit fails closed and counts nothing"] = function()
	local state: RateLimit.State = {}
	for _, now in { 0 / 0, math.huge, -math.huge } do
		expect.falsy(RateLimit.take(state, "X", 3, now), `now {now} refused`)
	end
	for _, limit in { 0 / 0, math.huge, -1, 2.5, "3" :: any } do
		expect.falsy(RateLimit.take(state, "X", limit, T0), `limit {limit} refused`)
	end
	expect.eq(state.X, nil, "no window was opened by any of them")
	expect.truthy(RateLimit.take(state, "X", 3, T0), "a good request still passes")
end

tests["reopensIn counts down to the end of the window"] = function()
	local state: RateLimit.State = {}
	expect.eq(RateLimit.reopensIn(state, "SaveSettings", T0), 0, "no window running")
	RateLimit.take(state, "SaveSettings", 3, T0)
	expect.eq(RateLimit.reopensIn(state, "SaveSettings", T0), WINDOW)
	expect.near(RateLimit.reopensIn(state, "SaveSettings", T0 + 2.5), WINDOW - 2.5, 1e-9)
	expect.eq(RateLimit.reopensIn(state, "SaveSettings", T0 + WINDOW + 4), 0, "never negative")
	expect.eq(RateLimit.reopensIn(state, "SaveSettings", T0 - 100), WINDOW, "never more than one window")
	expect.eq(RateLimit.reopensIn(state, "SaveSettings", 0 / 0), WINDOW, "a NaN clock waits a whole window")
	expect.eq(RateLimit.reopensIn(state, "Other", T0), 0, "per name")
end

tests["the C6b remotes have their own limits, and every limit is a whole number above 0"] = function()
	for _, name in { "GetSettings", "SaveSettings", "GetOnboarding", "AckOnboarding" } do
		expect.eq((Net.Limits :: any)[name], 3, `{name} is about 3 per 10 s`)
		expect.eq((Net.Requests :: any)[name], name, `{name} is a request`)
	end
	for name, limit in Net.Limits :: any do
		expect.truthy(type(limit) == "number" and limit >= 1 and limit % 1 == 0, `Net.Limits.{name}`)
	end
end

return tests
