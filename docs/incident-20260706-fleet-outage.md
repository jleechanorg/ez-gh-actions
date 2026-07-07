# Incident report — 2026-07-06 fleet outages (repo lifetime timeline)

The repo is 3 days old (first commit 2026-07-03 15:08 PDT). This doc records the full
operational timeline from creation through tonight's outages, reconstructed from git history,
the systemd journal, and live GitHub API state during the 2026-07-06 evening review session.

## Per-day journal stats (user unit ezgha.service)

| Day | Service starts | Watchdog events | "no usable backend" errors | JIT name conflicts |
|---|---|---|---|---|
| 2026-07-03 (repo created, 12 commits) | 13 | 0 | 5 | 0 |
| 2026-07-04 (27 commits) | 25 | 0 | 0 | 93 |
| 2026-07-05 (19 commits) | 12 | 0 | 0 | 80 |
| 2026-07-06 (12 commits) | **1,490** | **32** | **1,380** | 86 |

Interpretation: days 1–3 were normal iterate-and-restart development churn plus a persistent
low-grade JIT name-conflict problem (~80–90/day). Day 4 (today) had two compounding incidents.

## Incident A — ~4h crash loop while Colima was down (2026-07-06, daytime)

- The daemon found `no usable backend` 1,380 times and systemd restarted it in a tight loop
  (the bulk of today's 1,490 starts).
- Root cause: Colima/Lima VM (which hosts the Docker daemon on this box — context
  `lima-colima`, unix socket `~/.lima/colima/sock/docker.sock`) was down; the daemon has **no
  recovery path** for this (no `limactl start colima` attempt anywhere in src/) and no alert
  was sent (no alerting exists — Goal 5 at 0/10).
- Confirmed finding C-critical (self-healing): "Colima/Lima VM death mid-run is never recovered
  by anything — daemon error-loops passively forever."

## Incident B — watchdog SIGABRT loop (2026-07-06, 17:59–20:16 PDT)

- 10 watchdog kills (32 watchdog journal events) — systemd SIGABRT'd the daemon repeatedly.
- Root cause (confirmed finding): a single `ensure_count` iteration over a cold 16-runner fleet
  can exceed WatchdogSec; the daemon only pets the watchdog between iterations
  (src/main.rs:320-332). Live unit was hand-tuned to WatchdogSec=180 but src/service.rs still
  writes 60 — any `install-service` reinstall silently regresses the mitigation.
- 20:02 PDT: new binary installed (but SHA embed broken — reports `0.1.0-unknown`, so Gate 0
  cannot verify provenance). 20:06 and 20:37 PDT: service restarts with `Type=notify` +
  `WatchdogSec=3min` unit live.

## Incident C — JIT name-conflict slot wedge / GitHub-side zombie jobs (2026-07-06, ~20:30–21:00 PDT)

Observed live during the review session:

- 20:40 PDT: GitHub org registrations showed **14 of 15 `ez-runner-b-*` runners
  offline-but-busy, 1 online**; locally only 1–3 containers up. Fleet throughput effectively
  ~1/16. worldarchitect.ai queue backed up to 42+ queued runs.
- The daemon refused to reclaim the stale names: "presumed to belong to a live sibling host and
  will not be deleted." A sibling host DOES exist (`ez-mac-runner-b-*` on a Mac) but uses a
  different prefix, so the heuristic was misfiring on **our own** dead ephemeral runners
  (prefix `ez-runner-b` matches this host's config).
- Manual remediation attempt: `DELETE /orgs/jleechanorg/actions/runners/{id}` for all offline
  registrations → **every call failed HTTP 422 "Runner is currently running a job and cannot be
  deleted."** Key learning: when an ephemeral container dies mid-job (e.g. killed by Incident
  B's watchdog SIGABRTs), GitHub keeps the job `in_progress` and the registration locked until
  the job times out or the run is cancelled. The correct remediation is **cancel the zombie
  workflow runs** — i.e. exactly Goal 4 (trim/cancel stuck actions), which has zero
  implementation (0 matches for "cancel" repo-wide).
- ~20:50–21:00 PDT: fleet self-recovered to 15/16 online as GitHub released the stale busy
  registrations and new JIT registrations succeeded; queue began draining (42 → 38).

## Cross-cutting conclusions

1. Incidents A→B→C form a causal chain: watchdog kills (B) killed containers mid-job, which
   created GitHub-side zombie busy registrations (C), which wedged JIT name reuse and starved
   throughput. Fixing the watchdog budget alone removes the biggest zombie generator.
2. None of the three incidents produced any notification (Slack/email/webhook code: none).
3. All three incidents map to already-confirmed findings in
   `goal-gap-review-20260706.md` — the review's Phase 1+2 roadmap addresses each.
4. GitHub API constraint discovered: offline-busy runner registrations are undeletable while
   their zombie job is live; any zombie-reaper implementation must cancel the run first
   (`POST /repos/{owner}/{repo}/actions/runs/{id}/cancel`, or `force-cancel` for hung ones),
   then delete/replace the runner.

## Architecture note — Docker vs Colima (user question 2026-07-06)

We use both **by design, as layers, not alternatives**: Colima runs a Lima VM (4 CPU / 12 GiB /
120 GiB, Ubuntu 24.04 guest) whose purpose is to host the Docker daemon; the active docker
context is `lima-colima`. "Only Colima" is not a meaningful option — Colima without Docker (or
another container runtime) runs nothing. The real choice is:

- **Current: Docker-in-Lima-VM.** Hardware virtualization boundary between untrusted CI code
  and the host (DESIGN.md Layer 3). Cost: VM lifecycle is a new failure mode (Incident A) and
  resources are capped at the VM size (the "clamping cpus 2 → 0.5" journal lines are the daemon
  fitting 16 runners into the 4-CPU VM).
- **Alternative: native dockerd on the Ubuntu host.** Simpler, no VM outages, full host
  resources — but containers share the host kernel, so a container escape lands on the real
  machine. DESIGN.md's backend ladder deliberately rejects this as the default.

Recommendation: keep the VM boundary, and instead (a) make the daemon auto-restart Colima
(roadmap Phase 2), and (b) consider sizing the VM up if 16 runners × 0.5 CPU is the intended
capacity rather than an accident of clamping.
