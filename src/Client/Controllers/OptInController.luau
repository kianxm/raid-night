--!strict
--[[
	OptInController (owner: ui agent): the experience-notification opt-in prompt. The server
	decides when (PromptNotificationOptIn push, no payload); the client only shows Roblox's own
	prompt and reports what happened (ReportOptInResult { shown, accepted }, fired once per
	push). Inert until the Net entries exist (notifications' P2.7c), and never shown during
	onboarding because the server never sends it then.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Net")) :: any

local Client = script.Parent.Parent
local Strings = require(Client:WaitForChild("Hud"):WaitForChild("Strings"))
local Theme = require(Client:WaitForChild("Ui"):WaitForChild("Theme"))
local LogKit = require(Client:WaitForChild("Ui"):WaitForChild("LogKit"))
local Ui = require(Client:WaitForChild("Raid"):WaitForChild("Ui"))

local OptInController = {}

-- The card shown before Roblox's own prompt (D-071 OptIn). Returns the card and its two buttons.
local function buildCard(): (Frame, TextButton, TextButton)
	local gui = Ui.screenGui("OptIn", 8, Players.LocalPlayer:WaitForChild("PlayerGui"))
	local card = LogKit.popup(gui, "OptInCard", Theme.color.glow, UDim2.fromScale(0.92, 0.92), Vector2.new(520, 340))
	local title = Theme.text(card, Theme.type.title + 2, Theme.color.ink)
	title.Text = Strings.optTitle
	title.TextWrapped = true
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Size = UDim2.new(1, -32, 0, 66)
	title.Position = UDim2.fromOffset(16, 18)
	local body = Theme.bodyText(card, Theme.type.body, Theme.color.inkDim)
	body.Text = Strings.optBody
	body.TextWrapped = true
	body.TextXAlignment = Enum.TextXAlignment.Left
	body.TextYAlignment = Enum.TextYAlignment.Top
	body.Size = UDim2.new(1, -32, 0, 40)
	body.Position = UDim2.fromOffset(16, 90)
	local well = LogKit.well(card, "Example")
	well.Size = UDim2.new(1, -32, 0, 56)
	well.Position = UDim2.fromOffset(16, 136)
	local orb = Theme.orb(well, Theme.size.orb)
	orb.Position = UDim2.fromOffset(10, 14)
	local who = Theme.bodyText(well, Theme.type.caption, Theme.color.inkMute)
	who.Text = Strings.optExample
	who.TextXAlignment = Enum.TextXAlignment.Left
	who.Size = UDim2.new(1, -56, 0, 16)
	who.Position = UDim2.fromOffset(48, 6)
	local line = Theme.bodyText(well, Theme.type.label, Theme.color.ink)
	line.Text = Strings.optExampleBody
	line.TextXAlignment = Enum.TextXAlignment.Left
	line.Size = UDim2.new(1, -56, 0, 22)
	line.Position = UDim2.fromOffset(48, 26)
	local no = LogKit.ghost(card, "No", Strings.optNo, UDim2.new(0.3, 0, 0, Theme.size.tapMin + 8))
	no.AnchorPoint = Vector2.new(0, 1)
	no.Position = UDim2.new(0, 16, 1, -34)
	local yes = Ui.button(card, "Yes", Strings.optYes, Theme.color.glow, UDim2.new(0.7, -40, 0, Theme.size.tapMin + 8))
	yes.AnchorPoint = Vector2.new(1, 1)
	yes.Position = UDim2.new(1, -16, 1, -34)
	local hint = Theme.bodyText(card, Theme.type.caption, Theme.color.inkMute)
	hint.Text = Strings.optNext
	hint.Size = UDim2.new(1, -32, 0, 16)
	hint.Position = UDim2.new(0, 16, 1, -26)
	return card, yes, no
end

local function report(remote: RemoteEvent, shown: boolean, accepted: boolean)
	remote:FireServer({ shown = shown, accepted = accepted })
end

function OptInController.start()
	local pushName = Net.Pushes.PromptNotificationOptIn
	local reportName = Net.Requests.ReportOptInResult
	if type(pushName) ~= "string" or type(reportName) ~= "string" then
		return -- the server side has not landed yet
	end
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local push = remotes:WaitForChild(pushName) :: RemoteEvent
	local reporter = remotes:WaitForChild(reportName) :: RemoteEvent
	local service = game:GetService("ExperienceNotificationService")
	local busy = false
	local card, yes, no = buildCard()
	local function prompt()
		task.spawn(function()
			local okCan, can = pcall(function()
				return service:CanPromptOptInAsync()
			end)
			if not okCan or can ~= true then
				report(reporter, false, false)
				busy = false
				return
			end
			local okPrompt, result = pcall(function()
				return (service :: any):PromptOptIn()
			end)
			report(reporter, okPrompt, okPrompt and result == true)
			busy = false
		end)
	end
	no.Activated:Connect(function()
		card.Visible = false
		report(reporter, false, false)
		busy = false
	end)
	yes.Activated:Connect(function()
		card.Visible = false
		prompt()
	end)
	push.OnClientEvent:Connect(function()
		if busy then
			return
		end
		busy = true
		card.Visible = true
		Ui.pop(card)
	end)
end

return OptInController
