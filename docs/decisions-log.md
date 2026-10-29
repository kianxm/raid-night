# Decisions log

Technical decisions made under the playbook's decision policy (section 2), newest first. Kian
can overturn any entry; the orchestrator then turns the reversal into tasks.

### D-009 · 2026-10-28 · C1 runs in parallel with the P0.3b fix round
Context: C1 was queued behind #11 only to avoid edit conflicts in Types, Config and
contracts.md. Decision: start C1 now with a second data agent; it stays out of Escrow,
EscrowService and DataService and keeps its edits in separate spots; whichever merges second
rebases. Why: C1 is on the critical path to P0.5. Reversible: yes.

### D-008 · 2026-10-28 · Deferred to Phase 1: escrow GDPR ids and record cleanup
Context: reviewer suggestions on PR #11. Decision: return userIds from escrow UpdateAsync
transforms for erasure tooling, and clean up terminal escrow records, in Phase 1 (P1.1).
Why: no async raids or real players yet; simplest thing that passes the Phase 0 gate.
Reversible: yes.

### D-007 · 2026-10-28 · Escrow open-index becomes a contract; raidId length in Config
Context: reviewer on PR #11. Decision: `Types.EscrowOpenIndex` for `Open_<userId>` values,
indexing both raider and defender; `Config.Escrow.maxRaidIdLength`. Pruning of
`appliedTransfers` never removes an entry whose raidId is still open; a defender's load settles
their own Pending live records (debited → record Debited; not debited → Voided).
Why: the reviewer showed loss and duplication paths when a 7-day prune met an open escrow
(principle 1). Reversible: yes (additive type, Config value).

### D-006 · 2026-10-28 · PR size exceptions for escrow
Context: PR #11 is ~700 lines. Decision: accept; EscrowService must be reviewed as one unit.
Fix rounds may split the simulation extension into a stacked PR. Reversible: n/a.

### D-005 · 2026-10-28 · Critter.untradeable (Kian)
Decision: optional `untradeable: boolean?` on Critter, missing = tradeable, no migration. Set on
rescue-egg critters; survives escrow transfer. Any future trading or gifting code must refuse
it (reviewer checks). Reversible: yes (optional field).

### D-004 · 2026-10-28 · Rescue egg kept, with guards (Kian)
Decision: a free egg when a player owns no critters and banked + stored Glow (after accruing)
is below the egg price. Rolls from a fixed Common-only table, independent of `eggMaxTier`.
Reversible: yes.

### D-003 · 2026-10-28 · Live-stealing contract batch (Kian)
Decision: Net request `Lockdown` () -> boolean, limit 3 per 10 s. Display-only attributes
`CarryingUid`, `CarryingSpecies` (Player) and `LockdownUntil`, `LockdownReadyAt` (den); the
server keeps its own state and never reads them. `Config.LiveRaid` {lockdownSeconds 45,
lockdownCooldownSeconds 120, tagRange 6, grabHoldSeconds 1}. Lockdown blocks entry only
(raiders inside can leave; a carried critter drops at the border), live raids only,
server-enforced. `Config.Economy.eggMaxTier = "Uncommon"`, renormalized odds; Phase 2 raises it
to Mythic. Reversible: yes (Config).

### D-002 · 2026-10-28 · raids is the master kill switch (Kian)
Context: reviewer S2 on PR #2. Decision: any raid (live, async, revenge) needs `raids`; async
and revenge (including live revenge) also need `asyncRaids`; unknown kinds refused. Switches
block new raids only; escrow recovery and in-flight transfers always complete. Why: one flip
stops all theft during an incident. Reversible: yes (Config).

### D-001 · 2026-10-28 · Ledger edits happen in a worktree
Context: switching branches in the main checkout made Kian's `rojo serve` sync stale code into
Studio. Decision: orchestrator commits go through a worktree, never the main checkout.
Reversible: yes.
