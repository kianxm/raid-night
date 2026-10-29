--!strict
--[[
	MenuController (owner: ui agent): the left-edge menu strip and the one-modal-at-a-time host.
	Screens register themselves; the strip sits under the Glow panel, clear of the thumbstick.
	Each screen gets a modal body to fill and returns a `refresh` called when it opens and
	whenever the den state changes while open.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local Client = script.Parent.Parent
local Ui = require(Client:WaitForChild("Raid"):WaitForChild("Ui"))
local Strings = require(Client:WaitForChild("Hud"):WaitForChild("Strings"))
local HudLayout = require(Client:WaitForChild("Hud"):WaitForChild("HudLayout"))
local Audio = require(Client:WaitForChild("Sound"):WaitForChild("Audio"))
local DenController = require(script.Parent:WaitForChild("DenController")) :: any

local MenuController = {}

export type Screen = {
	id: string,
	label: string, -- already localized
	color: Color3,
	title: string,
	build: (body: ScrollingFrame) -> () -> (),
}

local gui: ScreenGui
local strip: Frame
local screens: { [string]: { frame: Frame, refresh: () -> () } } = {}
local current: string? = nil
local listeners: { (boolean) -> () } = {}

local function setCurrent(id: string?)
	current = id
	for _, fn in listeners do
		fn(id ~= nil)
	end
end

-- Called with true when a screen opens and false when none is open.
function MenuController.onChanged(fn: (boolean) -> ())
	table.insert(listeners, fn)
end

function MenuController.close()
	if current then
		screens[current].frame.Visible = false
		setCurrent(nil)
	end
end

function MenuController.show(id: string)
	MenuController.close()
	local entry = screens[id]
	if entry then
		entry.refresh()
		entry.frame.Visible = true
		Ui.pop(entry.frame)
		Audio.play("uiClick")
		setCurrent(id)
	end
end

function MenuController.register(screen: Screen)
	local frame, body, closeButton = Ui.modal(gui, screen.id, screen.title, screen.color)
	Ui.setButton(closeButton, Strings.menuClose, screen.color, true)
	closeButton.Activated:Connect(MenuController.close)
	screens[screen.id] = { frame = frame, refresh = screen.build(body) }

	local b = Ui.button(strip, screen.id .. "Button", screen.label, screen.color, UDim2.fromOffset(64, 44))
	b.LayoutOrder = #strip:GetChildren()
	b.Activated:Connect(function()
		if current == screen.id then
			MenuController.close()
		else
			MenuController.show(screen.id)
		end
	end)
end

function MenuController.start()
	gui = Ui.screenGui("Menu", 3, Players.LocalPlayer:WaitForChild("PlayerGui"))
	strip = Instance.new("Frame")
	strip.Name = "Strip"
	strip.BackgroundTransparency = 1
	-- Phone: a row under the Glow panel and protection chip. PC: top-right, since the hotbar
	-- already carries Shop, Critters and Defenses and the top-left belongs to Roblox chat.
	local desktop = HudLayout.mode(UserInputService.TouchEnabled, UserInputService.KeyboardEnabled) == "desktop"
	if desktop then
		strip.AnchorPoint = Vector2.new(1, 0)
		strip.Position = UDim2.new(1, -HudLayout.DESKTOP.inset, 0, 8)
	else
		strip.Position = UDim2.fromOffset(HudLayout.PHONE.inset, HudLayout.PHONE.stripY)
	end
	strip.Size = UDim2.fromOffset(if desktop then 420 else 300, 0)
	strip.AutomaticSize = Enum.AutomaticSize.Y
	strip.Parent = gui
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 4)
	list.FillDirection = Enum.FillDirection.Horizontal
	list.Wraps = true
	list.HorizontalAlignment = if desktop then Enum.HorizontalAlignment.Right else Enum.HorizontalAlignment.Left
	list.Parent = strip

	DenController.onChanged(function()
		if current then
			screens[current].refresh()
		end
	end)
end

return MenuController
