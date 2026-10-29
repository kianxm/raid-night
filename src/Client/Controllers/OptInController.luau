--!strict
--[[
	OptInController (owner: ui agent): the experience-notification opt-in prompt. The server
	decides when (PromptNotificationOptIn push, no payload); the client only shows Roblox's own
	prompt and reports what happened (ReportOptInResult { shown, accepted }, fired once per
	push). Inert until the Net entries exist (notifications' P2.7c), and never shown during
	onboarding because the server never sends it then.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Net")) :: any

local OptInController = {}

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
	push.OnClientEvent:Connect(function()
		if busy then
			return
		end
		busy = true
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
	end)
end

return OptInController
