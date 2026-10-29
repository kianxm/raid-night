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
	  - planned shrinks (decision D-036): owners who empty the den but its cheapest earner BEFORE
	    the grab, so the grab-time base itself is tiny and one cheap loss reaches the line, and
	    refill it once the carries are over, which must lift the protection again; half the time
	    a raider comes for the refilled den straight after
	  - mid-carry shrinks of a refilled den (decision D-037): when that comeback grab is accepted,
	    the owner often shrinks the den to just the carried critter before the escape lands; the
	    debit counts the record's grab-time rate, so it must still take the critter
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
	is Escrow.recover, which never debits a Live record afresh. A same-server retry of a live call
	left in flight keeps the first call's createNonce (EscrowService), so it too drives with
	advance, sometimes after a sweep's recovery already settled or voided the raid.

	Async records (P1.1) are never voided, and every path delivers their debit (Escrow.recover):
	  - async raids on away defenders too, built from their saved den
	  - the raider's server has the defender loaded only sometimes; otherwise the debit goes to
	    the defender's saved profile in one atomic write while no server holds it (an away
	    player), or as a message to the server that holds it (an online player, or a crashed
	    server's lock on an away one). That server delivers it with the defender loaded, on its
	    next save; some messages are lost, some arrive twice, all may arrive late
	  - every repeat delivery, from any server, after crashes before or after the write
	  - revenge raids (P1.3d): an async raider who holds a revenge token raids its target back,
	    usually with the token's raidId on the record (revengeRaidId), sometimes without it (a
	    record from before the raid passed it); tokens expire and are pruned on join, as
	    Profile.prepare does, so some revenge credits find their token gone

	The raider's side of a credit (P1.3d), checked on every save of any profile: a new Async
	credit that moved something adds exactly one Outgoing raid-log entry (from the record and the
	credit: the defender, the species and Glow credited, isRevenge), one pair count against the
	defender, and, for a revenge record naming a token against that defender, removes the token
	(D-054: one revenge raid per token). Nothing else does: not an empty Async credit (a failed
	revenge keeps its token), not a Live credit, not a repeat (redelivery, recovery, a crash
	before the commit), and no save outside a credit. A token is only ever added by a debit,
	never changed, and removed only by such a credit or once expired.

	Storage behaves like DataStore: every load returns a copy, and nothing persists until saved,
	so a crash loses unsaved work exactly as a real server would. The record store enforces the
	forward-only rule (Escrow.canReplace) on every write; records and open indexes are written
	through the same pure rules as EscrowService (Escrow.decideCreate, Escrow.indexAdd).

	On every save of a profile that gains a debit, it checks the daily loss rule for the record's
	kind (Escrow invariant 4, decision D-031): a Live debit takes the critter (still on its pad)
	exactly when the den is not protected, judged by the test's own copy of the rule (today's
	live losses below protectionLossShare of the larger of the day's base and the den's Glow/s
	just before the debit, D-036), and records exactly the stolen critter's Glow/s; the day's
	first live loss sets the base to the record's liveBaseRate, or to the den's Glow/s at the
	debit when it has none, and later losses never change it (D-034); an Async debit takes
	nothing once the defender lost Config.Limits.maxLossesPerDay critters that day. It also
	checks invariant 5 (D-033): a Live debit that took no critter and no Glow leaves the
	defender's shield, revenge tokens, pair count and raid log untouched; every other debit
	records all four.

	After every sweep and at the end, it checks:
	  1. every critter uid exists in exactly one place
	  2. Glow is conserved
	  3. a den's live losses today, before its last live steal, were under the protection line
	     measured at that steal's debit (D-036: the line moves with the den's Glow/s), and under
	     the line at the day's highest Glow/s seen at any of its live debits (kept apart, so a
	     bookkeeping slip in the first check cannot hide a day that lost too much)
	  4. both sides of every committed escrow agree; a voided escrow moved nothing; no Async
	     record is ever voided
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
local PLANNED_SHRINK_CHANCE = 0.1 -- per raid round: the owner empties the den but one earner before the grab (D-036)
local REFILL_RAID_CHANCE = 0.5 -- per planned shrink: a raider comes for the refilled den straight after
local CARRY_SHRINK_CHANCE = 0.5 -- per accepted comeback grab: the alerted owner shrinks the den mid-carry (D-037)
-- Async delivery (P1.1). Drawn from a second generator, so the live half's draws stay as before.
local OFFLINE_RAID_CHANCE = 0.3 -- per raid round: an async raid on any den, its owner away or not
local DEFENDER_HERE_CHANCE = 0.4 -- per async drive: an online defender is in the raider's server
local DEAD_LOCK_CHANCE = 0.15 -- per offline write: a crashed server's lock still holds the profile
local DELIVERY_FAIL_CHANCE = 0.1 -- per offline write or message: the DataStore call fails first
local NUDGE_LOSS_CHANCE = 0.15 -- per message: lost before the defender's server reads it
local NUDGE_REPEAT_CHANCE = 0.2 -- per message: delivered twice
-- Revenge raids (P1.3d). Drawn from a third generator, so the other draws are made as before.
local REVENGE_CHANCE = 0.8 -- per async raid: a raider holding a revenge token raids its target back
local REVENGE_NO_ID_CHANCE = 0.2 -- per revenge raid: the record carries no revengeRaidId
local REVENGE_AGAIN_CHANCE = 0.3 -- per revenge raid naming a token: raids back again with it

-- The test's own statement of live protection (decisions D-036, D-037), kept apart from RaidRules
-- so the simulation checks the rule rather than the implementation against itself: today's live
-- losses reach protectionLossShare of the larger of the day's base and the den's Glow/s right now
-- and, at a debit, the record's grab-time rate when it is a finite number >= 0.
local function liveLine(p: PlayerProfile, grabRate: number?): number
	local grab = if type(grabRate) == "number" and grabRate >= 0 and grabRate < math.huge then grabRate else 0
	return Config.LiveRaid.protectionLossShare * math.max(p.liveLossBaseRate :: number, Economy.denRate(p), grab)
end

local function protectedByRule(p: PlayerProfile, now: number, grabRate: number?): boolean
	local base, lost = p.liveLossBaseRate, p.liveLossRateToday
	if p.lossDay ~= RaidRules.dayIndex(now) or base == nil or lost == nil then
		return false
	end
	return lost >= liveLine(p, grabRate)
end

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

-- The same fields with the same values (flat tables, such as revenge tokens).
local function same(a: { [string]: any }, b: { [string]: any }): boolean
	for k, v in a do
		if b[k] ~= v then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
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

	local nudges: { [number]: { string } } = {}
	for userId = 1, PLAYERS do
		nudges[userId] = {}
	end

	local world = {
		rng = rng,
		arng = rngLib.new(seed * 31 + 7), -- async delivery's draws
		rrng = rngLib.new(seed * 53 + 11), -- revenge raids' draws (P1.3d)
		profiles = profiles,
		records = records,
		index = index,
		awayUntil = awayUntil,
		nudges = nudges, -- debit messages waiting in each profile's queue (raidIds)
		viaNudge = false, -- a message's delivery is running
		-- The highest Glow/s any line input reached at a den's live debits today (invariant 3).
		dayHigh = {} :: { [number]: { day: number, rate: number } },
		before = {} :: { [string]: PlayerProfile }, -- each raid's defender as saved before it began
		store = (nil :: any) :: Escrow.Store,
		now = START,
		lastLiveLoss = {} :: { [number]: number }, -- Glow/s of each den's latest live loss
		-- The protection line (D-036) at each den's latest live loss, measured just before its debit.
		lastLiveLine = {} :: { [number]: number },
		-- Raids whose grab RaidService would accept (the den not protected then), carrying their grab
		-- rate, whose owner may shrink the den mid-carry: the debit must take the critter (D-037).
		mustTake = {} :: { [string]: true },
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
			-- D-036: planned shrinks (emptied before the grab, refilled after the carries), and live
			-- steals that landed only because the den's Glow/s now outweighed the day's base: the base
			-- alone (D-034) would have kept the den protected.
			plannedShrinks = 0,
			refillReopened = 0,
			-- D-037: owners who shrank a refilled den during the carry, and live steals that landed
			-- only because the debit counted the grab's rate: the den as it was at the debit was
			-- protected.
			carryShrinks = 0,
			carryShrinkDefeated = 0,
			-- D-033: debits that took nothing at all.
			emptyLive = 0,
			emptyAsync = 0,
			-- P1.1: async debits written to an unheld profile, repeats that found them already
			-- there, messages sent (a crashed server's lock among them) and debits they delivered.
			offlineDebits = 0,
			offlineRepeats = 0,
			messages = 0,
			deadLocks = 0,
			messageDebits = 0,
			-- P1.3d, the raider's side: Async credits that logged the raid, empty Async credits and
			-- Live credits that recorded nothing, credits saved again while their record was still
			-- Debited (a repeat must change nothing), revenge raids, their credits that used a token's
			-- token (D-054: removed it), found it gone (spent by another revenge, or expired), or
			-- named none.
			outgoingLogged = 0,
			emptyAsyncCredits = 0,
			liveCredits = 0,
			creditRepeats = 0,
			revengeRaids = 0,
			revengeSpent = 0,
			revengeTokenGone = 0,
			revengeNoId = 0,
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
			-- D-036 and D-037, both ways: protected by the rule at the debit (the record's grab-time
			-- rate counted) <=> the debit leaves the critter on its pad. RaidRules.liveProtected (what
			-- canGrabLive and the den attribute read, without the record) agrees with the rule too.
			local wasProtected = protectedByRule(before, applied.at, r.liveBaseRate)
			local denProtected = protectedByRule(before, applied.at, nil)
			expect.eq(
				RaidRules.liveProtected(before, applied.at),
				denProtected,
				`{raidId}: liveProtected disagrees with the rule`
			)
			expect.eq(
				RaidRules.liveProtectedAtDebit(before, applied.at, r.liveBaseRate),
				wasProtected,
				`{raidId}: liveProtectedAtDebit disagrees with the rule`
			)
			if onPad then
				expect.eq(
					applied.critter ~= nil,
					not wasProtected,
					`{raidId}: a live debit on an open den takes the critter`
				)
			end
			if world.mustTake[raidId] and onPad then
				expect.truthy(applied.critter, `{raidId}: a grab accepted before a mid-carry shrink still lands`)
			end
			if applied.critter then
				assert(not wasProtected, `{raidId}: a live debit took a critter from a protected den`)
				if denProtected then
					stats.carryShrinkDefeated += 1 -- the grab's rate let it land (D-037)
				end
				local today = before.lossDay == RaidRules.dayIndex(applied.at)
				local lostBefore = if today then before.liveLossRateToday or 0 else 0
				local value = Economy.critterRate(applied.critter, before.rebirths)
				expect.eq(after.liveLossRateToday, lostBefore + value, `{raidId}: live loss recorded at its Glow/s`)
				world.lastLiveLoss[after.userId] = value
				-- The line this steal was under (invariant 3): with the base it is judged against, which
				-- is the record's or the debit's own on the day's first loss.
				local judged = table.clone(before)
				judged.liveLossBaseRate = after.liveLossBaseRate
				world.lastLiveLine[after.userId] = liveLine(judged, r.liveBaseRate)
				-- The day's high (invariant 3): the largest line input at any of today's live debits.
				local day = RaidRules.dayIndex(applied.at)
				local high = world.dayHigh[after.userId]
				if high == nil or high.day ~= day then
					high = { day = day, rate = 0 }
					world.dayHigh[after.userId] = high
				end
				local grabRate = if type(r.liveBaseRate) == "number" then r.liveBaseRate else 0
				high.rate = math.max(high.rate, after.liveLossBaseRate :: number, Economy.denRate(before), grabRate)
				local baseBefore = if today then before.liveLossBaseRate else nil
				if baseBefore and lostBefore >= Config.LiveRaid.protectionLossShare * baseBefore then
					stats.refillReopened += 1 -- the day's base alone would have refused it (D-034)
				end
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

		-- Glow (P1.1): a Live debit takes up to its request; an Async one its share of what is
		-- stored at the debit (the snapshot's figure plays no part). Never more than is stored.
		local stored = math.max(math.floor(before.stored), 0)
		local bonus = if r.isRevenge then 1 + Config.Loot.revengeBonus else 1
		local glowRule = if live
			then math.min(stored, r.glowRequested)
			else math.floor(stored * Config.Loot.storedGlowShare * bonus)
		expect.eq(applied.glow, glowRule, `{raidId}: the Glow a {Escrow.kindOf(r)} debit takes`)
		expect.eq(after.stored, before.stored - applied.glow, `{raidId}: taken from storage`)

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

	-- The raider's side of a credit (P1.3d), on every save of any profile. Works out what the save
	-- may change from the entries it adds (a debit: the pair count against its raider; an Async
	-- credit that moved something: the pair count against its defender, the Outgoing log entry and
	-- the revenge token's flag), then checks that exactly that changed. A repeat adds no entry, so
	-- it must change none of them; neither may any save outside a debit or a credit.
	local function checkRaiderSide(before: PlayerProfile, after: PlayerProfile)
		local now = world.now
		local stats = world.stats
		local logged: { [string]: AppliedTransfer } = {} -- new credits that must log their raid
		local counted: { [string]: number } = {} -- other userId -> new pair counts this save adds
		local spends: { [string]: number } = {} -- revenge token raidId -> the defender it must target
		for raidId, applied in after.appliedTransfers do
			local r = records[raidId]
			if before.appliedTransfers[raidId] ~= nil then
				if applied.role == "Credit" and r.state == "Debited" then
					stats.creditRepeats += 1 -- credited before; the record has not caught up yet
				end
				continue
			end
			local empty = applied.critter == nil and applied.glow == 0
			local async = Escrow.kindOf(r) == "Async"
			if applied.role == "Debit" then
				if async or not empty then -- D-033: an empty live debit counts nothing
					local key = tostring(r.raiderUserId)
					counted[key] = (counted[key] or 0) + 1
				end
			elseif not async then
				stats.liveCredits += 1
			elseif empty then
				stats.emptyAsyncCredits += 1
			else
				logged[raidId] = applied
				local key = tostring(r.defenderUserId)
				counted[key] = (counted[key] or 0) + 1
				if r.revengeRaidId then
					spends[r.revengeRaidId] = r.defenderUserId
				elseif r.isRevenge then
					stats.revengeNoId += 1
				end
			end
		end

		-- Pair counts move only with this save's new debits and credits.
		local keys: { [string]: true } = {}
		for _, list in { before.pairRaidsToday, after.pairRaidsToday, counted } :: { { [string]: number } } do
			for key in list do
				keys[key] = true
			end
		end
		for key in keys do
			local other = tonumber(key) :: number
			expect.eq(
				RaidRules.pairCount(after, other, now),
				RaidRules.pairCount(before, other, now) + (counted[key] or 0),
				`{after.userId}: the pair count with {key} moves only with a new debit or credit`
			)
		end

		-- Outgoing entries: one per credit that moved something, from its record and credit, once.
		local had: { [string]: true } = {}
		for _, entry in before.raidLog do
			if entry.direction == "Outgoing" then
				had[entry.raidId] = true
			end
		end
		local seen: { [string]: true } = {}
		for _, entry in after.raidLog do
			if entry.direction ~= "Outgoing" then
				continue
			end
			local raidId = entry.raidId
			expect.falsy(seen[raidId], `{raidId}: the raider's log holds it once`)
			seen[raidId] = true
			if had[raidId] then
				continue
			end
			local applied = logged[raidId]
			expect.truthy(applied, `{raidId}: an Outgoing entry appears only with its raid's credit`)
			local r = records[raidId]
			expect.eq(entry.otherUserId, r.defenderUserId, `{raidId}: logged against the defender`)
			expect.eq(entry.escaped, true, `{raidId}: logged as escaped`)
			expect.eq(entry.speciesId, if applied.critter then applied.critter.speciesId else nil, `{raidId}: species`)
			expect.eq(entry.glow, applied.glow, `{raidId}: the Glow credited, never the estimate`)
			expect.eq(entry.isRevenge, r.isRevenge, `{raidId}: revenge`)
			expect.eq(entry.at, applied.at, `{raidId}: logged at the credit`)
		end
		for raidId in logged do
			expect.truthy(seen[raidId] and not had[raidId], `{raidId}: a credit that moved something logs it`)
			stats.outgoingLogged += 1
		end

		-- Revenge tokens: added only by a debit and never changed; removed by a revenge credit
		-- against their target (D-054: one revenge raid per token), which must remove it, or once
		-- expired (pruning on load), and by nothing else.
		for id, token in after.revengeTokens do
			local was = before.revengeTokens[id]
			if was == nil then
				local applied = after.appliedTransfers[id]
				expect.truthy(
					applied and applied.role == "Debit" and before.appliedTransfers[id] == nil,
					`{after.userId}: token {id} appears only with its raid's debit`
				)
				continue
			end
			expect.truthy(same(token, was), `{id}: a kept token never changes`)
			expect.falsy(spends[id] == was.targetUserId, `{id}: a revenge credit against its target removes it`)
		end
		for id, was in before.revengeTokens do
			if after.revengeTokens[id] == nil then
				local spend = spends[id] == was.targetUserId
				expect.truthy(
					spend or now >= was.expiresAt,
					`{after.userId}: token {id} removed only by its revenge or expiry`
				)
				if spend then
					stats.revengeSpent += 1
				end
			end
		end
		for id in spends do
			if before.revengeTokens[id] == nil then
				stats.revengeTokenGone += 1
			end
		end
	end

	local function checkSave(profile: PlayerProfile)
		local before = profiles[profile.userId]
		for raidId, applied in profile.appliedTransfers do
			if applied.role == "Debit" and before.appliedTransfers[raidId] == nil then
				checkNewDebit(before, profile, raidId, applied)
				if world.viaNudge then
					world.stats.messageDebits += 1
				end
			end
		end
		checkRaiderSide(before, profile)
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
		-- An async debit for a defender the driving server does not hold (EscrowService over
		-- DataService.updateOffline and sendMessage).
		debitAbsent = function(record, now)
			local arng = world.arng
			if arng.chance(DELIVERY_FAIL_CHANCE) then
				error(`{CRASH}: DataStore call failed`)
			end
			local userId = record.defenderUserId
			local away = world.now < awayUntil[userId]
			local deadLock = away and arng.chance(DEAD_LOCK_CHANCE)
			if not away or deadLock then
				-- A server holds the profile (or a crashed one's lock does): the offline write is
				-- refused, and the debit goes to that profile's message queue.
				table.insert(world.nudges[userId], record.raidId)
				world.stats.messages += 1
				world.stats.deadLocks += if deadLock then 1 else 0
				return nil
			end
			-- One atomic write on the latest saved profile; nothing to write if already debited.
			local p = deepCopy(profiles[userId])
			local had = p.appliedTransfers[record.raidId] ~= nil
			local applied = Escrow.debitDefender(p, record, now)
			if had then
				world.stats.offlineRepeats += 1
			else
				checkSave(p)
				profiles[userId] = p
				world.stats.offlineDebits += 1
			end
			return deepCopy(applied)
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
		-- Today's live losses before the den's last live steal were under the line measured at that
		-- steal's debit (D-036: the line moves with the den, so it is the one from that moment).
		local base, lost = p.liveLossBaseRate, p.liveLossRateToday
		if p.lossDay == today and base and lost then
			local beforeLast = lost - world.lastLiveLoss[userId]
			local line = world.lastLiveLine[userId]
			expect.truthy(
				beforeLast < line,
				`{label}: {userId} lost {beforeLast} Glow/s past {line} before the last steal`
			)
			-- The day-high bound (C5 note): kept from every live debit today, apart from `line`.
			local high = world.dayHigh[userId]
			local dayLine = if high and high.day == today then Config.LiveRaid.protectionLossShare * high.rate else 0
			expect.truthy(
				beforeLast < dayLine,
				`{label}: {userId} lost {beforeLast} Glow/s past the day-high line {dayLine}`
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

	-- `live` only for the call that created a Live record (EscrowService.transferLive); an Async
	-- record is driven by recover on every path (EscrowService.transferAsync too). `present`: who
	-- is loaded in the driving server; by default every online player.
	local function drive(raidId: string, live: boolean, present: ((number) -> boolean)?)
		local r = world.records[raidId]
		local async = r ~= nil and Escrow.kindOf(r) == "Async"
		local ok, err = pcall(function()
			if live and not async then
				Escrow.advance(raidId, world.store, world.now, crashy)
			else
				Escrow.recover(raidId, world.store, world.now, present or online, crashy)
			end
		end)
		if not ok and not string.find(tostring(err), CRASH, 1, true) then
			error(err, 0) -- a real bug, not an injected crash
		end
		closeIfTerminal(raidId)
	end

	-- The raider's server, for one async drive: the raider is loaded there, and an online
	-- defender only sometimes (otherwise in another server, reached by message).
	local function raiderServer(raider: number, defender: number): (number) -> boolean
		local defenderHere = online(defender) and world.arng.chance(DEFENDER_HERE_CHANCE)
		return function(userId: number): boolean
			return (userId == raider and online(raider)) or (userId == defender and defenderHere)
		end
	end

	-- Each online player's server reads its message queue (on its next save) and recovers each
	-- raid with that player loaded and the other party elsewhere. Messages can be lost or come
	-- twice; recovery from the open indexes finishes what a lost one leaves.
	local function deliverNudges()
		for userId = 1, PLAYERS do
			local queue = world.nudges[userId]
			if #queue == 0 or not online(userId) then
				continue
			end
			world.nudges[userId] = {}
			local function here(id: number): boolean
				return id == userId
			end
			for _, raidId in queue do
				local times = if world.arng.chance(NUDGE_LOSS_CHANCE)
					then 0
					elseif world.arng.chance(NUDGE_REPEAT_CHANCE) then 2
					else 1
				for _ = 1, times do
					world.viaNudge = true
					drive(raidId, false, here)
					world.viaNudge = false
				end
			end
		end
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

	-- A player loads: prune against their open index (and expired revenge tokens, as
	-- Profile.prepare does), then recover each open raid.
	local function join(userId: number)
		away[userId] = nil
		local p = world.store.loadProfile(userId)
		for raidId, applied in p.appliedTransfers do
			if world.index[userId][raidId] and world.now - applied.at > retention then
				protected += 1 -- an open raid's entry past retention: the case pruning must skip
			end
		end
		Escrow.pruneApplied(p, world.now, world.index[userId])
		RaidRules.pruneRevengeTokens(p, world.now)
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

	-- One live or async steal by `thisRaider` for `grabbed` (from `snapshot`), created and driven
	-- as EscrowService does, with injected retries, duplicates, stale servers and departures.
	-- `measured` is the den's Glow/s when the grab was accepted (the record may carry it, D-034).
	-- `raidService`: a live steal exactly as RaidService makes it, a "Live" record that always
	-- carries `measured`.
	local function transfer(
		raidId: string,
		thisRaider: number,
		defenderId: number,
		grabbed: string?,
		snapshot: Types.DenSnapshot,
		measured: number,
		raidService: boolean?,
		offlineRaid: boolean?, -- an async raid from the snapshot, its owner online or away
		revenge: { id: string? }? -- an async revenge raid (P1.3d), with the token's raidId or none
	)
		local kind: Types.TransferKind = if offlineRaid
			then "Async"
			elseif rng.chance(ASYNC_CHANCE) and not raidService then "Async"
			else "Live"
		local isRevenge = revenge ~= nil
		assert(not isRevenge or kind == "Async", "revenge raids here are async raids")
		local loot = RaidRules.lootGlow(snapshot, isRevenge)
		local base: number? = nil
		if kind == "Live" then
			loot = if rng.chance(NO_GLOW_CHANCE) then 0 else loot
			base = if rng.chance(GRAB_BASE_CHANCE) or raidService then measured else nil
		end
		local revengeRaidId = if revenge then revenge.id else nil
		local record = Escrow.create(
			raidId,
			thisRaider,
			defenderId,
			grabbed,
			loot,
			isRevenge,
			world.now,
			kind,
			base,
			revengeRaidId
		)
		record.createNonce = `call-{raidId}`
		world.before[raidId] = deepCopy(world.profiles[defenderId])
		-- Index both parties before the record exists, as EscrowService does.
		local index = world.index
		index[thisRaider] = Escrow.indexAdd(index[thisRaider], raidId, "Raider", world.now) or index[thisRaider]
		index[defenderId] = Escrow.indexAdd(index[defenderId], raidId, "Defender", world.now) or index[defenderId]
		local created, ours = Escrow.decideCreate(world.records[raidId], record)
		assert(created and ours, `{raidId} is new`)
		world.store.saveRecord(created)
		table.insert(open, raidId)
		-- An async raid's own server holds the raider; the defender only sometimes.
		local function own(): ((number) -> boolean)?
			return if kind == "Async" then raiderServer(thisRaider, defenderId) else nil
		end
		drive(raidId, true, own())
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
			drive(raidId, true, own())
			retried += 1
		end
		if rng.chance(DUPLICATE_CHANCE) then
			-- The same work delivered twice, either path. A retried create (its first response
			-- lost) must still be recognised as this call's own.
			local _, again = Escrow.decideCreate(world.records[raidId], record)
			expect.truthy(again, `{raidId}: a retried create is this call's own`)
			drive(raidId, rng.chance(0.5), own())
		end
		if not Escrow.isTerminal(world.records[raidId]) then
			for _, party in { thisRaider, defenderId } do
				if online(party) and rng.chance(LEAVE_CHANCE) then
					leave(party)
				end
			end
		end
	end

	for i = 1, RAIDS do
		world.now += HOUR -- about six weeks of game time in total

		for userId = 1, PLAYERS do
			if away[userId] and online(userId) then
				join(userId)
			end
		end
		deliverNudges()

		local raiderId = pickOnline()
		local defenderId = if raiderId then pickOnline(raiderId) else nil
		if raiderId and defenderId then
			-- Critters the owner takes out of the den this round, and where they go back afterwards.
			local shrunk: { [string]: { placement: Types.Placement, padIndex: number? } } = {}
			local planned = false

			-- A planned shrink (D-036): before anyone grabs, the owner moves every earner but the
			-- cheapest pad critter (ties by uid) to Inventory, vault included, so the grab-time base
			-- is that one critter and losing it to an alt reaches the line. The den is refilled once
			-- the carries are over (below), which must lift the protection that loss bought.
			if rng.chance(PLANNED_SHRINK_CHANCE) then
				local live = world.store.loadProfile(defenderId)
				local keep: string?, keepRate = nil, math.huge
				for uid, c in live.critters do
					local rate = Economy.critterRate(c, live.rebirths)
					if c.placement == "Pad" and (rate < keepRate or (rate == keepRate and uid < (keep :: string))) then
						keep, keepRate = uid, rate
					end
				end
				for uid, c in live.critters do
					if uid ~= keep and (c.placement == "Pad" or c.placement == "Vault") then
						shrunk[uid] = { placement = c.placement, padIndex = c.padIndex }
						c.placement = "Inventory"
						c.padIndex = nil
					end
				end
				if next(shrunk) then
					world.store.saveProfile(live)
					world.stats.plannedShrinks += 1
					planned = true
				end
			end

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
			if grabbed and rng.chance(SHRINK_CHANCE) then
				local live = world.store.loadProfile(defenderId)
				local target = live.critters[grabbed]
				local targetRate = if target then Economy.critterRate(target, live.rebirths) else math.huge
				local moved = false
				for uid, c in live.critters do
					if c.placement == "Pad" and c.padIndex and Economy.critterRate(c, live.rebirths) > targetRate then
						shrunk[uid] = { placement = c.placement, padIndex = c.padIndex }
						c.placement = "Inventory"
						c.padIndex = nil
						moved = true
					end
				end
				if moved then
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
				-- The server refuses a live transfer unless both are loaded there.
				if online(raid.raider) and online(defenderId) then
					local raidId = if n == 1 then `raid-{i}` else `raid-{i}-{n}`
					-- The first raider grabbed before the owner reacted; the crowd grabs as it arrives.
					local measured = if n == 1 then grabRate else Economy.denRate(world.profiles[defenderId])
					-- A planned shrink's cheap loss is a live steal (an alt's, or a carry the owner let
					-- land), made as RaidService makes it.
					transfer(raidId, raid.raider, defenderId, raid.grabbed, snapshot, measured, planned and n == 1)
				end
			end

			-- The carries are over: the owner puts the earners back where they were (a refill).
			if next(shrunk) and online(defenderId) then
				local live = world.store.loadProfile(defenderId)
				for uid, was in shrunk do
					local c = live.critters[uid]
					if c and c.placement == "Inventory" then
						c.placement = was.placement
						c.padIndex = was.padIndex
					end
				end
				world.store.saveProfile(live)

				-- After a planned shrink, a raider sometimes comes for the refilled den the same day
				-- (D-036): whatever protection the shrunk den's cheap loss bought must not hold now.
				local comer = if planned and rng.chance(REFILL_RAID_CHANCE) then pickOnline(defenderId) else nil
				if comer then
					local refilled = world.profiles[defenderId]
					local seen = Matchmaking.buildSnapshot(deepCopy(refilled), world.now)
					local fresh = {}
					for _, c in seen.critters do
						if c.placement == "Pad" then
							table.insert(fresh, c.uid)
						end
					end
					if #fresh > 0 then
						local raidId = `raid-{i}-refill`
						local measured = Economy.denRate(refilled)
						-- RaidService refuses the grab while the den is protected (no record then). An
						-- accepted grab's record carries the rate it measured, and the owner, alerted,
						-- may shrink the den to just the carried critter before the escape lands
						-- (D-037): that must not refuse the steal.
						local accepted = not protectedByRule(refilled, world.now, nil)
						local carryShrink = accepted and rng.chance(CARRY_SHRINK_CHANCE)
						local target = fresh[rng.int(1, #fresh)]
						if carryShrink or rng.chance(0.5) then
							-- The cheapest pad critter (ties by uid): shrinking the den to a critter that
							-- earns at most twice the day's loss is what would protect it again.
							local cheapest = math.huge
							for _, uid in fresh do
								local rate = Economy.critterRate(refilled.critters[uid], refilled.rebirths)
								if rate < cheapest or (rate == cheapest and uid < target) then
									target, cheapest = uid, rate
								end
							end
						end
						local hidden: { [string]: { placement: Types.Placement, padIndex: number? } } = {}
						if carryShrink then
							local live = world.store.loadProfile(defenderId)
							for uid, c in live.critters do
								if uid ~= target and (c.placement == "Pad" or c.placement == "Vault") then
									hidden[uid] = { placement = c.placement, padIndex = c.padIndex }
									c.placement = "Inventory"
									c.padIndex = nil
								end
							end
							if next(hidden) then
								world.store.saveProfile(live)
								world.stats.carryShrinks += 1
							end
						end
						if accepted then
							world.mustTake[raidId] = true
						end
						transfer(raidId, comer, defenderId, target, seen, measured, accepted)
						-- The carry is over: the earners go back.
						if next(hidden) and online(defenderId) then
							local back = world.store.loadProfile(defenderId)
							for uid, was in hidden do
								local c = back.critters[uid]
								if c and c.placement == "Inventory" then
									c.placement = was.placement
									c.padIndex = was.padIndex
								end
							end
							world.store.saveProfile(back)
						end
					end
				end
			end
		end

		-- An async raid (P1.1) from a snapshot of any other den, whose owner may be away.
		local arng = world.arng
		local asyncRaider = if arng.chance(OFFLINE_RAID_CHANCE) then pickOnline() else nil
		local target = arng.int(1, PLAYERS)
		-- A raider holding an unexpired revenge token sometimes raids its target back instead
		-- (P1.3d); the record names the token, or does not.
		local rrng = world.rrng
		local revenge: { id: string? }? = nil
		if asyncRaider and rrng.chance(REVENGE_CHANCE) then
			local held: { Types.RevengeToken } = {}
			local tokens = world.profiles[asyncRaider].revengeTokens
			for _, id in sortedKeys(tokens) do
				local token = tokens[id]
				if world.now < token.expiresAt and token.targetUserId ~= asyncRaider then
					table.insert(held, token)
				end
			end
			if #held > 0 then
				local token = held[rrng.int(1, #held)]
				target = token.targetUserId
				revenge = { id = if rrng.chance(REVENGE_NO_ID_CHANCE) then nil else token.raidId }
			end
		end
		if asyncRaider and target ~= asyncRaider then
			local seen = Matchmaking.buildSnapshot(deepCopy(world.profiles[target]), world.now)
			local pads = {}
			for _, c in seen.critters do
				if c.placement == "Pad" then
					table.insert(pads, c.uid)
				end
			end
			if #pads > 0 then
				local measured = Economy.denRate(world.profiles[target])
				if revenge then
					world.stats.revengeRaids += 1
				end
				transfer(
					`async-{i}`,
					asyncRaider,
					target,
					pads[arng.int(1, #pads)],
					seen,
					measured,
					false,
					true,
					revenge
				)
				-- The same token again, started while the first raid's credit was still in flight
				-- (StartRaid still saw the token): whichever credit lands first removes it, and the
				-- other finds it gone.
				if revenge and revenge.id and online(asyncRaider) and rrng.chance(REVENGE_AGAIN_CHANCE) then
					world.stats.revengeRaids += 1
					local grab = pads[rrng.int(1, #pads)]
					transfer(`async-{i}-again`, asyncRaider, target, grab, seen, measured, false, true, revenge)
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
		deliverNudges()
		sweep()
	end
	-- Late and repeated messages for raids already settled change nothing.
	deliverNudges()
	checkInvariants(world, expectedUids, expectedGlow, `seed {seed} final`)

	-- Both sides of every committed escrow agree (where the entry was not yet legitimately
	-- pruned); a voided escrow touched neither profile.
	local committed, voided = 0, 0
	for raidId, r in world.records do
		local debit = world.profiles[r.defenderUserId].appliedTransfers[raidId]
		local credit = world.profiles[r.raiderUserId].appliedTransfers[raidId]
		if r.state == "Voided" then
			expect.eq(Escrow.kindOf(r), "Live", `{raidId}: an Async record is never voided`)
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
	-- Without these it would not prove that a refill lifts protection (D-036).
	expect.truthy(stats.plannedShrinks > 0, "an owner emptied the den before the grab and refilled it after")
	expect.truthy(stats.refillReopened > 0, "a live steal landed on a den the day's base alone would protect")
	-- Without these it would not prove that a mid-carry shrink cannot refuse the steal (D-037).
	expect.truthy(stats.carryShrinks > 0, "an owner shrank a refilled den during the carry")
	expect.truthy(stats.carryShrinkDefeated > 0, "a debit landed only because it counted the grab's rate")
	-- Without these it would not prove async delivery (P1.1): offline writes and their repeats,
	-- messages (a crashed server's lock among them) and the debits they delivered.
	expect.truthy(stats.offlineDebits > 0 and stats.offlineRepeats > 0, "offline debits, and repeats that found them")
	expect.truthy(stats.messages > 0 and stats.deadLocks > 0, "debits sent by message, past a dead lock too")
	expect.truthy(stats.messageDebits > 0, "a message's delivery debited the defender in their server")
	-- Without these it would not prove the raider's side of a credit (P1.3d): logged once when
	-- something moved, nothing when it did not or the record is Live, nothing again on a repeat.
	expect.truthy(stats.outgoingLogged > 0, "async credits logged the raid on the raider")
	expect.truthy(stats.emptyAsyncCredits > 0, "an async credit that moved nothing recorded nothing")
	expect.truthy(stats.liveCredits > 0, "live credits recorded nothing on the raider")
	expect.truthy(stats.creditRepeats > 0, "a credit saved again before its commit changed nothing")
	-- ...and revenge raids in the async half (D-054): a credit removes its token once, a credit
	-- whose token is already gone (spent or expired) still lands, and a record without the token's
	-- raidId spends nothing.
	expect.truthy(stats.revengeRaids > 0 and stats.revengeSpent > 0, "revenge credits removed their token")
	expect.truthy(stats.revengeTokenGone > 0, "a revenge credit whose token was already gone still landed")
	expect.truthy(stats.revengeNoId > 0, "a revenge record without a revengeRaidId spent no token")
end

tests["the same holds across 5 more random seeds"] = function()
	local defeated = 0
	for seed = 2, 6 do
		local _, _, _, _, _, stats = runSimulation(seed * 7919)
		expect.truthy(stats.refillReopened > 0, `seed {seed * 7919}: a refill reopened a protected den`)
		expect.truthy(stats.outgoingLogged > 0, `seed {seed * 7919}: async credits logged the raid on the raider`)
		expect.truthy(stats.revengeSpent > 0, `seed {seed * 7919}: a revenge credit removed its token`)
		-- Every seed checks that a debit after a mid-carry shrink still takes the critter (mustTake);
		-- the case where only the grab's rate decides it is rarer, so it is counted over the seeds.
		defeated += stats.carryShrinkDefeated
	end
	expect.truthy(defeated > 0, "a mid-carry shrink was defeated on these seeds too")
end

return tests
