# Orchestrator handoff

Updated 2026-10-28. Read this first on startup, then docs/progress.md. Follow the playbook's
"Context discipline" (section 2).

## Phase
Phase 0 gate APPROVED (Kian). Finishing the post-gate follow-ups, then promote integration →
main and STOP. Do not start Phase 1 until Kian says so. Don't ask Kian for multi-player testing.

## In flight
- C4 (data), branch `agent/data/C4` (maybe stacked `agent/data/C4-b`): D-033 empty live
  commits grant nothing; liveProtected NaN test; D-034 `EscrowRecord.liveBaseRate` + trailing
  `transferLive(..., liveBaseRate)` param; contracts.md mirror of #62's money-model rules. The
  agent was dispatched by the previous session; if no PR is open from that branch, re-dispatch
  C4 (spec: progress.md row + D-033/D-034).
- P0.5h (raid), PR #71: open, CI green, unmerged. Merge AFTER C4. It already passes
  `liveBaseRate` as transferLive's 7th argument.

## Next, in order
1. When C4's PR is open: `reviewer` pass on C4 (contract, escrow) and #71 together.
   Blocking findings go back to the owning agent.
2. Integration agent: checks (pass/fail) on C4 then #71; merge C4 first, then #71.
3. Integration agent: single-client Studio recheck of P0.5h/i (test-hook plan in #71, P0.5i
   plan in #70). Fast-forward Kian's main checkout first (`git pull --ff-only`, it is on
   `integration`); never switch branches there (Rojo serves it).
4. Ledger: C4 / P0.5h Done; any new deferred multi-client items from #71's description.
5. Promote integration → main: PR `integration` → `main`, CI `check` green, merge commit
   (ruleset: PR-only, no force-push). Then stop and report.

## Done this session
#69 (D-034 ledger), #70 (P0.5i, merged), this PR (D-035, context discipline).

## Ask Kian
None blocking. Not-urgent P2.8 product questions stay in progress.md Blocked.

## Remember
- Ledger edits go through a worktree + PR; ledger PRs merge on green CI.
- P0.5i cosmetic edge (noted in its row); D-035 keeps refusal reasons unshown for now.
