# Cold-start plan v4 — RESTRUCTURED per swarm verdict (2026-07-07)

Swarm verdict on v3.1: REVISE. 5/5 lenses REVISE, 18 blocking findings, 2 hard
blockers + a decisive over-engineering finding. Rather than patch v3.1 and keep
the monolithic C1-first plan, the swarm's SIMPLER-ALTERNATIVE lens (#1/#2/#3) is
adopted: SPLIT into risk/ROI-ordered phases with a MEASUREMENT GATE before the
risky mirror machinery.

## Root insight (swarm finding #1/#2/#3 — GENUINE, unaddressed by any prior round)
The mirror machinery (C1) is the entire source of risk (RCE history, daemon
integration, disk, reaper) AND its marginal benefit over cheaper options was
NEVER measured. C2 (wheelhouse) is ~36% of the win, orthogonal, low-risk, needs
zero daemon changes — yet v3 sequenced it BEHIND C1's high-risk soak. And
actions/cache / checkout blob-filter tuning were never A/B'd at all.

## New phased plan

### PHASE 1 (ship now — passed review, low risk, no daemon change): C2 wheelhouse
- Dockerfile.runner: bake ABI-matched wheelhouse (ruff/mypy/pinned reqs),
  PIP_FIND_LINKS. Repo requirements stay authoritative, PyPI fallback.
- ezgha repo change only (image); config already points at ezgha-runner:latest.
- Rollback: revert Dockerfile, rebuild. No flag needed (image is the unit).
- Measure: presubmit deps-install step before/after (job-level timing).
- This is bead jleechan-yov PHASE 1. Dispatch to sidekick NOW.

### PHASE 2 (cheap experiment, worldai-side, parallel): checkout tuning
- Audit which workflows already use fetch-depth:1; add --filter=blob:none where
  full history unused. Diff branch chore/ci-fast-checkout FIRST (another session
  may already own this — adopt/land theirs, don't duplicate).
- Measure checkout step before/after. This may capture most of C1's win at near-
  zero risk/complexity, which is exactly the swarm's ROI challenge.

### GATE (measurement, not code): decide if C1 mirror is worth its risk
- After P1+P2 land + 48h data: compute REMAINING checkout+setup time.
- IF remaining gap < ~30s/job median → STOP. Do not build C1. The mirror
  machinery's risk is unjustified. Close C1 as "superseded by cheaper wins."
- ONLY IF remaining gap is large AND checkout-dominated → proceed to Phase 3
  with the full v3.1 design PLUS the 2 swarm blockers below.

### PHASE 3 (conditional, gated): C1 mirror — v3.1 + swarm blockers A & B
Fold ONLY IF the gate says build it:
- BLOCKER A (confirmed code bug): existing free_disk_gb guard
  (docker_backend.rs:761-780) measures the Colima VM overlay via
  `docker run --entrypoint df`, NOT the host FS where ~/.cache/ezgha/mirrors
  lives. Mirror could silently defeat ezgha's own disk-floor protection. FIX:
  add a HOST-side disk check on the mirror root, gating both maintenance-thread
  ops and ensure_count spawn eligibility, wired to doctor.sh/CRITICAL. Document
  which FS each guard covers.
- BLOCKER B (adversary-resistant reaper): section E's "no-open-fd" snapshot reap
  is a liveness check a semi-trusted job defeats by holding an fd open →
  unbounded disk. FIX: hard TTL fallback = max(2×fetch_interval, max_job_runtime);
  past TTL, force-kill the holding container via existing slot primitives, then
  reap. Name the concurrency primitive explicitly: pure symlink flip + mtime/lsof
  check ON THE MAINTENANCE THREAD, ZERO shared Rust locks with the serve tick
  (satisfies item H non-blocking claim provably).
- Plus the narrower genuine findings as spike gates: refspec pin (never fetch
  refs/pull/* into shared mirror — #5), credential-scrub race (#11), Colima
  virtiofs symlink-flip TOCTOU test (#10), bounded entrypoint dissociate clone
  with timeout (#12), rollback runbook (#14).

## Net
Swarm converted a risky monolith into: ship the safe 36% now, measure the cheap
alternative, and build the risky 60% ONLY if measurement proves it's needed —
with 2 hard blockers already specified for that conditional path. This is the
"eliminate waste, measure, then size" discipline applied to our own optimization.
