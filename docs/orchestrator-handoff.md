# Orchestrator handoff

Updated 2026-10-29. Read this first on startup, then docs/progress.md. Follow the playbook's
"Context discipline" (section 2).

## Phase
Phase 2 is at its human gate (gate report: docs/gate-report-phase2.md). Do not start Phase 3 or
cross the gate until Kian approves. Everything is folded into `preview/phase2` (c6521f7 incl. the UI redesign P2.13, 662 tests,
0 fail); nothing is merged into integration (merge refused, D-058).

## In flight
Nothing. Open: #116 (Phase 1 ledger), the Phase 2 ledger PR (stacked on #116), #138 (tuning
PROPOSAL, not in preview), plus older stacked PRs that GitHub still shows open (#118-#130, #87) but
whose commits are all in preview/phase2.

## Next (after Kian)
1. Kian lands #116, preview/phase2 → integration (one PR), the ledger PR; picks #138's option.
2. Integration agent: fast-forward the main checkout (never switch branches), Studio pass on
   integration, then the 4-client session with testers.
3. Fill Creator Dashboard ids (Config.Purchases, notification MESSAGE_IDS) when Kian sends them.
4. When credits return: P2.1 Gate 1 picks, P2.2 kit generation, P2.11 audio (D-057).

## Pending
P2.13f screenshot pass vs the design canvas: retry with Kian's screen awake (integration agent, D-060 method).

## Ask Kian
Merges; #138 tuning; lockpick rule (D-068); product definitions and refund questions (D-061,
D-065); storage-full notification; credits; paid-randomness mini-phase stays out (CLAUDE.md rule 6).

## Remember
- Ledger worktree: $CLAUDE_JOB_DIR/tmp/wt-ledger2 (job 26a0a7a7), branch agent/integration/ledger-p2.
- Preview worktree: $CLAUDE_JOB_DIR/tmp/wt-preview2 (integration agent).
- Studio: healthy at the end of the run, Edit mode, nothing saved; StudioMemoryProfiles = true.
- Never switch branches in Kian's main checkout (Rojo).
