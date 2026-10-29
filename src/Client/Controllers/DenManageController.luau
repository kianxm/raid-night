--!strict
--[[
	DenManageController (owner: ui agent): the Den screen. A grid of pads plus Vault and Bag
	chips. Tap a critter to select it, tap a pad to move it there (the server swaps if the pad
	is taken), or use To Vault / To Bag. Display plus PlaceCritter requests only; the server
	validates every move, so a refused move just shows a short message.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Client = script.Parent.Parent
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net")) :: any
local Economy = require(Shared:WaitForChild("Economy")) :: any
local CritterCatalog = require(Shared:WaitForChild("CritterCatalog")) :: any
local Ui = require(Client:WaitForChild("Raid"):WaitForChild("Ui"))
local Strings = require(Client:WaitForChild("Hud"):WaitForChild("Strings"))
local InventoryMath = require(Client:WaitForChild("Hud"):WaitForChild("InventoryMath"))
local CritterCard = require(Client:WaitForChild("Ui"):WaitForChild("CritterCard"))
local Request = require(Client:WaitForChild("Request"))
local MenuController = require(script.Parent:WaitForChild("MenuController")) :: any
local DenController = require(script.Parent:WaitForChild("DenController")) :: any
local InventoryController = require(script.Parent:WaitForChild("InventoryController")) :: any
local Theme = Ui.theme

local DenManageController = {}

local function nameOf(speciesId: string): string
	local s = CritterCatalog.get(speciesId)
	return if s then s.name else "?"
end

local function tierOf(speciesId: string): string?
	local s = CritterCatalog.get(speciesId)
	return if s then s.tier else nil
end

function DenManageController.start()
	MenuController.register({
		id = "Den",
		label = Strings.menuDen,
		color = Ui.COLOR.glow,
		title = Strings.denTitle,
		build = function(body)
			-- PC (DeskCollection.dc.html): a wider popup, five cards across.
			local cap = body.Parent and body.Parent:FindFirstChildOfClass("UISizeConstraint")
			if cap and not UserInputService.TouchEnabled then
				cap.MaxSize = Vector2.new(720, 560)
			end
			local selected: string? = nil

			local status = Ui.label(body, Ui.BODY, Theme.type.body, Theme.color.inkDim)
			status.Name = "Status"
			status.LayoutOrder = 0
			status.Size = UDim2.new(1, -8, 0, 24)
			status.Text = Strings.denPickHint
			status.ZIndex = 10

			local counts = Ui.label(body, Ui.DISPLAY, Theme.type.numberSm)
			counts.TextXAlignment = Enum.TextXAlignment.Left
			counts.Name = "Counts"
			counts.LayoutOrder = 1
			counts.Size = UDim2.new(1, -8, 0, 24)
			counts.ZIndex = 10

			local grid = Instance.new("Frame")
			grid.Name = "Grid"
			grid.LayoutOrder = 2
			grid.BackgroundTransparency = 1
			grid.Size = UDim2.new(1, -8, 0, 0)
			grid.AutomaticSize = Enum.AutomaticSize.Y
			grid.ZIndex = 9
			local layout = Instance.new("UIGridLayout")
			layout.CellSize = UDim2.fromOffset(CritterCard.WIDTH, CritterCard.HEIGHT)
			layout.CellPadding = UDim2.fromOffset(6, 6)
			layout.SortOrder = Enum.SortOrder.LayoutOrder
			layout.Parent = grid
			grid.Parent = body

			local chips = grid:Clone()
			chips.Name = "Chips"
			chips:ClearAllChildren()
			chips.LayoutOrder = 3
			local chipLayout = Instance.new("UIGridLayout")
			chipLayout.CellSize = UDim2.fromOffset(CritterCard.WIDTH, CritterCard.HEIGHT)
			chipLayout.CellPadding = UDim2.fromOffset(6, 6)
			chipLayout.SortOrder = Enum.SortOrder.LayoutOrder
			chipLayout.Parent = chips
			chips.Parent = body

			local actions = Instance.new("Frame")
			actions.Name = "Actions"
			actions.LayoutOrder = 4
			actions.BackgroundTransparency = 1
			actions.Size = UDim2.new(1, -8, 0, 52)
			actions.ZIndex = 9
			local actionLayout = Instance.new("UIListLayout")
			actionLayout.FillDirection = Enum.FillDirection.Horizontal
			actionLayout.Padding = UDim.new(0, 8)
			actionLayout.Parent = actions
			actions.Parent = body
			local toVault = Ui.button(actions, "ToVault", Strings.denToVault, Ui.COLOR.gold, UDim2.new(0.5, -4, 1, 0))
			local toBag = Ui.button(actions, "ToBag", Strings.denToBag, Ui.COLOR.go, UDim2.new(0.5, -4, 1, 0))

			local refresh: () -> ()

			local function move(placement: string, padIndex: number?)
				local uid = selected
				if uid == nil then
					return
				end
				Request.invoke(Net.Requests.PlaceCritter, function(_, ok)
					status.Text = if ok == true then Strings.placeDone else Strings.placeFailed
					if ok == true then
						selected = nil
					end
					refresh()
				end, uid, placement, padIndex)
			end

			toVault.Activated:Connect(function()
				move("Vault", nil)
			end)
			toBag.Activated:Connect(function()
				move("Inventory", nil)
			end)

			local function pick(uid: string, name: string)
				selected = if selected == uid then nil else uid
				status.Text = if selected
					then Strings.format(Strings.denSelected, { name = name })
					else Strings.denPickHint
				refresh()
			end

			refresh = function()
				local state = DenController.getState()
				if not state then
					return
				end
				local rebirths = state.rebirths or 0
				for _, parent in { grid, chips } do
					for _, child in parent:GetChildren() do
						if child:IsA("GuiButton") then
							child:Destroy()
						end
					end
				end
				local usable = Economy.padCount(state.denLevel)
				local slots = InventoryMath.padSlots(state.critters, usable)
				local used = 0
				for _, slot in slots do
					local c = slot.critter
					if c then
						used += 1
					end
					local info = if c
						then InventoryController.cardInfo(c, rebirths)
						else { name = Strings.denPadEmpty, tier = nil, caption = "" }
					local b = CritterCard.button(grid, slot.index, info, c ~= nil and c.uid == selected)
					b.Activated:Connect(function()
						if c and (selected == nil or selected == c.uid) then
							pick(c.uid, nameOf(c.speciesId))
						elseif selected ~= nil then
							move("Pad", slot.index)
						end
					end)
				end
				local vault = InventoryMath.inPlacement(state.critters, "Vault", tierOf)
				for i, c in vault do
					local b = CritterCard.button(chips, i, InventoryController.cardInfo(c, rebirths), c.uid == selected)
					b.Activated:Connect(function()
						pick(c.uid, nameOf(c.speciesId))
					end)
				end
				local bagCount = InventoryMath.count(state.critters, "Inventory")
				counts.Text = table.concat({
					Strings.format(Strings.denPads, { used = tostring(used), total = tostring(usable) }),
					Strings.format(
						Strings.denVault,
						{ used = tostring(#vault), total = tostring(state.vaultSlots or 1) }
					),
					Strings.format(Strings.denBag, { n = tostring(bagCount) }),
				}, "   ")
				Ui.setButton(toVault, Strings.denToVault, Ui.COLOR.gold, selected ~= nil)
				Ui.setButton(toBag, Strings.denToBag, Ui.COLOR.go, selected ~= nil)
			end
			return refresh
		end,
	})
end

return DenManageController
