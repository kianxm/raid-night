--!strict
--[[
	Kill switches (docs/contracts.md, approved by Kian 2026-10-28):
	  - `raids` is the master switch: no raid of any kind starts while it is off.
	  - "Async" raids and revenge raids also need `asyncRaids`.
	  - Unknown kinds are refused.
	  - Switches stop NEW transfers only. Records already in Pending or Debited always finish.
]]

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
	-- { raids, asyncRaids, kind, isRevenge, expected }
	local cases: { { any } } = {}
	for _, raids in { true, false } do
		for _, asyncRaids in { true, false } do
			table.insert(cases, { raids, asyncRaids, "Live", false, raids })
			table.insert(cases, { raids, asyncRaids, "Async", false, raids and asyncRaids })
			table.insert(cases, { raids, asyncRaids, "Async", true, raids and asyncRaids })
			table.insert(cases, { raids, asyncRaids, "Live", true, raids and asyncRaids })
			table.insert(cases, { raids, asyncRaids, "Trade", false, false })
			table.insert(cases, { raids, asyncRaids, "", false, false })
		end
	end
	for _, case in cases do
		local flags = { raids = case[1], asyncRaids = case[2] }
		local ok, reason = Escrow.canStartTransfer(flags, case[3], case[4])
		local label = `raids={case[1]} asyncRaids={case[2]} kind={case[3]} revenge={case[4]}`
		expect.eq(ok, case[5], label)
		if ok then
			expect.eq(reason, nil, `{label}: no reason when allowed`)
		else
			expect.truthy(type(reason) == "string" and #reason > 0, `{label}: says why`)
		end
	end
end

tests["recovery finishes Pending and Debited records with every switch off"] = function()
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
	}

	local raider, defender = fixtures.veteran(1, NOW), fixtures.veteran(2, NOW)
	fixtures.give(defender, fixtures.critter("fox", "crescent_fox", "Pad", 1))
	fixtures.give(defender, fixtures.critter("owl", "crescent_fox", "Pad", 2))
	defender.stored = 1000
	profiles[1], profiles[2] = raider, defender
	local glowBefore = raider.glow + raider.stored + defender.glow + defender.stored

	-- Start both while switches are on, then crash each at a different point.
	local function crashAfter(point: string)
		return function(name: string)
			if name == point then
				error("simulated crash after " .. name)
			end
		end
	end
	store.saveRecord(Escrow.create("stuck-pending", 1, 2, "fox", 100, false, NOW))
	store.saveRecord(Escrow.create("stuck-debited", 1, 2, "owl", 100, false, NOW))
	expect.falsy(pcall(Escrow.advance, "stuck-pending", store, NOW, crashAfter("savedDefender")))
	expect.falsy(pcall(Escrow.advance, "stuck-debited", store, NOW, crashAfter("savedRecordDebited")))
	expect.eq(records["stuck-pending"].state, "Pending", "debit saved, record not")
	expect.eq(records["stuck-debited"].state, "Debited")

	-- Every switch off: nothing new may start...
	local off = { raids = false, asyncRaids = false }
	for _, kind in { "Live", "Async" } do
		expect.falsy(Escrow.canStartTransfer(off, kind), `{kind} refused while off`)
	end
	-- ...but recovery takes no flags at all, and finishes both.
	for _, raidId in { "stuck-pending", "stuck-debited" } do
		local record = Escrow.advance(raidId, store, NOW + 60)
		expect.eq(record and record.state, "Committed", raidId)
	end

	-- Invariants: each uid in exactly one place, Glow conserved.
	for _, uid in { "fox", "owl" } do
		expect.eq(profiles[2].critters[uid], nil, `defender no longer has {uid}`)
		expect.truthy(profiles[1].critters[uid], `raider has {uid}`)
	end
	local glowAfter = profiles[1].glow + profiles[1].stored + profiles[2].glow + profiles[2].stored
	expect.eq(glowAfter, glowBefore, "Glow conserved")
	expect.eq(profiles[1].glow - raider.glow, 200, "raider got both raids' Glow")
end

return tests
