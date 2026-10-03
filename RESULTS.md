# Runner throughput results — 2026-10-03

Branch: `codex/runner-throughput-20261003` (working tree only; no push done
yet — root owns runtime deploy per repo policy + this session's no-restart
gate). Source-only diff: `src/docker_backend.rs` +444 / -37.

## What changed

### 1. Parallel readiness probes (Mac 6×3s → ~3s wall-clock)

`executing_runner_count_with_probe` now fans `docker top` out across every
owned container in parallel via `std::thread::scope` instead of strictly
sequentially. Per-probe budget is still capped at `LOCAL_TOP_TIMEOUT` (3s)
and the shared `LOCAL_READINESS_BUDGET` (30s) is still honored — earlier
probes that finish quickly do not extend the deadline, and the FIRST
container whose `now()` reads past the deadline is the one named in the
incomplete-readiness error.

| Slots | Sequential worst-case | Parallel worst-case |
|---|---|---|
| 6 Mac  | 6 × 3s = 18s | ≤ 3s (+ scheduling overhead) |
| 10 Linux | 10 × 3s = 30s (entire budget) | ≤ 3s (+ scheduling overhead) |

Empirical: 6×50ms probes in
`parallel_readiness_probes_share_wall_clock_within_max_probe` complete in
≤ 4 × probe_cost + 100ms = 300ms; an isolated
`std::thread::spawn` measurement on this host shows 6×50ms parallel
= 50.3ms vs sequential = 300.4ms (≈ 6× speedup at this host's overhead).

Bounded by fleet contract: `owned.len() ≤ cfg.runner.count` (10 Linux + 6
Mac contract = 16 max), itself under `DOCKER_REAPER_ACTIVE_CAP` (64). No
new dependency, no new threading primitive — `std::thread::scope` is
stable in Rust 1.63+.

### 2. Busy / ReadyIdle diagnostic split (no idle-regress)

New `pub enum RunnerActivityState { Busy, ReadyIdle, Unknown }` and
`runner_activity_state(&str)` parser pin the three-state split:

* `Busy` — `Runner.Worker` present (executing a job right now)
* `ReadyIdle` — only `Runner.Listener` (registered, polling for work)
* `Unknown` — neither (broken container, runner process died)

`runner_present` (the boolean "ready to take jobs" view) is unchanged:
Listener OR Worker both still count as ready. The bead-jleechan-viff
fix (counting listeners as ready to suppress the false-positive
`settling ceiling reached` CRITICALs on idle healthy fleets) is preserved.

### 3. Container-absent reclaim (settling stops waiting on dead slots)

New `LocalRunnerActivity::Absent` variant. `local_runner_activity` now
classifies `docker top` stderr "No such container" / "No such object"
as `Absent` (container is definitively gone) — DISTINCT from `Unknown`
(timeout / daemon error / transient I/O stays fail-safe per the bead
directive "do not blindly treat all errors as absence").

`release_stale_slots` matches `Absent` and reclaims the slot
immediately, with a dedicated `reason=gh-rejected-container-absent`
log line and `ReclaimRecord` reason code. The settling-readiness path
treats `Absent` as `Ok(false)` (slot not ready) instead of bailing the
whole readiness pass on one dead container — so the other 9/10 slots'
evidence stays usable and the next serve tick can reconcile promptly
without waiting out the 30s shared budget.

`docker_top_container_absent(&str)` is the shared stderr classifier
both paths use. Pinning this in a test prevents drift if the docker
engine wording ever changes.

## Tests

```
$ cargo test --bin ezgha 2>&1 | tail -3
test result: ok. 427 passed; 0 failed; 1 ignored; 0 measured; 0 filtered out
```

| Test | Pins |
|---|---|
| `docker_top_container_absent_classifies_only_no_such_container` | The stderr classifier (only "No such container" / "No such object", not timeouts/daemon errors) |
| `runner_activity_state_distinguishes_busy_vs_ready_idle` | The three-state diagnostic split (Worker wins over Listener; substring non-match) |
| `parallel_readiness_probes_share_wall_clock_within_max_probe` | 6 parallel probes finish in ≤ 4×probe_cost + 100ms (parallelism headline win) |
| `parallel_readiness_probes_respect_per_probe_timeout` | Spawn-then-break on first deadline expiry; earlier probes still run |
| `release_stale_slots_reclaims_when_local_container_is_absent` | `LocalRunnerActivity::Absent` reclaims the slot (NOT the Unknown fail-safe) |

Existing tests adapted to the new `Fn + Sync` probe signature:

* `readiness_probes_share_deadline_and_stop_after_it` — wraps the
  per-probe `launched: Vec<(String, Duration)>` in `Arc<Mutex<_>>`
  (sort-by-name assertion; thread scheduling no longer deterministic).
* `executing_runner_count_from_containers` test branch — uses
  `AtomicU32::fetch_update` (saturating) instead of `fetch_sub` so the
  parallel-threads race past zero doesn't wrap `remaining` to
  `u32::MAX` and falsely report post-zero probes as ready.

Existing shell-test regressions also clean:

```
$ bash tests/commit_msg_provenance_prefix_test.sh       # PASS
$ bash tests/doctor_runner_verdict_line_test.sh        # PASS
$ bash tests/doctor_runner_expected_containers_test.sh  # PASS
$ bash tests/doctor_runner_heartbeat_starvation_test.sh # PASS
$ bash tests/doctor_runner_respawn_journal_test.sh      # PASS
```

## What was NOT done (out of scope / user-gated)

* No `cargo install` / `systemctl restart` / service touch — root
  rebuilds Linux then Mac after independent review.
* No changes to `~/.config/ezgha/config.toml`, runner count, prefix,
  image, or any host-side process. Source-only.
* No force push, no `git add -A` (single file staged).
* No dependency additions.
* `runner_activities_from_containers` (a future consumer-facing
  diagnostic helper returning `Vec<(String, RunnerActivityState)>`)
  was deliberately NOT added — the diagnostic enum is exposed and
  tested, but `main.rs` continues to consume the existing
  `local_executing_runner_count(&cfg) -> Result<u32>` so this commit
  ships no daemon-behavior change beyond the parallel probe and the
  Absent reclaim.

## Recommended review order

1. `runner_activity_state` + `RunnerActivityState` enum (~30 lines).
2. `docker_top_container_absent` classifier + `LocalRunnerActivity::Absent`
   + `local_runner_activity` classification (~50 lines).
3. `release_stale_slots` `Absent` arm (the consumer of #2).
4. `executing_runner_count_with_probe` parallel rewrite (the
   `Fn + Sync` signature change is the load-bearing one).
5. `executing_runner_count_from_containers` non-test branch
   "No such container" treatment.
6. New tests in the same commit.