--!strict
--[[
	The phase-gate test from the build plan: "zero duplicates in 1,000 simulated raids".

	Simulates many players raiding each other over about six weeks of game time, with:
	  - a server crash injected at random before the defender's first save and after any save
	  - duplicate deliveries (the same escrow driven twice)
	  - defenders moving the targeted critter into the vault mid-raid
	  - concurrent raids on the same defender
	  - pile-ons: a crowd of raiders taking turns on one den in the same hour, each for a critter
	    of its own, so dens reach live protection and the async count cap (decision D-031)
	  - Live and Async records mixed on the same defenders: each kind has its own daily loss rule
	  - Live records with and without a grab-time base (liveBaseRate, decision D-034), measured
	    before the owner reacts, and owners who move their best pad earner to Inventory during
	    the carry (shrinking the den to buy protection with one cheap loss), then put it back
	  - Live records that request no Glow (Phase 0 live steals, D-015), so live debits that take
	    nothing at all happen (D-033)
	  - players leaving after a crashed transfer and staying away 5 to 12 days, so open escrows
	    outlive the 7-day appliedTransfers retention
	  - on every join: prune appliedTransfers against the player's open-escrow index, then
	    recover each open raid, exactly as EscrowService does
	  - recovery that only touches a profile whose player is online (Escrow.recover); loading or
	    saving an away player's profile fails the run
	  - stale servers: a server whose lock on the defender was taken (it has not noticed yet)
	    recovers the raid from its copy from before the debit; all its saves of that profile fail,
	    as ProfileStore's do, so the void proof must stop it from voiding a saved debit

	Live raids happen between two online players and are driven by Escrow.advance (the call that
	creates the record, recognised by its createNonce even on a retried create); every later path
	is Escrow.recover, which never debits afresh. A same-server retry of a live call left in
	flight keeps the first call's createNonce (EscrowService), so it too drives with advance,
	sometimes after a sweep's recovery already settled or voided the raid.

	Storage behaves like DataStore: every load returns a copy, and nothing persists until saved,
	so a crash loses unsaved work exactly as a real server would. The record store enforces the
	forward-only rule (Escrow.canReplace) on every write; records and open indexes are written
	through the same pure rules as EscrowService (Escrow.decideCreate, Escrow.indexAdd).

	On every save of a profile that gains a debit, it checks the daily loss rule for the record's
	kind (Escrow invariant 4, decision D-031): a Live debit takes nothing from a den that was
	already protected, and records exactly the stolen critter's Glow/s; the day's first live loss
	sets the base to the record's liveBaseRate, or to the den's Glow/s at the debit when it has
	none, and later losses never change it (D-034); an Async debit takes nothing once the
	defender lost Config.Limits.maxLossesPerDay critters that day. It also checks invariant 5
	(D-033): a Live debit that took no critter and no Glow leaves the defender's shield, revenge
	tokens, pair count and raid log untouched; every other debit records all four.

	After every sweep and at the end, it checks:
	  1. every critter uid exists in exactly one place
	  2. Glow is conserved
	  3. a den's live losses today pass the protection line by at most its last loss
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
local Economy = require("../../src/Shared/Economy")

type PlayerProfile = Types.PlayerProfile
type EscrowRecord = Types.EscrowRecord
type EscrowOpenIndex = Types.EscrowOpenIndex
type AppliedTransfer = Types.AppliedTransfer

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
local STALE_CHANCE = 0.3 -- per drive: a stale server tries to recover the raid first
local RETRY_CHANCE = 0.5 -- per live call left in flight: the caller retries it with the same nonce
local ASYNC_CHANCE = 0.3 -- per record: an Async record (count cap) instead of a Live one (value rule)
local PILE_ON_CHANCE = 0.1 -- per raid round: a crowd takes turns on the same den
local PILE_ON_MAX = 6 -- extra raiders in a pile-on, at most
local GRAB_BASE_CHANCE = 0.5 -- per Live record: it carries the grab-time base (D-034)
local NO_GLOW_CHANCE = 0.5 -- per Live record: no Glow requested (Phase 0 live steals, D-015)
local SHRINK_CHANCE = 0.15 -- per raid round: the owner moves their best pad earner off during the carry

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
local STALE = "session lost to another server"

local function countKeys(t: { [string]: any }): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

-- The same raid-log entries, in the same order.
local function sameLog(a: { Types.RaidLogEntry }, b: { Types.RaidLogEntry }): boolean
	if #a ~= #b then
		return false
	end
	for i, entry in a do
		if entry.raidId ~= b[i].raidId then
			return false
		end
	end
	return true
end

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

	local world = {
		rng = rng,
		profiles = profiles,
		records = records,
		index = index,
		awayUntil = awayUntil,
		before = {} :: { [string]: PlayerProfile }, -- each raid's defender as saved before it began
		store = (nil :: any) :: Escrow.Store,
		now = START,
		lastLiveLoss = {} :: { [number]: number }, -- Glow/s of each den's latest live loss
		-- How often each daily loss rule was met, so a run proves it exercised them.
		stats = {
			liveTaken = 0,
			liveRefused = 0,
			protectionReached = 0,
			asyncTaken = 0,
			asyncCapped = 0,
			-- D-034: the day's first live loss, measured against the record's grab-time base or (no
			-- base on the record) the den at the debit; and how often the den had shrunk in between.
			grabBase = 0,
			debitBase = 0,
			grabBaseDiffers = 0,
			shrinkDefeated = 0, -- the shrunk den would have been protected; the grab-time base was not
			-- D-033: debits that took nothing at all.
			emptyLive = 0,
			emptyAsync = 0,
		},
	}

	-- A server can load or save only a profile it holds. Touching an away player's profile is a
	-- bug (recovery ignored presence), not an injected failure, so it fails the run.
	local function held(userId: number)
		assert(world.now >= awayUntil[userId], `touched the profile of away player {userId}`)
	end

	-- Escrow invariant 4 (decision D-031), on every save. `before` is the saved profile the debit's
	-- working copy was loaded from: nothing else saves that profile in between.
	local function checkNewDebit(before: PlayerProfile, after: PlayerProfile, raidId: string, applied: AppliedTransfer)
		local r = records[raidId]
		local target = if r.critterUid then before.critters[r.critterUid] else nil
		local onPad = target ~= nil and target.placement == "Pad"
		local stats = world.stats
		local live = Escrow.kindOf(r) == "Live"
		if live then
			local wasProtected = RaidRules.liveProtected(before, applied.at)
			if applied.critter then
				assert(not wasProtected, `{raidId}: a live debit took a critter from a protected den`)
				local today = before.lossDay == RaidRules.dayIndex(applied.at)
				local lostBefore = if today then before.liveLossRateToday or 0 else 0
				local value = Economy.critterRate(applied.critter, before.rebirths)
				expect.eq(after.liveLossRateToday, lostBefore + value, `{raidId}: live loss recorded at its Glow/s`)
				world.lastLiveLoss[after.userId] = value
				-- The base (D-034): set by the day's first live loss, never changed by a later one.
				if today and before.liveLossBaseRate ~= nil then
					expect.eq(after.liveLossBaseRate, before.liveLossBaseRate, `{raidId}: a later loss kept the base`)
				else
					local atDebit = Economy.denRate(before) -- the den the debit's working copy was loaded from
					local grab = r.liveBaseRate
					expect.eq(after.liveLossBaseRate, grab or atDebit, `{raidId}: the first loss's base`)
					if grab == nil then
						stats.debitBase += 1
					else
						stats.grabBase += 1
						local line = Config.LiveRaid.protectionLossShare
						if grab ~= atDebit then
							stats.grabBaseDiffers += 1
						end
						if value >= line * atDebit and value < line * grab then
							stats.shrinkDefeated += 1
						end
					end
				end
				stats.liveTaken += 1
				if RaidRules.liveProtected(after, applied.at) then
					stats.protectionReached += 1
				end
			elseif wasProtected and onPad then
				stats.liveRefused += 1
			end
		else
			local atCap = RaidRules.lossesToday(before, applied.at) >= Config.Limits.maxLossesPerDay
			if applied.critter then
				assert(not atCap, `{raidId}: an async debit took a critter at the daily cap`)
				stats.asyncTaken += 1
			elseif atCap and onPad then
				stats.asyncCapped += 1
			end
		end

		-- Invariant 5 (D-033): an empty live debit grants nothing; every other debit records the
		-- raid on the defender (Async unchanged, even when empty).
		local empty = applied.critter == nil and applied.glow == 0
		local pairBefore = RaidRules.pairCount(before, r.raiderUserId, applied.at)
		local pairAfter = RaidRules.pairCount(after, r.raiderUserId, applied.at)
		if live and empty then
			expect.eq(after.shieldUntil, before.shieldUntil, `{raidId}: an empty live debit gave a shield`)
			expect.eq(after.revengeTokens[raidId], nil, `{raidId}: an empty live debit gave a revenge token`)
			expect.eq(countKeys(after.revengeTokens), countKeys(before.revengeTokens), `{raidId}: revenge tokens`)
			expect.eq(pairAfter, pairBefore, `{raidId}: an empty live debit used up the pair slot`)
			expect.truthy(sameLog(before.raidLog, after.raidLog), `{raidId}: an empty live debit wrote the raid log`)
			stats.emptyLive += 1
		else
			local shield = math.max(before.shieldUntil, applied.at + Config.Shield.afterSuccessfulRaidSeconds)
			expect.eq(after.shieldUntil, shield, `{raidId}: the defender's shield`)
			expect.truthy(after.revengeTokens[raidId], `{raidId}: the defender's revenge token`)
			expect.eq(pairAfter, pairBefore + 1, `{raidId}: the pair count`)
			expect.eq(after.raidLog[1] and after.raidLog[1].raidId, raidId, `{raidId}: the raid log`)
			if empty then
				stats.emptyAsync += 1
			end
		end
	end

	local function checkSave(profile: PlayerProfile)
		local before = profiles[profile.userId]
		for raidId, applied in profile.appliedTransfers do
			if applied.role == "Debit" and before.appliedTransfers[raidId] == nil then
				checkNewDebit(before, profile, raidId, applied)
			end
		end
	end

	world.store = {
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
			held(userId)
			return deepCopy(profiles[userId])
		end,
		saveProfile = function(profile)
			held(profile.userId)
			checkSave(profile)
			profiles[profile.userId] = deepCopy(profile)
		end,
		saveProfileWithoutEntry = function(profile, raidId)
			held(profile.userId)
			checkSave(profile)
			-- This store's sessions are never stale, so the proof passes; it must never pass while
			-- a debit for the raid is saved (voiding then would strand the loot).
			assert(profile.appliedTransfers[raidId] == nil, `void proof for {raidId} with a debit in hand`)
			assert(profiles[profile.userId].appliedTransfers[raidId] == nil, `void proof for {raidId}, debit saved`)
			profiles[profile.userId] = deepCopy(profile)
		end,
	}

	return world
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

	local today = RaidRules.dayIndex(world.now)
	for userId, p in world.profiles do
		for uid in p.critters do
			place(uid, `profile {userId}`)
		end
		-- Today's live losses pass the protection line by at most the steal that crossed it.
		local base, lost = p.liveLossBaseRate, p.liveLossRateToday
		if p.lossDay == today and base and lost then
			local beforeLast = lost - world.lastLiveLoss[userId]
			local line = Config.LiveRaid.protectionLossShare * base
			expect.truthy(
				beforeLast < line,
				`{label}: {userId} lost {beforeLast} Glow/s past {line} before the last steal`
			)
		end
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
	local staleRefused = 0
	local retried = 0

	local function online(userId: number): boolean
		return world.now >= world.awayUntil[userId]
	end

	local function crashy(name: string)
		if rng.chance(CRASH_CHANCE) then
			error(CRASH .. " at " .. name)
		end
	end

	local function closeIfTerminal(raidId: string)
		local r = world.records[raidId]
		if r and Escrow.isTerminal(r) then
			world.index[r.raiderUserId][raidId] = nil
			world.index[r.defenderUserId][raidId] = nil
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
		closeIfTerminal(raidId)
	end

	-- A server that still believes it holds the defender (another server took the lock; it has
	-- not noticed) recovers from its copy from before the debit. Every save it makes of that
	-- profile fails, as ProfileStore's do once the lock is gone.
	local function staleDrive(raidId: string)
		local r = world.records[raidId]
		local defenderId = r.defenderUserId
		local debitSaved = world.profiles[defenderId].appliedTransfers[raidId] ~= nil
		local base = world.store
		local function refuse(userId: number)
			if userId == defenderId then
				error(`{STALE}: {userId}`, 0)
			end
		end
		local stale: Escrow.Store = {
			loadRecord = base.loadRecord,
			saveRecord = base.saveRecord,
			loadProfile = function(userId)
				return if userId == defenderId then deepCopy(world.before[raidId]) else base.loadProfile(userId)
			end,
			saveProfile = function(profile)
				refuse(profile.userId)
				base.saveProfile(profile)
			end,
			saveProfileWithoutEntry = function(profile, id)
				refuse(profile.userId)
				base.saveProfileWithoutEntry(profile, id)
			end,
		}
		local function present(userId: number): boolean
			return userId == defenderId or online(userId)
		end
		local ok, err = pcall(Escrow.recover, raidId, stale, world.now, present)
		if not ok and not string.find(tostring(err), STALE, 1, true) then
			error(err, 0)
		end
		if not ok and r.state == "Pending" and debitSaved then
			staleRefused += 1 -- exactly the case a void without proof would get wrong
		end
		closeIfTerminal(raidId)
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
			if rng.chance(STALE_CHANCE) then
				staleDrive(raidId)
			end
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
			-- The grab-time base (D-034): the den's Glow/s when the grab is accepted, before the
			-- owner is alerted and can react.
			local grabRate = Economy.denRate(defender)

			-- The defender reacts before the debit lands: moves the target into the vault.
			if grabbed and rng.chance(VAULT_MOVE_CHANCE) then
				local live = world.store.loadProfile(defenderId)
				if live.critters[grabbed] then
					live.critters[grabbed].placement = "Vault"
					live.critters[grabbed].padIndex = nil
					world.store.saveProfile(live)
				end
			end
			-- ...or moves every pad critter that earns more than the target to Inventory, to shrink
			-- the den so that one cheap loss reaches the protection line (the exploit D-034
			-- closes). They go back on their pads once the carries are over (below).
			local shrunk: { [string]: number } = {} -- uid -> its pad
			if grabbed and rng.chance(SHRINK_CHANCE) then
				local live = world.store.loadProfile(defenderId)
				local target = live.critters[grabbed]
				local targetRate = if target then Economy.critterRate(target, live.rebirths) else math.huge
				for uid, c in live.critters do
					if c.placement == "Pad" and c.padIndex and Economy.critterRate(c, live.rebirths) > targetRate then
						shrunk[uid] = c.padIndex
						c.placement = "Inventory"
						c.padIndex = nil
					end
				end
				if next(shrunk) then
					world.store.saveProfile(live)
				end
			end

			local raids = { { raider = raiderId, grabbed = grabbed } }
			if rng.chance(CONCURRENT_CHANCE) then
				local second = pickOnline(defenderId) -- a second raider hits the same den at once
				if second and second ~= raiderId then
					table.insert(raids, { raider = second, grabbed = grabbed })
				end
			end
			if #pads > 0 and rng.chance(PILE_ON_CHANCE) then
				-- A crowd takes turns on the den, each for a critter of its own (from the same stale
				-- snapshot): enough losses in one day to reach live protection or the async cap.
				for _ = 1, rng.int(2, PILE_ON_MAX) do
					local extra = pickOnline(defenderId)
					if extra then
						table.insert(raids, { raider = extra, grabbed = pads[rng.int(1, #pads)] })
					end
				end
			end

			for n, raid in raids do
				local thisRaider = raid.raider
				if not (online(thisRaider) and online(defenderId)) then
					continue -- the server refuses a live transfer unless both are loaded there
				end
				local raidId = if n == 1 then `raid-{i}` else `raid-{i}-{n}`
				local kind: Types.TransferKind = if rng.chance(ASYNC_CHANCE) then "Async" else "Live"
				local loot = RaidRules.lootGlow(snapshot, false)
				local base: number? = nil
				if kind == "Live" then
					loot = if rng.chance(NO_GLOW_CHANCE) then 0 else loot
					-- The first raider grabbed before the owner reacted; the crowd grabs as it arrives.
					local measured = if n == 1 then grabRate else Economy.denRate(world.profiles[defenderId])
					base = if rng.chance(GRAB_BASE_CHANCE) then measured else nil
				end
				local record =
					Escrow.create(raidId, thisRaider, defenderId, raid.grabbed, loot, false, world.now, kind, base)
				record.createNonce = `call-{raidId}`
				world.before[raidId] = deepCopy(world.profiles[defenderId])
				-- Index both parties before the record exists, as EscrowService does.
				local index = world.index
				index[thisRaider] = Escrow.indexAdd(index[thisRaider], raidId, "Raider", world.now) or index[thisRaider]
				index[defenderId] = Escrow.indexAdd(index[defenderId], raidId, "Defender", world.now)
					or index[defenderId]
				local created, ours = Escrow.decideCreate(world.records[raidId], record)
				assert(created and ours, `{raidId} is new`)
				world.store.saveRecord(created)
				table.insert(open, raidId)
				drive(raidId, true)
				if rng.chance(STALE_CHANCE) then
					staleDrive(raidId)
				end
				if not Escrow.isTerminal(world.records[raidId]) and rng.chance(RETRY_CHANCE) then
					-- transferLive returned InFlight and the caller retries with identical arguments.
					-- The server kept this call's createNonce, so the retry is still the creating
					-- call and drives with advance. A sweep's recovery may run first.
					if rng.chance(0.5) then
						drive(raidId, false)
					end
					local _, ours = Escrow.decideCreate(world.records[raidId], record)
					expect.truthy(ours, `{raidId}: a retry with the kept nonce is the creating call`)
					drive(raidId, true)
					retried += 1
				end
				if rng.chance(DUPLICATE_CHANCE) then
					-- The same work delivered twice, either path. A retried create (its first response
					-- lost) must still be recognised as this call's own.
					local _, again = Escrow.decideCreate(world.records[raidId], record)
					expect.truthy(again, `{raidId}: a retried create is this call's own`)
					drive(raidId, rng.chance(0.5))
				end
				if not Escrow.isTerminal(world.records[raidId]) then
					for _, party in { thisRaider, defenderId } do
						if online(party) and rng.chance(LEAVE_CHANCE) then
							leave(party)
						end
					end
				end
			end

			-- The carries are over: the owner puts the earners back on their pads.
			if next(shrunk) and online(defenderId) then
				local live = world.store.loadProfile(defenderId)
				for uid, padIndex in shrunk do
					local c = live.critters[uid]
					if c and c.placement == "Inventory" then
						c.placement = "Pad"
						c.padIndex = padIndex
					end
				end
				world.store.saveProfile(live)
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
	return committed, voided, protected, staleRefused, retried, world.stats
end

local tests = {}

tests["1,000 raids with crashes, duplicates, races and long absences never duplicate or lose anything"] = function()
	local committed, voided, protected, staleRefused, retried, stats = runSimulation(1)
	expect.truthy(committed >= RAIDS * 0.8, `expected most escrows to commit, got {committed}`)
	expect.truthy(voided > 0, "the void path was exercised")
	-- Without this the simulation would not prove that pruning skips open raids.
	expect.truthy(protected > 0, "a join met an open raid's entry older than the retention window")
	-- Without this it would not prove the void proof stops a stale server.
	expect.truthy(staleRefused > 0, "a stale server met a Pending record whose debit was saved")
	expect.truthy(retried > 0, "a live call left in flight was retried with its kept nonce")
	-- Without these it would not prove invariant 4 for each kind (decision D-031).
	expect.truthy(stats.protectionReached > 0, "a live steal crossed a den's protection line")
	expect.truthy(stats.liveRefused > 0, "a live debit met a protected den and took nothing")
	expect.truthy(stats.asyncCapped > 0, "an async debit met the daily count cap and took nothing")
	expect.truthy(stats.liveTaken > 0 and stats.asyncTaken > 0, "both kinds stole critters")
	-- Without these it would not prove the grab-time base (D-034) or empty live commits (D-033).
	expect.truthy(stats.grabBase > 0 and stats.debitBase > 0, "first live losses with and without a grab-time base")
	expect.truthy(stats.grabBaseDiffers > 0, "a den changed between the grab and the debit")
	expect.truthy(stats.shrinkDefeated > 0, "a shrunk den that the debit-time base would have protected")
	expect.truthy(stats.emptyLive > 0, "a live debit took nothing and granted nothing")
	expect.truthy(stats.emptyAsync > 0, "an async debit took nothing and still recorded the raid")
end

tests["the same holds across 5 more random seeds"] = function()
	for seed = 2, 6 do
		runSimulation(seed * 7919)
	end
end

return tests
