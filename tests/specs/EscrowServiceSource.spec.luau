--!strict
--[[
	Source guards for EscrowService and DataService (Lune cannot run them): the storage rules
	that keep escrow safe must hold in the text.
	  - Raw escrow storage (memory, the DataStore) only inside read and update (D-026), so every
	    access goes through backend() and its retries.
	  - Every escrow write stores the userIds it is about (D-008, GDPR erasure tooling).
	  - DataService writes the profiles DataStore outside ProfileStore in one place only, the
	    offline write, which never writes a profile a server holds.
	  - An async debit message only wakes recovery; async transfers never use the live path.
]]

local expect = require("../lib/expect")
local source = require("../lib/source")

local ESCROW = "src/Server/Services/EscrowService.luau"
local DATA = "src/Server/Services/DataService.luau"

local function count(text: string, pattern: string): number
	return select(2, string.gsub(text, pattern, ""))
end

-- `code` with the named functions' bodies cut out.
local function without(code: string, names: { string }): string
	for _, name in names do
		local body = source.functionBody(code, name)
		expect.truthy(body, `{name} found`)
		local first, last = string.find(code, body :: string, 1, true)
		code = string.sub(code, 1, (first :: number) - 1) .. string.sub(code, (last :: number) + 1)
	end
	return code
end

local tests = {}

tests["raw escrow storage is touched only inside read and update"] = function()
	local code = source.codeOnly(source.read(ESCROW))
	-- storage() sets the DataStore once; openEscrowFor reads (never writes) the memory index.
	local rest = without(code, { "read", "update", "storage", "openEscrowFor" })
	expect.eq(count(rest, "memory"), 1, "memory only declared outside read/update")
	expect.eq(count(rest, "dataStore"), 1, "dataStore only declared outside read/update")
	for _, call in { "GetAsync", "UpdateAsync", "SetAsync", "RemoveAsync", "IncrementAsync", "ListKeysAsync" } do
		expect.eq(count(rest, ":" .. call .. "%("), 0, `no :{call} outside read/update`)
	end
	local guard = source.functionBody(code, "openEscrowFor") or ""
	expect.eq(count(guard, "memory%b[]%s*="), 0, "openEscrowFor never writes memory")
	local storage = source.functionBody(code, "storage") or ""
	expect.eq(count(storage, "memory%["), 0, "storage() never touches memory")
end

tests["every escrow write stores the userIds it is about"] = function()
	local code = source.codeOnly(source.read(ESCROW))
	local update = source.functionBody(code, "update") or ""
	expect.truthy(string.find(update, "^function update%(key: string, userIds: { number }"), "update takes userIds")
	expect.truthy(string.find(update, "return value, userIds\n"), "the DataStore transform returns them")
	expect.eq(count(update, ":UpdateAsync%("), 1, "one UpdateAsync")
	local rest = without(code, { "update" })
	local records = count(rest, "update%(recordKey%([^\n]*{ record%.raiderUserId, record%.defenderUserId }")
	local indexes = count(rest, "update%(indexKey%(userId%), { userId }")
	expect.eq(records, 2, "record writes name both parties")
	expect.eq(indexes, 2, "index writes name their owner")
	expect.eq(count(rest, "[^%w_]update%("), records + indexes, "no other update call")
end

tests["DataService writes a profile outside ProfileStore only in the offline write, never a held one"] = function()
	local code = source.codeOnly(source.read(DATA))
	expect.eq(count(code, "GetDataStore%("), 1, "one raw DataStore")
	expect.eq(count(code, ":UpdateAsync%("), 1, "one raw write")
	for _, call in { "SetAsync", "RemoveAsync", "IncrementAsync" } do
		expect.eq(count(code, ":" .. call .. "%("), 0, `no raw {call}`)
	end
	local write = source.functionBody(code, "offlineWrite") or ""
	expect.truthy(string.find(write, "GetDataStore%(STORE_NAME%)"), "on the profiles store")
	expect.truthy(string.find(write, ":UpdateAsync%("), "the raw write is in offlineWrite")
	-- Inside the transform: a held profile is refused before fn runs, and the write keeps
	-- ProfileStore's UserIds and RobloxMetaData.
	local held = string.find(write, 'if latest%.MetaData%.ActiveSession ~= nil then%s*outcome = "held"%s*return nil')
	local prepared = string.find(write, "pcall%(Profile%.prepare, deepCopy%(latest%.Data%)")
	local ran = string.find(write, "local write, value = fn%(profile%)")
	expect.truthy(held and prepared and ran, "held check, prepare and fn found")
	expect.truthy((held :: number) < (prepared :: number) and (prepared :: number) < (ran :: number), "in that order")
	expect.truthy(
		string.find(write, "return latest, latest%.UserIds, latest%.RobloxMetaData"),
		"keeps UserIds and metadata"
	)
	-- updateOffline sends a profile loaded here back as held.
	local entry = source.functionBody(code, "DataService.updateOffline") or ""
	expect.truthy(
		string.find(entry, 'if mode == "Memory" or sessions%[userId%] or testProfiles%[userId%] then%s*return "held"'),
		"a profile held here (or any, in Memory mode) is never written offline"
	)
end

tests["an async debit accrues the defender to the debit first, on every path"] = function()
	local code = source.codeOnly(source.read(ESCROW))
	local store = source.functionBody(code, "storeFor") or ""
	-- Loaded here (and so in the defender's own server, after a message): loadProfile accrues.
	local load = string.match(store, "loadProfile = (function.-\n\t\tend),")
	expect.truthy(load, "loadProfile found")
	local accrued = string.find(load :: string, "Economy%.accrue%(profile, os%.time%(%)%)")
	local returned = string.find(load :: string, "return profile")
	expect.truthy(accrued and returned and (accrued :: number) < (returned :: number), "accrued before use")
	-- Not loaded anywhere: the offline write runs Escrow.debitAbsentProfile (accrue, then debit;
	-- Escrow.spec) and nothing else inside the one write.
	local absent = string.match(store, "debitAbsent = (function.-\n\t\tend),")
	expect.truthy(absent, "debitAbsent found")
	local write = string.match(absent :: string, "DataService%.updateOffline%(defenderId, (function.-\n\t\t\tend)%)")
	expect.truthy(write, "the offline write's fn found")
	local body = string.gsub(write :: string, "%s+", " ")
	expect.eq(
		body,
		"function(profile: PlayerProfile) return Escrow.debitAbsentProfile(profile, record, now) end",
		"it accrues and debits through Escrow.debitAbsentProfile only"
	)
end

tests["a profile save counts only when the exact entry, loot included, is saved"] = function()
	local code = source.codeOnly(source.read(ESCROW))
	local store = source.functionBody(code, "storeFor") or ""
	local save = string.match(store, "saveProfile = (function.-\n\t\tend),")
	expect.truthy(save, "saveProfile found")
	expect.truthy(string.find(save :: string, "local expected = deepCopy%(entry%)"), "the entry copied before the save")
	expect.truthy(string.find(save :: string, "return Escrow%.sameApplied%(expected, applied%)"), "matched whole")
	expect.falsy(string.find(save :: string, "applied%.role =="), "not by role and time alone")
end

tests["recovery keeps running: the sweep is guarded and each rescan runs on its own thread"] = function()
	local code = source.codeOnly(source.read(ESCROW))
	local start = source.functionBody(code, "EscrowService.start") or ""
	expect.truthy(string.find(start, "local ok, err = pcall%(sweep%)"), "the sweep loop survives an error")
	expect.eq(count(start, "[^%w_]sweep%(%)"), 0, "never called bare")
	local sweep = source.functionBody(code, "sweep") or ""
	expect.truthy(string.find(sweep, "task%.spawn%(recoverUser, userId, true%)"), "rescans spawned")
	expect.eq(count(sweep, "[^%w_.]recoverUser%(userId, true%)"), 0, "never run inline")
end

tests["an async transfer whose first record read fails, with nothing earlier in flight, is Refused"] = function()
	local code = source.codeOnly(source.read(ESCROW))
	local async = source.functionBody(code, "startAsync") or ""
	local read = string.find(async, "local readOk, existing = pcall%(read, recordKey%(raidId%)%)")
	local refused = string.find(async, 'return if earlier then "InFlight" else "Refused"')
	local firstWrite = string.find(async, "indexAdd%(")
	expect.truthy(read and refused and firstWrite, "guarded read, refusal and first write found")
	expect.truthy((refused :: number) < (firstWrite :: number), "refused before anything is written")
end

tests["a debit message only wakes recovery, and async transfers never take the live path"] = function()
	local code = source.codeOnly(source.read(ESCROW))
	local start = source.functionBody(code, "EscrowService.start") or ""
	local listener = string.match(start, "DataService%.onMessage%(DEBIT_TOPIC, (function.-\n\tend)%)")
	expect.truthy(listener, "debit listener registered at start")
	expect.truthy(string.find(listener :: string, "task%.spawn%(driveLocked, raidId, userId%)"), "it wakes recovery")
	expect.falsy(string.find(listener :: string, "Escrow%."), "and touches no escrow step itself")
	local async = source.functionBody(code, "startAsync") or ""
	expect.eq(count(async, "drive%(raidId, raiderUserId, false, false%)"), 2, "both drives recover")
	expect.eq(count(async, "drive%("), 2, "no other drive")
	expect.falsy(string.find(async, "Escrow%.advance"), "never the live path")
	expect.truthy(
		string.find(async, 'Escrow%.create%(.-"Async",%s*nil,%s*revengeRaidId%s*%)'),
		"creates an Async record carrying the revenge token, never a grab-time base"
	)
end

tests["an async transfer naming a bad revenge token is Refused before anything is read or written"] = function()
	local code = source.codeOnly(source.read(ESCROW))
	local entry = source.functionBody(code, "EscrowService.transferAsync") or ""
	expect.truthy(
		string.find(entry, "pcall%(%s*startAsync,[^%)]-isRevenge == true,%s*revengeRaidId%s*%)"),
		"transferAsync hands the token to startAsync"
	)
	local async = source.functionBody(code, "startAsync") or ""
	local check = string.find(async, 'Escrow%.checkRevengeRaidId%("Async", isRevenge, revengeRaidId%)')
	local refused = string.find(async, 'if not revengeOk then%s*return "Refused", revengeWhy')
	local created = string.find(async, "Escrow%.create%(")
	local firstRead = string.find(async, "pcall%(read, ")
	local firstWrite = string.find(async, "indexAdd%(")
	expect.truthy(check and refused and created and firstRead and firstWrite, "check, refusal, create, read, write")
	expect.truthy((check :: number) < (refused :: number), "checked, then refused")
	for name, at in { create = created, read = firstRead, write = firstWrite } do
		expect.truthy((refused :: number) < (at :: number), `refused before the {name}`)
	end
end

return tests
