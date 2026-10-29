--!strict
--[[
	DenWorldService (owner: raid agent)

	Builds the night-lit map under workspace.World at server start, gives each player a den plot
	(Shared/Plots.luau decides which), spawns their character in it on every spawn, and frees and
	empties the plot when they leave. Layout numbers live in Plots.Layout.

	World swap seam (P2.3): every piece (ground, plaza, street lamps, den floor, border strips,
	pads, spawn, sign, vault door, lantern) is built through Raid/Kit.luau, so art named in
	Shared/WorldKit.luau replaces the greybox with no code change. Performance: each den is an
	Atomic streaming model (StreamingEnabled is a place setting; start() warns when it is off),
	its 30 pad parts are built once and pooled (hidden pads are unparented), pads carry no lights
	(one Lantern per den instead) and nothing here runs per frame.

	Server API (P0.4 economy and P0.5 live stealing build on it). Plots are numbers 1..8.
	  getPlot(player) -> number?               nil while the server is full (player waits)
	  getOwner(plot) -> Player?
	  getModel(plot) -> Model                  workspace.World.Dens.Den<plot>
	  getPads(plot) -> { BasePart }            all Plots.Layout.maxPads (30) pad parts, ordered by
	                                           index (Plots.padLocal). Pads past the shown count
	                                           are built but unparented. Economy.usablePadCount
	                                           caps use by den level, so #getPads is the physical
	                                           pad count.
	  getShownPadCount(plot) -> number         pads 1..n are in the world
	  setShownPads(plot, n)                    shows pads 1..n and pad n + 1 dim ("next to
	                                           unlock"). RaidService calls it with
	                                           WorldKit.shownPads(owner's den level). Idempotent.
	  getBorder(plot) -> Model                 4 neon strips, CanCollide/CanTouch/CanQuery off
	  getContents(plot) -> Folder              parent anything placed in the den here
	  getSpawnCFrame(plot) -> CFrame
	  isInsideDen(plot, position) -> boolean   X/Z footprint test, border line counts as inside
	  plotAt(position) -> number?              nil on the street, plaza or off the map
	  onPlotAssigned(fn(player, plot)) -> disconnect   also called at once for current owners
	  onPlotReleased(fn(player, plot)) -> disconnect   runs before the den is emptied
	Replicated for the client: Player attribute "Plot" (number), den Model attributes "Plot"
	and "OwnerUserId" (0 when empty), pad attribute "PadIndex". On release, Contents and any pad
	children except the pad's kit "Art" are destroyed and the den goes back to level-1 pads, so
	the next owner gets an empty den.
]]

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Plots = require(Shared:WaitForChild("Plots")) :: any
local WorldKit = require(Shared:WaitForChild("WorldKit")) :: any
local Kit = require(script.Parent.Parent:WaitForChild("Raid"):WaitForChild("Kit")) :: any

local L = Plots.Layout
local GROUND_TOP = 0.5 -- sits above a default Baseplate (top at 0) so nothing z-fights
local FLOOR_H = 0.4
local PAD_H = 0.4
local FLOOR_TOP = GROUND_TOP + FLOOR_H
local START_PADS: number = WorldKit.shownPads(1) -- what an empty den shows

-- Style bible night palette: navy, deep indigo, slate; neon only on accents.
local NAVY = Color3.fromHex("#0B1026")
local INDIGO = Color3.fromHex("#1B1F3B")
local SLATE = Color3.fromHex("#2E3552")
local LAMP_WARM = Color3.fromRGB(255, 196, 120)

type Den = {
	model: Model,
	pads: { BasePart }, -- all maxPads, pooled
	padFolder: Folder,
	nextPad: BasePart, -- the dim "next to unlock" marker
	shown: number,
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

local function part(parent: Instance?, props: { [string]: any }): Part
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
local function ghost(p: Part): Part
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	return p
end

-- Flat floor pieces: walked on, never touched or shadowed.
local function flat(p: Part): Part
	p.CanTouch = false
	p.CastShadow = false
	return p
end

local function setLighting()
	Lighting.ClockTime = 0
	Lighting.Brightness = 1.5
	Lighting.Ambient = Color3.fromRGB(45, 50, 80)
	Lighting.OutdoorAmbient = Color3.fromRGB(80, 90, 135)
	Lighting.EnvironmentDiffuseScale = 0.3
	Lighting.EnvironmentSpecularScale = 0.3
	Lighting.FogColor = Color3.fromRGB(40, 44, 92) -- blue-violet depth fog (style bible)
	Lighting.FogStart = 180
	Lighting.FogEnd = 650
end

-- A lamp (kit piece lamp_post) named `name`: thin post, neon head and one warm PointLight;
-- `base` is its bottom centre. Art that brings its own Light keeps it; otherwise the server
-- adds the one light to the art's highest part.
local function lamp(name: string, parent: Instance, base: CFrame, height: number, range: number): Model
	local model = Kit.decor("lamp_post", parent, base, function(greybox: Model)
		local post = flat(part(greybox, {
			Name = "Post",
			Size = Vector3.new(0.6, height, 0.6),
			CFrame = base * CFrame.new(0, height / 2, 0),
			Color = INDIGO,
		}))
		post.CanQuery = false
		ghost(part(greybox, {
			Name = "Head",
			Size = Vector3.new(1.6, 1.6, 1.6),
			CFrame = base * CFrame.new(0, height + 0.8, 0),
			Material = Enum.Material.Neon,
			Color = LAMP_WARM,
		}))
	end)
	model.Name = name
	if not model:FindFirstChildWhichIsA("Light", true) then
		local top: BasePart? = nil
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") and (top == nil or d.Position.Y > top.Position.Y) then
				top = d
			end
		end
		if top then
			local light = Instance.new("PointLight")
			light.Color = LAMP_WARM
			light.Range = range
			light.Brightness = 1.2
			light.Shadows = false
			light.Parent = top
		end
	end
	return model
end

-- Shows pads 1..count (clamped to the layout) and the next one dim. No work when unchanged.
local function showPads(den: Den, count: number)
	count = math.clamp(math.floor(count), 0, L.maxPads)
	if count == den.shown then
		return
	end
	den.shown = count
	for index, pad in den.pads do
		pad.Parent = if index <= count then den.padFolder else nil
	end
	if count < L.maxPads then
		Kit.pivot(den.nextPad, den.pads[count + 1].CFrame * CFrame.new(0, -PAD_H / 4, 0))
		den.nextPad.Parent = den.padFolder
	else
		den.nextPad.Parent = nil
	end
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
	-- Streams in and out as one unit, so a client never sees pads without their den.
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic

	local floor = flat(part(model, {
		Name = "Floor",
		Size = Vector3.new(L.plotSize, FLOOR_H, L.plotSize),
		CFrame = at(0, GROUND_TOP + FLOOR_H / 2, 0),
		Color = INDIGO,
	}))
	Kit.dress(floor, "den_base")
	model.PrimaryPart = floor

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
		local strip = ghost(part(border, {
			Name = `Strip{i}`,
			Size = s[1],
			CFrame = at(s[2], FLOOR_TOP + 0.25, s[3]),
			Material = Enum.Material.Neon,
			Color = accent,
		}))
		Kit.dress(strip, "den_border")
	end
	border.Parent = model

	local padFolder = Instance.new("Folder")
	padFolder.Name = "Pads"
	local padColor = SLATE:Lerp(accent, 0.15)
	local pads = {}
	for pad = 1, L.maxPads do
		local lx, lz = Plots.padLocal(pad)
		local p = flat(part(nil, {
			Name = `Pad{pad}`,
			Size = Vector3.new(L.padSize, PAD_H, L.padSize),
			CFrame = at(lx, FLOOR_TOP + PAD_H / 2, lz),
			Color = padColor,
		}))
		p:SetAttribute("PadIndex", pad)
		Kit.dress(p, "pad")
		pads[pad] = p
	end
	local nextPad = ghost(part(nil, {
		Name = "NextPad",
		Size = Vector3.new(L.padSize, PAD_H / 2, L.padSize),
		CFrame = pads[1].CFrame,
		Color = NAVY:Lerp(accent, 0.25),
	}))
	Kit.dress(nextPad, "pad_locked")
	padFolder.Parent = model

	local spawnPad = ghost(part(model, {
		Name = "Spawn",
		Size = Vector3.new(5, 0.1, 5),
		CFrame = at(0, FLOOR_TOP + 0.05, L.spawnZ),
		Material = Enum.Material.Neon,
		Color = accent,
	}))
	Kit.dress(spawnPad, "den_spawn")

	local sign = flat(part(model, {
		Name = "Sign",
		Size = Vector3.new(16, 3.5, 0.4),
		CFrame = at(0, FLOOR_TOP + 7, L.signZ),
		Color = NAVY,
	}))
	Kit.dress(sign, "den_sign")
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 20
	gui.LightInfluence = 0 -- readable at night
	gui.MaxDistance = 150
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = accent
	label.Text = "Empty Den"
	label.Parent = gui
	gui.Parent = sign

	local props = Instance.new("Folder")
	props.Name = "Props"
	local vaultBase = at(L.vaultX, FLOOR_TOP, L.vaultZ)
	local vault = Kit.decor("vault_door", props, vaultBase, function(door: Model)
		flat(part(door, {
			Name = "Door",
			Size = Vector3.new(6, 8, 1),
			CFrame = vaultBase * CFrame.new(0, 4, 0),
			Color = SLATE,
		}))
		ghost(part(door, {
			Name = "Trim",
			Size = Vector3.new(6.4, 0.4, 1.2),
			CFrame = vaultBase * CFrame.new(0, 8.2, 0),
			Material = Enum.Material.Neon,
			Color = accent,
		}))
	end)
	vault.Name = "VaultDoor"
	lamp("Lantern", props, at(L.lanternX, FLOOR_TOP, L.lanternZ), 7, 24)
	props.Parent = model

	local contents = Instance.new("Folder")
	contents.Name = "Contents"
	contents.Parent = model

	local den: Den = {
		model = model,
		pads = pads,
		padFolder = padFolder,
		nextPad = nextPad,
		shown = -1,
		border = border,
		contents = contents,
		signLabel = label,
		spawn = at(0, FLOOR_TOP + 3.5, L.spawnZ),
	}
	showPads(den, START_PADS)
	model.Parent = parent
	return den
end

-- BaseParts, lights and all instances under `root`.
local function census(root: Instance): (number, number, number)
	local parts, lights, all = 0, 0, 0
	for _, d in root:GetDescendants() do
		all += 1
		if d:IsA("BasePart") then
			parts += 1
		elseif d:IsA("Light") then
			lights += 1
		end
	end
	return parts, lights, all
end

local function buildWorld()
	local old = workspace:FindFirstChild("World")
	if old then
		old:Destroy()
	end
	Kit.preload()
	local world = Instance.new("Folder")
	world.Name = "World"

	local ground = flat(part(world, {
		Name = "Ground",
		Size = Vector3.new(320, 2, 240),
		CFrame = CFrame.new(0, GROUND_TOP - 1, 0),
		Color = NAVY,
	}))
	Kit.dress(ground, "ground")
	local plaza = flat(part(world, {
		Name = "Plaza",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(FLOOR_H, L.plazaRadius * 2, L.plazaRadius * 2),
		CFrame = CFrame.new(0, GROUND_TOP + FLOOR_H / 2, 0) * CFrame.Angles(0, 0, math.pi / 2),
		Color = SLATE,
	}))
	-- A cylinder lies on its side, so give the art an upright base and footprint explicitly.
	Kit.dress(plaza, "plaza", CFrame.new(0, GROUND_TOP, 0), Vector3.new(L.plazaRadius * 2, FLOOR_H, L.plazaRadius * 2))
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
	plazaSpawn.CastShadow = false
	plazaSpawn.Parent = world

	-- Warm lamp pools in the gaps between dens, on both sides of the street.
	local street = Instance.new("Folder")
	street.Name = "Street"
	local edge = L.rowOffset - L.plotSize / 2 - 4
	for _, spot in { { -1, -1 }, { -1, 1 }, { 1, -1 }, { 1, 1 } } do
		lamp("StreetLamp", street, CFrame.new(spot[1] * L.plotSpacing, GROUND_TOP, spot[2] * edge), 9, 30)
	end
	street.Parent = world
	-- Street props have no greybox: each appears once its kit art exists (WorldKit.PropSpots).
	local streetProps = Instance.new("Folder")
	streetProps.Name = "Props"
	for _, spot in WorldKit.PropSpots do
		if Kit.has(spot.piece) then
			local base = CFrame.new(spot.x, GROUND_TOP, spot.z) * CFrame.Angles(0, spot.yaw, 0)
			Kit.decor(spot.piece, streetProps, base, function() end)
		end
	end
	streetProps.Parent = world

	local densFolder = Instance.new("Folder")
	densFolder.Name = "Dens"
	densFolder.Parent = world
	for plot = 1, L.plotCount do
		dens[plot] = buildDen(plot, densFolder)
	end
	world.Parent = workspace

	local partCount, lightCount, instanceCount = census(world)
	print(
		`[DenWorld] built {L.plotCount} dens: {partCount} parts, {lightCount} lights, {instanceCount} instances;`
			.. ` streaming {if workspace.StreamingEnabled then "on" else "OFF"}, kit art for {Kit.artCount()} pieces`
	)
	local denParts = census(dens[1].model)
	local expected = WorldKit.denWorldParts(START_PADS)
	if RunService:IsStudio() and Kit.artCount() == 0 and denParts ~= expected then
		warn(`[DenWorld] den 1 has {denParts} parts; WorldKit.denWorldParts says {expected}: update the budget`)
	end
	if not workspace.StreamingEnabled then
		warn("[DenWorld] Workspace.StreamingEnabled is off: every client loads every den and pocket")
	end
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
			if child.Name ~= "Art" then
				child:Destroy()
			end
		end
	end
	showPads(den, START_PADS)
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

function DenWorldService.getShownPadCount(plot: number): number
	return dens[plot].shown
end

function DenWorldService.setShownPads(plot: number, count: number)
	showPads(dens[plot], count)
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
