# Orchestrator handoff

Updated 2026-10-29. Read this first on startup, then docs/progress.md. Follow the playbook's
"Context discipline" (section 2).

## Phase
Phase 1 complete: gate APPROVED (Kian), all tasks merged, soak clean (P1.10g), integration
promoted to main (#117, 1a877da). STOP state: do not start Phase 2 until Kian says "Run Phase 2".

## In flight
Nothing. Ledger PR #116 (this file + soak/promotion notes) waits for Kian's merge.

## Open for Kian
- Merge #116. Reconnect the Rojo plugin in Studio (Studio was restarted from the CLI).
- Delete soak test keys: Player_-1000001..9, Escrow_soak-1..27, Open_-1000001..9.
- Config.Flags.asyncRaids stays off until every pre-Phase-1 server has shut down (D-049).
- Friends playtest (Phase 1 gate kit, docs/playtests/phase1.md) + deferred multi-person list;
  then triage the hardening backlog in progress.md.
- P2.8 product questions (not urgent).

## Remember
- Merges: the permission check refuses `gh pr merge` unless Kian explicitly asks in chat
  (memory: merges-need-kian). Stack PRs; ledger on one PR per wave.
- Never switch branches in Kian's main checkout (Rojo); fast-forward only.
- Studio soak tooling: DataTestHook test sessions (#112, D-056), test ids only.
- Decisions D-041..D-056 in docs/decisions-log.md.
