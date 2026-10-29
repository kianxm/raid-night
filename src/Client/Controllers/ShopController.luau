--!strict
--[[
	ShopController (owner: ui agent): the Shop screen. Buy an egg or upgrade the den with Glow.
	Every button shows its price; there is no Robux item and no paid randomness at launch. The
	odds are one tap away in the HUD chip. The client only requests; the server answers.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Client = script.Parent.Parent
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net")) :: any
local Economy = require(Shared:WaitForChild("Economy")) :: any
local Config = require(Shared:WaitForChild("Config")) :: any
local GearRules = require(Shared:WaitForChild("GearRules")) :: any
local CritterCatalog = require(Shared:WaitForChild("CritterCatalog")) :: any
local Ui = require(Client:WaitForChild("Raid"):WaitForChild("Ui"))
local Theme = Ui.theme
local Strings = require(Client:WaitForChild("Hud"):WaitForChild("Strings"))
local HudMath = require(Client:WaitForChild("Hud"):WaitForChild("HudMath"))
local ShopMath = require(Client:WaitForChild("Hud"):WaitForChild("ShopMath"))
local LanternBanner = require(Client:WaitForChild("Hud"):WaitForChild("LanternBanner"))
local Request = require(Client:WaitForChild("Request"))
local MenuController = require(script.Parent:WaitForChild("MenuController")) :: any
local GearController = require(script.Parent:WaitForChild("GearController")) :: any
local OnboardingController = require(script.Parent:WaitForChild("OnboardingController")) :: any
local DenController = require(script.Parent:WaitForChild("DenController")) :: any

local ShopController = {}

local function offerText(offer: ShopMath.Offer, buyText: string, freeText: string): string
	if offer.label == "free" then
		return freeText
	elseif offer.label == "max" then
		return Strings.shopMaxLevel
	end
	return Strings.format(buyText, { price = HudMath.abbreviate(offer.price) })
end

local function card(body: Instance, name: string, order: number, color: Color3)
	local c = Ui.card(body, name, order, 128)
	local title = Ui.label(c, Ui.DISPLAY, 24)
	title.Name = "Title"
	title.Size = UDim2.new(1, -16, 0, 30)
	title.Position = UDim2.fromOffset(8, 6)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 10
	local note = Ui.label(c, Ui.BODY, 16, Ui.COLOR.dim)
	note.Name = "Note"
	note.Size = UDim2.new(1, -16, 0, 20)
	note.Position = UDim2.fromOffset(8, 38)
	note.TextXAlignment = Enum.TextXAlignment.Left
	note.ZIndex = 10
	local button = Ui.button(c, "Action", "", color, UDim2.new(1, -16, 0, 52))
	button.AnchorPoint = Vector2.new(0.5, 1)
	button.Position = UDim2.new(0.5, 0, 1, -8)
	button.ZIndex = 10
	return title, note, button
end

local REFETCH_SECONDS = 15 -- GetShopOffers and GetGear are rate limited; refresh() runs often

local function header(body: Instance, text: string, order: number): TextLabel
	local h = Ui.label(body, Ui.DISPLAY, 22, Ui.COLOR.dim)
	h.Name = "Header"
	h.LayoutOrder = order
	h.Size = UDim2.new(1, -8, 0, 30)
	h.Text = text
	h.TextXAlignment = Enum.TextXAlignment.Left
	h.ZIndex = 9
	return h
end

-- A compact row: title and note on the left, one big button on the right.
local function row(body: Instance, name: string, order: number)
	local c = Ui.card(body, name, order, 84)
	local title = Ui.label(c, Ui.DISPLAY, 22)
	title.Size = UDim2.new(0.5, -12, 0, 30)
	title.Position = UDim2.fromOffset(8, 10)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 10
	local note = Ui.label(c, Ui.BODY, 15, Ui.COLOR.dim)
	note.Size = UDim2.new(0.5, -12, 0, 24)
	note.Position = UDim2.fromOffset(8, 46)
	note.TextXAlignment = Enum.TextXAlignment.Left
	note.ZIndex = 10
	local button = Ui.button(c, "Action", "", Ui.COLOR.gold, UDim2.new(0.5, -8, 0, 56))
	button.AnchorPoint = Vector2.new(1, 0.5)
	button.Position = UDim2.new(1, -8, 0.5, 0)
	button.ZIndex = 10
	return c, title, note, button
end

-- The Robux section (server's GetShopOffers) and the Glow gear section (GetGear). Returns a
-- `refresh(state)`. Robux rows are only prompted here; the server grants at the receipt.
local function buildExtras(body: Instance)
	local player = Players.LocalPlayer
	header(body, Strings.shopRobuxHeader, 10)
	local robuxNote = Ui.label(body, Ui.BODY, 16, Ui.COLOR.dim)
	robuxNote.Name = "RobuxNote"
	robuxNote.LayoutOrder = 11
	robuxNote.Size = UDim2.new(1, -8, 0, 28)
	robuxNote.Text = Strings.shopLoading
	robuxNote.ZIndex = 9
	header(body, Strings.shopGearHeader, 100)

	local offers: any = nil -- last GetShopOffers answer
	local gear: any = nil -- last GetGear answer
	local offerRows: { [string]: { frame: Frame, title: TextLabel, note: TextLabel, button: TextButton } } = {}
	local gearRows: { [string]: { frame: Frame, title: TextLabel, note: TextLabel, button: TextButton } } = {}
	local lastFetch = 0
	local lastGlow = 0
	local render: () -> ()

	local function fetch()
		lastFetch = os.clock()
		Request.invoke(Net.Requests.GetShopOffers, function(ok, result)
			offers = if ok and type(result) == "table" then result else nil
			render()
		end)
		Request.invoke(Net.Requests.GetGear, function(ok, result)
			gear = if ok and type(result) == "table" then result else nil
			render()
		end)
	end

	local function prompt(offer: any)
		if not ShopMath.robux(offer.id, offer.price).available then
			return
		end
		if offer.kind == "pass" then
			MarketplaceService:PromptGamePassPurchase(player, offer.id)
		else
			MarketplaceService:PromptProductPurchase(player, offer.id)
		end
	end

	local function rowFor(rows: any, key: string, order: number, onTap: () -> ())
		local r = rows[key]
		if not r then
			local frame, title, note, button = row(body, key, order)
			r = { frame = frame, title = title, note = note, button = button }
			rows[key] = r
			button.Activated:Connect(function()
				r.onTap()
			end)
		end
		r.onTap = onTap
		return r
	end

	render = function()
		-- Robux rows: show only what the server returned.
		local list: { any } = if offers
				and offers.policyKnown == true
				and type(offers.offers) == "table"
			then offers.offers
			else {}
		robuxNote.Visible = #list == 0
		robuxNote.Text = if offers == nil or offers.policyKnown ~= true
			then Strings.shopLoading
			else Strings.shopRobuxNone
		local seen: { [string]: boolean } = {}
		for i, offer in list do
			local key = tostring(offer.key)
			seen[key] = true
			local r = rowFor(offerRows, key, 11 + i, function()
				prompt(offer)
			end)
			local info = ShopMath.robux(offer.id, offer.price)
			r.frame.Visible = true
			r.title.Text = Strings.offerNames[key] or Strings.offerGeneric
			r.note.Text = if info.available then "" else Strings.shopNotAvailable
			Ui.setButton(
				r.button,
				if info.available
					then Strings.format(Strings.shopRobuxFor, { price = tostring(info.price) })
					else Strings.shopNotAvailable,
				Ui.COLOR.go,
				info.available
			)
		end
		for key, r in offerRows do
			r.frame.Visible = seen[key] == true
		end

		-- Gear rows.
		if type(gear) == "table" then
			for i, slot in gear do
				local r = rowFor(gearRows, slot.id, 100 + i, function()
					Request.invoke(Net.Requests.UpgradeGear, function(_, ok)
						-- false = refused, nothing spent: say so right on the row
						gearRows[slot.id].note.Text = if ok == true
							then Strings.shopGearDone
							else Strings.shopGearFailed
						lastFetch = 0
						task.delay(0.3, fetch)
						task.delay(0.5, GearController.refresh) -- the HUD bar's levels and cooldowns
					end, slot.id)
				end)
				local on = GearRules.switchedOn(Config.Gear, slot.id)
				local cost = if on then GearRules.upgradeCost(slot.id, slot.level) else nil
				local g = ShopMath.gear(slot.level, lastGlow, cost, on and cost == nil and slot.level > 0)
				r.frame.Visible = true
				r.title.Text = Strings.gearNames[slot.id] or slot.id
				if g.label == "need" then
					r.note.Text = Strings.format(Strings.shopNeedGlow, { n = HudMath.abbreviate(g.missing) })
				elseif slot.level <= 0 then
					r.note.Text = Strings.shopGearNotOwned
				else
					r.note.Text = Strings.format(Strings.shopGearLevel, { n = tostring(slot.level) })
				end
				local text = if g.label == "max"
					then Strings.shopMaxLevel
					elseif g.label == "off" then Strings.shopGearOff
					else Strings.format(
						if slot.level <= 0 then Strings.shopGearBuyFor else Strings.shopGearUpgradeFor,
						{ price = HudMath.abbreviate(g.cost) }
					)
				Ui.setButton(r.button, text, Ui.COLOR.glow, g.enabled)
			end
		end
	end

	local function afterPurchase()
		task.delay(2, fetch) -- the server grants at the receipt, a moment after the prompt closes
	end
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(afterPurchase)
	MarketplaceService.PromptProductPurchaseFinished:Connect(afterPurchase)

	return function(state: any)
		lastGlow = state.glow
		if os.clock() - lastFetch > REFETCH_SECONDS then
			fetch()
		else
			render()
		end
	end
end

function ShopController.start()
	LanternBanner.start()
	MenuController.register({
		id = "Shop",
		label = Strings.menuShop,
		color = Ui.COLOR.gold,
		title = Strings.shopTitle,
		build = function(body)
			-- PC: a wider two-column screen (design: PC Shop); phone keeps the narrow list.
			if UserInputService.KeyboardEnabled and not UserInputService.TouchEnabled then
				local modal = body.Parent
				local cap = modal and modal:FindFirstChildOfClass("UISizeConstraint")
				if cap then
					cap.MaxSize = Vector2.new(760, 620)
				end
				local list = body:FindFirstChildOfClass("UIListLayout")
				if list then
					list:Destroy()
				end
				local grid = Instance.new("UIGridLayout")
				grid.SortOrder = Enum.SortOrder.LayoutOrder
				grid.CellSize = UDim2.new(0.5, -10, 0, 128)
				grid.CellPadding = UDim2.fromOffset(Theme.space.s2, Theme.space.s2)
				grid.Parent = body
			end
			local eggTitle, eggNote, eggButton = card(body, "Egg", 1, Ui.COLOR.gold)
			local upTitle, upNote, upButton = card(body, "Upgrade", 2, Ui.COLOR.glow)

			local refreshExtras = buildExtras(body)

			local function refresh()
				local state = DenController.getState()
				if not state then
					return
				end
				refreshExtras(state)
				local price = Economy.paidEggPrice(state.denLevel, OnboardingController.getStatus())
				local free = HudMath.isRescue(#state.critters, state.glow, state.stored, price)
				local egg = ShopMath.egg(state.glow, price, free)
				eggTitle.Text = if free then Strings.shopEggFree else Strings.shopEggTitle
				if egg.label == "need" then
					eggNote.Text = Strings.format(Strings.shopNeedGlow, { n = HudMath.abbreviate(egg.missing) })
				end
				local eggText = offerText(egg, Strings.shopBuyFor, Strings.shopBuyFree)
				Ui.setButton(eggButton, eggText, Ui.COLOR.gold, egg.enabled)

				local up = ShopMath.upgrade(state.glow, Economy.upgradeCost(state.denLevel))
				upTitle.Text = Strings.format(Strings.shopUpgradeTitle, { n = tostring(state.denLevel) })
				if up.label == "need" then
					upNote.Text = Strings.format(Strings.shopNeedGlow, { n = HudMath.abbreviate(up.missing) })
				else
					upNote.Text = Strings.format(Strings.shopPads, { n = tostring(Economy.padCount(state.denLevel)) })
				end
				Ui.setButton(upButton, offerText(up, Strings.shopUpgradeFor, ""), Ui.COLOR.glow, up.enabled)
			end

			eggButton.Activated:Connect(function()
				Request.invoke(Net.Requests.BuyEgg, function(_, critter)
					local species = if type(critter) == "table" then CritterCatalog.get(critter.speciesId) else nil
					eggNote.Text = if species
						then Strings.format(Strings.shopHatched, { name = species.name })
						else Strings.shopBuyFailed
				end)
			end)
			upButton.Activated:Connect(function()
				Request.invoke(Net.Requests.UpgradeDen, function(_, ok)
					upNote.Text = if ok == true then Strings.shopUpgraded else Strings.shopUpgradeFailed
				end)
			end)
			return refresh
		end,
	})
end

return ShopController
