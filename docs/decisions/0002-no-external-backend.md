# 0002: No external backend at launch

**Status:** accepted · 2026-10-27

**Decision.** Build everything on Roblox services: DataStore (profiles, snapshots, escrow),
MemoryStore (matchmaking pools, raid locks, presence), TeleportService (live revenge), and
Open Cloud notifications.

**Why.** No servers to run, pay for or secure; one less thing to break during a launch spike.
Everything the design needs exists on the platform.

**Revisit when.** Analytics or live-ops config outgrow what in-experience tools give you.
