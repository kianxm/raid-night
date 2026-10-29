--[[
	Economy simulation (task P1.7): one player from den level 1 to their first rebirth.

	    lune run tools/sim/economy.luau              -- every scenario, 60 players each
	    lune run tools/sim/economy.luau 10           -- 10 players per scenario
	    lune run tools/sim/economy.luau 40 proposed  -- one scenario

	Seeded and deterministic: player i always uses seed i, so two runs print the same report.
	It runs the REAL src/Shared modules (Economy, RaidRules, Escrow, Matchmaking, Profile,
	CritterCatalog, Data/Critters). A scenario only swaps Config values: the modules are loaded
	again with a Config copy whose overrides are checked against the real Config's shape.

	Player model (assumptions, all in SIM below): 2-3 sessions a day of 10-25 min in UTC
	afternoon/evening (+ morning on 3-session days), collecting every 30 s while online.
	Spending: upgrade the den when affordable; else buy an egg if a pad is free, or if the egg's
	expected Glow/s gain pays its price back within SIM.eggPaybackHours. The best critter sits in
	the vault, the next best on pads (Economy.place), the rest in Inventory.
	Async raids both ways through Escrow (create, debitDefender, markDebited, creditRaider) and
	RaidRules.canRaid: 1-3 outgoing raids per session against a den of similar power (a mirror
	of the player's pads, same tiers, rolled species, offline 0-12 h); incoming raid attempts
	arrive while offline at the rate the player raids (a symmetric population). Loot Glow is 25%
	of stored Glow accrued to the raid moment (the design's rule). Live steals are not modeled.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local Rng = require("../../tests/lib/rng")

local HOUR, DAY = 3600, 86400

local SIM = {
	players = 60,
	maxDays = 120,
	start = 1_800_000_000 - 1_800_000_000 % DAY, -- a UTC midnight
	sessionMinutes = { 10, 25 },
	threeSessionShare = 0.5, -- share of days with 3 sessions; the rest have 2
	windows = { { 7, 9 }, { 15.5, 18 }, { 19, 22 } }, -- UTC hours; 2-session days skip the first
	step = 30, -- seconds between collects while online
	raidsPerSession = { 1, 3 },
	raidSeconds = 180,
	raidSuccess = 0.5, -- design target 45-60%
	opponentOfflineHours = 12,
	eggPaybackHours = 6,
	physicalPads = 30, -- design: pads 6 -> 30 (the Phase 0 world builds 6)
}

-- Scenarios: Config overrides as "Section.key" = value, or "EggOdds.<Tier>" = weight.
-- P1_8: the values Kian approved at the Phase 1 gate (P1.8), i.e. Config before P2.4t.
local P1_8 = { ["Economy.eggPriceBase"] = 150, ["Economy.eggPriceGrowth"] = 1.32 }
-- P2.4t option B: a steeper egg price plus doubled Legendary/Mythic odds (paid for by Rare).
-- Changes the published odds, so it needs a design call (and HudMath.spec / contracts.md updates).
local ODDS = {
	["Economy.eggPriceBase"] = 450,
	["Economy.eggPriceGrowth"] = 1.28,
	["EggOdds.Rare"] = 0.10,
	["EggOdds.Legendary"] = 0.036,
	["EggOdds.Mythic"] = 0.004,
}
local PHASE2 = { ["Economy.eggMaxTier"] = "Mythic" } -- D-003: Phase 2 raises the egg cap (live from P2.4)
local PHASE1_CAP = { ["Economy.eggMaxTier"] = "Uncommon" } -- the Phase 0-1 cap, for before/after rows

local function merge(...: { [string]: any }): { [string]: any }
	local out = {}
	for _, t in { ... } do
		for k, v in t do
			out[k] = v
		end
	end
	return out
end

local SCENARIOS = {
	{ name = "current", note = "Config as it is (P2.4t proposal, eggMaxTier Mythic)", overrides = {} },
	{
		name = "no-change",
		note = "P1.8 values with eggMaxTier Mythic (Config before P2.4t)",
		overrides = merge(PHASE2, P1_8),
	},
	{
		name = "phase1-cap",
		note = "P1.8 values with eggMaxTier Uncommon (the Phase 1 mid-game pace)",
		overrides = merge(P1_8, PHASE1_CAP),
	},
	{
		name = "odds",
		note = "option B: egg price 450 x1.28, Rare 10%, Legendary 3.6%, Mythic 0.4%",
		overrides = merge(PHASE2, ODDS),
	},
}

-- Module loading --------------------------------------------------------------------------------

local ROOT = assert(string.match(debug.info(1, "s"), "^(.*)[/\\]tools[/\\]sim[/\\][^/\\]+$"), "repo root")
local SHARED = `{ROOT}/src/Shared/`

local function deepCopy(t: any): any
	if type(t) ~= "table" then
		return t
	end
	local out = {}
	for k, v in t do
		out[k] = deepCopy(v)
	end
	return out
end

local function deepFreeze(t: any): any
	for _, v in t do
		if type(v) == "table" and not table.isfrozen(v) then
			deepFreeze(v)
		end
	end
	return table.freeze(t)
end

local function loadShared(overrides: { [string]: any }): { [string]: any }
	local cache = {}
	local function load(name: string): any
		if cache[name] then
			return cache[name]
		end
		local dir = string.match(name, "^(.*)/") or ""
		local function req(path: string): any
			local rel = string.gsub(path, "^%./", "")
			if string.sub(rel, 1, 3) == "../" then
				rel = string.sub(rel, 4)
			elseif dir ~= "" then
				rel = `{dir}/{rel}`
			end
			return load(rel)
		end
		local chunk =
			luau.load(fs.readFile(SHARED .. name .. ".luau"), { debugName = name, environment = { require = req } })
		local module = chunk()
		if name == "Config" then
			module = deepCopy(module)
			for key, value in overrides do
				local section, field = string.match(key, "^(%w+)%.(%w+)$")
				local tbl = section and module[section]
				if section == "EggOdds" then
					-- EggOdds.<Tier>=weight sets that tier's weight; the weights must still sum to 1.
					local entry = nil
					for _, e in tbl do
						entry = if e.tier == field then e else entry
					end
					assert(entry and type(value) == "number", `override {key}: no EggOdds tier {field}`)
					entry.weight = value
				else
					assert(tbl and type(tbl[field]) == type(value), `override {key} does not match Config's shape`)
					tbl[field] = value
				end
			end
			local total = 0
			for _, e in module.EggOdds do
				total += e.weight
			end
			assert(math.abs(total - 1) < 1e-9, `EggOdds weights sum to {total}, not 1`)
			module = deepFreeze(module)
		end
		cache[name] = module
		return module
	end
	return {
		Config = load("Config"),
		Economy = load("Economy"),
		RaidRules = load("RaidRules"),
		Escrow = load("Escrow"),
		Matchmaking = load("Matchmaking"),
		Profile = load("Profile"),
		Catalog = load("CritterCatalog"),
	}
end

-- One player ------------------------------------------------------------------------------------

local function simulatePlayer(M: { [string]: any }, seed: number): { [string]: any }
	local Config, Economy, RaidRules, Escrow, Catalog = M.Config, M.Economy, M.RaidRules, M.Escrow, M.Catalog
	local rng = Rng.new(seed * 7919)
	local maxTier = Config.Economy.eggMaxTier
	-- Raided dens mirror the player's own tiers, so eggs are the only source of a rebirth tier.
	local canEverRebirth = Catalog.tierRank(maxTier) >= Catalog.tierRank(Config.Economy.rebirthMinTier)
	local pads = SIM.physicalPads
	local p = M.Profile.new(1, SIM.start)
	local nextId = 0
	local function uid(prefix: string): string
		nextId += 1
		return `{prefix}{nextId}`
	end
	local function rate(c: any): number
		return Catalog.get(c.speciesId).glowPerSecond
	end

	local out = {
		levelAt = {} :: { [number]: { days: number, played: number, rate: number } },
		daily = {} :: { [number]: { level: number, held: number, price: number } }, -- at each day's last session end
		passive = 0,
		lootIn = 0,
		lootOut = 0,
		eggs = 0,
		raids = 0,
		raidWins = 0,
		revenge = 0,
		stolenIn = 0,
		raidedAttempts = 0,
		raidedHits = 0,
		lost = 0,
		rebirthDay = nil :: number?,
		played = 0,
	}

	-- Best critter in the vault, the next best on pads, the rest in Inventory (only Legendary+
	-- junk is kept: lower Inventory critters never earn again, and dropping them keeps it fast).
	local function arrange(now: number)
		local list = {}
		for _, c in p.critters do
			table.insert(list, c)
		end
		table.sort(list, function(a, b)
			return if rate(a) ~= rate(b) then rate(a) > rate(b) else a.uid < b.uid
		end)
		local usable = Economy.usablePadCount(p.denLevel, pads)
		local want = {}
		for i, c in list do
			want[c.uid] = if i <= p.vaultSlots then "Vault" elseif i <= p.vaultSlots + usable then "Pad" else "Inventory"
		end
		for _, c in list do
			if c.placement ~= want[c.uid] and c.placement ~= "Inventory" then
				assert(Economy.place(p, c.uid, "Inventory", nil, pads, now))
			end
		end
		for _, c in list do
			if c.placement ~= want[c.uid] then
				local pad = if want[c.uid] == "Pad" then Economy.firstFreePad(p, pads) else nil
				assert(Economy.place(p, c.uid, want[c.uid], pad, pads, now))
			end
			if
				c.placement == "Inventory"
				and Catalog.tierRank(Catalog.get(c.speciesId).tier) < Catalog.tierRank("Legendary")
			then
				p.critters[c.uid] = nil
			end
		end
	end

	local function weakestPadRate(): number?
		local usable = Economy.usablePadCount(p.denLevel, pads)
		local weakest, used = math.huge, 0
		for _, c in p.critters do
			if c.placement == "Pad" then
				used += 1
				weakest = math.min(weakest, rate(c))
			end
		end
		return if used < usable then nil else weakest
	end

	-- Expected Glow/s an egg adds over the weakest pad critter, from the published odds.
	local function eggGain(weakest: number): number
		local gain = 0
		for _, t in Economy.eggTierOdds(maxTier) do
			for _, s in Economy.speciesOdds(t.tier) do
				gain += t.chance * s.chance * math.max(0, Catalog.get(s.speciesId).glowPerSecond - weakest)
			end
		end
		return gain
	end

	local function spend(now: number)
		for _ = 1, 500 do
			local cost = Economy.upgradeCost(p.denLevel)
			if cost and p.glow >= cost then
				assert(Economy.upgradeDen(p, now))
				local lvl = p.denLevel
				out.levelAt[lvl] =
					{ days = (now - SIM.start) / DAY, played = out.played / HOUR, rate = Economy.denRate(p) }
				arrange(now)
				continue
			end
			local price = Economy.eggCost(p)
			local weakest = weakestPadRate()
			-- At max level without a Legendary, eggs are the only way to rebirth: buy every one.
			local hunting = cost == nil and canEverRebirth and not Economy.canRebirth(p)
			local worth = hunting or weakest == nil or eggGain(weakest) * SIM.eggPaybackHours * HOUR >= price
			if p.glow < price or not worth then
				return
			end
			local critter = Economy.buyEgg(p, now, {
				tierRoll = rng.next(),
				speciesRoll = rng.next(),
				uid = uid("egg"),
				maxTier = maxTier,
				physicalPads = pads,
			})
			assert(critter, "egg purchase failed")
			out.eggs += 1
			arrange(now)
		end
	end

	-- A den like the player's (same tiers on the same number of pads, species rolled), offline
	-- 0-12 h, old enough and big enough to raid.
	local function opponent(now: number): any
		nextId += 1
		local d = M.Profile.new(-nextId, now - 30 * DAY)
		d.denLevel = math.max(Config.Protection.minDenLevel, p.denLevel)
		local pad = 0
		for _, c in p.critters do
			if c.placement == "Pad" then
				pad += 1
				local species = Economy.rollSpecies(Catalog.get(c.speciesId).tier, rng.next())
				local id = uid("opp")
				d.critters[id] = {
					uid = id,
					speciesId = species.id,
					mutation = "None",
					placement = "Pad",
					padIndex = pad,
					acquiredAt = 0,
				}
			end
		end
		d.storedUpdatedAt = now - rng.next() * SIM.opponentOfflineHours * HOUR
		RaidRules.resetDailyIfNeeded(d, now)
		return d
	end

	-- One async raid from `raider` on `defender` at `now`, through the real escrow steps.
	local function raid(raider: any, defender: any, now: number, isRevenge: boolean): (boolean, any?)
		RaidRules.resetDailyIfNeeded(raider, now)
		local snapshot = M.Matchmaking.buildSnapshot(defender, now) -- accrues: stored at the raid moment
		local ok = RaidRules.canRaid(raider, snapshot, RaidRules.lossesToday(defender, now), now, nil)
		if not ok and not isRevenge then
			return false, nil
		end
		local escaped = rng.chance(SIM.raidSuccess)
		local best = nil
		for _, c in snapshot.critters do
			if c.placement == "Pad" and (best == nil or rate(c) > rate(best)) then
				best = c
			end
		end
		local raidId = uid("raid")
		RaidRules.recordOutgoing(raider, raidId, defender.userId, escaped, nil, 0, isRevenge, now)
		if not escaped then
			return true, nil
		end
		local glowAsk = RaidRules.lootGlow(snapshot, isRevenge)
		local record =
			Escrow.create(raidId, raider.userId, defender.userId, best and best.uid, glowAsk, isRevenge, now, "Async")
		Escrow.markDebited(record, Escrow.debitDefender(defender, record, now), now)
		return true, Escrow.creditRaider(raider, record, now)
	end

	local function session(startAt: number, minutes: number)
		local now = startAt
		local stop = startAt + minutes * 60
		local raidsLeft = rng.int(SIM.raidsPerSession[1], SIM.raidsPerSession[2])
		while now < stop do
			out.passive += Economy.collect(p, now)
			spend(now)
			if Economy.canRebirth(p) then
				out.rebirthDay = (now - SIM.start) / DAY
				return
			end
			if raidsLeft > 0 and now + SIM.raidSeconds <= stop then
				raidsLeft -= 1
				RaidRules.pruneRevengeTokens(p, now)
				local token = next(p.revengeTokens)
				if token then
					p.revengeTokens[token] = nil
					out.revenge += 1
				end
				local done, credit = raid(p, opponent(now), now, token ~= nil)
				if done then
					out.raids += 1
					now += SIM.raidSeconds
					out.played += SIM.raidSeconds
					if credit then
						out.raidWins += 1
						out.lootIn += credit.glow
						out.stolenIn += if credit.critter then 1 else 0
						arrange(now)
					end
				end
			else
				now += SIM.step
				out.played += SIM.step
			end
		end
		out.passive += Economy.collect(p, now)
		spend(now)
		local day = math.floor((now - SIM.start) / DAY) + 1
		out.daily[day] = { level = p.denLevel, held = p.glow + p.stored, price = Economy.eggPrice(p.denLevel) }
		return now
	end

	-- Incoming raid attempts while offline: a Poisson process at the player's own raid rate.
	local perSecond = (SIM.raidsPerSession[1] + SIM.raidsPerSession[2]) / 2 * 2.5 / DAY
	local function offline(from: number, to: number)
		local t = from
		while true do
			t += -math.log(1 - rng.next()) / perSecond
			if t >= to then
				return
			end
			out.raidedAttempts += 1
			local storedBefore = 0
			local critters = 0
			Economy.accrue(p, t)
			storedBefore = p.stored
			for _ in p.critters do
				critters += 1
			end
			local raider = M.Profile.new(-1_000_000 - out.raidedAttempts, t)
			local _, credit = raid(raider, p, t, false)
			if credit then
				out.raidedHits += 1
				out.lootOut += storedBefore - p.stored
				local after = 0
				for _ in p.critters do
					after += 1
				end
				out.lost += critters - after
			end
		end
	end

	local lastEnd = SIM.start
	for day = 0, SIM.maxDays - 1 do
		local count = if rng.chance(SIM.threeSessionShare) then 3 else 2
		for w = 4 - count, 3 do
			local window = SIM.windows[w]
			local startAt = SIM.start + day * DAY + (window[1] + rng.next() * (window[2] - window[1])) * HOUR
			if startAt > lastEnd then
				offline(lastEnd, startAt)
				local ended = session(startAt, rng.int(SIM.sessionMinutes[1], SIM.sessionMinutes[2]))
				-- Done at rebirth, or at max level when no egg can hatch a rebirth tier (stuck for good).
				if out.rebirthDay or (p.denLevel >= Config.Economy.maxDenLevel and not canEverRebirth) then
					out.finalLevel = p.denLevel
					return out
				end
				lastEnd = ended
			end
		end
	end
	out.finalLevel = p.denLevel
	return out
end

-- Report ----------------------------------------------------------------------------------------

local function quantile(values: { number }, q: number): number?
	if #values == 0 then
		return nil
	end
	local sorted = table.clone(values)
	table.sort(sorted)
	return sorted[math.clamp(math.floor(q * (#sorted - 1) + 1.5), 1, #sorted)]
end

local function fmt(x: number?, digits: number?): string
	if x == nil then
		return "-"
	end
	local d = digits or 1
	if math.abs(x) >= 1e6 then
		return string.format("%.2fM", x / 1e6)
	elseif math.abs(x) >= 1e4 then
		return string.format("%.0fk", x / 1e3)
	end
	return string.format(`%.{d}f`, x)
end

local function runScenario(scenario: any, players: number): { [string]: any }
	local M = loadShared(scenario.overrides)
	assert(#M.Catalog.validate() == 0, "CritterCatalog.validate() is not clean")
	local results = {}
	for seed = 1, players do
		table.insert(results, simulatePlayer(M, seed))
	end
	return { scenario = scenario, results = results, M = M }
end

local function column(results: { any }, pick: (any) -> number?): { number }
	local values = {}
	for _, r in results do
		local v = pick(r)
		if v ~= nil then
			table.insert(values, v)
		end
	end
	return values
end

local function report(run: { [string]: any })
	local results, M = run.results, run.M
	print(`\n## Scenario \`{run.scenario.name}\`: {run.scenario.note}\n`)
	local rebirths = column(results, function(r)
		return r.rebirthDay
	end)
	print(
		`First rebirth: {#rebirths}/{#results} players within {SIM.maxDays} days; median day {fmt(
			quantile(rebirths, 0.5)
		)} (p10 {fmt(quantile(rebirths, 0.1))}, p90 {fmt(quantile(rebirths, 0.9))}).`
	)
	local final = column(results, function(r)
		return r.finalLevel
	end)
	local stuck = 0
	for _, r in results do
		stuck += if r.rebirthDay == nil and r.finalLevel >= M.Config.Economy.maxDenLevel then 1 else 0
	end
	print(
		`Den level at the end: median {fmt(quantile(final, 0.5), 0)}; {stuck} stuck at max level without a Legendary.\n`
	)
	print("| Den level | Upgrade cost | Egg price | Day reached (median) | Hours played | Glow/s on reaching |")
	print("| --- | --- | --- | --- | --- | --- |")
	for _, level in { 2, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50 } do
		local at = function(field)
			return quantile(
				column(results, function(r)
					return r.levelAt[level] and r.levelAt[level][field]
				end),
				0.5
			)
		end
		local cost = M.Economy.upgradeCost(level - 1)
		print(
			`| {level} | {fmt(cost, 0)} | {fmt(M.Economy.eggPrice(level), 0)} | {fmt(at("days"))} | {fmt(at("played"))} | {fmt(
				at("rate"),
				0
			)} |`
		)
	end
	-- Time per level band: each player's own days and hours from one level to the next, then the
	-- median over the players who reached both ends (level 1 is day 0, 0 h).
	print("\n| Level band | Players | Days in band (median) | Hours played in band (median) |")
	print("| --- | --- | --- | --- |")
	for _, band in { { 1, 10 }, { 10, 20 }, { 20, 30 }, { 30, 40 }, { 40, 50 } } do
		local from, to = band[1], band[2]
		local function span(field: string): { number }
			return column(results, function(r)
				local a = if from == 1 then { days = 0, played = 0 } else r.levelAt[from]
				local b = r.levelAt[to]
				return if a and b then b[field] - a[field] else nil
			end)
		end
		local days = span("days")
		print(`| {from} -> {to} | {#days} | {fmt(quantile(days, 0.5))} | {fmt(quantile(span("played"), 0.5))} |`)
	end
	print(
		"\n| Day | Players still playing | Den level | Glow held at last session end | Egg price | Held / egg price |"
	)
	print("| --- | --- | --- | --- | --- | --- |")
	for _, day in { 1, 2, 3, 5, 7, 10, 14, 21, 28, 42, 60, 90, 120 } do
		local rows = column(results, function(r)
			return r.daily[day] and 1
		end)
		if #rows > 0 then
			local q = function(pick)
				return quantile(
					column(results, function(r)
						return r.daily[day] and pick(r.daily[day])
					end),
					0.5
				)
			end
			-- stylua: ignore
			print(`| {day} | {#rows} | {fmt(q(function(d) return d.level end), 0)} | {fmt(q(function(d) return d.held end), 0)} | {fmt(q(function(d) return d.price end), 0)} | {fmt(q(function(d) return d.held / d.price end))} |`)
		end
	end
	local sum = function(field)
		local total = 0
		for _, r in results do
			total += r[field]
		end
		return total
	end
	local days = sum("played") / HOUR
	local lootShare = 100 * sum("lootIn") / (sum("passive") + sum("lootIn"))
	local lostShare = 100 * sum("lootOut") / (sum("passive") + sum("lootOut"))
	print(
		`\nRaid economy (all players): raid loot is {fmt(lootShare)}% of Glow income; raiders took {fmt(lostShare)}% of the passive Glow the dens earned.`
	)
	print(
		`Outgoing raids {sum("raids")} ({fmt(100 * sum("raidWins") / math.max(1, sum("raids")))}% won, {sum("revenge")} revenge), critters stolen {sum(
			"stolenIn"
		)}; incoming attempts {sum("raidedAttempts")}, hits {sum("raidedHits")}, critters lost {sum("lost")}; eggs {sum(
			"eggs"
		)}; {fmt(days)} h played.`
	)
end

-- `lune run tools/sim/economy.luau 40 custom Economy.eggPriceGrowth=1.3 Economy.eggMaxTier=Mythic`
-- runs one scenario with the given Config overrides (for sweeps and P1.8 checks); `sim.<field>=x`
-- changes a player-model assumption instead (sim.raidSuccess=0.6).
local args = process.args
local players = tonumber(args[1]) or SIM.players
if args[2] == "custom" then
	local overrides = {}
	for i = 3, #args do
		local key, value = string.match(args[i], "^([%w%.]+)=(.+)$")
		assert(key, `bad override "{args[i]}", expected Section.key=value`)
		local simField = string.match(key, "^sim%.(%w+)$")
		local sim: any = SIM
		if simField then
			assert(type(sim[simField]) == "number", `unknown sim field {simField}`)
			sim[simField] = assert(tonumber(value), `sim.{simField} must be a number`)
		else
			overrides[key] = tonumber(value) or value
		end
	end
	table.insert(SCENARIOS, { name = "custom", note = table.concat(args, " ", 3), overrides = overrides })
end
for _, scenario in SCENARIOS do
	if args[2] == nil or args[2] == scenario.name then
		report(runScenario(scenario, players))
	end
end
