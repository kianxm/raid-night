# Decisions log

Technical decisions made under the playbook's decision policy (section 2), newest first. Kian
can overturn any entry; the orchestrator then turns the reversal into tasks.

### D-045 · 2026-10-29 · P1.7 tuning waits for Kian; P1.8 prepared
Context: economy on #95 proposes upgradeCostBase 100→500, eggPriceBase 50→150, eggPriceGrowth
1.12→1.32. Each serves a quoted design target, but no design-doc numeric range covers them and
they set a first-rebirth pace (~3 weeks) the design never defines. Decision: not approved under
D-041; P1.8 applies the values in a stacked PR that merges only if Kian approves. Async loot
reading leave-time stored Glow is a bug, not tuning: sent to P1.1 (debit accrues to debit time).
Why: pacing is a product call; the PR makes it a one-click approval. Reversible: yes.

### D-044 · 2026-10-29 · Merges wait for Kian; dependent work stacks on PR branches
Context: from #92 on, the session's permission check refuses every `gh pr merge` ("Merge
Without Review"), even after a reviewer pass and for docs-only ledger PRs. Decision: no merge is
worked around. A task whose dependency is an open PR branches from that PR's branch and targets
it (stacked PR); Phase 1's chain is linear (P1.1 → P1.3 → P1.4/P1.6, P1.7 → P1.8), so no
combining merges are needed. Checks and reviews run on the PR branches. Studio runs for unmerged
code wait until Kian merges, because Rojo serves the main checkout on `integration`. Ledger
updates stay on the open ledger PR. Kian merges in the order listed in the gate report.
Why: respect the permission boundary and still finish the code. Reversible: yes (process).

### D-043 · 2026-10-29 · Only offline dens are async raid targets
Context: matchmaking on #91. Decision: GetRaidTargets lists a den as an async target only while
its owner is offline (presence absent); online owners are raided live in their own server. A
Studio-only hook may skip the asyncRaids flag for playtests (IsStudio + Memory persistence +
test ids); live remotes always respect Config.Flags. Why: one den is never raided live and async
at once; the hook can't reach a live game. Reviewer approved. Reversible: yes.

### D-042 · 2026-10-29 · P1.2 runs alongside P1.1; tools/sim goes to economy
Context: P1.2 lists P1.1 as a dependency, but snapshots, pools, locks and presence live in
matchmaking's own files and only read DataService as it is. Decision: start P1.2 in parallel
with P1.1; it must not depend on new P1.1 code. P1.3 still waits for both. `tools/sim/**` is
owned by economy (P1.7). Why: P1.1 is the critical path; this fills the fourth slot without
sharing files. Reversible: yes (process).

### D-041 · 2026-10-29 · Phase 1 runs unattended overnight (Kian)
Context: Kian started Phase 1 and is away overnight. Decision: the orchestrator makes every
technical call under the decision policy and logs it here. Steps that need a human or a live
environment (multi-client or two-server runs, a private publish, Creator Dashboard) are skipped
and listed under "Needs Kian" in the gate report; ready tasks keep running. P1.7's tuning stop is
approved by the orchestrator when every proposed value sits inside the design doc's ranges
(Config only, reversible); anything outside them waits for Kian. Irreversible choices that could
go either way are prepared, not taken. Why: keep the phase moving without crossing Kian's
decisions. Reversible: yes (Kian can overturn any entry at the gate).

### D-039 · 2026-10-29 · Process speed-ups (Kian)
Context: ~24 h of Phase 0 produced 77 PRs, 25 of them ledger-only; the live-protection chain
(P0.5g to C5, ~3,200 lines, D-033 to D-037) was reviewer rounds on edge cases that lose nothing,
before any multiplayer playtest. Decision: (1) pre-playtest scope: until a phase's human
playtest, fix only duplication or loss, client trust and policy; other exploit or fairness edge
cases go to the hardening backlog in progress.md. Principle 6 now means "a few lines in an open
PR". (2) Reviewer severity bar: only those classes, or a broken change, block; suggestions never
start a fix round; re-reviews check only earlier blockers; one fix round per PR unless it's a loss
path; no review for UI, copy, assets or docs-only PRs. (3) Effort: `reviewer` and `data` default to
high, spawned at xhigh only for Escrow, Profile, DataService, EscrowService or purchases. (4) One
ledger PR per merge wave, auto-merged. (5) PRs up to ~800 lines when they must be reviewed as one
unit. (6) Studio once per merge wave, single client; escrow and profile PRs still get their own
run. (7) contracts.md keeps rules, not reasons; agents read only the sections they touch. Why:
same safety on the risky code, much less churn everywhere else. Reversible: yes (process).

### D-038 · 2026-10-28 · Critter personalities and the three-animation set (Kian)
Context: art direction change before Asset Gate 1 (no concept images generated yet). Decision:
every critter has a distinct personality expression that still reads as cute; Commons simple and
cheerful, Rare and above more attitude; never sad, crying, injured or frightened. New required
`CritterSpecies.personality` (one or two words, at most 6 share one), assigned for all 40 and
checked by `CritterCatalog.validate`; every prompt gets a tier-aware expression line and AVOID
names distressed expressions. Each critter animates a happy den idle, a sneaky carried walk and
a gotcha pose when stolen; base art keeps one expression. Three idle lines that read as fear
(crumb_rat, mirror_cat, abyss_angler "panics"/"startles") were reworded. Why: a style decision
inside the approved direction (0006). Reversible: yes (static design data; no persisted change).

### D-037 · 2026-10-28 · The live debit also counts the grab-time rate
Context: data on #79: after a refill reopens a den (D-036), the owner, alerted at carry start,
could shrink it mid-carry so the debit sees protection and takes nothing. Decision: at the
escrow debit, protection is measured against max(liveLossBaseRate, current denRate, the record's
liveBaseRate when finite and >= 0); grabs, the den attribute and prompts are unchanged. Why:
every accepted carry lands, which keeps D-034's intent (principle 6). Reviewer approved.
Reversible: yes.

### D-036 · 2026-10-28 · Live protection measures against max(base, current den rate) (Kian)
Context: data on #73, reviewer on #73/#71: D-034 doesn't stop a planned shrink (empty the den
but one Common, lose it to an alt or after a dropped carry, refill: a day of live protection).
Decision: option (b). A den is live-protected only while today's live losses reach
protectionLossShare of max(liveLossBaseRate, Economy.denRate(den now)). Refilling the den lifts
protection; a real loss still protects (the den's rate drops with it). Applies everywhere
liveProtected is used (grab, escrow debit, den attribute). Scheduled as C5 (data); reviewer pass.
Reversible: yes.

### D-035 · 2026-10-28 · Grab refusal reasons stay unshown in Phase 0
Context: ui on #70: the refusal copy for LiveProtected / PostLossSafety is built and tested, but
no remote delivers a grab refusal reason to the client (GrabCritter has no reply). Decision: no
new Net push now; the den markers ("Protected today", "Safe for m:ss") already explain the two
new refusals, and the deferred list already asks testers whether refusals need a message. If
they do, add a `GrabRefused` push (Net + contracts.md + reviewer) and hook the existing copy.
Why: principle 7, and a contract change for copy the testers may not need. Reversible: yes.

### D-034 · 2026-10-28 · Live protection base is the den's rate at the grab (Kian)
Context: reviewer on #64: measured at the first live debit, the base can be shrunk during the
carry (the owner is alerted at the grab and can move high earners to Inventory/Vault), buying
full-day protection with one cheap loss. Decision: option (b). The base is Economy.denRate of
the den at the moment of the grab, before the owner can be alerted. Orchestrator details:
RaidService measures it when the grab is accepted (the earliest server event the owner can see),
keeps it with the carry and passes it to EscrowService.transferLive; the Live EscrowRecord gains
optional `liveBaseRate: number?`, set at create and never changed (retries pass the same value),
finite and >= 0 or refused at create. At the debit, the day's first live loss uses the record's
liveBaseRate; a record without it (older records, async) falls back to denRate at the debit.
Reviewer pass (contract). Reversible: yes (optional field).

### D-033 · 2026-10-28 · Empty live commits grant nothing
Context: reviewer on #65. Decision: when a live debit takes nothing (den protected) and Glow is
0, still write the appliedTransfers entry (idempotency), but skip the defender's shield, revenge
token, pairRaidsToday increment and "escaped" raid-log entry. Pin it in the simulation. Why: an
empty steal must not use up the raider's pair slot or hand the defender rewards (principle 4).
Rare after D-031 (grabs refuse protected dens and in-flight carries). Reversible: yes.

### D-032 · 2026-10-28 · Robux-linked multiplier mechanics
Context: reviewer on #59. Decisions: (1) the multiplier is pure (Economy.glowBoostFactor) and
fails closed: unknown PolicyService result = restricted; (2) kill switch: Robux-linked
multipliers apply only while Config.Flags.purchases is on; (3) earned = species rate × mutation
× placement × rebirth × (1 + applicable Config.Boosts bonuses), applied through accrue's factor;
(4) the storage cap uses the unboosted rate, so a boost ending never leaves stored Glow above the
cap; (5) accrue at the old factor before the factor changes (boost start/end, VIP ownership or
policy result arriving, joining/leaving a boosted server); (6) the restriction flag, VIP
ownership and Lantern Night state come only from the server. Open product/policy questions for
Kian are in docs/progress.md Blocked. Reversible: yes.

### D-031 · 2026-10-28 · Live loss rules: value-based daily protection (Kian)
Decision (replaces the count-based cap for live steals): (1) after a live loss the den can't be
grabbed from for 60 s (Config.LiveRaid.postLossSafetySeconds); (2) live same-pair limit 2 per day
(maxStealsPerPairPerDay); (3) daily live protection is value-based: when today's live losses
reach 50% (protectionLossShare) of the den's Glow per second, measured at its first live loss of
the day, the den is protected for the rest of the UTC day; optional profile fields
liveLossBaseRate and liveLossRateToday, reset daily, no migration; (4) live steals move critters
through Escrow.luau on the two in-server profiles until P1.1. All values in Config, server-
enforced, display-only attributes, reviewer pass. Scheduled as part of P0.5 (P0.5g data, P0.5h
raid, P0.5i ui). Phase 3 tuning item P3.9 (churn after first loss, raid success rate, like
ratio). Kit question added: "Did you chase the thief after being robbed?".
Orchestrator details: applies to live steals only; async keeps maxLossesPerDay until Phase 1;
loss value = the stolen critter's Glow/s (Economy.critterRate) at debit; enforced at grab (also
refused while a carry from that den is in flight) and again at escrow debit (EscrowRecord gains
optional kind, missing = Live); the 60 s timer is server memory (live steals are same-server).
Reversible: yes.

### D-030 · 2026-10-28 · Robux-linked Glow multipliers are off for policy-restricted players (Kian)
Decision: Lantern Night stays a Glow multiplier. All Robux-bought Glow multipliers (VIP 1.5×
and Lantern Night) are Robux-linked. For a player whose PolicyService info restricts paid
random items, they never apply: VIP keeps its non-Glow perks, and other players' Lantern Nights
don't boost them, so their Glow stays earn-only and eggs stay purchasable. Egg odds are shown
everywhere. Both products stay gated on the reviewer policy audit and the PolicyService check
in P2.8. Amends D-028. Orchestrator details: boosts multiply the rebirth-adjusted rate (earned =
base × rebirth × (1 + applicable bonuses)); the bonuses stack additively (VIP +50% and Lantern
Night +50% = 2.0×), values in Config.Boosts; pure multiplier logic tested per policy flag
(C2, P0.12). Reversible: yes.

### D-029 · 2026-10-28 · Three more launch products, no randomness (Kian)
Decision: add to the launch catalog (design-summary, PurchaseService): server boost "Lantern
Night" (99-199 Robux, +50% Glow earned server-wide for 15 min, buyer announced; the open policy
check below is answered by D-030), critter
accessories (25-149, direct sale, cosmetic only), escape emotes (pass, 49-149). No randomness.
Open policy check (orchestrator flag): Lantern Night sells extra Glow earning for Robux while
Glow buys random eggs (D-028's reason for earn-only Glow); it ships only after a reviewer policy
audit and PolicyService checks in P2.8. Accessories and emotes never change stats. Prices are
ranges until the Phase 3 price tests. Reversible: yes.

### D-028 · 2026-10-28 · Glow is earn-only at launch; egg odds on screen from Phase 0 (Kian)
Decision: no Glow packs at launch; no product grants Glow for Robux. Glow packs move to the
Phase 2 paid-randomness mini-phase, shipped with PolicyService region checks and a reviewer
audit. Egg odds are shown on screen for every egg from Phase 0, read from Config.EggOdds after
the eggMaxTier renormalization (rescue egg: Common 100%). Updated design-summary, decision
0005, contracts.md, playbook, PurchaseService header. Why: Glow buys eggs, so selling Glow would
make eggs paid random items (CLAUDE.md rule 6). Reversible: yes, in the Phase 2 mini-phase.
Amended by D-030: Robux-bought Glow multipliers (VIP 1.5×, Lantern Night) are allowed but never
apply to players whose PolicyService info restricts paid random items.

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
