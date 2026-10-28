--!strict
--[[
	The phase-gate test from the build plan: "zero duplicates in 1,000 simulated raids".

	Simulates many players raiding each other over a week of game time, with:
	  - a server crash injected at random between any two saves
	  - duplicate deliveries (the same escrow advanced twice)
	  - defenders moving the targeted critter into the vault mid-raid
	  - concurrent raids on the same defender
	  - recovery sweeps that finish whatever crashed

	Storage behaves like DataStore: every load returns a copy, and nothing persists until saved,
	so a crash loses unsaved work exactly as a real server would.

	After every sweep and at the end, it checks:
	  1. every critter uid exists in exactly one place
	  2. Glow is conserved
	  3. no defender ever exceeds the daily loss cap
	  4. both sides of every committed escrow agree
]]

local expect = require("../lib/expect")
local rngLib = require("../lib/rng")
local fixtures = require("../lib/fixtures")
local Types = require("../../src/Shared/Types")
local Escrow = require("../../src/Shared/Escrow")
local RaidRules = require("../../src/Shared/RaidRules")
local Matchmaking = require("../../src/Shared/Matchmaking")
local Config = require("../../src/Shared/Config")
local CritterCatalog = require("../../src/Shared/CritterCatalog")

type PlayerProfile = Types.PlayerProfile
type EscrowRecord = Types.EscrowRecord

local START = 1_800_000_000
local PLAYERS = 40
local CRITTERS_PER_PLAYER = 12
local RAIDS = 1000
local CRASH_CHANCE = 0.15 -- per save
local DUPLICATE_CHANCE = 0.2
local VAULT_MOVE_CHANCE = 0.1
local CONCURRENT_CHANCE = 0.1

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

local CRASH = "simulated crash"

local function newWorld(seed: number)
	local rng = rngLib.new(seed)
	local profiles: { [number]: PlayerProfile } = {}
	local records: { [string]: EscrowRecord } = {}
	local speciesIds = {}
	for _, species in CritterCatalog.all() do
		table.insert(speciesIds, species.id)
	end

	for userId = 1, PLAYERS do
		local p = fixtures.veteran(userId, START)
		p.stored = rng.int(0, 50_000)
		p.glow = rng.int(0, 10_000)
		for i = 1, CRITTERS_PER_PLAYER do
			local speciesId = speciesIds[rng.int(1, #speciesIds)]
			fixtures.give(p, fixtures.critter(`u{userId}-c{i}`, speciesId, "Pad", i))
		end
		profiles[userId] = p
	end

	local store: Escrow.Store = {
		loadRecord = function(raidId)
			local r = records[raidId]
			return if r then deepCopy(r) else nil
		end,
		saveRecord = function(record)
			records[record.raidId] = deepCopy(record)
		end,
		loadProfile = function(userId)
			return deepCopy(profiles[userId])
		end,
		saveProfile = function(profile)
			profiles[profile.userId] = deepCopy(profile)
		end,
	}

	return {
		rng = rng,
		profiles = profiles,
		records = records,
		store = store,
	}
end

-- What is in flight for one escrow: taken from the defender, not yet credited to the raider.
-- It lives in the record once Debited, or only in the defender's applied transfer if the
-- server crashed between saving the defender and saving the record.
local function inFlight(world, r: EscrowRecord): Types.AppliedTransfer?
	if Escrow.isTerminal(r) or world.profiles[r.raiderUserId].appliedTransfers[r.raidId] then
		return nil
	end
	if r.state == "Debited" then
		return { role = "Debit", at = r.updatedAt, critter = r.critter, glow = r.glow }
	end
	return world.profiles[r.defenderUserId].appliedTransfers[r.raidId]
end

local function totals(world)
	local glow = 0
	for _, p in world.profiles do
		glow += p.glow + p.stored
	end
	for _, r in world.records do
		local flight = inFlight(world, r)
		if flight then
			glow += flight.glow
		end
	end
	return glow
end

local function checkInvariants(world, expectedUids: number, expectedGlow: number, label: string)
	local seen: { [string]: string } = {}
	local count = 0
	local function place(uid: string, where: string)
		if seen[uid] then
			error(`{label}: DUPLICATE critter {uid} in {seen[uid]} and {where}`)
		end
		seen[uid] = where
		count += 1
	end

	for userId, p in world.profiles do
		for uid in p.critters do
			place(uid, `profile {userId}`)
		end
		expect.truthy(p.lossesToday <= Config.Limits.maxLossesPerDay, `{label}: loss cap exceeded for {userId}`)
	end
	for raidId, r in world.records do
		local flight = inFlight(world, r)
		if flight and flight.critter then
			place(flight.critter.uid, `in flight {raidId}`)
		end
	end

	expect.eq(count, expectedUids, `{label}: critter count (some lost)`)
	expect.eq(totals(world), expectedGlow, `{label}: Glow not conserved`)
end

local function runSimulation(seed: number)
	local world = newWorld(seed)
	local rng = world.rng
	local expectedUids = PLAYERS * CRITTERS_PER_PLAYER
	local expectedGlow = totals(world)
	local open: { string } = {}

	local function crashy(name: string)
		if rng.chance(CRASH_CHANCE) then
			error(CRASH .. " after " .. name)
		end
	end

	local function tryAdvance(raidId: string, now: number, checkpoint: ((string) -> ())?)
		local ok, err = pcall(Escrow.advance, raidId, world.store, now, checkpoint)
		if not ok and not string.find(tostring(err), CRASH, 1, true) then
			error(err, 0) -- a real bug, not an injected crash
		end
	end

	local function sweep(now: number)
		local stillOpen = {}
		for _, raidId in open do
			tryAdvance(raidId, now, crashy) -- recovery can crash too
			local r = world.records[raidId]
			if not Escrow.isTerminal(r) then
				table.insert(stillOpen, raidId)
			end
		end
		open = stillOpen
	end

	local now = START
	for i = 1, RAIDS do
		now += 600 -- 10 minutes per raid: about a week of game time in total

		local raiderId = rng.int(1, PLAYERS)
		local defenderId = rng.int(1, PLAYERS - 1)
		if defenderId >= raiderId then
			defenderId += 1
		end

		local defender = world.profiles[defenderId]
		local snapshot = Matchmaking.buildSnapshot(deepCopy(defender), now)

		-- Pick a pad critter from the (possibly stale) snapshot.
		local pads = {}
		for _, c in snapshot.critters do
			if c.placement == "Pad" then
				table.insert(pads, c.uid)
			end
		end
		local grabbed = if #pads > 0 then pads[rng.int(1, #pads)] else nil

		-- The defender reacts before the debit lands: moves the target into the vault.
		if grabbed and rng.chance(VAULT_MOVE_CHANCE) then
			local live = world.store.loadProfile(defenderId)
			if live.critters[grabbed] then
				live.critters[grabbed].placement = "Vault"
				live.critters[grabbed].padIndex = nil
				world.store.saveProfile(live)
			end
		end

		local raidIds = { `raid-{i}` }
		if rng.chance(CONCURRENT_CHANCE) then
			table.insert(raidIds, `raid-{i}-b`) -- a second raider hits the same den at once
		end

		for index, raidId in raidIds do
			local thisRaider = if index == 1 then raiderId else (raiderId % PLAYERS) + 1
			if thisRaider == defenderId then
				thisRaider = (thisRaider % PLAYERS) + 1
			end
			local record = Escrow.create(
				raidId,
				thisRaider,
				defenderId,
				grabbed,
				RaidRules.lootGlow(snapshot, false),
				false,
				now
			)
			world.store.saveRecord(record)
			table.insert(open, raidId)
			tryAdvance(raidId, now, crashy)
			if rng.chance(DUPLICATE_CHANCE) then
				tryAdvance(raidId, now, crashy) -- the same work delivered twice
			end
		end

		if i % 25 == 0 then
			sweep(now)
			checkInvariants(world, expectedUids, expectedGlow, `seed {seed} after raid {i}`)
		end
	end

	-- Final recovery: keep sweeping (crashes still possible) until everything is terminal.
	local guard = 0
	while #open > 0 do
		guard += 1
		assert(guard < 1000, "recovery never finished")
		sweep(now)
	end
	checkInvariants(world, expectedUids, expectedGlow, `seed {seed} final`)

	-- Both sides of every committed escrow agree.
	local committed = 0
	for raidId, r in world.records do
		expect.eq(r.state, "Committed", `{raidId} not committed`)
		local debit = world.profiles[r.defenderUserId].appliedTransfers[raidId]
		local credit = world.profiles[r.raiderUserId].appliedTransfers[raidId]
		expect.truthy(debit and credit, `{raidId} missing a side`)
		expect.eq(debit.glow, r.glow, `{raidId} debit glow`)
		expect.eq(credit.glow, r.glow, `{raidId} credit glow`)
		expect.eq(debit.critter and debit.critter.uid, r.critter and r.critter.uid, `{raidId} debit critter`)
		expect.eq(credit.critter and credit.critter.uid, r.critter and r.critter.uid, `{raidId} credit critter`)
		committed += 1
	end
	return committed
end

local tests = {}

tests["1,000 raids with crashes, duplicates and races never duplicate or lose anything"] = function()
	local committed = runSimulation(1)
	expect.truthy(committed >= RAIDS, `expected at least {RAIDS} escrows, got {committed}`)
end

tests["the same holds across 5 more random seeds"] = function()
	for seed = 2, 6 do
		runSimulation(seed * 7919)
	end
end

return tests
