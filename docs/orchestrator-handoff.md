# Orchestrator handoff

Updated 2026-10-29. Read this first on startup, then docs/progress.md. Follow the playbook's
"Context discipline" (section 2).

## Phase
Phase 2 running unattended overnight (Kian, 2026-10-29). Stop at the Phase 2 gate with the gate
report. No Higgsfield credits: placeholders (D-057). Merges refused: stack PRs, build
preview/phase2, Kian merges (D-058).

## In flight (wave 1)
- C6 data (xhigh): Phase 2 profile fields, agent/data/C6
- P2.3 raid: kit seam, pads 6→30, perf, agent/raid/P2.3
- P2.5 ui: full UI pass (may split a/b/c stacked), agent/ui/P2.5
- P2.7 notifications: agent/notifications/P2.7

## Next
Wave 2 as slots free: P2.4 economy, P2.2 assets briefs, then after C6: P2.8 economy (reviewer
xhigh), P2.9 data, P2.10 raid (stack on P2.3 + C6), P2.6 ui (stack on P2.5 + C6). Settings and
opt-in remotes requested by ui/notifications go on top of C6. Then integration: checks per PR,
preview/phase2, single-client Studio pass (D-060), P2.12 kit, gate report.

## Ask Kian
Merges (#116 ledger first, then Phase 2 stack), credits + Gate 1 (#87), P2.8 product list and
prices, notification strings, D-061 defaults, closed-test access (~200 testers).

## Remember
- Ledger worktree: $CLAUDE_JOB_DIR/tmp/wt-ledger2 (job 26a0a7a7), branch agent/integration/ledger-p2,
  stacked on #116 (agent/integration/ledger-p1-soak). Open its PR once there's a wave to record.
- Never switch branches in Kian's main checkout (Rojo).
- Design summary mentions a Phase 2 paid-randomness mini-phase (paid eggs, Blood Moon, Glow packs);
  not in the playbook's Phase 2 table and CLAUDE.md rule 6 forbids it at launch: not started, flag at gate.
