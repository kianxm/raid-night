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
- **Personality** (Kian, 2026-10-28, D-038). Every critter has a distinct personality expression
  (sleepy, smug, suspicious, grumpy, mischievous and so on) that still reads as cute. Commons are
  simple and cheerful. Rarity raises attitude: Rare and above get more character, such as a
  smirk, a cool stare or an air of mystery. No critter is ever sad, crying, injured or
  frightened. The word is the `personality` field in Critters.luau (one or two words, at most 6
  critters share one, checked by `CritterCatalog.validate`). The base art shows one charming
  expression; it does not change between views.
- **Animation set** (every critter): a **happy idle** in the den (its `idle` line), a **sneaky
  walk** while carried, and a **gotcha pose** when stolen. The critter is always in on the joke:
  never generate or animate a distressed pose (struggling, cowering, crying, hurt).
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
> characters, franchise mascots, human faces, weapons, gore, scary or sexualized features, sad,
> crying, injured or frightened expressions or poses.

**EXPRESSION** (Common / Uncommon / Rare and above)
> Expression: {personality}, kept simple and friendly so it reads as cute.
>
> Expression: {personality}, with a touch of attitude that still reads as cute and friendly.
>
> Expression: {personality}, with lots of character that still reads as cute and charming.

**ANIMATIONS** (written to `brief.json`, not to image prompts)
> denIdle: happy idle in the den: {idle}
>
> carried: sneaky walk while carried: tiptoes in the air and glances side to side, in on the
> heist, never struggling
>
> stolen: gotcha pose when stolen: a quick {personality} gotcha, in on the joke, never sad or
> scared

**TURNAROUND VIEW** (one image per view: front, side, back)
> {STYLE} Character: {name}, {look}. {EXPRESSION} {view} view, neutral standing pose, full
> body, centered, orthographic camera, evenly lit, plain mid-grey background. Main glow color
> {glow}; other colors {palette}. {AVOID}

**ICON**
> {STYLE} Inventory icon of {name}, {look}. {EXPRESSION} Three-quarter view, head and body
> centered and filling the frame, soft rim light, glow color {glow}, plain background for
> removal. {AVOID}
