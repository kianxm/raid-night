# 0001: Strict Luau, Rojo, and Lune for tests

**Status:** accepted · 2026-10-27

**Decision.** Write the game in strict Luau (`--!strict` in every file). Keep source in files
synced to Studio with Rojo. Test pure logic with Lune, outside Studio.

**Why.** Native language, most examples and community help, no compile step. Files in Git
give real diffs, reviews and parallel agent work. Lune lets agents and CI run tests in
seconds without a Studio instance, which is the shared bottleneck.

**Consequences.**
- Pure logic lives in `src/Shared/` with no Roblox APIs, so Lune can run it.
- Shared modules use relative string requires (`require("./Types")`), which work in both
  Lune and Roblox. The Studio smoke test in `docs/setup.md` confirms this on day one.
- Server and client code uses Roblox instance requires and is tested by playtests.
