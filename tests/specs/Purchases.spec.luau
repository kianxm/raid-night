--!strict
--[[
	P2.8: the Glow-factor helper's pure half (Economy.accrueBoosted, collectBoosted,
	changeGlowInputs), the Robux catalog's policy rules (Config.Purchases, Economy.purchaseOffered,
	perkActive), and ProcessReceipt's steps (Economy.processReceipt) with C6's Profile receipts,
	including a simulation of forced shutdowns and redeliveries.
]]

local expect = require("../lib/expect")
local fixtures = require("../lib/fixtures")
local rngLib = require("../lib/rng")
local Economy = require("../../src/Shared/Economy")
local Config = require("../../src/Shared/Config")
local Profile = require("../../src/Shared/Profile")
local Types = require("../../src/Shared/Types")

type PlayerProfile = Types.PlayerProfile

local NOW = 1_800_000_000
local HOUR = 3600

-- Live settings: purchases on, VIP online only (D-061 (2)).
local ON = { purchasesEnabled = true, vipBoostsOffline = false }
local OFF = { purchasesEnabled = false, vipBoostsOffline = false }

-- A veteran with one 1 Glow/s critter on a pad, last accrued at `at`.
local function den(at: number): PlayerProfile
	local p = fixtures.veteran(1, at)
	fixtures.give(p, fixtures.critter("a", "dusk_mouse"))
	return p
end

-- A joined state (offline gap paid) with the given inputs.
local function joined(p: PlayerProfile, change: any): Economy.GlowFactorState
	local state = Economy.newGlowFactorState()
	Economy.changeGlowInputs(state, nil, p.storedUpdatedAt, change, ON)
	Economy.accrueBoosted(state, p, p.storedUpdatedAt, ON)
	expect.truthy(state.joined, "joined")
	return state
end

local tests = {}

-- Glow-factor helper -----------------------------------------------------------------------------

tests["a fresh state is factor 1: the policy is unknown, so it fails closed even with VIP"] = function()
	local state = Economy.newGlowFactorState()
	expect.eq(Economy.glowFactorAt(state, NOW, ON), 1, "fresh")
	Economy.changeGlowInputs(state, nil, NOW, { vip = true, lanternNightUntil = NOW + 900 }, ON)
	expect.eq(Economy.glowFactorAt(state, NOW, ON), 1, "VIP + Lantern Night, policy unknown")
	Economy.changeGlowInputs(state, nil, NOW, { paidRandomRestricted = false }, ON)
	expect.eq(Economy.glowFactorAt(state, NOW, ON), 2, "known unrestricted")
end

tests["a VIP player with normal activity earns 1.5x over 10 minutes online"] = function()
	local p = den(NOW)
	local state = joined(p, { vip = true, paidRandomRestricted = false })
	local earned = 0
	for t = NOW + 30, NOW + 600, 30 do -- a HUD request or collect every 30 s
		earned += Economy.accrueBoosted(state, p, t, ON)
	end
	expect.eq(earned, 900, "600 s at 1 Glow/s x 1.5")
end

tests["a VIP player who joins after 8 hours offline gains exactly the unboosted 8 hours"] = function()
	local leftAt = NOW - 8 * HOUR
	local p = den(leftAt)
	local state = Economy.newGlowFactorState()
	-- PolicyService and MarketplaceService answered before the profile loaded.
	Economy.changeGlowInputs(state, nil, NOW, { vip = true, paidRandomRestricted = false }, ON)
	expect.eq(Economy.accrueBoosted(state, p, NOW, ON), 8 * HOUR, "offline gap at factor 1")
	expect.eq(Economy.accrueBoosted(state, p, NOW + 60, ON), 90, "then 1.5x online")
end

tests["vipBoostsOffline (one Config value) pays the offline gap at VIP only, never Lantern Night"] = function()
	local p = den(NOW - HOUR)
	local state = Economy.newGlowFactorState()
	Economy.changeGlowInputs(
		state,
		nil,
		NOW,
		{ vip = true, paidRandomRestricted = false, lanternNightUntil = NOW + 900 },
		ON
	)
	local settings = { purchasesEnabled = true, vipBoostsOffline = true }
	expect.eq(Economy.accrueBoosted(state, p, NOW, settings), 1.5 * HOUR, "VIP 1.5x offline, no Lantern Night")
	expect.eq(Config.Purchases.vipBoostsOffline, false, "launch default: online only (D-061)")
end

tests["a factor change accrues at the OLD factor first"] = function()
	local p = den(NOW)
	local state = joined(p, { paidRandomRestricted = false })
	-- VIP bought 100 s in: those 100 s are paid at 1, the next 100 s at 1.5.
	expect.eq(Economy.changeGlowInputs(state, p, NOW + 100, { vip = true }, ON), 100, "old factor")
	expect.eq(p.storedUpdatedAt, NOW + 100, "accrued to the change")
	expect.eq(Economy.accrueBoosted(state, p, NOW + 200, ON), 150, "new factor after")
	-- The policy turns restricted: the 1.5x period is paid before it drops to 1.
	expect.eq(Economy.changeGlowInputs(state, p, NOW + 300, { paidRandomRestricted = true }, ON), 150, "old")
	expect.eq(Economy.accrueBoosted(state, p, NOW + 400, ON), 100, "restricted: 1")
end

tests["Lantern Night ends on its own: an accrue spanning the end splits there"] = function()
	local p = den(NOW)
	local state = joined(p, { paidRandomRestricted = false })
	Economy.changeGlowInputs(state, p, NOW, { lanternNightUntil = NOW + 900 }, ON)
	expect.eq(Economy.accrueBoosted(state, p, NOW + 1000, ON), 900 * 1.5 + 100, "boosted to the end, then 1")
	expect.eq(Economy.accrueBoosted(state, p, NOW + 1100, ON), 100, "after the end")
	expect.eq(Economy.glowFactorAt(state, NOW + 899, ON), 1.5, "during")
	expect.eq(Economy.glowFactorAt(state, NOW + 900, ON), 1, "at the end")
end

tests["VIP and Lantern Night stack additively to 2x"] = function()
	local p = den(NOW)
	local state = joined(p, { vip = true, paidRandomRestricted = false, lanternNightUntil = NOW + 900 })
	expect.eq(Economy.accrueBoosted(state, p, NOW + 100, ON), 200, "2x")
end

tests["a restricted or unknown player never gets a factor above 1, whatever the inputs"] = function()
	local rng = rngLib.new(828)
	for _, restricted in { true, "nil" } do
		local p = den(NOW)
		local state = Economy.newGlowFactorState()
		if restricted == true then
			Economy.changeGlowInputs(state, nil, NOW, { paidRandomRestricted = true }, ON)
		end
		Economy.accrueBoosted(state, p, NOW, ON)
		local t = NOW
		for _ = 1, 300 do
			local step = rng.int(1, 120)
			Economy.changeGlowInputs(state, p, t, {
				vip = rng.chance(0.5),
				lanternNightUntil = if rng.chance(0.5) then t + rng.int(0, 900) else 0,
			}, ON)
			expect.eq(Economy.glowFactorAt(state, t, ON), 1, `factor at {t}`)
			local added = Economy.accrueBoosted(state, p, t + step, ON)
			expect.eq(added, step, `unboosted over {step} s`)
			t += step
		end
	end
end

tests["the kill switch makes every factor 1"] = function()
	local p = den(NOW)
	local state = Economy.newGlowFactorState()
	Economy.changeGlowInputs(
		state,
		nil,
		NOW,
		{ vip = true, paidRandomRestricted = false, lanternNightUntil = NOW + 900 },
		OFF
	)
	Economy.accrueBoosted(state, p, NOW, OFF)
	expect.eq(Economy.accrueBoosted(state, p, NOW + 100, OFF), 100, "purchases off")
end

tests["bad input values fail closed, and the factor stays clamped"] = function()
	local p = den(NOW)
	local state = joined(p, { vip = true, paidRandomRestricted = false })
	local bad: any = { vip = "yes", paidRandomRestricted = 1, lanternNightUntil = 0 / 0 }
	Economy.changeGlowInputs(state, p, NOW, bad, ON)
	expect.eq(state.inputs.vip, false, "vip -> false")
	expect.eq(state.inputs.paidRandomRestricted, nil, "restricted -> unknown")
	expect.eq(state.inputs.lanternNightUntil, 0, "NaN end -> none")
	for _, value in { math.huge, -5, "soon" } do
		Economy.changeGlowInputs(state, p, NOW, { lanternNightUntil = value :: any }, ON)
		expect.eq(state.inputs.lanternNightUntil, 0, `end {value} -> none`)
	end
	-- Corrupted state values can never push the factor past every boost together.
	state.inputs = { vip = 7 :: any, paidRandomRestricted = false, lanternNightUntil = math.huge }
	expect.truthy(Economy.glowFactorAt(state, NOW, ON) <= Economy.maxGlowBoostFactor(), "clamped")
	expect.eq(Economy.accrueBoosted(state, p, NOW + 100, ON), 100, "vip 7 counts as no VIP")
	-- A NaN `now` or a non-table change changes nothing.
	local before = p.stored
	expect.eq(Economy.changeGlowInputs(state, p, 0 / 0, { vip = true }, ON), 0, "NaN now")
	expect.eq(Economy.changeGlowInputs(state, p, NOW + 200, nil :: any, ON), 0, "no change table")
	expect.eq(Economy.accrueBoosted(state, p, 0 / 0, ON), 0, "NaN accrue")
	expect.eq(p.stored, before, "stored untouched")
end

tests["a boost fills storage faster, never past the unboosted cap"] = function()
	local p = den(NOW)
	local state = joined(p, { vip = true, paidRandomRestricted = false, lanternNightUntil = NOW + 100 * HOUR })
	Economy.accrueBoosted(state, p, NOW + 50 * HOUR, ON)
	expect.eq(p.stored, Economy.storageCap(p), "at the cap")
end

tests["collectBoosted banks what was earned at the factor"] = function()
	local p = den(NOW)
	local state = joined(p, { vip = true, paidRandomRestricted = false })
	expect.eq(Economy.collectBoosted(state, p, NOW + 100, ON), 150, "banked")
	expect.eq(p.glow, 150, "glow")
	expect.eq(p.stored, 0, "stored")
end

tests["a Lantern Night purchase extends a running one and never stacks the bonus"] = function()
	local s = Config.Boosts.lanternNightSeconds
	expect.eq(Economy.extendLanternNight(0, NOW), NOW + s, "starts now")
	expect.eq(Economy.extendLanternNight(NOW + 100, NOW), NOW + 100 + s, "extends")
	expect.eq(Economy.extendLanternNight(NOW - 5, NOW), NOW + s, "an ended one starts again")
	expect.eq(Economy.extendLanternNight(0 / 0, NOW), NOW + s, "NaN end")
	local p = den(NOW)
	local state = joined(p, { paidRandomRestricted = false })
	Economy.changeGlowInputs(state, p, NOW, { lanternNightUntil = Economy.extendLanternNight(0, NOW) }, ON)
	local twice = Economy.extendLanternNight(state.inputs.lanternNightUntil, NOW)
	Economy.changeGlowInputs(state, p, NOW, { lanternNightUntil = twice }, ON)
	expect.eq(Economy.glowFactorAt(state, NOW, ON), 1.5, "two purchases: still +50%")
end

-- Catalog and policy (D-028, D-029, D-061) --------------------------------------------------------

local GLOW_LINKED_PASSES = { "vip", "vaultSlot", "autoCollect", "raidScout" }
local GLOW_LINKED_PRODUCTS = { "shield", "lanternNight", "eventPass" }

tests["policy audit: every item that raises or protects Glow is Robux-linked"] = function()
	for _, key in GLOW_LINKED_PASSES do
		expect.eq((Config.Purchases.passes :: any)[key].robuxLinked, true, `passes.{key}`)
	end
	for _, key in GLOW_LINKED_PRODUCTS do
		expect.eq((Config.Purchases.products :: any)[key].robuxLinked, true, `products.{key}`)
	end
	-- D-061 (3): Lantern Night is hidden from restricted players. D-065: so is VIP (its non-Glow
	-- perks are not defined, so a restricted buyer would get nothing).
	expect.eq(Config.Purchases.products.lanternNight.offerRestricted, false, "Lantern Night hidden")
	expect.eq(Config.Purchases.passes.vip.offerRestricted, false, "VIP hidden (D-065)")
end

tests["no product is random or grants Glow, and every entry is well-formed"] = function()
	local function check(where: string, item: any)
		expect.truthy(type(item.id) == "number" and item.id >= 0 and item.id % 1 == 0, `{where}.id`)
		expect.truthy(type(item.price) == "number" and item.price > 0 and item.price % 1 == 0, `{where}.price`)
		expect.eq(type(item.robuxLinked), "boolean", `{where}.robuxLinked`)
		expect.eq(type(item.offerRestricted), "boolean", `{where}.offerRestricted`)
	end
	for key, item in Config.Purchases.passes :: any do
		check(`passes.{key}`, item)
	end
	for key, item in Config.Purchases.products :: any do
		check(`products.{key}`, item)
		expect.truthy(table.find(Economy.PRODUCT_KINDS, item.kind) ~= nil, `products.{key}.kind {item.kind}`)
		if item.kind == "accessory" then
			expect.eq(type(item.accessoryId), "string", `products.{key}.accessoryId`)
		end
	end
	for _, kind in Economy.PRODUCT_KINDS do
		for _, word in { "egg", "luck", "glow", "random", "summon", "pack" } do
			expect.falsy(string.find(string.lower(kind), word, 1, true), `kind {kind} mentions {word}`)
		end
	end
	expect.eq(Config.Purchases.currentEventId, "", "no event: the event pass is not offered")
	expect.truthy(Config.Purchases.autoCollectSeconds >= 10, "auto-collect interval")
end

tests["purchaseOffered: kill switch, placeholder ids, and Robux-linked items fail closed"] = function()
	local linked = { id = 5, price = 99, robuxLinked = true, offerRestricted = false }
	local linkedOffered = { id = 5, price = 99, robuxLinked = true, offerRestricted = true }
	local cosmetic = { id = 5, price = 99, robuxLinked = false, offerRestricted = true }
	local placeholder = { id = 0, price = 99, robuxLinked = false, offerRestricted = true }
	local function policy(restricted: boolean?, enabled: boolean?): Economy.PurchasePolicy
		return { paidRandomRestricted = restricted, purchasesEnabled = enabled ~= false }
	end
	expect.truthy(Economy.purchaseOffered(linked, policy(false)), "linked, unrestricted")
	expect.falsy(Economy.purchaseOffered(linked, policy(true)), "linked, restricted")
	expect.falsy(Economy.purchaseOffered(linked, policy(nil)), "linked, unknown")
	expect.truthy(Economy.purchaseOffered(linkedOffered, policy(true)), "offerRestricted")
	expect.truthy(Economy.purchaseOffered(cosmetic, policy(nil)), "cosmetic, unknown")
	expect.falsy(Economy.purchaseOffered(cosmetic, policy(false, false)), "purchases off")
	expect.falsy(Economy.purchaseOffered(placeholder, policy(false)), "id 0")
	expect.falsy(Economy.purchaseOffered(cosmetic, nil :: any), "no policy")
end

tests["perkActive: owned, on, created, and Robux-linked perks only when known unrestricted"] = function()
	local linked = { id = 5, price = 99, robuxLinked = true, offerRestricted = true }
	local cosmetic = { id = 5, price = 99, robuxLinked = false, offerRestricted = true }
	local known = { paidRandomRestricted = false, purchasesEnabled = true }
	local restricted = { paidRandomRestricted = true, purchasesEnabled = true }
	local unknown = { paidRandomRestricted = nil, purchasesEnabled = true }
	expect.truthy(Economy.perkActive(linked, true, known), "linked, known")
	expect.falsy(Economy.perkActive(linked, true, restricted), "linked, restricted")
	expect.falsy(Economy.perkActive(linked, true, unknown), "linked, unknown")
	expect.falsy(Economy.perkActive(linked, false, known), "not owned")
	expect.truthy(Economy.perkActive(cosmetic, true, restricted), "cosmetic, restricted")
	expect.falsy(Economy.perkActive(cosmetic, true, { paidRandomRestricted = false, purchasesEnabled = false }), "off")
	expect.falsy(
		Economy.perkActive({ id = 0, price = 1, robuxLinked = false, offerRestricted = true }, true, known),
		"id 0"
	)
end

tests["productById finds created products only"] = function()
	expect.eq(Economy.productById(0), nil, "0 is never a product")
	expect.eq(Economy.productById(-3), nil, "negative")
	expect.eq(Economy.productById(1.5), nil, "fraction")
	expect.eq(Economy.productById(987654321), nil, "unknown")
end

tests["the vault slot pass adds a slot that is not saved"] = function()
	local p = den(NOW)
	fixtures.give(p, fixtures.critter("v1", "dusk_mouse", "Vault"))
	fixtures.give(p, fixtures.critter("b", "dusk_mouse", "Pad", 2))
	expect.eq(Economy.vaultCapacity(p, nil), p.vaultSlots, "no pass")
	expect.eq(Economy.vaultCapacity(p, 1), p.vaultSlots + 1, "pass")
	for _, bad in { -1, 0.5, 0 / 0, math.huge, "1" } do
		expect.eq(Economy.vaultCapacity(p, bad :: any), p.vaultSlots, `bad extra {bad}`)
	end
	local ok, why = Economy.place(p, "b", "Vault", nil, 6, NOW)
	expect.falsy(ok, "vault full without the pass")
	expect.eq(why, "vault is full", "reason")
	expect.truthy(Economy.place(p, "b", "Vault", nil, 6, NOW, nil, 1), "the pass slot")
	expect.eq(p.vaultSlots, 1, "nothing saved")
	-- The perk turning off never moves a critter out; it only stops new ones going in.
	expect.truthy(Economy.place(p, "b", "Vault", nil, 6, NOW, nil, 0), "already in the vault")
	expect.eq(Economy.vaultCount(p), 2, "both stay")
end

-- ProcessReceipt ---------------------------------------------------------------------------------

-- Steps over a real profile with C6's Profile helpers; grant = one "gem" accessory.
local function steps(profile: PlayerProfile, purchaseId: any, productId: any, save: () -> boolean): Economy.ReceiptSteps
	return {
		hasReceipt = function(): boolean
			return Profile.hasReceipt(profile, purchaseId)
		end,
		canGrant = function(): boolean
			return true
		end,
		record = function(): boolean
			return Profile.recordReceipt(profile, purchaseId, productId, NOW)
		end,
		grant = function(): boolean
			return Profile.grantAccessory(profile, "gem")
		end,
		save = save,
	}
end

local function always(): boolean
	return true
end

tests["a receipt grants once; a redelivery grants nothing and is acknowledged after a save"] = function()
	local p = den(NOW)
	local saves = 0
	local function save(): boolean
		saves += 1
		return Profile.hasReceipt(p, "r1")
	end
	expect.eq(Economy.processReceipt(steps(p, "r1", 7, save)), "PurchaseGranted", "first")
	expect.eq(Economy.processReceipt(steps(p, "r1", 7, save)), "PurchaseGranted", "redelivery")
	expect.eq(Profile.accessoryCount(p, "gem"), 1, "granted once")
	expect.eq(saves, 2, "the redelivery confirmed a save too")
end

tests["a failed save is never acknowledged; the redelivery then grants nothing more"] = function()
	local p = den(NOW)
	local function fail(): boolean
		return false
	end
	expect.eq(Economy.processReceipt(steps(p, "r1", 7, fail)), "NotProcessedYet", "save failed")
	expect.eq(Economy.processReceipt(steps(p, "r1", 7, fail)), "NotProcessedYet", "redelivery, save failed")
	expect.eq(Economy.processReceipt(steps(p, "r1", 7, always)), "PurchaseGranted", "redelivery, saved")
	expect.eq(Profile.accessoryCount(p, "gem"), 1, "granted once")
end

tests["bad receipt input: recordReceipt refuses, nothing is granted, never PurchaseGranted"] = function()
	local p = den(NOW)
	local cases: { { any } } = {
		{ "", 7 }, -- empty PurchaseId
		{ string.rep("x", 101), 7 }, -- too long
		{ 12345, 7 }, -- not a string
		{ nil, 7 },
		{ "ok", 0 }, -- product id 0
		{ "ok", -7 },
		{ "ok", 7.5 },
		{ "ok", 0 / 0 },
	}
	for i, case in cases do
		local saved = false
		local decision = Economy.processReceipt(steps(p, case[1], case[2], function(): boolean
			saved = true
			return true
		end))
		expect.eq(decision, "NotProcessedYet", `case {i}`)
		expect.falsy(saved, `case {i} never reaches the save`)
	end
	expect.eq(Profile.accessoryCount(p, "gem"), 0, "nothing granted")
	expect.eq(p.receipts, nil, "nothing recorded")
end

tests["a product that may not be granted now records nothing"] = function()
	local p = den(NOW)
	local s = steps(p, "r1", 7, always)
	s.canGrant = function(): boolean
		return false
	end
	expect.eq(Economy.processReceipt(s), "NotProcessedYet", "refused")
	expect.falsy(Profile.hasReceipt(p, "r1"), "no receipt")
end

tests["a grant refused after the record is never acknowledged"] = function()
	local p = den(NOW)
	local s = steps(p, "r1", 7, always)
	s.grant = function(): boolean
		return false
	end
	expect.eq(Economy.processReceipt(s), "NotProcessedYet", "not acknowledged")
end

-- Forced shutdowns and redeliveries. One player's saved profile (the DataStore), at most one
-- server holding a live copy, and Roblox's queue of receipts not yet acknowledged. A crash drops
-- the live copy (whatever was not saved is gone); Roblox redelivers every unacknowledged receipt
-- whenever the player is in a server. Grants are "gem" accessories, so the saved count must end
-- equal to the number of purchases: none lost, none doubled.
--
-- Redelivered before load (reviewer B1 on #127): on a join Roblox redelivers at once, while the
-- profile is still loading (after a forced shutdown the load waits for the dead server's lock).
-- With `waitForLoad` the server waits for the load, as PurchaseService's decide does; without
-- it, it answers NotProcessedYet, and a receipt only ever redelivered at join is never granted.

local CRASH = "forced shutdown"

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in value do
		copy[k] = deepCopy(v)
	end
	return copy
end

-- Returns how many purchases were never acknowledged (always 0 when waitForLoad, or it fails).
local function simulate(seed: number, purchases: number, waitForLoad: boolean): number
	local rng = rngLib.new(seed)
	local saved: PlayerProfile = deepCopy(den(NOW))
	local live: PlayerProfile? = deepCopy(saved)
	local loading = false -- the player is in a new server whose profile load has not finished
	local queue: { string } = {} -- unacknowledged PurchaseIds, oldest first
	local productOf: { [string]: number } = {}
	local acknowledged: { [string]: number } = {}
	local made = 0

	local function finishLoad()
		if loading then
			live = deepCopy(saved)
			loading = false
		end
	end

	local function deliver(purchaseId: string)
		if not live and loading and waitForLoad then
			finishLoad() -- the server waits for the load before deciding
		end
		local profile = live
		if not profile then
			return -- NotProcessedYet: nobody here, or the profile is not loaded yet
		end
		local crashAt = if rng.chance(0.15) then rng.int(1, 3) else 0 -- 1 after grant, 2 mid-save, 3 after save
		local saveFails = rng.chance(0.15)
		local s = steps(profile, purchaseId, productOf[purchaseId], function(): boolean
			if crashAt == 1 then
				error(CRASH, 0)
			end
			if saveFails then
				return false
			end
			if crashAt == 2 and rng.chance(0.5) then
				error(CRASH, 0) -- the write never landed
			end
			saved = deepCopy(profile)
			if crashAt == 2 or crashAt == 3 then
				error(CRASH, 0) -- saved, but the answer never reached Roblox
			end
			return Profile.hasReceipt(saved, purchaseId)
		end)
		local ok, decision = pcall(Economy.processReceipt, s)
		if not ok then
			expect.eq(decision, CRASH, "only forced shutdowns throw")
			live = nil
			return
		end
		if decision == "PurchaseGranted" then
			acknowledged[purchaseId] = (acknowledged[purchaseId] or 0) + 1
			local index = table.find(queue, purchaseId)
			if index then
				table.remove(queue, index)
			end
		end
	end

	local function redeliverAll()
		for _, id in table.clone(queue) do
			deliver(id)
		end
	end

	for step = 1, purchases * 4 do
		local roll = rng.next()
		if roll < 0.3 and made < purchases and live then
			made += 1
			local id = `p{seed}-{made}`
			productOf[id] = rng.int(1, 5)
			table.insert(queue, id)
			deliver(id)
		elseif roll < 0.55 and #queue > 0 then
			deliver(queue[rng.int(1, #queue)])
		elseif roll < 0.7 and live then
			saved = deepCopy(live) -- ProfileStore autosave
		elseif roll < 0.8 then
			live = nil -- forced shutdown with nothing in flight
			loading = false
		elseif not live then
			loading = true -- the player joins a new server; Roblox redelivers before the load
			redeliverAll()
			finishLoad()
		end
		local current = live
		if current then
			expect.truthy(Profile.accessoryCount(current, "gem") <= made, `step {step}: no more grants than buys`)
		end
		expect.truthy(Profile.accessoryCount(saved, "gem") <= made, `step {step}: saved never doubles`)
	end
	-- Drain: the player keeps rejoining, and Roblox redelivers only at each join, before the load.
	for _ = 1, 200 do
		if #queue == 0 then
			break
		end
		live = nil
		loading = true
		redeliverAll()
		finishLoad()
	end
	if not waitForLoad then
		return #queue
	end
	expect.eq(#queue, 0, `seed {seed}: every purchase acknowledged`)
	for id, count in acknowledged do
		expect.eq(count, 1, `seed {seed}: {id} acknowledged once`)
		expect.truthy(Profile.hasReceipt(saved, id), `seed {seed}: {id} saved`)
	end
	expect.eq(Profile.accessoryCount(saved, "gem"), made, `seed {seed}: each purchase granted exactly once`)
	return 0
end

tests["forced shutdowns mid-purchase never double-grant or lose a purchase (simulation)"] = function()
	for seed = 1, 40 do
		simulate(seed, 60, true)
	end
end

tests["a receipt redelivered before the profile loads is granted once the server waits for the load"] = function()
	-- The waiting server drains every seed (checked inside simulate). Answering at once instead
	-- leaves purchases unacknowledged on every rejoin: the case B1 fixes is really exercised.
	local stuck = 0
	for seed = 1, 40 do
		simulate(seed, 60, true)
		stuck += simulate(seed, 60, false)
	end
	expect.truthy(stuck > 0, "without the wait, some purchase is never acknowledged")
end

-- P2.8c: GetShopOffers (Economy.shopOffers) --------------------------------------------------------

-- A created catalog: every Config.Purchases entry with a real id, so the policy rules decide.
local function createdCatalog(eventId: string): any
	local catalog = { currentEventId = eventId, passes = {}, products = {} }
	local nextId = 100
	for _, group in { "passes", "products" } do
		for key, item in (Config.Purchases :: any)[group] do
			local copy = table.clone(item)
			nextId += 1
			copy.id = nextId
			catalog[group][key] = copy
		end
	end
	return catalog
end

local function keysOf(offers: { any }): { [string]: boolean }
	local set = {}
	for _, offer in offers do
		set[offer.key] = true
	end
	return set
end

local KNOWN = { paidRandomRestricted = false, purchasesEnabled = true }
local RESTRICTED = { paidRandomRestricted = true, purchasesEnabled = true }
local UNKNOWN = { paidRandomRestricted = nil, purchasesEnabled = true }

tests["shopOffers: restricted and unknown players never see a Robux-linked offer (D-061, D-065)"] = function()
	local catalog = createdCatalog("week1")
	for _, policy in { RESTRICTED, UNKNOWN } do
		local offers = Economy.shopOffers(catalog, policy :: any)
		expect.truthy(#offers > 0, "cosmetics are still offered")
		for _, offer in offers do
			local group = if offer.kind == "pass" then catalog.passes else catalog.products
			local item = group[offer.key]
			expect.truthy(item.robuxLinked ~= true or item.offerRestricted == true, `{offer.key} hidden`)
		end
		local shown = keysOf(offers)
		for _, key in { "vip", "vaultSlot", "autoCollect", "raidScout", "lanternNight", "shield", "eventPass" } do
			expect.falsy(shown[key], `{key} never shown to a restricted or unknown player`)
		end
	end
end

tests["shopOffers: a known unrestricted player sees every created item, owned passes left out"] = function()
	local catalog = createdCatalog("week1")
	local offers = Economy.shopOffers(catalog, KNOWN :: any, function(key: string): boolean
		return key == "vip"
	end)
	local shown = keysOf(offers)
	expect.falsy(shown.vip, "owned pass left out")
	for key in catalog.passes do
		if key ~= "vip" then
			expect.truthy(shown[key], `pass {key}`)
		end
	end
	for key in catalog.products do
		expect.truthy(shown[key], `product {key}`)
	end
	for _, offer in offers do
		local group = if offer.kind == "pass" then catalog.passes else catalog.products
		local item = group[offer.key]
		expect.eq(offer.id, item.id, "id")
		expect.eq(offer.price, item.price, "price")
		if offer.kind ~= "pass" then
			expect.eq(offer.kind, item.kind, "product kind")
		end
	end
end

tests["shopOffers: passes first, then products, each sorted by key"] = function()
	local offers = Economy.shopOffers(createdCatalog("week1"), KNOWN :: any)
	local seenProduct = false
	local last: { [string]: string } = {}
	for _, offer in offers do
		local group = if offer.kind == "pass" then "pass" else "product"
		if group == "product" then
			seenProduct = true
		else
			expect.falsy(seenProduct, "no pass after a product")
		end
		expect.truthy(last[group] == nil or last[group] < offer.key, "sorted by key")
		last[group] = offer.key
	end
end

tests["shopOffers: nothing with purchases off, placeholder ids, or a bad catalog; no event, no event pass"] = function()
	local catalog = createdCatalog("week1")
	expect.eq(#Economy.shopOffers(catalog, { paidRandomRestricted = false, purchasesEnabled = false }), 0, "off")
	expect.eq(#Economy.shopOffers(Config.Purchases, KNOWN :: any), 0, "launch ids are all 0")
	expect.eq(#Economy.shopOffers(nil, KNOWN :: any), 0, "no catalog")
	expect.eq(#Economy.shopOffers({ passes = 5, products = "x" }, KNOWN :: any), 0, "malformed groups")
	expect.falsy(keysOf(Economy.shopOffers(createdCatalog(""), KNOWN :: any)).eventPass, "no event running")
	expect.truthy(keysOf(Economy.shopOffers(catalog, KNOWN :: any)).eventPass, "event running")
end

tests["shopOffers never offers what purchaseOffered refuses"] = function()
	local catalog = createdCatalog("week1")
	for _, policy in { KNOWN, RESTRICTED, UNKNOWN } do
		for _, offer in Economy.shopOffers(catalog, policy :: any) do
			local group = if offer.kind == "pass" then catalog.passes else catalog.products
			expect.truthy(Economy.purchaseOffered(group[offer.key], policy :: any), offer.key)
		end
	end
end

return tests
