--!strict
--[[
	Test runner for pure game logic. Runs under Lune, no Roblox Studio needed:

	    lune run tests/run.luau            -- all specs
	    lune run tests/run.luau Escrow     -- only specs whose file name contains "Escrow"

	Exits with code 1 if anything fails, so CI and agents can rely on it.
	Add new spec files to SPECS below.
]]

local process = require("@lune/process")

local SPECS: { { name: string, load: () -> { [string]: () -> () } } } = {
	{
		name = "AssetPrompts",
		load = function()
			return require("./specs/AssetPrompts.spec")
		end,
	},
	{
		name = "AssetKit",
		load = function()
			return require("./specs/AssetKit.spec")
		end,
	},
	{
		name = "Catalog",
		load = function()
			return require("./specs/Catalog.spec")
		end,
	},
	{
		name = "Config",
		load = function()
			return require("./specs/Config.spec")
		end,
	},
	{
		name = "Economy",
		load = function()
			return require("./specs/Economy.spec")
		end,
	},
	{
		name = "GearMath",
		load = function()
			return require("./specs/GearMath.spec")
		end,
	},
	{
		name = "InventoryMath",
		load = function()
			return require("./specs/InventoryMath.spec")
		end,
	},
	{
		name = "SettingsState",
		load = function()
			return require("./specs/SettingsState.spec")
		end,
	},
	{
		name = "ShopMath",
		load = function()
			return require("./specs/ShopMath.spec")
		end,
	},
	{
		name = "CritterVisuals",
		load = function()
			return require("./specs/CritterVisuals.spec")
		end,
	},
	{
		name = "Purchases",
		load = function()
			return require("./specs/Purchases.spec")
		end,
	},
	{
		name = "PurchaseSource",
		load = function()
			return require("./specs/PurchaseSource.spec")
		end,
	},
	{
		name = "OnboardingMath",
		load = function()
			return require("./specs/OnboardingMath.spec")
		end,
	},
	{
		name = "HudMath",
		load = function()
			return require("./specs/HudMath.spec")
		end,
	},
	{
		name = "HudLayout",
		load = function()
			return require("./specs/HudLayout.spec")
		end,
	},
	{
		name = "RaidRules",
		load = function()
			return require("./specs/RaidRules.spec")
		end,
	},
	{
		name = "RaidRulesLive",
		load = function()
			return require("./specs/RaidRulesLive.spec")
		end,
	},
	{
		name = "AsyncRaidRules",
		load = function()
			return require("./specs/AsyncRaidRules.spec")
		end,
	},
	{
		name = "LiveLossRules",
		load = function()
			return require("./specs/LiveLossRules.spec")
		end,
	},
	{
		name = "RaidServiceSource",
		load = function()
			return require("./specs/RaidServiceSource.spec")
		end,
	},
	{
		name = "GearRules",
		load = function()
			return require("./specs/GearRules.spec")
		end,
	},
	{
		name = "Replay",
		load = function()
			return require("./specs/Replay.spec")
		end,
	},
	{
		name = "Matchmaking",
		load = function()
			return require("./specs/Matchmaking.spec")
		end,
	},
	{
		name = "NotificationRules",
		load = function()
			return require("./specs/NotificationRules.spec")
		end,
	},
	{
		name = "Plots",
		load = function()
			return require("./specs/Plots.spec")
		end,
	},
	{
		name = "WorldKit",
		load = function()
			return require("./specs/WorldKit.spec")
		end,
	},
	{
		name = "Profile",
		load = function()
			return require("./specs/Profile.spec")
		end,
	},
	{
		name = "Settings",
		load = function()
			return require("./specs/Settings.spec")
		end,
	},
	{
		name = "Onboarding",
		load = function()
			return require("./specs/Onboarding.spec")
		end,
	},
	{
		name = "OnboardingEgg",
		load = function()
			return require("./specs/OnboardingEgg.spec")
		end,
	},
	{
		name = "TutorialGrant",
		load = function()
			return require("./specs/TutorialGrant.spec")
		end,
	},
	{
		name = "RaidOnboarding",
		load = function()
			return require("./specs/RaidOnboarding.spec")
		end,
	},
	{
		name = "RateLimit",
		load = function()
			return require("./specs/RateLimit.spec")
		end,
	},
	{
		name = "Escrow",
		load = function()
			return require("./specs/Escrow.spec")
		end,
	},
	{
		name = "EscrowServiceSource",
		load = function()
			return require("./specs/EscrowServiceSource.spec")
		end,
	},
	{
		name = "EscrowKillSwitch",
		load = function()
			return require("./specs/EscrowKillSwitch.spec")
		end,
	},
	{
		name = "TestProfiles",
		load = function()
			return require("./specs/TestProfiles.spec")
		end,
	},
	{
		name = "TestSessions",
		load = function()
			return require("./specs/TestSessions.spec")
		end,
	},
	{
		name = "Analytics",
		load = function()
			return require("./specs/Analytics.spec")
		end,
	},
	{
		name = "AnalyticsServiceSource",
		load = function()
			return require("./specs/AnalyticsServiceSource.spec")
		end,
	},
	{
		name = "EscrowSimulation",
		load = function()
			return require("./specs/EscrowSimulation.spec")
		end,
	},
}

local filter = process.args[1]
local passed, failed = 0, 0
local failures: { string } = {}
local started = os.clock()

for _, spec in SPECS do
	if filter and not string.find(spec.name, filter, 1, true) then
		continue
	end
	print(`\n{spec.name}`)
	local tests = spec.load()
	local names = {}
	for name in tests do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		local t0 = os.clock()
		local ok, err = pcall(tests[name])
		local ms = math.floor((os.clock() - t0) * 1000)
		if ok then
			passed += 1
			print(`  PASS  {name} ({ms} ms)`)
		else
			failed += 1
			print(`  FAIL  {name}\n        {err}`)
			table.insert(failures, `{spec.name} > {name}`)
		end
	end
end

local seconds = string.format("%.2f", os.clock() - started)
print(`\n{passed} passed, {failed} failed in {seconds}s`)
if failed > 0 then
	for _, name in failures do
		print(`  - {name}`)
	end
	process.exit(1)
end
