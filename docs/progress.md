# Progress

Current phase: 0 · Last updated: 2026-10-28 (evening)

## Phase 0: Prototype (parallelism 2)

| Task | Agent | Depends | Status | Branch / PR | Attempts | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| P0.1 | integration | — | Done | #1 | 1 | CI green (tests, StyLua, selene, luau-analyze via rokit). Baseline StyLua diffs fixed |
| P0.2 | raid | — | Done | #3, #4 | 1 | 107 parts, 48 lights. Studio (1 client): own den + sign, respawn, walkable border, leave clears den. Multi-client spawn/reassign verified by Lune tests only; 3-client Studio check pending (Kian) |
| P0.3 | data | — | Done | #2 | 1 | Reviewer APPROVED. Studio: survives rejoin on real DataStore, fresh-save stamping, flags. Not verified: 2-player leave, session-steal kick (needs 2 servers) |
| P0.3a | data | P0.3b, C1 | Todo | | 0 | Reviewer follow-ups on #2: S3 stamp only true templates, S4 session/Player guard, S6-S8 docs. S1 moved into P0.3b (same file). Runs after P0.3b to avoid DataService conflicts |
| P0.3b | data | P0.3 | In progress | #11 | 2 | Reviewer REQUEST CHANGES: B1 prune of open escrows (loss/dupe), B2 index removed during create, B3 Refused for in-flight raidIds. Fix round running (D-006, D-007). Kill-switch contract change (approved 2026-10-28): `raids` is the master switch, async/revenge also need `asyncRaids`, recovery never gated; pure check + flag-combination and recovery-while-off tests; reviewer pass. Reviewer S5 + S1 + S2 (enforce flag inside the entry point): DataService save-now-and-confirm + same-server Escrow.Store so P0.5 live steals go through Escrow durably. Prerequisite for P0.5 |
| P0.4 | economy | P0.3 | Done | #9, #10 | 1 | Studio (1 client) passed steps 1-8: egg, collect math, pads/overflow, swaps, 15 bad payloads refused, rate limit, upgrade costs. Rejoin persistence and 2-client checks being rerun. Note: Inventory is uncapped (balance item) |
| C1 | data | — | In progress | agent/data/C1 | 1 | Runs in parallel with the P0.3b fix round (D-009). Approved contract batch (2026-10-28, see Decisions): Net `Lockdown` + limit 3; display-only attributes; `Config.LiveRaid`; `Config.Economy.eggMaxTier`; `Critter.untradeable`. Reviewer pass |
| P0.4b | economy | C1 | Todo | | 0 | eggMaxTier from Config; rescue egg rolls Common-only from its own table, sets `untradeable`; accrue before the rescue check (uncollected Glow counts) |
| P0.5 | raid | P0.2, P0.4, P0.3b, C1, P0.4b | Todo | | 0 | P0.3b added: live steals are cross-profile moves (golden rule 4) |
| P0.6 | ui | P0.4 | Done | #12, #17 | 1 | #17 fixed the top-bar overlap (issue #15); Studio recheck with P0.6b. Client only; not run in Studio yet (phone emulator check in the P0.8 session). Lockdown button disabled until the remote exists |
| P0.6b | ui | C1 | Todo | | 0 | Swap the `LOCKDOWN_REMOTE` constant for `Net.Requests.Lockdown` |
| P0.7 | assets | — | Done | #5 | 2 | 10 images via Higgsfield MCP (seedream_v4_5, 10 credits, 100 left). Style locked by Kian: ref-01 (finish) + ref-02 (night lighting) in `assets/clean/_style/`. Body plan follows the animal (style bible). Stage 1 follow-up: `tools/assets/generate.sh` STYLE_REFS still lists ref-03/ref-04, which do not exist |
| P0.8 | integration | P0.5, P0.6, P0.6b | Todo | | 0 | |

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
- Multi-client check (Studio MCP can't start Test > Clients and Servers): run a 3-player Local
  Server once. Each player in a different den with their name on the sign; Player2 leaving doesn't
  affect Player1; a new join gets the freed den with empty pads. Also folded into P0.8.

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
- G0: cleared 2026-10-27 (Kian, in chat)
- Style lock: cleared 2026-10-28 (Kian picked ref-01 + ref-02; body plan follows the animal)
