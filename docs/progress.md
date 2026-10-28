# Progress

Current phase: 0 · Last updated: 2026-10-27

## Phase 0: Prototype (parallelism 2)

| Task | Agent | Depends | Status | Branch / PR | Attempts | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| P0.1 | integration | — | In progress | agent/integration/P0.1 | 1 | Also fix 3 baseline StyLua diffs (see below) |
| P0.2 | raid | — | Todo | | 0 | |
| P0.3 | data | — | In progress | agent/data/P0.3 | 1 | Vendor ProfileStore (approved). `Config.Flags` is a contract change: propose first |
| P0.4 | economy | P0.3 | Todo | | 0 | |
| P0.5 | raid | P0.2, P0.4 | Todo | | 0 | |
| P0.6 | ui | P0.4 | Todo | | 0 | |
| P0.7 | assets | — | Blocked | | 0 | Needs a credits budget from Kian before generating |
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
- 2026-10-27: `integration` branch created from `main` with the playbook, ledger and `rokit.toml`.
- `.gitignore` has `Packages/`, which also ignores `src/Server/Packages/` where ProfileStore is
  supposed to be vendored. Fix in P0.3 (anchor the pattern to `/Packages/`).

## Blocked (needs Kian)
- P0.3: approve the `Config.Flags` contract change (proposal posted in chat 2026-10-27).
- P0.7: credits budget for style exploration.

## Gate history
- G0: cleared 2026-10-27 (Kian, in chat)
