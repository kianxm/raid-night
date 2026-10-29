--!strict
-- Player settings (P2.5, C6b): Profile's defaults, the SaveSettings check and the server handlers.
local expect = require("../lib/expect")
local source = require("../lib/source")
local Profile = require("../../src/Shared/Profile")
local Net = require("../../src/Shared/Net")

local NOW = 1_800_000_000

local tests = {}

local function keyCount(t: { [any]: any }): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

local function good(): any
	return { musicVolume = 0.5, sfxVolume = 0.25, reducedMotion = true }
end

tests["the server defaults match the client's: music 0.6, sfx 0.8, reduced motion off"] = function()
	-- ui's SettingsState starts from these before GetSettings answers (PR #121).
	expect.eq(Profile.SETTINGS_DEFAULTS.musicVolume, 0.6)
	expect.eq(Profile.SETTINGS_DEFAULTS.sfxVolume, 0.8)
	expect.eq(Profile.SETTINGS_DEFAULTS.reducedMotion, false)
	expect.truthy(table.isfrozen(Profile.SETTINGS_DEFAULTS :: any))
	local read = Profile.settingsOf(Profile.new(1, NOW))
	expect.eq(read.musicVolume, 0.6, "a new save reads the defaults")
	expect.eq(read.sfxVolume, 0.8)
	expect.eq(read.reducedMotion, false)
	expect.eq(keyCount(read), 3, "GetSettings sends exactly the three settings")
end

tests["missing settings read as defaults, corrupt ones as defaults or clamped"] = function()
	local p: any = Profile.new(1, NOW)
	p.settings = "corrupt"
	expect.eq(Profile.settingsOf(p).musicVolume, 0.6, "a non-table reads as all defaults")
	p.settings = { musicVolume = 0 / 0, sfxVolume = "loud", reducedMotion = 1 }
	local read = Profile.settingsOf(p)
	expect.eq(read.musicVolume, 0.6, "NaN reads as the default")
	expect.eq(read.sfxVolume, 0.8, "a string reads as the default")
	expect.eq(read.reducedMotion, false, "a number reads as the default")
	p.settings = { musicVolume = 7, sfxVolume = -2, reducedMotion = true }
	read = Profile.settingsOf(p)
	expect.eq(read.musicVolume, 1, "too loud reads clamped")
	expect.eq(read.sfxVolume, 0, "below silent reads clamped")
	expect.eq(read.reducedMotion, true)
	p.settings = { musicVolume = 0 }
	read = Profile.settingsOf(p)
	expect.eq(read.musicVolume, 0, "muted is a real choice, not a missing one")
	expect.eq(read.sfxVolume, 0.8, "a field never saved reads its default")
end

tests["cleanSettings clamps volumes to 0..1 and rounds them to 0.01"] = function()
	local cases: { { number } } = {
		{ 1.5, 1 },
		{ -0.25, 0 },
		{ 1e300, 1 },
		{ -1e300, 0 },
		{ 0.456, 0.46 },
		{ 0.4549, 0.45 },
		{ 0, 0 },
		{ 1, 1 },
		{ 0.001, 0 },
	}
	for _, case in cases do
		local request = good()
		request.musicVolume = case[1]
		request.sfxVolume = case[1]
		local clean = Profile.cleanSettings(request)
		expect.truthy(clean, `{case[1]} accepted`)
		expect.eq((clean :: any).musicVolume, case[2], `music {case[1]}`)
		expect.eq((clean :: any).sfxVolume, case[2], `sfx {case[1]}`)
	end
end

tests["cleanSettings refuses NaN, inf, wrong types and missing fields whole"] = function()
	local bad: { any } = {
		"loud",
		42,
		true,
		{},
		{ 0.2, 0.3, false },
		{ musicVolume = 0 / 0, sfxVolume = 0.5, reducedMotion = false },
		{ musicVolume = 0.5, sfxVolume = 0 / 0, reducedMotion = false },
		{ musicVolume = math.huge, sfxVolume = 0.5, reducedMotion = false },
		{ musicVolume = 0.5, sfxVolume = -math.huge, reducedMotion = false },
		{ musicVolume = "0.2", sfxVolume = 0.5, reducedMotion = false },
		{ musicVolume = 0.5, sfxVolume = 0.5, reducedMotion = "yes" },
		{ musicVolume = 0.5, sfxVolume = 0.5, reducedMotion = 1 },
		{ musicVolume = 0.5, sfxVolume = 0.5, reducedMotion = nil }, -- reducedMotion is required
		{ sfxVolume = 0.5, reducedMotion = false }, -- music missing
		{ musicVolume = 0.5, reducedMotion = false }, -- sfx missing
	}
	for i, request in bad do
		expect.eq(Profile.cleanSettings(request), nil, `bad request {i} refused`)
	end
	expect.eq(Profile.cleanSettings(nil), nil, "nil refused")
end

tests["cleanSettings ignores extra keys and reads only the request's own fields"] = function()
	local request: any = good()
	request.admin = true
	request.glow = 1e9
	request[1] = "x"
	local clean = Profile.cleanSettings(request) :: any
	expect.truthy(clean, "extra keys do not refuse a good request")
	expect.eq(keyCount(clean), 3, "only the three settings come out")
	expect.eq(clean.admin, nil)
	expect.eq(clean.glow, nil)

	-- A field reached only through a metatable does not count, and nothing else is read.
	local inherited = setmetatable({ sfxVolume = 0.5, reducedMotion = false }, {
		__index = function(_, key)
			return if key == "musicVolume" then 0.5 else error(`read {key}`)
		end,
	})
	expect.eq(Profile.cleanSettings(inherited), nil, "an inherited field is missing")
	local guarded = setmetatable(good(), {
		__index = function(_, key)
			error(`read {key}`)
		end,
	})
	expect.truthy(Profile.cleanSettings(guarded), "no other key is ever read")
end

tests["applySettings replaces all three settings, and a repeat is still accepted"] = function()
	local p: any = Profile.new(1, NOW)
	expect.truthy(Profile.applySettings(p, { musicVolume = 1.5, sfxVolume = 0.123, reducedMotion = true, x = 1 }))
	expect.eq(p.settings.musicVolume, 1, "clamped")
	expect.eq(p.settings.sfxVolume, 0.12, "rounded")
	expect.eq(p.settings.reducedMotion, true)
	expect.eq(keyCount(p.settings), 3, "the extra key is not saved")
	expect.truthy(Profile.applySettings(p, { musicVolume = 1, sfxVolume = 0.12, reducedMotion = true }))
	expect.eq(p.settings.musicVolume, 1, "the same values again are accepted and unchanged")
	expect.truthy(Profile.applySettings(p, { musicVolume = 0, sfxVolume = 0, reducedMotion = false }))
	local read = Profile.settingsOf(p)
	expect.eq(read.musicVolume, 0)
	expect.eq(read.sfxVolume, 0)
	expect.eq(read.reducedMotion, false, "an explicit choice of the default is saved")
	expect.eq(p.settings.reducedMotion, false)

	local corrupt: any = Profile.new(2, NOW)
	corrupt.settings = 5
	expect.truthy(Profile.applySettings(corrupt, good()), "a corrupt saved value is replaced")
	expect.eq(corrupt.settings.sfxVolume, 0.25)
end

tests["applySettings writes nothing when it refuses"] = function()
	local p: any = Profile.new(1, NOW)
	expect.truthy(Profile.applySettings(p, good()))
	local saved = p.settings
	for _, request in { nil, "x", { musicVolume = 0 / 0, sfxVolume = 1, reducedMotion = false }, {} } :: { any } do
		expect.falsy(Profile.applySettings(p, request))
	end
	expect.eq(p.settings, saved, "the saved table is untouched")
	expect.eq(p.settings.musicVolume, 0.5)
	expect.eq(p.settings.sfxVolume, 0.25)
	expect.eq(p.settings.reducedMotion, true)

	local fresh: any = Profile.new(2, NOW)
	expect.falsy(Profile.applySettings(fresh, { musicVolume = 1 }))
	expect.eq(fresh.settings, nil, "a refused first request leaves the field absent")
end

-- Server handlers (DataService, which Lune cannot run): source guards ----------------------------

local function dataServiceCode(): string
	return source.codeOnly(source.read("src/Server/Services/DataService.luau"))
end

local function body(code: string, name: string): string
	local found = source.functionBody(code, name)
	assert(found, `{name} not found in DataService.luau`)
	return found
end

local function has(text: string, needle: string, message: string)
	expect.truthy(string.find(text, needle, 1, true), message)
end

local function hasNot(text: string, needle: string, message: string)
	expect.eq(string.find(text, needle, 1, true), nil, message)
end

tests["the settings remotes are named in Net and rate-limited about 3 per 10 s"] = function()
	expect.eq(Net.Requests.GetSettings, "GetSettings", "the name ui's SettingsController already calls")
	expect.eq(Net.Requests.SaveSettings, "SaveSettings")
	expect.eq(Net.Limits.GetSettings, 3)
	expect.eq(Net.Limits.SaveSettings, 3)
end

tests["SaveSettings counts every request, checks it with cleanSettings and never forces a save"] = function()
	local code = dataServiceCode()
	local save = body(code, "onSaveSettings")
	has(save, "take(player, Net.Requests.SaveSettings, Net.Limits.SaveSettings)", "rate-limited by its own limit")
	has(save, "Profile.cleanSettings(request)", "the untrusted table goes through cleanSettings")
	has(save, "Profile.applySettings(profile, settings)", "and only the cleaned settings are saved")
	hasNot(save, "saveNow", "settings ride the next autosave or the leave")
	local take = string.find(save, "take(", 1, true) :: number
	local apply = string.find(save, "Profile.applySettings", 1, true) :: number
	expect.truthy(take < apply, "the request is counted before anything is written")
end

tests["a SaveSettings over the limit is kept and lands when the window reopens or on leave"] = function()
	local code = dataServiceCode()
	local save = body(code, "onSaveSettings")
	has(save, "deferredSettings[userId] = settings", "the latest request over the limit is kept")
	has(save, "RateLimit.reopensIn(", "and applied when the window reopens")
	has(save, "deferredSettings[userId] = nil", "a newer request within the limit wins")
	local install = body(code, "installRequests")
	has(install, "DataService.onProfileReleasing(applyDeferredSettings)", "a kept request lands before the final save")
	local apply = body(code, "applyDeferredSettings")
	hasNot(apply, "task.", "the release listener must not yield")
end

tests["GetSettings is rate-limited and answers the defaults-filled settings once the profile loads"] = function()
	local code = dataServiceCode()
	local get = body(code, "onGetSettings")
	has(get, "take(player, Net.Requests.GetSettings, Net.Limits.GetSettings)", "rate-limited")
	has(get, "awaitProfile(player, Net.Requests.GetSettings)", "waits a bounded time for the profile")
	has(get, "Profile.settingsOf(profile)", "defaults filled in")
	local await = body(code, "awaitProfile")
	has(await, "PROFILE_WAIT_SECONDS", "the wait is bounded")
	has(await, "task.wait(PROFILE_POLL_SECONDS)", "and polls, never in a tight loop")
	has(await, "isGone(player)", "and stops when the player leaves")
end

tests["every settings and onboarding remote is guarded so no error reaches the client"] = function()
	local install = body(dataServiceCode(), "installRequests")
	for _, name in { "GetSettings", "SaveSettings", "GetOnboarding", "AckOnboarding" } do
		has(install, `guarded(Net.Requests.{name},`, `{name} is wrapped`)
	end
	has(install, "Net.Pushes.OnboardingChanged", "the push exists")
end

return tests
