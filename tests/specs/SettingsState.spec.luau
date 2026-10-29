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

tests["retry delay backs off to a 30 s ceiling"] = function()
	expect.eq(SettingsState.retryDelay(1), 2, "first")
	expect.eq(SettingsState.retryDelay(3), 8, "third")
	expect.eq(SettingsState.retryDelay(5), 30, "capped")
	expect.eq(SettingsState.retryDelay(40), 30, "stays capped")
	expect.eq(SettingsState.retryDelay(0), 2, "bad attempt")
end

tests["a late load keeps what the player already touched"] = function()
	local saved = { musicVolume = 0.2, sfxVolume = 0.3, reducedMotion = true }
	local local_ = { musicVolume = 0.9, sfxVolume = 0.8, reducedMotion = false }
	local merged = SettingsState.mergeLoaded(saved, local_, { musicVolume = true })
	expect.eq(merged.musicVolume, 0.9, "touched keeps local")
	expect.eq(merged.sfxVolume, 0.3, "untouched takes saved")
	expect.eq(merged.reducedMotion, true, "untouched takes saved")
	expect.eq(SettingsState.mergeLoaded(nil, local_, {}).sfxVolume, 0.8, "bad payload keeps local")
end

return tests
