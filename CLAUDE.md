# Raid Night — instructions for every agent

Raid Night is a Roblox steal-and-collect game where your den earns while you are offline,
gets raided while you are offline, and a notification names the raider so you come back for
revenge. Read `docs/design-summary.md` before your first task.

## Golden rules

1. **The server decides everything.** Clients request; the server validates and acts. Never
   trust a client payload, position or timestamp.
2. **Contracts are shared and slow to change.** `src/Shared/Types.luau`, `src/Shared/Net.luau`
   and `src/Shared/Config.luau` are contracts. Changing one means updating
   `docs/contracts.md` in the same commit and getting a `reviewer` pass.
3. **Pure logic stays pure.** Everything in `src/Shared/` (except `Net.luau` names) is pure Luau:
   no Roblox services, no `os.time()`, no randomness inside. Pass `now` and random numbers in.
   That is what lets `lune run tests/run.luau` test it without Studio.
4. **Never duplicate or lose a critter.** All cross-profile moves go through `Escrow.luau`.
   Never write another player's profile directly.
5. **Stay in your lane.** Each agent owns specific folders (table below). Need a change outside
   them? Note it in your PR description and hand it to the owner. Do not edit it yourself.
6. **No paid randomness at launch, no ransom.** Robux never buys eggs or luck at launch, and
   nothing ever sells a stolen critter back.
7. **Public information only.** Build only on public Roblox APIs, docs and announcements.

## Layout

```
src/Shared/        pure logic + contracts   -> ReplicatedStorage.Shared
src/Shared/Data/   static design data (critters)
src/Server/        services                 -> ServerScriptService.Server
src/Client/        controllers + UI         -> StarterPlayerScripts.Client
tests/             Lune tests for src/Shared (run without Studio)
tools/assets/      asset pipeline (Higgsfield prompts and generation)
assets/            raw (git-ignored), clean (approved), ui, audio
docs/              design summary, contracts, setup, agents playbook, decisions
.claude/agents/    subagent definitions
```

## Commands

| What | Command |
| --- | --- |
| All tests | `lune run tests/run.luau` |
| One spec | `lune run tests/run.luau Escrow` |
| Format | `stylua src tests tools` |
| Lint | `selene src` |
| Type-check pure logic | `luau-analyze src/Shared/*.luau src/Shared/Data/*.luau` |
| Sync to Studio | `rojo serve` (then connect the Rojo plugin) |
| Build asset prompts | `lune run tools/assets/build_prompts.luau` |

## Ownership

| Agent | Owns | Never touches |
| --- | --- | --- |
| `data` | `src/Server/Services/DataService.luau`, `EscrowService.luau`, `src/Shared/Escrow.luau`, `src/Shared/Profile.luau` | UI |
| `economy` | `src/Shared/Economy.luau`, `Config.luau` values, `Data/Critters.luau` stats, `IncomeService`, `PurchaseService` | Escrow |
| `raid` | `src/Shared/RaidRules.luau`, `RaidService.luau`, `src/Server/Raid/**`, den/pocket world code (`DenWorldService`, `Plots.luau`) | Profiles directly |
| `matchmaking` | `src/Shared/Matchmaking.luau`, `MatchmakingService`, `SnapshotService` | Escrow |
| `notifications` | `NotificationService.luau` | Everything else |
| `ui` | `src/Client/**` | `src/Server/**` |
| `assets` | `tools/assets/**`, `assets/**`, `docs/style-bible.md` | Game code |
| `integration` | The only agent that drives Roblox Studio (MCP), playtests, merges | Feature code |
| `reviewer` | Read-only. Reviews every PR touching contracts, escrow or purchases | Writing code |

## Definition of done (every task)

- [ ] `lune run tests/run.luau` passes, and new pure logic has tests
- [ ] `stylua --check src tests tools`, `selene src` and `luau-analyze` on `src/Shared` are clean
- [ ] Contract changes are reflected in `docs/contracts.md`
- [ ] PR description says what changed, what was tested, and anything handed to another owner

## Working in parallel

Each agent works in its own git worktree and branch (`agent/<name>/<task>`), opens a PR into
`integration`, and never merges its own PR. Only the `integration` agent drives Studio,
because there is one Studio instance. Details: `docs/agents.md`.
