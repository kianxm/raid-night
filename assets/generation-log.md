# Generation log

Every generation, kept or not. The assets agent appends a row per job.

## Running total

| Stage | Images | Credits | Balance after |
| --- | --- | --- | --- |
| Stage 0 style exploration (2026-10-28), attempt 1 | 0 produced (10 calls refused) | 0 | 110 |
| Stage 0 style exploration (2026-10-28), attempt 2 (MCP) | 10 | 10 | 100 |
| **Total to date** | **10** | **10** | **100** |

## Stage 0 plan: style exploration (P0.7)

- **Date:** 2026-10-28. **Budget:** hard cap of 10 images, no retries (approved by Kian).
- **Balance before:** 110 credits (workspace `Private`, plus plan).
- **Model:** `seedream_v4_5` (Seedream 4.5), `quality high`, 1:1. This is a standard text-to-image
  model that takes up to 14 reference images, which Stage 2 needs for style refs plus the front view.
  It costs 1 credit per image at either quality; FLUX.2 flex is 3 and Nano Banana 2 is 1.5.
- **Estimate:** `higgsfield generate cost` returned 1 credit for each of the 10 jobs, so 10 credits
  in total (9.1% of the balance).
- **Commercial use:** according to the Higgsfield help center, the Terms of Use (s. 4.4) give the
  user ownership of outputs, don't restrict commercial use, and don't tie commercial use to a plan.
  Paid plans download without a watermark. Outputs may not be used to train AI models (s. 5).
  Nothing model-specific is published for Seedream.
- **Critters:** Dusk Mouse (Common, small round mammal), Static Crab (Rare, wide low crustacean
  with an object shell), Abyss Angler (Legendary, floating fish).
- **Lever varied:** presentation and lighting. Every prompt starts from STYLE and ends with AVOID.
  `turnaround` = the front.txt prompt verbatim (evenly lit, mid-grey); `night` = in-world moonlight,
  lamp pool, fog and navy background with a soft glow; `icon` = the icon.txt prompt verbatim (rim
  light); `night_tier` = in-world with a Legendary-strength glow, aura and motes.
- **Script:** `tools/assets/stage0_style.sh` (dry run by default). Raw outputs go to `assets/raw/_style/`.

## Jobs

| Date | Critter | Stage | Model | Credits | Kept? | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-10-28 | dusk_mouse | 0 style-01 turnaround | seedream_v4_5 | 0 | n/a (no output) | Refused: only_mcp_usage_on_trial_is_available |
| 2026-10-28 | dusk_mouse | 0 style-02 night | seedream_v4_5 | 0 | n/a (no output) | Refused: only_mcp_usage_on_trial_is_available |
| 2026-10-28 | dusk_mouse | 0 style-03 icon | seedream_v4_5 | 0 | n/a (no output) | Refused: only_mcp_usage_on_trial_is_available |
| 2026-10-28 | static_crab | 0 style-04 turnaround | seedream_v4_5 | 0 | n/a (no output) | Refused: only_mcp_usage_on_trial_is_available |
| 2026-10-28 | static_crab | 0 style-05 night | seedream_v4_5 | 0 | n/a (no output) | Refused: only_mcp_usage_on_trial_is_available |
| 2026-10-28 | static_crab | 0 style-06 icon | seedream_v4_5 | 0 | n/a (no output) | Refused: only_mcp_usage_on_trial_is_available |
| 2026-10-28 | abyss_angler | 0 style-07 turnaround | seedream_v4_5 | 0 | n/a (no output) | Refused: only_mcp_usage_on_trial_is_available |
| 2026-10-28 | abyss_angler | 0 style-08 night | seedream_v4_5 | 0 | n/a (no output) | Refused: only_mcp_usage_on_trial_is_available |
| 2026-10-28 | abyss_angler | 0 style-09 icon | seedream_v4_5 | 0 | n/a (no output) | Refused: only_mcp_usage_on_trial_is_available |
| 2026-10-28 | abyss_angler | 0 style-10 night_tier | seedream_v4_5 | 0 | n/a (no output) | Refused: only_mcp_usage_on_trial_is_available |

**Attempt 1 outcome (2026-10-28):** the server rejected all 10 CLI calls before creating a job
(`only_mcp_usage_on_trial_is_available`). The account is on a trial (transactions: 10 registration
credits plus 100 subscription credits, both granted 2026-10-28), and trial accounts can only
generate through the Higgsfield MCP, not the CLI. `generate list` shows no jobs. The balance is
still 110. Nothing was retried. Blocked until Kian decides how to proceed (see the P0.7 report).

### Attempt 2 (2026-10-28, Higgsfield MCP)

Same 10 prompts (`stage0_style.sh prompts` writes them), sent through the MCP
`generate_image_batch` with `seedream_v4_5`, `quality high`, 1:1, paid from credits (no trial
unlim available for this model). Jobs 06 and 09 were rejected with a 429 rate limit before any job
was created; they were resubmitted once with identical prompts (no output had existed, so this is
not a re-roll). Balance 110 -> 100: exactly 1 credit per image. Outputs are 4096x4096 PNGs in
`assets/raw/_style/`, with `jobs.txt` mapping each file to its job ID. "Kept?" waits for the
style lock gate; the notes are the assets agent's read against the style bible.

| Date | Critter | Stage | Model | Credits | Kept? | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-10-28 | dusk_mouse | 0 style-01 turnaround | seedream_v4_5 | 1 | pending gate | Closest to the bible: matte vinyl, one glow (ears), clean silhouette. Framed low and small |
| 2026-10-28 | dusk_mouse | 0 style-02 night | seedream_v4_5 | 1 | pending gate | Best mood: moonlight, lamp pool, violet fog. Adds a second glow (belly patch) |
| 2026-10-28 | dusk_mouse | 0 style-03 icon | seedream_v4_5 | 1 | pending gate | Baked-in text tile "Dusk Mouse #7E7" (hex code leaked as text); whiskers; belly glow. Unusable as is |
| 2026-10-28 | static_crab | 0 style-04 turnaround | seedream_v4_5 | 1 | pending gate | Plush/felt texture, not matte; TV held in front, not worn as shell; human-like feet |
| 2026-10-28 | static_crab | 0 style-05 night | seedream_v4_5 | 1 | pending gate | Strong scene and read; TV held, not a shell; slightly plush |
| 2026-10-28 | static_crab | 0 style-06 icon | seedream_v4_5 | 1 | pending gate | Felt texture, extra chest glow, TV held; dark background instead of plain |
| 2026-10-28 | abyss_angler | 0 style-07 turnaround | seedream_v4_5 | 1 | pending gate | Baked-in title text (misspelled); reads as a shark; extra glowing fish charm. Unusable |
| 2026-10-28 | abyss_angler | 0 style-08 night | seedream_v4_5 | 1 | pending gate | Moon lure reads well; plush black body, belly glow, stray fishing rods as props |
| 2026-10-28 | abyss_angler | 0 style-09 icon | seedream_v4_5 | 1 | pending gate | Nice matte finish and moon lure; baked-in rounded app-icon frame; belly glow |
| 2026-10-28 | abyss_angler | 0 style-10 night_tier | seedream_v4_5 | 1 | pending gate | Legendary glow and motes read; holds a fishing rod with a second moon; plush texture |

**Patterns for Stage 1 prompts** (to fold into the job templates once the style is locked):
- Hex codes leak into the image as text. Name colors in words ("pale cyan") and keep hex in briefs.
- "Inventory icon" makes the model draw an app-icon frame or label tile. Ask for "character
  portrait, three-quarter view" and add the icon frame in UI.
- "One softly glowing feature" is ignored about half the time (belly patches). Name the glow
  and add "no other glowing parts".
- Night scenes drift to plush/felt. Add "smooth matte vinyl toy surface, no fuzz".
- "Angler" pulls in fishing rods. Add "no props, no fishing gear".
- Every critter came out bipedal with stubby humanoid legs, including the crab and the fish.
  Decide whether that is the house style or whether body plans should follow the animal.
