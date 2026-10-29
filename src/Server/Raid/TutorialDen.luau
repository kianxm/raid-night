--!strict
--[[
	TutorialDen (owner: raid agent): the guided first steal, Appendix C step 4 (P2.6r, D-064).

	Placement. One small round den per player, on the street in front of their own den
	(Plots.tutorialPosition: den-local (0, 42), 14 studs past the front border), so every den has
	its own spot, clear of the other dens, the plaza, lamps and street props (Plots.spec), and a
	carry from it always crosses the street before it reaches home. It exists only while that
	player's next onboarding step is the guided steal (RaidRules.tutorialDenOpen on
	Profile.onboardingStatus) and IncomeService.tutorialCritterAvailable(player) is true; it is
	destroyed as soon as either stops (the steal landed, onboarding was skipped, the player left
	or lost their den). Parts: a floor disc and a pad (2) plus CritterView's critter.

	Server-owned: no defender profile, no Escrow, nothing stolen from anyone. One placeholder
	critter, Economy.TUTORIAL_CRITTER_SPECIES with no mutation.
	  Grab    The pad's "StealPrompt" (F, like a live pad). The server times the hold
	          (Config.LiveRaid.grabHoldSeconds) and re-checks RaidRules.canGrabTutorial 10 times a
	          second: the den's own player only (anyone else: NotYourTutorial), still open, a den
	          and a loaded profile, not carrying live, in an async raid or already carrying, and
	          range to the server pad (Config.LiveRaid.grabRange). Rate limit Net.Limits.GrabCritter.
	  Carry   The normal live carry: walk speed RaidRules.carryWalkSpeed(weight), the critter over
	          the head (CarryProp), RaidRules.carryStep for the movement budget, height and the
	          street rule. No owner, so no tag; no Lockdown; no live loss rule; no kill switch
	          (onboarding must not stall when raids are switched off, and no transfer happens).
	          Display-only Player attributes CarryingUid ("tutorial") / CarryingSpecies.
	  Drop    Too fast, too high, died, left, or the den closed: the critter goes back on its pad
	          (try again). RaidEnded { raidId = "", escaped = false } like a live drop.
	  Escape  Inside their own den: IncomeService.grantTutorialCritter(player), and nothing else
	          (it claims the stealHome step itself; advancing that step first would spend the claim).
	          Once per player ever (the claim), so it cannot be farmed. RaidEnded { raidId =
	          RaidRules.TUTORIAL_RAID_ID, escaped = true, speciesId } when granted; escaped false if
	          the grant refused (the den then closes on its own, or stays for another try).
	          Never counted as a successful raid (RaidEvents), never a raid analytics event.

	Display for the client (ui's guidance, never read by the server): the den Model
	"TutorialDen<userId>" under workspace.TutorialDens with attribute OwnerUserId, streamed
	persistently to its player; Player attribute TutorialDenPosition (Vector3, the pad's top) while
	the den is open, absent otherwise. Other players can stream the den in when nearby; its prompt
	refuses them, and the client hides it for anyone but OwnerUserId (ui handoff).

	Never writes a profile and never yields.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterPlayer = game:GetService("StarterPlayer")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local CritterCatalog = require(Shared.CritterCatalog)
local Economy = require(Shared.Economy)
local Net = require(Shared.Net)
local Plots = require(Shared.Plots)
local Profile = require(Shared.Profile)
local RaidRules = require(Shared.RaidRules)
local Types = require(Shared.Types)
local Services = script.Parent.Parent.Services
local DataService = require(Services.DataService) :: any
local DenWorldService = require(Services.DenWorldService) :: any
local IncomeService = require(Services.IncomeService) :: any
local CritterView = require(script.Parent.Parent.Economy.CritterView) :: any
local CarryProp = require(script.Parent.CarryProp)

export type Api = {
	rootOf: (Player) -> BasePart?,
	-- Carrying a live critter or in an async raid (RaidService / AsyncRaid server state).
	busy: (Player) -> boolean,
	raidEnded: RemoteEvent,
}

type Den = {
	plot: number,
	model: Model,
	pad: BasePart,
	critter: Instance?, -- unparented while carried
	floorTop: number,
}
type Carry = {
	speciesId: string,
	walkSpeed: number,
	lastPos: Vector3,
	lastAt: number,
	budget: number,
	crossedStreet: boolean,
	floorY: number,
	prop: Instance,
}

local L = Plots.Layout
local GROUND_TOP = 0.5 -- DenWorldService's street ground top
local FLOOR_H = 0.4
local PAD_H = 0.4
local PAD_SIZE = 5
local HOLD_GRACE = 0.25 -- the prompt asks for a little longer than the server needs
local PROMPT_DISTANCE = 8
local TICK = 0.1
local SYNC_TICK = 0.5
local LIMIT_WINDOW_SECONDS = 10
local INDIGO = Color3.fromHex("#1B1F3B")
local PAD_COLOR = Color3.fromRGB(62, 56, 120)
local POSITION_ATTRIBUTE = "TutorialDenPosition"

local TutorialDen = {}

local api: Api
local folder: Folder
local dens: { [Player]: Den } = {}
local holds: { [Player]: number } = {} -- os.clock() the hold started
local carries: { [Player]: Carry } = {}
local windows: { [Player]: { start: number, count: number } } = {}
local started = false

local function debugLog(message: string)
	if RunService:IsStudio() then
		print(`[TutorialDen] {message}`)
	end
end

local function species(): Types.CritterSpecies?
	return CritterCatalog.get(Economy.TUTORIAL_CRITTER_SPECIES)
end

local function humanoidOf(player: Player): Humanoid?
	local character = player.Character
	return if character then character:FindFirstChildOfClass("Humanoid") else nil
end

local function allowGrab(player: Player): boolean
	local now = os.clock()
	local window = windows[player]
	if not window or now - window.start >= LIMIT_WINDOW_SECONDS then
		window = { start = now, count = 0 }
		windows[player] = window
	end
	window.count += 1
	return window.count <= Net.Limits.GrabCritter
end

-- Is this player's onboarding at the guided steal, with the tutorial critter still to claim?
local function eligible(player: Player): boolean
	local profile = DataService.getProfile(player.UserId)
	if profile == nil then
		return false
	end
	local ok, status = pcall(Profile.onboardingStatus, profile)
	if not ok or not RaidRules.tutorialDenOpen(status) then
		return false
	end
	local read, available = pcall(IncomeService.tutorialCritterAvailable, player)
	return read and available == true
end

local function part(parent: Instance, props: { [string]: any }): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in props do
		(p :: any)[key] = value
	end
	p.Parent = parent
	return p
end

-- Draws the critter on the pad (CritterView, so it looks like any den critter).
local function drawCritter(den: Den)
	if den.critter and den.critter.Parent == den.model then
		return
	end
	local info = species()
	if not den.critter and info then
		local ok, model = pcall(CritterView.build, info.id, "None")
		if ok and model then
			den.critter = model
		end
	end
	local critter = den.critter
	if critter and critter:IsA("Model") then
		critter:PivotTo(den.pad.CFrame * CFrame.new(0, PAD_H / 2, 0))
		critter.Parent = den.model
	end
end

local function sendEnded(player: Player, raidId: string, escaped: boolean, speciesId: string)
	if player.Parent ~= nil then
		local payload: Net.RaidEnd = { raidId = raidId, escaped = escaped, speciesId = speciesId, glow = 0 }
		pcall(api.raidEnded.FireClient, api.raidEnded, player, payload)
	end
end

local function clearCarrier(player: Player, carry: Carry)
	carries[player] = nil
	pcall(function()
		carry.prop:Destroy()
		player:SetAttribute("CarryingUid", "")
		player:SetAttribute("CarryingSpecies", "")
		local humanoid = humanoidOf(player)
		if humanoid then
			humanoid.WalkSpeed = StarterPlayer.CharacterWalkSpeed
		end
	end)
end

-- The critter goes back on its pad (if the den is still open). Nothing was ever granted.
local function drop(player: Player, carry: Carry, why: string)
	clearCarrier(player, carry)
	local den = dens[player]
	if den then
		pcall(drawCritter, den)
	end
	sendEnded(player, "", false, carry.speciesId)
	debugLog(`{player.Name} dropped the tutorial critter ({why})`)
end

local function closeDen(player: Player)
	holds[player] = nil
	local carry = carries[player]
	if carry then
		drop(player, carry, "den closed")
	end
	local den = dens[player]
	dens[player] = nil
	if den then
		pcall(function()
			if den.critter then
				den.critter:Destroy() -- unparented while it was carried
			end
			den.model:Destroy()
			player:SetAttribute(POSITION_ATTRIBUTE, nil)
		end)
		debugLog(`closed {player.Name}'s tutorial den`)
	end
end

local function openDen(player: Player, plot: number)
	local x, z = Plots.tutorialPosition(plot)
	local model = Instance.new("Model")
	model.Name = `TutorialDen{player.UserId}`
	model.ModelStreamingMode = Enum.ModelStreamingMode.PersistentPerPlayer
	model:SetAttribute("OwnerUserId", player.UserId)
	local floor = part(model, {
		Name = "Floor",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(FLOOR_H, L.tutorialRadius * 2, L.tutorialRadius * 2),
		CFrame = CFrame.new(x, GROUND_TOP + FLOOR_H / 2, z) * CFrame.Angles(0, 0, math.pi / 2),
		Color = INDIGO,
	})
	model.PrimaryPart = floor
	local floorTop = GROUND_TOP + FLOOR_H
	local pad = part(model, {
		Name = "Pad",
		Size = Vector3.new(PAD_SIZE, PAD_H, PAD_SIZE),
		CFrame = CFrame.new(x, floorTop + PAD_H / 2, z),
		Color = PAD_COLOR,
		CanCollide = false,
		CanQuery = false,
	})
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "StealPrompt"
	prompt.ActionText = "Steal"
	prompt.ObjectText = if species() then (species() :: Types.CritterSpecies).name else ""
	prompt.KeyboardKeyCode = Enum.KeyCode.F -- like a live pad
	prompt.HoldDuration = Config.LiveRaid.grabHoldSeconds + HOLD_GRACE
	prompt.MaxActivationDistance = PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
	prompt.PromptButtonHoldBegan:Connect(function(who: Player)
		TutorialDen.requestGrab(who, player)
	end)
	prompt.PromptButtonHoldEnded:Connect(function(who: Player)
		if who == player then
			holds[who] = nil
		end
	end)
	prompt.Parent = pad
	local den: Den = { plot = plot, model = model, pad = pad, critter = nil, floorTop = floorTop }
	dens[player] = den
	drawCritter(den)
	model.Parent = folder
	pcall(model.AddPersistentPlayer, model, player)
	player:SetAttribute(POSITION_ATTRIBUTE, pad.Position + Vector3.new(0, PAD_H / 2, 0))
	debugLog(`opened {player.Name}'s tutorial den in front of den {plot}`)
end

-- Opens or closes each player's den to match their onboarding (2 times a second).
local function sync()
	for _, player in Players:GetPlayers() do
		local plot = DenWorldService.getPlot(player)
		local want = plot ~= nil and eligible(player)
		local den = dens[player]
		if den and (not want or den.plot ~= plot) then
			closeDen(player)
			den = nil
		end
		if want and not den then
			local ok, err = pcall(openDen, player, plot :: number)
			if not ok then
				warn(`[TutorialDen] could not open {player.Name}'s den: {err}`)
				closeDen(player)
			end
		end
	end
end

local function check(player: Player, owner: Player): (boolean, string?)
	local den = dens[owner]
	local root = api.rootOf(player)
	return RaidRules.canGrabTutorial({
		isOwner = player == owner,
		open = den ~= nil and eligible(player),
		raiderReady = DenWorldService.getPlot(player) ~= nil and DataService.getProfile(player.UserId) ~= nil,
		busy = carries[player] ~= nil or api.busy(player),
		distance = if den and root then (root.Position - den.pad.Position).Magnitude else math.huge,
	})
end

-- The prompt asks for a grab on `owner`'s tutorial den; the server times the hold.
function TutorialDen.requestGrab(player: Player, owner: Player): (boolean, string?)
	if not allowGrab(player) then
		return false, "RateLimited"
	end
	local ok, reason = check(player, owner)
	if not ok then
		debugLog(`tutorial grab refused for {player.Name}: {reason}`)
		return false, reason
	end
	holds[player] = os.clock()
	return true, nil
end

local function startCarry(player: Player)
	local den = dens[player]
	local info = species()
	local root = api.rootOf(player)
	local humanoid = humanoidOf(player)
	if not (den and info and root and humanoid) then
		return
	end
	local prop = CarryProp.attach(root, info, "None")
	local walkSpeed = RaidRules.carryWalkSpeed(StarterPlayer.CharacterWalkSpeed, info.weight)
	local carry: Carry = {
		speciesId = info.id,
		walkSpeed = walkSpeed,
		lastPos = root.Position,
		lastAt = os.clock(),
		budget = RaidRules.carryStartBudget(),
		crossedStreet = false,
		floorY = den.floorTop,
		prop = prop,
	}
	carries[player] = carry
	local ok, err = pcall(function()
		humanoid.WalkSpeed = walkSpeed
		player:SetAttribute("CarryingUid", RaidRules.TUTORIAL_CRITTER_UID)
		player:SetAttribute("CarryingSpecies", info.id)
		if den.critter then
			den.critter.Parent = nil
		end
	end)
	if not ok then
		warn(`[TutorialDen] could not start the carry: {err}`)
		drop(player, carry, "start failed")
		return
	end
	debugLog(`{player.Name} grabbed the tutorial {info.id}`)
end

local function stepHolds()
	for player, startedAt in holds do
		local ok, reason = check(player, player)
		if not ok then
			holds[player] = nil
			debugLog(`tutorial hold cancelled for {player.Name}: {reason}`)
		elseif RaidRules.grabHoldDone(startedAt, os.clock()) then
			holds[player] = nil
			startCarry(player)
		end
	end
end

-- Home: the grant is the whole outcome. IncomeService claims the stealHome step itself.
local function escape(player: Player, carry: Carry)
	clearCarrier(player, carry)
	local ok, critter = pcall(IncomeService.grantTutorialCritter, player)
	local granted = ok and critter ~= nil
	if not ok then
		warn(`[TutorialDen] grantTutorialCritter failed for {player.Name}: {critter}`)
	end
	if granted then
		closeDen(player)
	else
		local den = dens[player]
		if den then
			pcall(drawCritter, den) -- still open: back on its pad for another try
		end
	end
	sendEnded(player, RaidRules.TUTORIAL_RAID_ID, granted, carry.speciesId)
	debugLog(`{player.Name} carried the tutorial critter home: {if granted then "granted" else "not granted"}`)
end

local function stepCarry(player: Player, carry: Carry)
	local root = api.rootOf(player)
	if player.Parent == nil or not root then
		return drop(player, carry, "raider gone")
	end
	if not dens[player] then
		return drop(player, carry, "den closed")
	end
	local now = os.clock()
	local pos = root.Position
	local delta = pos - carry.lastPos
	local plot = DenWorldService.getPlot(player)
	local outcome, budget, crossedStreet = RaidRules.carryStep({
		moved = Vector3.new(delta.X, 0, delta.Z).Magnitude,
		dt = now - carry.lastAt,
		walkSpeed = carry.walkSpeed,
		budget = carry.budget,
		height = pos.Y - carry.floorY,
		insideOwnDen = plot ~= nil and DenWorldService.isInsideDen(plot, pos),
		-- No defender den: the tutorial den is on the street, so every sample is "outside".
		wasInsideDefenderDen = false,
		insideDefenderDen = false,
		crossedStreet = carry.crossedStreet,
		lockdownActive = false,
		ownerDistance = nil, -- no owner, so nobody tags
	})
	carry.lastPos, carry.lastAt, carry.budget, carry.crossedStreet = pos, now, budget, crossedStreet
	if outcome == "Escape" then
		escape(player, carry)
	elseif outcome ~= "Continue" then
		drop(player, carry, outcome)
	end
end

local function stepCarries()
	for player, carry in carries do
		local ok, err = pcall(stepCarry, player, carry)
		if not ok then
			warn(`[TutorialDen] carry step failed for {player.Name}: {err}`)
			if carries[player] == carry then
				drop(player, carry, "error")
			end
		end
	end
end

function TutorialDen.isCarrying(player: Player): boolean
	return carries[player] ~= nil
end

-- Studio status line (RaidService's describe).
function TutorialDen.describe(): string
	local parts = {}
	for player, den in dens do
		local state = if carries[player] then "carrying" elseif holds[player] then "holding" else "open"
		table.insert(parts, `{player.Name}'s tutorial den (in front of den {den.plot}): {state}`)
	end
	return if #parts == 0 then "no tutorial dens" else table.concat(parts, "; ")
end

local function guard(name: string, step: () -> ())
	local ok, err = pcall(step)
	if not ok then
		warn(`[TutorialDen] {name} step failed: {err}`)
	end
end

function TutorialDen.start(injected: Api)
	if started then
		return
	end
	started = true
	api = injected
	folder = Instance.new("Folder")
	folder.Name = "TutorialDens"
	folder.Parent = workspace
	Players.PlayerRemoving:Connect(function(player: Player)
		closeDen(player)
		windows[player] = nil
	end)
	local clock, syncClock = 0, SYNC_TICK
	RunService.Heartbeat:Connect(function(dt: number)
		clock += dt
		syncClock += dt
		if clock >= TICK then
			clock = 0
			guard("holds", stepHolds)
			guard("carries", stepCarries)
		end
		if syncClock >= SYNC_TICK then
			syncClock = 0
			guard("sync", sync)
		end
	end)
end

return TutorialDen
