--!strict
--[[
	Studio test profiles (decision D-019). The id rule is pure; the rest lives in DataService and
	EscrowService, which Lune cannot run, so source guards pin the gates that keep a test profile
	away from any real save: Studio only, memory persistence only, reserved ids only. They also
	pin that profiles and escrow share one storage mode whatever order services start in, and
	that a test profile is released only when EscrowService's guard says no escrow is open.
]]
local expect = require("../lib/expect")
local source = require("../lib/source")
local Profile = require("../../src/Shared/Profile")

local tests = {}

tests["only whole ids at or below -1,000,000 are test ids"] = function()
	for _, id in { -1_000_000, -1_000_001, -2_000_000_000 } do
		expect.truthy(Profile.isTestUserId(id), `{id} is a test id`)
	end
	-- Real accounts, the template's 0, and Studio Local Server players (-1, -2, ...) are not.
	for _, id in { 1, 0, -1, -2, -8, -999_999, -1_000_000.5, -math.huge, 0 / 0 } do
		expect.falsy(Profile.isTestUserId(id), `{id} is not a test id`)
	end
end

tests["loadTestProfile refuses outside Studio, without memory persistence and for unreserved ids"] = function()
	local code = source.codeOnly(source.read("src/Server/Services/DataService.luau"))
	local body = source.functionBody(code, "DataService.loadTestProfile")
	expect.truthy(body, "loadTestProfile found")
	local gates = string.find(
		body :: string,
		"^function DataService%.loadTestProfile%b()[^\n]*\n"
			.. "%s*if not RunService:IsStudio%(%) then%s*error%b()%s*end"
			.. '%s*if DataService%.persistence%(%) ~= "Memory" then%s*error%b()%s*end'
			.. "%s*if not Profile%.isTestUserId%(userId%) then%s*error%b()%s*end"
	)
	expect.truthy(gates, "the three gates come first, before anything is stored")
	expect.eq(select(2, string.gsub(code, "testProfiles%[[^%]]+%]%s*=%s*profile", "")), 1, "one place adopts")
end

tests["the memory switch is read once, at start, and only in Studio"] = function()
	local code = source.codeOnly(source.read("src/Server/Services/DataService.luau"))
	expect.eq(select(2, string.gsub(code, "GetAttribute", "")), 1, "one attribute read")
	local start = source.functionBody(code, "DataService.start") or ""
	expect.truthy(
		string.find(
			start,
			"memoryOnly = RunService:IsStudio%(%) and ServerStorage:GetAttribute%(MEMORY_SWITCH%) == true"
		),
		"read in start(), behind IsStudio"
	)
	expect.truthy(string.find(start, "store = if memoryOnly then profileStore%.Mock else profileStore"), "mock store")
	local persistence = source.functionBody(code, "DataService.persistence") or ""
	expect.truthy(string.find(persistence, 'if memoryOnly then%s*return "Memory"'), "persistence reports Memory")
end

tests["EscrowService guards test profile releases"] = function()
	local code = source.codeOnly(source.read("src/Server/Services/EscrowService.luau"))
	local start = source.functionBody(code, "EscrowService.start") or ""
	expect.truthy(string.find(start, "DataService%.guardTestRelease%(openEscrowFor%)"), "guard registered at start")
	-- The guard trusts this server's memory only when escrow really lives there.
	local guard = source.functionBody(code, "openEscrowFor") or ""
	expect.truthy(
		string.find(
			guard,
			'^function openEscrowFor%b()[^\n]*\n%s*if storage%(%) ~= "Memory" then%s*return "[^"]+"%s*end'
		),
		"openEscrowFor refuses first unless escrow storage is memory"
	)
end

tests["releaseTestProfile consults the escrow guard, and fails closed, before letting go"] = function()
	local code = source.codeOnly(source.read("src/Server/Services/DataService.luau"))
	expect.eq(select(2, string.gsub(code, "testProfiles%[[^%]]+%]%s*=%s*nil", "")), 1, "one place lets go")
	expect.eq(select(2, string.gsub(code, "\n%s*testReleaseGuard%s*=", "")), 1, "only guardTestRelease sets it")
	local body = source.functionBody(code, "DataService.releaseTestProfile")
	expect.truthy(body, "releaseTestProfile found")
	local text = body :: string
	local _, cleared = string.find(text, "\n%s*testProfiles%[userId%] = nil\n")
	-- No guard registered: refuse (EscrowService.start has not run, so nobody can vouch).
	local _, noGuard = string.find(
		text,
		"\n%s*local guard = testReleaseGuard\n%s*if guard == nil then\n.-\n%s*return false, why\n%s*end\n"
	)
	-- A guard: consulted (an error in it also refuses), and any reason keeps the profile.
	local _, consulted = string.find(
		text,
		"\n%s*local checked, why = pcall%(guard, userId%)\n"
			.. "%s*if not checked or why ~= nil then\n.-\n%s*return false, reason\n%s*end\n"
	)
	expect.truthy(cleared, "releaseTestProfile clears the entry")
	expect.truthy(noGuard, "a missing guard refuses the release")
	expect.truthy(consulted, "the guard is consulted and its answer (or error) refuses")
	expect.truthy((noGuard :: number) < (consulted :: number), "missing guard checked first")
	expect.truthy((consulted :: number) < (cleared :: number), "the guard is consulted before the entry is cleared")
end

tests["persistence() is nil until start() has read the memory switch"] = function()
	local code = source.codeOnly(source.read("src/Server/Services/DataService.luau"))
	expect.truthy(string.find(code, "\nlocal started = false\n"), "a started flag, false until start()")
	expect.eq(select(2, string.gsub(code, "\n%s*started%s*=", "")), 1, "one place sets started")
	local persistence = source.functionBody(code, "DataService.persistence") or ""
	expect.truthy(
		string.find(
			persistence,
			"^function DataService%.persistence%b()[^\n]*\n%s*if not started then%s*return nil%s*end"
		),
		"persistence() answers nil before anything else until start() has run"
	)
	local start = source.functionBody(code, "DataService.start") or ""
	expect.truthy(
		string.find(start, "^function DataService%.start%(%)\n%s*if started then%s*error%b()%s*end"),
		"start() runs once, so the switch is read once"
	)
	local switch = string.find(start, "\n%s*memoryOnly = RunService:IsStudio%(%)")
	local chosen = string.find(start, "\n%s*store = if memoryOnly then")
	local flag = string.find(start, "\n%s*started = true")
	expect.truthy(switch and chosen and flag, "start() reads the switch, chooses the store and sets started")
	expect.truthy((switch :: number) < (chosen :: number), "the store follows the switch")
	expect.truthy(
		(chosen :: number) < (flag :: number),
		"started is set only once the switch is read and the store chosen"
	)
end

tests["EscrowService takes its storage mode only from a decided persistence()"] = function()
	local code = source.codeOnly(source.read("src/Server/Services/EscrowService.luau"))
	expect.eq(select(2, string.gsub(code, "DataService%.persistence%(", "")), 1, "persistence() asked in one place")
	expect.eq(select(2, string.gsub(code, "\n%s*mode%s*=", "")), 1, "mode set in one place")
	expect.eq(select(2, string.gsub(code, "\n%s*dataStore%s*=", "")), 1, "dataStore set in one place")
	local storage = source.functionBody(code, "storage") or ""
	local _, undecided = string.find(
		storage,
		"\n%s*local decided = DataService%.persistence%(%)\n%s*if decided == nil then%s*return nil%s*end"
	)
	local set = string.find(storage, "\n%s*mode = decided\n")
	expect.truthy(undecided, "storage() returns nil, uncached, while persistence() is undecided")
	expect.truthy(set, "storage() takes the mode from persistence()")
	expect.truthy((undecided :: number) < (set :: number), "the mode is set only after the nil check")
	local backend = source.functionBody(code, "backend") or ""
	expect.truthy(
		string.find(backend, "local decided = storage%(%)\n%s*if decided == nil then%s*error%b()"),
		"backend() errors while the mode is undecided"
	)
	-- Every escrow read and write picks its backend through backend(), first thing.
	for _, name in { "read", "update" } do
		local body = source.functionBody(code, name) or ""
		expect.truthy(
			string.find(body, `^function {name}%b()[^\n]*\n%s*if backend%(%) == "Memory" then`),
			`{name} picks its backend through backend() first`
		)
	end
	-- transferLive refuses before any write while undecided.
	local live = source.functionBody(code, "EscrowService.transferLive") or ""
	local refused = string.find(live, 'if storage%(%) == nil then%s*return "Refused"')
	local driven = string.find(live, "pcall%(startOrResume")
	expect.truthy(
		refused and driven and (refused :: number) < (driven :: number),
		"transferLive refuses while undecided"
	)
end

return tests
