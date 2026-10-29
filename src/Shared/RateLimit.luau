--!strict
--[[
	RateLimit (owner: data agent): fixed-window request limits per player, the rule Net.Limits
	states ("max requests per player per 10 seconds"). Pure: the caller keeps one State per player
	and passes `now` from its own monotonic clock (os.clock() on the server), never a client value.

	A window opens at the first request after the previous one ran out and lasts WINDOW_SECONDS;
	within it at most `limit` requests of one name pass. Each name has its own window.
]]

local RateLimit = {}

RateLimit.WINDOW_SECONDS = 10

export type Window = { start: number, count: number }
export type State = { [string]: Window }

local function isFinite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

--[[
	Counts one request named `name` at `now` and returns whether it is within `limit`. A request over
	the limit still counts, so a flood keeps the window shut until it runs out. Refuses (false,
	counting nothing) a `now` that is not finite, or a `limit` that is not a whole number >= 0, so a
	bad clock or a typo fails closed instead of opening a window that never ends.
]]
function RateLimit.take(state: State, name: string, limit: number, now: number): boolean
	if not isFinite(now) or not isFinite(limit) or limit < 0 or limit % 1 ~= 0 then
		return false
	end
	local window = state[name]
	if window == nil or now - window.start >= RateLimit.WINDOW_SECONDS then
		window = { start = now, count = 0 }
		state[name] = window
	end
	window.count += 1
	return window.count <= limit
end

-- Seconds from `now` until `name`'s window runs out: 0 when none is running, never more than
-- WINDOW_SECONDS (and WINDOW_SECONDS for a `now` that is not finite).
function RateLimit.reopensIn(state: State, name: string, now: number): number
	if not isFinite(now) then
		return RateLimit.WINDOW_SECONDS
	end
	local window = state[name]
	if window == nil then
		return 0
	end
	return math.clamp(window.start + RateLimit.WINDOW_SECONDS - now, 0, RateLimit.WINDOW_SECONDS)
end

return RateLimit
