# Orchestrator handoff

Updated 2026-10-29. Read this first on startup, then docs/progress.md. Follow the playbook's
"Context discipline" (section 2).

## Phase
Phase 1 running, unattended overnight (D-041): decide technical calls, log them, skip anything
needing a human or live environment into "Needs Kian", stop at the Phase 1 gate with the report.

## In flight
- P1.1 data (xhigh): agent/data/P1.1. Escrow.Store, messages/offline debits, recovery, alarm,
  D-008/D-012#6/D-026 TODOs. Reviewer at xhigh + own Studio run after merge.
- P1.7 economy: agent/economy/P1.7. Sim + proposal; orchestrator approves if in design ranges.
- P1.9 matchmaking: agent/matchmaking/P1.9. Live revenge server side; UI button is P1.6.
- #92 (P1.5b fix for #90): open, merge refused by permission check twice. Needs Kian.

## Next
- P1.3 (raid) when P1.1 merges. Prompt must include: StartRaid re-checks blocks both ways and
  flags; refuse async raid if presence fresh; take/release lock on every end; pass the
  snapshot's power to noteRaided; strip DenSnapshot.blockedUserIds from client payloads;
  RaidStart carries gatePosition + endsAt (UI asks); server-written RaidLogSeenAt (UI asks).
- P1.4 after P1.3; P1.6 after P1.3 (branch from integration, not #92); P1.8 after P1.7.
- P1.10: single-client soak in Studio only; multi-client part deferred.

## Ask Kian
- Merge #92 / allow integration agent merges of reviewed PRs.
- P2.8 product questions (not urgent).

## Remember
- D-044: merges are refused by the permission check. Stack dependent tasks on the parent PR
  branch; Kian merges in order; ledger stays on the open ledger PR (#93).
- Auto-merge is disabled on the repo: merge ledger PRs by hand after CI (`gh pr checks --watch`).
- Ledger worktree: $CLAUDE_JOB_DIR/tmp/wt-ledger (job 26a0a7a7).
- Never switch branches in Kian's main checkout (Rojo); fast-forward only.
- Integration at b075020 (271 tests) + #89 merged (9575905).
