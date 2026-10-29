# 0005: No paid randomness at launch

**Status:** accepted · 2026-10-27

**Decision.** At launch, Robux buys only direct items (passes, shields, timer skips, event
pass). No Robux eggs, no luck boosts, no server-wide summons that change odds.

**Why.** Anything random bought directly or indirectly with Robux is a paid random item
under Roblox policy and needs on-screen odds for every outcome, live odds while boosts are
active, and region gating through PolicyService. Building that well takes time the launch
does not have, and a policy problem during the launch spike is unrecoverable.

**Revisit.** Phase 2, once the odds panel and PolicyService checks are built and reviewed.

**Never.** Selling the return of a stolen critter.

**Amended 2026-10-28 (Kian, D-028).** No Glow packs at launch: Glow is earn-only. Glow buys
eggs, so selling Glow for Robux would make every egg a paid random item. Glow packs move to the
Phase 2 paid-randomness mini-phase with PolicyService region checks and a reviewer audit. Egg
odds are shown on screen for every egg from Phase 0 anyway.
