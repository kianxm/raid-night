--!strict
--[[
	Source guards for the raid server code (no Studio needed). They pin the rules a reviewer
	would otherwise have to re-check by hand on every PR:
	  - Config.Flags is read in exactly one place, as Escrow.canStartTransfer's argument (D-002).
	  - No server decision reads an attribute (docs/contracts.md, Replicated attributes; D-014).
	  - Raid code never writes a profile or saves one (golden rule 4): no critter, placement, pad,
	    Glow, stored or loss-counter assignment, no Economy.place, no escrow debit or credit.
]]

local fs = require("@lune/fs")
local expect = require("../lib/expect")

local FILES = {
	"src/Server/Services/RaidService.luau",
	"src/Server/Raid/Lockdown.luau",
	"src/Server/Raid/TestHook.luau",
}
-- TestHook builds its own in-memory stand-in profile, which no player owns, so it is the one
-- file allowed to fill a critters table. It must still never save anything.
local BUILDS_FAKE_PROFILE = { ["src/Server/Raid/TestHook.luau"] = true }

local function codeOnly(source: string): string
	source = string.gsub(source, "%-%-%[(=*)%[.-%]%1%]", "")
	source = string.gsub(source, "%-%-[^\n]*", "")
	return source
end

local function count(code: string, plain: string): number
	local n, from = 0, 1
	while true do
		local first, last = string.find(code, plain, from, true)
		if not first then
			return n
		end
		n += 1
		from = (last :: number) + 1
	end
end

local tests = {}

tests["RaidService reads Config.Flags only through Escrow.canStartTransfer"] = function()
	for i = 2, #FILES do
		expect.eq(count(codeOnly(fs.readFile(FILES[i])), "Flags"), 0, `{FILES[i]} reads a flag`)
	end
	local code = codeOnly(fs.readFile(FILES[1]))
	expect.eq(count(code, "Flags"), 1, "exactly one flag read")
	expect.eq(count(code, 'Escrow.canStartTransfer(Config.Flags, "Live"'), 1, "and it is the kill-switch check")
end

tests["the test hook only ever installs in Studio"] = function()
	local code = codeOnly(fs.readFile("src/Server/Raid/TestHook.luau"))
	expect.truthy(
		string.find(code, "function TestHook.install%(raidApi: Api%)%s+if not RunService:IsStudio%(%) then%s+return")
	)
	local service = codeOnly(fs.readFile(FILES[1]))
	expect.truthy(
		string.find(service, "if RunService:IsStudio%(%) then%s+local TestHook = require%(RaidFolder%.TestHook%)"),
		"TestHook is required lazily, inside the Studio check"
	)
	expect.eq(count(service, "RaidFolder.TestHook"), 1, "and nowhere else")
	expect.truthy(string.find(service, 'assert%(RunService:IsStudio%(%), "stand%-ins are Studio%-only"%)'))
end

tests["the stand-in uses a reserved test id that no player, Studio test client included, can have"] = function()
	local hook = codeOnly(fs.readFile("src/Server/Raid/TestHook.luau"))
	expect.truthy(string.find(hook, "local STAND_IN_USER_ID = %-1_000_001%s"), "reserved id")
	local world = codeOnly(fs.readFile("src/Server/Services/DenWorldService.luau"))
	local first = string.find(world, "function DenWorldService.assignStandIn", 1, true)
	local last = string.find(world, "function DenWorldService.releaseStandIn", 1, true)
	expect.truthy(first and last, "stand-in functions found")
	local assign = string.sub(world, first :: number, last :: number)
	local release = string.sub(world, last :: number, string.find(world, "\nend\n", last :: number) :: number)
	expect.truthy(string.find(assign, "assert%(RunService:IsStudio%(%)"), "assign: Studio only")
	expect.truthy(string.find(assign, "assert%(userId <= %-1_000_000"), "assign: reserved ids only")
	expect.truthy(string.find(assign, "assert%(Players:GetPlayerByUserId%(userId%) == nil"), "assign: no player")
	expect.truthy(string.find(assign, "assert%(Plots%.plotOf%(state, userId%) == nil"), "assign: no den yet")
	expect.truthy(string.find(release, "assert%(RunService:IsStudio%(%)"), "release: Studio only")
	expect.truthy(string.find(release, "assert%(userId < 0"), "release: negative ids only")
end

tests["raid server code never reads an attribute"] = function()
	for _, path in FILES do
		expect.eq(count(codeOnly(fs.readFile(path)), "GetAttribute"), 0, path)
	end
end

tests["raid server code never writes or saves a profile"] = function()
	for _, path in FILES do
		local code = codeOnly(fs.readFile(path))
		expect.eq(count(code, "saveNow"), 0, `{path} saves a profile`)
		expect.eq(count(code, "resetDailyIfNeeded"), 0, `{path} resets daily counters`)
		expect.eq(count(code, "record" .. "Outgoing"), 0, `{path} writes a raid log`)
		if not BUILDS_FAKE_PROFILE[path] then
			expect.falsy(string.find(code, "critters%[[^%]]+%]%s*=[^=]"), `{path} assigns into a critters table`)
			expect.falsy(string.find(code, "%.placement%s*=[^=]"), `{path} changes a placement`)
		end
		expect.falsy(string.find(code, "%.padIndex%s*=[^=]"), `{path} moves a critter to a pad`)
		expect.eq(count(code, "Economy.place"), 0, `{path} places a critter`)
		expect.falsy(string.find(code, "debitDefender%s*%("), `{path} debits a defender`)
		expect.falsy(string.find(code, "creditRaider%s*%("), `{path} credits a raider`)
		for _, field in { "glow", "stored", "lossesToday" } do
			local assigns = string.find(code, '[%.%["]' .. field .. '["%]]*%s*[%+%-%*/]?=[^=]')
			expect.falsy(assigns, `{path} assigns {field}`)
		end
	end
end

return tests
