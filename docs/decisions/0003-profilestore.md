# 0003: ProfileStore for player data

**Status:** accepted · 2026-10-27

**Decision.** Use ProfileStore for player profiles: session locking (one server owns a profile
at a time) and a message queue for changes sent from other servers.

**Why.** Session locking prevents two servers overwriting the same save, the classic cause
of item duplication. The message queue is how a raider's server asks the defender's server
to apply an escrow debit without writing the defender's save directly.

**Vendored version:** _record the version and source URL here when you vendor it._
