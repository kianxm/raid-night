--!strict
--[[
	SettingsController (owner: ui agent): music volume, SFX volume and reduced motion.
	Settings apply locally the moment they change (SettingsState).

	STUB: saving them with the profile needs two server remotes that are not in Net.luau yet.
	Until the data agent adds them, the calls below find no remote and do nothing, so settings
	last for the session. Proposed contract (hand-off in the P2.5c PR):
	  GetSettings  () -> { musicVolume: number, sfxVolume: number, reducedMotion: boolean }?
	  SaveSettings (settings) -> boolean   -- server clamps 0..1, requires a boolean, ignores extras
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local Client = script.Parent.Parent
local Ui = require(Client:WaitForChild("Raid"):WaitForChild("Ui"))
local Strings = require(Client:WaitForChild("Hud"):WaitForChild("Strings"))
local SettingsState = require(Client:WaitForChild("Hud"):WaitForChild("SettingsState"))
local Request = require(Client:WaitForChild("Request"))
local MenuController = require(script.Parent:WaitForChild("MenuController")) :: any

local STUB_GET = "GetSettings" -- not in Net.luau yet
local STUB_SAVE = "SaveSettings" -- not in Net.luau yet
local SAVE_DELAY = 1.5

local SettingsController = {}

local function sliderCard(body: Instance, order: number, title: string, color: Color3, onChange: (number) -> ())
	local card = Ui.card(body, title, order, 96)
	local name = Ui.label(card, Ui.DISPLAY, 22)
	name.Text = title
	name.Size = UDim2.new(0.6, 0, 0, 28)
	name.Position = UDim2.fromOffset(8, 6)
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.ZIndex = 10
	local value = Ui.label(card, Ui.DISPLAY, 22, color)
	value.Size = UDim2.new(0.3, 0, 0, 28)
	value.Position = UDim2.new(0.7, -8, 0, 6)
	value.TextXAlignment = Enum.TextXAlignment.Right
	value.ZIndex = 10

	local track = Instance.new("TextButton") -- a button so touches land on it
	track.Name = "Track"
	track.Text = ""
	track.AutoButtonColor = false
	track.Size = UDim2.new(1, -24, 0, 36)
	track.Position = UDim2.new(0, 12, 1, -48)
	track.BackgroundColor3 = Ui.COLOR.panel
	track.ZIndex = 10
	Ui.round(track, 12)
	Ui.outline(track, 3)
	track.Parent = card
	local fill = Instance.new("Frame")
	fill.BackgroundColor3 = color
	fill.BorderSizePixel = 0
	fill.ZIndex = 11
	Ui.round(fill, 12)
	fill.Parent = track

	local function show(v: number)
		fill.Size = UDim2.fromScale(math.max(v, 0.04), 1)
		value.Text = Strings.format(Strings.settingsPercent, { pct = tostring(math.floor(v * 100 + 0.5)) })
	end
	local dragging = false
	local function setFromX(x: number)
		local w = track.AbsoluteSize.X
		if w <= 0 then
			return
		end
		local v = math.clamp((x - track.AbsolutePosition.X) / w, 0, 1)
		show(v)
		onChange(v)
	end
	track.InputBegan:Connect(function(input: InputObject)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			dragging = true
			setFromX(input.Position.X)
		end
	end)
	UserInputService.InputChanged:Connect(function(input: InputObject)
		if
			dragging
			and (
				input.UserInputType == Enum.UserInputType.MouseMovement
				or input.UserInputType == Enum.UserInputType.Touch
			)
		then
			setFromX(input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			dragging = false
		end
	end)
	return show
end

function SettingsController.start()
	local saveToken = 0
	local function scheduleSave()
		saveToken += 1
		local token = saveToken
		task.delay(SAVE_DELAY, function()
			if token == saveToken then
				Request.invoke(STUB_SAVE, function() end, SettingsState.get())
			end
		end)
	end

	MenuController.register({
		id = "Settings",
		label = Strings.menuSettings,
		color = Ui.COLOR.dim,
		title = Strings.settingsTitle,
		build = function(body)
			local showMusic = sliderCard(body, 1, Strings.settingsMusic, Ui.COLOR.glow, function(v)
				SettingsState.set({ musicVolume = v })
				scheduleSave()
			end)
			local showSfx = sliderCard(body, 2, Strings.settingsSfx, Ui.COLOR.gold, function(v)
				SettingsState.set({ sfxVolume = v })
				scheduleSave()
			end)

			local row = Ui.card(body, "ReducedMotion", 3, 64)
			local name = Ui.label(row, Ui.DISPLAY, 22)
			name.Text = Strings.settingsReducedMotion
			name.Size = UDim2.new(0.55, 0, 1, 0)
			name.Position = UDim2.fromOffset(8, 0)
			name.TextXAlignment = Enum.TextXAlignment.Left
			name.ZIndex = 10
			local toggle = Ui.button(row, "Toggle", "", Ui.COLOR.go, UDim2.new(0.4, 0, 0, 48))
			toggle.AnchorPoint = Vector2.new(1, 0.5)
			toggle.Position = UDim2.new(1, -8, 0.5, 0)
			toggle.ZIndex = 10
			toggle.Activated:Connect(function()
				SettingsState.set({ reducedMotion = not SettingsState.get().reducedMotion })
				scheduleSave()
			end)

			local function refresh()
				local s = SettingsState.get()
				showMusic(s.musicVolume)
				showSfx(s.sfxVolume)
				-- Not Ui.setButton: a disabled (inactive) button would stop being tappable.
				local title = toggle:FindFirstChild("Title") :: TextLabel
				title.Text = if s.reducedMotion then Strings.settingsOn else Strings.settingsOff
				toggle.BackgroundColor3 = if s.reducedMotion then Ui.COLOR.go else Ui.COLOR.disabled
			end
			SettingsState.onChanged(refresh)
			refresh()
			return refresh
		end,
	})

	-- Load the saved settings if the server offers them (see STUB note above).
	task.spawn(function()
		Players.LocalPlayer:WaitForChild("PlayerGui")
		Request.invoke(STUB_GET, function(ok, saved)
			if ok and type(saved) == "table" then
				SettingsState.set(saved)
			end
		end)
	end)
end

return SettingsController
