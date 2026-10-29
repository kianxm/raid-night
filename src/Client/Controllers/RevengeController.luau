--!strict
--[[
	RevengeController (owner: ui agent)

	The Revenge button flow, shared by the raid log and the Raid Portal (they call `begin`).
	  - Raider offline or unknown: StartRaid(targetUserId, revengeRaidId), the async revenge raid.
	  - Raider online (RaidTarget.raiderOnline): a small choice card, "Join their server"
	    (JoinRevengeServer) or "Raid their den" (the async raid). Join progress and failure
	    reasons come from RevengeJoinStatus. On a retryable failure the async raid is offered, never
	    started on its own.
	Display only: the server decides every outcome. A refusal is a short toast, never an error.

	Started FIRST in Main so the RevengeJoinStatus push is heard even when it lands right after
	the teleport arrives (state "Arrived" shows up in the new server).
]]

local Players = game:GetService("Players")

local Hud = script.Parent.Parent:WaitForChild("Hud")
local Raid = script.Parent.Parent:WaitForChild("Raid")
local Strings = require(Hud:WaitForChild("Strings"))
local RaidApi = require(Raid:WaitForChild("RaidApi"))
local RaidMath = require(Raid:WaitForChild("RaidMath"))
local Toast = require(Raid:WaitForChild("Toast"))
local Ui = require(Raid:WaitForChild("Ui"))
local Theme = require(script.Parent.Parent:WaitForChild("Ui"):WaitForChild("Theme"))
local LogKit = require(script.Parent.Parent:WaitForChild("Ui"):WaitForChild("LogKit"))

local COLOR = {
	glow = Theme.color.glow,
	revenge = Theme.color.revenge,
	gold = Theme.color.gold,
	ink = Theme.color.ink,
	inkDim = Theme.color.inkDim,
	inkMute = Theme.color.inkMute,
	line = Theme.color.line,
}
local SLOW_SECONDS = 20 -- a real wait: after this the teleport has not happened, so say so

local RevengeController = {}

type Pending = { userId: number, raidId: string, name: string }

local card: Frame
local titleLabel: TextLabel
local avatarLabel: TextLabel
local closedCard: Frame
local closedTitle: TextLabel
local closedBody: TextLabel
local closedAvatar: TextLabel
local statusLabel: TextLabel
local joinButton: TextButton
local denButton: TextButton
local pending: Pending? = nil
local busy = false
local joinToken = 0

local function setStatus(text: string)
	statusLabel.Text = text
	statusLabel.Visible = text ~= ""
end

local function close()
	card.Visible = false
	pending = nil
	busy = false
	joinToken += 1
end

-- The async revenge raid. Used directly (offline raider) and from the card.
local function startAsync(userId: number, raidId: string, fromCard: boolean)
	if busy then
		return
	end
	busy = true
	task.spawn(function()
		local start = RaidApi.startRaid(userId, raidId)
		busy = false
		if start then
			close()
		elseif fromCard then
			setStatus(Strings.portalRefused)
		else
			Toast.show(Strings.portalRefused)
		end
	end)
end

local function applyStatus(status: any)
	local p = pending
	if status.state == "Arrived" then
		local name = if type(status.targetUserId) == "number" then RaidApi.nameFor(status.targetUserId) else nil
		close()
		if name then
			Toast.show(Strings.format(Strings.revengeArrived, { name = name }))
		end
		return
	end
	if not p or status.revengeRaidId ~= p.raidId then
		if status.state == "Failed" then
			Toast.show((Strings :: any)[RaidMath.failKey(status.reason)])
		end
		return
	end
	if status.state == "Teleporting" then
		busy = true
		joinToken += 1
		local mine = joinToken
		joinButton.Active = false
		Ui.setButton(joinButton, Strings.revengeJoinLive, COLOR.glow, false)
		setStatus(Strings.format(Strings.revengeJoining, { name = p.name }))
		task.delay(SLOW_SECONDS, function()
			if mine == joinToken and pending == p then
				busy = false
				setStatus(Strings.revengeSlow)
				Ui.setButton(denButton, Strings.revengeDenInstead, COLOR.revenge, true)
			end
		end)
	else -- Failed
		busy = false
		joinToken += 1
		Ui.setButton(joinButton, Strings.revengeJoinLive, COLOR.glow, false)
		setStatus((Strings :: any)[RaidMath.failKey(status.reason)])
		if RaidMath.fallbackOffered(status.reason) then
			Ui.setButton(denButton, Strings.revengeDenInstead, COLOR.revenge, true)
		else
			Ui.setButton(denButton, Strings.revengeRaidNow, COLOR.revenge, false)
		end
	end
end

-- Revenge pressed. `raiderOnline` comes from RaidTarget (nil when the caller does not know).
function RevengeController.begin(userId: number, revengeRaidId: string, raiderOnline: boolean?)
	if busy then
		return
	end
	if raiderOnline ~= true then
		startAsync(userId, revengeRaidId, false)
		return
	end
	local name = RaidApi.nameFor(userId)
	pending = { userId = userId, raidId = revengeRaidId, name = name }
	titleLabel.Text = Strings.format(Strings.revengeTitle, { name = name })
	setStatus("")
	Ui.setButton(joinButton, Strings.revengeJoinLive, COLOR.glow, true)
	Ui.setButton(denButton, Strings.revengeRaidNow, COLOR.revenge, true)
	avatarLabel.Text = string.upper(string.sub(name, 1, 2))
	card.Visible = true
	Ui.pop(card)
end

function RevengeController.showClosed(userId: number)
	local name = RaidApi.nameFor(userId)
	closedTitle.Text = Strings.revengeClosedTitle
	closedBody.Text = Strings.format(Strings.revengeClosedBody, { name = name })
	closedAvatar.Text = string.upper(string.sub(name, 1, 2))
	closedCard.Visible = true
	Ui.pop(closedCard)
end

local function buildChoice(gui: ScreenGui)
	card = LogKit.popup(gui, "RevengeCard", COLOR.revenge, UDim2.fromScale(0.92, 0.92), Vector2.new(620, 330))

	local face = LogKit.avatar(card, "??", COLOR.revenge, 52)
	face.Position = UDim2.fromOffset(16, 18)
	avatarLabel = face:FindFirstChildOfClass("TextLabel") :: TextLabel

	titleLabel = Theme.text(card, Theme.type.title, COLOR.revenge)
	titleLabel.Size = UDim2.new(1, -150, 0, 30)
	titleLabel.Position = UDim2.fromOffset(78, 16)
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.TextTruncate = Enum.TextTruncate.AtEnd

	local online = Theme.chip(card, "Online", Strings.revengeOnline, Theme.color.panelSunken, Theme.color.ink)
	online.Size = UDim2.fromOffset(110, 24)
	online.Position = UDim2.fromOffset(78, 50)
	local dot = Instance.new("Frame")
	dot.Size = UDim2.fromOffset(8, 8)
	dot.Position = UDim2.new(0, 6, 0.5, -4)
	dot.BackgroundColor3 = Theme.color.go
	dot.BorderSizePixel = 0
	Theme.corner(dot, Theme.radius.full)
	dot.Parent = online
	local onlineText = online:FindFirstChild("Text") :: TextLabel
	onlineText.Position = UDim2.fromOffset(20, 2)
	onlineText.Size = UDim2.new(1, -26, 1, -4)

	local x = LogKit.closeX(card)
	x.Activated:Connect(close)

	-- Two option cards side by side: Raid their den (primary) and Join their server.
	local function option(name: string, x0: number, title: string, body: string, note: string): Frame
		local f = LogKit.well(card, name)
		f.Size = UDim2.new(0.5, -22, 0, 150)
		f.Position = UDim2.new(x0, if x0 == 0 then 16 else 6, 0, 84)
		local t = Theme.text(f, Theme.type.buttonText - 2, COLOR.ink)
		t.Text = title
		t.TextXAlignment = Enum.TextXAlignment.Left
		t.Size = UDim2.new(1, -20, 0, 26)
		t.Position = UDim2.fromOffset(10, 8)
		local b = Theme.bodyText(f, Theme.type.label, COLOR.inkDim)
		b.Text = body
		b.TextWrapped = true
		b.TextXAlignment = Enum.TextXAlignment.Left
		b.TextYAlignment = Enum.TextYAlignment.Top
		b.Size = UDim2.new(1, -20, 0, 38)
		b.Position = UDim2.fromOffset(10, 36)
		local n = Theme.bodyText(f, Theme.type.caption, COLOR.inkMute)
		n.Text = note
		n.TextXAlignment = Enum.TextXAlignment.Left
		n.Size = UDim2.new(1, -20, 0, 16)
		n.Position = UDim2.fromOffset(10, 76)
		return f
	end
	local denCard = option("DenOption", 0, Strings.revengeDen, Strings.revengeDenBody, "")
	denButton =
		Ui.button(denCard, "Den", Strings.revengeRaidNow, COLOR.revenge, UDim2.new(1, -20, 0, Theme.size.tapMin))
	denButton.AnchorPoint = Vector2.new(0, 1)
	denButton.Position = UDim2.new(0, 10, 1, -8)
	denButton.Activated:Connect(function()
		local p = pending
		if p and denButton.Active then
			startAsync(p.userId, p.raidId, true)
		end
	end)

	local joinCard = option("JoinOption", 0.5, Strings.revengeJoin, Strings.revengeJoinBody, Strings.revengeJoinNote)
	joinButton =
		Ui.button(joinCard, "Join", Strings.revengeJoinLive, COLOR.glow, UDim2.new(1, -20, 0, Theme.size.tapMin))
	joinButton.AnchorPoint = Vector2.new(0, 1)
	joinButton.Position = UDim2.new(0, 10, 1, -8)
	joinButton.Activated:Connect(function()
		local p = pending
		if not p or busy or not joinButton.Active then
			return
		end
		busy = true
		setStatus(Strings.format(Strings.revengeJoining, { name = p.name }))
		task.spawn(function()
			local status = RaidApi.joinRevengeServer(p.raidId)
			if status == nil then
				applyStatus({ state = "Failed", revengeRaidId = p.raidId, reason = "TeleportFailed" })
			elseif status.state == "Teleporting" then
				-- applyStatus already ran through the revengeStatus event; keep waiting for the push.
				busy = true
			end
		end)
	end)

	statusLabel = Theme.bodyText(card, Theme.type.body, COLOR.gold)
	statusLabel.Size = UDim2.new(1, -32, 0, 20)
	statusLabel.Position = UDim2.new(0, 16, 1, -52)
	statusLabel.Visible = false

	local noBuy = Theme.bodyText(card, Theme.type.caption, COLOR.inkMute)
	noBuy.Text = Strings.revengeNoBuy
	noBuy.TextXAlignment = Enum.TextXAlignment.Left
	noBuy.Size = UDim2.new(1, -32, 0, 18)
	noBuy.Position = UDim2.new(0, 16, 1, -28)
end

local function buildClosed(gui: ScreenGui)
	closedCard = LogKit.popup(gui, "RevengeClosed", COLOR.glow, UDim2.fromScale(0.92, 0.92), Vector2.new(480, 330))
	local face = LogKit.avatar(closedCard, "??", COLOR.line, 52)
	face.Position = UDim2.fromOffset(16, 18)
	closedAvatar = face:FindFirstChildOfClass("TextLabel") :: TextLabel

	closedTitle = Theme.text(closedCard, Theme.type.title, COLOR.ink)
	closedTitle.Size = UDim2.new(1, -150, 0, 56)
	closedTitle.Position = UDim2.fromOffset(78, 18)
	closedTitle.TextXAlignment = Enum.TextXAlignment.Left
	closedTitle.TextWrapped = true

	local x = LogKit.closeX(closedCard)
	x.Activated:Connect(function()
		closedCard.Visible = false
	end)

	closedBody = Theme.bodyText(closedCard, Theme.type.body, COLOR.inkDim)
	closedBody.TextWrapped = true
	closedBody.TextXAlignment = Enum.TextXAlignment.Left
	closedBody.TextYAlignment = Enum.TextYAlignment.Top
	closedBody.Size = UDim2.new(1, -32, 0, 40)
	closedBody.Position = UDim2.fromOffset(16, 88)

	local well = LogKit.well(closedCard, "Note")
	well.Size = UDim2.new(1, -32, 0, 40)
	well.Position = UDim2.fromOffset(16, 136)
	local note = Theme.bodyText(well, Theme.type.label, COLOR.inkMute)
	note.Text = Strings.revengeClosedNote
	note.Size = UDim2.new(1, -20, 1, -8)
	note.Position = UDim2.fromOffset(10, 4)
	note.TextXAlignment = Enum.TextXAlignment.Left

	local done = Ui.button(closedCard, "Done", Strings.close, COLOR.glow, UDim2.new(1, -32, 0, Theme.size.tapMin + 8))
	done.AnchorPoint = Vector2.new(0, 1)
	done.Position = UDim2.new(0, 16, 1, -16)
	done.Activated:Connect(function()
		closedCard.Visible = false
	end)
end

function RevengeController.start()
	RaidApi.start()
	local gui = Ui.screenGui("Revenge", 8, Players.LocalPlayer:WaitForChild("PlayerGui"))
	buildChoice(gui)
	buildClosed(gui)

	RaidApi.revengeStatus:Connect(applyStatus)
	RaidApi.raidStarted:Connect(close)
end

return RevengeController
