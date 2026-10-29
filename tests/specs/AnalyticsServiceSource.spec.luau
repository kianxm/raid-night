--!strict
--[[
	Source guards for analytics (P2.9; Lune cannot run server code):
	  - AnalyticsService is the only Roblox analytics caller; every call goes through send's pcall,
	    after the schema, and it never requires DataService or EscrowService (both require it).
	  - Escrow.luau stays pure and untouched by analytics; EscrowService announces a step only
	    after the record write landed, deferred and inside pcall, and reaches NotificationService
	    only through the optional lookup (works with or without PR #118).
	  - DataService opens the session on load and logs session_end before EndSession, and logs
	    onboarding_step after an onboarding advance wrote, never before or without it (P2.9b).
	  - Every debit that took Glow logs the DenRaided sink, Live included (P2.9b).
]]

local fs = require("@lune/fs")

local expect = require("../lib/expect")
local source = require("../lib/source")

local ANALYTICS = "src/Server/Services/AnalyticsService.luau"
local ESCROW_SERVICE = "src/Server/Services/EscrowService.luau"
local ESCROW = "src/Shared/Escrow.luau"
local DATA = "src/Server/Services/DataService.luau"

local function count(text: string, pattern: string): number
	return select(2, string.gsub(text, pattern, ""))
end

local tests = {}

tests["only AnalyticsService calls Roblox's AnalyticsService"] = function()
	local function scan(dir: string)
		for _, name in fs.readDir(dir) do
			local path = `{dir}/{name}`
			if fs.isDir(path) then
				if name ~= "Packages" then
					scan(path)
				end
			elseif string.match(name, "%.luau$") then
				local relative = string.gsub(path, "^.-/src/", "src/")
				local code = source.codeOnly(fs.readFile(path))
				if relative ~= ANALYTICS then
					expect.eq(count(code, 'GetService%("AnalyticsService"%)'), 0, `{relative} does not call it`)
				end
			end
		end
	end
	local here = debug.info(1, "s")
	local root = string.match(here, "^(.*)[/\\]tests[/\\]specs[/\\][^/\\]+$") :: string
	scan(`{root}/src`)
end

tests["every Roblox analytics call is inside send's pcall, after the schema"] = function()
	local code = source.codeOnly(source.read(ANALYTICS))
	local send = source.functionBody(code, "send") or ""
	expect.truthy(string.find(send, "local ok, err = pcall%(call%)"), "send runs the call in pcall")
	expect.eq(count(code, "RobloxAnalytics:Log"), 4, "four Roblox calls")
	for _, call in { "LogCustomEvent", "LogOnboardingFunnelStepEvent", "LogFunnelStepEvent", "LogEconomyEvent" } do
		local at = string.find(code, "RobloxAnalytics:" .. call .. "%(")
		expect.truthy(at, `{call} used`)
		local before = string.sub(code, 1, at :: number)
		local lastSend = 0
		for position in string.gmatch(before, "()send%(") do
			lastSend = position
		end
		expect.truthy(lastSend > 0, `{call} is inside a send callback`)
		local between = string.sub(code, lastSend, at :: number)
		expect.truthy(string.find(between, "function%(%)"), `{call} runs in send's callback`)
	end
	local track = source.functionBody(code, "AnalyticsService.track") or ""
	local encoded = string.find(track, "Analytics%.encode%(event, fields%)")
	local logged = string.find(track, "LogCustomEvent")
	expect.truthy(encoded and logged and (encoded :: number) < (logged :: number), "validated before it is sent")
	local economy = source.functionBody(code, "AnalyticsService.economy") or ""
	local checked = string.find(economy, "Analytics%.economy%(flowId, amount, endingBalance%)")
	local sent = string.find(economy, "LogEconomyEvent")
	expect.truthy(checked and sent and (checked :: number) < (sent :: number), "economy validated before it is sent")
end

tests["AnalyticsService requires neither DataService nor EscrowService"] = function()
	local code = source.codeOnly(source.read(ANALYTICS))
	for _, name in { "DataService", "EscrowService", "NotificationService", "RaidService" } do
		expect.falsy(string.find(code, "require%([^%)]*" .. name), `no require of {name}`)
	end
	-- A live server always sends; Studio only behind its switch.
	local sending = source.functionBody(code, "sending") or ""
	expect.truthy(string.find(sending, "if not RunService:IsStudio%(%) then%s*return true, false"), "live sends")
	-- session_end once, whoever sees the leave first (a lost lock ends DataService's entry early).
	expect.truthy(
		string.find(
			code,
			"Players%.PlayerRemoving:Connect%(function%(player: Player%)%s*AnalyticsService%.sessionEnded%(player, os%.time%(%)%)"
		),
		"its own leave handler ends the session too"
	)
	local ended = source.functionBody(code, "AnalyticsService.sessionEnded") or ""
	local logged = string.find(ended, 'AnalyticsService%.track%(player, "session_end"')
	local forgot = string.find(ended, "sessions%[player%.UserId%] = nil")
	expect.truthy(logged and forgot and (logged :: number) < (forgot :: number), "logged once, then forgotten")
end

tests["Escrow.luau knows nothing of analytics or notifications"] = function()
	local code = source.codeOnly(source.read(ESCROW))
	for _, word in { "Analytics", "Notification", "onLoss", "task%." } do
		expect.eq(count(code, word), 0, `Escrow.luau has no {word}`)
	end
end

tests["EscrowService announces a step only after its record write, deferred and guarded"] = function()
	local code = source.codeOnly(source.read(ESCROW_SERVICE))
	expect.eq(count(code, "[^%w_]announce%(record, before%)"), 1, "one announce call")
	local store = source.functionBody(code, "storeFor") or ""
	local save = string.match(store, "saveRecord = (function.-\n\t\tend),") or ""
	local before = string.find(save, "local before = if last%.record then last%.record%.state else nil")
	local wrote = string.find(save, "\n%s*saveRecord%(record%)")
	local announced = string.find(save, "announce%(record, before%)")
	expect.truthy(before and wrote and announced, "state read, write, announce")
	expect.truthy((before :: number) < (wrote :: number) and (wrote :: number) < (announced :: number), "in order")
	local announce = source.functionBody(code, "announce") or ""
	expect.truthy(string.find(announce, "local saved: EscrowRecord = deepCopy%(record%)"), "a copy of the record")
	expect.truthy(string.find(announce, "task%.defer%(function%(%)"), "deferred: never inside the drive")
	expect.truthy(string.find(announce, "pcall%(announcer, saved%)"), "and guarded")
	expect.truthy(
		string.find(announce, 'before == "Pending" and saved%.state == "Debited"')
			and string.find(announce, 'before == "Debited" and saved%.state == "Committed"'),
		"only the debit and the credit announce"
	)
	-- Analytics and notifications are reached only from the announcers.
	for _, call in { "AnalyticsService%.", "onLoss%(" } do
		local rest = code
		for _, name in { "announceDebit", "announceCredit" } do
			local body = source.functionBody(code, name) or ""
			expect.truthy(#body > 0, `{name} found`)
			local first, last = string.find(rest, body, 1, true)
			rest = string.sub(rest, 1, (first :: number) - 1) .. string.sub(rest, (last :: number) + 1)
		end
		expect.eq(count(rest, call), 0, `{call} only in the announcers`)
	end
end

tests["every debit that took Glow logs DenRaided, Live included, so live raids balance RaidLoot"] = function()
	local code = source.codeOnly(source.read(ESCROW_SERVICE))
	local debit = source.functionBody(code, "announceDebit") or ""
	local sink = string.find(debit, 'AnalyticsService%.economy%(defender, "DenRaided", record%.glow,')
	local asyncOnly = string.find(debit, 'if Escrow%.kindOf%(record%) == "Async" then')
	expect.truthy(sink and asyncOnly, "found")
	expect.truthy((sink :: number) < (asyncOnly :: number), "the sink is logged before, not inside, the Async branch")
	expect.truthy(string.find(debit, "if defender and profile and record%.glow > 0 then"), "only Glow that moved")
	expect.eq(count(code, '"DenRaided"'), 1, "logged in one place")
	local credit = source.functionBody(code, "announceCredit") or ""
	expect.truthy(string.find(credit, 'AnalyticsService%.economy%(raider, "RaidLoot", record%.glow,'), "its source")
	expect.falsy(string.find(credit, "kindOf"), "the source is logged for every kind too")
end

tests["DataService logs onboarding_step only after an onboarding advance wrote"] = function()
	local code = source.codeOnly(source.read(DATA))
	local trackOnboarding = source.functionBody(code, "trackOnboarding") or ""
	expect.truthy(
		string.find(trackOnboarding, "Analytics%.onboardingStepEvents%(before, after, profile%.createdAt, now%)"),
		"one event per step completed, seconds since the first join"
	)
	expect.truthy(
		string.find(trackOnboarding, 'AnalyticsService%.track%(userId, "onboarding_step", fields%)'),
		"fire-and-forget"
	)
	for _, banned in { "task%.wait", "task%.delay", "saveNow", ":Wait%(" } do
		expect.falsy(string.find(trackOnboarding, banned), `never yields ({banned})`)
	end
	expect.eq(count(code, '"onboarding_step"'), 1, "logged in one place")
	local cases = {
		{ "DataService.advanceOnboarding", "if not Profile%.advanceOnboardingTo%(profile, stepId, now%) then" },
		{ "onAckOnboarding", 'if outcome == "Advanced" then' },
	}
	for _, case in cases do
		local name, wrote = case[1], case[2]
		local fn = source.functionBody(code, name) or ""
		local before = string.find(fn, "local before = Profile%.onboardingStep%(profile%)")
		local gate = string.find(fn, wrote)
		local tracked = string.find(fn, "trackOnboarding%(userId, profile, before, now%)")
		expect.truthy(before and gate and tracked, `{name}: found`)
		expect.truthy((before :: number) < (gate :: number), `{name}: the step count is read before the advance`)
		expect.truthy((gate :: number) < (tracked :: number), `{name}: logged only once the advance wrote`)
	end
end

tests["EscrowService reaches NotificationService only through the optional lookup"] = function()
	local code = source.codeOnly(source.read(ESCROW_SERVICE))
	expect.falsy(string.find(code, "require%(script%.Parent%.NotificationService%)"), "no hard require")
	local lookup = source.functionBody(code, "notifications") or ""
	expect.truthy(string.find(lookup, 'FindFirstChild%("NotificationService"%)'), "found by name")
	expect.truthy(string.find(lookup, "pcall%(require, module%)"), "required in pcall")
	expect.truthy(string.find(lookup, 'type%(%(service :: any%)%.onLoss%) == "function"'), "only with an onLoss")
	local debit = source.functionBody(code, "announceDebit") or ""
	expect.truthy(string.find(debit, "service%.onLoss%({"), "onLoss called from the debit announcement")
	expect.truthy(string.find(debit, "record%.defenderUserId <= 0 or record%.raiderUserId <= 0"), "never for test ids")
	-- The name is the raider's Roblox DisplayName or username, never anything a player typed.
	local name = source.functionBody(code, "raiderName") or ""
	expect.truthy(string.find(name, "return player%.DisplayName"), "DisplayName when here")
	expect.truthy(string.find(name, "Players:GetNameFromUserIdAsync%(userId%)"), "else the username")
	expect.truthy(string.find(name, "for attempt = 1, #NAME_LOOKUP_DELAYS %+ 1 do"), "bounded retries")
end

tests["DataService opens the analytics session on load and logs session_end before EndSession"] = function()
	local code = source.codeOnly(source.read(DATA))
	local added = source.functionBody(code, "onPlayerAdded") or ""
	local held = string.find(added, "sessions%[userId%] = { session = session, player = player }")
	local started = string.find(added, "AnalyticsService%.sessionStarted%(player, profile, os%.time%(%)%)")
	local listeners = string.find(added, "for _, fn in table%.clone%(loadedListeners%) do")
	expect.truthy(held and started and listeners, "found")
	expect.truthy((held :: number) < (started :: number) and (started :: number) < (listeners :: number), "in order")
	local removing = source.functionBody(code, "onPlayerRemoving") or ""
	local ended = string.find(removing, "AnalyticsService%.sessionEnded%(player, os%.time%(%)%)")
	local endSession = string.find(removing, "entry%.session:EndSession%(%)")
	expect.truthy(ended and endSession and (ended :: number) < (endSession :: number), "session_end first")
	expect.truthy(string.find(removing, "if entry and entry%.player == player then"), "only for its own session")
end

return tests
