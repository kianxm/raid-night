# Raid Night

A Roblox steal-and-collect game where your den earns, and gets raided, while you are offline.

This repo is the foundation: contracts, tested core logic, agent setup and asset pipeline.
No gameplay code is written yet, on purpose.

## Start here

1. `docs/setup.md`: day-0 checklist (accounts, tools, Studio, Claude Code connections)
2. `docs/design-summary.md`: what we are building
3. `CLAUDE.md`: rules every agent follows
4. `docs/agents.md`: how to run agents in parallel, with kickoff prompts
5. `docs/asset-pipeline.md` and `docs/style-bible.md`: how art gets made

## What is already done

| Piece | Where | Status |
| --- | --- | --- |
| Shared contracts (types, remotes, config) | `src/Shared/Types.luau`, `Net.luau`, `Config.luau` | Done |
| 40 launch critters | `src/Shared/Data/Critters.luau` | Done, validated |
| Economy math | `src/Shared/Economy.luau` | Done, tested |
| Raid rules (shields, caps, protection, revenge) | `src/Shared/RaidRules.luau` | Done, tested |
| Matchmaking and snapshots | `src/Shared/Matchmaking.luau` | Done, tested |
| Escrow (no-dupe transfers) | `src/Shared/Escrow.luau` | Done, 1,000-raid crash simulation |
| Profile defaults and migrations | `src/Shared/Profile.luau` | Done |
| Server and client services | `src/Server`, `src/Client` | Skeletons with owners and TODOs |
| Agent roster | `.claude/agents/` | 9 agents |
| Asset prompts for all 40 critters | `assets/jobs/` | Generated |

## Run the tests

```bash
lune run tests/run.luau
```

Expected: `54 passed, 0 failed`.

## Layout

```
src/Shared/     pure logic + contracts (ReplicatedStorage.Shared)
src/Server/     services (ServerScriptService.Server)
src/Client/     controllers + UI (StarterPlayerScripts.Client)
tests/          Lune tests
tools/assets/   prompt builder + generation script
assets/         jobs, raw (ignored), clean, ui, audio
docs/           design, contracts, setup, agents, style, decisions
.claude/agents/ subagent definitions
```
# raid-night
