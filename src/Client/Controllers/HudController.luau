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
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net")) :: any
local Economy = require(Shared:WaitForChild("Economy")) :: any
local Config = require(Shared:WaitForChild("Config")) :: any
local CritterCatalog = require(Shared:WaitForChild("CritterCatalog")) :: any

local Hud = script.Parent.Parent:WaitForChild("Hud")
local Ui = require(script.Parent.Parent:WaitForChild("Raid"):WaitForChild("Ui"))
local Strings = require(Hud:WaitForChild("Strings"))
local HudMath = require(Hud:WaitForChild("HudMath"))
local HudLayout = require(Hud:WaitForChild("HudLayout"))
local SettingsState = require(Hud:WaitForChild("SettingsState"))
local Theme = require(script.Parent.Parent:WaitForChild("Ui"):WaitForChild("Theme"))
local OnboardingController = require(script.Parent:WaitForChild("OnboardingController")) :: any
local DenController = require(script.Parent:WaitForChild("DenController")) :: any

local LOCKDOWN_REMOTE = Net.Requests.Lockdown
local TOAST_SECONDS = 4
local BANNER_SECONDS = 6
local TOAST_Y = 56
local TIMER_Y = 8

local C = Theme.color
local COLOR = {
	panel = C.panel,
	outline = C.night900,
	text = C.ink,
	glow = C.glow,
	collect = C.go,
	collectFull = C.gold,
	buy = C.gold,
	lock = C.lock,
	disabled = C.disabled,
}
local DISPLAY_FONT = Theme.display
local BODY_FONT = Theme.body
local MODE = HudLayout.mode(UserInputService.TouchEnabled, UserInputService.KeyboardEnabled)
local DESKTOP = MODE == "desktop"

local HudController = {}

local player = Players.LocalPlayer
local remotes: Instance

local round, outline, label, panel = Ui.round, Ui.outline, Ui.label, Ui.panel

-- One chunky button with a big title and a small price/sub line. Min height 56 px for thumbs.
local function makeButton(parent: Instance, name: string, order: number, color: Color3)
	local b = Theme.button(parent, name, "", color, UDim2.new(1, 0, 0, 58))
	b.LayoutOrder = order
	local title = b:FindFirstChild("Title") :: TextLabel
	title.Size = UDim2.new(1, -12, 0.55, 0)
	title.Position = UDim2.fromOffset(6, 3)
	local sub = Theme.bodyText(b, Theme.type.body, COLOR.outline)
	sub.Name = "Sub"
	sub.Size = UDim2.new(1, -12, 0.35, 0)
	sub.Position = UDim2.new(0, 6, 0.6, 0)
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

local function setSub(b: TextButton, text: string)
	local sub = b:FindFirstChild("Sub")
	if sub and sub:IsA("TextLabel") then
		sub.Text = text
	end
end

local function setEnabled(b: TextButton, enabled: boolean, color: Color3)
	b.BackgroundColor3 = if enabled then color else COLOR.disabled
	b.Active = enabled
	local ink = if enabled then C.onAccent else C.onDisabled
	for _, name in { "Title", "Sub" } do
		local l = b:FindFirstChild(name)
		if l and l:IsA("TextLabel") then
			l.TextColor3 = ink
		end
	end
end

-- PC hotbar (DeskMain.dc.html): bottom-center, keys 1-6 then Lockdown apart on Q. Slots are
-- Theme buttons with a keycap chip; no icon art exists yet, so the label carries the meaning.
local SLOT_STYLE: { [string]: { text: string, fill: Color3, neutral: boolean } } = {
	collect = { text = Strings.collect, fill = COLOR.collect, neutral = false },
	eggs = { text = Strings.hotbarEggs, fill = COLOR.buy, neutral = false },
	raid = { text = Strings.raid, fill = C.glow, neutral = false },
	shop = { text = Strings.menuShop, fill = C.panelRaised, neutral = true },
	critters = { text = Strings.hotbarCritters, fill = C.panelRaised, neutral = true },
	defenses = { text = Strings.hotbarDefenses, fill = C.panelRaised, neutral = true },
	lockdown = { text = Strings.lockdown, fill = COLOR.lock, neutral = false },
}

local function buildHotbar(gui: ScreenGui): { [string]: TextButton }
	local slots: { [string]: TextButton } = {}
	local bar = Instance.new("Frame")
	bar.Name = "Hotbar"
	bar.BackgroundTransparency = 1
	bar.AnchorPoint = Vector2.new(0, 1)
	bar.Size = UDim2.fromScale(1, 0)
	bar.AutomaticSize = Enum.AutomaticSize.Y
	bar.Position = UDim2.new(0, 0, 1, -HudLayout.DESKTOP.hotbarBottom)
	bar.Parent = gui
	local function fit()
		local layout = HudLayout.hotbar(gui.AbsoluteSize.X)
		bar.Size = UDim2.new(1, 0, 0, layout.slotSize)
		bar.AutomaticSize = Enum.AutomaticSize.None
		for i, slot in HudLayout.SLOTS do
			local b = slots[slot.action]
			b.Size = UDim2.fromOffset(layout.slotSize, layout.slotSize)
			b.Position = UDim2.fromOffset(layout.xs[i], 0)
		end
	end
	for _, slot in HudLayout.SLOTS do
		local style = SLOT_STYLE[slot.action]
		local b = Theme.button(bar, slot.action, style.text, style.fill, UDim2.fromOffset(64, 64))
		local title = b:FindFirstChild("Title") :: TextLabel
		title.Size = UDim2.new(1, -8, 0.4, 0)
		title.Position = UDim2.new(0, 4, 0.5, 0)
		title.TextColor3 = if style.neutral then C.ink else C.onAccent
		local key, keyText = Theme.chip(b, "Key", slot.keyLabel, C.night900, C.ink)
		key.Size = UDim2.fromOffset(24, 22)
		key.Position = UDim2.fromOffset(4, 4)
		keyText.Font = DISPLAY_FONT
		local sub = Theme.bodyText(b, Theme.type.caption, if style.neutral then C.inkDim else C.onAccent)
		sub.Name = "Sub"
		sub.Size = UDim2.new(1, -8, 0, 14)
		sub.Position = UDim2.new(0, 4, 0.3, 0)
		slots[slot.action] = b
	end
	fit()
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)

	-- Space / Shift reminder, bottom-right.
	local hint = Theme.bodyText(gui, Theme.type.caption, C.inkMute)
	hint.Name = "KeyHint"
	hint.AnchorPoint = Vector2.new(1, 1)
	hint.Size = UDim2.fromOffset(200, 18)
	hint.Position = UDim2.new(1, -24, 1, -28)
	hint.TextXAlignment = Enum.TextXAlignment.Right
	hint.Text = `Space {Strings.hintJump}   Shift {Strings.hintSprint}`
	return slots
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

	-- Glow counter + storage. Phone: top-left under the Roblox bar. PC: bottom-left (no
	-- thumbstick there, and chat keeps the top-left). Orb + number + rate, bar, caption.
	local PH, DK = HudLayout.PHONE, HudLayout.DESKTOP
	local top = panel(gui, "GlowPanel", UDim2.fromOffset(0, 0), UDim2.fromOffset(0, 0))
	local sizeLimit = Instance.new("UISizeConstraint")
	if DESKTOP then
		top.AnchorPoint = Vector2.new(0, 1)
		top.Position = UDim2.new(0, DK.inset, 1, -DK.inset)
		top.Size = UDim2.fromOffset(DK.glowWidth, DK.glowHeight)
	else
		top.Position = UDim2.fromOffset(PH.inset, 8)
		top.Size = UDim2.new(0.3, 0, 0, PH.glowHeight)
		sizeLimit.MinSize = Vector2.new(PH.glowMinWidth, PH.glowHeight)
		sizeLimit.MaxSize = Vector2.new(PH.glowMaxWidth, PH.glowHeight)
		sizeLimit.Parent = top
	end
	Theme.padding(top, Theme.space.s2)
	local orb = Theme.orb(top, Theme.size.orb)
	orb.Position = UDim2.fromOffset(0, 2)
	local glowText = label(top, DISPLAY_FONT, if DESKTOP then 34 else Theme.type.number)
	glowText.Size = UDim2.new(1, -120, 0, 34)
	glowText.Position = UDim2.fromOffset(Theme.size.orb + 6, 0)
	glowText.TextColor3 = COLOR.glow
	glowText.TextXAlignment = Enum.TextXAlignment.Left
	local rateText = label(top, DISPLAY_FONT, Theme.type.numberSm, C.inkDim)
	rateText.Name = "Rate"
	rateText.AnchorPoint = Vector2.new(1, 0)
	rateText.Size = UDim2.fromOffset(84, 22)
	rateText.Position = UDim2.new(1, 0, 0, 8)
	rateText.TextXAlignment = Enum.TextXAlignment.Right
	local storage = Theme.bar(top, "StorageBar", 16)
	storage.track.Position = UDim2.fromOffset(0, 40)
	local barBack = storage.track
	local fill = storage.fill
	local barText = label(top, BODY_FONT, Theme.type.caption, C.inkDim)
	barText.Name = "Caption"
	barText.Size = UDim2.new(1, 0, 0, 16)
	barText.Position = UDim2.fromOffset(0, 60)
	barText.TextXAlignment = Enum.TextXAlignment.Left
	barBack.Name = "StorageBar"

	-- Top-center: carried critter (hidden unless carrying).
	local carry = panel(gui, "Carrying", UDim2.fromOffset(220, 40), UDim2.new(0.5, -110, 0, 8))
	carry.Visible = false
	local carryText = label(carry, DISPLAY_FONT, 22)
	carryText.Size = UDim2.new(1, -16, 1, 0)
	carryText.Position = UDim2.fromOffset(8, 0)

	-- Short toast under the carried pill (raid alerts, Lockdown result). The text colour carries
	-- the kind (toast kinds in the design system: gold default, go, lock); the sub line is dim.
	local toast = panel(gui, "Toast", UDim2.fromOffset(280, 40), UDim2.new(0.5, -140, 0, TOAST_Y))
	toast.Visible = false
	toast.ZIndex = 5
	local toastText = label(toast, DISPLAY_FONT, Theme.type.buttonText - 2, C.gold)
	toastText.Size = UDim2.new(1, -16, 1, 0)
	toastText.Position = UDim2.fromOffset(8, 0)
	toastText.ZIndex = 6
	local toastSub = label(toast, BODY_FONT, Theme.type.caption + 2, C.inkDim)
	toastSub.Name = "Sub"
	toastSub.Size = UDim2.new(1, -16, 0, 22)
	toastSub.Position = UDim2.fromOffset(8, 32)
	toastSub.ZIndex = 6
	toastSub.Visible = false

	-- Breach banner (Breach.dc.html): the only pulsing element. Siren tile, revenge title, one
	-- dim line. Top-centre, over the carried pill, which a defender is not showing.
	local bannerWidth = if DESKTOP then 560 else 430
	local banner = panel(gui, "Breach", UDim2.new(0.92, 0, 0, 64), UDim2.new(0.5, 0, 0, 8))
	banner.AnchorPoint = Vector2.new(0.5, 0)
	banner.Visible = false
	banner.ZIndex = 7
	local bannerCap = Instance.new("UISizeConstraint")
	bannerCap.MaxSize = Vector2.new(bannerWidth, 64)
	bannerCap.Parent = banner
	local bannerRim = banner:FindFirstChildOfClass("UIStroke") :: UIStroke
	bannerRim.Thickness = Theme.stroke.heavy
	local siren = Instance.new("Frame")
	siren.Name = "Siren"
	siren.Size = UDim2.fromOffset(44, 44)
	siren.Position = UDim2.new(0, 8, 0.5, -22)
	siren.BackgroundColor3 = C.revenge
	siren.BorderSizePixel = 0
	siren.ZIndex = 8
	Theme.corner(siren, Theme.radius.lg)
	Theme.outline(siren, Theme.stroke.normal)
	Theme.gradient(siren, 0.2)
	siren.Parent = banner
	local sirenMark = label(siren, DISPLAY_FONT, Theme.type.titleLg, C.onAccent)
	sirenMark.Text = "!"
	sirenMark.ZIndex = 9
	local bannerTitle = label(banner, DISPLAY_FONT, Theme.type.title - 2, C.revenge)
	bannerTitle.Name = "Title"
	bannerTitle.Size = UDim2.new(1, -72, 0, 28)
	bannerTitle.Position = UDim2.fromOffset(60, 6)
	bannerTitle.TextXAlignment = Enum.TextXAlignment.Left
	bannerTitle.ZIndex = 8
	local bannerSub = label(banner, BODY_FONT, Theme.type.label, C.inkDim)
	bannerSub.Name = "Sub"
	bannerSub.Size = UDim2.new(1, -72, 0, 22)
	bannerSub.Position = UDim2.fromOffset(60, 36)
	bannerSub.TextXAlignment = Enum.TextXAlignment.Left
	bannerSub.ZIndex = 8

	-- Lockdown timer (Lockdown.dc.html): lock-purple pill, top-centre, only while sealed.
	local timer = panel(gui, "LockdownTimer", UDim2.fromOffset(250, 40), UDim2.new(0.5, -125, 0, TIMER_Y))
	timer.Visible = false
	timer.ZIndex = 4
	(timer:FindFirstChildOfClass("UIStroke") :: UIStroke).Color = C.lock
	local timerTitle = label(timer, DISPLAY_FONT, Theme.type.buttonText - 2, C.lock)
	timerTitle.Size = UDim2.new(1, -90, 1, 0)
	timerTitle.Position = UDim2.fromOffset(12, 0)
	timerTitle.TextXAlignment = Enum.TextXAlignment.Left
	timerTitle.ZIndex = 5
	local timerClock = label(timer, DISPLAY_FONT, Theme.type.number - 4, C.ink)
	timerClock.Size = UDim2.fromOffset(72, 40)
	timerClock.Position = UDim2.new(1, -80, 0, 0)
	timerClock.TextXAlignment = Enum.TextXAlignment.Right
	timerClock.ZIndex = 5

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
		-- PC: the hotbar owns Collect/Eggs/Lockdown; only the odds chip stays, above the key hints.
		column.Position = UDim2.new(1, -12, 1, -(if DESKTOP then 64 else layout.reserve))
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
						local px = if layout.compact then 1 else 6
						pad.PaddingTop = UDim.new(0, px)
						pad.PaddingBottom = UDim.new(0, px)
					end
					child.TextSize = layout.chipText
					child.TextTruncate = Enum.TextTruncate.None
				else
					child.Size = UDim2.new(1, 0, 0, layout.button)
					child.Visible = not DESKTOP
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
	oddsChip.AutoButtonColor = false
	oddsChip.Font = BODY_FONT
	oddsChip.TextSize = 14
	oddsChip.TextColor3 = COLOR.text
	oddsChip.RichText = true
	oddsChip.TextWrapped = true
	oddsChip.Text = ""
	round(oddsChip, Theme.radius.md)
	outline(oddsChip, Theme.stroke.thin)
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
	oddsClose.TextColor3 = C.onAccent
	oddsClose.Text = Strings.oddsClose
	oddsClose.ZIndex = 9
	round(oddsClose, Theme.radius.lg)
	outline(oddsClose, Theme.stroke.normal)
	oddsClose.Parent = oddsPanel

	return {
		hotbar = if DESKTOP then buildHotbar(gui) else {},
		glowText = glowText,
		rateText = rateText,
		storage = storage,
		fill = fill,
		barText = barText,
		carry = carry,
		carryText = carryText,
		toast = toast,
		toastText = toastText,
		toastSub = toastSub,
		banner = banner,
		bannerRim = bannerRim,
		bannerTitle = bannerTitle,
		bannerSub = bannerSub,
		timer = timer,
		timerTitle = timerTitle,
		timerClock = timerClock,
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
	-- kind picks the text colour: "gold" (default), "go", "lock" or "plain".
	local function showToast(text: string, sub: string?, kind: string?)
		toastToken += 1
		local token = toastToken
		ui.toastText.Text = text
		ui.toastText.TextColor3 = if kind == "go"
			then C.go
			elseif kind == "lock" then C.lock
			elseif kind == "plain" then C.ink
			else C.gold
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

	-- Breach banner. It pulses its rim unless Reduced motion is on; the pulse stops when it hides.
	local bannerToken = 0
	local pulse: Tween? = nil
	local function showBanner(title: string)
		bannerToken += 1
		local token = bannerToken
		ui.bannerTitle.Text = title
		ui.bannerSub.Text = if DESKTOP then Strings.breachSubDesktop else Strings.breachSub
		ui.banner.Visible = true
		if pulse then
			pulse:Cancel()
			pulse = nil
		end
		ui.bannerRim.Color = C.night900
		if not SettingsState.get().reducedMotion then
			local t = TweenService:Create(
				ui.bannerRim,
				TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
				{ Color = C.revenge }
			)
			pulse = t
			t:Play()
		end
		task.delay(BANNER_SECONDS, function()
			if token == bannerToken then
				ui.banner.Visible = false
				if pulse then
					pulse:Cancel()
					pulse = nil
				end
			end
		end)
	end

	-- No optimistic state: the result only picks a toast; the button follows the den attributes.
	ui.lock.Activated:Connect(function()
		request(LOCKDOWN_REMOTE, busy, function(result)
			showToast(
				if result == true then Strings.lockdownStarted else Strings.lockdownRefused,
				nil,
				if result == true then "lock" else nil
			)
		end)
	end)

	-- PC hotbar: the same requests as the phone rail, plus the menu screens. Keys go through
	-- ContextActionService and Pass, so nothing that already listens for 1-6 or Q is swallowed.
	-- Only built and bound with a keyboard and no touch input (HudLayout.mode).
	local function openScreen(id: string)
		local menu = script.Parent:WaitForChild("MenuController") :: ModuleScript
		(require(menu) :: any).show(id)
	end
	local ACTIONS: { [string]: () -> () } = {
		collect = function()
			request(Net.Requests.Collect, busy)
		end,
		eggs = function()
			request(Net.Requests.BuyEgg, busy)
		end,
		raid = function()
			(require(script.Parent:WaitForChild("RaidPortalController")) :: any).open()
		end,
		shop = function()
			openScreen("Shop")
		end,
		critters = function()
			openScreen("Bag")
		end,
		defenses = function()
			openScreen("Den")
		end,
		lockdown = function()
			request(LOCKDOWN_REMOTE, busy, function(result)
				showToast(
					if result == true then Strings.lockdownStarted else Strings.lockdownRefused,
					nil,
					if result == true then "lock" else nil
				)
			end)
		end,
	}
	if DESKTOP then
		for _, slot in HudLayout.SLOTS do
			local action = ACTIONS[slot.action]
			local button = ui.hotbar[slot.action]
			button.Activated:Connect(action)
			ContextActionService:BindAction("RaidNight_" .. slot.action, function(_, state)
				if state == Enum.UserInputState.Begin then
					action()
				end
				return Enum.ContextActionResult.Pass
			end, false, Enum.KeyCode[slot.keyName])
		end
	end

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
			showBanner(
				if name then Strings.format(Strings.beingRaided, { name = name }) else Strings.beingRaidedUnknown
			)
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
				showToast(Strings.format(Strings.dropped, { name = name }), nil, "plain")
			elseif payload.escaped == true then
				showToast(Strings.format(Strings.stolen, { name = name }), nil, "go")
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
			local price = Economy.paidEggPrice(state.denLevel, OnboardingController.getStatus())
			local free = HudMath.isRescue(#state.critters, state.glow, stored, price)

			ui.glowText.Text = HudMath.abbreviate(state.glow)
			local share = if state.storageCap > 0 then math.clamp(stored / state.storageCap, 0, 1) else 0
			local full = HudLayout.storageTone(share) == "full"
			ui.storage.set(share, full)
			ui.rateText.Text = if full
				then Strings.ratePaused
				else Strings.format(Strings.ratePerSecond, { rate = HudMath.abbreviate(state.ratePerSecond) })
			ui.rateText.TextColor3 = if full then C.inkMute else C.inkDim
			ui.barText.Text = if full
				then Strings.storageFullCaption
				else Strings.storage .. " " .. HudMath.abbreviate(stored) .. " / " .. HudMath.abbreviate(
					state.storageCap
				)
			ui.barText.TextColor3 = if full then C.gold else C.inkDim

			-- Gold Collect when storage is full (StorageFull.dc.html): the reason to come back.
			local collectColor = if full then COLOR.collectFull else COLOR.collect
			ui.collectTitle.Text = Strings.collect
			ui.collectSub.Text = "+" .. HudMath.abbreviate(stored)
			setEnabled(ui.collect, stored >= 1, collectColor)

			ui.buyTitle.Text = Strings.buyEgg
			ui.buySub.Text = if free then Strings.free else HudMath.abbreviate(price) .. " " .. Strings.glow
			setEnabled(ui.buy, free or state.glow >= price, COLOR.buy)

			local hb = ui.hotbar
			if hb.collect then
				setEnabled(hb.collect, stored >= 1, collectColor)
				setSub(hb.collect, "+" .. HudMath.abbreviate(stored))
				setEnabled(hb.eggs, free or state.glow >= price, COLOR.buy)
				setSub(hb.eggs, if free then Strings.free else HudMath.abbreviate(price))
			end

			-- Egg odds for THIS egg: compact tier lines always visible, species in the panel.
			local tiers, labels = nextOdds(free)
			local isCompact = ui.isCompact()
			local chipText
			if isCompact then
				-- Two tiers per line (6 tiers = 3 lines): "C 55%  U 25%".
				local parts = {}
				for i, t in tiers do
					table.insert(parts, `{string.sub(t.tier, 1, 1)} {labels[i]}`)
				end
				chipText = HudMath.chipRows(parts, 2)
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
			ui.carryText.TextColor3 = C.tier[species.tier] or C.ink
		end

		-- Lockdown button (rail on phone, Q slot on PC).
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
		-- Lockdown timer pill; the toast slides below it so neither covers the other.
		local sealed = status == "active"
		ui.timer.Visible = sealed
		ui.timer.Position = UDim2.new(0.5, -125, 0, if ui.carry.Visible then TOAST_Y else TIMER_Y)
		ui.toast.Position = UDim2.new(0.5, -140, 0, if sealed then TOAST_Y + 48 else TOAST_Y)
		if sealed then
			ui.timerTitle.Text = Strings.lockdownStarted
			ui.timerClock.Text = HudMath.clock(left)
		end
		local hbLock = ui.hotbar.lockdown
		if hbLock then
			setEnabled(hbLock, ui.lock.Active, COLOR.lock)
			setSub(hbLock, ui.lockSub.Text)
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
