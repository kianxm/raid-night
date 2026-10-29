# Decisions log

Technical decisions made under the playbook's decision policy (section 2), newest first. Kian
can overturn any entry; the orchestrator then turns the reversal into tasks.

### D-015 · 2026-10-28 · Phase 0 live steals take the critter only
Decision: transferLive glowRequested = 0 for live steals in Phase 0; stored Glow is only taken by
async raids (Phase 1). Why: simplest loop for the "is stealing fun" gate. Reversible: yes.

### D-014 · 2026-10-28 · P0.5 does not wait on P0.4b
Decision: start P0.5 right after C1. P0.5 identifies critters from the defender's profile and
server pad positions, never model attributes, so the IncomeService cleanup in P0.4b is not a
prerequisite. Why: critical path. Reversible: n/a.

### D-013 · 2026-10-28 · Lockdown blocks revenge raiders too
Context: reviewer on #22. Decision: an active Lockdown blocks entry for every live raider,
revenge included. Why: revenge skipping a shield does not mean skipping the owner's active
defense; one simple rule. Reversible: yes.

### D-012 · 2026-10-28 · #11 re-review suggestions done now, in P0.3a
Context: reviewer approved #11 with 7 non-blocking suggestions. Decision: do 1-5 and 7 in P0.3a
(index timestamp refresh on re-add, prove session ownership before voiding, retry party from
the record, per-call create nonce, identical-arguments retry rule, test gaps); record 6 (async
debits by message will race the void rule; EscrowRecord has no kind) as a P1.1 TODO. Why:
principle 6, cheap to close now. Reversible: yes.

### D-011 · 2026-10-28 · Lockdown cooldown counts from the end
Decision: LockdownReadyAt = LockdownUntil + lockdownCooldownSeconds, so a den is locked at most
45 s in every 165 s. Why: fair to raiders (principle 4); lockdowns cannot be chained.
Reversible: yes (Config + one formula).

### D-010 · 2026-10-28 · Multi-client testing deferred; single-client harness for P0.5
Context: Kian has no testers now and will test with people once, at the end. Decision: keep all
multi-client checks in one deferred list in docs/progress.md; P0.5 ships a Studio-only test
hook (guarded by RunService:IsStudio()) that seeds a dummy defender den so one client can
exercise grab, carry, tag, escape, lockdown and the escrow handoff. Why: keep verifying as we go
without needing people. Reversible: yes.

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
