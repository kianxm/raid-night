--!strict
--[[
	ShopController (owner: ui agent): the Shop screen. Buy an egg or upgrade the den with Glow.
	Every button shows its price; there is no Robux item and no paid randomness at launch. The
	odds are one tap away in the HUD chip. The client only requests; the server answers.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Client = script.Parent.Parent
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net")) :: any
local Economy = require(Shared:WaitForChild("Economy")) :: any
local CritterCatalog = require(Shared:WaitForChild("CritterCatalog")) :: any
local Ui = require(Client:WaitForChild("Raid"):WaitForChild("Ui"))
local Strings = require(Client:WaitForChild("Hud"):WaitForChild("Strings"))
local HudMath = require(Client:WaitForChild("Hud"):WaitForChild("HudMath"))
local ShopMath = require(Client:WaitForChild("Hud"):WaitForChild("ShopMath"))
local Request = require(Client:WaitForChild("Request"))
local MenuController = require(script.Parent:WaitForChild("MenuController")) :: any
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

function ShopController.start()
	MenuController.register({
		id = "Shop",
		label = Strings.menuShop,
		color = Ui.COLOR.gold,
		title = Strings.shopTitle,
		build = function(body)
			local eggTitle, eggNote, eggButton = card(body, "Egg", 1, Ui.COLOR.gold)
			local upTitle, upNote, upButton = card(body, "Upgrade", 2, Ui.COLOR.glow)

			local function refresh()
				local state = DenController.getState()
				if not state then
					return
				end
				local price = Economy.eggPrice(state.denLevel)
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
