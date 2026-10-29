--[[
	Onboarding simulation (task P2.6f, issue #146, decision D-070): join to the second egg
	(onboarding step buyEgg) and to the first steal home (stealHome), per onboarding egg price.

	    lune run tools/sim/onboarding.luau

	Deterministic. It runs the REAL src/Shared modules (Economy, Profile, CritterCatalog); a row
	only swaps Config.Onboarding.buyEggPrice (a price at or above eggPrice(1) means no discount,
	which is the "before" row). Every starter Common is played once (the rescue egg rolls them with
	equal chance, Economy.rollSpecies), so "mean" is the expected time over the free critter.

	Timing models (seconds; the player buys the moment banked + stored Glow covers the price):
	  floor   no tool latency: hatch at 10, first collect at 30 (Appendix C), 5 s to collect and
	          press Buy, 12 s for the tutorial steal (60 studs of walking, 1.25 s hold). With no
	          discount this gives the issue's ~3:00 floor for a 1 Glow/s critter.
	  studio  the P2.12b scripted Studio run's marks (about 40 s of tool latency in them): hatch at
	          45, first collect at 69, 9 s to collect and buy, 27 s from buyEgg to stealHome. With
	          no discount and a 1 Glow/s critter it reproduces the measured 204 s and 231 s.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")

local ROOT = assert(string.match(debug.info(1, "s"), "^(.*)[/\\]tools[/\\]sim[/\\][^/\\]+$"), "repo root")
local SHARED = `{ROOT}/src/Shared/`

local START = 1_800_000_000

local MODELS = {
	{ name = "floor", hatch = 10, collect = 30, buyOverhead = 5, steal = 12 },
	{ name = "studio", hatch = 45, collect = 69, buyOverhead = 9, steal = 27 },
}

-- 150 = no discount (the "before" row: not below eggPrice(1)). The header prints Config's value.
local PRICES: { number } = { 150, 40, 50, 60, 75 }

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

-- Loads src/Shared fresh, with Config.Onboarding.buyEggPrice replaced when `price` is given.
local function loadShared(price: number?): { [string]: any }
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
		if name == "Config" and price ~= nil then
			module = deepCopy(module)
			assert(type(module.Onboarding.buyEggPrice) == "number", "Config.Onboarding.buyEggPrice")
			module.Onboarding.buyEggPrice = price
			module = deepFreeze(module)
		end
		cache[name] = module
		return module
	end
	return {
		Config = load("Config"),
		Economy = load("Economy"),
		Profile = load("Profile"),
		Catalog = load("CritterCatalog"),
	}
end

-- One player: returns (rate, buyEgg time, stealHome time, price paid).
local function play(M: { [string]: any }, model: any, speciesRoll: number): (number, number, number, number)
	local Economy, Profile = M.Economy, M.Profile
	local p = Profile.prepare(Profile.new(0, 0), 1, START)
	p.storedUpdatedAt = START
	local function roll(uid: string): any
		return { tierRoll = 0, speciesRoll = speciesRoll, uid = uid, maxTier = "Mythic", physicalPads = 6 }
	end

	local t = START + model.hatch
	local free = assert(Economy.buyEgg(p, t, roll("free"), Profile.onboardingStatus(p)), "free egg")
	assert(free.untradeable and free.placement == "Pad", "the free egg is the hatch, on a pad")
	assert(Profile.advanceOnboardingTo(p, "place", t))
	local rate = Economy.denRate(p)

	t = START + model.collect
	assert(Economy.collect(p, t) > 0, "first collect banks Glow")
	assert(Profile.advanceOnboardingTo(p, "collect", t))

	-- Wait at the station until banked + stored covers the egg, then collect and buy.
	local status = Profile.onboardingStatus(p)
	local price = Economy.eggCost(p, status)
	while true do
		Economy.accrue(p, t)
		if math.floor(p.glow + p.stored) >= price then
			break
		end
		t += 1
	end
	t += model.buyOverhead
	Economy.collect(p, t)
	local glowBefore = p.glow
	assert(Economy.buyEgg(p, t, roll("second"), status), "second egg")
	assert(Profile.advanceOnboardingTo(p, "buyEgg", t))
	local buyAt = t - START
	return rate, buyAt, buyAt + model.steal, glowBefore - p.glow
end

local function clock(seconds: number): string
	local s = math.floor(seconds + 0.5)
	return string.format("%d:%02d", s // 60, s % 60)
end

-- Every Common the rescue egg can hatch, one species roll each (the middle of its slot).
local probe = loadShared(nil)
local commons = 0
for _, species in probe.Catalog.all() do
	if species.tier == "Common" then
		commons += 1
	end
end
assert(commons > 0, "Commons")

print("Onboarding: join -> second egg (buyEgg) -> first steal home (stealHome), per onboarding egg price")
print(
	`Real Config.Onboarding.buyEggPrice = {probe.Config.Onboarding.buyEggPrice}, eggPrice(1) = {probe.Economy.eggPrice(
		1
	)}`
)
print("")
print("| price | model | buyEgg @1 Glow/s | stealHome @1 | @2 | @3 | stealHome mean | worst | paid |")
print("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
for _, price in PRICES do
	local M = loadShared(price)
	for _, model in MODELS do
		local byRate: { [number]: { buy: number, home: number } } = {}
		local sum, worst, paid = 0, 0, 0
		for i = 1, commons do
			local rate, buyAt, homeAt, cost = play(M, model, (i - 0.5) / commons)
			byRate[rate] = { buy = buyAt, home = homeAt }
			sum += homeAt
			worst = math.max(worst, homeAt)
			paid = cost
		end
		local function at(rate: number, key: string): string
			local row = byRate[rate]
			return if row then clock((row :: any)[key]) else "-"
		end
		print(
			`| {price} | {model.name} | {at(1, "buy")} | {at(1, "home")} | {at(2, "home")} | {at(3, "home")} | {clock(
				sum / commons
			)} | {clock(worst)} | {paid} |`
		)
	end
end
