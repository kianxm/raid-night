--!strict
--[[
	Source guards for P2.8 (Lune cannot run server code):
	  - The Glow-factor helper (D-030, D-032): Economy's accrue and collect functions appear in
	    src/Server only between IncomeService's BEGIN/END GLOW FACTOR HELPER markers, so every
	    server accrue of an online player pays that player's factor. Call sites still waiting for
	    their owner's handoff are listed in PENDING, exactly, and Config.Flags.purchases must stay
	    off while any remain (the C4 gate).
	  - ProcessReceipt answers PurchaseGranted in one place, only for Economy.processReceipt's
	    "PurchaseGranted", and PurchaseService never touches Glow balances.
]]

local fs = require("@lune/fs")

local expect = require("../lib/expect")
local source = require("../lib/source")
local Config = require("../../src/Shared/Config")

local INCOME = "src/Server/Services/IncomeService.luau"
local PURCHASE = "src/Server/Services/PurchaseService.luau"
local SNAPSHOT = "src/Server/Services/SnapshotService.luau"

-- Economy functions that accrue (or collect, which accrues): only the helper may call them.
local GUARDED = { "Economy%.accrue", "Economy%.collect", "Economy%.changeGlowInputs" }

-- Factor-1 accrues of an online player outside the helper, waiting for their owner (handoffs in
-- the P2.8 PR). When one lands, remove it here; the guard fails until you do. Landed: data's
-- EscrowService loadProfile and DataService seedTestSession (P2.8b, IncomeService.accrue).
-- Snapshots (matchmaking) are tracked separately in pendingNow.
local PENDING: { [string]: number } = {}

local function count(text: string, pattern: string): number
	return select(2, string.gsub(text, pattern, ""))
end

local function serverFiles(): { string }
	local here = debug.info(1, "s")
	local root = string.match(here, "^(.*)[/\\]tests[/\\]specs[/\\][^/\\]+$")
	assert(root, `cannot find the repo root from "{here}"`)
	local found: { string } = {}
	local function walk(relative: string)
		for _, name in fs.readDir(`{root}/{relative}`) do
			local path = `{relative}/{name}`
			if fs.isDir(`{root}/{path}`) then
				walk(path)
			elseif string.match(name, "%.luau?$") then
				table.insert(found, path)
			end
		end
	end
	walk("src/Server")
	table.sort(found)
	return found
end

-- IncomeService's code with the helper cut out, and the helper itself.
local function splitHelper(): (string, string)
	local raw = source.read(INCOME)
	local b1, b2 = string.find(raw, "%-%- BEGIN GLOW FACTOR HELPER[^\n]*\n")
	local e1, e2 = string.find(raw, "%-%- END GLOW FACTOR HELPER[^\n]*\n")
	expect.truthy(b1 and e1, "IncomeService has the helper markers")
	expect.eq(count(raw, "BEGIN GLOW FACTOR HELPER"), 1, "one BEGIN marker")
	expect.eq(count(raw, "END GLOW FACTOR HELPER"), 1, "one END marker")
	expect.truthy((b2 :: number) < (e1 :: number), "BEGIN before END")
	local helper = string.sub(raw, b2 :: number, (e1 :: number) - 1)
	local rest = string.sub(raw, 1, (b1 :: number) - 1) .. string.sub(raw, (e2 :: number) + 1)
	return source.codeOnly(rest), source.codeOnly(helper)
end

-- Pending sites outside IncomeService, as they stand.
local function pendingNow(): { [string]: number }
	local sites: { [string]: number } = {}
	for _, path in serverFiles() do
		if path ~= INCOME then
			local code = source.codeOnly(source.read(path))
			local n = 0
			for _, pattern in GUARDED do
				n += count(code, pattern)
			end
			if n > 0 then
				sites[path] = n
			end
		end
	end
	-- Regression guard (landed in P2.8m): snapshots of online players must accrue through the
	-- helper before Matchmaking.buildSnapshot's factor-1 accrue.
	local snapshot = source.codeOnly(source.read(SNAPSHOT))
	if
		string.find(snapshot, "Matchmaking%.buildSnapshot%(") and not string.find(snapshot, "IncomeService%.accrue%(")
	then
		sites[SNAPSHOT] = 1
	end
	return sites
end

local tests = {}

tests["Economy's accrue and collect are called in IncomeService only inside the helper"] = function()
	local rest, helper = splitHelper()
	for _, pattern in GUARDED do
		expect.eq(count(rest, pattern), 0, `no {pattern} outside the helper in IncomeService`)
	end
	expect.truthy(count(helper, "Economy%.accrueBoosted%(") >= 1, "the helper accrues at the factor")
	expect.eq(count(helper, "Economy%.changeGlowInputs%("), 1, "one place changes the factor")
	expect.truthy(string.find(rest, "DataService%.onProfileReleasing%(releaseGlow%)"), "final accrue on leave")
end

tests["outside IncomeService, only the listed handoffs still accrue (and only that often)"] = function()
	local now = pendingNow()
	local expected = table.clone(PENDING)
	for path, n in now do
		expect.eq(expected[path], n, `{path}: unexpected accrue/collect outside the helper`)
	end
	for path, n in expected do
		expect.eq(now[path], n, `{path}: the handoff landed? remove it from PENDING`)
	end
end

tests["purchases stay off while any online accrue skips the helper (C4 gate)"] = function()
	local any = next(pendingNow()) ~= nil
	if any then
		expect.eq(Config.Flags.purchases, false, "Config.Flags.purchases with pending factor-1 accrues")
	end
end

tests["every IncomeService request accrues through the helper before its handler"] = function()
	local rest = splitHelper()
	local guarded = source.functionBody(rest, "guarded") or ""
	local accrueAt = string.find(guarded, "IncomeService%.accrue%(profile, now%)")
	local handlerAt = string.find(guarded, "handler%(player, profile, now")
	expect.truthy(accrueAt and handlerAt and accrueAt < handlerAt, "accrue, then the handler with the same now")
	local push = source.functionBody(rest, "push") or ""
	expect.truthy(string.find(push, "IncomeService%.accrue%(profile, now%)"), "push accrues through the helper")
end

tests["ProcessReceipt grants in one place, only on processReceipt's PurchaseGranted"] = function()
	local code = source.codeOnly(source.read(PURCHASE))
	expect.eq(count(code, "Enum%.ProductPurchaseDecision%.PurchaseGranted"), 1, "one PurchaseGranted")
	expect.eq(count(code, "%.ProcessReceipt%s*="), 1, "one ProcessReceipt assignment")
	expect.eq(count(code, "Economy%.processReceipt%("), 1, "one processReceipt call")
	local wrapper = source.functionBody(code, "processReceipt") or ""
	expect.truthy(string.find(wrapper, "pcall%(decide, info%)"), "errors are NotProcessedYet")
	expect.truthy(
		string.find(
			wrapper,
			'if decision == "PurchaseGranted" then\n%s*return Enum%.ProductPurchaseDecision%.PurchaseGranted'
		),
		"PurchaseGranted only for processReceipt's answer"
	)
	local decide = source.functionBody(code, "decide") or ""
	-- B1 (#127): wait for the load (and the policy) before deciding, then fetch both again.
	local waitAt = string.find(decide, "DataService%.getProfile%(userId%) ~= nil")
	local refetchAt = string.find(decide, "local profile = DataService%.getProfile%(userId%)")
	local stepsAt = string.find(decide, "Economy%.processReceipt%(")
	expect.truthy(
		waitAt and refetchAt and stepsAt and waitAt < refetchAt and refetchAt < stepsAt,
		"wait, re-fetch, decide"
	)
	expect.truthy(string.find(decide, "state%.policyDone"), "a Robux-linked first grant waits for the policy")
	expect.eq(count(decide, "IncomeService%.refresh%("), 0, "refresh runs on its own thread (refreshLater)")
	expect.truthy(string.find(decide, "Profile%.recordReceipt%("), "receipts through C6's helper")
	expect.truthy(string.find(decide, "DataService%.saveNow%("), "a confirmed save")
	expect.truthy(string.find(decide, "data%.receipts%[purchaseId%]"), "the save must hold the receipt")
end

tests["PurchaseService never touches Glow balances or sells randomness"] = function()
	local code = source.codeOnly(source.read(PURCHASE))
	for _, pattern in { "%.glow%s*[%+%-]?=", "%.stored%s*[%+%-]?=", "buyEgg", "rollTier", "EggOdds" } do
		expect.eq(count(code, pattern), 0, `no {pattern} in PurchaseService`)
	end
	for _, pattern in GUARDED do
		expect.eq(count(code, pattern), 0, `no {pattern} in PurchaseService`)
	end
	expect.truthy(string.find(code, "IncomeService%.setGlowInputs%("), "factor inputs go through the helper")
end

return tests
