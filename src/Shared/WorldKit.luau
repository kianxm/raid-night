--!strict
--[[
	WorldKit (owner: raid agent): the world-art seam and the world's part budget. Pure.

	The seam (P2.3). Every world piece the server builds (den base, pads, border, vault door,
	traps, plaza, props, pocket walls...) is named here and built through one lookup in
	src/Server/Raid/Kit.luau:
	  1. a template named after the piece in ServerStorage.WorldKit (a Studio import), else
	  2. the piece's assetId below, loaded once at server start, else
	  3. today's procedural greybox placeholder.
	So the P2.2 art drops in by filling an assetId (or a ServerStorage template) with no code
	change. Ids are 0 until the kit is imported (D-057: no art credits tonight).

	Roles:
	  Anchor  Code depends on the placeholder part (it collides, prompts hang off it, code reads
	          its CFrame and Size). It is always built; art is laid over it as a child Model "Art"
	          and the part turns invisible, unless keepAnchor (a gameplay signal, like the border
	          strips that turn red in a Lockdown).
	  Decor   Nothing reads it. Art replaces the placeholder outright.

	Art authoring convention: one Model per piece, pivot at the bottom centre of its footprint,
	front (the -Z LookVector) facing the street (dens) or the escape gate (pockets). The server
	scales it uniformly to fit the anchor's X/Z footprint, anchors it and turns off collision,
	touch, query and shadows on every part. Scripts inside an asset are removed. artParts is the
	most parts (MeshParts count) one copy of the art may have: the budget below assumes it.

	Budget. Part and instance counts are what the greybox build makes, piece by piece. Pieces
	built by other services (IncomeService's critters and station) are estimates from their
	code today and are marked as such; if those change, change them here too.
]]

local Economy = require("./Economy")
local Plots = require("./Plots")
local RaidRules = require("./RaidRules")
local Types = require("./Types")

export type Role = "Anchor" | "Decor"
export type Piece = {
	assetId: number, -- 0 = no art yet
	role: Role,
	parts: number, -- BaseParts in the greybox placeholder
	artParts: number, -- the most parts the art for this piece may use
	keepAnchor: boolean?, -- Anchor only: the placeholder stays visible under the art
}

local WorldKit = {}

local function piece(role: Role, parts: number, artParts: number, keepAnchor: boolean?): Piece
	return { assetId = 0, role = role, parts = parts, artParts = artParts, keepAnchor = keepAnchor }
end

-- Piece ids match the asset manifest (assets/kit/manifest.json, P2.2) one to one; ids below
-- the "seam only" line are extra pieces the manifest does not list yet (greybox until it does).
WorldKit.Pieces = table.freeze({
	-- In the P2.2 manifest
	den_base = piece("Anchor", 1, 4), -- the den floor
	pad = piece("Anchor", 1, 1),
	vault_door = piece("Decor", 2, 4),
	plaza = piece("Anchor", 1, 6),
	lamp_post = piece("Decor", 2, 3), -- street lamps and each den's lantern
	trap_slow_puddle = piece("Anchor", 1, 2),
	trap_net = piece("Anchor", 1, 2),
	trap_sprinkler = piece("Anchor", 1, 2),
	trap_alarm_moth = piece("Anchor", 1, 2),
	trap_trapdoor = piece("Anchor", 1, 2),
	-- Street props: art only. No greybox (0 parts), so they appear once their art exists.
	barrel = piece("Decor", 0, 2),
	bench = piece("Decor", 0, 3),
	crate_stack = piece("Decor", 0, 3),
	fence_segment = piece("Decor", 0, 3),
	mailbox = piece("Decor", 0, 2),
	rock_cluster = piece("Decor", 0, 3),
	shrub = piece("Decor", 0, 2),
	tree_small = piece("Decor", 0, 3),
	wheelbarrow = piece("Decor", 0, 3),
	-- Seam only (not in the manifest yet)
	ground = piece("Anchor", 1, 4),
	den_border = piece("Anchor", 1, 1, true), -- one strip; turns red in a Lockdown
	pad_locked = piece("Anchor", 1, 1), -- the next pad to unlock, shown dim
	den_spawn = piece("Anchor", 1, 1),
	den_sign = piece("Anchor", 1, 3, true), -- the owner's name is a SurfaceGui on the anchor
	pocket_floor = piece("Anchor", 1, 4),
	pocket_wall = piece("Anchor", 1, 3),
	escape_gate = piece("Anchor", 1, 3, true),
	pocket_pad = piece("Anchor", 1, 1),
	guard = piece("Anchor", 1, 3),
} :: { [string]: Piece })

-- Every trap kind in Types.TrapKind, for the kit and its tests.
WorldKit.TrapKinds = table.freeze({ "SlowPuddle", "Net", "Sprinkler", "AlarmMoth", "Trapdoor" } :: { Types.TrapKind })

-- The kit piece for a pocket trap of this kind: "trap_slow_puddle" for "SlowPuddle".
function WorldKit.trapPiece(kind: string): string
	return "trap_" .. string.lower((string.gsub(kind, "(%l)(%u)", "%1_%2")))
end

-- Where the street props stand: world x, z (studs, ground level) and yaw (radians). On the
-- street edges and the map ends, clear of dens, the plaza and the lamps (tested).
export type PropSpot = { piece: string, x: number, z: number, yaw: number }
WorldKit.PropSpots = table.freeze({
	{ piece = "bench", x = 0, z = 31, yaw = math.pi },
	{ piece = "mailbox", x = -40, z = 31, yaw = math.pi },
	{ piece = "barrel", x = 40, z = -31, yaw = 0 },
	{ piece = "crate_stack", x = -140, z = 30, yaw = math.pi },
	{ piece = "wheelbarrow", x = 140, z = -30, yaw = 0 },
	{ piece = "fence_segment", x = -150, z = 0, yaw = math.pi / 2 },
	{ piece = "rock_cluster", x = 150, z = 0, yaw = -math.pi / 2 },
	{ piece = "shrub", x = -100, z = -31, yaw = 0 },
	{ piece = "tree_small", x = 100, z = 31, yaw = math.pi },
} :: { PropSpot })

-- How many pads a den shows (and can use) at this level: Economy's curve, capped by the layout.
function WorldKit.shownPads(denLevel: number): number
	return math.clamp(Economy.padCount(denLevel), 0, Plots.Layout.maxPads)
end

-- Fixed counts of the greybox world -------------------------------------------------------------

WorldKit.Map = table.freeze({
	streetLamps = 4,
	lights = 4, -- one PointLight per street lamp
	-- Instances other than parts: World, Dens, Street and Props Folders, a Model + PointLight per
	-- lamp.
	otherInstances = 4 + 4 * 2,
})

WorldKit.Den = table.freeze({
	borderStrips = 4,
	lights = 1, -- the lantern's PointLight; pads have none
	-- Instances other than parts that a den's own build makes: Model, Border Model, Pads Folder,
	-- Props Folder, vault door Model, lantern Model + PointLight, Sign SurfaceGui + TextLabel,
	-- Contents Folder.
	otherInstances = 10,
	padPromptInstances = 1, -- RaidService's StealPrompt on each shown pad
})

-- Estimates of what other services put in a den today (IncomeService, owner: economy).
WorldKit.External = table.freeze({
	critterParts = 2, -- Body + Glow
	critterInstances = 5, -- Model, Body, Glow, BillboardGui, TextLabel
	critterGuis = 1,
	stationParts = 4, -- EggConveyor, Egg, GlowJar, UpgradePlinth
	stationInstances = 8, -- Model, 4 parts, 3 ProximityPrompts
	crittersFolder = 1,
})

-- Ceilings the tests hold the world to. Phone target: 8 full dens on screen. "WithArt" prices
-- every piece at its artParts ceiling; an Anchor's invisible placeholder still counts (memory),
-- although the renderer skips it.
WorldKit.Budget = table.freeze({
	denParts = 110, -- one den at 30 pads with 30 critters, everything in it
	denInstances = 260,
	denPartsWithArt = 160,
	mapParts = 900, -- the whole main map: 8 full dens plus streets and plaza
	mapInstances = 2100,
	mapPartsWithArt = 1300,
	mapLights = 16,
	pocketParts = 90, -- one pocket den at its fullest
	pocketPartsWithArt = 170,
})

export type Cost = { parts: number, instances: number, lights: number, guis: number }

local P = WorldKit.Pieces

-- Parts one copy of a piece costs: its greybox, or with art its art ceiling (plus the anchor
-- that stays under an Anchor piece's art).
local function partsOf(name: string, withArt: boolean?): number
	local info = P[name]
	assert(info, `unknown kit piece {name}`)
	if not withArt then
		return info.parts
	end
	return if info.role == "Anchor" then info.parts + info.artParts else info.artParts
end
WorldKit.partsOf = partsOf

-- One den: its own pieces at `shownPads`, plus `critters` pad critters and the economy station.
function WorldKit.denCost(shownPads: number, critters: number, withArt: boolean?): Cost
	local maxPads = Plots.Layout.maxPads
	shownPads = math.clamp(shownPads, 0, maxPads)
	critters = math.clamp(critters, 0, shownPads)
	local D, X = WorldKit.Den, WorldKit.External
	local locked = if shownPads < maxPads then 1 else 0
	local own = partsOf("den_base", withArt)
		+ D.borderStrips * partsOf("den_border", withArt)
		+ partsOf("den_spawn", withArt)
		+ partsOf("den_sign", withArt)
		+ partsOf("vault_door", withArt)
		+ partsOf("lamp_post", withArt)
		+ shownPads * partsOf("pad", withArt)
		+ locked * partsOf("pad_locked", withArt)
	local parts = own + X.stationParts + critters * X.critterParts
	local instances = own
		+ D.otherInstances
		+ shownPads * D.padPromptInstances
		+ X.stationInstances
		+ X.crittersFolder
		+ critters * X.critterInstances
	return {
		parts = parts,
		instances = instances,
		lights = D.lights,
		guis = 1 + critters * X.critterGuis, -- the sign, and a name tag per critter
	}
end

-- Parts DenWorldService itself builds for one den (no critters, no station), greybox: what it
-- checks against the live count in Studio.
function WorldKit.denWorldParts(shownPads: number): number
	return WorldKit.denCost(shownPads, 0).parts - WorldKit.External.stationParts
end

-- The main map's own pieces: ground, plaza, plaza spawn, street lamps and street props.
function WorldKit.mapBaseCost(withArt: boolean?): Cost
	local parts = partsOf("ground", withArt) + partsOf("plaza", withArt) + 1
	parts += WorldKit.Map.streetLamps * partsOf("lamp_post", withArt)
	local props = 0
	for _, spot in WorldKit.PropSpots do
		local n = partsOf(spot.piece, withArt)
		parts += n
		props += if n > 0 then 1 else 0 -- a prop's Model exists only when it has parts
	end
	return {
		parts = parts,
		instances = parts + WorldKit.Map.otherInstances + props,
		lights = WorldKit.Map.lights,
		guis = 0,
	}
end

-- The whole main map with every den at `shownPads` pads, `critters` of them full.
function WorldKit.mapCost(shownPads: number, critters: number, withArt: boolean?): Cost
	local base = WorldKit.mapBaseCost(withArt)
	local den = WorldKit.denCost(shownPads, critters, withArt)
	local n = Plots.Layout.plotCount
	return {
		parts = base.parts + n * den.parts,
		instances = base.instances + n * den.instances,
		lights = base.lights + n * den.lights,
		guis = base.guis + n * den.guis,
	}
end

-- One pocket den: floor, 4 walls, gate, then a pad and a critter orb per laid-out pad, a part per
-- trap and per guard (src/Server/Raid/Pocket.luau). With art, traps are priced at the costliest
-- trap piece.
function WorldKit.pocketParts(pads: number, traps: number, guards: number, withArt: boolean?): number
	local Pk = RaidRules.Pocket
	pads = math.clamp(pads, 0, Pk.maxPads)
	traps = math.clamp(traps, 0, Pk.maxTraps)
	guards = math.clamp(guards, 0, Pk.maxGuards)
	local trap = 0
	for _, kind in WorldKit.TrapKinds do
		trap = math.max(trap, partsOf(WorldKit.trapPiece(kind), withArt))
	end
	return partsOf("pocket_floor", withArt)
		+ 4 * partsOf("pocket_wall", withArt)
		+ partsOf("escape_gate", withArt)
		+ pads * (partsOf("pocket_pad", withArt) + 1)
		+ traps * trap
		+ guards * partsOf("guard", withArt)
end

return WorldKit
