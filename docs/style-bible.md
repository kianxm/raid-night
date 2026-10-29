# Style bible

Every asset, human-made or generated, follows this page. Prompts are built from the blocks at
the bottom by `tools/assets/build_prompts.luau`, so editing a block here means editing it there.

## The look in one line

Chunky, toy-like night critters glowing softly in a dark navy moonlit town.

## World

| Element | Rule |
| --- | --- |
| Base colors | Night navy `#0B1026`, deep indigo `#1B1F3B`, slate `#2E3552` |
| Light | Cool moonlight key from above, warm lamp pools on the ground, neon accents |
| Materials | Matte, toon-shaded, flat colors; no photoreal textures |
| Glow | Each critter has ONE glowing feature in its palette's first color |
| Fog | Light blue-violet fog for depth; rare critters must still pop through it |

## Critters

- **Proportions:** head about 40% of height, big eyes, short stubby limbs, rounded body.
- **Body plan follows the animal** (Kian, 2026-10-28). A crab scuttles, a whale floats, a bat
  hangs; critters are not all upright bipeds. The proportions above apply within each body
  plan. Each critter belongs to one shared plan so rigs and animations are reused: `upright`,
  `quadruped`, `crawler`, `floater`, `flyer` (a rare one-off, like a serpent, is allowed).
  Prompts must name the body plan and its pose, because the style references show an upright
  mouse and will otherwise pull every critter upright.
- **Silhouette:** recognizable as a black shape at phone size. Test by filling it solid black.
- **One idea per critter:** the `look` line in Critters.luau. Do not add extra props.
- **Palette:** from Critters.luau; the first color is the glow.
- **Tier reads from across the map:** glow intensity and particles scale with tier. Common:
  soft glow, no particles. Rare: brighter glow, a few motes. Legendary+: strong glow, trail
  or aura. Secret: unique effect nobody else has.
- **Mutations are done in-engine**, not as new models: Shiny (sparkle overlay), Moonlit
  (pale blue rim light), Haunted (translucent + green wisps), Golden (gold material swap).
- **Originality:** never resemble an existing character, mascot, brand or franchise.

### Technical budgets (our targets)

| Tier | Triangles | Texture |
| --- | --- | --- |
| Common, Uncommon | up to ~1,500 | 512 px |
| Rare, Epic | up to ~3,000 | 512-1024 px |
| Legendary, Mythic, Secret | up to ~5,000 | 1024 px |

Check Roblox's current mesh import limits before the first import; these targets sit well
under them on purpose, for phone performance with 8 dens of critters on screen.

## UI

Chunky rounded panels, thick outlines, big icons, one accent color per screen (the glow
color of whatever matters most). Numbers huge, labels short. Font: one rounded display font
for numbers and titles, one clean sans for body. Every screen readable at phone size.

## Audio

- **Den breach alarm:** short, urgent, cartoonish siren with a comic "uh-oh" tail. The brand sound.
- **Escape jingle:** 2-3 second sneaky-heist sting that resolves on a bright note.
- **Music:** lo-fi night loop for dens; tenser plucked-strings loop during raids.
- **Critter idles:** tiny, cute, never annoying on loop. Keep them under 1 second.

## Prompt blocks

These are copied into prompts by the builder script. Keep them in sync with
`tools/assets/build_prompts.luau`.

**STYLE**
> Stylized 3D game character for a cozy nighttime game. Chunky toy-like shapes, soft rounded
> silhouette, oversized head about 40 percent of body height, big expressive eyes, short stubby
> limbs. Matte toon-shaded body with one softly glowing feature. Clean simple shapes and
> textures, no fine detail. Readable silhouette at small size.

**AVOID**
> Avoid photorealism, realistic fur strands, text, letters, logos, watermarks, existing cartoon
> characters, franchise mascots, human faces, weapons, gore, scary or sexualized features.

**TURNAROUND VIEW** (one image per view: front, side, back)
> {STYLE} Character: {name}, {look}. {view} view, neutral standing pose, full body, centered,
> orthographic camera, evenly lit, plain mid-grey background. Main glow color {glow}; other
> colors {palette}. {AVOID}

**ICON**
> {STYLE} Inventory icon of {name}, {look}. Three-quarter view, head and body centered and
> filling the frame, soft rim light, glow color {glow}, plain background for removal. {AVOID}
