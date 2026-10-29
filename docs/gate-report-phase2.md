# Phase 2 gate report

2026-10-29, unattended overnight run. Phase 2 stops here, at its human gate. Nothing is merged into
`integration` and nothing is published or created in the Creator Dashboard.

## Summary

- **Phase:** 2 (Vertical slice).
- **Tasks:** 26 of 31 rows are Done. Four are Blocked on credits or on Kian: P2.1, P2.2 generation, P2.11 and P2.4t. P2.12's build freeze and tester access are yours.
- **PRs:** 30 PRs (#118 to #149, without #138 and #146/#147, which are issues) are folded into `preview/phase2` at **802513e**. Earlier Phase 2 art work (#87) is in it too. Merging into integration was refused by the permission check (D-058).

## How to land it

1. Merge #116 (Phase 1 ledger).
2. Open and merge one PR `preview/phase2` → `integration`, the same way Phase 1 landed with #111. This brings every Phase 2 PR in order. The other path is merging PR by PR, in the order in the progress table.
3. Merge the Phase 2 ledger PR (this file, progress, decisions log, handoff, CLAUDE.md ownership).
4. #138 is a tuning proposal and stays out until you pick an option (see below).

## Exit checks

| Check | Result |
| --- | --- |
| All tests and CI green | **Pass.** 657 tests and 0 failures on preview/phase2. EscrowSimulation is green. StyLua, selene and luau-analyze are clean. CI passed on every PR. |
| Onboarding under 3 minutes | **Pass (single client, Studio).** Join to first steal took 60 s, about 25-30 s of it tool latency. The first run took 3:51, which led to issue #146 and fix D-070. |
| No errors in a 4-client session | **Not run.** It needs people (deferred list). The single-client Studio pass had no errors from our code. |
| Analytics events arriving | **Partial.** Every event, funnel step and economy flow reached AnalyticsService in Studio with no errors. Seeing them in the dashboard needs a published place. |

## What was built

- **Profiles (C6, C6b, C6c):** seven optional profile fields with no migration. Adds settings and onboarding remotes (server-advanced steps), rate limits, and an idempotent successful-raid count.
- **World (P2.3):** every den and pocket piece is built through a kit lookup. It uses a real model when an id exists and today's greybox otherwise. Pads go from 6 to 30 by den level. Dens stream as units and the map uses 12 lights. A full 30-pad map is 851 parts.
- **Critters (P2.4):** a species → asset-id seam, tier glow, and all four mutations on placeholders. `eggMaxTier` is raised to Mythic.
- **UI (P2.5, P2.5d-h):** Shop, Bag, Den management, Settings (music, SFX, reduced motion), a strings table, sound cues with empty ids, the gear HUD, the 6-tier odds chip and the critter idle animation.
- **Onboarding (P2.6, P2.6e, P2.6r, P2.6f):** one hint at a time. A free egg, then collect, then a discounted second egg, then a per-player tutorial den next door with a guided steal and a one-time untradeable critter, then the raid-log tip. New players get a 30-minute live shield.
- **Notifications (P2.7, P2.7b, P2.7c):** one per player per day, "first critter lost" only. State lives in its own DataStore with atomic day claims. The opt-in prompt comes only after the first real raid, and launch data opens revenge (still checked on the server).
- **Monetization (P2.8, P2.8b, P2.8c, P2.8m):** passes and products with no paid randomness. Receipts are exactly-once, including a redelivery before the profile loads after a forced shutdown. There is a single Glow-factor helper with a source guard, and every online accrue goes through it. Restricted players fail closed. Gear is bought with Glow.
- **Analytics (P2.9, P2.9b):** all 17 Appendix A events, the onboarding and raid-flow funnels, and Glow sources and sinks. No names and no typed text are logged.
- **Gear (P2.10):** grapple, smoke, decoy, speed coil and lockpick. Everything is server-validated, with a kill switch.
- **Closed-test kit (P2.12):** `docs/playtests/phase2.md` with a "Before inviting" checklist.

## What to test yourself (about 1 hour, plus the closed test)

1. Land the merges (above), then serve Rojo from integration.
2. Play a fresh account in Studio for about 5 minutes. Check that the onboarding hints read well, that the tutorial steal feels guided, and that the placeholder art is acceptable for testers.
3. Play a phone emulator at 667x375 and 844x390, covering every screen (none were captured at phone size).
4. Work through the "Before inviting" checklist in `docs/playtests/phase2.md`:
   - notification string and Open Cloud key;
   - products and passes with prices, then their ids pasted into Config.Purchases;
   - the `purchases`, `notifications` and `asyncRaids` flags (asyncRaids is off by default, and D-049's old-server rule applies);
   - tester group Play access for about 200 people (check the limit with an alt);
   - phone perf.
5. Run the 4-client session and the deferred multi-person checks (progress.md).
6. Run the closed test of about 200 players for 7+ days. It passes at D1 25%+ with no data-loss reports.

## Known issues

| Severity | Issue |
| --- | --- |
| Medium | All art and audio are placeholders (no credits, D-057). Testers will see greybox dens and shapes. |
| Medium | Progression is fast after Mythic eggs: den level 40 arrives on day 2.7 (was 16.7). Proposal #138 is waiting on you. |
| Low | Pocket-den critters still draw as orbs. |
| Low | A pending async escape that lands later isn't counted toward the first-raid opt-in prompt. |
| Low | The "Protected while you learn" chip isn't built. |
| Low | The rest is the hardening backlog in progress.md (all fail-safe, triage after the playtest, D-039). |
| Info | Not verified live: Open Cloud notification send, PromptOptIn's return value, real Robux purchases, 2-client gear. |

## Decisions made this phase (docs/decisions-log.md; overturn any)

- **D-057:** Phase 2 runs on placeholder art and sound. Generation is blocked; P2.3 and P2.4 build seams that load real ids later.
- **D-058:** stacked PRs plus `preview/phase2`; you merge.
- **D-059:** one profile-field batch (C6). Owners add additive remotes in their own PRs with review.
- **D-060:** Studio checks by temporary sync into the unsaved edit place, with test ids only.
- **D-061:** product defaults:
  - Glow-raising products fail closed for restricted players.
  - VIP is online-only.
  - Lantern Night is hidden from restricted players.
- **D-062:** notification state lives in its own DataStore. The storage-full notification is built but off.
- **D-063:**
  - Data wires the settings and onboarding remotes.
  - Accessories stay with the buyer and never travel with a stolen critter.
  - Gear level 0 means not owned.
- **D-064:** no onboarding skip. The tutorial steal is a one-time untradeable grant.
- **D-065:**
  - Restricted players aren't offered VIP.
  - A restricted buyer outside our UI gets NotProcessedYet.
  - Timer skips, event pass and cosmetics stay undefined.
- **D-066:** `raided_offline` is logged against the raider when the defender is offline.
- **D-067:** follow-ups land on preview/phase2.
- **D-068:**
  - The lockpick lets one raider through one Lockdown after 8 s at the border. It is switchable, and it narrows your lockdown rule.
  - Gear has a kill switch.
- **D-069:**
  - The new-player shield holds while the new player steals from others.
  - The tutorial den ignores the `raids` switch.
- **D-070:** onboarding's second egg costs 50 Glow (normal 150), once per player.
- **D-040** (yours, from #87) is restored to the log.

## Open questions for you

1. **Merges:** land #116, preview/phase2 and the ledger PR (or allow the integration agent to merge reviewed PRs).
2. **Tuning after Mythic (#138):** pick one option.
   1. Egg price 400 ×1.26: L40 on day 4.7, rebirth median 23.8, Glow held about 15 egg prices.
   2. Doubled Legendary/Mythic odds.
   3. No change: L40 on day 2.7, rebirth 21.7.
   4. A new task: egg tiers unlock by den level, which would hit both targets.
3. **Lockpick (D-068):** keep "picks a Lockdown" (a narrow exception to your lockdown rule), or turn it off with `Config.Gear.items.lockpick.enabled`?
4. **Products (D-061, D-065):**
   - Define VIP's non-Glow perks, timer skips, event-pass rewards and the raid scout perk. Raid scout's proposal is +1 target.
   - Is NotProcessedYet acceptable for a restricted buyer outside our UI?
   - Should Lantern Night carry over or refund on a server shutdown?
   - Should all Glow-protecting products count as Robux-linked?
5. **Notifications:** approve the optional storage-full notification, or keep it off.
6. **Credits:** about 263 Higgsfield credits for the world kit, plus critter 3D and audio; Asset Gate 1 picks in #87.
7. **Design note:** design-summary mentions a "Phase 2 paid-randomness mini-phase" (paid eggs, Blood Moon, Glow packs). It isn't in the playbook's Phase 2 table, and CLAUDE.md rule 6 forbids it at launch, so it wasn't started. Confirm it stays out.

## Next phase preview (Phase 3, after the gate and the Go public gate)

The first four tasks:

1. P3.1, publish and dashboard (integration). Needs your go-public approval.
2. P3.4, hardening pass (raid), starting from the backlog.
3. P3.3, Nemesis (matchmaking).
4. P3.8, security and policy audit (reviewer).
