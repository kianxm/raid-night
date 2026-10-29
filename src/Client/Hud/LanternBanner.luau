--!strict
--[[
	LanternBanner (owner: ui agent): a short banner for the Lantern Night announcement. It claims
	"+50% Glow" only when the server says `boosted` is true; otherwise it just names the buyer.
	Never a buy button. Display only.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Client = script.Parent.Parent
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net")) :: any
local Ui = require(Client:WaitForChild("Raid"):WaitForChild("Ui"))
local Strings = require(script.Parent:WaitForChild("Strings"))
local ShopMath = require(script.Parent:WaitForChild("ShopMath"))

local LanternBanner = {}

local SECONDS = 5

function LanternBanner.start()
	local gui = Ui.screenGui("LanternBanner", 8, Players.LocalPlayer:WaitForChild("PlayerGui"))
	local frame = Ui.panel(gui, "Banner", UDim2.fromOffset(340, 48), UDim2.new(0.5, 0, 0, 62))
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.Visible = false
	local label = Ui.label(frame, Ui.DISPLAY, 20, Ui.COLOR.gold)
	label.Size = UDim2.new(1, -16, 1, -8)
	label.Position = UDim2.fromOffset(8, 4)
	local token = 0

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local push = remotes:WaitForChild(Net.Pushes.ServerAnnouncement) :: RemoteEvent
	push.OnClientEvent:Connect(function(kind: any, payload: any)
		if kind ~= "LanternNight" then
			return
		end
		local info = ShopMath.lantern(payload)
		if not info then
			return
		end
		label.Text =
			Strings.format(if info.boosted then Strings.lanternBoosted else Strings.lanternPlain, { name = info.name })
		frame.Visible = true
		Ui.pop(frame)
		token += 1
		local mine = token
		task.delay(SECONDS, function()
			if token == mine then
				frame.Visible = false
			end
		end)
	end)
end

return LanternBanner
