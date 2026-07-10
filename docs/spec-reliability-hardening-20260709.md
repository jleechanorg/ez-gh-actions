# Spec — ezgha reliability hardening (SIGTERM drain · deploy lock · chaos canary)

**Date:** 2026-07-09
**Beads:** `ez-gh-actions-30p` (P0, also tracked as `-uh2` P1) · `ez-gh-actions-k5yk` (P1) · `ez-gh-actions-29v1` (P1)
**Author:** exploration/spec pass (implementation NOT started — route coding through /sidekick or /swarm)
**Posture:** reliability-first, brownfield. **No new features, no new logging systems, no new crates.** Single binary. Reuse `src/main.rs` (serve loop), `src/docker_backend.rs` (slot lifecycle), `src/github.rs` (API), `src/service.rs` (unit generation).

---

## 0. Runtime facts this spec is built on (verified, with citations)

- The daemon is **plain `std`, blocking, single-threaded** — **not tokio**. `fn main()` at `main.rs:612` is non-async; concurrency is a couple of manual `std::thread`s (watchdog heartbeat, platform probe). The serve loop is a bare `loop { … std::thread::sleep(sleep); }` at `main.rs:763-859` with **no exit condition**.
- **Zero signal handling exists today.** No SIGTERM/SIGINT/ctrl_c/tokio::signal/sigaction anywhere in `src/`. On `systemctl stop` / watchdog restart the process is simply SIGKILLed after the stop timeout. (bead 30p problem statement)
- Available crates only: **`libc = "0.2"`** (already used for `flock` at `main.rs:1026-1028`; provides `signal`/`sigaction`/`getloadavg`) and **`sd-notify = "0.4"`** (already sends `Ready` at `main.rs:132` and `Watchdog` pings at `watchdog.rs:11`). No tokio, signal-hook, nix, ctrlc, fs2, fd-lock. `Cargo.toml:13-22`.
- **Systemd unit is generated in-binary** by `service.rs::systemd_service_unit` (`service.rs:24-75`) → `~/.config/systemd/user/ezgha.service`. It is `Type=notify` (`service.rs:51`), `WatchdogSec=300` (`service.rs:62`), `NotifyAccess=all` (`service.rs:63`). **It has no `TimeoutStopSec`, no `KillMode`, no `KillSignal`, no `NotifyState::Stopping`.** Default `DefaultTimeoutStopSec` (~90s) applies.
- **launchd plist is generated in-binary** by `service.rs::install_launchd` (`service.rs:147-222`) with `KeepAlive=true` (`service.rs:184-185`) — so a graceful self-exit under launchd is read as a crash and relaunched unless coordinated. No `NOTIFY_SOCKET` on macOS, so all sd_notify/watchdog calls are already no-ops there by design.
- **`slot_assignments.toml` is the only durable in-flight record.** `SlotAssignments` (`docker_backend.rs:54-78`): `assignments[slot]=""` means *reserved, JIT in flight, container not yet up*; `assignments[slot]=<runner_id>` means *assigned*; `registered_at[slot]` starts the 60s grace window. Writes are atomic temp-file+`rename(2)` (`docker_backend.rs:245-260`) precisely to survive mid-flight death.
- **po2 respawn-pacing is OBSOLETE.** It was merged (`d612ad7`) then **removed** (`c46fa7e`, "watchdog now 96"); bead closed obsolete (`eab6b5e`). Spawning is now **strictly serial, all N-missing back-to-back in one loop, no pacing/loadavg gate** (`start_missing_runners_with_starter`, `docker_backend.rs:1284-1323`), pinned by regression test `start_missing_runners_starts_full_shortfall_directly` (`docker_backend.rs:1690`). **Consequence:** a kill mid-`ensure_count` can leave *several* JIT registrations in the orphan window simultaneously — raising the stakes for 30p. (Corrects the stale memory note that po2 was gated on 30p.)

### The orphan window (the defect 30p closes)

```
next_slot_excluding       docker_backend.rs:294   slot row = ""            [reserved, no GH reg]
generate_jitconfig        github.rs:765/814/831   GH POST creates reg   ◀ ORPHAN WINDOW OPENS
                                                   returns (jit, runner_id)
record_slot_runner_id_for docker_backend.rs:1085   slot row = runner_id     [assigned; 60s grace starts]
docker run -d --rm        docker_backend.rs:1106    container starts
return (id, name)         docker_backend.rs:1125                          ◀ ORPHAN WINDOW CLOSES
```
Kill between `github.rs:1075` and `docker_backend.rs:1125`: GitHub registration is live, no container. Today the **only** cleanup is the async `release_stale_slots` reaper on the *next* start's tick, gated by the 60s `REGISTRATION_GRACE_WINDOW` (`docker_backend.rs:80-87, 646-663`) — and it **fails closed** (reaps nothing) when GitHub is unreachable (`docker_backend.rs:355-376`). In-process cleanup at `docker_backend.rs:1109/1118` (`github::remove_runner`) only fires when `docker run` *returns an error to the live process* — never on a `kill -9`. This is the 409-zombie slot-starvation source from 2026-07-08/09.

---

## 1. Blast-radius statement (required by CLAUDE.md §Safety)

Per the Blast-Radius & Interaction Review rule, each change states the bounded metric, its normal peak, and the safe margin. Per the Self-Outage Prevention Principle, none of these mechanisms may cause the outage they guard against.

| Change | Bounded metric | Normal peak | Directive / margin |
|---|---|---|---|
| SIGTERM drain grace budget | wall-clock between SIGTERM and clean exit | drain of ≤ (16 Linux) in-flight regs, each a bounded `remove_runner_until` | Hard cap **15s** total drain (below the **300s** `WatchdogSec` and below default **90s** `TimeoutStopSec`). Add explicit `TimeoutStopSec=30` so systemd never SIGKILLs mid-drain. |
| New `remove_runner_until` (deadline-bounded delete) | per-call GitHub blocking time | unbounded `remove_runner` today can sleep ~128s+ under secondary rate-limit backoff | Bounded by caller deadline (≤15s). On deadline miss it **leaves the reaper to reclaim** (fail-safe, not fail-orphan) — the 60s grace window + forward-sweep already handle it. |
| Interruptible serve sleep | SIGTERM-to-observe latency | up to a full `serve_tick` (30s default) today | Replace `std::thread::sleep` at `main.rs:858` with the existing `watchdog::sleep_interruptibly` idiom → latency ≤ poll granularity (~200ms). No change to tick cadence. |
| Deploy lock (`ezgha deploy`) | concurrent prod mutators | 2 shared-checkout deploy collisions on 2026-07-09 | `flock(LOCK_EX\|LOCK_NB)` on `deploy.lock` — a second deployer fails **loudly with the owner's session id**, zero silent races. Reuses the proven `serve.lock` pattern. |
| Chaos canary | fleet disruption during self-test | kills **1** container + injects **1** simulated fault per run | **Opt-in, off by default** (`[chaos].enabled=false`); refuses to run if `load_1min > 12` or `containers < count`; kills exactly one slot and asserts self-heal — it must never itself trip the fleet below floor for longer than the SLO it measures. Self-Outage Principle: guarded by the same Gate-0 preconditions as deploy. |

---

## 2. Brownfield inventory — what STAYS, what CHANGES, what is DELETED

**Delete-first rule:** if a root-cause change obsoletes a prior mechanism, delete it rather than stack a patch (memory: `second-fix-means-stop`).

### STAYS (reused as-is)
- `generate_jitconfig(gh, name, labels, owned_ids) -> (encoded_jit, runner_id)` — `github.rs:758`. `runner_id` (u64) is the load-bearing drain handle.
- `remove_runner(gh, id)` — `github.rs:963`. The delete primitive (but see CHANGES: needs a bounded twin).
- `list_runners` / `list_runners_until` — `github.rs:915/921`.
- `runner_is_reclaimable` — `github.rs:903` (owned→any-state, cross-host→offline+!busy only). Drain must delete **by owned id**, never by name (cross-host name collisions must not be force-deleted).
- `slot_assignments.toml` model + atomic write + `release_stale_slots` reaper + 60s grace window — `docker_backend.rs:54-78, 245-260, 348-558`. The drain is a *fast path*; the reaper stays as the *safety net* for anything drain misses.
- `acquire_serve_lock` / `ServeLock` flock pattern — `main.rs:1003-1041`. Generalized for the deploy lock.
- `managed_containers` / `current_prefix_containers` — `docker_backend.rs:1145/1173`. The local "N healthy" primitive for Gate-0 and chaos assertions.
- `watchdog::sleep_interruptibly` + `AtomicBool` stop-flag idiom — `watchdog.rs:71-80`. The template for the shutdown flag.
- `run_restart_command_with_timeout` — `main.rs:333`. Reused for deploy subprocess steps.
- Existing **workflow** canary (`canary.rs`) — untouched; the chaos canary is orthogonal.

### CHANGES (edited in place)
- **`main.rs` serve loop** (`main.rs:763-859`): add shutdown-flag check at loop top and replace the `main.rs:858` sleep with an interruptible one. **Coordinate with sibling `codex/hardening-bxy-fl0`** which also edits `main.rs` (+52) and `watchdog.rs` (+53, adds a heartbeat thread) — claim `main.rs`/`watchdog.rs` ownership before dispatching a coder (memory: cross-host file ownership; 3 collisions/day).
- **`service.rs::systemd_service_unit`** (`service.rs:46-71`): add `TimeoutStopSec=30`. Optionally `KillMode=mixed` so only the main process gets SIGTERM first (children reaped after). Requires reinstall of the unit.
- **`service.rs::install_launchd` plist** (`service.rs:176-200`): add `ExitTimeOut` and ensure graceful self-exit isn't fought by `KeepAlive` during a deploy-driven stop (see §3.4).
- **`github.rs`**: add `remove_runner_until(gh, id, deadline)` built on the existing `run_gh_with_backoff_until` (`github.rs:393-398`), mirroring `list_runners_until`. The current `remove_runner` uses **unbounded** backoff and can blow a 15s budget.
- **`Commands` enum + dispatch** (`main.rs:37-105`, `616-938`): add `Deploy` and `SelfTest`/`Chaos` variants (clap derive).

### DELETED / explicitly NOT built
- **No new logging or telemetry system** (goal constraint). Chaos results reuse the existing JSONL `append_history` pattern (`canary.rs:347`) and `alert` path — no new sink.
- **No revival of po2 pacing.** It is deleted and obsolete (watchdog now 96s effective via the sibling heartbeat). Do not reintroduce load-gated batching into `ensure_count`; the regression test at `docker_backend.rs:1690` pins this.
- **`stop_all` is NOT reused for graceful shutdown.** `stop_all` (`docker_backend.rs:1194-1240`) `docker rm -f`s **every** owned container unconditionally (`docker_backend.rs:1199`) — that aborts in-progress jobs, violating 30p requirement (3) "do not kill already-running/registered containers." Graceful drain must **only** touch in-flight (non-container-backed) registrations. `stop_all` stays wired to the manual `ezgha stop` CLI only.
- **No new `Canary*` name overloads.** Chaos types use distinct names (`ChaosResult`, `[chaos]` TOML) to avoid colliding with `CanaryResult`/`CanaryConfig`/`ezgha-canary-*` (`canary.rs:12-30, 143`).

---

## 3. Feature 1 — SIGTERM graceful shutdown (bead 30p, P0)

**Goal:** on stop/restart the serve loop stops spawning, drains/deregisters in-flight JIT registrations, leaves running containers alive, and exits cleanly within a bounded grace — so restarts never orphan registrations. Must satisfy systemd `Type=notify` + `WatchdogSec=300` + `TimeoutStopSec` and macOS launchd SIGTERM semantics.

### 3.1 Signal handler (libc, async-signal-safe)
- Install once, before the serve loop, via `libc::sigaction` (or `libc::signal`) for **SIGTERM and SIGINT**.
- Handler does **only** `SHUTDOWN.store(true, Ordering::SeqCst)` on a process-global `static AtomicBool` — no allocation, no I/O (async-signal-safety). This mirrors the watchdog `AtomicBool` idiom (`watchdog.rs:16, 43-52`).
- Immediately send `sd_notify(false, &[NotifyState::Stopping])` from the loop (not the handler) once the flag is observed, so systemd knows drain is in progress and the `WatchdogSec` clock intent is clear.

### 3.2 Seams the flag is observed at (exact)
1. **Loop top** `main.rs:763`: `if SHUTDOWN.load() { break; }` — gives the only exit from the infinite loop.
2. **Before `ensure_count_outcome`** `main.rs:767`: skip the spawn/reconcile call so no new runners start.
3. **Spawn gate** `start_missing_runners_with_starter` `docker_backend.rs:1293` (next to the existing `watchdog::ping()`): check flag inside `for _ in 0..missing` and `break` mid-batch — stops spawning even if SIGTERM lands during a refill.
4. **Sleep** `main.rs:858`: replace `std::thread::sleep(sleep)` with `watchdog::sleep_interruptibly(sleep, &SHUTDOWN)` so SIGTERM latency is ≤ poll granularity instead of ≤ 30s.

### 3.3 Drain algorithm (on `break`, before `Ok(())`)
```
deadline = Instant::now() + 15s
regs = read_slot_assignments_for(cfg)                     // docker_backend.rs:133
containers = managed_containers()                          // docker_backend.rs:1145 (source of truth)
for (slot, id) in regs.assignments:
    if id == "":                                           // reserved, JIT not yet issued
        release_slot_for(slot)                             // local only, no GH reg exists
        continue
    if a live container is labelled ezgha.runner_id == id: // docker_backend.rs:1088-1104 label
        leave it  — a real runner is (or will be) attached; DO NOT deregister or rm
        continue
    // in-flight orphan: registration exists, no container ⇒ deregister
    if Instant::now() < deadline:
        remove_runner_until(gh, id, deadline)              // NEW bounded delete
        release_slot_for(slot)
    else:
        leave for release_stale_slots reaper (60s grace + forward sweep)
```
Key invariants:
- **Only** registrations with **no matching container** are deregistered. Anything backed by a running container (busy or idle) survives the restart and is re-counted by `ensure_count` on next start (adopt-not-kill; `docker_backend.rs:1356-1363`).
- Delete strictly by **owned runner_id**, never by name (`runner_is_reclaimable` cross-host guard, `github.rs:903-913`).
- Anything not drained within 15s is **safe** — the reaper + grace window reclaim it. Drain is best-effort-fast, not the sole guarantee. Fail-safe, never fail-orphan.

### 3.4 systemd / launchd contract
- **systemd:** add `TimeoutStopSec=30` to `service.rs:46-71` (drain caps at 15s, leaving margin). Keep `Type=notify`; send `NotifyState::Stopping`. Consider `KillMode=mixed`. **Reinstall required** (`ezgha install-service`) — call out in the deploy runbook.
- **launchd:** on macOS `KeepAlive=true` (`service.rs:185`) relaunches on any exit, and there's no `NOTIFY_SOCKET`. The `libc` SIGTERM handler works identically (platform-agnostic). Add `ExitTimeOut` to the plist. For a *deploy-initiated* stop, the deploy path must `launchctl unload` (not just kill) so KeepAlive doesn't fight the graceful exit; a plain `launchctl kickstart -k` restart still delivers SIGTERM → handler drains → exit → relaunch, which is acceptable (drain runs before exit).

### 3.5 Interaction with sibling `hardening-bxy-fl0`
That branch adds `watchdog::start_heartbeat()` (independent keepalive thread, `watchdog.rs`) and touches `main.rs` (+52). The heartbeat is **complementary** (keeps `WatchdogSec` fed during a slow tick) and does **not** implement drain. Land order: rebase this work on top of the heartbeat, or coordinate a single owner for `main.rs`/`watchdog.rs`. The interruptible-sleep change must respect the heartbeat thread's own `AtomicBool`.

### 3.6 Tests
- Unit: drain leaves container-backed regs, deletes container-less regs, releases empty-id reservations — drive via `TEST_MANAGED_CONTAINERS` (`docker_backend.rs:1141`), injected `slot_assignments`, and a fake `remove_runner`.
- Unit: `sleep_interruptibly` returns early when flag set.
- Unit: `remove_runner_until` bails before a sleep that crosses the deadline (mirror `list_runners_until` tests).
- Integration (chaos canary in §5 is the end-to-end proof): SIGTERM mid-spawn ⇒ zero orphaned registrations after restart.

---

## 4. Feature 2 — single-writer deploy lock + `ezgha deploy` (bead k5yk, P1)

**Goal:** a flock-based lock so a concurrent cargo-install / systemctl-restart from another agent session fails loudly with the lock owner's session id; a `deploy` subcommand that encapsulates detached-worktree build → Gate-0 checks → single restart → post-restart version verify.

### 4.1 The lock
- Generalize `acquire_serve_lock` (`main.rs:1003-1041`) into `acquire_lock(cfg, "deploy.lock")` returning the same `ServeLock` guard (auto-release on fd close/process death). Same `libc::flock(LOCK_EX|LOCK_NB)` — zero new crates.
- **Owner identity:** after acquiring, write `session_id\npid\nunix_ts\nhostname` into the lock file body (the current pattern opens with `truncate(false)` and writes nothing — `main.rs:1017`). A blocked deployer, on `WouldBlock`, **reads the file** and reports: `deploy refused — lock held by session <id> (pid <n>, host <h>, since <ts>)`. Session id comes from the agent env (e.g. `$CLAUDE_SESSION_ID` / a `--session-id` flag); fall back to pid if unset.
- Scope note: this is a **deploy-time** lock, distinct from the runtime `serve.lock`. The daemon under deploy keeps its own `serve.lock`; `ezgha deploy` restarts it.

### 4.2 `ezgha deploy` subcommand (new `Commands::Deploy`, dispatch after `main.rs:925`)
Ordered steps, each fail-loud, all under the deploy lock:
1. **Acquire deploy lock** (else exit non-zero with owner id).
2. **Build in a detached worktree** (never the shared checkout — memory: 2 shared-checkout collisions). Use `std::process::Command` (`cargo build`/`cargo install --path .` from the worktree). Reuse `run_restart_command_with_timeout` (`main.rs:333`) for timeouts.
3. **Gate-0 preconditions** (block restart if unsafe):
   - `load_1min < 12` — **new code**: `libc::getloadavg` (libc already a dep) or read `/proc/loadavg`. No load-avg reader exists anywhere today (verified).
   - `containers >= count` (or `>= 12` floor) — reuse `managed_containers()` + `current_prefix_containers().len()` (`docker_backend.rs:1145/1173`).
   - Honor the CLAUDE.md **draining-fleet exception**: low load + shrinking container count + live in-flight child ⇒ restart *is* the remediation. (Encode as an override flag `--force-drain` with an explicit log line.)
4. **Single restart** — `systemctl --user restart ezgha.service` (Linux) / `launchctl kickstart -k` (macOS). Exactly one, never stacked.
5. **Post-restart version verify** — compare `ezgha --version` embedded SHA (`CARGO_PKG_VERSION-GIT_SHA`, `main.rs:25`) against `git rev-parse --short HEAD` (this is Gate 0 of `verify-exit-criteria.sh:143-173`). Fail loud on mismatch.

### 4.3 Non-goals / guardrails
- `ezgha deploy` does **not** replace the single-writer human discipline in CLAUDE.md §"After any commit" — it *enforces* it in-binary so it survives session death. Dispatched sub-agents still must not invoke it (only the session deploy-owner runs deploy steps).
- Does not auto-run `verify-exit-criteria.sh` (that dispatches a live canary and can auto-start units); leave that to the operator, or gate behind `--verify`.

### 4.4 Tests
- Lock contention: second `acquire_lock` gets `WouldBlock` and the reported message contains the first owner's session id.
- Gate-0: refuses restart when a fake loadavg > 12 or container count < floor; proceeds otherwise.
- Version-verify mismatch ⇒ non-zero exit.

---

## 5. Feature 3 — chaos / failure-injection canary (bead 29v1, P1)

**Goal:** a self-test mode that (a) kills a runner container, (b) kills the daemon mid-spawn, (c) simulates GitHub API truncation, and asserts the self-heal SLO — **fleet back to configured count within 3 serve ticks, zero orphaned registrations afterward** — keeping today's fixes fixed.

### 5.1 Shape
- New `Commands::SelfTest`/`Chaos` variant (template: `CanaryOnce` arm `main.rs:900-924` — load config, run, print JSON, `bail!` on assertion failure). Off by default; opt-in `[chaos].enabled` + explicit CLI invocation.
- **Orthogonal to the workflow canary** — new `ChaosResult` struct, `[chaos]` config section. May reuse the `append_history` JSONL helper (`canary.rs:347`) and `alert_canary` pattern (`canary.rs:363`) — no new sink.
- Precondition gate (Self-Outage Principle): refuse to run unless `load_1min < 12` and `containers >= count` (same Gate-0 reader as §4.3). Kills exactly one slot per scenario.

### 5.2 Three scenarios + assertions (all primitives already exist)
| Scenario | Injection | Assertion (poll every tick up to 3× `serve_tick()`) |
|---|---|---|
| Container kill | `docker rm -f <one current-prefix container>` | `current_prefix_containers().len()` (`docker_backend.rs:1173`) returns to `cfg.runner.count`; `offline_*_missing_container_*` classifiers (`docker_backend.rs:671/730`) return empty |
| Daemon-kill mid-spawn | `kill` the daemon while a JIT reg is in the orphan window (§0); restart | after restart: `list_runners` (`github.rs:915`) shows **zero** prefix-matching orphans (online-never / container-less); slot file has no dangling assigned-without-container row |
| API truncation | Feed `list_runners` a well-formed-but-short page set | `release_stale_slots` **fails closed** (reaps nothing, no mass false-reclaim) — asserts `docker_backend.rs:355-376` behavior holds; fleet count unchanged |

- SLO: "back to N/N within 3 ticks" = poll `current_prefix_containers().len()` for up to `3 * cfg.runner.serve_tick()`. "Zero orphaned registrations" = the orphan classifiers + a `list_runners` cross-check return empty.

### 5.3 Injection mechanism — decision needed
The existing injection seams (`TEST_MANAGED_CONTAINERS`, `TEST_DOCKER_BIN`, `TEST_START_ONE_NAMES`, `TEST_RELEASE_STALE_SLOTS_RESULT`, injected `generate_jitconfig`/`starter` closures) are `#[cfg(test)]`-only (`docker_backend.rs:31-47`). A **runtime** chaos canary needs either:
- **(A)** real injection against the live fleet (`docker rm -f` a real container, `kill` the real daemon) — highest fidelity, matches the bead's intent, but must run on a canary/reserved slot to bound blast radius; **or**
- **(B)** promote a minimal subset of the test seams to a runtime-gated `#[cfg(feature="chaos")]` or env-gated path so truncation/mid-spawn can be simulated without a real kill.

**Recommendation:** container-kill and truncation via **(A)** on a single reserved slot (real `docker rm -f`, real short-list via a wrapper `TEST_DOCKER_BIN`-style shim that ezgha already supports); daemon-kill-mid-spawn is inherently a real `kill` orchestrated by the canary as a child/sibling process. Decide before implementation — this is the main open design question.

### 5.4 Where it runs
- Nightly is the bead's framing. Given it kills a container, run it against the **reserved canary capacity** (memory: `ezgha-saturation-nextsteps` — healthy-runner proof needs reserved canary capacity), never a slot that could be executing a real job. Assert on `docker top` `Runner.Worker` truth, not API counts (CLAUDE.md fleet standard).

---

## 6. Sequencing & coordination

1. **30p first** (P0, gates watchdog-timer re-enablement per `uh2`). It also produces the `remove_runner_until` primitive and the interruptible-sleep seam that 29v1's assertions lean on.
2. **k5yk second** — the deploy lock makes landing 30p (which requires a unit reinstall + restart) safe against concurrent sessions.
3. **29v1 last** — it is the executable proof that 30p (zero orphans on restart) and the reaper hold under injection.

**File-ownership claims before dispatching coders** (memory: 3 collisions/day, one 2-min outage): `main.rs` and `watchdog.rs` overlap sibling `codex/hardening-bxy-fl0`; `docker_backend.rs` overlaps several sidekick worktrees (`wt-oau`, `wt-qbl`, `wt-pr33`). Claim these, rebase on `hardening-bxy-fl0`'s heartbeat, and deploy only from a detached worktree.

## 7. Open questions (decide before coding)
1. Chaos injection **(A) real vs (B) gated-seams** (§5.3) — recommend A on reserved capacity.
2. `KillMode=mixed` vs default `control-group` (§3.4) — does killing child `gh`/`docker` clients mid-drain matter? (docker-side containers survive client death, so default is likely fine.)
3. Session-id source for the deploy lock (§4.1) — `$CLAUDE_SESSION_ID` env vs a required `--session-id` flag.
4. Should `ezgha deploy` own the unit reinstall (`install-service`) needed for the new `TimeoutStopSec`, or is that a one-time manual step?
