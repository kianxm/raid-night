# Agents playbook: how to build Raid Night with parallel agents

You are the orchestrator. Agents do the work in parallel; you decide what gets built, keep
the contracts stable, and merge. The subagent definitions live in `.claude/agents/`.

## The setup

```
main ◀── integration ◀── agent/<name>/<task>    (one branch + one worktree per task)
```

- Every task runs in its own git worktree (`claude --worktree <name>`, or agent view does it
  for you), so parallel agents never edit the same checkout.
- Every task ends in a PR into `integration`. Agents never merge their own PRs.
- The `reviewer` subagent reviews any PR that touches `src/Shared/Types.luau`, `Net.luau`,
  `Escrow.luau`, `Profile.luau` or purchases.
- The `integration` agent is the only one that drives Roblox Studio through MCP, because
  there is one Studio instance. It merges, syncs with Rojo, playtests, and reports bugs back.
- `src/Server/Packages/` is vendored third-party code only (ProfileStore today): never edit,
  lint or format it (it is excluded in `.styluaignore` and `selene.toml`), and never put our
  code there. Update it only by re-vendoring, as its decision record says
  (`docs/decisions/0003-profilestore.md`).

## Which Claude Code mechanism, when

| Situation | Use | Why |
| --- | --- | --- |
| Prototype (weeks 1-3) | One session, you + Claude, sequential | Finding the fun does not parallelize |
| Independent feature tasks (async core onward) | Agent view (`claude agents`): hand off tasks, check status, step in when one needs you | Each session gets its own worktree automatically |
| A side question inside a task (search, audit, research) | Subagents | Keeps your main context clean |
| Big uniform jobs (40 critter prompt jobs, balance sims, a codebase-wide audit) | Dynamic workflows (`/workflows`) | A script coordinates many agents and cross-checks results |
| A large mechanical change across many files | `/batch` | Splits into isolated worktree subagents that each open a PR |
| Tightly coupled work where agents must talk | Agent teams (experimental, off by default) | Only if the above fail; teammates share files, so partition carefully |

Running many agents multiplies token usage. Start with 3-4 parallel tasks, not 10.

## Rules for you, the orchestrator

1. **Contracts first.** Before a parallel round, settle any new types or remotes yourself (or
   with one agent), merge them, then fan out. Parallel agents drift when the schema moves.
2. **One task, one PR, under ~400 lines.** Small PRs review fast and revert cleanly.
3. **Merge daily into `integration`, playtest daily.** Integration pain grows with time.
4. **Gates are real.** Do not start the next phase until its gate passes (see design summary).
5. **Never let an agent grade its own work.** The reviewer and the tests decide.

## Phase 0: prototype (weeks 1-3), one session

Work with one Claude Code session yourself. The question is whether grabbing a critter and
running it home is fun live with friends; offline raids cannot save a loop that is not.

> Read CLAUDE.md and docs/design-summary.md. Build the greybox prototype: a map with 8 den
> plots, pads, borders, lazy income using Economy.luau, an egg conveyor with 10 Common and
> Uncommon critters as colored placeholder shapes, live stealing (grab, carry with weight
> slowdown, tag to drop, escape across your border), and a 45-second lockdown button. No
> persistence beyond a simple save, no async raids, no UI polish. Keep game rules in the
> Shared pure modules with tests. Tell me what to playtest with 4 friends.

Gate: 4 friends play 30+ minutes without being asked to. If not, change the loop before
Phase 1.

## Phase 1 fan-out (async core), in merge order

| # | Agent | Task | Depends on |
| --- | --- | --- | --- |
| 1 | `data` | DataService with ProfileStore; `Escrow.Store` implementation; recovery sweep | — |
| 2 | `matchmaking` | SnapshotService + MemoryStore pools + raid locks + presence | 1 (profiles) |
| 3 | `raid` | Pocket dens from snapshots, traps, guard AI, timer, end-of-raid handoff | 1, 2 |
| 4 | `ui` | Raid Portal, raid HUD, raid log, revenge button (against `Net.luau` with mocks) | contracts only |
| 5 | `economy` | Balance sim: Glow sources vs sinks per den level; tune `Config.luau` | — |

Tasks 1, 4 and 5 can start on day one in parallel. 2 starts when 1's profile API is merged.

## Kickoff prompts (paste into a new agent session)

**data, task 1**
> Read CLAUDE.md, docs/contracts.md and src/Shared/Escrow.luau. Implement DataService with
> ProfileStore (vendored at src/Server/Packages/ProfileStore.luau) following the TODOs in the
> file, then EscrowService implementing the Escrow.Store interface and the recovery sweep.
> Do not change Escrow.luau's behavior; the simulation must still pass. Open a PR into
> `integration` with a test plan the integration agent can run in Studio.

**matchmaking, task 2**
> Read CLAUDE.md and src/Shared/Matchmaking.luau. Implement SnapshotService and
> MatchmakingService per their TODOs: snapshots on leave and on the interval, MemoryStore
> sorted maps per power band, raid locks with TTL, and the presence map. Keep all selection
> logic in Matchmaking.luau with tests. PR into `integration`.

**raid, task 3**
> Read CLAUDE.md, docs/design-summary.md (Async raids) and src/Shared/RaidRules.luau.
> Implement async raids in RaidService: StartRaid checks, pocket den built from a snapshot far
> off-map, traps and simple guard AI, 3-minute timer, server-authoritative grabs and carrying,
> and handoff to EscrowService on escape. Record replay frames at 5 Hz. PR into `integration`.

**ui, task 4**
> Read CLAUDE.md and src/Shared/Net.luau. Build the Raid Portal (3 targets + revenge targets
> first), the in-raid HUD (timer, carried critter, escape arrow) and the raid log panel that
> opens on login when something happened. Use mock data behind the Net contract so you do not
> depend on server work. Mobile-first layout. PR into `integration`.

**economy, task 5**
> Read CLAUDE.md and src/Shared/Economy.luau. Write tools/sim/economy.luau (Lune) that
> simulates a player from level 1 to rebirth with realistic play patterns, and report time to
> each den level, Glow held vs egg prices, and raid loot as a share of income. Propose Config
> changes in a PR with the before/after numbers. Do not change behavior, only values.

**reviewer (after any contract or escrow PR)**
> Review PR <number> against CLAUDE.md and docs/contracts.md. Run lune run tests/run.luau.
> Hunt specifically for duplication paths, client trust, non-idempotent writes and contract
> drift. Reply with blocking issues first, then suggestions.

**integration (daily)**
> Merge approved PRs into `integration`, run the tests, sync with Rojo, playtest in Studio via
> MCP with 2+ test clients, and file every bug as an issue assigned to the owning agent. Post
> a short daily status: merged, broken, blocked.

**assets (any time, in parallel with code)**
> Read docs/style-bible.md and docs/asset-pipeline.md. Run lune run tools/assets/build_prompts.luau,
> then generate turnaround images for the next 5 critters in assets/jobs/, stopping for my
> approval before any 3D generation.
