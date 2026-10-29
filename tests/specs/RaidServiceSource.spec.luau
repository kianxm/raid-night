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
}

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

tests["a Lockdown push-back shifts the carry sample by the server's move only"] = function()
	local service = codeOnly(fs.readFile(FILES[1]))
	-- Only the carry constructor sets lastPos outright; the per-sample update assigns it in a tuple.
	-- Any `.lastPos = ...` would let a push (or anything else) forgive the client's own move.
	expect.falsy(string.find(service, "%.lastPos%s*=[^=]"), "a push must never forgive the client's own move")
	expect.eq(count(service, "carry.lastPos += delta"), 1, "the push callback shifts lastPos by the push")
	local lockdown = codeOnly(fs.readFile("src/Server/Raid/Lockdown.luau"))
	expect.truthy(
		string.find(lockdown, "onPushed%(player, Vector3%.new%(x %- pos%.X, 0, z %- pos%.Z%)%)"),
		"Lockdown reports the push delta from the pre-push server position"
	)
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
		expect.falsy(string.find(code, "critters%[[^%]]+%]%s*=[^=]"), `{path} assigns into a critters table`)
		expect.falsy(string.find(code, "%.placement%s*=[^=]"), `{path} changes a placement`)
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
