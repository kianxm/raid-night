# Generation log

Every generation, kept or not. The assets agent appends a row per job.

## Running total

| Stage | Images | Credits | Balance after |
| --- | --- | --- | --- |
| Stage 0 style exploration (2026-10-28), attempt 1 | 0 produced (10 calls refused) | 0 | 110 |
| **Total to date** | **0** | **0** | **110** |

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
