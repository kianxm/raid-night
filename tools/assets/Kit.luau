--!strict
--[[
	World kit briefs (task P2.2). Pure: no file access, so tests/specs/AssetKit.spec can check it.
	tools/assets/build_kit.luau writes the results to assets/kit/.

	Each piece has a purpose, a size in studs, a mobile budget (triangles and Roblox parts), the
	glow accent, an image prompt and 3D notes. Image prompts reuse the critter STYLE block's
	finish words and a kit AVOID block, and name colors in words (hex stays out of prompts).

	Piece ids are PROPOSED for the raid agent (P2.3 had no kit lookup on its branch when this
	was written); trap ids are "trap_" plus the snake_case TrapKind from src/Shared/Types.luau.
	Sizes that come from game code (pads, den, plaza, trap radius) are quoted from
	src/Shared/Plots.luau and RaidRules.Pocket; change them here if those change.
]]

local Kit = {}

Kit.STYLE = "Stylized 3D game environment piece for a cozy nighttime game. Chunky toy-like shapes, "
	.. "rounded edges, oversized simple forms, smooth matte vinyl toy surface with toon shading, flat colors, "
	.. "no fine detail, no photoreal textures. Dark night navy, deep indigo and slate palette, lit by cool "
	.. "moonlight from above. Isolated on a plain dark background, three-quarter view, whole object in frame."

Kit.AVOID = "Avoid photorealism, text, letters, numbers, labels, logos, watermarks, frames, borders, "
	.. "captions, characters, creatures, people, existing franchise props or buildings, weapons, gore, "
	.. "scary or grim features, extra glowing parts beyond the one named."

-- Glow colors in words. Kept to a few accents so the world stays calm and critters still pop.
Kit.GLOW_WORDS = {
	lamp = "warm amber lamp glow",
	moon = "soft pale blue moonlight glow",
	alert = "bright warning orange glow",
	mint = "soft mint green glow",
	violet = "soft violet glow",
}

export type Piece = {
	id: string,
	name: string,
	group: string, -- den | trap | world | prop
	purpose: string,
	size: { x: number, y: number, z: number }, -- studs
	triangles: number, -- mobile budget for the mesh
	parts: number, -- Roblox Part budget if built from primitives or split into sub-meshes
	repeats: number, -- most that may be on screen at once; sets how strict the budget is
	glow: string?, -- key into GLOW_WORDS, nil for no glow
	glowAt: string?,
	subject: string,
	notes: string, -- 3D notes
	texture: number,
}

local function piece(
	id: string,
	name: string,
	group: string,
	purpose: string,
	size: { x: number, y: number, z: number },
	budget: { triangles: number, parts: number, repeats: number },
	glow: { key: string, at: string }?,
	subject: string,
	notes: string
): Piece
	return {
		id = id,
		name = name,
		group = group,
		purpose = purpose,
		size = size,
		triangles = budget.triangles,
		parts = budget.parts,
		repeats = budget.repeats,
		glow = if glow then glow.key else nil,
		glowAt = if glow then glow.at else nil,
		subject = subject,
		notes = notes,
		texture = 512,
	}
end

local function prop(
	id: string,
	name: string,
	w: number,
	h: number,
	subject: string,
	glow: { key: string, at: string }?,
	budget: { triangles: number, parts: number, repeats: number },
	notes: string
): Piece
	return piece(
		id,
		name,
		"prop",
		`Street and den dressing: {string.lower(name)}. Never blocks a pad.`,
		{ x = w, y = h, z = w },
		budget,
		glow,
		subject,
		notes
	)
end

Kit.PIECES = {
	piece(
		"den_base",
		"Den base",
		"den",
		"The floor, low border wall and back-wall nook of one player's den; critters sit on pads on top of it.",
		{ x = 56, y = 4, z = 56 },
		{ triangles = 3000, parts = 12, repeats = 8 },
		{ key = "moon", at = "a thin strip of light along the top of the low border wall" },
		"a square cozy den floor made of dark slate flagstones with a low rounded border wall and a small arched "
			.. "nook in the back wall, seen from above at a three-quarter angle, empty floor",
		"Modular: floor tiles plus four border segments so the pad and spawn layout (Plots.luau) sits on top. "
			.. "Flat top for pads, border strip on its own emissive material. Pivot at floor centre, top at y=0."
	),
	piece(
		"pad",
		"Critter pad",
		"den",
		"The round stand one critter sits on (6 to 30 per den); glows in the critter's color in-engine.",
		{ x = 8, y = 0.6, z = 8 },
		{ triangles = 300, parts = 3, repeats = 30 },
		{ key = "lamp", at = "a ring inset around the top edge" },
		"a low round stone pedestal pad with a rounded rim and a shallow dish on top, empty",
		"Cheapest and most repeated piece: no undercut, no tiny detail. Glow ring on its own emissive material "
			.. "so the engine can recolor it per critter and dim it when empty. Pivot centre of the base."
	),
	piece(
		"vault_door",
		"Vault door",
		"den",
		"The chunky round door to the vault, where critters are safe and earn 50%; raiders cannot touch it.",
		{ x = 8, y = 10, z = 2 },
		{ triangles = 1500, parts = 6, repeats = 8 },
		{ key = "mint", at = "the round lock wheel in the centre of the door" },
		"a big round toy-like vault door set in a thick arched stone frame, a chunky lock wheel in the middle, "
			.. "rounded bolts around the edge, front view, closed",
		"Door and frame as one mesh, lock wheel a separate emissive mesh so a script can spin it. Pivot at the "
			.. "bottom centre, front faces -Z. Should read as safe and friendly, not menacing."
	),
	piece(
		"trap_slow_puddle",
		"Slow puddle trap",
		"trap",
		"Pocket-den trap (SlowPuddle): a sticky puddle that slows a raider who steps in it.",
		{ x = 6, y = 0.5, z = 6 },
		{ triangles = 400, parts = 3, repeats = 12 },
		{ key = "violet", at = "the surface of the puddle" },
		"a round puddle of thick glossy goo on the ground with a few rounded bubbles, flat and low",
		"Diameter 6 matches Pocket.trapRadius 3. Flat disc with a few bumps; goo surface on its own emissive "
			.. "material, or a Part cylinder plus decal if the mesh costs too much. Pivot centre of the base."
	),
	piece(
		"trap_net",
		"Net trap",
		"trap",
		"Pocket-den trap (Net): a net that drops and holds a raider briefly.",
		{ x = 6, y = 4, z = 6 },
		{ triangles = 900, parts = 5, repeats = 12 },
		{ key = "alert", at = "the small trigger plate on the ground" },
		"a chunky toy-like net trap: a round folded rope net bundle resting on a tripod of stubby wooden posts "
			.. "over a round trigger plate, tidy and cartoonish",
		"Two states wanted: set (this mesh) and sprung, which the engine does by tweening the net down, so net "
			.. "and posts are separate meshes. Thick cords, no thin strands. Pivot centre of the base."
	),
	piece(
		"trap_sprinkler",
		"Sprinkler trap",
		"trap",
		"Pocket-den trap (Sprinkler): sprays and soaks a raider, shoving them off course.",
		{ x = 4, y = 4, z = 4 },
		{ triangles = 800, parts = 4, repeats = 12 },
		{ key = "moon", at = "the nozzle head" },
		"a chunky toy-like garden sprinkler on a short stubby pipe stand with a round rotating nozzle head",
		"Nozzle head is a separate mesh so it can spin; the water spray is a particle emitter in-engine, not "
			.. "modeled. Pivot centre of the base."
	),
	piece(
		"trap_alarm_moth",
		"Alarm moth trap",
		"trap",
		"Pocket-den trap (AlarmMoth): a lantern that wakes the guards and sends them chasing.",
		{ x = 3, y = 5, z = 3 },
		{ triangles = 700, parts = 4, repeats = 12 },
		{ key = "alert", at = "the lantern glass" },
		"a chunky toy-like standing lantern on a short post with a round glass bulb and two small round "
			.. "wing-shaped fins on its sides, cute and rounded",
		"No moth creature: the wings are fins on the lantern, so it stays a prop. Glass bulb on its own "
			.. "emissive material, pulsed by script when triggered. Pivot centre of the base."
	),
	piece(
		"trap_trapdoor",
		"Trapdoor trap",
		"trap",
		"Pocket-den trap (Trapdoor): a floor hatch that drops a raider back toward the gate.",
		{ x = 6, y = 0.6, z = 6 },
		{ triangles = 350, parts = 3, repeats = 12 },
		{ key = "alert", at = "a thin seam around the hatch" },
		"a square wooden trapdoor hatch set flush in a stone floor tile, chunky hinge bars and a round ring "
			.. "handle, seen from above at a three-quarter angle, closed",
		"Hatch is a separate mesh from the surrounding tile so it can swing open. No detail smaller than 0.3 "
			.. "studs. Pivot at the hinge edge for the hatch, centre for the tile."
	),
	piece(
		"plaza",
		"Plaza",
		"world",
		"The round hub at the centre of the street where the 8 dens meet; first thing a player sees.",
		{ x = 48, y = 3, z = 48 },
		{ triangles = 4000, parts = 10, repeats = 1 },
		{ key = "lamp", at = "the pool of light under the centrepiece" },
		"a round town plaza paved in dark slate cobblestones with a ring of low planters and a small chunky "
			.. "stone fountain in the middle, seen from above at a three-quarter angle, empty of people",
		"Diameter 48 matches Plots plazaRadius 24. One-off, so it gets the biggest budget in the kit. "
			.. "Fountain water on its own emissive material. Pivot at plaza centre, top at y=0."
	),
	prop(
		"lamp_post",
		"Lamp post",
		1,
		9,
		"a chunky street lamp post with a round glass lamp on a curled top",
		{ key = "lamp", at = "the lamp glass" },
		{ triangles = 500, parts = 3, repeats = 40 },
		"Warm lamp pools are the world's key light, so this prop matters most. The light is a PointLight in-engine."
	),
	prop(
		"bench",
		"Bench",
		5,
		3,
		"a chunky rounded wooden park bench with stubby legs",
		nil,
		{ triangles = 350, parts = 2, repeats = 12 },
		"No glow material."
	),
	prop(
		"crate_stack",
		"Crate stack",
		5,
		5,
		"two chunky wooden crates stacked, with a small lantern on top, no markings on the crates",
		{ key = "lamp", at = "the small lantern on top" },
		{ triangles = 450, parts = 3, repeats = 16 },
		"Lantern on its own emissive material."
	),
	prop(
		"barrel",
		"Barrel",
		3,
		3.5,
		"a chunky round wooden barrel with thick hoops",
		nil,
		{ triangles = 300, parts = 2, repeats = 16 },
		"No glow material."
	),
	prop(
		"fence_segment",
		"Fence segment",
		8,
		3,
		"a short section of chunky rounded wooden picket fence with a stone post at each end",
		nil,
		{ triangles = 350, parts = 2, repeats = 40 },
		"Tiles end to end along the den borders; keep both ends identical so it repeats."
	),
	prop(
		"mailbox",
		"Mailbox",
		1.5,
		3.5,
		"a chunky toy-like curved-top mailbox on a short post with a small raised flag",
		{ key = "alert", at = "the small flag" },
		{ triangles = 300, parts = 2, repeats = 8 },
		"Flag on its own emissive material; a script can raise it when a raid log is waiting."
	),
	prop(
		"shrub",
		"Shrub",
		4,
		3.5,
		"a round bushy shrub made of three overlapping smooth leafy blobs in deep blue-green",
		nil,
		{ triangles = 250, parts = 1, repeats = 30 },
		"Single material, no leaf cards; blobs only."
	),
	prop(
		"rock_cluster",
		"Rock cluster",
		5,
		3,
		"a cluster of three smooth rounded slate boulders of different sizes with a few small crystal specks "
			.. "on the biggest one",
		{ key = "violet", at = "the few small crystal specks" },
		{ triangles = 300, parts = 2, repeats = 24 },
		"Crystal specks on their own emissive material."
	),
	prop(
		"tree_small",
		"Small tree",
		6,
		11,
		"a small round-topped night tree with a thick short trunk and a puffy blue-green canopy dotted with "
			.. "a few tiny fruits",
		{ key = "moon", at = "the few tiny fruits in the canopy" },
		{ triangles = 800, parts = 3, repeats = 16 },
		"Canopy as one blobby mesh, no leaf cards. Fruit specks on their own emissive material."
	),
	prop(
		"wheelbarrow",
		"Wheelbarrow",
		3,
		2.5,
		"a chunky toy-like wooden wheelbarrow with one round wheel, empty",
		nil,
		{ triangles = 400, parts = 3, repeats = 6 },
		"No glow material. The wheel can be a separate mesh for a roll animation."
	),
}

function Kit.hasGlow(p: Piece): boolean
	return p.glow ~= nil
end

-- The image prompt for one piece: style, subject, the one glow, avoid.
function Kit.prompt(p: Piece): string
	local glow = "No glowing parts at all."
	if p.glow then
		glow = `One glowing feature: {p.glowAt}, with a {Kit.GLOW_WORDS[p.glow]}. No other glowing parts.`
	end
	return table.concat({ Kit.STYLE, `Subject: {p.subject}.`, glow, Kit.AVOID }, " ")
end

-- Credit model for when credits return. Costs are from assets/generation-log.md: seedream_v4_5
-- is 1 credit per image; Tripo H3.1 multiview was quoted at 9 credits (Meshy 30). Kit pieces
-- have one concept image, so single-image-to-3D is assumed to cost about the same as Tripo.
Kit.IMAGE_COST = 1
Kit.IMAGES_PER_PIECE = 2 -- a concept plus one retry on average
Kit.MESH_COST = 9
Kit.MESH_RETRY_RATE = 0.3 -- share of meshes regenerated once

export type Estimate = {
	pieces: number,
	images: number,
	meshes: number,
	imageCredits: number,
	meshCredits: number,
	total: number,
}

function Kit.estimate(pieces: { Piece }): Estimate
	local n = #pieces
	local images = n * Kit.IMAGES_PER_PIECE
	local meshes = math.ceil(n * (1 + Kit.MESH_RETRY_RATE))
	return {
		pieces = n,
		images = images,
		meshes = meshes,
		imageCredits = images * Kit.IMAGE_COST,
		meshCredits = meshes * Kit.MESH_COST,
		total = images * Kit.IMAGE_COST + meshes * Kit.MESH_COST,
	}
end

return Kit
