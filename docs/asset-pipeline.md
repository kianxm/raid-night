# Asset pipeline

From a line in `Critters.luau` to a rigged critter in Roblox, in six stages with two human
approval gates. The `assets` agent runs it; you approve.

```
Critters.luau ──build_prompts──▶ assets/jobs/<id>/      prompts + brief
              ──generate (images)──▶ assets/raw/<id>/   front, side, back, icon
              ── GATE 1: you approve the look ──
              ──generate (3D)──▶ assets/raw/<id>/model.glb
              ──Blender cleanup──▶ assets/clean/<id>/   model.fbx, icon.png
              ── GATE 2: you approve in Studio ──
              ──import──▶ Roblox (asset ids recorded in assets/clean/<id>/ids.json)
```

## Stage 0: lock the style (once, before any critter)

1. Generate 6-10 style exploration images from the STYLE block with 3 different critters.
2. Pick the best 3-4 and save them as `assets/clean/_style/ref-01.png` and onward.
3. Superseded (2026-10-29): the locked reference is a mouse and leaks its ears into other
   critters, so only `dusk_mouse` passes it; see the style bible. Original rule: every later
   generation passes these as reference images. This is what keeps 40 critters
   looking like one game. Pick a model that accepts multiple references.

## Stage 1: build prompts

```bash
lune run tools/assets/build_prompts.luau          # all critters
lune run tools/assets/build_prompts.luau fox      # ids containing "fox"
```

Prompt text, each critter's body plan and pose, and the hex-to-words color names live in
`tools/assets/Prompts.luau` (tested by `tests/specs/AssetPrompts.spec.luau`). A new critter needs
an `ART` entry there. Writes `assets/jobs/<id>/front.txt`, `side.txt`, `back.txt`, `icon.txt` and `brief.json`
(name, tier, personality, palette, the three-animation set, triangle and texture budgets), plus
`assets/jobs/INDEX.md`.

## Stage 2: concept images

Generate in batches of 5 critters. Generate the **front view first**, pick the best, then
generate side and back using the chosen front as a reference so all three views match.
Then the icon. Remove the icon background.

`tools/assets/generate.sh` wraps the Higgsfield CLI and defaults to a dry run that only
prints commands. Model ids and flags change; confirm them in the Higgsfield CLI docs first.

**GATE 1.** You review the batch. Rejected critters get a note in their `brief.json` and are
regenerated. Nothing goes to 3D without your approval.

## Stage 3: 3D

Run multi-image-to-3D with the approved front, side and back views, textured. Multi-view
gives much better meshes than a single image.

- Auto-rigging tools target humanoids. Most critters are not humanoid: rig them by hand in
  Blender with a small skeleton (root, body, head, 2-4 limbs, tail) or animate as a rigid
  body with squash and stretch.
- Legendary, Mythic and Secret critters get a human artist pass. They are the clip bait.

## Stage 4: Blender cleanup checklist

- [ ] Reduce to the tier's triangle budget (style bible)
- [ ] Scale: 1 unit = 1 stud; critter height 2-4 studs by tier
- [ ] Pivot at the feet, facing -Z
- [ ] One material; texture at the tier's size; glow feature on its own material for emissive
- [ ] Clean names: `<id>_mesh`, `<id>_mat`, `<id>_glow`
- [ ] The three animations from `brief.json` (`animations`): happy den idle 1-3 seconds looping,
  sneaky carried walk looping, gotcha pose one-shot. No distressed poses (style bible)
- [ ] Export to `assets/clean/<id>/model.fbx`

## Stage 5: import and record

Import with the Studio 3D importer. Record asset ids in `assets/clean/<id>/ids.json`
(`mesh`, `texture`, `icon`, `animation`). Mutations are applied in-engine (style bible).

**GATE 2.** You check it in Studio next to two other critters: same style, readable at
distance, glow pops in fog.

## Cost control

- Show the credit estimate before every batch; log every generation in
  `assets/generation-log.md` (date, critter, stage, model, cost, kept or discarded).
- Images are cheap; 3D is not. That is why Gate 1 comes before 3D.
- Batch 5 at a time so a style problem costs 5 generations, not 40.

## Other assets

| Asset | Tool | Notes |
| --- | --- | --- |
| UI icons (non-critter) | Vector model to SVG, then rasterize to PNG for Roblox | Keep a source SVG in `assets/ui/` |
| Game icon and thumbnails | Image model + real gameplay captures | Thumbnails must show the real game |
| Alarm sting, jingle, SFX | Audio model | Check commercial-use terms per model |
| Music loops | Audio model or licensed library | Loops must cut seamlessly |
| Trailer / TikToks | Real gameplay first; AI video only for stylized intros | Never misrepresent gameplay |
