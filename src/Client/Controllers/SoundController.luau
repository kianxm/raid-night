--!strict
--[[
	SoundController (owner: ui agent): starts the music loop and plays the alarm sting and
	escape jingle off the same server pushes the HUD already reads. Silent until Audio.CUES
	has ids (D-057). Display only.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Client = script.Parent.Parent
local Net = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Net")) :: any
local Audio = require(Client:WaitForChild("Sound"):WaitForChild("Audio"))

local SoundController = {}

function SoundController.start()
	Audio.startMusic()
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("Remotes")
		local alarm = remotes:WaitForChild(Net.Pushes.BeingRaidedLive) :: RemoteEvent
		alarm.OnClientEvent:Connect(function()
			Audio.play("alarmSting")
		end)
		local ended = remotes:WaitForChild(Net.Pushes.RaidEnded) :: RemoteEvent
		ended.OnClientEvent:Connect(function(payload: any)
			if type(payload) == "table" and payload.escaped == true then
				Audio.play("escapeJingle")
			end
		end)
	end)
end

return SoundController
