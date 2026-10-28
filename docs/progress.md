# Progress

Current phase: 0 · Last updated: 2026-10-28

## Phase 0: Prototype (parallelism 2)

| Task | Agent | Depends | Status | Branch / PR | Attempts | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| P0.1 | integration | — | Done | #1 | 1 | CI green (tests, StyLua, selene, luau-analyze via rokit). Baseline StyLua diffs fixed |
| P0.2 | raid | — | In review | #3, #4 | 1 | Split for size: #3 Plots pure logic (+326), #4 DenWorldService (+421, stacked). CI green on both. Place settings hand-off: Max Players 8 (Kian), remove template Baseplate/SpawnLocation |
| P0.3 | data | — | In review | #2 | 1 | ProfileStore 1.0.3 vendored. `Config.Flags` approved by Kian 2026-10-28. Reviewer APPROVED (no blockers). Integration: merge + Studio rejoin test |
| P0.3a | data | P0.3 | Todo | | 0 | Reviewer follow-ups on #2: S1 fail-closed flag check, S3 stamp only true templates, S4 session/Player guard, S6-S8 docs |
| P0.3b | data | P0.3 | Todo | | 0 | Reviewer S5: DataService save-now-and-confirm + same-server Escrow.Store so P0.5 live steals go through Escrow durably. Prerequisite for P0.5 |
| P0.4 | economy | P0.3 | Todo | | 0 | |
| P0.5 | raid | P0.2, P0.4, P0.3b | Todo | | 0 | P0.3b added: live steals are cross-profile moves (golden rule 4) |
| P0.6 | ui | P0.4 | Todo | | 0 | |
| P0.7 | assets | — | Blocked | agent/assets/P0.7 | 1 | Higgsfield trial allows MCP-only generation; CLI refused all 10 calls (0 credits spent, 110 left). Ready: seedream_v4_5, 10 prompts, 1 credit each. Needs session restart with Higgsfield MCP loaded |
| P0.8 | integration | P0.5, P0.6 | Todo | | 0 | |

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
- 2026-10-28: Playbook Appendix D is out of date; `.github/workflows/ci.yml` (PR #1) is the source
  of truth (pinned tools via rokit, selene included).
- 2026-10-27: `integration` branch created from `main` with the playbook, ledger and `rokit.toml`.
- `.gitignore` has `Packages/`, which also ignores `src/Server/Packages/` where ProfileStore is
  supposed to be vendored. Fix in P0.3 (anchor the pattern to `/Packages/`).

## Blocked (needs Kian)
- P0.7: restart Claude Code so the Higgsfield MCP loads (trial accounts can't generate through the
  CLI). Refused CLI calls produced nothing and cost 0 credits; the 10-image cap is treated as unused.
- Repo protections: GitHub Free (private repo) does not enforce rulesets; Kian created one but it
  is inactive until Pro. Decision 2026-10-28: PRs-only by convention for Phase 0; revisit (upgrade
  to Pro) before Phase 1 fan-out.

## Gate history
- G0: cleared 2026-10-27 (Kian, in chat)
