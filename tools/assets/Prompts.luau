--!strict
--[[
	Prompt text for critter concept art. Pure: no file access, so tests/specs/AssetPrompts.spec
	can check it. tools/assets/build_prompts.luau writes the results to assets/jobs/.

	The STYLE, AVOID, EXPRESSION, BODY PLAN and ANIMATIONS blocks must match docs/style-bible.md.
	Lessons from the Stage 0 style test (assets/generation-log.md) are folded in:
	  - hex codes leak into images as text, so colors are named in words (hex stays in briefs)
	  - "inventory icon" draws an app-icon frame, so the icon is a plain character portrait
	  - the single glow is ignored half the time, so prompts say "no other glowing parts"
	  - night scenes drift to plush, so the finish is "smooth matte vinyl toy surface, no fuzz"
	  - the style references show an upright mouse, so every prompt names the body plan and pose
]]

local Prompts = {}

Prompts.STYLE = "Stylized 3D game character for a cozy nighttime game. Chunky toy-like shapes, soft rounded "
	.. "silhouette, oversized head about 40 percent of body height, big expressive eyes, short stubby "
	.. "limbs only where the animal has limbs. Smooth matte vinyl toy surface with toon shading, no fuzz, no felt, no plush texture. "
	.. "Clean simple shapes and textures, no fine detail. Readable silhouette at small size."

Prompts.AVOID = "Avoid photorealism, realistic fur strands, text, letters, numbers, labels, logos, watermarks, "
	.. "frames, borders, strings, ropes, hooks or hangers, existing cartoon characters, franchise mascots, human faces, weapons, gore, scary "
	.. "or sexualized features, sad, crying, injured or frightened expressions or poses."

-- Body plans are shared so rigs and animations are reused (style bible, "Body plan follows the
-- animal"). Each pose is written for a neutral turnaround.
Prompts.BODY_PLANS = {
	upright = "standing upright on two short legs, arms relaxed",
	quadruped = "standing on all four short legs like an animal, not upright like a person",
	crawler = "low to the ground in its natural animal posture, not standing upright like a person",
	floater = "floating in the air a little above the ground with no legs, nothing touching the ground",
	flyer = "hovering in the air with its wings spread and its legs tucked, not standing",
	serpent = "long serpentine body coiled in a loose ring, not standing upright",
}

-- Every critter's plan and its one glowing feature (named, or the model puts the glow anywhere).
-- A critter may also override its pose when the plan's default would fight its `look` line, and
-- its `look` line itself: Legendary and above carry a fuller signature design (the wow ladder),
-- and the bat hovers pending a catalog change by its owner.
Prompts.ART = {
	dusk_mouse = { bodyPlan = "upright", glow = "its oversized ears" },
	lantern_snail = {
		bodyPlan = "crawler",
		glow = "its paper lantern shell",
		pose = "a real snail body with no arms and no legs: one soft foot sliding along the ground, the lantern shell on its back",
	},
	puddle_newt = {
		bodyPlan = "crawler",
		glow = "the stripe down its back",
		pose = "on four short splayed legs, belly close to the ground",
	},
	pebble_toad = {
		bodyPlan = "crawler",
		glow = "the speckled spots on its skin",
		pose = "squatting low on all four legs like a toad",
	},
	sock_moth = { bodyPlan = "flyer", glow = "the tips of its feathery antennae" },
	-- Kian, 2026-10-29: the bat hovers instead of hanging (no ceiling to rig against). `look` overrides
	-- the catalog line until the economy owner updates Critters.luau to match.
	snooze_bat = {
		bodyPlan = "flyer",
		glow = "the pompom on its nightcap",
		look = "chubby purple bat in a floppy nightcap, dozing in mid-air",
		pose = "hovering right side up with its wings spread, eyes closed, legs tucked; not hanging, nothing holds it up",
	},
	blinkbug = { bodyPlan = "flyer", glow = "its lightbulb-shaped tail" },
	crumb_rat = { bodyPlan = "upright", glow = "the cracker crumb it is hugging" },
	button_beetle = {
		bodyPlan = "crawler",
		glow = "the four holes in its button shell",
		pose = "on six short legs, body low and round",
	},
	fuzz_owlet = {
		bodyPlan = "upright",
		glow = "its huge eyes",
		pose = "standing upright on two tiny feet, wings folded at its sides",
	},
	drama_possum = { bodyPlan = "quadruped", glow = "its tail tip" },
	neon_shrimp = {
		bodyPlan = "floater",
		glow = "its long antennae",
		pose = "floating curled in the air, tiny gloves raised",
	},
	moonquill = { bodyPlan = "quadruped", glow = "the tips of its quills" },
	boo_mole = {
		bodyPlan = "floater",
		glow = "its translucent ghostly body",
		pose = "floating like a little ghost, body fading into a wispy tail",
	},
	lid_raccoon = { bodyPlan = "upright", glow = "the rim of its trash can lid" },
	nimbus_lamb = { bodyPlan = "quadruped", glow = "the little lightning flickers inside its storm cloud wool" },
	puddle_jelly = {
		bodyPlan = "floater",
		glow = "its dangling tendrils",
		pose = "a jellyfish body with no arms and no legs: a round bell floating in the air, tendrils dangling below",
	},
	streetlamp_frog = { bodyPlan = "upright", glow = "the bulb of its miniature streetlamp" },
	wick_cat = { bodyPlan = "quadruped", glow = "the candle flame on its tail" },
	noodle_weasel = { bodyPlan = "quadruped", glow = "its collar" },
	static_crab = {
		bodyPlan = "crawler",
		glow = "the television screen",
		pose = "scuttling on short crab legs, claws empty, the television worn on its back like a hermit crab shell with the screen facing forward above its eyes",
	},
	crescent_fox = { bodyPlan = "quadruped", glow = "its crescent moon tail" },
	patchwork_bear = { bodyPlan = "upright", glow = "its fabric patches" },
	dj_owl = {
		bodyPlan = "upright",
		glow = "its tiny turntable",
		pose = "standing upright on two short feet, wings resting on the turntable",
	},
	shroom_fawn = { bodyPlan = "quadruped", glow = "the mushroom clusters on its antlers" },
	bubble_otter = {
		bodyPlan = "floater",
		glow = "the soap bubble around it",
		pose = "floating on its back inside the bubble, paws on its belly",
	},
	comet_ferret = { bodyPlan = "quadruped", glow = "its comet tail" },
	tick_toad = {
		bodyPlan = "crawler",
		glow = "the pocket watch face in its belly",
		pose = "sitting up like a frog on its back legs, belly facing forward",
	},
	aurora_pup = { bodyPlan = "quadruped", glow = "its aurora mane" },
	mirror_cat = { bodyPlan = "quadruped", glow = "the moon reflected on its chrome coat" },
	pocket_whale = { bodyPlan = "floater", glow = "its constellation spots" },
	ufo_hamster = {
		bodyPlan = "floater",
		glow = "the rim lights of its flying saucer",
		pose = "sitting inside its saucer, which floats above the ground",
	},
	neon_drake = { bodyPlan = "flyer", glow = "the neon outlines of its wings" },
	storm_hare = {
		bodyPlan = "floater",
		glow = "its lightning-bolt ears",
		pose = "sitting on its small thundercloud, which floats above the ground",
		look = "sleek silver-and-white hare in a daring surfer stance on a small crackling thundercloud, tall lightning-bolt ears, a streaming silver mane, tiny arcs of electricity dancing around the cloud; its body is silver, never yellow, with yellow only on the small electric arcs",
	},
	lunar_kitsune = {
		bodyPlan = "quadruped",
		glow = "its three moon-phase tails",
		look = "elegant spirit fox with exactly three long flowing tails, each tipped with a glowing moon phase (crescent, half and full), a small crescent mark on its forehead and wisps of pale spirit flame at its paws",
	},
	abyss_angler = {
		bodyPlan = "floater",
		glow = "its full-moon lure",
		pose = "floating as if swimming, lure held up in front of its face",
		look = "round deep-sea anglerfish with a sly grin of tiny rounded teeth, flowing ribbon-like fins and a tiny full-moon lure on a curling stalk",
	},
	king_bandit = {
		bodyPlan = "upright",
		glow = "its trash can lid crown",
		look = "regal raccoon wearing a crown made from a trash can lid and a tattered velvet cape, with a royal sash made from a candy wrapper",
	},
	nebula_owl = {
		bodyPlan = "upright",
		glow = "the swirling galaxy in its wings",
		pose = "standing upright on two short feet, wings opened wide",
		look = "majestic owl with a crest of star-tipped feathers, wings spread wide to show a swirling galaxy inside them, a small star mark on its forehead and tiny planets orbiting its head",
	},
	eclipse_wyrm = {
		bodyPlan = "serpent",
		glow = "the eclipse ring of its coiled body",
		look = "serpentine dragon with its own sleek horned dragon head, a crown of small swept-back horns, long whisker barbels and narrow golden eyes, no round ears; its long scaled body coils into a ring that frames a blazing solar eclipse corona behind it",
	},
	midnight_mew = {
		bodyPlan = "floater",
		glow = "its single huge crescent-moon eye",
		look = "a creature from another world with a cat-like silhouette made of living night sky: its body is a deep starfield with drifting nebula wisps, its ears trail off into smoke, and one single huge crescent-moon eye sits in the center of its face, with a halo of tiny orbiting stars",
	},
}

-- Rarity raises attitude: Commons stay simple, Uncommons get a touch more, Rare and above get the most.
local EXPRESSION_BY_TIER = {
	Common = "kept simple and friendly so it reads as cute",
	Uncommon = "with a touch of attitude that still reads as cute and friendly",
}
local EXPRESSION_RARE_AND_ABOVE = "with lots of character that still reads as cute and charming"

-- The wow ladder (Kian, 2026-10-29): the rarer the critter, the more spectacular it looks.
-- Commons and Uncommons stay simple; each tier above adds spectacle.
Prompts.TIER_WOW = {
	Rare = "Rare tier: one signature flourish that makes it stand out from common critters.",
	Epic = "Epic tier: a more elaborate, eye-catching silhouette with one standout flourish and a "
		.. "slightly stronger glow.",
	Legendary = "Legendary tier: majestic and unforgettable at a glance, a hero of the collection. A unique "
		.. "silhouette and a face and head designed for this species, not a generic toy face. Its glowing "
		.. "feature glows strongly, with a soft aura and a few floating light motes in the same color.",
	Mythic = "Mythic tier: awe-inspiring and celestial, rarer than legendary. Layered, intricate details "
		.. "that still read as one clear silhouette, a face and head designed for this species, and a "
		.. "radiant aura with orbiting light motes in the glow color.",
	Secret = "Secret tier: otherworldly and mysterious, unlike any ordinary animal, the single most "
		.. "spectacular critter in the game. A one-of-a-kind silhouette, a dramatic aura and drifting light "
		.. "effects in the glow color.",
}

-- The style reference image (assets/clean/_style/ref-01.png) is a mouse, and its round ears and face
-- leak into every critter it is passed with (Kian, 2026-10-29). Only the mouse gets it; the STYLE
-- block's words carry the finish for everyone else.
function Prompts.usesStyleReference(species): boolean
	return species.id == "dusk_mouse"
end

local HUES: { { below: number, name: string } } = {
	{ below = 15, name = "red" },
	{ below = 40, name = "orange" },
	{ below = 65, name = "yellow" },
	{ below = 85, name = "lime" },
	{ below = 150, name = "green" },
	{ below = 175, name = "mint" },
	{ below = 200, name = "cyan" },
	{ below = 245, name = "blue" },
	{ below = 290, name = "violet" },
	{ below = 320, name = "magenta" },
	{ below = 345, name = "pink" },
	{ below = 360, name = "red" },
}

-- Names a "#RRGGBB" color in plain words, because image models draw hex codes as text.
function Prompts.colorName(hex: string): string
	local r = tonumber(string.sub(hex, 2, 3), 16) :: number / 255
	local g = tonumber(string.sub(hex, 4, 5), 16) :: number / 255
	local b = tonumber(string.sub(hex, 6, 7), 16) :: number / 255
	local maxC, minC = math.max(r, g, b), math.min(r, g, b)
	local light = (maxC + minC) / 2
	local chroma = maxC - minC
	local sat = if chroma == 0 then 0 else chroma / (1 - math.abs(2 * light - 1))

	if sat < 0.15 or chroma < 0.06 then
		if light > 0.93 then
			return "white"
		elseif light > 0.7 then
			return "light grey"
		elseif light > 0.4 then
			return "grey"
		elseif light > 0.08 then
			return "charcoal"
		end
		return "black"
	end

	local hue
	if maxC == r then
		hue = 60 * (((g - b) / chroma) % 6)
	elseif maxC == g then
		hue = 60 * ((b - r) / chroma + 2)
	else
		hue = 60 * ((r - g) / chroma + 4)
	end
	local name = "red"
	for _, entry in HUES do
		if hue < entry.below then
			name = entry.name
			break
		end
	end
	local warm = name == "red" or name == "orange" or name == "yellow"
	local purple = name == "violet" or name == "magenta"

	if sat < 0.25 and light >= 0.3 and (name == "blue" or name == "cyan") then
		return if light > 0.6 then "light blue-grey" else "blue-grey"
	elseif light < 0.3 then
		if purple then
			return "deep purple"
		elseif name == "blue" or name == "cyan" then
			return if light < 0.15 then "midnight navy" else "dark navy"
		elseif name == "pink" then
			return "burgundy"
		elseif warm then
			return "dark brown"
		end
		return `very dark {name}`
	elseif light < 0.5 then
		if name == "orange" or name == "yellow" then
			return if sat < 0.5 then "brown" else "amber"
		elseif name == "mint" then
			return "deep teal"
		elseif name == "pink" then
			return "raspberry"
		elseif name == "violet" then
			return "muted purple"
		end
		return if sat < 0.4 then `muted {name}` else `deep {name}`
	elseif warm and sat < 0.45 then
		return if light > 0.8 then "cream" elseif light > 0.6 then "beige" else "tan"
	elseif light > 0.8 then
		if name == "red" then
			return "pale pink"
		elseif name == "orange" then
			return "peach"
		end
		return `pale {name}`
	elseif light > 0.6 then
		if name == "red" then
			return "coral"
		end
		return `light {name}`
	end
	return if sat < 0.4 then `dusty {name}` else `bright {name}`
end

local function colorLine(species): string
	local others = {}
	for i = 2, #species.palette do
		table.insert(others, Prompts.colorName(species.palette[i]))
	end
	local glow = Prompts.ART[species.id].glow
	return `Its one glowing feature is {glow}, which glows softly in {Prompts.colorName(species.palette[1])}, with `
		.. `no other glowing parts. Other colors: {table.concat(others, " and ")}. No extra props or accessories beyond the `
		.. `ones named.`
end

-- The tier's wow line, with a leading space, or "" for Common and Uncommon.
function Prompts.wowLine(species): string
	local wow = Prompts.TIER_WOW[species.tier]
	return if wow then ` {wow}` else ""
end

function Prompts.expressionLine(species): string
	local tone = EXPRESSION_BY_TIER[species.tier] or EXPRESSION_RARE_AND_ABOVE
	return `Expression: {species.personality}, {tone}.`
end

-- The critter's look line: its art override, else the catalog's.
function Prompts.look(species): string
	return Prompts.ART[species.id].look or species.look
end

-- The critter's body plan pose: its own override, else its plan's default.
function Prompts.pose(species): string
	local art = Prompts.ART[species.id]
	assert(art, `{species.id} has no entry in Prompts.ART`)
	return art.pose or Prompts.BODY_PLANS[art.bodyPlan]
end

function Prompts.view(species, view: string): string
	return `{Prompts.STYLE} Character: {species.name}, {Prompts.look(species)}. Body: {Prompts.pose(species)}.{Prompts.wowLine(
		species
	)} ` .. `{Prompts.expressionLine(species)} {view} view, full body, centered and filling most of the frame, ` .. `orthographic camera, evenly lit, plain mid-grey background. {colorLine(
		species
	)} {Prompts.AVOID}`
end

function Prompts.icon(species): string
	return `{Prompts.STYLE} Character portrait of {species.name}, {Prompts.look(species)}. Body: {Prompts.pose(species)}.{Prompts.wowLine(
		species
	)} ` .. `{Prompts.expressionLine(species)} Three-quarter view, head and body centered and filling the frame, ` .. `soft rim light, plain flat light-grey background. {colorLine(
		species
	)} {Prompts.AVOID}`
end

return Prompts
