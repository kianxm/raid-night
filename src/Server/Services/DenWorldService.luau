--!strict
--[[
	DenWorldService (owner: raid agent)

	Builds the night-lit greybox map under workspace.World at server start, gives each player a
	den plot (Shared/Plots.luau decides which), spawns their character in it on every spawn, and
	frees and empties the plot when they leave. Layout numbers live in Plots.Layout.

	Server API (P0.4 economy and P0.5 live stealing build on it). Plots are numbers 1..8.
	  getPlot(player) -> number?               nil while the server is full (player waits)
	  getOwner(plot) -> Player?
	  getModel(plot) -> Model                  workspace.World.Dens.Den<plot>
	  getPads(plot) -> { BasePart }            ordered 1..6, front row (1-3) then back row
	  getBorder(plot) -> Model                 4 neon strips, CanCollide/CanTouch/CanQuery off
	  getContents(plot) -> Folder              parent anything placed in the den here
	  getSpawnCFrame(plot) -> CFrame
	  isInsideDen(plot, position) -> boolean   X/Z footprint test, border line counts as inside
	  plotAt(position) -> number?              nil on the street, plaza or off the map
	  onPlotAssigned(fn(player, plot)) -> disconnect   also called at once for current owners
	  onPlotReleased(fn(player, plot)) -> disconnect   runs before the den is emptied
	Replicated for the client: Player attribute "Plot" (number), den Model attributes "Plot"
	and "OwnerUserId" (0 when empty). On release, Contents and any pad children except the
	pad's "Light" are destroyed, so the next owner gets an empty den.
]]

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Plots = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Plots")) :: any

local L = Plots.Layout
local GROUND_TOP = 0.5 -- sits above a default Baseplate (top at 0) so nothing z-fights
local FLOOR_H = 0.4
local PAD_H = 0.4
local FLOOR_TOP = GROUND_TOP + FLOOR_H

type Den = {
	model: Model,
	pads: { BasePart },
	border: Model,
	contents: Folder,
	signLabel: TextLabel,
	spawn: CFrame,
}

type Callback = (Player, number) -> ()

local ACCENTS = {
	Color3.fromRGB(90, 200, 255),
	Color3.fromRGB(255, 120, 200),
	Color3.fromRGB(140, 255, 150),
	Color3.fromRGB(255, 200, 90),
	Color3.fromRGB(180, 140, 255),
	Color3.fromRGB(255, 130, 100),
	Color3.fromRGB(100, 255, 230),
	Color3.fromRGB(240, 240, 120),
}

local state = Plots.new()
local dens: { Den } = {}
local assigned: { Callback } = {}
local released: { Callback } = {}
local started = false

local DenWorldService = {}

local function part(parent: Instance, props: { [string]: any }): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in props do
		(p :: any)[key] = value
	end
	p.Parent = parent
	return p
end

-- Ghost parts are seen but never touched: no collision, touch events or raycast hits.
local function ghost(p: BasePart)
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
end

local function setLighting()
	Lighting.ClockTime = 0
	Lighting.Brightness = 1.5
	Lighting.Ambient = Color3.fromRGB(45, 50, 80)
	Lighting.OutdoorAmbient = Color3.fromRGB(80, 90, 135)
	Lighting.EnvironmentDiffuseScale = 0.3
	Lighting.EnvironmentSpecularScale = 0.3
	Lighting.FogColor = Color3.fromRGB(12, 16, 32)
	Lighting.FogStart = 180
	Lighting.FogEnd = 650
end

local function buildDen(plot: number, parent: Instance): Den
	local _, _, facing = Plots.center(plot)
	local forward = Vector3.new(0, 0, facing)
	local function at(localX: number, y: number, localZ: number): CFrame
		local x, z = Plots.toWorld(plot, localX, localZ)
		local pos = Vector3.new(x, y, z)
		return CFrame.lookAt(pos, pos + forward) -- front face points at the street
	end
	local accent = ACCENTS[plot]
	local half = L.plotSize / 2

	local model = Instance.new("Model")
	model.Name = `Den{plot}`
	model:SetAttribute("Plot", plot)
	model:SetAttribute("OwnerUserId", 0)

	model.PrimaryPart = part(model, {
		Name = "Floor",
		Size = Vector3.new(L.plotSize, FLOOR_H, L.plotSize),
		CFrame = at(0, GROUND_TOP + FLOOR_H / 2, 0),
		Color = Color3.fromRGB(34, 38, 60),
	})

	local border = Instance.new("Model")
	border.Name = "Border"
	local t = 0.6
	local strips = {
		{ Vector3.new(L.plotSize, 0.5, t), 0, half - t / 2 },
		{ Vector3.new(L.plotSize, 0.5, t), 0, -half + t / 2 },
		{ Vector3.new(t, 0.5, L.plotSize - 2 * t), half - t / 2, 0 },
		{ Vector3.new(t, 0.5, L.plotSize - 2 * t), -half + t / 2, 0 },
	}
	for i, s in strips do
		ghost(part(border, {
			Name = `Strip{i}`,
			Size = s[1],
			CFrame = at(s[2], FLOOR_TOP + 0.25, s[3]),
			Material = Enum.Material.Neon,
			Color = accent,
			Transparency = 0.35,
		}))
	end
	border.Parent = model

	local padFolder = Instance.new("Folder")
	padFolder.Name = "Pads"
	local pads = {}
	for pad = 1, L.padsPerPlot do
		local lx, lz = Plots.padLocal(pad)
		local p = part(padFolder, {
			Name = `Pad{pad}`,
			Size = Vector3.new(L.padSize, PAD_H, L.padSize),
			CFrame = at(lx, FLOOR_TOP + PAD_H / 2, lz),
			Color = Color3.fromRGB(70, 78, 112),
		})
		p:SetAttribute("PadIndex", pad)
		local light = Instance.new("PointLight")
		light.Name = "Light"
		light.Color = accent:Lerp(Color3.new(1, 1, 1), 0.5)
		light.Range = 10
		light.Brightness = 0.8
		light.Shadows = false
		light.Parent = p
		pads[pad] = p
	end
	padFolder.Parent = model

	ghost(part(model, {
		Name = "Spawn",
		Size = Vector3.new(5, 0.1, 5),
		CFrame = at(0, FLOOR_TOP + 0.05, L.spawnZ),
		Material = Enum.Material.Neon,
		Color = accent,
		Transparency = 0.5,
	}))

	local sign = part(model, {
		Name = "Sign",
		Size = Vector3.new(16, 3.5, 0.4),
		CFrame = at(0, FLOOR_TOP + 7, L.signZ),
		Color = Color3.fromRGB(22, 26, 44),
	})
	sign.CastShadow = false
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 30
	gui.LightInfluence = 0 -- readable at night
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = accent
	label.Text = "Empty Den"
	label.Parent = gui
	gui.Parent = sign

	local contents = Instance.new("Folder")
	contents.Name = "Contents"
	contents.Parent = model

	model.Parent = parent
	return {
		model = model,
		pads = pads,
		border = border,
		contents = contents,
		signLabel = label,
		spawn = at(0, FLOOR_TOP + 3.5, L.spawnZ),
	}
end

local function buildWorld()
	local old = workspace:FindFirstChild("World")
	if old then
		old:Destroy()
	end
	local world = Instance.new("Folder")
	world.Name = "World"

	part(world, {
		Name = "Ground",
		Size = Vector3.new(320, 2, 240),
		CFrame = CFrame.new(0, GROUND_TOP - 1, 0),
		Color = Color3.fromRGB(18, 22, 38),
	})
	part(world, {
		Name = "Plaza",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(FLOOR_H, L.plazaRadius * 2, L.plazaRadius * 2),
		CFrame = CFrame.new(0, GROUND_TOP + FLOOR_H / 2, 0) * CFrame.Angles(0, 0, math.pi / 2),
		Color = Color3.fromRGB(44, 50, 80),
	})
	-- Fallback spawn for anyone without a den (server full). Den spawns are code-driven.
	local plazaSpawn = Instance.new("SpawnLocation")
	plazaSpawn.Name = "PlazaSpawn"
	plazaSpawn.Anchored = true
	plazaSpawn.Neutral = true
	plazaSpawn.Duration = 0
	plazaSpawn.Size = Vector3.new(6, 0.4, 6)
	plazaSpawn.CFrame = CFrame.new(0, FLOOR_TOP + 0.2, 0)
	plazaSpawn.Material = Enum.Material.Neon
	plazaSpawn.Color = Color3.fromRGB(120, 130, 200)
	plazaSpawn.Parent = world

	local densFolder = Instance.new("Folder")
	densFolder.Name = "Dens"
	densFolder.Parent = world
	for plot = 1, L.plotCount do
		dens[plot] = buildDen(plot, densFolder)
	end
	world.Parent = workspace

	local partCount, lightCount = 0, 0
	for _, d in world:GetDescendants() do
		if d:IsA("BasePart") then
			partCount += 1
		elseif d:IsA("Light") then
			lightCount += 1
		end
	end
	print(`[DenWorld] built {L.plotCount} dens: {partCount} parts, {lightCount} lights`)
end

local function fire(list: { Callback }, player: Player, plot: number)
	for _, fn in table.clone(list) do
		task.spawn(fn, player, plot)
	end
end

local function subscribe(list: { Callback }, fn: Callback): () -> ()
	table.insert(list, fn)
	return function()
		local i = table.find(list, fn)
		if i then
			table.remove(list, i)
		end
	end
end

local function moveToDen(player: Player, plot: number)
	local character = player.Character
	if character and character.Parent then
		character:PivotTo(dens[plot].spawn)
	end
end

local function givePlot(player: Player, plot: number)
	local den = dens[plot]
	player:SetAttribute("Plot", plot)
	den.model:SetAttribute("OwnerUserId", player.UserId)
	den.signLabel.Text = `{player.DisplayName}'s Den`
	moveToDen(player, plot)
	fire(assigned, player, plot)
end

local function emptyDen(plot: number)
	local den = dens[plot]
	den.contents:ClearAllChildren()
	for _, pad in den.pads do
		for _, child in pad:GetChildren() do
			if child.Name ~= "Light" then
				child:Destroy()
			end
		end
	end
	den.model:SetAttribute("OwnerUserId", 0)
	den.signLabel.Text = "Empty Den"
end

local function onCharacterAdded(player: Player, character: Model)
	if not character:WaitForChild("HumanoidRootPart", 10) then
		return
	end
	local plot = Plots.plotOf(state, player.UserId) -- re-read: the plot may have changed while waiting
	if plot and player.Character == character then
		character:PivotTo(dens[plot].spawn)
	end
end

local function onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
	local plot = Plots.assign(state, player.UserId)
	if plot then
		givePlot(player, plot)
	else
		warn(`[DenWorld] server full, {player.Name} waits in the plaza for a free den`)
	end
end

-- Empties a released den and hands it to the first waiting player still in the server.
local function freePlot(plot: number, nextUserId: number?)
	emptyDen(plot)
	while nextUserId do
		local nextPlayer = Players:GetPlayerByUserId(nextUserId)
		if nextPlayer then
			givePlot(nextPlayer, plot)
			return
		end
		nextUserId = select(2, Plots.release(state, nextUserId)) -- they left; free it again
	end
end

local function onPlayerRemoving(player: Player)
	local plot, nextUserId = Plots.release(state, player.UserId)
	player:SetAttribute("Plot", nil)
	if not plot then
		return
	end
	fire(released, player, plot)
	freePlot(plot, nextUserId)
end

function DenWorldService.start()
	if started then
		return
	end
	started = true
	setLighting()
	buildWorld()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
end

function DenWorldService.getPlot(player: Player): number?
	return Plots.plotOf(state, player.UserId)
end

function DenWorldService.getOwner(plot: number): Player?
	local userId = Plots.ownerOf(state, plot)
	return if userId then Players:GetPlayerByUserId(userId) else nil
end

function DenWorldService.getModel(plot: number): Model
	return dens[plot].model
end

function DenWorldService.getPads(plot: number): { BasePart }
	return table.clone(dens[plot].pads)
end

function DenWorldService.getBorder(plot: number): Model
	return dens[plot].border
end

function DenWorldService.getContents(plot: number): Folder
	return dens[plot].contents
end

function DenWorldService.getSpawnCFrame(plot: number): CFrame
	return dens[plot].spawn
end

function DenWorldService.isInsideDen(plot: number, position: Vector3): boolean
	return Plots.isInside(plot, position.X, position.Z)
end

function DenWorldService.plotAt(position: Vector3): number?
	return Plots.plotAt(position.X, position.Z)
end

-- Studio test stand-ins (RaidService's TestHook, decision D-010) --------------------------------

-- Gives a free den to a fake owner so one client has a den to raid. The id must be a reserved
-- test id (<= -1_000_000): Studio's Local Server players are -1, -2, ... and must never be
-- matched. Never queues: returns nil when no den is free. Listeners are not called (they expect a
-- Player), and getOwner(plot) stays nil.
function DenWorldService.assignStandIn(userId: number, displayName: string): number?
	assert(RunService:IsStudio(), "stand-in dens are Studio-only")
	assert(userId <= -1_000_000, "stand-in userIds are reserved test ids (<= -1000000)")
	assert(Players:GetPlayerByUserId(userId) == nil, "a player has this userId")
	assert(Plots.plotOf(state, userId) == nil, "this stand-in already has a den")
	if Plots.freeCount(state) == 0 then
		return nil
	end
	local plot = Plots.assign(state, userId) :: number
	dens[plot].model:SetAttribute("OwnerUserId", userId)
	dens[plot].signLabel.Text = `{displayName}'s Den`
	return plot
end

function DenWorldService.releaseStandIn(userId: number)
	assert(RunService:IsStudio(), "stand-in dens are Studio-only")
	assert(userId <= -1_000_000, "stand-in userIds are reserved test ids (<= -1000000)")
	local plot, nextUserId = Plots.release(state, userId)
	if plot then
		freePlot(plot, nextUserId)
	end
end

function DenWorldService.onPlotAssigned(fn: Callback): () -> ()
	for plot = 1, L.plotCount do
		local owner = DenWorldService.getOwner(plot)
		if owner then
			task.spawn(fn, owner, plot)
		end
	end
	return subscribe(assigned, fn)
end

function DenWorldService.onPlotReleased(fn: Callback): () -> ()
	return subscribe(released, fn)
end

return DenWorldService
