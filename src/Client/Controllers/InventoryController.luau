--!strict
--[[
	InventoryController (owner: ui agent): the Bag screen. Lists critters in Inventory with two
	big buttons each: send to the first free pad, or to the Vault. Display plus requests only;
	the server validates every PlaceCritter (pad locked, Vault full, critter busy).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Client = script.Parent.Parent
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net")) :: any
local Economy = require(Shared:WaitForChild("Economy")) :: any
local CritterCatalog = require(Shared:WaitForChild("CritterCatalog")) :: any
local Ui = require(Client:WaitForChild("Raid"):WaitForChild("Ui"))
local Strings = require(Client:WaitForChild("Hud"):WaitForChild("Strings"))
local InventoryMath = require(Client:WaitForChild("Hud"):WaitForChild("InventoryMath"))
local Request = require(Client:WaitForChild("Request"))
local MenuController = require(script.Parent:WaitForChild("MenuController")) :: any
local DenController = require(script.Parent:WaitForChild("DenController")) :: any

local InventoryController = {}

local function tierOf(speciesId: string): string?
	local s = CritterCatalog.get(speciesId)
	return if s then s.tier else nil
end

-- "Common" or "Rare, Shiny".
function InventoryController.describe(critter: any): (string, string)
	local s = CritterCatalog.get(critter.speciesId)
	local tier = if s then s.tier else "?"
	local line = if critter.mutation ~= "None"
		then Strings.format(Strings.critterLineMutation, { tier = tier, mutation = critter.mutation })
		else Strings.format(Strings.critterLine, { tier = tier })
	return if s then s.name else "?", line
end

function InventoryController.start()
	MenuController.register({
		id = "Bag",
		label = Strings.menuBag,
		color = Ui.COLOR.go,
		title = Strings.bagTitle,
		build = function(body)
			local status = Ui.label(body, Ui.BODY, 16, Ui.COLOR.dim)
			status.Name = "Status"
			status.LayoutOrder = 0
			status.Size = UDim2.new(1, -8, 0, 24)
			status.ZIndex = 10

			local function move(uid: string, placement: string, padIndex: number?)
				Request.invoke(Net.Requests.PlaceCritter, function(_, ok)
					status.Text = if ok == true then Strings.placeDone else Strings.placeFailed
				end, uid, placement, padIndex)
			end

			return function()
				local state = DenController.getState()
				for _, child in body:GetChildren() do
					if child:IsA("Frame") then
						child:Destroy()
					end
				end
				if not state then
					return
				end
				local usable = Economy.padCount(state.denLevel)
				local free = InventoryMath.firstFreePad(state.critters, usable)
				local bag = InventoryMath.inPlacement(state.critters, "Inventory", tierOf)
				if #bag == 0 then
					status.Text = Strings.bagEmpty
				end
				for i, critter in bag do
					local row = Ui.card(body, "Row" .. i, i, 72)
					local name, line = InventoryController.describe(critter)
					local title = Ui.label(row, Ui.DISPLAY, 22)
					title.Text = name
					title.Size = UDim2.new(0.5, -8, 0, 30)
					title.Position = UDim2.fromOffset(8, 6)
					title.TextXAlignment = Enum.TextXAlignment.Left
					title.ZIndex = 10
					local sub = Ui.label(row, Ui.BODY, 14, Ui.COLOR.dim)
					sub.Text = line
					sub.Size = UDim2.new(0.5, -8, 0, 22)
					sub.Position = UDim2.fromOffset(8, 40)
					sub.TextXAlignment = Enum.TextXAlignment.Left
					sub.ZIndex = 10

					local toPad = Ui.button(row, "ToPad", Strings.bagToPad, Ui.COLOR.go, UDim2.new(0.25, -6, 0, 52))
					toPad.AnchorPoint = Vector2.new(1, 0.5)
					toPad.Position = UDim2.new(0.75, -4, 0.5, 0)
					toPad.ZIndex = 10
					Ui.setButton(toPad, Strings.bagToPad, Ui.COLOR.go, free ~= nil)
					toPad.Activated:Connect(function()
						if free ~= nil then
							move(critter.uid, "Pad", free)
						end
					end)
					local toVault =
						Ui.button(row, "ToVault", Strings.bagToVault, Ui.COLOR.gold, UDim2.new(0.25, -6, 0, 52))
					toVault.AnchorPoint = Vector2.new(1, 0.5)
					toVault.Position = UDim2.new(1, -8, 0.5, 0)
					toVault.ZIndex = 10
					toVault.Activated:Connect(function()
						move(critter.uid, "Vault", nil)
					end)
				end
			end
		end,
	})
end

return InventoryController
