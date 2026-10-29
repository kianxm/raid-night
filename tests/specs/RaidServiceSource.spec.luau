--!strict
--[[
	Source guards for the raid server code (no Studio needed). They pin the rules a reviewer
	would otherwise have to re-check by hand on every PR:
	  - Config.Flags is read in exactly one place, as Escrow.canStartTransfer's argument (D-002).
	  - No server decision reads an attribute (docs/contracts.md, Replicated attributes; D-014).
	  - Raid code never writes a profile or saves one (golden rule 4): no critter, placement, pad,
	    Glow, stored or loss-counter assignment, no Economy.place, no escrow debit or credit.
	  - The live protection base is measured with Economy.denRate when the grab is accepted and
	    reaches transferLive as its 7th argument on every attempt (D-034).
]]

local fs = require("@lune/fs")
local expect = require("../lib/expect")

local FILES = {
	"src/Server/Services/RaidService.luau",
	"src/Server/Raid/Lockdown.luau",
	"src/Server/Raid/TestHook.luau",
	"src/Server/Raid/AsyncRaid.luau",
	"src/Server/Raid/Pocket.luau",
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

tests["raid code reads Config.Flags only through Escrow.canStartTransfer"] = function()
	local kinds = { [FILES[1]] = "Live", ["src/Server/Raid/AsyncRaid.luau"] = "Async" }
	for _, path in FILES do
		local code = codeOnly(fs.readFile(path))
		local kind = kinds[path]
		expect.eq(count(code, "Flags"), if kind then 1 else 0, `{path}: flag reads`)
		if kind then
			local check = `Escrow.canStartTransfer(Config.Flags, "{kind}"`
			expect.eq(count(code, check), 1, `{path}: and it is the {kind} kill-switch check`)
		end
	end
end

tests["async raids: start checks, lock on every end, nothing private to the client"] = function()
	local code = codeOnly(fs.readFile("src/Server/Raid/AsyncRaid.luau"))
	local first = string.find(code, "local function startRaid", 1, true)
	local last = string.find(code, "local function onStartRaid", 1, true)
	expect.truthy(first and last, "startRaid found")
	local start = string.sub(code, first :: number, last :: number)
	expect.truthy(string.find(start, "RaidRules.canStartAsync(", 1, true), "pure start checks")
	expect.truthy(string.find(start, "SnapshotService.blockedBy(player.UserId)", 1, true), "raider's block list")
	expect.truthy(string.find(start, "MatchmakingService.getPresence(targetUserId)", 1, true), "presence")
	local lock = string.find(start, "MatchmakingService.acquireLock(", 1, true)
	local release = string.find(start, "MatchmakingService.releaseLock, targetUserId, raidId", 1, true)
	expect.truthy(lock and release and release > lock, "a failed entry releases the lock")
	local endFirst = string.find(code, "local function endRaid", 1, true)
	local endLast = string.find(code, "local function grab", 1, true)
	local finish = string.sub(code, endFirst :: number, endLast :: number)
	expect.eq(
		count(finish, "pcall(MatchmakingService.releaseLock, raid.defenderUserId, raid.raidId)"),
		1,
		"every end releases"
	)
	expect.eq(count(code, "storedGlow"), 0, "exact Glow never reaches the client")
	expect.eq(count(code, "blockedUserIds"), 0, "the block list never reaches the client")
	expect.eq(count(code, "EscrowService"), 0, "P1.3a: the escape goes through RaidService.onAsyncEscape")
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
	expect.truthy(string.find(release, "assert%(userId <= %-1_000_000"), "release: reserved ids only")
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

tests["the grab-time protection base reaches transferLive as its 7th argument (D-034)"] = function()
	local code = codeOnly(fs.readFile(FILES[1]))
	expect.eq(count(code, "EscrowService.transferLive"), 1, "one transferLive call site")
	local call = string.match(code, "pcall%(%s*EscrowService%.transferLive%s*,([^%)]*)%)")
	expect.truthy(call, "transferLive is called through pcall")
	local args = {}
	for arg in string.gmatch(call :: string, "[^,]+") do
		table.insert(args, (string.gsub(arg, "%s", "")))
	end
	expect.eq(#args, 7, "transferLive gets 7 arguments")
	expect.eq(args[7], "liveBaseRate", "the 7th is the grab-time base")
	expect.truthy(string.find(code, "local liveBaseRate = carry%.liveBaseRate"), "taken from the carry")
	expect.truthy(string.find(code, "liveBaseRate = liveBaseRate,"), "the carry keeps the hold's value")
	expect.truthy(string.find(code, "startCarry%([^%)]*hold%.liveBaseRate%)"), "the hold's value starts the carry")
	local first = string.find(code, "function RaidService.requestGrab", 1, true)
	local last = string.find(code, "function RaidService.cancelGrab", 1, true)
	expect.truthy(first and last, "requestGrab found")
	local requestGrab = string.sub(code, first :: number, last :: number)
	expect.truthy(
		string.find(requestGrab, "liveBaseRate = Economy%.denRate%(ownerProfile%)"),
		"measured with Economy.denRate in requestGrab"
	)
	expect.eq(count(code, "Economy.denRate"), 1, "and nowhere else")
end

tests["a live revenge comes only from MatchmakingService and reaches transferLive as its 6th argument"] = function()
	local code = codeOnly(fs.readFile(FILES[1]))
	local call = string.match(code, "pcall%(%s*EscrowService%.transferLive%s*,([^%)]*)%)")
	expect.truthy(call, "transferLive is called through pcall")
	local args = {}
	for arg in string.gmatch(call :: string, "[^,]+") do
		table.insert(args, (string.gsub(arg, "%s", "")))
	end
	expect.eq(args[6], "isRevenge", "the 6th is the server's revenge decision")
	expect.truthy(
		string.find(
			code,
			"local revengeRaidId = RaidRules%.liveRevengeAtEscape%(carry%.revengeRaidId, liveRevengeOf%(player%), defenderUserId%)"
		),
		"re-read at the escape, against the carry's defender"
	)
	expect.truthy(string.find(code, "local isRevenge = revengeRaidId ~= nil"), "isRevenge follows that answer")
	expect.eq(count(code, "MatchmakingService.getLiveRevenge"), 1, "one place reads the live revenge")
	expect.truthy(
		string.find(code, "RaidRules%.liveRevengeAgainst%(liveRevengeOf%(player%), ownerUserId%)"),
		"the grab is a revenge only against the den's owner"
	)
	expect.truthy(
		string.find(code, "flagsAllow = liveAllowed%(revengeRaidId ~= nil%)"),
		"a revenge grab needs asyncRaids"
	)
	expect.eq(count(code, "revengeTokens"), 0, "raid code never touches a revenge token")
end

return tests
