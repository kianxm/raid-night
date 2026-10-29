# Progress

Current phase: 0 → 1 (Phase 0 gate approved; Phase 1 not started, waiting for Kian) · Last updated: 2026-10-28

## Phase 0: Prototype (parallelism 2)

| Task | Agent | Depends | Status | Branch / PR | Attempts | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| P0.1 | integration | — | Done | #1 | 1 | CI green (tests, StyLua, selene, luau-analyze via rokit). Baseline StyLua diffs fixed |
| P0.2 | raid | — | Done | #3, #4 | 1 | 107 parts, 48 lights. Studio (1 client): own den + sign, respawn, walkable border, leave clears den. Multi-client spawn/reassign verified by Lune tests only; 3-client Studio check pending (Kian) |
| P0.3 | data | — | Done | #2 | 1 | Reviewer APPROVED. Studio: survives rejoin on real DataStore, fresh-save stamping, flags. Not verified: 2-player leave, session-steal kick (needs 2 servers) |
| P0.3a | data | P0.3b | Done | #25, #26 | 1 | Reviewer APPROVED both (mutation runs confirmed). 111 tests on integration |
| P0.3b | data | P0.3 | Done | #11 | 2 | Reviewer APPROVED after fix round (B1-B3; mutation runs reproduce dupe/loss on old code). 96 tests. saveNow, transferLive, escrow DataStore + recovery, kill-switch semantics (D-002). Server code not yet run in Studio (2-player plan deferred) |
| P0.4 | economy | P0.3 | Done | #9, #10 | 1 | Studio (1 client) passed steps 1-8: egg, collect math, pads/overflow, swaps, 15 bad payloads refused, rate limit, upgrade costs. Rejoin persistence and 2-client checks being rerun. Note: Inventory is uncapped (balance item) |
| C1 | data | — | Done | #22 | 1 | Reviewer APPROVED. 102 tests on integration. Doc follow-ups folded into P0.3a |
| P0.4b | economy | C1 | Done | #28 | 1 | 106 tests. Rescue egg Common-only + untradeable; accrue before the rescue check; eggMaxTier from Config; server uid→model table (no attribute reads). Follow-up: delete the "One existing read" paragraph in contracts.md (data) |
| P0.5 | raid | P0.2, P0.4, P0.3b, C1 | Done | #27, #29, #30, #32 | 3 | Reviewer APPROVED round 3 (attack reruns: teleport-into-lockdown and gap-jumps refused). integration code identical to the reviewed tree. 169 tests |
| P0.6 | ui | P0.4 | Done | #12, #17 | 1 | #17 fixed the top-bar overlap (issue #15); Studio recheck with P0.6b. Client only; not run in Studio yet (phone emulator check in the P0.8 session). Lockdown button disabled until the remote exists |
| P0.6b | ui | C1 | Done | #33 | 1 | Lockdown via Net, D-011 states, carried pill, raid toast, StealPrompt hidden in own den |
| P0.7 | assets | — | Done | #5 | 2 | 10 images via Higgsfield MCP (seedream_v4_5, 10 credits, 100 left). Style locked by Kian: ref-01 (finish) + ref-02 (night lighting) in `assets/clean/_style/`. Body plan follows the animal (style bible). Stage 1 follow-up: `tools/assets/generate.sh` STYLE_REFS still lists ref-03/ref-04, which do not exist |
| P0.5e | data | P0.5 | Done | #37, #38 | 1 | Reviewer APPROVED both. Studio memory switch (ServerStorage StudioMemoryProfiles), test profiles (ids <= -1_000_000), grabRange in Config, storage mode fixed before use. 122 tests |
| P0.4c | economy | — | Done | #36 | 1 | Placement never moves a carried critter (as mover or swapped occupant). 115 tests |
| P0.4d | economy | — | Done | #47 | 1 | Fixes #43. Inventory critters auto-fill free pads (D-027). Studio-verified. 176 tests |
| P0.6c | ui | — | Done | #46 | 1 | Fixes #41. Raider toast on RaidEnded (stolen / dropped / not confirmed). Studio-verified |
| P0.8 | integration | P0.5, P0.6, P0.6b | Done | #20, #44 | 2 | Kit ready (corrected against the build, #44). Single-client Studio pass passed twice, output clean (stand-in for the 2-client exit check). Private publish and the multi-client session are Kian's, at the gate |
| P0.9 | economy | — | In progress | agent/economy/P0.9 | 1 | Egg odds helpers (tier, rescue, species, next egg) matching the real rolls; Glow packs out of PurchaseService (D-028) |
| P0.10 | ui | P0.9 | Done | #51 | 1 | Odds chip + panel (D-028). Studio-checked. Fixes for #54 (phone layout) and #55 (per-species rounding) in P0.10b |
| P0.11 | economy | — | Done | #53 | 1 | PurchaseService catalog header for D-029 |
| P0.10b | ui | P0.10 | Done | #57 | 1 | Fixes #54 (compact column on short screens, fit tested 320-900 px) and #55 (true per-species odds). Studio-simulated; real phone check deferred |
| C2 | data | — | Done | #59 | 1 | Reviewer APPROVED. Config.Boosts + contracts.md Robux-linked multipliers (D-030) |
| P0.12 | economy | C2 | Done | #62 | 2 | Reviewer APPROVED; S1/S2/S5 landed: glowBoostFactor({ vip, lanternNight, paidRandomRestricted?, purchasesEnabled }) fails closed, factor clamped to [1, maxGlowBoostFactor()], NaN `now` ignored. 206 tests |
| P0.5g | data | — | In review | #64, #65 | 1 | Stacked; merge #64 then #65 together (#64 alone would let the count cap empty-commit live steals). 210 tests. Reviewer running |
| P0.5h | raid | P0.5g | Todo | | 0 | RaidService: postLossSafetySeconds timer (server memory), in-flight refusal, new canGrabLive inputs, transferLive kind Live, den attributes LiveProtected / LiveGrabReadyAt |
| P0.5i | ui | P0.5h | Todo | | 0 | Show "Protected today" and the post-loss countdown from den LiveProtected / LiveGrabReadyAt (display only) |

## Resume here (for a fresh session)

State at handover (2026-10-28): integration green, all Phase 0 tasks done except the post-gate
follow-ups below. Kian approved the Phase 0 gate; he will say when to start Phase 1.
1. #62 (P0.12): DONE (merged).
2. #64 + #65 (P0.5g): a reviewer was running. If no review is posted, run a fresh `reviewer` on
   both (focus: recordLiveLoss exactly once incl. recovery, empty-commit side effects, old data,
   value rule gaming, canGrabLive order). Fix → re-review → merge #64 then #65.
3. Then P0.5h (raid): RaidService wiring per the canGrabLive changes in #64's description
   (lastLiveLossAt in server memory, set on Committed and on give-up while InFlight; in-flight
   refusal; den attributes LiveProtected / LiveGrabReadyAt). Then P0.5i (ui) display.
4. Data mirror PR: copy into docs/contracts.md (rules in #62's description): Money model:
   earned = base × mutation × placement × rebirth × factor; cap uses the unboosted rate; accrue
   at the old factor before any factor change; a factor outside [1, Economy.maxGlowBoostFactor()]
   counts as 1; a NaN `now` changes nothing. Robux-linked multipliers: glowBoostFactor({ vip,
   lanternNight, paidRandomRestricted?, purchasesEnabled }) returns 1 when restricted is true or
   nil, purchases are off, or a required field is missing/non-boolean; else 1 + bonuses (additive).
5. Studio single-client recheck after P0.5h/i (integration agent; Kian's main checkout must be
   fast-forwarded for Rojo; never switch branches there).
6. Promote integration → main with a merge commit (Kian approved the gate; "do what you need").
Open questions for Kian are under Blocked. Orchestrator ledger edits go through a worktree.

## Phase 1: Async core (not started; entry needs the Phase 0 gate)

P1.1 to P1.10 all `Todo`. See `docs/playbook.md`.

## Setup notes
- 2026-10-27: G0 cleared (Kian). Toolchain installed: rojo 7.7.1, StyLua 2.6.0, selene 0.32.0,
  lune 0.11.1 (`rokit.toml`), luau-analyze from the latest Luau release in `~/.local/bin`.
  Rojo Studio plugin installed.
- Baseline checks: tests 54/54, selene clean, luau-analyze clean. `stylua --check` fails on
  `src/Shared/Economy.luau`, `tests/run.luau` and `tests/specs/EscrowSimulation.spec.luau`
  (formatting only).
- 2026-10-27: Studio MCP connected ("Raid Night", placeId 140078354239554). Smoke test passed:
  output prints `[RaidNight] server started`. Harmless warning from the default place:
  `ContentId rbxassetid://203785492 ... Asset type does not match` (not from our code).
- 2026-10-28: Stopped for the day at Kian's request after merging #2, #3, #4 (integration at
  9b169b5, CI green, 75 tests). Ready next: P0.4 (economy), P0.3b (data), P0.3a (data); P0.7
  after a restart with the Higgsfield MCP. `workspace.StreamingEnabled` is already on.
- 2026-10-28: Kian enabled Studio Access to API Services and set Max Players to 8.
- 2026-10-28: Playbook Appendix D is out of date; `.github/workflows/ci.yml` (PR #1) is the source
  of truth (pinned tools via rokit, selene included).
- 2026-10-27: `integration` branch created from `main` with the playbook, ledger and `rokit.toml`.
- `.gitignore` has `Packages/`, which also ignores `src/Server/Packages/` where ProfileStore is
  supposed to be vendored. Fix in P0.3 (anchor the pattern to `/Packages/`).

## Blocked (needs Kian)

Not urgent: all three are needed before P2.8 ships products, nothing earlier.
- Other Robux products that raise or protect a restricted player's Glow (reviewer S1 on #59):
  vault slot (Vault critters earn 50%), auto-collect, shield, timer skips (undefined; if any
  skip covers income it grants Glow), event pass rewards, raid scout, and VIP's "non-Glow
  perks" (undefined). D-030 only switches off the two multipliers. Should all of these be
  Robux-linked too (off or reduced for restricted players), or classified one by one in the
  P2.8 audit?
- Does VIP's 1.5× apply to offline income (accrue covers both), or only while online?
- Restricted buyers: should Lantern Night be hidden from players whose policy restricts paid
  random items, and should the VIP description say the Glow bonus isn't available everywhere?

## Deferred to the end-of-phase session (Kian, 2026-10-28)

Kian has no testers available now; every multi-person check runs once at the end, with the
Phase 0 gate playtest. Until then, coverage comes from single-client Studio runs, Lune tests and
the escrow simulation. Do not ask for multi-client runs in status reports.

- 3 players: each in a different den with their name on the sign; one leaving doesn't affect
  the others; a new join gets the freed den with empty pads (P0.2).
- 2 players: other dens' prompts hidden and refused; each den shows only its owner's critters;
  a leaving player's den is cleared (P0.4, P0.6).
- 2 players: transferLive between two loaded profiles, repeat raidId, refusals, rejoin check
  (P0.3b playtest plan, with API access on and off).
- 2 servers: session-steal kick (P0.3).
- 2+ players: live stealing end to end (P0.5: multi-client checks listed in #29, #30, #32) and
  the friends playtest (Phase 0 gate).
- Live carry anti-cheat under real lag (D-025): a Light carrier frozen ~0.8 s exactly while
  crossing the gap between neighbouring dens drops as SkippedStreet (fails safe); check jitter
  doesn't cause false drops; moveRefill 1.1 feels fair.
- 2 players: a critter being carried is never auto-placed or redrawn (#47; covered by a Lune spec).
- 2 players: limit refusals (PairLimit, daily loss cap) show no message; judge if testers need one.
- Phone emulator: compact HUD column actually switches on a real small screen (#57), and the
  floor below ~330 px usable height.
- Phone emulator: HUD layout and the top-bar fix (P0.6, #17); "Free" egg label on a wiped
  profile.

## Repo rules
- 2026-10-28: repo made public, so the `protected` ruleset is now enforced on `main` and
  `integration`: changes only by PR, required status check `check` (CI), no force-push, no
  deletion, 0 approvals, no bypass. Ledger updates go through PRs too; no direct commits.

## Decisions

Full log with reasons: `docs/decisions-log.md`.

- 2026-10-28 (Kian): `Config.Flags.raids` is the master kill switch. Any raid (live, async,
  revenge) starts only if `raids` is on; async and revenge raids also need `asyncRaids`. Switches
  block new raids only; escrow recovery and in-flight transfers always complete. Implemented in
  P0.3b; RaidService must call the same check (hand-off to `raid` for P0.5).

- 2026-10-28 (Kian): live-stealing contract batch approved with conditions. Lockdown blocks
  entry only (raiders already inside can leave; a carried critter drops at the border), applies to
  live raids only, duration/cooldown enforced server-side. `CarryingUid`, `CarryingSpecies`,
  `LockdownUntil`, `LockdownReadyAt` attributes are display-only: the server keeps its own state
  and never reads them. `eggMaxTier` renormalizes allowed tiers' odds (tested); Phase 2 raises it
  to Mythic. `Config.LiveRaid` = {lockdownSeconds 45, lockdownCooldownSeconds 120, tagRange 6,
  grabHoldSeconds 1}.
- 2026-10-28 (Kian): keep the rescue egg, with guards: Common-only fixed table (independent of
  eggMaxTier); rescue critters get `untradeable = true`; "can't afford" uses banked + stored Glow
  after accruing. `Critter.untradeable: boolean?` approved (missing = tradeable, no migration);
  any future trading or gifting code must refuse it (reviewer checks).
- Live revenge needs `asyncRaids` too (follows the 2026-10-28 kill-switch wording literally).

## Gate history

- Phase 0 exit checks: passed 2026-10-28 (176 tests, CI green on 860c3f4, single-client Studio
  session with no errors; the 2-client session is deferred to Kian's end-of-phase test).
- Phase 0 gate: APPROVED 2026-10-28 (Kian, in chat), before the friends playtest; the deferred
  multi-person checks stay open for when testers are available. Do not start Phase 1 until Kian says so.
- G0: cleared 2026-10-27 (Kian, in chat)
- Style lock: cleared 2026-10-28 (Kian picked ref-01 + ref-02; body plan follows the animal)
