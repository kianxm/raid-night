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
local Config = require(Shared:WaitForChild("Config")) :: any
local CritterCatalog = require(Shared:WaitForChild("CritterCatalog")) :: any

local Hud = script.Parent.Parent:WaitForChild("Hud")
local Ui = require(script.Parent.Parent:WaitForChild("Raid"):WaitForChild("Ui"))
local Strings = require(Hud:WaitForChild("Strings"))
local HudMath = require(Hud:WaitForChild("HudMath"))
local DenController = require(script.Parent:WaitForChild("DenController")) :: any

local LOCKDOWN_REMOTE = Net.Requests.Lockdown
local TOAST_SECONDS = 4

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

local round, outline, label, panel = Ui.round, Ui.outline, Ui.label, Ui.panel

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

-- The odds of the next bought egg, from Economy's helpers only (D-028). `rescue` comes from the
-- same HudMath rule as the "Free" label. Returns percent labels aligned with `tiers`.
local function nextOdds(rescue: boolean): ({ { tier: string, chance: number } }, { string })
	local tiers = if rescue then Economy.rescueEggTierOdds() else Economy.eggTierOdds(Config.Economy.eggMaxTier)
	local chances = {}
	for _, t in tiers do
		table.insert(chances, t.chance)
	end
	return tiers, HudMath.percentLabels(chances)
end

local function oddsPanelText(tiers: { { tier: string, chance: number } }, labels: { string }, rescue: boolean): string
	local lines = { if rescue then Strings.oddsRescue else Strings.oddsEqual }
	for i, t in tiers do
		table.insert(lines, "")
		table.insert(lines, `<b>{t.tier}  {labels[i]}</b>`)
		local species = Economy.speciesOdds(t.tier)
		if #species > 0 then
			local names = {}
			for _, sp in species do
				local info = CritterCatalog.get(sp.speciesId)
				table.insert(names, if info then info.name else "?")
			end
			local each = HudMath.eachLabel(#species)
			table.insert(lines, table.concat(names, ", "))
			table.insert(lines, Strings.format(Strings.oddsEach, { pct = each }))
		end
	end
	return table.concat(lines, "\n")
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
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
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

	-- Short toast under the carried pill (raid alerts, Lockdown result).
	local toast = panel(gui, "Toast", UDim2.fromOffset(280, 40), UDim2.new(0.5, -140, 0, 56))
	toast.Visible = false
	toast.ZIndex = 5
	local toastText = label(toast, DISPLAY_FONT, 20)
	toastText.Size = UDim2.new(1, -16, 1, 0)
	toastText.Position = UDim2.fromOffset(8, 0)
	toastText.ZIndex = 6
	local toastSub = label(toast, BODY_FONT, 14)
	toastSub.Name = "Sub"
	toastSub.Size = UDim2.new(1, -16, 0, 22)
	toastSub.Position = UDim2.fromOffset(8, 32)
	toastSub.ZIndex = 6
	toastSub.Visible = false

	-- Right column, above the default jump button (bottom ~150 px stays clear).
	local column = Instance.new("Frame")
	column.Name = "Actions"
	column.AnchorPoint = Vector2.new(1, 1)
	column.Position = UDim2.new(1, -12, 1, -HudMath.columnLayout(math.huge).reserve)
	column.Size = UDim2.fromOffset(130, 0)
	column.AutomaticSize = Enum.AutomaticSize.Y
	column.BackgroundTransparency = 1
	column.Parent = gui
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.VerticalAlignment = Enum.VerticalAlignment.Bottom
	list.Padding = UDim.new(0, 8)
	list.Parent = column

	-- Re-fit on size changes (#54): full layout on tall screens, compact on phone landscape.
	local function applyLayout()
		local layout = HudMath.columnLayout(gui.AbsoluteSize.Y)
		column.Position = UDim2.new(1, -12, 1, -layout.reserve)
		list.Padding = UDim.new(0, layout.gap)
		for _, child in column:GetChildren() do
			if child:IsA("TextButton") then
				if child.Name == "OddsChip" then
					if layout.compact then
						child.AutomaticSize = Enum.AutomaticSize.None
						child.Size = UDim2.new(1, 0, 0, layout.chip)
					else
						child.AutomaticSize = Enum.AutomaticSize.Y
						child.Size = UDim2.fromScale(1, 0)
					end
					local pad = child:FindFirstChildOfClass("UIPadding")
					if pad then
						local px = if layout.compact then 3 else 6
						pad.PaddingTop = UDim.new(0, px)
						pad.PaddingBottom = UDim.new(0, px)
					end
					child.TextSize = if layout.compact then 12 else 14
					child.TextTruncate = if layout.compact then Enum.TextTruncate.AtEnd else Enum.TextTruncate.None
				else
					child.Size = UDim2.new(1, 0, 0, layout.button)
				end
			end
		end
		return layout.compact
	end

	local collect, collectTitle, collectSub = makeButton(column, "Collect", 4, COLOR.collect)
	local buy, buyTitle, buySub = makeButton(column, "BuyEgg", 3, COLOR.buy)
	local lock, lockTitle, lockSub = makeButton(column, "Lockdown", 1, COLOR.lock)

	-- Always-visible compact tier odds right above Buy Egg (display only). Tapping it opens the
	-- species panel. Free to open; it never costs anything.
	local oddsChip = Instance.new("TextButton")
	oddsChip.Name = "OddsChip"
	oddsChip.LayoutOrder = 2
	oddsChip.Size = UDim2.fromScale(1, 0)
	oddsChip.AutomaticSize = Enum.AutomaticSize.Y
	oddsChip.BackgroundColor3 = COLOR.panel
	oddsChip.AutoButtonColor = true
	oddsChip.Font = BODY_FONT
	oddsChip.TextSize = 14
	oddsChip.TextColor3 = COLOR.text
	oddsChip.RichText = true
	oddsChip.TextWrapped = true
	oddsChip.Text = ""
	round(oddsChip, 12)
	outline(oddsChip, 2)
	local chipPad = Instance.new("UIPadding")
	chipPad.PaddingTop = UDim.new(0, 6)
	chipPad.PaddingBottom = UDim.new(0, 6)
	chipPad.PaddingLeft = UDim.new(0, 6)
	chipPad.PaddingRight = UDim.new(0, 6)
	chipPad.Parent = oddsChip
	oddsChip.Parent = column
	local compact = applyLayout()
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		compact = applyLayout()
	end)

	-- Odds panel: centered, scrolls, 48 px close button. Hidden until the chip is tapped.
	local oddsPanel = panel(gui, "OddsPanel", UDim2.new(0, 300, 0.8, 0), UDim2.fromScale(0.5, 0.5))
	oddsPanel.AnchorPoint = Vector2.new(0.5, 0.5)
	oddsPanel.Visible = false
	oddsPanel.ZIndex = 8
	local oddsTitle = label(oddsPanel, DISPLAY_FONT, 24)
	oddsTitle.Size = UDim2.new(1, -16, 0, 34)
	oddsTitle.Position = UDim2.fromOffset(8, 6)
	oddsTitle.Text = Strings.oddsTitle
	oddsTitle.ZIndex = 9
	local oddsScroll = Instance.new("ScrollingFrame")
	oddsScroll.BackgroundTransparency = 1
	oddsScroll.BorderSizePixel = 0
	oddsScroll.Size = UDim2.new(1, -16, 1, -108)
	oddsScroll.Position = UDim2.fromOffset(8, 44)
	oddsScroll.CanvasSize = UDim2.new()
	oddsScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	oddsScroll.ScrollBarThickness = 6
	oddsScroll.ZIndex = 9
	oddsScroll.Parent = oddsPanel
	local oddsBody = Instance.new("TextLabel")
	oddsBody.BackgroundTransparency = 1
	oddsBody.Size = UDim2.new(1, -8, 0, 0)
	oddsBody.AutomaticSize = Enum.AutomaticSize.Y
	oddsBody.Font = BODY_FONT
	oddsBody.TextSize = 16
	oddsBody.TextColor3 = COLOR.text
	oddsBody.TextXAlignment = Enum.TextXAlignment.Left
	oddsBody.TextYAlignment = Enum.TextYAlignment.Top
	oddsBody.TextWrapped = true
	oddsBody.RichText = true
	oddsBody.ZIndex = 9
	oddsBody.Parent = oddsScroll
	local oddsClose = Instance.new("TextButton")
	oddsClose.Name = "Close"
	oddsClose.AnchorPoint = Vector2.new(0.5, 1)
	oddsClose.Size = UDim2.new(1, -16, 0, 48)
	oddsClose.Position = UDim2.new(0.5, 0, 1, -8)
	oddsClose.BackgroundColor3 = COLOR.buy
	oddsClose.Font = DISPLAY_FONT
	oddsClose.TextSize = 22
	oddsClose.TextColor3 = COLOR.outline
	oddsClose.Text = Strings.oddsClose
	oddsClose.ZIndex = 9
	round(oddsClose, 14)
	outline(oddsClose, 3)
	oddsClose.Parent = oddsPanel

	return {
		glowText = glowText,
		fill = fill,
		barText = barText,
		carry = carry,
		carryText = carryText,
		toast = toast,
		toastText = toastText,
		toastSub = toastSub,
		collect = collect,
		collectTitle = collectTitle,
		collectSub = collectSub,
		buy = buy,
		buyTitle = buyTitle,
		buySub = buySub,
		lock = lock,
		lockTitle = lockTitle,
		lockSub = lockSub,
		oddsChip = oddsChip,
		isCompact = function()
			return compact
		end,
		oddsPanel = oddsPanel,
		oddsBody = oddsBody,
		oddsClose = oddsClose,
	}
end

-- My den Model: the one whose OwnerUserId is me. Display only.
local function findMyDen(): Instance?
	local world = workspace:FindFirstChild("World")
	local dens = world and world:FindFirstChild("Dens")
	if not dens then
		return nil
	end
	for _, den in dens:GetChildren() do
		if den:GetAttribute("OwnerUserId") == player.UserId then
			return den
		end
	end
	return nil
end

-- Lockdown state from my den's attributes (server time, D-011): active, then cooldown, then ready.
local function lockdownStatus(): (string, number)
	local den = findMyDen()
	if not den then
		return "ready", 0
	end
	local now = workspace:GetServerTimeNow()
	local activeUntil = den:GetAttribute("LockdownUntil")
	local readyAt = den:GetAttribute("LockdownReadyAt")
	if type(activeUntil) == "number" and now < activeUntil then
		return "active", activeUntil - now
	end
	if type(readyAt) == "number" and now < readyAt then
		return "cooldown", readyAt - now
	end
	return "ready", 0
end

-- Calls `fn(instance)` once the named child of Remotes exists (now or later). The client never
-- creates remotes; the server owns them.
local function whenRemote(name: string, fn: (Instance) -> ())
	local found = remotes:FindFirstChild(name)
	if found then
		fn(found)
		return
	end
	local conn: RBXScriptConnection
	conn = remotes.ChildAdded:Connect(function(child)
		if child.Name == name then
			conn:Disconnect()
			fn(child)
		end
	end)
end

local function request(name: string, busy: { [string]: boolean }, onResult: ((any) -> ())?)
	local remote = remotes:FindFirstChild(name)
	if not remote or not remote:IsA("RemoteFunction") or busy[name] then
		return
	end
	busy[name] = true
	task.spawn(function()
		local ok, result = pcall(function()
			return remote:InvokeServer()
		end)
		busy[name] = false
		if ok and onResult then
			onResult(result)
		end
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
	ui.oddsChip.Activated:Connect(function()
		ui.oddsPanel.Visible = not ui.oddsPanel.Visible
	end)
	ui.oddsClose.Activated:Connect(function()
		ui.oddsPanel.Visible = false
	end)
	local toastToken = 0
	local function showToast(text: string, sub: string?)
		toastToken += 1
		local token = toastToken
		ui.toastText.Text = text
		-- A second short line grows the toast; the main line keeps the top 40 px.
		ui.toastSub.Text = sub or ""
		ui.toastSub.Visible = sub ~= nil
		ui.toast.Size = UDim2.fromOffset(280, if sub then 62 else 40)
		ui.toastText.Size = UDim2.new(1, -16, 0, 40)
		ui.toast.Visible = true
		task.delay(TOAST_SECONDS, function()
			if token == toastToken then
				ui.toast.Visible = false
			end
		end)
	end

	-- No optimistic state: the result only picks a toast; the button follows the den attributes.
	ui.lock.Activated:Connect(function()
		request(LOCKDOWN_REMOTE, busy, function(result)
			showToast(if result == true then Strings.lockdownStarted else Strings.lockdownRefused)
		end)
	end)

	whenRemote(Net.Pushes.BeingRaidedLive, function(remote)
		if not remote:IsA("RemoteEvent") then
			return
		end
		remote.OnClientEvent:Connect(function(raiderUserId: any)
			local name: string? = nil
			if type(raiderUserId) == "number" then
				local found = Players:GetPlayerByUserId(raiderUserId)
				name = if found then found.DisplayName else nil
			end
			showToast(if name then Strings.format(Strings.beingRaided, { name = name }) else Strings.beingRaidedUnknown)
		end)
	end)

	-- Live steal outcome for the raider. Display only: the server already decided (D-020).
	whenRemote(Net.Pushes.RaidEnded, function(remote)
		if not remote:IsA("RemoteEvent") then
			return
		end
		remote.OnClientEvent:Connect(function(payload: any)
			-- Async raids carry a reason; RaidHudController shows their outcome card instead.
			if type(payload) ~= "table" or payload.reason ~= nil then
				return
			end
			local speciesId = payload.speciesId
			local species = if type(speciesId) == "string" then CritterCatalog.get(speciesId) else nil
			local name = if species then species.name else "?"
			if payload.raidId == "" then
				showToast(Strings.format(Strings.dropped, { name = name }))
			elseif payload.escaped == true then
				showToast(Strings.format(Strings.stolen, { name = name }))
			else
				showToast(Strings.stealUnconfirmed, Strings.stealUnconfirmedSub)
			end
		end)
	end)

	local function render()
		local state, receivedAt = DenController.getState()
		if state then
			local elapsed = os.clock() - receivedAt
			local stored = HudMath.predictStored(state.stored, state.storageCap, state.ratePerSecond, elapsed)
			local price = Economy.eggPrice(state.denLevel)
			local free = HudMath.isRescue(#state.critters, state.glow, stored, price)

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

			-- Egg odds for THIS egg: compact tier lines always visible, species in the panel.
			local tiers, labels = nextOdds(free)
			local isCompact = ui.isCompact()
			local chipText
			if isCompact then
				-- One short line (wraps to two at 130 px): "Odds: C 68.75% · U 31.25%".
				local parts = {}
				for i, t in tiers do
					table.insert(parts, `{string.sub(t.tier, 1, 1)} {labels[i]}`)
				end
				chipText = `<b>{Strings.odds}:</b> ` .. table.concat(parts, " · ")
			else
				local chipLines = { `<b>{Strings.odds}</b>` }
				for i, t in tiers do
					table.insert(chipLines, `{t.tier} {labels[i]}`)
				end
				chipText = table.concat(chipLines, "\n")
			end
			if chipText ~= ui.oddsChipText then
				ui.oddsChipText = chipText
				ui.oddsChip.Text = chipText
				ui.oddsBody.Text = oddsPanelText(tiers, labels, free)
			end
		end

		-- Carried critter: display-only Player attribute; "" or absent = not carrying.
		local speciesId = player:GetAttribute("CarryingSpecies")
		local species = if type(speciesId) == "string" and speciesId ~= "" then CritterCatalog.get(speciesId) else nil
		ui.carry.Visible = species ~= nil
		if species then
			ui.carryText.Text = Strings.format(Strings.carrying, { name = species.name, tier = species.tier })
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

	-- Re-render when the server changes the attributes we draw, not only on the timer.
	local watched: { [Instance]: boolean } = {}
	local function watchDen(den: Instance)
		if watched[den] then
			return
		end
		watched[den] = true
		for _, attr in { "OwnerUserId", "LockdownUntil", "LockdownReadyAt" } do
			den:GetAttributeChangedSignal(attr):Connect(render)
		end
	end
	for _, attr in { "Plot", "CarryingUid", "CarryingSpecies" } do
		player:GetAttributeChangedSignal(attr):Connect(render)
	end
	task.spawn(function()
		local dens = workspace:WaitForChild("World"):WaitForChild("Dens")
		for _, den in dens:GetChildren() do
			watchDen(den)
		end
		dens.ChildAdded:Connect(function(den)
			watchDen(den)
			render()
		end)
	end)
	remotes.ChildAdded:Connect(function()
		render()
	end)

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
