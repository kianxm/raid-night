--!strict
--[[
	Kill switches (docs/contracts.md; decision D-002, approved by Kian 2026-10-28):
	  - `raids` is the master switch: no raid of any kind starts while it is off.
	  - "Async" raids and revenge raids also need `asyncRaids`.
	  - Unknown kinds are refused.
	  - Switches stop NEW transfers only. Records already in Pending or Debited always finish.
]]

local fs = require("@lune/fs")
local expect = require("../lib/expect")
local fixtures = require("../lib/fixtures")
local Types = require("../../src/Shared/Types")
local Escrow = require("../../src/Shared/Escrow")

type PlayerProfile = Types.PlayerProfile
type EscrowRecord = Types.EscrowRecord

local NOW = 1_800_000_000

local function deepCopy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in value :: any do
		copy[k] = deepCopy(v)
	end
	return copy :: any
end

local tests = {}

tests["every flag combination and kind gives the approved answer"] = function()
	-- { kind, isRevenge, needs asyncRaids, known kind }
	local kinds: { { any } } = {
		{ "Live", nil, false, true },
		{ "Live", false, false, true },
		{ "Live", true, true, true },
		{ "Async", nil, true, true },
		{ "Async", false, true, true },
		{ "Async", true, true, true },
		{ "Trade", nil, false, false },
		{ "Trade", true, false, false },
		{ "", false, false, false },
	}
	for _, raids in { true, false } do
		for _, asyncRaids in { true, false } do
			for _, k in kinds do
				local expected = k[4] and raids and (asyncRaids or not k[3])
				local ok, reason = Escrow.canStartTransfer({ raids = raids, asyncRaids = asyncRaids }, k[1], k[2])
				local label = `raids={raids} asyncRaids={asyncRaids} kind={k[1]} revenge={k[2]}`
				expect.eq(ok, expected, label)
				if ok then
					expect.eq(reason, nil, `{label}: no reason when allowed`)
				else
					expect.truthy(type(reason) == "string" and #reason > 0, `{label}: says why`)
				end
			end
		end
	end
end

tests["recovery finishes records crashed at every stage with every switch off"] = function()
	local profiles: { [number]: PlayerProfile } = {}
	local records: { [string]: EscrowRecord } = {}
	local store: Escrow.Store = {
		loadRecord = function(raidId)
			local r = records[raidId]
			return if r then deepCopy(r) else nil
		end,
		saveRecord = function(record)
			local ok, why = Escrow.canReplace(records[record.raidId], record)
			assert(ok, why)
			records[record.raidId] = deepCopy(record)
		end,
		loadProfile = function(userId)
			return deepCopy(profiles[userId])
		end,
		saveProfile = function(profile)
			profiles[profile.userId] = deepCopy(profile)
		end,
		saveProfileWithoutEntry = function(profile, raidId)
			assert(profiles[profile.userId].appliedTransfers[raidId] == nil, "void proof with a saved debit")
			profiles[profile.userId] = deepCopy(profile)
		end,
	}

	local raider, defender = fixtures.veteran(1, NOW), fixtures.veteran(2, NOW)
	-- `after`: the crash point; `state`: the record it leaves; `final`: where recovery takes it.
	local stuck = {
		{ raidId = "stuck-unsaved", uid = "bat", after = "debitedUnsaved", state = "Pending", final = "Voided" },
		{ raidId = "stuck-pending", uid = "fox", after = "savedDefender", state = "Pending", final = "Committed" },
		{ raidId = "stuck-debited", uid = "owl", after = "savedRecordDebited", state = "Debited", final = "Committed" },
		{ raidId = "stuck-credited", uid = "elk", after = "savedRaider", state = "Debited", final = "Committed" },
	}
	for i, case in stuck do
		fixtures.give(defender, fixtures.critter(case.uid, "crescent_fox", "Pad", i))
	end
	defender.stored = 1000
	profiles[1], profiles[2] = raider, defender
	local glowBefore = raider.glow + raider.stored + defender.glow + defender.stored

	-- Start each while switches are on, then crash it at a different point.
	for _, case in stuck do
		store.saveRecord(Escrow.create(case.raidId, 1, 2, case.uid, 100, false, NOW))
		local ok = pcall(Escrow.advance, case.raidId, store, NOW, function(name: string)
			if name == case.after then
				error("simulated crash after " .. name)
			end
		end)
		expect.falsy(ok, `{case.raidId} crashed`)
		expect.eq(records[case.raidId].state, case.state, case.raidId)
	end

	-- Every switch off: nothing new may start...
	local off = { raids = false, asyncRaids = false }
	for _, kind in { "Live", "Async" } do
		expect.falsy(Escrow.canStartTransfer(off, kind), `{kind} refused while off`)
	end
	-- ...but recovery takes no flags at all, and finishes every one, the void path included.
	local function everyone(_userId: number): boolean
		return true
	end
	for _, case in stuck do
		local record = Escrow.recover(case.raidId, store, NOW + 60, everyone)
		expect.eq(record and record.state, case.final, case.raidId)
	end

	-- Invariants: each uid in exactly one place, Glow conserved, nothing credited twice.
	for _, case in stuck do
		local stolen = case.final == "Committed"
		expect.eq(profiles[2].critters[case.uid] == nil, stolen, `defender has {case.uid} only if voided`)
		expect.eq(profiles[1].critters[case.uid] ~= nil, stolen, `raider has {case.uid} only if committed`)
	end
	local glowAfter = profiles[1].glow + profiles[1].stored + profiles[2].glow + profiles[2].stored
	expect.eq(glowAfter, glowBefore, "Glow conserved")
	expect.eq(profiles[1].glow - raider.glow, 300, "raider got each raid's Glow exactly once")
end

-- Strips comments so the guard looks at code only.
local function codeOnly(source: string): string
	source = string.gsub(source, "%-%-%[(=*)%[.-%]%1%]", "")
	source = string.gsub(source, "%-%-[^\n]*", "")
	return source
end

-- Reads a repo file by its path from the repo root, found from this spec's own location (not
-- the working directory), so the guard checks the right file wherever `lune run` starts.
local function readRepoFile(relative: string): string
	local here = debug.info(1, "s")
	local root = string.match(here, "^(.*)[/\\]tests[/\\]specs[/\\][^/\\]+$")
	assert(root, `cannot find the repo root from this spec's path "{here}"`)
	local path = `{root}/{relative}`
	assert(fs.isFile(path), `guarded source file missing: {path}`)
	return fs.readFile(path)
end

tests["EscrowService reads Config.Flags only inside canStartTransfer"] = function()
	local code = codeOnly(readRepoFile("src/Server/Services/EscrowService.luau"))
	local first, last = string.find(code, "function EscrowService%.canStartTransfer.-\nend\n")
	expect.truthy(first and last, "canStartTransfer found")
	local inside = string.sub(code, first :: number, last :: number)
	local outside = string.sub(code, 1, (first :: number) - 1) .. string.sub(code, (last :: number) + 1)
	expect.truthy(string.find(inside, "Config.Flags", 1, true), "canStartTransfer reads Config.Flags")
	expect.falsy(string.find(outside, "Flags", 1, true), "no other code reads a flag (recovery never does)")
end

return tests
