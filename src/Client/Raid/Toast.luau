--!strict
--[[
	Toast (owner: ui agent): one short message for the raid screens (refusals, revenge status).
	Its own ScreenGui above the other raid screens, top-center. Display only.
]]

local Players = game:GetService("Players")

local Ui = require(script.Parent:WaitForChild("Ui"))

local SECONDS = 4

local Toast = {}

local holder: Frame? = nil
local text: TextLabel? = nil
local token = 0

local function build()
	local gui = Ui.screenGui("RaidToast", 9, Players.LocalPlayer:WaitForChild("PlayerGui"))
	local frame = Ui.panel(gui, "Toast", UDim2.fromOffset(300, 44), UDim2.new(0.5, 0, 0, 10))
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.Visible = false
	local label = Ui.label(frame, Ui.DISPLAY, 20, Ui.COLOR.gold)
	label.Size = UDim2.new(1, -16, 1, -8)
	label.Position = UDim2.fromOffset(8, 4)
	holder, text = frame, label
end

function Toast.show(message: string)
	if not holder then
		build()
	end
	local frame, label = holder :: Frame, text :: TextLabel
	token += 1
	local mine = token
	label.Text = message
	frame.Visible = true
	task.delay(SECONDS, function()
		if mine == token then
			frame.Visible = false
		end
	end)
end

return Toast
