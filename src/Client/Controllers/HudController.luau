--!strict
--[[
	HudController (owner: ui agent)

	Phone-first HUD: Glow counter, den storage bar (locally predicted between server pushes),
	carried-critter indicator, and a right-edge column of thumb buttons (Collect, Buy Egg,
	Lockdown). It only renders and requests; the server decides every outcome.

	Layout (landscape phone): top-left Glow + storage (under Roblox's top bar), top-center carried
	critter, right column sits above the default jump button. Left/bottom-left stays clear for the
	thumbstick.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net")) :: any
local Economy = require(Shared:WaitForChild("Economy")) :: any
local CritterCatalog = require(Shared:WaitForChild("CritterCatalog")) :: any

local Hud = script.Parent.Parent:WaitForChild("Hud")
local Strings = require(Hud:WaitForChild("Strings"))
local HudMath = require(Hud:WaitForChild("HudMath"))
local DenController = require(script.Parent:WaitForChild("DenController")) :: any

-- PENDING CONTRACT: "Lockdown" is not in Net.Requests yet. Replace this constant with
-- Net.Requests.Lockdown once the contract is approved.
local LOCKDOWN_REMOTE = "Lockdown"

local COLOR = {
	panel = Color3.fromHex("1B1F3B"),
	outline = Color3.fromHex("0B1026"),
	text = Color3.fromHex("FFFFFF"),
	glow = Color3.fromHex("78E6FF"),
	barBack = Color3.fromHex("2E3552"),
	collect = Color3.fromHex("5BE38A"),
	buy = Color3.fromHex("FFC857"),
	lock = Color3.fromHex("9B7BFF"),
	disabled = Color3.fromHex("4A5070"),
}
local DISPLAY_FONT = Enum.Font.FredokaOne
local BODY_FONT = Enum.Font.GothamBold

local HudController = {}

local player = Players.LocalPlayer
local remotes: Instance

local function round(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
end

local function outline(parent: Instance, thickness: number)
	local s = Instance.new("UIStroke")
	s.Color = COLOR.outline
	s.Thickness = thickness
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
end

local function label(parent: Instance, font: Enum.Font, maxSize: number): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = font
	l.TextColor3 = COLOR.text
	l.TextScaled = true
	l.Size = UDim2.fromScale(1, 1)
	local limit = Instance.new("UITextSizeConstraint")
	limit.MaxTextSize = maxSize
	limit.MinTextSize = 12
	limit.Parent = l
	l.Parent = parent
	return l
end

local function panel(parent: Instance, name: string, size: UDim2, position: UDim2): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.Size = size
	f.Position = position
	f.BackgroundColor3 = COLOR.panel
	f.BorderSizePixel = 0
	round(f, 14)
	outline(f, 3)
	f.Parent = parent
	return f
end

-- One chunky button with a big title and a small price/sub line. Min height 56 px for thumbs.
local function makeButton(parent: Instance, name: string, order: number, color: Color3)
	local b = Instance.new("TextButton")
	b.Name = name
	b.LayoutOrder = order
	b.Size = UDim2.new(1, 0, 0, 58)
	b.BackgroundColor3 = color
	b.AutoButtonColor = true
	b.Text = ""
	round(b, 14)
	outline(b, 3)
	b.Parent = parent
	local title = label(b, DISPLAY_FONT, 22)
	title.Name = "Title"
	title.Size = UDim2.new(1, -12, 0.55, 0)
	title.Position = UDim2.fromOffset(6, 3)
	title.TextColor3 = COLOR.outline
	local sub = label(b, BODY_FONT, 16)
	sub.Name = "Sub"
	sub.Size = UDim2.new(1, -12, 0.35, 0)
	sub.Position = UDim2.new(0, 6, 0.6, 0)
	sub.TextColor3 = COLOR.outline
	return b, title, sub
end

local function setEnabled(b: TextButton, enabled: boolean, color: Color3)
	b.BackgroundColor3 = if enabled then color else COLOR.disabled
	b.Active = enabled
end

local function build(): { [string]: any }
	local gui = Instance.new("ScreenGui")
	gui.Name = "Hud"
	gui.ResetOnSpawn = false
	-- ScreenInsets supersedes IgnoreGuiInset. CoreUISafeInsets keeps content clear of the
	-- Roblox top bar and also covers device notches and rounded corners.
	gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	gui.DisplayOrder = 1
	gui.Parent = player:WaitForChild("PlayerGui")

	-- Top-left: Glow + storage.
	local top = panel(gui, "GlowPanel", UDim2.new(0.3, 0, 0, 74), UDim2.fromOffset(10, 8))
	local sizeLimit = Instance.new("UISizeConstraint")
	sizeLimit.MinSize = Vector2.new(170, 74)
	sizeLimit.MaxSize = Vector2.new(260, 74)
	sizeLimit.Parent = top
	local glowText = label(top, DISPLAY_FONT, 30)
	glowText.Size = UDim2.new(1, -16, 0, 36)
	glowText.Position = UDim2.fromOffset(8, 4)
	glowText.TextColor3 = COLOR.glow
	glowText.TextXAlignment = Enum.TextXAlignment.Left

	local barBack = Instance.new("Frame")
	barBack.Name = "StorageBar"
	barBack.Size = UDim2.new(1, -16, 0, 22)
	barBack.Position = UDim2.fromOffset(8, 44)
	barBack.BackgroundColor3 = COLOR.barBack
	barBack.BorderSizePixel = 0
	round(barBack, 8)
	outline(barBack, 2)
	barBack.Parent = top
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = COLOR.collect
	fill.BorderSizePixel = 0
	round(fill, 8)
	fill.Parent = barBack
	local barText = label(barBack, BODY_FONT, 16)
	barText.ZIndex = 2

	-- Top-center: carried critter (hidden unless carrying).
	local carry = panel(gui, "Carrying", UDim2.fromOffset(220, 40), UDim2.new(0.5, -110, 0, 8))
	carry.Visible = false
	local carryText = label(carry, DISPLAY_FONT, 22)
	carryText.Size = UDim2.new(1, -16, 1, 0)
	carryText.Position = UDim2.fromOffset(8, 0)

	-- Right column, above the default jump button (bottom ~150 px stays clear).
	local column = Instance.new("Frame")
	column.Name = "Actions"
	column.AnchorPoint = Vector2.new(1, 1)
	column.Position = UDim2.new(1, -12, 1, -150)
	column.Size = UDim2.fromOffset(130, 0)
	column.AutomaticSize = Enum.AutomaticSize.Y
	column.BackgroundTransparency = 1
	column.Parent = gui
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.VerticalAlignment = Enum.VerticalAlignment.Bottom
	list.Padding = UDim.new(0, 8)
	list.Parent = column

	local collect, collectTitle, collectSub = makeButton(column, "Collect", 3, COLOR.collect)
	local buy, buyTitle, buySub = makeButton(column, "BuyEgg", 2, COLOR.buy)
	local lock, lockTitle, lockSub = makeButton(column, "Lockdown", 1, COLOR.lock)

	return {
		glowText = glowText,
		fill = fill,
		barText = barText,
		carry = carry,
		carryText = carryText,
		collect = collect,
		collectTitle = collectTitle,
		collectSub = collectSub,
		buy = buy,
		buyTitle = buyTitle,
		buySub = buySub,
		lock = lock,
		lockTitle = lockTitle,
		lockSub = lockSub,
	}
end

-- Lockdown state from the den Model attributes (server time). Pending contract.
local function lockdownStatus(): (string, number)
	local plot = player:GetAttribute("Plot")
	local world = workspace:FindFirstChild("World")
	local dens = world and world:FindFirstChild("Dens")
	local den = dens and plot ~= nil and dens:FindFirstChild("Den" .. tostring(plot))
	if not den then
		return "ready", 0
	end
	local now = workspace:GetServerTimeNow()
	local activeUntil = den:GetAttribute("LockdownUntil")
	local readyAt = den:GetAttribute("LockdownReadyAt")
	if type(activeUntil) == "number" and activeUntil > now then
		return "active", activeUntil - now
	end
	if type(readyAt) == "number" and readyAt > now then
		return "cooldown", readyAt - now
	end
	return "ready", 0
end

local function request(name: string, busy: { [string]: boolean })
	local remote = remotes:FindFirstChild(name)
	if not remote or not remote:IsA("RemoteFunction") or busy[name] then
		return
	end
	busy[name] = true
	task.spawn(function()
		pcall(function()
			remote:InvokeServer()
		end)
		busy[name] = false
	end)
end

function HudController.start()
	remotes = ReplicatedStorage:WaitForChild("Remotes")
	local ui = build()
	local busy: { [string]: boolean } = {}

	ui.collect.Activated:Connect(function()
		request(Net.Requests.Collect, busy)
	end)
	ui.buy.Activated:Connect(function()
		request(Net.Requests.BuyEgg, busy)
	end)
	ui.lock.Activated:Connect(function()
		request(LOCKDOWN_REMOTE, busy)
	end)

	local function render()
		local state, receivedAt = DenController.getState()
		if state then
			local elapsed = os.clock() - receivedAt
			local stored = HudMath.predictStored(state.stored, state.storageCap, state.ratePerSecond, elapsed)
			local price = Economy.eggPrice(state.denLevel)
			local free = #state.critters == 0 and math.floor(state.glow + stored) < price

			ui.glowText.Text = HudMath.abbreviate(state.glow) .. " " .. Strings.glow
			local share = if state.storageCap > 0 then math.clamp(stored / state.storageCap, 0, 1) else 0
			ui.fill.Size = UDim2.fromScale(share, 1)
			ui.barText.Text = if share >= 1
				then Strings.storageFull
				else HudMath.abbreviate(stored) .. " / " .. HudMath.abbreviate(state.storageCap)

			ui.collectTitle.Text = Strings.collect
			ui.collectSub.Text = "+" .. HudMath.abbreviate(stored)
			setEnabled(ui.collect, stored >= 1, COLOR.collect)

			ui.buyTitle.Text = Strings.buyEgg
			ui.buySub.Text = if free then Strings.free else HudMath.abbreviate(price) .. " " .. Strings.glow
			setEnabled(ui.buy, free or state.glow >= price, COLOR.buy)
		end

		-- Carried critter (PENDING CONTRACT: absent attribute = not carrying).
		local speciesId = player:GetAttribute("CarryingSpecies")
		local species = if type(speciesId) == "string" and speciesId ~= "" then CritterCatalog.get(speciesId) else nil
		ui.carry.Visible = species ~= nil
		if species then
			ui.carryText.Text = Strings.format(Strings.carrying, { name = species.name })
		end

		-- Lockdown button.
		local available = remotes:FindFirstChild(LOCKDOWN_REMOTE) ~= nil
		local status, left = lockdownStatus()
		ui.lockTitle.Text = Strings.lockdown
		if not available then
			ui.lockSub.Text = ""
			setEnabled(ui.lock, false, COLOR.lock)
		elseif status == "active" then
			ui.lockSub.Text = Strings.format(Strings.lockdownActive, { time = HudMath.clock(left) })
			setEnabled(ui.lock, false, COLOR.lock)
		elseif status == "cooldown" then
			ui.lockSub.Text = Strings.format(Strings.lockdownCooldown, { time = HudMath.clock(left) })
			setEnabled(ui.lock, false, COLOR.lock)
		else
			ui.lockSub.Text = ""
			setEnabled(ui.lock, true, COLOR.lock)
		end
	end

	-- Display only; ~10 Hz is plenty for a bar and countdowns.
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc >= 0.1 then
			acc = 0
			render()
		end
	end)
	DenController.onChanged(function()
		render()
	end)
end

return HudController
