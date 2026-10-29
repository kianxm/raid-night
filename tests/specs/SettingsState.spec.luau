--!strict
local expect = require("../lib/expect")
local SettingsState = require("../../src/Client/Hud/SettingsState")

local tests = {}

local base = { musicVolume = 0.5, sfxVolume = 0.5, reducedMotion = false }

tests["sanitize clamps volumes and keeps the base for bad fields"] = function()
	local s = SettingsState.sanitize({ musicVolume = 3, sfxVolume = -1, reducedMotion = "yes" }, base)
	expect.eq(s.musicVolume, 1, "clamped high")
	expect.eq(s.sfxVolume, 0, "clamped low")
	expect.eq(s.reducedMotion, false, "bad type falls back")
	expect.eq(SettingsState.sanitize(nil, base).musicVolume, 0.5, "non-table")
	expect.eq(SettingsState.sanitize({ musicVolume = 0 / 0 }, base).musicVolume, 0.5, "NaN")
end

tests["set merges, notifies once, and ignores no-ops"] = function()
	local calls = 0
	SettingsState.onChanged(function()
		calls += 1
	end)
	SettingsState.set({ reducedMotion = true })
	SettingsState.set({ reducedMotion = true })
	expect.eq(calls, 1, "one change")
	expect.eq(SettingsState.get().reducedMotion, true, "applied")
	SettingsState.set({ sfxVolume = 0.25 })
	expect.eq(SettingsState.get().reducedMotion, true, "other fields kept")
end

tests["volumeFor scales the cue by its slider"] = function()
	local s = { musicVolume = 0.5, sfxVolume = 0, reducedMotion = false }
	expect.near(SettingsState.volumeFor("music", 0.8, s), 0.4, 1e-9, "music")
	expect.eq(SettingsState.volumeFor("sfx", 1, s), 0, "muted sfx")
end

return tests
