--!strict
--[[
	SettingsState (owner: ui agent): the player's client settings (music volume, SFX volume,
	reduced motion) as plain data. Applied locally at once; saving them to the profile needs a
	server remote that does not exist yet (see SettingsController). No Roblox services, so Lune
	can test it.
]]

local SettingsState = {}

export type Settings = {
	musicVolume: number, -- 0..1
	sfxVolume: number, -- 0..1
	reducedMotion: boolean,
}

local current: Settings = { musicVolume = 0.6, sfxVolume = 0.8, reducedMotion = false }
local listeners: { (Settings) -> () } = {}

local function clamp01(v: any, fallback: number): number
	if type(v) ~= "number" or v ~= v then
		return fallback
	end
	return math.clamp(v, 0, 1)
end

-- Turns anything (a saved value, a bad payload) into valid settings. Unknown or wrong-typed
-- fields fall back to `base`.
function SettingsState.sanitize(raw: any, base: Settings): Settings
	if type(raw) ~= "table" then
		return table.clone(base)
	end
	return {
		musicVolume = clamp01(raw.musicVolume, base.musicVolume),
		sfxVolume = clamp01(raw.sfxVolume, base.sfxVolume),
		reducedMotion = if type(raw.reducedMotion) == "boolean" then raw.reducedMotion else base.reducedMotion,
	}
end

function SettingsState.get(): Settings
	return table.clone(current)
end

-- Merges `patch` into the settings (invalid fields ignored) and tells listeners if anything changed.
function SettingsState.set(patch: any)
	local nextValue = SettingsState.sanitize(patch, current)
	if
		nextValue.musicVolume == current.musicVolume
		and nextValue.sfxVolume == current.sfxVolume
		and nextValue.reducedMotion == current.reducedMotion
	then
		return
	end
	current = nextValue
	for _, fn in listeners do
		fn(table.clone(current))
	end
end

function SettingsState.onChanged(fn: (Settings) -> ())
	table.insert(listeners, fn)
end

-- Final volume for a cue: its own base volume scaled by the matching slider.
function SettingsState.volumeFor(kind: "music" | "sfx", base: number, s: Settings): number
	local slider = if kind == "music" then s.musicVolume else s.sfxVolume
	return math.clamp(base * slider, 0, 1)
end

return SettingsState
