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
	local presence = string.find(start, "pcall(MatchmakingService.getPresence, targetUserId)", 1, true)
	expect.truthy(presence, "presence, read under pcall")
	local failClosed = string.find(start, "if not presenceRead or presenceOk == false then", 1, true)
	expect.truthy(failClosed and failClosed > (presence :: number), "a failed presence read refuses (fail closed)")
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
	expect.eq(count(code, "EscrowService"), 0, "the escape goes through RaidService.onAsyncEscape")
	local enterFirst = string.find(code, "local function enterPocket", 1, true)
	local enter = string.sub(code, enterFirst :: number, first :: number)
	local here = string.find(enter, "Players:GetPlayerByUserId(snapshot.userId) ~= nil", 1, true)
	expect.truthy(here, "enterPocket re-checks the owner is not here, after the lock")
	local acquire = string.find(enter, "Pocket.acquire()", 1, true)
	expect.truthy(acquire and (here :: number) < acquire, "before a pocket is taken")
	expect.truthy(string.find(enter, "pcall(sendHome, player)", 1, true), "a failed entry sends the raider home")
	local escapeAt = string.find(finish, "pcall(api.onEscape", 1, true)
	local releaseAt = string.find(finish, "pcall(MatchmakingService.releaseLock", 1, true)
	expect.truthy(escapeAt and releaseAt and escapeAt < releaseAt, "the lock is held until escrow answers")
end

tests["async escape: escrow only, through transferAsync with server-tracked arguments"] = function()
	local code = codeOnly(fs.readFile(FILES[1]))
	expect.eq(count(code, "EscrowService.transferAsync"), 1, "one transferAsync call site")
	local call = string.match(code, "pcall%(%s*EscrowService%.transferAsync%s*,([^%)]*)%)")
	expect.truthy(call, "transferAsync is called through pcall")
	local args = {}
	for arg in string.gmatch(call :: string, "[^,]+") do
		table.insert(args, (string.gsub(arg, "%s", "")))
	end
	expect.eq(
		table.concat(args, ","),
		"run.raidId,run.raiderUserId,run.defenderUserId,run.critterUid,run.glowRequested,run.isRevenge",
		"every argument comes from the server-tracked escape"
	)
	local first = string.find(code, "function RaidService.onAsyncEscape", 1, true)
	local body = string.sub(code, first :: number, string.find(code, "\nend\n", first :: number) :: number)
	expect.truthy(string.find(body, "RaidRules.asyncEscapeOutcome(", 1, true), "the outcome is the pure rule's")
	expect.truthy(string.find(body, "appliedTransfers[run.raidId]", 1, true), "read from the raider's profile")
	expect.eq(count(body, "transferLive"), 0, "never the live path")
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

tests["replays: started with RaidService, recorded under pcall, saved without yielding (P1.4b)"] = function()
	local service = codeOnly(fs.readFile(FILES[1]))
	local startAt = string.find(service, "function RaidService.start", 1, true)
	expect.truthy(startAt, "RaidService.start found")
	local start = string.sub(service, startAt :: number)
	expect.eq(count(start, "pcall(ReplayStore.start, remotes"), 1, "GetReplay is registered in RaidService.start")
	expect.eq(count(service, "ReplayStore.start"), 1, "only there, and under pcall")
	local replayAt = string.find(start, "pcall(ReplayStore.start", 1, true)
	local asyncAt = string.find(start, "AsyncRaid.start(", 1, true)
	expect.truthy(replayAt and asyncAt and replayAt < asyncAt, "before AsyncRaid.start, which runs regardless")
	local code = codeOnly(fs.readFile("src/Server/Raid/AsyncRaid.luau"))
	expect.eq(count(code, "ReplayStore."), 1, "one ReplayStore call")
	expect.eq(count(code, "ReplayStore.save("), 1, "and it is the non-yielding save")
	for call in string.gmatch(code, "[%w_%.%(]*Replay%.record%a+") do
		expect.truthy(string.find(call, "^pcall%(Replay%.record"), `{call} runs under pcall`)
	end
	expect.truthy(string.find(code, "pcall(Replay.newRecorder,", 1, true), "a recorder that cannot start is skipped")
	local endFirst = string.find(code, "local function endRaid", 1, true)
	local endLast = string.find(code, "local function grab", 1, true)
	local finish = string.sub(code, endFirst :: number, endLast :: number)
	local saveAt = string.find(finish, "saveReplay(raid)", 1, true)
	local spawnAt = string.find(finish, "task.spawn(", 1, true)
	expect.truthy(saveAt and spawnAt and saveAt < spawnAt, "saved at the end, before (and apart from) escrow")
	local save = string.sub(code, string.find(code, "local function saveReplay", 1, true) :: number, endFirst :: number)
	expect.truthy(string.find(save, "pcall(function()", 1, true), "encode and save are guarded")
end

return tests
