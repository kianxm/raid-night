--!strict
--[[
	Studio test profiles (decision D-019). The id rule is pure; the rest lives in DataService and
	EscrowService, which Lune cannot run, so source guards pin the gates that keep a test profile
	away from any real save: Studio only, memory persistence only, reserved ids only.
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
end

return tests
