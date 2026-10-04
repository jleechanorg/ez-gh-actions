# Runner throughput — 2026-10-03

Branch `codex/runner-throughput-20261003` — source-only changes,
ready for root runtime deployment. Three commits, in order:

| Commit | Subject |
|---|---|
| `d250267` | runner throughput: parallel readiness probes + busy/idle diagnostics + container-absent reclaim |
| `b4669de` | runner throughput: 6s probe cap + absent reconcile + drop unused activity enum |
| `907ecda` | runner throughput: opt-in cpu_burst + absent-shortage fix (independent-review critical) |

## Final HEAD for deployment

```
907ecda  HEAD (this commit)
b4669de  round-2 review feedback fixes
d250267  first-pass (parallel probes + diagnostic split + absent reclaim)
```

Root owns `cargo install --path .`, `systemctl --user restart ezgha.service`,
the `~/.config/ezgha/config.toml` edits, and `git push` (no `git add -A`,
no force push).

## 2026-10-04 correction — current source and CPU-burst interpretation

The `907ecda` deployment-head label below is historical. This document
records a commit series; deployment must pin the current source with
`git rev-parse HEAD` rather than treat an earlier prose SHA as authoritative.

The earlier aggregate-CPU statement was incorrect. With opt-in
`limits.cpu_burst = true`, each container receives a finite individual ceiling
of `min(cfg.limits.cpus, daemon_ncpu)` only after VM and finite-capacity
validation. The sum of those ceilings may exceed VM vCPU count (for example,
six 4-CPU ceilings on an 8-vCPU VM); they are not an aggregate reservation.
Actual concurrent execution remains bounded by the verified finite VM CPU
supply and its scheduler. This can increase runnable-container contention, and
no measured performance gain is claimed here. Default-false behavior and the
memory clamp are unchanged.

---

## Commit `907ecda` — post-review critical fix + opt-in cpu_burst

### Fix A — absent slot counts toward shortage, not toward alive

Independent review of `b4669de` flagged HIGH-severity: post-refill readiness
computed `alive_after = summary.ready + summary.absent.len()`, so a freshly-
spawned slot that disappeared before `docker top` could find it (the "No
such container" race) zeroed the shortage and selected `Recovered`,
skipping settling and sleeping the full 30 s serve-tick. One-line fix:

```rust
// src/docker_backend.rs:4816
(cfg.runner.count.saturating_sub(summary.ready), None)
```

`Unknown safety` preserved: `Err` from the probe still propagates through
the `Err(error)` arm — only `ProbeOutcome::Absent` is the confirmed-loss
signal. Pinned by `parallel_readiness_probe_overrun_propagates_as_err_not_absent`.

New regression test (the missing half of the review's ask):
`post_refill_absent_container_forces_shortage_and_immediate_reconcile` —
verifies (a) `remaining_shortage == 2` not 0, (b) `StartSettling` selected,
(c) settling armed, (d) second poll forces `Ceiling` via main.rs absent-
aware short circuit, (e) `settling_plan` returns `(Duration::ZERO, true)`.
Confirmed FAIL against the pre-fix code with the exact assertion message.

### Fix B — opt-in `limits.cpu_burst` (Mac fixed8CPU VM only)

2026-10-03 Mac `cgroup cpu.stat` sample: one runner used 7.69 M us in 6 s
while throttled (others near zero). All 6 aggregate 3.3 CPU on an 8-CPU
VM; equal-share clamp `--cpus 8/6 = 1.33` was the bottleneck.

Design (minimum safe, default unchanged):
- New `limits.cpu_burst: bool` (default `false`).
- `effective_limits` returns `Result`: on `cpu_burst=true` with
  unsupported host (daemon not VM-contained OR no finite positive
  ncpu), returns `Err`. `Serve` startup AND `start_one` propagate the
  Err via `?` so any unsupported burst bails before runner mutation.
- When honored, per-container ceiling relaxes to `min(cfg.limits.cpus,
  ncpu)`. Aggregate `count * ceiling` is bounded by VM vCPU count
  (the per-container value gets translated to `cfs_quota_us`, and a
  value above `ncpu` would exceed one physical CPU).
- Memory clamp unchanged.
- Default-false does NOT call `platform::detect()` — no extra probes
  on the hot path; gated behind `cfg.limits.cpu_burst`.
- Reuses existing `daemon_in_vm` + `daemon_capacity()` probes.

Tests pin the contract:
- `cpu_burst_defaults_to_false`
- `cpu_burst_with_vm_and_finite_capacity_relaxes_to_daemon_cpu`
- `cpu_burst_unsupported_on_host_daemon_returns_err`
- `cpu_burst_unsupported_with_no_capacity_returns_err`
- `cpu_burst_rejects_nan_ncpu`
- `cpu_burst_rejects_zero_ncpu`
- `cpu_burst_default_does_not_run_platform_detect`
- `cpu_burst_per_container_cap_does_not_exceed_daemon_capacity`

### Test summary

```
$ cargo test --bin ezgha -j 2 2>&1 | tail -3
test result: ok. 440 passed; 0 failed; 1 ignored; 0 measured; 0 filtered out
```

Up from 431 (`b4669de`): +9 (1 absent-regression + 8 cpu_burst:
default-false, VM+finite relax, host-refuses, no-capacity-refuses,
NaN-refuses, zero-refuses, default-no-VM-probe, per-container-cap).

Shell regressions clean: `commit_msg_provenance_prefix`, `doctor_runner_verdict_line`,
`doctor_runner_expected_containers`, `doctor_runner_heartbeat_starvation`,
`doctor_runner_respawn_journal` — all PASS.

---

## Final-state runtime notes (root's deployment plan)

### Linux (jeff-ubuntu) — `runner.serve_tick_seconds 20 → 10`

Backed-up exact config edit on `~/.config/ezgha/config.toml`:

```toml
[runner]
serve_tick_seconds = 10   # was 20
```

Then rebuild + restart (Gate 0 SHA match, Gate 3 load-aware check, then
`systemctl --user restart ezgha.service`).

Observed pre-edit state (justification):
- Repeated `7/10 Runner.Worker` samples (3 productive slots left idle
  every cycle).
- 33 s observed reconcile cycles = `serve_tick_seconds(20) +
  readiness_probe_serial_drift(13)`; halving the tick to 10 s brings
  reconcile floor to ~23 s without any new polling code.
- 20 s configured idle sleep between cycles, no other hot path.

Effect: halves the idle-wait budget, ~50% faster recovery from
transient slot loss. No polling-code change, no probe cadence change,
no admission/PSI gate change. Linux default `limits.cpu_burst = false`
remains (Linux 20-CPU host already has plenty of equal-share headroom).

### Mac (ez-mac-runner-g-1..6) — keep tick 5, enable `cpu_burst = true`

`serve_tick_seconds` stays at 5 (already short; the Mac fixed8CPU VM
is the probe-latency-bound fleet, not the reconcile-floor-bound one).

Add `cpu_burst = true` to `[limits]` only when root flips it (config
edit is NOT done by this commit). The Mac fleet is the use case that
motivates the opt-in: VM 8 CPU / 6 slots with a hot job needing
~2.15 CPUs gets clipped at equal-share 1.33; burst relaxes to
`min(cfg.limits.cpus, ncpu) = 4.0` for the verified-VM + finite-capacity
eligibility path.

### Out of scope / NOT touched

- No `cargo install` / `systemctl restart` / config edits done in this commit.
- No change to Linux `limits.cpu_burst` (default false, stays).
- No new platform probes; reuses `daemon_in_vm` + `daemon_capacity()`.
- `doctor-runner` untouched (its strict `Runner.Worker` semantics are
  a separate view from daemon settling's "ready locally").
- No force push, no `git add -A`.

---

## Prior commits (preserved for context)

### `b4669de` — round-2 review feedback

- `LOCAL_TOP_TIMEOUT 3s → 6s` (bead jleechan-95jk: measured 3.2-4.5 s
  `docker top` latency on Mac under load; 5 new tests including
  overrun-propagates-as-Err, parallel-completion-under-6s, absent-summary
  plumbing, NotReady-distinct-from-Absent).
- Removed unused `pub enum RunnerActivityState` + parser + test.
- Renamed daemon settling log lines `executing locally` → `ready locally
  (listeners or workers)`. `runner_present` bool view unchanged.
- Surfaced absent container names via `ReadinessSummary.absent` so the
  settling loop forces `Ceiling` instead of waiting out 25 s. Pinned by
  `readiness_summary_reports_absent_container_names` and
  `readiness_summary_treats_not_ready_distinct_from_absent`.

### `d250267` — first-pass

- Parallel `docker top` fan-out via `std::thread::scope` (Mac 6×3 s → ≤3 s).
- `LocalRunnerActivity::{Busy, Unknown, Idle, Absent}` 4-state split.
- `release_stale_slots` reclaims `Absent` slots immediately with
  `reason=gh-rejected-container-absent`.

---

## Original `d250267` RESULTS section

#### 1. Parallel readiness probes (Mac 6×3s → ~3s wall-clock)

`executing_runner_count_with_probe` now fans `docker top` out across every
owned container in parallel via `std::thread::scope` instead of strictly
sequentially. Per-probe budget is still capped at `LOCAL_TOP_TIMEOUT`
(6 s in `b4669de`; 3 s in `d250267`) and the shared `LOCAL_READINESS_BUDGET`
(30 s) is still honored.

| Slots | Sequential worst-case | Parallel worst-case |
|---|---|---|
| 6 Mac  | 6 × 3 s = 18 s | ≤ 3 s (+ overhead) |
| 10 Linux | 10 × 3 s = 30 s (entire budget) | ≤ 3 s (+ overhead) |

#### 2. Busy / ReadyIdle diagnostic split (no idle-regress)

`LocalRunnerActivity::{Busy, Unknown, Idle, Absent}` and
`docker_top_container_absent` classifier pin the four-state split.
`release_stale_slots` matches `Absent` and reclaims immediately.

#### 3. Container-absent reclaim (settling stops waiting on dead slots)

`Absent` is a normal probe outcome (other 9/10 slots' evidence stays
usable); container name surfaces to settling via `ReadinessSummary.absent`
(see `b4669de` for the full plumbing).

## Queue scheduler cadence correction (2026-10-04)

The current ceiling plan returns `(Duration::ZERO, false)`; the earlier
`true` description records the superseded implementation. Queue/invariant
dispatch now checks each enabled monitor's own due interval before cloning
configuration or spawning a worker. Attempts are separated by at least
`runner.serve_tick()`, including unknown/low REST budget, tick errors, and
OS spawn failures. This keeps tick-counted REST backoff from being compressed
by zero-sleep ceiling or five-second settling iterations. Fallible named
thread spawning restores both states on failure; single-flight monitoring
remains independent of runner refill.
