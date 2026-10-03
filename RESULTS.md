# Runner throughput — 2026-10-03

Branch `codex/runner-throughput-20261003` — source-only changes,
ready for root runtime deployment. Three commits, in order:

| Commit | Subject |
|---|---|
| `d250267` | runner throughput: parallel readiness probes + busy/idle diagnostics + container-absent reclaim |
| `b4669de` | runner throughput: 6s probe cap + absent reconcile + drop unused activity enum |
| `HEAD`   | runner throughput: opt-in cpu_burst + absent-shortage fix (independent-review critical) |

## Final HEAD for deployment

```
<pending: SHA printed after this commit lands>
```

Root owns `cargo install --path .`, `systemctl --user restart ezgha.service`,
the `~/.config/ezgha/config.toml` edits, and `git push` (no `git add -A`,
no force push).

---

## Commit HEAD — post-review critical fix + opt-in cpu_burst

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

2026-10-03 Mac `cgroup cpu.stat` sample: one runner used 7.69 M us in 6 s,
throttled 57/58 periods (5.21 M us / 12.9 M us = 87 % clipped). All 6
aggregate 3.3 CPU; VM had 4.7 CPU unused. Equal-share clamp `8/6 = 1.33`
was the bottleneck (hot job needed ~2.15 CPUs).

Design (minimum safe, default unchanged):
- New `limits.cpu_burst: bool` (default `false`).
- Honored ONLY when `platform::detect().daemon_in_vm` AND finite
  `daemon_capacity().0`. Otherwise loud warning + equal-share fallback.
- Per-container ceiling relaxes to `min(cfg.limits.cpus, ncpu)`. Aggregate
  `count * ceiling` still bounded by VM physical CPUs via kernel
  `cfs_quota_us` on the daemon cgroup.
- Memory clamp unchanged.
- Reuses existing `daemon_in_vm` + `daemon_capacity()` probes.

Four focused tests pin the contract:
- `cpu_burst_defaults_to_false`
- `cpu_burst_with_vm_and_finite_capacity_relaxes_to_daemon_cpu`
- `cpu_burst_without_vm_or_capacity_falls_back_to_equal_share` (host + unknown)
- `cpu_burst_per_container_cap_does_not_exceed_daemon_capacity`

### Test summary

```
$ cargo test --bin ezgha -j 2 2>&1 | tail -3
test result: ok. 436 passed; 0 failed; 1 ignored; 0 measured; 0 filtered out
```

Up from 431 (`b4669de`): +5 (1 absent-regression + 4 cpu_burst).

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