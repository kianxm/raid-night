# Progress

Current phase: 2 (started 2026-10-29, unattended overnight; D-057) · Last updated: 2026-10-29

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
| P0.9 | economy | — | Done | #50 | 1 | Egg odds helpers (tier, rescue, species, next egg) matching the real rolls; Glow packs out of PurchaseService (D-028) |
| P0.10 | ui | P0.9 | Done | #51 | 1 | Odds chip + panel (D-028). Studio-checked. Fixes for #54 (phone layout) and #55 (per-species rounding) in P0.10b |
| P0.11 | economy | — | Done | #53 | 1 | PurchaseService catalog header for D-029 |
| P0.10b | ui | P0.10 | Done | #57 | 1 | Fixes #54 (compact column on short screens, fit tested 320-900 px) and #55 (true per-species odds). Studio-simulated; real phone check deferred |
| C2 | data | — | Done | #59 | 1 | Reviewer APPROVED. Config.Boosts + contracts.md Robux-linked multipliers (D-030) |
| P0.12 | economy | C2 | Done | #62 | 2 | Reviewer APPROVED; S1/S2/S5 landed: glowBoostFactor({ vip, lanternNight, paidRandomRestricted?, purchasesEnabled }) fails closed, factor clamped to [1, maxGlowBoostFactor()], NaN `now` ignored. 206 tests |
| P0.5g | data | — | Done | #64, #65 | 1 | Reviewer APPROVED both. Value-based live protection, postLossSafetySeconds, live pair limit, EscrowRecord.kind, simulation reaches protection 53-65x per seed. 225 tests on integration. Follow-ups: D-033 (data), base-measurement question (Kian) |
| C4 | data | P0.5g | Done | #73, #74 | 1 | Reviewer APPROVED. D-033, D-034 (`EscrowRecord.liveBaseRate`, transferLive 7th arg), NaN test, contracts.md mirror of #62. P2.8 gate: the factor-1 accrue in EscrowService/Matchmaking must be fixed before `purchases` turns on. Studio-verified (D-033 empty commit, D-034 shrink mid-carry) |
| P0.5h | raid | P0.5g, C4 | Done | #71 | 1 | Reviewer APPROVED. Base measured at grab-hold accept; source guard pins it; loss time keeps fractional seconds; server hides prompts on closed dens. Studio-verified (single client). 242 tests on integration (f50ab1c) |
| C5 | data | C4 | Done | #79 | 1 | Reviewer APPROVED. D-036 (protection vs max(base, current rate)) and D-037 (debit also counts the grab-time rate). Note: the simulation's day-total loss invariant is now implied by the per-debit check; consider a day-high check in P1.1. Studio-verified single client (plan step 4 hits PairLimit as written; rerun on a fresh seed: fix the plan text or add a test-hook pair reset). 256 tests on integration (973d261) |
| P0.5j | ui | — | Done | #80 | 1 | Reviewer APPROVED. Copy "Protected" / "Protected from steals"; chip 200 px. Log-only "live-protected today" text in RaidService left (raid, cosmetic) |
| P0.5i | ui | — | Done | #70 | 1 | Den marker "Protected today" / "Safe for m:ss", own-den chip, steal prompt hidden while protected. Refusal copy built but no channel to show it (D-035). Cosmetic edge: a prompt the server disabled while protection hid it comes back on when protection ends (server still refuses) |

## Resume here (for a fresh session)

Read `docs/orchestrator-handoff.md` first; it is the current state. Follow the playbook's
"Context discipline" (section 2).

## Phase 1: Async core (parallelism 4)

Started 2026-10-29 (Kian: "Run Phase 1", unattended overnight; D-041).

| Task | Agent | Depends | Status | Branch / PR | Attempts | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| P1.1 | data | — | In review | #97, #98 (stacked) | 1 | #97 pure async rules + EscrowSimulation; #98 messages, one-shot offline write, transferAsync, 60 s sweep, dupe alarm, D-008 ids, D-026. 269 tests. Async loot accrues to debit time. Reviewer (xhigh) APPROVED both; fix round (D-049) re-reviewed APPROVED (275 tests; mutation runs). Own Studio run waits for merge (D-044) |
| P1.2 | matchmaking | P1.1 | Done | #91 | 1 | Reviewer APPROVED. Studio single-client plan passed (targets from test-account snapshots, locks, blocks, presence). Only offline dens are async targets (D-043). 271 tests |
| P1.3 | raid | P1.1, P1.2 | In progress | P1.3a: #100, #101 (stacked), in review; P1.3b: Todo | 1 | Split (D-046). #100 contracts + pure rules, #101 server + pocket den: reviewer APPROVED both, 286 tests (D-050). P1.3c #103 (data, markRaidLogSeen, stacked on #100): reviewer APPROVED, 287 tests; the RaidLogSeenAt attribute keeps its load value. P1.3b #106: escape → transferAsync, RaidEnded Committed/InFlight(pending)/Refused, presence-failure refusal; 318 tests; reviewer APPROVED (+2 small follow-ups). P1.3d #109 (data, stacked on #107): raider Outgoing log, pair count, revenge token removed on a moving credit (D-054); EscrowRecord.revengeRaidId + transferAsync 7th arg; 329 tests; simulation extended with async revenge. P1.3e #110 (raid one-liner passing revengeRaidId, stacked on #109). Reviewer (xhigh) APPROVED #109 and #110; all mutations caught. P1.3b = escrow handoff, shield, revenge token, logs, pair limit, markRaidLogSeen (after P1.1 fix round) |
| P1.4 | raid | P1.3 | In review | P1.4a: #99 (approved); P1.4b: #107 (stacked on #106), reviewer APPROVED | 1 | Split (D-046). #99: 3-min raid = 1,768 bytes, ±0.25 stud, reviewer APPROVED (decode fuzzed), 281 tests; GetReplay limit 3 and 7-day index cleanup approved (D-048). P1.4b = hook into raids after P1.3a, using save() not saveNow() |
| P1.5 | ui | — | Done | #89, #92 (open) | 1 | Studio: log, HUD, outcome card pass; portal blank (#90). Fix #92 reviewed, merge refused by the permission check (Needs Kian). Phone sizes not emulated (deferred). ~986 lines accepted as one unit |
| P1.6 | ui | P1.3, P1.5 | In review | #102, #108 | 1 | Stacked on #100, contains #92 and #94 (D-044). #108 (stacked on #102): "On its way!" and Glow-only outcome cards for #106. Real remotes, revenge + join-server flow, block list via GetCore (D-051). 290 tests, CI green. UI: no review. Studio plan and the two-account loop wait (Kian) |
| P1.7 | economy | — | In review | #95 | 1 | Sim + report (in PR description), CI green, 271 tests. Proposal needs Kian: no numeric design range, sets a ~3-week first-rebirth pace (D-045). Found: async loot reads leave-time stored Glow (sent to P1.1); den world builds 6 pads vs design 6→30 (raid, Phase 2); rebirth impossible until eggMaxTier rises (D-003) |
| P1.8 | economy | P1.7 | Done | #96 (via preview/phase1) | 1 | Approved by Kian at the gate. Prepared: 3 Config values, sim matches #95's after numbers, 271 tests. Merge only on Kian's approval (D-045) |
| P1.9 | matchmaking | P1.2 | In review | #94; P1.9b #105 (stacked) | 1 | #105 (raid): live steal escapes as a revenge transfer when getLiveRevenge is active; 280 tests; token not spent yet (D-052); reviewer APPROVED (no Glow bonus on live revenge, retries keep identical args). Reviewer APPROVED, 276 tests, CI green; merge waits for Kian (D-044). Studio single-client plan and the two-server check not run (Kian). RaidService wiring of getLiveRevenge handed to P1.3 |
| P1.10 | integration | P1.6, P1.9 | Done | #104, #112, #115 | 1 | Single-server soak clean 2026-10-29 (P1.10g, integration 506fe40, test ids only): ~30 min, 24 raids, 7 forced stops mid-transfer (Stop ~5 s, recovery 1-3 s), 0 dupes, 0 losses, 0 errors; soak-4 recovered once; #114 fixed by #115. Multi-client parts stay on the deferred list |

## Phase 2: Vertical slice (parallelism 4)

Started 2026-10-29 (Kian: "Run Phase 2", unattended overnight). No Higgsfield credits: placeholder
art and sound, generation blocked (D-057). Merges wait for Kian; PRs stack, `preview/phase2` proves
the stack (D-058). Profile fields for the phase come in one batch, C6 (D-059).

| Task | Agent | Depends | Status | Branch / PR | Attempts | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| C6 | data | — | In progress | agent/data/C6 | 1 | Phase 2 optional profile fields (settings, onboarding, notifications, gear, purchases, analytics), no migration |
| P2.1 | assets | — | Blocked | #87 (open) | 1 | Generation paused: no credits (D-057); Gate 1 picks are Kian's. Prompts and 40 fronts done in #87 |
| P2.2 | assets | — | Todo | | 0 | Briefs + prompts only; generation blocked (D-057) |
| P2.3 | raid | — | In progress | agent/raid/P2.3 | 1 | Was P2.2: kit seam with placeholder pieces, pads 6→30, mobile perf pass (D-057) |
| P2.4 | economy | — | Todo | | 0 | Was P2.1: model-id seam with placeholder fallback, mutation effects, eggMaxTier → Mythic (D-057) |
| P2.5 | ui | — | In progress | agent/ui/P2.5 | 1 | Full UI pass, inventory, den mgmt, settings, strings table, sound hooks with empty ids (P2.11 stand-in) |
| P2.6 | ui | P2.5, C6 | Todo | | 0 | Onboarding (Appendix C) |
| P2.7 | notifications | — | In progress | agent/notifications/P2.7 | 1 | Send rules, opt-in timing, launch data; strings for Kian |
| P2.8 | economy | C6 | Todo | | 0 | Passes/products, glow-factor helper, policy audit; products for Kian |
| P2.9 | data | C6 | Todo | | 0 | Analytics events (Appendix A) + funnels |
| P2.10 | raid | C6, P2.3 | Todo | | 0 | Gear (live only for lockpick) |
| P2.11 | assets | — | Blocked | | 0 | No credits (D-057); sound hooks ship empty in P2.5 |
| P2.12 | integration | all | Todo | | 0 | Closed-test build + kit; access setup is Kian's |

## Setup notes
- 2026-10-28: Studio MCP command bar `require(DataService)` gets a separate module copy (nil
  profiles); check profiles through a temporary server Script instead. `StudioMemoryProfiles`
  is left true in the open edit place (unsaved, unpublished).
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

- Merges: the permission check refuses `gh pr merge` (D-044/D-058). Phase 1 ledger #116 and every
  Phase 2 PR wait for you; merge order is in the gate report.
- Higgsfield credits for P2.1/P2.2/P2.11 generation, and Asset Gate 1 picks (#87).

P2.8 product questions (defaults chosen in D-061; confirm or overturn at the gate):
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
- 2 players: limit refusals (PairLimit, LiveProtected, PostLossSafety) show no message; judge if testers
  need one (D-035: copy is ready, needs a GrabRefused push).
- Phone emulator: compact HUD column actually switches on a real small screen (#57), and the
  floor below ~330 px usable height.
- Phone emulator: HUD layout and the top-bar fix (P0.6, #17); "Free" egg label on a wiped
  profile.
- Live loss rules (#71/#73): a second raider grabbing during a carry gets PostLossSafety; a second
  client sees LiveProtected / LiveGrabReadyAt replicate with a matching countdown; a real owner
  leaving mid-window leaves the den clean for the next owner; a real owner moving earners via
  PlaceCritter mid-carry keeps the grab-time base; the owner sees nothing during the 1 s hold;
  a UTC day roll clears LiveProtected within 0.5 s; no raid-log entry for a real empty steal.
- Phone emulator: Raid Portal, in-raid HUD, raid log and outcome card at 667x375 and 844x390 (P1.5, #89/#92); Studio viewport could not be resized.
- Phone emulator: den status chip and markers (P0.5i, #70); the 200 px chip (#80) may overlap the
  top-centre toast below ~700 px wide (667x375 landscape): check, or move/narrow it.
- Live protection (D-036/D-037): an owner buying an egg after a protecting loss (auto-place lifts
  protection); an owner vaulting during a carry from a refilled den (the steal still lands).

## Hardening backlog (triage after the phase playtest, D-039)

Exploit and fairness edge cases that lose nothing and fail safe. One line each: what, where it
came from, rough size. Not fixed before the phase's human playtest; then kept, scheduled or
dropped based on real play.

- Pool withdraw uses the band from load-time power; an offline raid that moved the den two bands leaves a stale entry while online (reviewer #91, MatchmakingService:594; small).
- Leave-publish race on a server hop plus up to 60 s of pool cache can relist an online player (reviewer #91; P1.3 refuses async raids on fresh presence; small).
- A raider can block their victim after a raid to hide from revenge (reviewer #91; decide after playtest).
- Raider's own block list is session-only until their first ReportBlocked; fall back to the last snapshot (reviewer #91; small).
- Studio hook `targets` also skips the `raids` gate; doc says asyncRaids only (reviewer #91; Studio only, doc fix).
- Escrow (reviewer #98): a debit finished in another server is credited only on the raider server's next retry (up to 30 min backoff); a crashed server's stale lock keeps a defender "held" until they return (consider ProfileStore's 630 s assume-dead); unbounded MessageAsync retry threads during an outage (one pending send per user+raid); the dupe alarm can't see a critter both parties own (assert at credit); an erased defender save errors forever (park it). All fail safe.
- Escrow follow-ups (re-review #97/#98): two sameApplied asserts (different `at`; saved critter with an extra field); a repeat transferAsync after Commit or a dupe alarm whose read fails reports Refused though the loot moved (status only).
- Finished escrow records are never deleted (D-008 cleanup deferred, D-047; storage growth only; proposal in #98).
- ReplayStore: cap expired-replay deletes per save (~4) so a returning raider's 64-delete burst can't drain the DataStore budget; delete the dropped list even if SetAsync fails; cache fetched records; finite startedAt check (reviewer #99; small).
- DenSnapshot has no losses-today count, so StartRaid assumes 0 (the escrow debit still enforces the cap) (raid #100; matchmaking; small).
- Async raids (reviewer #101): trap slow / Net is judged against the new walk speed at once, so a carrier with >150 ms ping can drop as TooFast (fails safe; add a grace); no movement budget before a grab lets a teleport skip guards/traps on the way in (carry back is checked); presence read error should be reported by matchmaking, not read as offline (P1.3b refuses on error); confirm StreamingEnabled is on in the place so pockets stay hidden.
- Client RaidMath helpers (hintKey, failKey, outcomeKey) have no unit tests (tests/ is outside ui's lane; small).
- markRaidLogSeen could take os.time() itself instead of a passed `now`; a fast server clock leaves a future value (display only) (reviewer #103; tiny).
- Live revenge doesn't spend the revenge token on commit: needs optional revengeRaidId on transferLive / Escrow.create / the record, spent at the raider credit (data), then a one-line raid change (raid #105, D-052; small-medium). RaidEnd has no revenge flag for a "Revenge!" screen (ui; optional).
- Live revenge: asyncRaids flipped off between the escape re-read and transferLive refuses the carry instead of a plain steal (fails safe); getLiveRevenge per hold step could be cached (reviewer #105; tiny).
- Async shield memory is per server: a raider who hops servers can re-raid a just-shielded offline den until the snapshot/pool catches up (raid #106; small).
- Raid lock TTL 240 s (raid 180 s + up to ~2 min escrow) can expire; raise it or refresh before escape (reviewer #106). Earlier note: lock TTL during a long raid plus a slow transfer (raid #106; small).
- MatchmakingService.getPresence swallows read failures; return (nil, false) so callers fail closed (raid #106; tiny).
- Live path never calls recordOutgoing: live raiders get no Outgoing log entry or raider pair count (data #109; pre-existing; small).
- An empty Async debit still counts a pair slot on the defender's side (data #109; pre-existing; fairness).
- While a revenge transfer is InFlight the lock is released and the token still exists, so a second revenge raid on the same token is possible (bounded by the pair limit; refuse tokens named by an open escrow) (reviewer #109; small). RaidRules.recordOutgoing doc comment is stale vs D-053 (raid; tiny).
- A credit still in flight doesn't count toward the raider's pair limit yet (data #109; small).
- Soak tooling: Studio test sessions added in #112 (D-056). Test keys to delete by hand: Player_-1000001..9, Escrow_soak-1..27, Open_-1000001..9. docs/playtests/phase1.md part 3 should switch the soak to `DataTestHook` load/seed/release with test ids only (integration; small). Seeded test stored jumps 1000 → ~36900 on first raid from an old storedUpdatedAt (kit text stale).
- (Done, see P1.10 row) Earlier partial soak (P1.10e, 2026-10-29) ~15 of 30 min with #112 test sessions: 4 cycles, 0 dupes, 0
  losses, 0 game errors; Studio wedged on the first forced stop with StudioEscrowPause active (same
  as D-055's run). Issue #114 (data) investigating; retry needs a Studio restart. Test keys left:
  Player_-1000001..5, Escrow_soak-1..4 (soak-4 Pending: the recovery evidence), Open_-1000001/5.
- releaseTestSession can report "saved" from an autosave already in flight (reviewer #112; cosmetic). ReplayStore SetAsync passes raw {raider, defender} ids; apply the accounts filter if a test id can reach it (raid; tiny).
- Pool memory at scale: 7-day entries may exceed MemoryStore quota (matchmaking #91; medium). Five more edge cases listed in #91.
- Revenge landing: arrive()'s 0.2 s wait can lose to DenWorldService onCharacterAdded and send the player home (reviewer #94; UX).
- Revenge join `pending` expires at 30 s while TeleportAsync may be in flight, allowing a second attempt (reviewer #94; fails safe).
- getLiveRevenge can miss a block that exists only in a snapshot and was added after arrival (reviewer #94; rare).
- `raiderOnline` tells a victim whether their raider is online (reviewer #94; privacy note, by design, blocks respected).
- seenOnline: one MemoryStore read per revenge row per GetRaidTargets (15 s cache); watch the budget (reviewer #94). Six more in #94.

## Repo rules
- 2026-10-28: repo made public, so the `protected` ruleset is now enforced on `main` and
  `integration`: changes only by PR, required status check `check` (CI), no force-push, no
  deletion, 0 approvals, no bypass. Ledger updates go through PRs too; no direct commits.
  Batch them: one ledger PR per merge wave, `gh pr merge --auto` (D-039).

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

- Promotion: integration → main after the Phase 1 gate, 2026-10-29 (#117, 1a877da).

- Phase 1 exit checks: tests green on integration (348, EscrowSimulation included); soak clean
  (P1.10g); multi-person checks deferred to the playtest per Kian. 2026-10-29.
- Phase 1 gate: APPROVED 2026-10-29 (Kian, in chat), including the P1.8 tuning (#96). Landed by
  merging `preview/phase1` (all Phase 1 PRs + #96 + this ledger) into integration. Still open: the
  soak and the multi-person checks (deferred list), run with testers like Phase 0.

- Promotion: integration → main after the post-gate follow-ups (C4, P0.5h, P0.5i), 2026-10-28.
- Phase 0 exit checks: passed 2026-10-28 (176 tests, CI green on 860c3f4, single-client Studio
  session with no errors; the 2-client session is deferred to Kian's end-of-phase test).
- Phase 0 gate: APPROVED 2026-10-28 (Kian, in chat), before the friends playtest; the deferred
  multi-person checks stay open for when testers are available. Do not start Phase 1 until Kian says so.
- G0: cleared 2026-10-27 (Kian, in chat)
- Style lock: cleared 2026-10-28 (Kian picked ref-01 + ref-02; body plan follows the animal)
