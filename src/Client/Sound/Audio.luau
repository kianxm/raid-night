--!strict
--[[
	Audio (owner: ui agent): named sound cues. No audio assets exist yet (D-057), so every id is
	an empty string and nothing plays. To add a sound, paste its "rbxassetid://..." into
	CUES below; no other code changes. Volumes follow the player's settings.
]]

local SoundService = game:GetService("SoundService")

local SettingsState = require(script.Parent.Parent:WaitForChild("Hud"):WaitForChild("SettingsState"))

local Audio = {}

export type Cue = {
	id: string, -- "" = not made yet: the cue is silent
	kind: "music" | "sfx",
	volume: number, -- base volume 0..1, scaled by the matching setting
	looped: boolean,
}

Audio.CUES = {
	alarmSting = { id = "", kind = "sfx", volume = 1, looped = false }, -- den breach alarm
	escapeJingle = { id = "", kind = "sfx", volume = 0.9, looped = false }, -- raid escape
	uiClick = { id = "", kind = "sfx", volume = 0.6, looped = false },
	critterIdle = { id = "", kind = "sfx", volume = 0.4, looped = false }, -- under 1 second
	musicLoop = { id = "", kind = "music", volume = 0.7, looped = true }, -- lo-fi night den loop
} :: { [string]: Cue }

local music: Sound? = nil

local function volume(cue: Cue): number
	return SettingsState.volumeFor(cue.kind, cue.volume, SettingsState.get())
end

local function make(cue: Cue): Sound
	local s = Instance.new("Sound")
	s.SoundId = cue.id
	s.Looped = cue.looped
	s.Volume = volume(cue)
	s.Parent = SoundService
	return s
end

-- Plays a one-shot cue. Unknown names and empty ids do nothing.
function Audio.play(name: string)
	local cue = Audio.CUES[name]
	if not cue or cue.id == "" or cue.looped then
		return
	end
	local s = make(cue)
	s.Ended:Once(function()
		s:Destroy()
	end)
	s:Play()
end

-- Starts the music loop (once) and keeps its volume on the music slider.
function Audio.startMusic()
	local cue = Audio.CUES.musicLoop
	if music or cue.id == "" then
		return
	end
	local s = make(cue)
	music = s
	s:Play()
	SettingsState.onChanged(function()
		s.Volume = volume(cue)
	end)
end

return Audio
