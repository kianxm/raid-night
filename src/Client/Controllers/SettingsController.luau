--!strict
--[[
	SettingsController (owner: ui agent): music volume, SFX volume and reduced motion.
	Settings apply locally the moment they change (SettingsState). They load with GetSettings
	(retried with backoff while it answers nil) and save with SaveSettings. Nothing is saved
	before GetSettings has answered, so a slow load can never overwrite the saved values with
	defaults; changes made in the meantime stay local and are saved right after the load.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Client = script.Parent.Parent
local Ui = require(Client:WaitForChild("Raid"):WaitForChild("Ui"))
local Theme = Ui.theme
local Strings = require(Client:WaitForChild("Hud"):WaitForChild("Strings"))
local SettingsState = require(Client:WaitForChild("Hud"):WaitForChild("SettingsState"))
local Request = require(Client:WaitForChild("Request"))
local MenuController = require(script.Parent:WaitForChild("MenuController")) :: any
local Net = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Net")) :: any

local SAVE_DELAY = 1.5
local SAVE_RETRIES = 3

local SettingsController = {}

local function sliderCard(body: Instance, order: number, title: string, color: Color3, onChange: (number) -> ())
	local card = Ui.card(body, title, order, 96)
	local name = Ui.label(card, Ui.DISPLAY, Theme.type.buttonText)
	name.Text = title
	name.Size = UDim2.new(0.6, 0, 0, 28)
	name.Position = UDim2.fromOffset(8, 6)
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.ZIndex = 10
	local value = Ui.label(card, Ui.DISPLAY, Theme.type.number - 6, color)
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
	track.BackgroundColor3 = Theme.color.panelSunken
	track.ZIndex = 10
	Theme.corner(track, Theme.radius.full)
	Theme.outline(track, Theme.stroke.thin)
	track.Parent = card
	local fill = Instance.new("Frame")
	fill.BackgroundColor3 = color
	fill.BorderSizePixel = 0
	fill.ZIndex = 11
	Theme.corner(fill, Theme.radius.full)
	Theme.gradient(fill, 0.22)
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
	local loaded = false -- GetSettings has answered; until then nothing is saved
	local touched: { [string]: boolean } = {} -- fields the player changed before the load
	local saveToken = 0

	local function trySave(token: number, retries: number)
		Request.invoke(Net.Requests.SaveSettings, function(ok, saved)
			if token ~= saveToken then
				return -- a newer change has its own save queued
			end
			if not (ok and saved == true) and retries > 0 then
				task.delay(SAVE_DELAY * 2, function()
					if token == saveToken then
						trySave(token, retries - 1)
					end
				end)
			end
		end, SettingsState.get())
	end
	local function scheduleSave(field: string)
		if not loaded then
			touched[field] = true
			return
		end
		saveToken += 1
		local token = saveToken
		task.delay(SAVE_DELAY, function()
			if token == saveToken then
				trySave(token, SAVE_RETRIES)
			end
		end)
	end

	MenuController.register({
		id = "Settings",
		label = Strings.menuSettings,
		color = Theme.color.inkDim,
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
			local name = Ui.label(row, Ui.DISPLAY, Theme.type.buttonText)
			name.Text = Strings.settingsReducedMotion
			name.Size = UDim2.fromScale(0.55, 1)
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
				title.TextColor3 = if s.reducedMotion then Theme.color.onAccent else Theme.color.onDisabled
				toggle.BackgroundColor3 = if s.reducedMotion then Theme.color.go else Theme.color.disabled
			end
			SettingsState.onChanged(refresh)
			refresh()
			return refresh
		end,
	})

	-- Load the saved settings; nil (profile not ready, or a missing remote) retries with backoff.
	task.spawn(function()
		Players.LocalPlayer:WaitForChild("PlayerGui")
		local attempt = 0
		while not loaded do
			Request.invoke(Net.Requests.GetSettings, function(ok, saved)
				if ok and type(saved) == "table" then
					SettingsState.set(SettingsState.mergeLoaded(saved, SettingsState.get(), touched))
					loaded = true
				end
			end)
			-- Request.invoke answers on its own thread; wait for it, or for the answer to be nil.
			local waited = 0
			while not loaded and waited < 25 and Request.isBusy(Net.Requests.GetSettings) do
				task.wait(0.25)
				waited += 0.25
			end
			if not loaded then
				attempt += 1
				task.wait(SettingsState.retryDelay(attempt))
			end
		end
		if next(touched) ~= nil then
			touched = {}
			scheduleSave("reducedMotion") -- save what the player chose while the load was pending
		end
	end)
end

return SettingsController
