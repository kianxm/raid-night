--!strict
--[[
	The phase-gate test from the build plan: "zero duplicates in 1,000 simulated raids".

	Simulates many players raiding each other over about six weeks of game time, with:
	  - a server crash injected at random before the defender's first save and after any save
	  - duplicate deliveries (the same escrow driven twice)
	  - defenders moving the targeted critter into the vault mid-raid
	  - concurrent raids on the same defender
	  - players leaving after a crashed transfer and staying away 5 to 12 days, so open escrows
	    outlive the 7-day appliedTransfers retention
	  - on every join: prune appliedTransfers against the player's open-escrow index, then
	    recover each open raid, exactly as EscrowService does
	  - recovery that only touches a profile whose player is online (Escrow.recover)

	Live raids happen between two online players and are driven by Escrow.advance (the call that
	creates the record); every later path is Escrow.recover, which never debits afresh.

	Storage behaves like DataStore: every load returns a copy, and nothing persists until saved,
	so a crash loses unsaved work exactly as a real server would. The record store enforces the
	forward-only rule (Escrow.canReplace) on every write.

	After every sweep and at the end, it checks:
	  1. every critter uid exists in exactly one place
	  2. Glow is conserved
	  3. no defender ever exceeds the daily loss cap
	  4. both sides of every committed escrow agree; a voided escrow moved nothing
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
type EscrowOpenIndex = Types.EscrowOpenIndex

local START = 1_800_000_000
local HOUR = 3600
local DAY = 86400
local PLAYERS = 40
local CRITTERS_PER_PLAYER = 12
local RAIDS = 1000
local CRASH_CHANCE = 0.15 -- per checkpoint
local DUPLICATE_CHANCE = 0.2
local VAULT_MOVE_CHANCE = 0.1
local CONCURRENT_CHANCE = 0.1
local LEAVE_CHANCE = 0.1 -- per party, after a transfer that did not finish

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
	local index: { [number]: EscrowOpenIndex } = {}
	local awayUntil: { [number]: number } = {}
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
		index[userId] = {}
		awayUntil[userId] = 0
	end

	local store: Escrow.Store = {
		loadRecord = function(raidId)
			local r = records[raidId]
			return if r then deepCopy(r) else nil
		end,
		saveRecord = function(record)
			-- The server's record store refuses any write that is not a forward move; every write
			-- the driver makes, including after crashes and duplicates, must pass the same rule.
			local ok, why = Escrow.canReplace(records[record.raidId], record)
			assert(ok, `record store refused {record.raidId}: {why}`)
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
		index = index,
		awayUntil = awayUntil,
		store = store,
		now = START,
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

local function sortedKeys(t: { [string]: any }): { string }
	local keys = {}
	for k in t do
		table.insert(keys, k)
	end
	table.sort(keys)
	return keys
end

local function runSimulation(seed: number)
	local world = newWorld(seed)
	local rng = world.rng
	local expectedUids = PLAYERS * CRITTERS_PER_PLAYER
	local expectedGlow = totals(world)
	local open: { string } = {}
	local away: { [number]: true } = {}
	local retention = Config.Escrow.appliedTransferRetentionSeconds
	local protected = 0

	local function online(userId: number): boolean
		return world.now >= world.awayUntil[userId]
	end

	local function crashy(name: string)
		if rng.chance(CRASH_CHANCE) then
			error(CRASH .. " at " .. name)
		end
	end

	-- `live` only for the call that created the record (EscrowService.transferLive).
	local function drive(raidId: string, live: boolean)
		local ok, err = pcall(function()
			if live then
				Escrow.advance(raidId, world.store, world.now, crashy)
			else
				Escrow.recover(raidId, world.store, world.now, online, crashy)
			end
		end)
		if not ok and not string.find(tostring(err), CRASH, 1, true) then
			error(err, 0) -- a real bug, not an injected crash
		end
		local r = world.records[raidId]
		if r and Escrow.isTerminal(r) then
			world.index[r.raiderUserId][raidId] = nil
			world.index[r.defenderUserId][raidId] = nil
		end
	end

	-- A player loads: prune against their open index, then recover each open raid.
	local function join(userId: number)
		away[userId] = nil
		local p = world.store.loadProfile(userId)
		for raidId, applied in p.appliedTransfers do
			if world.index[userId][raidId] and world.now - applied.at > retention then
				protected += 1 -- an open raid's entry past retention: the case pruning must skip
			end
		end
		Escrow.pruneApplied(p, world.now, world.index[userId])
		world.store.saveProfile(p)
		for _, raidId in sortedKeys(world.index[userId]) do
			drive(raidId, false)
		end
	end

	local function leave(userId: number)
		away[userId] = true
		world.awayUntil[userId] = world.now + rng.int(5 * 24, 12 * 24) * HOUR
	end

	local function sweep()
		local stillOpen = {}
		for _, raidId in open do
			drive(raidId, false) -- recovery can crash too
			if not Escrow.isTerminal(world.records[raidId]) then
				table.insert(stillOpen, raidId)
			end
		end
		open = stillOpen
	end

	local function pickOnline(except: number?): number?
		for _ = 1, 20 do
			local userId = rng.int(1, PLAYERS)
			if userId ~= except and online(userId) then
				return userId
			end
		end
		return nil
	end

	for i = 1, RAIDS do
		world.now += HOUR -- about six weeks of game time in total

		for userId = 1, PLAYERS do
			if away[userId] and online(userId) then
				join(userId)
			end
		end

		local raiderId = pickOnline()
		local defenderId = if raiderId then pickOnline(raiderId) else nil
		if raiderId and defenderId then
			local defender = world.profiles[defenderId]
			local snapshot = Matchmaking.buildSnapshot(deepCopy(defender), world.now)

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

			local raiders = { raiderId }
			if rng.chance(CONCURRENT_CHANCE) then
				local second = pickOnline(defenderId) -- a second raider hits the same den at once
				if second and second ~= raiderId then
					table.insert(raiders, second)
				end
			end

			for n, thisRaider in raiders do
				local raidId = if n == 1 then `raid-{i}` else `raid-{i}-b`
				local loot = RaidRules.lootGlow(snapshot, false)
				local record = Escrow.create(raidId, thisRaider, defenderId, grabbed, loot, false, world.now)
				-- Index both parties before the record exists, as EscrowService does.
				world.index[thisRaider][raidId] = { role = "Raider", createdAt = world.now }
				world.index[defenderId][raidId] = { role = "Defender", createdAt = world.now }
				world.store.saveRecord(record)
				table.insert(open, raidId)
				drive(raidId, true)
				if rng.chance(DUPLICATE_CHANCE) then
					drive(raidId, rng.chance(0.5)) -- the same work delivered twice, either path
				end
				if not Escrow.isTerminal(world.records[raidId]) then
					for _, party in { thisRaider, defenderId } do
						if online(party) and rng.chance(LEAVE_CHANCE) then
							leave(party)
						end
					end
				end
			end
		end

		if i % 25 == 0 then
			sweep()
			checkInvariants(world, expectedUids, expectedGlow, `seed {seed} after raid {i}`)
		end
	end

	-- Final recovery: everyone comes back, then keep sweeping (crashes still possible).
	for userId = 1, PLAYERS do
		world.now = math.max(world.now, world.awayUntil[userId])
	end
	world.now += HOUR
	for userId = 1, PLAYERS do
		if away[userId] then
			join(userId)
		end
	end
	local guard = 0
	while #open > 0 do
		guard += 1
		assert(guard < 1000, "recovery never finished")
		sweep()
	end
	checkInvariants(world, expectedUids, expectedGlow, `seed {seed} final`)

	-- Both sides of every committed escrow agree (where the entry was not yet legitimately
	-- pruned); a voided escrow touched neither profile.
	local committed, voided = 0, 0
	for raidId, r in world.records do
		local debit = world.profiles[r.defenderUserId].appliedTransfers[raidId]
		local credit = world.profiles[r.raiderUserId].appliedTransfers[raidId]
		if r.state == "Voided" then
			expect.falsy(debit or credit, `{raidId} voided but a profile applied it`)
			voided += 1
			continue
		end
		expect.eq(r.state, "Committed", `{raidId} not terminal`)
		for _, side in { debit, credit } do
			if side then
				expect.eq(side.glow, r.glow, `{raidId} glow`)
				expect.eq(side.critter and side.critter.uid, r.critter and r.critter.uid, `{raidId} critter`)
			end
		end
		committed += 1
	end
	for userId = 1, PLAYERS do
		expect.eq(next(world.index[userId]), nil, `open index of {userId} not empty`)
	end
	return committed, voided, protected
end

local tests = {}

tests["1,000 raids with crashes, duplicates, races and long absences never duplicate or lose anything"] = function()
	local committed, voided, protected = runSimulation(1)
	expect.truthy(committed >= RAIDS * 0.8, `expected most escrows to commit, got {committed}`)
	expect.truthy(voided > 0, "the void path was exercised")
	-- Without this the simulation would not prove that pruning skips open raids.
	expect.truthy(protected > 0, "a join met an open raid's entry older than the retention window")
end

tests["the same holds across 5 more random seeds"] = function()
	for seed = 2, 6 do
		runSimulation(seed * 7919)
	end
end

return tests
