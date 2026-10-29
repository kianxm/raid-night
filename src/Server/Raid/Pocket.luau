--!strict
--[[
	Pocket (owner: raid agent): pooled pocket-den models for async raids.

	One slot per raider, far off-map (ORIGIN, SLOT_SPACING apart), so with streaming no other
	client loads it. A slot's model is built the first time it is used and then reused: release()
	takes it out of the world (Parent = nil) and dress() lays the next raid's pads, critters, traps
	and guards on the same parts. Parts beyond what a raid needs stay unparented.

	Part budget per pocket: 1 floor + 4 walls + 1 gate, then 2 per laid-out pad (pad + critter),
	1 per trap (RaidRules.Pocket.maxTraps) and 1 per guard (maxGuards). A den with 6 pads, 4 traps
	and 2 guards is 24 parts; the most any pocket can hold is 6 + 60 + 12 + 4 = 82.

	Display only: every position the raid logic uses comes from RaidRules.pocketLayout and the
	server's own copy of it; no attribute here is ever read back.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local CritterCatalog = require(Shared.CritterCatalog)
local RaidRules = require(Shared.RaidRules)

local P = RaidRules.Pocket
local ORIGIN = Vector3.new(8000, 0, 0) -- floor top of slot 1; the map spans a few hundred studs
local SLOT_SPACING = 200
local WALL_HEIGHT = 8
local PROMPT_DISTANCE = 8
local TRAP_COLORS: { [string]: Color3 } = {
	SlowPuddle = Color3.fromRGB(90, 200, 255),
	Net = Color3.fromRGB(230, 230, 230),
	Sprinkler = Color3.fromRGB(60, 140, 255),
	AlarmMoth = Color3.fromRGB(255, 200, 60),
	Trapdoor = Color3.fromRGB(40, 30, 50),
}

export type Pocket = {
	slot: number,
	origin: Vector3, -- floor-top centre in the world
	model: Model,
	pads: { [number]: BasePart },
	orbs: { [number]: BasePart }, -- the critter drawn on each pad (a neon ball for now)
	traps: { BasePart },
	guards: { BasePart },
	inUse: boolean,
}

local Pocket = {}

local slots: { Pocket } = {}
local onPrompt: ((Player, Pocket, number) -> ())? = nil

local function part(name: string, size: Vector3, color: Color3, parent: Instance?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

function Pocket.world(pocket: Pocket, x: number, z: number, y: number?): Vector3
	return pocket.origin + Vector3.new(x, y or 0, z)
end

-- Pocket-local x, z and height above the floor of a world position.
function Pocket.toLocal(pocket: Pocket, position: Vector3): (number, number, number)
	local d = position - pocket.origin
	return d.X, d.Z, d.Y
end

local function build(slot: number): Pocket
	local origin = ORIGIN + Vector3.new(0, 0, (slot - 1) * SLOT_SPACING)
	local model = Instance.new("Model")
	model.Name = `Pocket{slot}`
	local pocket: Pocket = {
		slot = slot,
		origin = origin,
		model = model,
		pads = {},
		orbs = {},
		traps = {},
		guards = {},
		inUse = false,
	}
	local floor = part("Floor", Vector3.new(P.size, 2, P.size), Color3.fromRGB(28, 30, 60), model)
	floor.CFrame = CFrame.new(origin - Vector3.new(0, 1, 0))
	model.PrimaryPart = floor
	local half = P.size / 2
	for i, offset in
		{ Vector3.new(0, 0, -half), Vector3.new(0, 0, half), Vector3.new(-half, 0, 0), Vector3.new(half, 0, 0) }
	do
		local size = if i <= 2 then Vector3.new(P.size, WALL_HEIGHT, 2) else Vector3.new(2, WALL_HEIGHT, P.size)
		local wall = part("Wall", size, Color3.fromRGB(45, 40, 90), model)
		wall.CFrame = CFrame.new(origin + offset + Vector3.new(0, WALL_HEIGHT / 2, 0))
	end
	local gate = part("EscapeGate", Vector3.new(P.gateRadius * 2, 10, 1), Color3.fromRGB(80, 255, 160), model)
	gate.Material = Enum.Material.Neon
	gate.Transparency = 0.4
	gate.CanCollide = false
	gate.CFrame = CFrame.new(Pocket.world(pocket, 0, half - 1.5, 5))
	return pocket
end

local function padPart(pocket: Pocket, padIndex: number): BasePart
	local pad = pocket.pads[padIndex]
	if pad then
		return pad
	end
	local point = RaidRules.pocketPad(padIndex) :: RaidRules.Point
	local created = part(`Pad{padIndex}`, Vector3.new(8, 0.4, 8), Color3.fromRGB(70, 60, 140), nil)
	created.CFrame = CFrame.new(Pocket.world(pocket, point.x, point.z, 0.2))
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Grab"
	prompt.KeyboardKeyCode = Enum.KeyCode.F
	prompt.HoldDuration = 0.5
	prompt.MaxActivationDistance = PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Triggered:Connect(function(player: Player)
		if onPrompt and pocket.inUse then
			onPrompt(player, pocket, padIndex)
		end
	end)
	prompt.Parent = created
	pocket.pads[padIndex] = created
	local critter = part("Critter", Vector3.one * 2.5, Color3.new(1, 1, 1), nil)
	critter.Shape = Enum.PartType.Ball
	critter.Material = Enum.Material.Neon
	critter.CanCollide = false
	critter.CanQuery = false
	critter.Massless = true
	pocket.orbs[padIndex] = critter
	return created
end

-- Puts a critter back on its pad (anchored, unwelded). Also used for a dropped carry.
function Pocket.returnCritter(pocket: Pocket, padIndex: number)
	local critter = pocket.orbs[padIndex]
	local pad = pocket.pads[padIndex]
	if critter and pad then
		for _, child in critter:GetChildren() do
			child:Destroy()
		end
		critter.Anchored = true
		critter.CFrame = pad.CFrame + Vector3.new(0, 1.6, 0)
		critter.Parent = if pad.Parent then pocket.model else nil
	end
end

-- Moves a pad's critter onto the carrier's head.
function Pocket.attachCritter(pocket: Pocket, padIndex: number, root: BasePart)
	local critter = pocket.orbs[padIndex]
	if critter then
		critter.CFrame = root.CFrame * CFrame.new(0, 4.5, 0)
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = root
		weld.Part1 = critter
		weld.Parent = critter
		critter.Anchored = false
		critter.Parent = pocket.model -- not the character: a character reset must not destroy a pooled part
	end
end

-- A free slot, built on first use, or nil when every slot is taken.
function Pocket.acquire(): Pocket?
	for slot = 1, math.max(Players.MaxPlayers, 8) do
		local pocket = slots[slot]
		if not pocket then
			pocket = build(slot)
			slots[slot] = pocket
		end
		if not pocket.inUse then
			pocket.inUse = true
			return pocket
		end
	end
	return nil
end

-- Lays one raid on the slot. `species` maps padIndex -> species id for the pads to draw.
function Pocket.dress(pocket: Pocket, layout: RaidRules.PocketLayout, species: { [number]: string })
	for padIndex, pad in pocket.pads do
		pad.Parent = nil
		pocket.orbs[padIndex].Parent = nil
	end
	for padIndex in layout.pads do
		local pad = padPart(pocket, padIndex)
		local info = CritterCatalog.get(species[padIndex])
		pad.Parent = pocket.model
		local prompt = pad:FindFirstChildOfClass("ProximityPrompt")
		if prompt then
			prompt.ObjectText = if info then info.name else ""
		end
		pocket.orbs[padIndex].Color = if info then Color3.fromHex(info.palette[1]) else Color3.new(1, 1, 1)
		Pocket.returnCritter(pocket, padIndex)
	end
	for i, trap in layout.traps do
		local p = pocket.traps[i]
			or part("Trap", Vector3.new(P.trapRadius * 2, 0.3, P.trapRadius * 2), Color3.new(), nil)
		pocket.traps[i] = p
		p.CanCollide = false
		p.Color = TRAP_COLORS[trap.kind] or Color3.new(1, 0, 1)
		p.CFrame = CFrame.new(Pocket.world(pocket, trap.x, trap.z, 0.15))
		p.Parent = pocket.model
	end
	for i = #layout.traps + 1, #pocket.traps do
		pocket.traps[i].Parent = nil
	end
	for i in layout.guardRoutes do
		local g = pocket.guards[i] or part("Guard", Vector3.new(3, 5, 3), Color3.fromRGB(255, 70, 90), nil)
		pocket.guards[i] = g
		g.Material = Enum.Material.Neon
		g.CanCollide = false
		g.Parent = pocket.model
	end
	for i = #layout.guardRoutes + 1, #pocket.guards do
		pocket.guards[i].Parent = nil
	end
	pocket.model.Parent = workspace
end

function Pocket.moveGuard(pocket: Pocket, index: number, x: number, z: number)
	local g = pocket.guards[index]
	if g then
		g.CFrame = CFrame.new(Pocket.world(pocket, x, z, 2.5))
	end
end

function Pocket.release(pocket: Pocket)
	for padIndex in pocket.pads do
		Pocket.returnCritter(pocket, padIndex)
	end
	pocket.model.Parent = nil
	pocket.inUse = false
end

function Pocket.onPrompt(fn: (Player, Pocket, number) -> ())
	onPrompt = fn
end

return Pocket
