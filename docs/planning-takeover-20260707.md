# Planning takeover — 2026-07-07

This note records the handoff after reading the relevant Claude and Codex sparse
history for the 2026-07-06 ezgha incident/review work. It is the current
planning source beside `roadmap/README.md`; use `br list --status open` for live
issue state.

## Sparse history evidence

- Claude project memory says the core dossier is `docs/goal-gap-review-20260706.md`,
  `docs/goal-gap-findings-20260706.md`, `docs/incident-20260706-fleet-outage.md`,
  and `docs/innovation-canary-slo-20260706.md`. Scorecard remains 5/4/4/1/0.
- Claude memory `adversarial-review-blind-spots` explains the planning failure:
  findings were adversarially checked, but imported beads, final ordering, and
  fix composition were not.
- The latest Claude conversation accepted the external cold review, closed stale
  `5rz`, promoted `k4h`, reframed `juv`, and intended to close `gdy`.
- Current repo/bead state contradicted one point: `gdy` was still open. The
  takeover closed it and updated metadata so roadmap and beads match.
- Codex sparse history confirms the canary critique: canary is the right sensor,
  but it must not ship as a silent standalone feature. It needs alerting and a
  reusable run/job/runner correlation layer.

## Corrections applied

- Closed `ez-gh-actions-gdy` as stale/done; the roadmap already treated it as
  closed, and current code has the capacity bail/clamp.
- Promoted `ez-gh-actions-bxy` to P1 because it is the highest-risk live wedge:
  `start_one` leaks reserved slots on JIT failure, and corrupt slot TOML still
  blocks all slot operations.
- Promoted `ez-gh-actions-ozk` to P2 because API backoff must precede any
  exit-after-N degraded-state escalation.
- Retitled `ez-gh-actions-juv` to `feat(correlation): GitHub run-job-runner layer
  + canary SLO consumer`.
- Created `ez-gh-actions-fl0` for Docker CLI timeouts, which was Phase 1 in the
  roadmap but had no tracking bead.

## Design order

1. Stabilize local invariants: `bxy`, `fl0`, `twp`, `n5p`.
2. Make the harness honest before trusting feature gates: `k4h`.
3. Add the minimum alert contract: `zmk`.
4. Bound retry loops before adding escalation: `ozk`, then `9yt`.
5. Build the shared GitHub run/job/runner correlation layer: `juv`.
6. Build consumers on that layer: canary SLO first, then `qbl` zombie reaper and
   `ftw` max-duration trim.
7. Only after `ozk` and `9yt`, add degraded-state exit/status escalation.

## Non-negotiable design constraints

- Zombie cleanup must cancel the assigned run first, then delete the runner
  registration. Starting with `remove_runner` repeats the HTTP 422 failure.
- `juv` must use durable run correlation, such as a nonce workflow input or
  equivalent, because `workflow_dispatch` does not return a run id.
- Canary polling must not block the single `serve` loop or watchdog pings.
- Gate 7 must prove an actual committed monitor/alert path, not only GitHub API
  reachability.
- The missing repo hook `.claude/hooks/git-header.sh` is itself a planning item;
  until it exists, footer generation will keep failing.
