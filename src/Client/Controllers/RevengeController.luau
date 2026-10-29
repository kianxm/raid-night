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

local COLOR = Ui.COLOR
local SLOW_SECONDS = 20 -- a real wait: after this the teleport has not happened, so say so

local RevengeController = {}

type Pending = { userId: number, raidId: string, name: string }

local card: Frame
local titleLabel: TextLabel
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
		Ui.setButton(joinButton, Strings.revengeJoin, COLOR.go, false)
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
		Ui.setButton(joinButton, Strings.revengeJoin, COLOR.go, false)
		setStatus((Strings :: any)[RaidMath.failKey(status.reason)])
		if RaidMath.fallbackOffered(status.reason) then
			Ui.setButton(denButton, Strings.revengeDenInstead, COLOR.revenge, true)
		else
			Ui.setButton(denButton, Strings.revengeDen, COLOR.revenge, false)
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
	Ui.setButton(joinButton, Strings.revengeJoin, COLOR.go, true)
	Ui.setButton(denButton, Strings.revengeDen, COLOR.revenge, true)
	card.Visible = true
end

function RevengeController.start()
	RaidApi.start()
	local gui = Ui.screenGui("Revenge", 8, Players.LocalPlayer:WaitForChild("PlayerGui"))

	card = Ui.panel(gui, "RevengeCard", UDim2.fromOffset(320, 200), UDim2.fromScale(0.5, 0.5))
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Visible = false
	local stroke = card:FindFirstChildOfClass("UIStroke") :: UIStroke
	stroke.Color = COLOR.revenge

	titleLabel = Ui.label(card, Ui.DISPLAY, 26, COLOR.revenge)
	titleLabel.Size = UDim2.new(1, -64, 0, 36)
	titleLabel.Position = UDim2.fromOffset(12, 8)
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.TextTruncate = Enum.TextTruncate.AtEnd

	local x = Ui.button(card, "Close", "X", COLOR.gold, UDim2.fromOffset(44, 36))
	x.AnchorPoint = Vector2.new(1, 0)
	x.Position = UDim2.new(1, -8, 0, 8)
	x.Activated:Connect(close)

	joinButton = Ui.button(card, "Join", Strings.revengeJoin, COLOR.go, UDim2.new(1, -24, 0, 50))
	joinButton.Position = UDim2.fromOffset(12, 54)
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

	denButton = Ui.button(card, "Den", Strings.revengeDen, COLOR.revenge, UDim2.new(1, -24, 0, 50))
	denButton.Position = UDim2.fromOffset(12, 112)
	denButton.Activated:Connect(function()
		local p = pending
		if p and denButton.Active then
			startAsync(p.userId, p.raidId, true)
		end
	end)

	statusLabel = Ui.label(card, Ui.BODY, 16, COLOR.gold)
	statusLabel.Size = UDim2.new(1, -24, 0, 24)
	statusLabel.Position = UDim2.new(0, 12, 1, -32)
	statusLabel.Visible = false

	RaidApi.revengeStatus:Connect(applyStatus)
	RaidApi.raidStarted:Connect(close)
end

return RevengeController
