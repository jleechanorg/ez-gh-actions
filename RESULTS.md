# Runner throughput results — 2026-10-03

Branch: `codex/runner-throughput-20261003` (working tree only; no push done
yet — root owns runtime deploy per repo policy + this session's no-restart
gate).

This document covers two commits on the branch:

* **Commit 1 — `d250267`** first-pass: parallel readiness probes +
  Busy/ReadyIdle/Unknown diagnostic split + container-absent reclaim.
  Original RESULTS.md below preserves that scope.
* **Commit 2 — pending**: round-2 review feedback. Three fixes:
  (a) raise per-probe `LOCAL_TOP_TIMEOUT` from 3s to 6s (measured 3.2-4.5s
      `docker top` latency on Mac under load), with tests pinning the new
      cap and that overrun probes propagate as `Err` not `Absent`;
  (b) drop the unused `pub enum RunnerActivityState` + `runner_activity_state`
      parser; rename the actual settling log lines to "ready locally
      (listeners or workers)" (the bool `runner_present` view stays — bead
      jleechan-viff Listener-or-Worker semantics preserved; doctor-runner
      stays strict `Runner.Worker`);
  (c) surface absent container names to the settling loop so it forces
      immediate reconciliation instead of waiting 25s for a slot that
      `docker top` says "No such container" (bead jleechan-95jk root-cause
      evidence).

---

## Commit 2 — round-2 review feedback fixes

### Fix 1 — `LOCAL_TOP_TIMEOUT` 3s → 6s

```rust
// src/docker_backend.rs
const LOCAL_TOP_TIMEOUT: Duration = Duration::from_secs(6);
```

Bead jleechan-95jk measured 3.2-4.5s `docker top` latency on the Mac
host under load. A 3s cap killed in-flight probes that were still going
to succeed and reported false "not ready". The parallel fan-out from
commit 1 keeps the shared 30s readiness budget bounded even with a 6s
per-probe cap — worst case is one slow probe (6s) plus scheduling
overhead, NOT 16 sequential 6s.

| Slots | Old sequential | Parallel (3s cap) | Parallel (6s cap) |
|---|---|---|---|
| 6 Mac  | 6 × 3s = 18s | ≤ 3s (+ overhead) | ≤ 6s (+ overhead) |
| 10 Linux | 10 × 3s = 30s (entire budget) | ≤ 3s (+ overhead) | ≤ 6s (+ overhead) |

Tests:

* `readiness_probe_timeout_caps_at_six_seconds_and_preserves_sub_six_seconds`
  — caps `30s → 6s`, preserves `5s → 5s`, preserves `2s → 2s`,
  preserves `500ms → 500ms`.
* `parallel_readiness_probes_complete_between_three_and_six_seconds` —
  three 5s sleeps all return `Ready`; total elapsed is in `[5s, 7s)`.
  This was the regression case at 3s: the old cap would have killed
  these probes mid-sleep.
* `parallel_readiness_probes_pass_six_second_timeout_argument` — the
  orchestrator hands the probe a `Duration::from_secs(6)` (not 3s).
  Companion to the cap test; pins the actual argument value.
* `parallel_readiness_probe_overrun_propagates_as_err_not_absent` —
  when the probe respects its timeout argument (the production probe
  uses `run_docker_with_timeout_at_deadline` which kills the docker
  process at the cap), the `Err` reaches `run_orchestrator` and is
  surfaced as `Err`, not silently mapped to `ProbeOutcome::Absent`.
  Pins the "Unknown safety" half of the bead directive: do not blindly
  treat all errors as absence.
* Existing `parallel_readiness_probes_share_wall_clock_within_max_probe`
  unchanged in spirit; comment updated to reference the 6s cap.

### Fix 2 — drop unused public abstraction, rename actual log lines

Removed:

* `pub enum RunnerActivityState { Busy, ReadyIdle, Unknown }`
* `fn runner_activity_state(output: &str) -> RunnerActivityState`
* `runner_activity_state_distinguishes_busy_vs_ready_idle` test

Replaced the daemon's settling log lines in `src/main.rs` from
`executing locally` to `ready locally (listeners or workers)`:

```
runner startup settling: 4/6 ready locally (listeners or workers) (poll 3/5)
runner startup settled:  6/6 ready locally (listeners or workers) after 4 poll(s)
runner startup settling ceiling reached: 4/6 ready locally (listeners or workers), best 5, 5 poll(s); running monitors before immediate reconciliation
```

`runner_present` (the bool view) is unchanged: Listener OR Worker counts
as ready, per bead jleechan-viff. The doctor-runner script keeps its
strict `Runner.Worker` EXECUTING semantics (only Worker, not Listener,
counts as EXECUTING) — see `doctor-runner`'s `classify_local_slot`
function. The two views are now honest:

* **Daemon settling** — "ready locally" = Listener or Worker (one slot
  can take a job).
* **Doctor-runner** — "EXECUTING" = Worker only (one slot is currently
  running a job).

### Fix 3 — surface absent container names to the settling loop

New `pub struct ReadinessSummary { pub ready: u32, pub absent: Vec<String> }`
returned by `local_executing_runner_count`. The settling loop in
`src/main.rs` now:

```rust
let decision = if !absent_names.is_empty() && executing < cfg.runner.count {
    eprintln!(
        "runner startup settling: {executing}/{} ready locally \
         (listeners or workers), but {} container(s) absent: \
         {absent_names:?}; forcing immediate reconciliation \
         instead of waiting out the {}-poll settling ceiling",
        cfg.runner.count, absent_names.len(), MAX_SETTLING_POLLS,
    );
    SettlingDecision::Ceiling
} else {
    episode.observe(Instant::now(), executing, cfg.runner.count)
};
```

The crucial user-cited bug was the Linux journal pattern "keeping slot
3 because docker top says No such container despite snapshot omission"
at 14:45:50 — the settling loop polled for 25s waiting for the absent
slot to come back. With `ProbeOutcome::Absent` now propagating the
container name into `ReadinessSummary.absent`, the settling loop forces
`SettlingDecision::Ceiling` immediately. `Ceiling` clears the local
settling episode and `settling_plan` returns `(Duration::ZERO, true)`,
so the next serve tick runs monitors and a full `ensure_count_outcome`
without waiting out the 25s ceiling.

Genuine `Err` from the probe (timeout, daemon error, transient I/O) is
**NOT** mapped to `ProbeOutcome::Absent` — it propagates as `Err` and
the settling loop preserves its existing wait-for-evidence behavior.
This is the "Unknown safety" half of the bead directive. Pinned by
`parallel_readiness_probe_overrun_propagates_as_err_not_absent` above.

New tests:

* `readiness_summary_reports_absent_container_names` — 4 containers;
  slots 2 and 4 return `ProbeOutcome::Absent`, slots 1 and 3 return
  `Ready`. Asserts `summary.ready == 2` and
  `summary.absent == ["ez-org-runner-2", "ez-org-runner-4"]` (sorted).
* `readiness_summary_treats_not_ready_distinct_from_absent` — slot 2
  returns `ProbeOutcome::NotReady` (container alive, no Runner
  process). Asserts `summary.ready == 2` and `summary.absent.is_empty()`
  — NOT conflating NotReady with Absent.

Post-refill (`ensure_count_outcome`'s `containers_after` recount)
also uses the new struct: `ready + absent.len()` is the alive count,
so a freshly-started container that dies before docker-top can find it
counts toward the remaining shortage instead of leaving settling to
poll 25s.

### Test summary (commit 2)

```
$ cargo test --bin ezgha -j 2 2>&1 | tail -3
test result: ok. 431 passed; 0 failed; 1 ignored; 0 measured; 0 filtered out
```

Up from 427 (commit 1): +5 new tests, −1 removed (`runner_activity_state_distinguishes_busy_vs_ready_idle`).

| Test | Pins |
|---|---|
| `readiness_probe_timeout_caps_at_six_seconds_and_preserves_sub_six_seconds` | `LOCAL_TOP_TIMEOUT = 6s` (raised from 3s for 3.2-4.5s measured probes) |
| `parallel_readiness_probes_complete_between_three_and_six_seconds` | 5s sleeps complete under 6s cap (regression case at 3s) |
| `parallel_readiness_probes_pass_six_second_timeout_argument` | Orchestrator hands the probe exactly `Duration::from_secs(6)` |
| `parallel_readiness_probe_overrun_propagates_as_err_not_absent` | "Unknown safety": probe `Err` propagates as `Err`, not silently mapped to `Absent` |
| `readiness_summary_reports_absent_container_names` | Parallel orchestration's `ProbeOutcome::Absent` → `ReadinessSummary.absent` plumbing |
| `readiness_summary_treats_not_ready_distinct_from_absent` | `NotReady` (alive container, no Runner) is NOT conflated with `Absent` |

Existing shell-test regressions also clean:

```
$ bash tests/commit_msg_provenance_prefix_test.sh       # PASS
$ bash tests/doctor_runner_verdict_line_test.sh        # PASS
$ bash tests/doctor_runner_expected_containers_test.sh  # PASS
$ bash tests/doctor_runner_heartbeat_starvation_test.sh # PASS
$ bash tests/doctor_runner_respawn_journal_test.sh      # PASS
```

Existing unit tests adapted:

* `readiness_probe_timeout_caps_at_three_seconds_*` → renamed to
  `readiness_probe_timeout_caps_at_six_seconds_*`.
* `readiness_probes_share_deadline_and_stop_after_it` — per-probe
  caps updated from 3s to 6s.
* `parallel_readiness_probes_respect_per_probe_timeout` — probe
  returns `ProbeOutcome::Ready`/`NotReady` (was `Ok(true)`/`Ok(false)`).
* `parallel_readiness_probes_share_wall_clock_within_max_probe` —
  same probe return-type migration; asserts `result.unwrap().ready`
  (was `result.unwrap()`).
* `executing_runner_count_from_containers` test branch — same
  migration; `Ok(present)` becomes
  `Ok(if present { ProbeOutcome::Ready } else { ProbeOutcome::NotReady })`.
* `local_worker_readiness_propagates_incomplete_probe_evidence` —
  unchanged: the configured `Err("synthetic docker top timeout")`
  propagates through unchanged.
* `post_refill_incomplete_readiness_preserves_starts_*` —
  `local_executing_runner_count(&cfg).unwrap().ready` (was `.unwrap()`).

### What was NOT done (out of scope / user-gated)

* No `cargo install` / `systemctl restart` / service touch — root
  rebuilds Linux then Mac after independent review.
* No changes to `~/.config/ezgha/config.toml`, runner count, prefix,
  image, or any host-side process. Source-only.
* No force push, no `git add -A` (single file staged).
* No dependency additions.
* `doctor-runner` was NOT touched — it keeps its strict `Runner.Worker`
  EXECUTING semantics (the daemon settling view is a separate concern).
* No removal of `LocalRunnerActivity::Absent` — the per-slot reclaim
  path in `release_stale_slots` still uses it; the daemon settling
  short-circuit added here uses the same `docker_top_container_absent`
  classifier from a different vantage point.

---

## Commit 1 — `d250267` first-pass (parallel probes + diagnostic split + absent reclaim)

### What changed

#### 1. Parallel readiness probes (Mac 6×3s → ~3s wall-clock)

`executing_runner_count_with_probe` now fans `docker top` out across every
owned container in parallel via `std::thread::scope` instead of strictly
sequentially. Per-probe budget is still capped at `LOCAL_TOP_TIMEOUT` (6s
in commit 2; 3s in commit 1) and the shared `LOCAL_READINESS_BUDGET` (30s)
is still honored.

| Slots | Sequential worst-case | Parallel worst-case |
|---|---|---|
| 6 Mac  | 6 × 3s = 18s | ≤ 3s (+ overhead) |
| 10 Linux | 10 × 3s = 30s (entire budget) | ≤ 3s (+ overhead) |

#### 2. Busy / ReadyIdle diagnostic split (no idle-regress)

`LocalRunnerActivity::{Busy, Unknown, Idle, Absent}` and `docker_top_container_absent`
classifier pin the four-state split. `release_stale_slots` matches `Absent`
and reclaims immediately with `reason=gh-rejected-container-absent`.

#### 3. Container-absent reclaim (settling stops waiting on dead slots)

The settling-readiness path treats `Absent` as a normal probe outcome (so
the other 9/10 slots' evidence stays usable) and surfaces the container
name to the settling loop (commit 2 expanded this surface area into
`ReadinessSummary.absent` so the settling loop can force immediate
reconciliation).