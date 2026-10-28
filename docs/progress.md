# Progress

Current phase: 0 · Last updated: 2026-10-28

## Phase 0: Prototype (parallelism 2)

| Task | Agent | Depends | Status | Branch / PR | Attempts | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| P0.1 | integration | — | Done | #1 | 1 | CI green (tests, StyLua, selene, luau-analyze via rokit). Baseline StyLua diffs fixed |
| P0.2 | raid | — | In progress | agent/raid/P0.2 | 1 | |
| P0.3 | data | — | In progress | agent/data/P0.3 | 1 | Vendor ProfileStore (approved). `Config.Flags` approved by Kian 2026-10-28 |
| P0.4 | economy | P0.3 | Todo | | 0 | |
| P0.5 | raid | P0.2, P0.4 | Todo | | 0 | |
| P0.6 | ui | P0.4 | Todo | | 0 | |
| P0.7 | assets | — | Todo | | 0 | Budget approved: 10 images max, no retries. Higgsfield CLI 1.2.2 authed; MCP added (needs session restart) |
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
- Repo protections: the repo is private on GitHub Free, which offers neither branch protection nor
  rulesets (API returns 403). Options are in PR #1: upgrade to Pro (recommended), make the repo
  public, or enforce by convention. Until then, PRs-only is by convention.

## Gate history
- G0: cleared 2026-10-27 (Kian, in chat)
