# Orchestrator handoff

Updated 2026-10-28. Read this first on startup, then docs/progress.md. Follow the playbook's
"Context discipline" (section 2).

## Phase
Phase 0 complete: gate APPROVED (Kian), all post-gate follow-ups done and merged, integration
promoted to main. STOP state: do not start Phase 1 until Kian says so. Don't ask Kian for
multi-player testing (deferred list in progress.md).

## In flight
- C5 (data), branch `agent/data/C5`: D-036 (Kian picked (b)). Then reviewer, integration
  merge + single-client check, ledger, promote integration → main again, stop.

## Next (only when Kian says "Run Phase 1")
- Phase 1 tasks P1.1-P1.10 in docs/playbook.md; P1.1 (data) carries D-008 and D-012 TODOs
  (escrow GDPR ids, record cleanup, void tombstone before async debits).
- P2.8 hard gate: factor-1 accrue in EscrowService/Matchmaking fixed before `purchases` on.

## Ask Kian (not blocking)
- P2.8 product questions (Robux-linked products, VIP offline, restricted buyers).

## Remember
- Ledger edits go through a worktree + PR; ledger PRs merge on green CI.
- Never switch branches in Kian's main checkout (Rojo); fast-forward only.
- D-035: grab refusal copy exists but no channel shows it; testers decide.
- Integration at f50ab1c (242 tests) before this ledger PR.
