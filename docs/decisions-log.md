# Decisions log

Technical decisions made under the playbook's decision policy (section 2), newest first. Kian
can overturn any entry; the orchestrator then turns the reversal into tasks.

### D-028 · 2026-10-28 · Glow is earn-only at launch; egg odds on screen from Phase 0 (Kian)
Decision: no Glow packs at launch; no product grants Glow for Robux. Glow packs move to the
Phase 2 paid-randomness mini-phase, shipped with PolicyService region checks and a reviewer
audit. Egg odds are shown on screen for every egg from Phase 0, read from Config.EggOdds after
the eggMaxTier renormalization (rescue egg: Common 100%). Updated design-summary, decision
0005, contracts.md, playbook, PurchaseService header. Why: Glow buys eggs, so selling Glow would
make eggs paid random items (CLAUDE.md rule 6). Reversible: yes, in the Phase 2 mini-phase.

### D-027 · 2026-10-28 · Phase 0: Inventory critters auto-fill free pads; fix steal feedback before the gate
Context: the P0.8 Studio pass found stolen critters (and eggs bought with full pads) land in
Inventory, which has no UI in Phase 0 (#43), and the raider sees no steal result (#41).
Decision: Economy.autoPlace moves Inventory critters onto free usable pads (oldest first; never
Vault, never locked, never displacing) on every den push; the HUD toasts RaidEnded. Both are
fixed before the gate because the gate asks whether stealing is fun. Revisit auto-place when
P2.5 adds an inventory UI. #42 (test-hook Lockdown state survives clear) is test-only and
deferred. Reversible: yes.

### D-026 · 2026-10-28 · Small escrow/data follow-ups go to P1.1
Decision: the #38 reviewer suggestions (a source guard that raw memory/DataStore access only
appears in read/update; pcall the storage() call in transferLive; "DataService not started"
error text), recovery refreshing the raider's HUD when a late InFlight commits, and the rebirth
lock check (applyRebirth must skip or refuse locked critters when rebirth is wired) are
recorded as P1.1 TODOs, not more Phase 0 rounds. Why: none is reachable in Phase 0; simplest
thing that passes the gate. Reversible: yes.

### D-025 · 2026-10-28 · Carry anti-cheat: lag-tolerant budget
Decision: keep the 1 s freeze rule (phone lag must not drop honest carriers) instead of capping
the budget below the 12-stud den gap. Guarantee: over any window a carrier moves at most
(v + 2) + refill·v·T studs (moveRefill lowered to 1.1); an escape needs an earlier sample on the
street, and that flag resets whenever the carrier is back inside the defender's den; carriers
above 16 studs drop; tags use X/Z distance; Lockdown push-backs shift the carry's last position
by the server's push so nothing the client moved is forgiven. Reviewer-checked. Reversible: yes.

### D-024 · 2026-10-28 · P0.4c runs as a third agent briefly
Decision: the ~20-line swap fix (reviewer B2 on #29) runs alongside the raid fix round and
P0.5e, above Phase 0's parallelism of 2. Why: it gates the #29 merge and is tiny.

### D-023 · 2026-10-28 · Rescue-egg critters stay stealable live
Context: reviewer on P0.5 (steal → free rescue egg → steal loop). Decision: untradeable means
no trading or gifting (D-005); live steals may take rescue critters. The loop is capped by
maxLossesPerDay and the same-pair limit (D-022). Kian may overturn. Reversible: yes.

### D-022 · 2026-10-28 · Same-pair limit and in-flight count for live grabs
Decision: live grabs refuse when the owner's lossesToday + carries in flight reach the daily
cap, and when the raider/owner pair is at maxRaidsPerPairPerDay (with in-flight). Shield and
new-player protection stay async-only in Phase 0; a short live grace for new players moves to
Phase 2 onboarding (P2.6). Why: stops one player taking all of a victim's losses in minutes
(principle 4). Reversible: yes.

### D-021 · 2026-10-28 · Movement-budget values stay in RaidRules for Phase 0
Decision: the carry anti-speed budget parameters live in RaidRules.Live until the next contract
batch moves them to Config.LiveRaid; grabRange moves now (D-018). Reversible: yes.

### D-020 · 2026-10-28 · Live steals report through RaidEnded
Decision: when a carry ends, the raider gets Net.Pushes.RaidEnded { raidId (escrow id, or ""
for a drop), escaped = Committed only, speciesId, glow 0 }. No new remote. Why: the raider
needs to know if a steal worked; reuses an existing contract. Reversible: yes.

### D-019 (revised 2026-10-28) · Studio-only test profiles, Memory persistence only
Revision after the reviewer's B4 on #32: test profiles are allowed only when the whole server
runs in Memory persistence (Studio-only switch to ProfileStore's mock store), with reserved ids
<= -1_000_000 (Studio's Local Server players use -1, -2, ...). The earlier "escrow in memory for
negative ids while API access is on" would have saved a real profile pointing at a memory-only
record. Original entry below.

### D-019 · 2026-10-28 · Studio-only test profiles; test escrow never persists
Decision: DataService.loadTestProfile/releaseTestProfile work only in Studio and only for
userId <= 0, in memory; any escrow with a party userId <= 0 keeps its record and index in
memory, even with Studio API access on. Why: single-client testing of the full steal path
(D-010) without fake data ever reaching a DataStore (principle 1). Reversible: yes.

### D-018 · 2026-10-28 · Grab range in Config
Decision: Config.LiveRaid.grabRange = 10 studs (was a RaidRules constant). Why: tuning knobs
live in Config (principle 5). Reversible: yes.

### D-016 · 2026-10-28 · DenState.eggCost deferred to the Phase 2 UI pass
Context: economy proposed adding eggCost to Net.DenState so the HUD stops mirroring the rescue
rule. Decision: defer to P2.5. The client copy is display-only and matches the server after
P0.4b; a three-lane contract change is not worth it for the Phase 0 gate. Reversible: yes.

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
