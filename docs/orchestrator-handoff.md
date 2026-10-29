# Orchestrator handoff

Updated 2026-10-29. Read this first on startup, then docs/progress.md. Follow the playbook's
"Context discipline" (section 2).

## Phase
Phase 1 at its human gate. All tasks coded, checked and reviewed, but nothing past #91 is merged:
the permission check refuses `gh pr merge` (D-044). Gate report posted (see Gate history).

## In flight
Nothing. Open PRs: #92-#110 (minus #91/#89 merged). `preview/phase1` (a6ad68f) = every PR except
#96 merged in order, conflicts resolved, 340 tests green. Ledger PR #93 holds D-041..D-054.

## Next (after Kian)
1. Kian merges (preview/phase1 in one go, or PR by PR per docs/playtests/phase1.md) and decides
   #96 (P1.8 tuning).
2. Integration agent: fast-forward the main checkout, run the single-client pass (escrow PRs get
   their own run), then the 30-min soak (P1.10). File fixes as tasks.
3. asyncRaids on only after every pre-P1.1 server has shut down (D-049).
4. Phase 1 gate playtest with friends (deferred multi-client list in progress.md).

## Ask Kian
- Restart Studio/MCP plugin (wedged); test escrow p11-sd-1 pending into his real account (D-055).
- Merge permission/merges (D-044); #92 first.
- P1.7/P1.8 pacing: approve ~3-week first rebirth, pick another, or keep values (D-045).
- P2.8 product questions (not urgent).

## Remember
- Ledger worktree: $CLAUDE_JOB_DIR/tmp/wt-ledger (job 26a0a7a7), branch ledger-p1-wave1 (#93).
- Never switch branches in Kian's main checkout (Rojo); fast-forward only.
- integration at b075020 (271 tests): #88, #89, #91 merged this phase.
