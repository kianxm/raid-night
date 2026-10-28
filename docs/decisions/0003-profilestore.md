# 0003: ProfileStore for player data

**Status:** accepted · 2026-10-27

**Decision.** Use ProfileStore for player profiles: session locking (one server owns a profile
at a time) and a message queue for changes sent from other servers.

**Why.** Session locking prevents two servers overwriting the same save, the classic cause
of item duplication. The message queue is how a raider's server asks the defender's server
to apply an escrow debit without writing the defender's save directly.

**Vendored version:** ProfileStore 1.0.3 (version from the repo's `wally.toml`), vendored
2026-10-28 from commit `45c9847cbcf1fc260369c50eb335aba7c35aecdd` of
https://github.com/MadStudioRoblox/ProfileStore (Apache-2.0, by loleris / MAD STUDIO).
`ProfileStore.luau` itself was last changed in commit `9580f7c` (2025-03-25).

- Source: https://raw.githubusercontent.com/MadStudioRoblox/ProfileStore/45c9847cbcf1fc260369c50eb335aba7c35aecdd/ProfileStore.luau
- Saved unmodified as `src/Server/Packages/ProfileStore.luau`
  (SHA-256 `ad43737203688b8e88cab34ebe8c483000c157e53bfb41e35f1b49ee89d0c95f`).
  Rojo maps it to `ServerScriptService.Server.Packages.ProfileStore`.
- Excluded from StyLua (`.styluaignore`) and selene (`selene.toml`). Never edit it in place;
  to update it, re-vendor a new commit and update this record.

**How we use it** (see `DataService.luau`): template `Profile.new(0, 0)`, then
`Profile.prepare` (migrate + fix-ups) on a copy after every load. We do not call
`Profile:Reconcile()`: missing fields are added by numbered migrations, never by the template.
