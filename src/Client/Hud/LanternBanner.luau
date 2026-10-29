--!strict
--[[
	LanternBanner (owner: ui agent): a short banner for the Lantern Night announcement. Shown only
	when the server says `boosted` is true; otherwise (restricted players, D-061) nothing at all
	appears, not even the buyer's name. Never a buy button. Display only.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Client = script.Parent.Parent
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net")) :: any
local Ui = require(Client:WaitForChild("Raid"):WaitForChild("Ui"))
local Theme = Ui.theme
local Strings = require(script.Parent:WaitForChild("Strings"))
local ShopMath = require(script.Parent:WaitForChild("ShopMath"))

local LanternBanner = {}

local SECONDS = 5

function LanternBanner.start()
	local gui = Ui.screenGui("LanternBanner", 8, Players.LocalPlayer:WaitForChild("PlayerGui"))
	-- Boost banner: gold-rimmed panel, siren dot, title over a dim caption (design: Lantern Night).
	local frame = Ui.panel(gui, "Banner", UDim2.fromOffset(420, 56), UDim2.new(0.5, 0, 0, 62))
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.Visible = false
	local rim = frame:FindFirstChildOfClass("UIStroke")
	if rim then
		rim.Color = Theme.color.gold
	end
	local cap = Instance.new("UISizeConstraint")
	cap.MaxSize = Vector2.new(420, 56)
	cap.Parent = frame
	local siren = Instance.new("Frame")
	siren.Name = "Siren"
	siren.AnchorPoint = Vector2.new(0, 0.5)
	siren.Position = UDim2.new(0, 14, 0.5, 0)
	siren.Size = UDim2.fromOffset(16, 22)
	siren.BackgroundColor3 = Theme.color.gold
	siren.BorderSizePixel = 0
	Theme.corner(siren, Theme.radius.sm)
	Theme.outline(siren, Theme.stroke.thin)
	siren.Parent = frame
	local label = Ui.label(frame, Ui.DISPLAY, Theme.type.buttonText, Theme.color.gold)
	label.Size = UDim2.new(1, -52, 0, 26)
	label.Position = UDim2.fromOffset(42, 5)
	label.TextXAlignment = Enum.TextXAlignment.Left
	local sub = Ui.label(frame, Ui.BODY, Theme.type.caption, Theme.color.inkDim)
	sub.Size = UDim2.new(1, -52, 0, 16)
	sub.Position = UDim2.fromOffset(42, 32)
	sub.TextXAlignment = Enum.TextXAlignment.Left
	sub.Text = Strings.lanternSub
	local token = 0

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local push = remotes:WaitForChild(Net.Pushes.ServerAnnouncement) :: RemoteEvent
	push.OnClientEvent:Connect(function(kind: any, payload: any)
		if kind ~= "LanternNight" then
			return
		end
		local info = ShopMath.lantern(payload)
		if not info or not info.boosted then
			return
		end
		label.Text = Strings.format(Strings.lanternTitle, { name = info.name })
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
