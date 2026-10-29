--!strict
--[[
	Studio test sessions (P1.10d): real ProfileStore sessions for reserved test ids, held and
	saved like a player's in DataStore persistence, so the forced-shutdown soak needs no real
	account. DataService and EscrowService cannot run under Lune, so source guards pin that a
	test session is unreachable outside Studio:
	  - loadTestSession refuses first unless RunService:IsStudio() AND the explicit
	    ServerStorage switch AND a test id hold, and then unless persistence is DataStore;
	  - it is the only code that ever puts a session in testSessions; everything else only
	    reads it or clears it, so in a live server every testSessions lookup finds nothing;
	  - the switch is read in one place, behind IsStudio; the DataTestHook is installed only in
	    Studio, and every command checks the switch and the id first;
	  - a player's join and leave never touch test sessions, and live lookups come first;
	  - EscrowService recovers a test session on its load and in the rescan, like a player.
]]

local expect = require("../lib/expect")
local source = require("../lib/source")

local DATA = "src/Server/Services/DataService.luau"
local ESCROW = "src/Server/Services/EscrowService.luau"

local function count(text: string, pattern: string): number
	return select(2, string.gsub(text, pattern, ""))
end

local function body(code: string, name: string): string
	local found = source.functionBody(code, name)
	expect.truthy(found, `{name} found`)
	return found :: string
end

local tests = {}

tests["loadTestSession refuses outside Studio, without the switch and for unreserved ids, first"] = function()
	local code = source.codeOnly(source.read(DATA))
	local on = body(code, "testSessionsOn")
	expect.truthy(
		string.find(
			on,
			"^function testSessionsOn%(%): boolean\n"
				.. "%s*return RunService:IsStudio%(%) and ServerStorage:GetAttribute%(TEST_SESSION_SWITCH%) == true\n"
				.. "end\n$"
		),
		"the switch counts only in Studio, and only when it is exactly true"
	)
	local load = body(code, "DataService.loadTestSession")
	expect.truthy(
		string.find(
			load,
			"^function DataService%.loadTestSession%b()[^\n]*\n"
				.. "%s*if not testSessionsOn%(%) then%s*error%b()%s*end"
				.. "%s*if not Profile%.isTestUserId%(userId%) then%s*error%b()%s*end"
				.. "%s*local mode = DataService%.persistence%(%)"
				.. '%s*if mode == nil then%s*return false, %b""'
				.. '%s*elseif mode ~= "DataStore" then%s*error%b()%s*end'
		),
		"Studio and the switch, then a test id, then DataStore persistence: before anything else"
	)
end

tests["the test-session switch is read once, behind IsStudio"] = function()
	local code = source.codeOnly(source.read(DATA))
	expect.truthy(string.find(code, '\nlocal TEST_SESSION_SWITCH = "StudioTestSessions"\n'), "the switch's name")
	expect.eq(count(code, "TEST_SESSION_SWITCH%)"), 1, "one read of the switch")
	expect.eq(count(body(code, "testSessionsOn"), "GetAttribute%(TEST_SESSION_SWITCH%)"), 1, "in testSessionsOn")
	-- Both gated entry points ask testSessionsOn, and nothing else does.
	expect.eq(count(code, "testSessionsOn%(%)"), 3, "the definition and two callers")
	expect.eq(count(body(code, "DataService.loadTestSession"), "testSessionsOn%(%)"), 1, "loadTestSession asks")
	expect.eq(count(body(code, "testHook"), "testSessionsOn%(%)"), 1, "the hook asks")
end

tests["only loadTestSession, after its gates, ever holds a test session"] = function()
	local code = source.codeOnly(source.read(DATA))
	expect.truthy(string.find(code, "\nlocal testSessions: { %[number%]: Session } = {}\n"), "starts empty")
	-- Every assignment into testSessions: one adopts the session, the rest clear an entry.
	local adopts, clears = 0, 0
	for value in string.gmatch(code, "testSessions%[[^%]]+%]%s*=%s*([%w_]+)") do
		if value == "session" then
			adopts += 1
		elseif value == "nil" then
			clears += 1
		else
			error(`unexpected testSessions write: {value}`)
		end
	end
	expect.eq(adopts, 1, "one place holds a session")
	expect.truthy(clears >= 1, "release and lock loss clear entries")
	expect.eq(count(code, "testSessions%s*="), 0, "the table itself is never replaced")
	expect.eq(count(code, "table%.insert%(testSessions"), 0, "nothing inserted any other way")
	local load = body(code, "DataService.loadTestSession")
	local gated = string.find(load, 'elseif mode ~= "DataStore" then')
	local held = string.find(load, "\n%s*testSessions%[userId%] = session\n")
	expect.truthy(gated and held, "gates and the hold found in loadTestSession")
	expect.truthy((gated :: number) < (held :: number), "held only after every gate")
	-- No AddUserId for a test id: it is not an account.
	expect.eq(count(load, "AddUserId"), 0, "a test id is never added as a user id")
end

tests["the DataTestHook exists only in Studio and checks the switch and a test id first"] = function()
	local code = source.codeOnly(source.read(DATA))
	local start = body(code, "DataService.start")
	expect.truthy(
		string.find(start, "\n%s*if RunService:IsStudio%(%) then%s*installTestHook%(%)%s*end\n"),
		"start() installs it behind IsStudio"
	)
	expect.eq(count(code, "\n%s*installTestHook%(%)"), 1, "installed from one place")
	expect.eq(count(code, '"DataTestHook"'), 1, "one hook instance")
	expect.truthy(string.find(body(code, "installTestHook"), "pcall%(testHook,"), "every command runs through testHook")
	local hook = body(code, "testHook")
	expect.truthy(
		string.find(
			hook,
			"^function testHook%b()[^\n]*\n"
				.. "%s*if not testSessionsOn%(%) then%s*return %b``%s*end"
				.. "%s*if not Profile%.isTestUserId%(userId%) then%s*return %b``%s*end"
		),
		"the switch (and Studio), then a test id, before any command"
	)
	-- Seeding writes only a test session this server holds (so one loadTestSession allowed).
	expect.truthy(
		string.find(
			body(code, "seedTestSession"),
			"^function seedTestSession%b()[^\n]*\n%s*local session = testSessions%[userId%]\n"
				.. "%s*if session == nil or not session:IsActive%(%) then%s*return %b``%s*end"
		),
		"seed refuses anything but a held test session"
	)
	expect.truthy(
		string.find(
			body(code, "DataService.releaseTestSession"),
			"^function DataService%.releaseTestSession%b()[^\n]*\n%s*if not RunService:IsStudio%(%) then%s*error%b()%s*end"
		),
		"releaseTestSession is Studio-only"
	)
end

tests["the seed accrues through the Glow-factor helper first, and changes nothing without it (P2.8b)"] = function()
	local code = source.codeOnly(source.read(DATA))
	local seed = body(code, "seedTestSession")
	local held = string.find(seed, "local session = testSessions%[userId%]")
	local hook = string.find(seed, 'local accrue = glowAccrue\n%s*if accrue == nil then%s*return %b""%s*end')
	local accrued = string.find(seed, "\n%s*accrue%(profile, now%)\n")
	local firstWrite = string.find(seed, "profile%.critters%[uid%] = ")
	local stored = string.find(seed, "profile%.stored %+= extra")
	expect.truthy(held and hook and accrued and firstWrite and stored, "held check, hook, accrue and writes found")
	expect.truthy((held :: number) < (hook :: number), "a held session first")
	expect.truthy((hook :: number) < (accrued :: number), "refused before anything when no helper is registered")
	expect.truthy((accrued :: number) < (firstWrite :: number), "accrued before placements change")
	expect.truthy((accrued :: number) < (stored :: number), "and before stored changes")
	expect.eq(count(seed, "accrue%("), 1, "one accrue")
	expect.eq(count(seed, "Economy%.accrue"), 0, "never a factor-1 accrue")
end

tests["a player's join and leave never touch test sessions, and live lookups come first"] = function()
	local code = source.codeOnly(source.read(DATA))
	for _, name in { "onPlayerAdded", "onPlayerRemoving", "DataService.onProfileLoaded" } do
		local text = body(code, name)
		expect.eq(count(text, "testSession"), 0, `{name} never touches test sessions`)
		expect.eq(count(text, "Test"), 0, `{name} never touches test sessions or profiles`)
	end
	local get = body(code, "DataService.getProfile")
	local live = string.find(get, "local entry = sessions%[userId%]")
	local studio = string.find(get, "local studio = testSessions%[userId%]")
	expect.truthy(live and studio and (live :: number) < (studio :: number), "getProfile asks sessions first")
	local save = body(code, "DataService.saveNow")
	expect.truthy(
		string.find(save, "local session = if entry then entry%.session else testSessions%[userId%]"),
		"saveNow uses a player's session whenever there is one"
	)
end

tests["EscrowService recovers a test session on its load and in the rescan, like a player"] = function()
	local code = source.codeOnly(source.read(ESCROW))
	local start = body(code, "EscrowService.start")
	expect.truthy(
		string.find(
			start,
			"DataService%.onTestSessionLoaded%(function%(userId: number%)%s*recoverUser%(userId%)%s*end%)"
		),
		"recovery runs on a test session's load"
	)
	local sweep = body(code, "sweep")
	local players = string.find(sweep, "for _, player in Players:GetPlayers%(%) do")
	local studio = string.find(
		sweep,
		"for _, userId in DataService%.testSessionIds%(%) do\n"
			.. "%s*if isHere%(userId%) and needsIndex%[userId%] == nil then\n"
			.. "%s*task%.spawn%(recoverUser, userId, true%)"
	)
	expect.truthy(players and studio, "both rescans found")
	expect.truthy((players :: number) < (studio :: number), "players are rescanned first, unchanged")
	-- Nothing else in escrow depends on test sessions: they are found through getProfile.
	expect.eq(count(code, "TestSession"), 1, "only the load signal names test sessions")
	expect.eq(count(code, "testSessionIds"), 1, "only the rescan lists them")
end

return tests
