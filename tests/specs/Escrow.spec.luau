--!strict
local expect = require("../lib/expect")
local fixtures = require("../lib/fixtures")
local Escrow = require("../../src/Shared/Escrow")
local Config = require("../../src/Shared/Config")
local RaidRules = require("../../src/Shared/RaidRules")
local Types = require("../../src/Shared/Types")
local Economy = require("../../src/Shared/Economy")

local NOW = 1_800_000_000

local function setup(kind: Types.TransferKind?)
	local raider = fixtures.veteran(1, NOW)
	local defender = fixtures.veteran(2, NOW)
	fixtures.give(defender, fixtures.critter("fox", "crescent_fox", "Pad", 1))
	defender.stored = 1000
	local record = Escrow.create("raid-1", raider.userId, defender.userId, "fox", 250, false, NOW, kind or "Live")
	return raider, defender, record
end

local function runAll(raider, defender, record)
	local debit = Escrow.debitDefender(defender, record, NOW)
	Escrow.markDebited(record, debit, NOW)
	Escrow.creditRaider(raider, record, NOW)
	Escrow.markCommitted(record, NOW)
end

local tests = {}

tests["happy path moves the critter and the Glow"] = function()
	local raider, defender, record = setup()
	runAll(raider, defender, record)
	expect.eq(defender.critters["fox"], nil, "defender lost the fox")
	expect.truthy(raider.critters["fox"], "raider has the fox")
	expect.eq(raider.critters["fox"].placement, "Inventory")
	expect.eq(raider.critters["fox"].stolenLockUntil, NOW + Config.Raid.stolenTradeLockSeconds)
	expect.eq(defender.stored, 750, "defender storage")
	expect.eq(raider.glow, 250, "raider wallet")
	expect.eq(record.state, "Committed")
end

tests["the defender gets a shield, a revenge token, a loss and a log entry"] = function()
	local raider, defender, record = setup()
	runAll(raider, defender, record)
	expect.eq(defender.shieldUntil, NOW + Config.Shield.afterSuccessfulRaidSeconds)
	expect.eq(defender.revengeTokens["raid-1"].targetUserId, raider.userId)
	expect.eq(defender.lossesToday, 1)
	expect.eq(defender.raidLog[1].direction, "Incoming")
	expect.eq(defender.raidLog[1].speciesId, "crescent_fox")
end

tests["repeating the debit changes nothing"] = function()
	local _, defender, record = setup()
	local first = Escrow.debitDefender(defender, record, NOW)
	local second = Escrow.debitDefender(defender, record, NOW + 5)
	expect.eq(first, second, "same applied transfer returned")
	expect.eq(defender.stored, 750, "Glow taken once")
	expect.eq(defender.lossesToday, 1, "loss counted once")
end

tests["repeating the credit changes nothing"] = function()
	local raider, defender, record = setup()
	runAll(raider, defender, record)
	Escrow.creditRaider(raider, record, NOW + 5)
	Escrow.creditRaider(raider, record, NOW + 6)
	expect.eq(raider.glow, 250, "Glow credited once")
end

tests["a critter moved to the vault before the debit is safe; Glow is still taken"] = function()
	local raider, defender, record = setup()
	defender.critters["fox"].placement = "Vault"
	runAll(raider, defender, record)
	expect.truthy(defender.critters["fox"], "fox stayed home")
	expect.eq(raider.critters["fox"], nil)
	expect.eq(raider.glow, 250)
	expect.eq(defender.lossesToday, 0, "no critter lost")
end

tests["the async loss cap is enforced at debit time, even if a raid slipped through"] = function()
	local raider, defender, record = setup("Async")
	defender.lossesToday = Config.Limits.maxLossesPerDay
	runAll(raider, defender, record)
	expect.truthy(defender.critters["fox"], "fox protected by the cap")
	expect.eq(raider.glow, 250, "Glow still taken")
	expect.eq(defender.liveLossRateToday, nil, "an async loss is not a live loss")
end

-- Live loss rules (decision D-031) ----------------------------------------------------------------

tests["a live debit ignores the count cap and values the loss before the critter leaves"] = function()
	local raider, defender, record = setup("Live")
	fixtures.give(defender, fixtures.critter("fox2", "crescent_fox", "Pad", 2))
	fixtures.give(defender, fixtures.critter("fox3", "crescent_fox", "Pad", 3))
	defender.lossesToday = Config.Limits.maxLossesPerDay
	runAll(raider, defender, record)
	expect.truthy(raider.critters["fox"], "the count cap does not stop live steals")
	expect.eq(defender.lossesToday, Config.Limits.maxLossesPerDay + 1, "still counted")
	expect.eq(defender.liveLossBaseRate, 75, "three foxes, the stolen one included")
	expect.eq(defender.liveLossRateToday, 25)
	Escrow.debitDefender(defender, record, NOW + 5)
	expect.eq(defender.liveLossRateToday, 25, "a repeated debit records nothing more")
end

tests["a live debit takes nothing from a protected den; the Glow still moves"] = function()
	local raider, defender, record = setup("Live")
	defender.liveLossBaseRate, defender.liveLossRateToday = 100, 50
	expect.truthy(RaidRules.liveProtected(defender, NOW))
	runAll(raider, defender, record)
	expect.truthy(defender.critters["fox"], "fox protected for the rest of the day")
	expect.eq(raider.critters["fox"], nil)
	expect.eq(raider.glow, 250, "Glow still taken")
	expect.eq(defender.liveLossRateToday, 50, "nothing more lost")
	expect.eq(record.state, "Committed", "the raid still settles")
end

tests["the live debit that crosses the threshold lands; the next one takes nothing"] = function()
	local raider, defender, record = setup("Live")
	fixtures.give(defender, fixtures.critter("fox2", "crescent_fox", "Pad", 2))
	runAll(raider, defender, record) -- 25 of a 50 base: exactly the share
	expect.truthy(raider.critters["fox"], "the crossing steal lands")
	expect.truthy(RaidRules.liveProtected(defender, NOW))
	local second = Escrow.create("raid-2", raider.userId, defender.userId, "fox2", 0, false, NOW + 60, "Live")
	runAll(raider, defender, second)
	expect.truthy(defender.critters["fox2"], "nothing after it")
	expect.eq(raider.critters["fox2"], nil)
end

tests["yesterday's protection does not stop today's live debit"] = function()
	local raider, defender, record = setup("Live")
	defender.lossDay = RaidRules.dayIndex(NOW) - 1
	defender.liveLossBaseRate, defender.liveLossRateToday = 100, 90
	runAll(raider, defender, record)
	expect.truthy(raider.critters["fox"])
	expect.eq(defender.liveLossBaseRate, 25, "a new day measures a new base")
end

tests["a record without a kind is Live"] = function()
	local raider, defender, record = setup("Live")
	record.kind = nil -- written before the field existed
	expect.eq(Escrow.kindOf(record), "Live")
	expect.eq(Escrow.kindOf(select(3, setup("Async"))), "Async")
	defender.lossesToday = Config.Limits.maxLossesPerDay
	runAll(raider, defender, record)
	expect.truthy(raider.critters["fox"], "the live rule applies, not the count cap")
	expect.eq(defender.liveLossRateToday, 25)
end

tests["a record's kind is written once"] = function()
	local _, _, record = setup("Live")
	expect.throws(function()
		Escrow.create("raid-x", 1, 2, nil, 0, false, NOW, "Trade" :: any)
	end, "unknown kind")
	local async = table.clone(record)
	async.kind = "Async"
	expect.falsy(Escrow.sameTransfer(record, async), "another kind is another transfer")
	expect.falsy(Escrow.canReplace(record, async))
	local missing = table.clone(record)
	missing.kind = nil
	expect.truthy(Escrow.sameTransfer(record, missing), "missing means Live: a retry still matches")
	expect.falsy(Escrow.canReplace(missing, record), "the store never fills in a missing kind")
	expect.falsy(Escrow.canReplace(record, missing), "nor drops one")
	expect.truthy(Escrow.canReplace(missing, table.clone(missing)), "an old record still moves forward")
end

-- Empty live commits (decision D-033) -----------------------------------------------------------

-- The four things a debit grants the defender, to compare before and after.
local function grants(profile: Types.PlayerProfile, raiderUserId: number)
	local tokens = 0
	for _ in profile.revengeTokens do
		tokens += 1
	end
	return profile.shieldUntil, tokens, RaidRules.pairCount(profile, raiderUserId, NOW), #profile.raidLog
end

tests["an empty live debit writes its entry but grants nothing (D-033)"] = function()
	local raider, defender, record = setup("Live")
	record.glowRequested = 0 -- Phase 0 live steals take no Glow (D-015)
	defender.liveLossBaseRate, defender.liveLossRateToday = 100, 50 -- protected
	local shield, tokens, pair, log = grants(defender, raider.userId)
	local first = Escrow.debitDefender(defender, record, NOW)
	expect.eq(defender.appliedTransfers["raid-1"], first, "the idempotency entry is written")
	expect.eq(first.critter, nil)
	expect.eq(first.glow, 0)
	local shieldAfter, tokensAfter, pairAfter, logAfter = grants(defender, raider.userId)
	expect.eq(shieldAfter, shield, "no shield")
	expect.eq(tokensAfter, tokens, "no revenge token")
	expect.eq(pairAfter, pair, "the raider's pair slot is not used up")
	expect.eq(logAfter, log, "no 'escaped' raid-log entry")
	expect.eq(defender.lossesToday, 0)
	expect.eq(Escrow.debitDefender(defender, record, NOW + 5), first, "a repeat returns the same entry")
	Escrow.markDebited(record, first, NOW)
	Escrow.creditRaider(raider, record, NOW)
	Escrow.markCommitted(record, NOW)
	expect.eq(record.state, "Committed", "the raid still settles")
	expect.eq(raider.glow, 0)
	expect.eq(next(raider.critters), nil, "the raider got nothing")
end

tests["a live debit whose critter is gone, with no Glow, grants nothing either"] = function()
	local raider, defender, record = setup("Live")
	record.glowRequested = 0
	defender.critters["fox"].placement = "Vault" -- moved before the escape landed
	defender.critters["fox"].padIndex = nil
	local shield, tokens, pair, log = grants(defender, raider.userId)
	runAll(raider, defender, record)
	local shieldAfter, tokensAfter, pairAfter, logAfter = grants(defender, raider.userId)
	expect.eq(shieldAfter, shield)
	expect.eq(tokensAfter, tokens)
	expect.eq(pairAfter, pair)
	expect.eq(logAfter, log)
	expect.truthy(defender.appliedTransfers["raid-1"], "still idempotent")
end

tests["a live debit that takes only Glow still records the raid"] = function()
	local raider, defender, record = setup("Live")
	defender.liveLossBaseRate, defender.liveLossRateToday = 100, 50 -- protected: Glow only
	runAll(raider, defender, record)
	expect.eq(raider.glow, 250)
	expect.eq(defender.shieldUntil, NOW + Config.Shield.afterSuccessfulRaidSeconds)
	expect.truthy(defender.revengeTokens["raid-1"])
	expect.eq(RaidRules.pairCount(defender, raider.userId, NOW), 1)
	expect.eq(defender.raidLog[1].raidId, "raid-1")
end

tests["an async debit that takes nothing still records the raid (unchanged by D-033)"] = function()
	local raider, defender, record = setup("Async")
	defender.stored = 0
	defender.lossesToday = Config.Limits.maxLossesPerDay
	runAll(raider, defender, record)
	expect.truthy(defender.critters["fox"], "capped")
	expect.eq(raider.glow, 0, "nothing stored, nothing taken")
	expect.eq(defender.shieldUntil, NOW + Config.Shield.afterSuccessfulRaidSeconds)
	expect.truthy(defender.revengeTokens["raid-1"])
	expect.eq(RaidRules.pairCount(defender, raider.userId, NOW), 1)
	expect.eq(defender.raidLog[1].raidId, "raid-1")
end

tests["an async debit takes its share of what is stored at the debit, not the snapshot's figure"] = function()
	local share = Config.Loot.storedGlowShare
	-- The snapshot saw nothing stored; the den earned 4000 offline, accrued before the debit.
	local raider, defender, record = setup("Async")
	record.glowRequested = 0
	defender.stored = 4000
	runAll(raider, defender, record)
	expect.eq(raider.glow, math.floor(4000 * share), "the share of what is stored now")
	expect.eq(defender.stored, 4000 - math.floor(4000 * share), "taken from storage")
	expect.eq(record.glow, raider.glow, "the credit is what was debited")
	-- Revenge takes the bonus share; a near-empty den gives what rounds down, never more.
	local _, revenged, revenge = setup("Async")
	revenge.isRevenge = true
	revenged.stored = 4000
	expect.eq(
		Escrow.debitDefender(revenged, revenge, NOW).glow,
		math.floor(4000 * share * (1 + Config.Loot.revengeBonus))
	)
	local _, poor, scrape = setup("Async")
	scrape.glowRequested = 1e9
	poor.stored = 3.9
	expect.eq(Escrow.debitDefender(poor, scrape, NOW).glow, math.floor(3 * share), "the request never raises it")
	expect.truthy(poor.stored >= 0, "never more than is stored")
end

-- Grab-time base on the record (decision D-034) ---------------------------------------------------

tests["create takes a grab-time base only on a Live record, and only a finite number >= 0"] = function()
	for _, good in { 0, 3, 112.5, 1e9 } do
		local record = Escrow.create("raid-b", 1, 2, "fox", 0, false, NOW, "Live", good)
		expect.eq(record.liveBaseRate, good, `{good} kept`)
		expect.truthy(Escrow.checkLiveBaseRate("Live", good))
	end
	expect.eq(Escrow.create("raid-b", 1, 2, "fox", 0, false, NOW, "Live").liveBaseRate, nil, "none: not measured")
	expect.truthy(Escrow.checkLiveBaseRate("Async", nil), "an async record has none")
	local bad: { any } = { 0 / 0, -1, -0.001, math.huge, -math.huge, 1e306, "603", true }
	for _, value in bad do
		local ok, why = Escrow.checkLiveBaseRate("Live", value)
		expect.falsy(ok, `{value} refused`)
		expect.truthy(type(why) == "string" and #why > 0, `{value}: says why`)
		expect.throws(function()
			Escrow.create("raid-b", 1, 2, "fox", 0, false, NOW, "Live", value)
		end, `create asserts on {value}`)
	end
	expect.falsy(Escrow.checkLiveBaseRate("Async", 10), "Live only")
	expect.throws(function()
		Escrow.create("raid-b", 1, 2, "fox", 0, false, NOW, "Async", 10)
	end, "an async record never carries one")
end

tests["a grab-time base is stored to 0.001 Glow/s, so a lossy JSON round trip keeps it exact"] = function()
	local function created(value: number): number
		return Escrow.create("raid-b", 1, 2, "fox", 0, false, NOW, "Live", value).liveBaseRate :: number
	end
	expect.eq(created(0.1 + 0.2), 0.3)
	expect.eq(created(25 * 1.1), 27.5, "a non-dyadic tuning value")
	expect.eq(created(603), 603)
	expect.eq(created(12.5), 12.5, "a vault half stays exact")
	expect.eq(created(0.0004), 0)
	for _, value in { 0.1 + 0.2, 25 * 1.1, 1 / 3, 1234.5678912, 98765.4321, 603, 12.5 } do
		local stored = created(value)
		-- 14 significant digits: the least an encoder might keep. A retry's fresh record must still
		-- equal the stored one (Escrow.sameTransfer).
		expect.eq(tonumber(string.format("%.14g", stored)), stored, `{value} survives`)
		expect.eq(created(value), stored, `{value}: the same input always gives the same record`)
	end
end

tests["the grab-time base is part of the transfer: a retry with another value is refused"] = function()
	local base = Escrow.create("raid-b", 1, 2, "fox", 0, false, NOW, "Live", 603)
	base.createNonce = "call-a"
	local retry = Escrow.create("raid-b", 1, 2, "fox", 0, false, NOW + 3, "Live", 603)
	retry.createNonce = "call-a"
	expect.truthy(Escrow.sameTransfer(base, retry), "identical arguments")
	for _, other in { 604, 0 } do
		local changed = Escrow.create("raid-b", 1, 2, "fox", 0, false, NOW, "Live", other)
		changed.createNonce = "call-a"
		expect.falsy(Escrow.sameTransfer(base, changed), `{other}: another transfer`)
		expect.falsy(Escrow.canReplace(base, changed), `{other}: the store refuses it`)
	end
	local none = table.clone(base)
	none.liveBaseRate = nil
	expect.falsy(Escrow.sameTransfer(base, none), "a missing base matches only a missing one")
	expect.falsy(Escrow.canReplace(base, none), "never dropped")
	expect.falsy(Escrow.canReplace(none, base), "never filled in")
	expect.truthy(Escrow.canReplace(none, table.clone(none)), "an old record without one still moves forward")
	local debited = table.clone(base)
	debited.state = "Debited"
	expect.truthy(Escrow.canReplace(base, debited), "kept through the state machine")
end

tests["Glow taken never exceeds what is stored"] = function()
	local raider, defender, record = setup()
	defender.stored = 40.9
	runAll(raider, defender, record)
	expect.eq(raider.glow, 40)
	expect.near(defender.stored, 0.9, 1e-9)
end

tests["void only works before any debit"] = function()
	local _, defender, record = setup()
	expect.truthy(Escrow.void(table.clone(record), defender, NOW), "pending can be voided")
	local debit = Escrow.debitDefender(defender, record, NOW)
	Escrow.markDebited(record, debit, NOW)
	expect.falsy(Escrow.void(record, defender, NOW), "debited cannot be voided")
end

tests["void is refused if the debit landed but the record save crashed"] = function()
	local _, defender, record = setup()
	Escrow.debitDefender(defender, record, NOW) -- defender saved, record still Pending
	expect.eq(record.state, "Pending")
	expect.falsy(Escrow.void(record, defender, NOW), "would strand the fox")
	expect.eq(record.state, "Pending", "record untouched; recovery will finish it")
end

tests["out-of-order steps are refused"] = function()
	local raider, _, record = setup()
	expect.throws(function()
		Escrow.creditRaider(raider, record, NOW)
	end, "credit before debit must fail")
	expect.throws(function()
		Escrow.markCommitted(record, NOW)
	end, "commit before debit must fail")
end

tests["crediting a critter the raider already owns is refused as a duplicate"] = function()
	local raider, defender, record = setup()
	local debit = Escrow.debitDefender(defender, record, NOW)
	Escrow.markDebited(record, debit, NOW)
	fixtures.give(raider, fixtures.critter("fox", "crescent_fox", "Inventory"))
	expect.throws(function()
		Escrow.creditRaider(raider, record, NOW)
	end)
end

tests["old idempotency entries are pruned after the retention window"] = function()
	local raider, defender, record = setup()
	runAll(raider, defender, record)
	expect.eq(Escrow.pruneApplied(raider, NOW + 60, {}), 0, "kept while fresh")
	expect.eq(Escrow.pruneApplied(raider, NOW + Config.Escrow.appliedTransferRetentionSeconds + 1, {}), 1)
end

tests["an old idempotency entry is never pruned while its raid is still open"] = function()
	local _, defender, record = setup()
	Escrow.debitDefender(defender, record, NOW)
	local later = NOW + Config.Escrow.appliedTransferRetentionSeconds + 1
	local open = { [record.raidId] = { role = "Defender" :: "Defender", createdAt = NOW } }
	expect.eq(Escrow.pruneApplied(defender, later, open), 0, "open raid kept")
	expect.truthy(defender.appliedTransfers[record.raidId])
	expect.eq(Escrow.pruneApplied(defender, later, {}), 1, "pruned once closed")
end

-- In-memory store for recover tests; profiles are working copies, as on a real server.
local function memoryStore(raider, defender, record)
	local profiles = { [raider.userId] = raider, [defender.userId] = defender }
	local records = { [record.raidId] = table.clone(record) }
	local store: Escrow.Store = {
		loadRecord = function(raidId)
			return if records[raidId] then table.clone(records[raidId]) else nil
		end,
		saveRecord = function(r)
			assert(Escrow.canReplace(records[r.raidId], r))
			records[r.raidId] = table.clone(r)
		end,
		loadProfile = function(userId)
			return profiles[userId]
		end,
		saveProfile = function() end,
		saveProfileWithoutEntry = function(profile, raidId)
			assert(profile.appliedTransfers[raidId] == nil, "void proof with a debit")
		end,
	}
	return store, records
end

local function everyone(_userId: number): boolean
	return true
end

tests["recover voids a Pending record whose defender was never debited, and moves nothing"] = function()
	local raider, defender, record = setup()
	local store, records = memoryStore(raider, defender, record)
	local result = Escrow.recover(record.raidId, store, NOW, everyone)
	expect.eq(result and result.state, "Voided")
	expect.eq(records[record.raidId].state, "Voided")
	expect.truthy(defender.critters["fox"], "defender keeps the fox")
	expect.eq(defender.stored, 1000, "defender keeps the Glow")
	expect.eq(raider.critters["fox"], nil)
end

tests["recover settles a saved debit with the raider away, and credits once they are back"] = function()
	local raider, defender, record = setup()
	Escrow.debitDefender(defender, record, NOW) -- saved, then the record write crashed
	local store, records = memoryStore(raider, defender, record)
	local function defenderOnly(userId: number): boolean
		return userId == defender.userId
	end
	Escrow.recover(record.raidId, store, NOW, defenderOnly)
	expect.eq(records[record.raidId].state, "Debited", "loot now held by the record")
	expect.eq(raider.critters["fox"], nil, "raider not here: not credited yet")
	Escrow.recover(record.raidId, store, NOW, everyone)
	expect.eq(records[record.raidId].state, "Committed")
	expect.truthy(raider.critters["fox"])
end

tests["recover voids nothing when the void proof fails (stale session), and voids once proven"] = function()
	local raider, defender, record = setup()
	local store, records = memoryStore(raider, defender, record)
	local proven = store.saveProfileWithoutEntry
	store.saveProfileWithoutEntry = function()
		error("session lost to another server")
	end
	expect.throws(function()
		Escrow.recover(record.raidId, store, NOW, everyone)
	end, "an unproven void must not finish quietly")
	expect.eq(records[record.raidId].state, "Pending", "left for a server that holds the defender")
	store.saveProfileWithoutEntry = proven
	Escrow.recover(record.raidId, store, NOW, everyone)
	expect.eq(records[record.raidId].state, "Voided")
	expect.truthy(defender.critters["fox"], "nothing moved")
end

tests["a create is this call's own only when the stored record carries its nonce"] = function()
	local _, _, record = setup()
	record.createNonce = "call-a"
	local toWrite, ours = Escrow.decideCreate(nil, record)
	expect.eq(toWrite, record, "no record yet: write it")
	expect.truthy(ours)
	-- The first attempt landed but its response was lost; the retry finds it.
	local landed = table.clone(record)
	toWrite, ours = Escrow.decideCreate(landed, record)
	expect.eq(toWrite, nil, "never written twice")
	expect.truthy(ours, "recognised as this call's own: drive it, do not void it")
	local other = table.clone(record)
	other.createNonce = "call-b"
	expect.falsy(select(2, Escrow.decideCreate(landed, other)), "another call's create")
	local old = table.clone(record)
	old.createNonce = nil
	expect.falsy(select(2, Escrow.decideCreate(old, old)), "a record without a nonce is never ours")
end

tests["the record store never lets the creating call's nonce change"] = function()
	local _, _, pending = setup()
	pending.createNonce = "call-a"
	local changed = table.clone(pending)
	changed.createNonce = "call-b"
	expect.falsy(Escrow.canReplace(pending, changed), "different nonce")
	changed.createNonce = nil
	expect.falsy(Escrow.canReplace(pending, changed), "nonce dropped")
	expect.truthy(Escrow.canReplace(pending, table.clone(pending)), "same nonce")
end

tests["re-adding an open raid refreshes its index time so the staleness rule protects the retry"] = function()
	local open = Escrow.indexAdd(nil, "raid-1", "Raider", NOW)
	expect.eq(open and open["raid-1"].createdAt, NOW, "added")
	local later = NOW + 20 * 60
	local refreshed = Escrow.indexAdd(open, "raid-1", "Raider", later)
	expect.eq(refreshed and refreshed["raid-1"].createdAt, later, "a retry 20 minutes later is fresh again")
	expect.eq(refreshed and refreshed["raid-1"].role, "Raider")
	expect.eq(Escrow.indexAdd(refreshed, "raid-1", "Raider", NOW), nil, "never moved back in time")
	expect.eq(Escrow.indexAdd(refreshed, "raid-1", "Raider", later), nil, "no write when unchanged")
end

tests["recover leaves a Pending record alone while its defender is away"] = function()
	local raider, defender, record = setup()
	local store, records = memoryStore(raider, defender, record)
	local function raiderOnly(userId: number): boolean
		return userId == raider.userId
	end
	Escrow.recover(record.raidId, store, NOW, raiderOnly)
	expect.eq(records[record.raidId].state, "Pending", "not voided without the defender's profile")
	expect.truthy(defender.critters["fox"])
end

-- Async records (P1.1): never voided; recover delivers the debit from any server -------------

-- memoryStore with debitAbsent: the defender's saved profile written in one go, or (held) a
-- message that only queues. `writes` counts the writes that landed.
local function asyncStore(raider, defender, record, held: boolean)
	local store, records = memoryStore(raider, defender, record)
	local sent = { writes = 0, messages = 0 }
	store.debitAbsent = function(r, now)
		if held then
			sent.messages += 1
			return nil
		end
		local had = defender.appliedTransfers[r.raidId] ~= nil
		local applied = Escrow.debitDefender(defender, r, now)
		sent.writes += if had then 0 else 1
		return applied
	end
	return store, records, sent
end

tests["recover never voids an Async record: a present defender is debited instead"] = function()
	local raider, defender, record = setup("Async")
	local store, records = asyncStore(raider, defender, record, false)
	Escrow.recover(record.raidId, store, NOW, everyone)
	expect.eq(records[record.raidId].state, "Committed", "delivered, not voided")
	expect.truthy(raider.critters["fox"], "the raider has the fox")
	expect.eq(defender.critters["fox"], nil)
	expect.eq(raider.glow, 250)
end

tests["an absent defender's async debit is written once, however often it is delivered"] = function()
	local raider, defender, record = setup("Async")
	local store, records, sent = asyncStore(raider, defender, record, false)
	local function raiderOnly(userId: number): boolean
		return userId == raider.userId
	end
	-- The write lands, then the server dies before the record moves on: a later pass repeats it.
	expect.throws(function()
		Escrow.recover(record.raidId, store, NOW, raiderOnly, function(name: string)
			if name == "deliveredDebit" then
				error("simulated crash")
			end
		end)
	end)
	expect.eq(records[record.raidId].state, "Pending", "the record still waits")
	Escrow.recover(record.raidId, store, NOW + 60, raiderOnly)
	Escrow.recover(record.raidId, store, NOW + 120, raiderOnly)
	expect.eq(sent.writes, 1, "one debit written; the repeats found it")
	expect.eq(records[record.raidId].state, "Committed")
	expect.eq(defender.stored, 750, "Glow taken once")
	expect.eq(raider.glow, 250, "Glow given once")
	expect.eq(defender.lossesToday, 1, "one loss")
end

tests["a held defender's async debit waits for that server; it stays Pending, never voided"] = function()
	local raider, defender, record = setup("Async")
	local store, records, sent = asyncStore(raider, defender, record, true)
	local function raiderOnly(userId: number): boolean
		return userId == raider.userId
	end
	Escrow.recover(record.raidId, store, NOW, raiderOnly)
	Escrow.recover(record.raidId, store, NOW + 30, raiderOnly)
	expect.eq(sent.messages, 2, "asked again on each pass")
	expect.eq(records[record.raidId].state, "Pending", "waiting for the defender's server")
	expect.truthy(defender.critters["fox"], "nothing moved yet")
	-- The defender's server reads the message: recovery there, with the defender loaded.
	local function defenderOnly(userId: number): boolean
		return userId == defender.userId
	end
	Escrow.recover(record.raidId, store, NOW + 40, defenderOnly)
	expect.eq(records[record.raidId].state, "Debited")
	Escrow.recover(record.raidId, store, NOW + 50, raiderOnly)
	expect.eq(records[record.raidId].state, "Committed")
	expect.truthy(raider.critters["fox"])
end

tests["an Async record can never be voided, even with no debit saved"] = function()
	local _, defender, record = setup("Async")
	expect.falsy(Escrow.void(record, defender, NOW), "refused")
	expect.eq(record.state, "Pending", "left for a delivery")
	expect.eq(defender.appliedTransfers[record.raidId], nil)
end

tests["an absent defender's debit accrues offline income to the debit inside its write, then takes its share"] = function()
	local _, defender, record = setup("Async")
	defender.stored = 0
	defender.storedUpdatedAt = NOW - 6 * 3600 -- six hours offline, the fox still on its pad
	local probe = table.clone(defender)
	Economy.accrue(probe, NOW)
	local atDebit = math.floor(probe.stored)
	expect.truthy(atDebit > 0, "the den earned while offline")
	local write, applied = Escrow.debitAbsentProfile(defender, record, NOW)
	expect.truthy(write, "a first debit writes")
	expect.eq(defender.storedUpdatedAt, NOW, "accrued to the debit")
	expect.eq(applied.glow, math.floor(atDebit * Config.Loot.storedGlowShare), "the share of the accrued store")
	expect.eq(defender.stored, probe.stored - applied.glow, "taken from it")
	-- A repeat later changes nothing, not even the accrual.
	local stored, at = defender.stored, defender.storedUpdatedAt
	local again, same = Escrow.debitAbsentProfile(defender, record, NOW + 600)
	expect.falsy(again, "a repeat writes nothing")
	expect.eq(same, applied, "the saved entry")
	expect.eq(defender.stored, stored)
	expect.eq(defender.storedUpdatedAt, at)
end

tests["recover refuses an absent defender's async debit when its store cannot reach them"] = function()
	local raider, defender, record = setup("Async")
	local store, records = memoryStore(raider, defender, record) -- no debitAbsent
	local function raiderOnly(userId: number): boolean
		return userId == raider.userId
	end
	expect.throws(function()
		Escrow.recover(record.raidId, store, NOW, raiderOnly)
	end)
	expect.eq(records[record.raidId].state, "Pending")
	expect.truthy(defender.critters["fox"])
end

-- Snapshots of one record at each state, for the record-store rule.
local function stages()
	local raider, defender, record = setup()
	local pending = table.clone(record)
	Escrow.markDebited(record, Escrow.debitDefender(defender, record, NOW), NOW)
	local debited = table.clone(record)
	Escrow.creditRaider(raider, record, NOW)
	Escrow.markCommitted(record, NOW)
	local voided = table.clone(pending)
	voided.state = "Voided"
	return pending, debited, table.clone(record), voided
end

tests["the record store creates only Pending records"] = function()
	local pending, debited = stages()
	expect.truthy(Escrow.canReplace(nil, pending), "create")
	expect.falsy(Escrow.canReplace(nil, debited), "a Debited record with nothing stored")
end

tests["the record store accepts forward moves and repeats, and refuses going back"] = function()
	local pending, debited, committed, voided = stages()
	expect.truthy(Escrow.canReplace(pending, debited), "Pending -> Debited")
	expect.truthy(Escrow.canReplace(debited, committed), "Debited -> Committed")
	expect.truthy(Escrow.canReplace(pending, voided), "Pending -> Voided")
	expect.truthy(Escrow.canReplace(debited, debited), "repeat")
	expect.falsy(Escrow.canReplace(committed, debited), "Committed -> Debited")
	expect.falsy(Escrow.canReplace(debited, pending), "Debited -> Pending")
	expect.falsy(Escrow.canReplace(debited, voided), "Debited -> Voided would strand loot")
	expect.falsy(Escrow.canReplace(voided, debited), "Voided -> Debited")
end

tests["the record store refuses a different transfer or different loot under the same raidId"] = function()
	local pending, debited = stages()
	local other = table.clone(pending)
	other.raiderUserId = 99
	expect.falsy(Escrow.canReplace(pending, other), "different raider")
	expect.falsy(Escrow.sameTransfer(pending, other))
	local revenge = table.clone(pending)
	revenge.isRevenge = true
	expect.falsy(Escrow.sameTransfer(pending, revenge), "revenge flag differs")
	local moreGlow = table.clone(debited)
	moreGlow.glow += 1
	expect.falsy(Escrow.canReplace(debited, moreGlow), "different Glow")
	local noCritter = table.clone(debited)
	noCritter.critter = nil
	expect.falsy(Escrow.canReplace(debited, noCritter), "different critter")
end

return tests
