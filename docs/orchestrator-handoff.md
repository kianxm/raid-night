# Orchestrator handoff

Updated 2026-10-28. Read this first on startup, then docs/progress.md. Follow the playbook's
"Context discipline" (section 2).

## Phase
Phase 0 complete: gate APPROVED (Kian), all post-gate follow-ups done and merged, integration
promoted to main. STOP state: do not start Phase 1 until Kian says so. Don't ask Kian for
multi-player testing (deferred list in progress.md).

## In flight
Nothing. C5 (#79) and P0.5j (#80) merged; integration promoted to main again after this ledger
PR. No open feature PRs.

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
- Integration at 973d261 (256 tests). D-036/D-037 close self-protection.
