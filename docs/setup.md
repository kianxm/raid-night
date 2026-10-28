# Setup: day 0

Do these in order. Nothing here requires writing game code.

## 1. Clear the blocker

- [ ] Confirm with Roblox (manager or legal) how the outside-activity and conflict-of-interest
      policies treat publishing your own experience and cashing out through DevEx.

## 2. Accounts and keys

- [ ] Roblox account for publishing, with 2-step verification on, and a Plus subscription
      (required to publish or update all-ages experiences since April 30, 2026)
- [ ] Create a Roblox community (group) to own the experience, so revenue and permissions
      are not tied to one personal account
- [ ] Higgsfield account; decide plan vs. pay-per-generation API (generations through the CLI
      and MCP use credits, not plan unlimiteds)
- [ ] Discord server for players and creators (can wait until soft launch)

## 3. Toolchain

Install [Rokit](https://github.com/rojo-rbx/rokit) (toolchain manager), then in the repo root:

```bash
rokit init
rokit add rojo-rbx/rojo
rokit add JohnnyMorganz/StyLua
rokit add Kampfkarren/selene
rokit add lune-org/lune
rokit install
```

This writes `rokit.toml` with pinned versions; commit it so every agent uses the same tools.
If a command's syntax has changed, check Rokit's README.

Then:

```bash
git init && git lfs install
lune run tests/run.luau        # expect: 54 passed, 0 failed
stylua --check src tests tools
selene src
luau-analyze src/Shared/*.luau src/Shared/Data/*.luau   # strict type check, expect no output
```

`luau-analyze` ships in the official Luau release zip (github.com/luau-lang/luau, Releases).
Put it on your PATH. For type checking server and client code against Roblox APIs, use the
luau-lsp extension in your editor with Rojo's sourcemap.

## 4. Packages

ProfileStore (session-locked player data) is vendored, not installed through Wally:

- [ ] Download the official ProfileStore module from its maintainer's GitHub or Creator Store page
- [ ] Save it as `src/Server/Packages/ProfileStore.luau`
- [ ] Record the version you vendored in `docs/decisions/0003-profilestore.md`

## 5. Studio

- [ ] Install the Rojo Studio plugin, then `rojo serve` and connect
- [ ] Create a baseplate place; publish it to the community as a private experience
- [ ] Game Settings → Security: enable Studio access to API services (DataStore/MemoryStore in Studio)
- [ ] **Smoke test:** press Play. The output should print `[RaidNight] server started`.
      This proves the Shared modules' relative `require("./Types")` calls resolve in Roblox.
      If they do not, stop and hand it to the `data` agent before anything else.

## 6. Connect Claude Code

```bash
# Roblox Studio's built-in MCP server:
# Studio → Assistant → ⋯ → Manage MCP Servers → turn on "Enable Studio as MCP server"
# → Quick connect → Claude Code

# Higgsfield (generation from Claude Code)
claude mcp add --transport http higgsfield https://mcp.higgsfield.ai/mcp
npx skills add higgsfield-ai/skills    # optional: Higgsfield's skills for agents
```

Install the Higgsfield CLI from higgsfield.ai/mcp (CLI tab), then `higgsfield auth login`.

Only the `integration` agent should use the Studio MCP connection. See `docs/agents.md`.

## 7. Repo hygiene

- [ ] Push to a private GitHub repo; protect `main` and `integration` (PRs only)
- [ ] Add CI later: run `lune run tests/run.luau`, `stylua --check`, `selene src` on every PR
