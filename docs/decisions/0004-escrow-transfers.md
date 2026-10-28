# 0004: All cross-profile transfers go through escrow

**Status:** accepted · 2026-10-27

**Decision.** Raid loot moves from defender to raider through an escrow record per raidId,
in single-key, idempotent steps (`src/Shared/Escrow.luau`).

**Why.** DataStore has no multi-key transactions and the two profiles usually live on
different servers. A duplication exploit can wreck the economy and trust in a day.

**Proof.** `tests/specs/EscrowSimulation.spec.luau` runs 1,000 raids with injected crashes,
duplicate deliveries and races across six seeds, and checks that no critter is ever
duplicated or lost and Glow is conserved. Deliberately removing either idempotency check
makes it fail, so it guards what it claims to.

**Rule.** Any change to escrow must keep the simulation green and get a reviewer pass.
