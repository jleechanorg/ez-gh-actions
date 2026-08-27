# Borg Failure Ladder Implementation Plan

> **Execution rule:** implement this plan with disjoint parallel writers, tests first, and no live lifecycle or pressure testing. Static/code completion does not make the live ironclad goal pass.

**Goal:** Make runner failures collapse inward—job, then one container/slot, then fleet admission, then the Colima VM—while runner load, PSI handling, and watchdog repair have no path that requests a physical-host reboot.

**Architecture:** `ezgha` owns runner admission and per-slot recovery. A persistent circuit ledger prevents a repeatedly failing slot from hot-looping and pauses all new admissions when failures are systemic. The existing root-owned pressure repair script remains the only component allowed to shed every runner and stop Colima; the Rust daemon retains only its existing bounded backend-start recovery when Docker is genuinely unreachable and must never stop the VM or operate on the host. systemd cgroups bound QEMU and guest runners. Kernel boot, kdump, watchdog deployment, Colima profile changes, and restoring the live fleet to ten Linux runners remain explicit operator actions.

**Tech stack:** Rust, TOML state/configuration, shell, systemd user units, Docker/Colima, watchdog(8).

## Non-negotiable rulings

- Capacity contract remains 10 Linux plus 6 Mac runners. The temporary live count of 5 is a known ironclad failure, not a new target.
- Preserve the measured QEMU envelope (`MemoryHigh=34G`, `MemoryMax=38G`, `MemorySwapMax=2G`, `CPUQuota=1600%`). A 30G hard limit is below the recorded 31.8 GiB normal peak and is unsafe without a separately approved Colima resizing exercise.
- Do not infer infrastructure health from GitHub job conclusions. Only local start/runtime failures and host/guest pressure signals drive the failure ladder.
- The Rust daemon may pause admission, quarantine slots, and make its existing bounded backend-start request when Docker is genuinely unreachable. It may not stop Colima, reboot, shut down, panic, or invoke watchdog repair. Admission guards and runner-start failures must not be misclassified as backend-unreachable errors.
- The root watchdog repair path is ordered: close admission, remove managed containers, reclaim, then bounded Colima stop if pressure remains. It must always return success to watchdog so it cannot vote for a host reboot.
- Whole-home 9p remains an explicit open isolation gap. The repository has no authoritative Lima mount configuration surface, so this change is deferred rather than guessed.
- `nohz=off`, crashkernel deduplication, kdump arming, watchdog deployment/reload, Colima lifecycle, service restarts, and fleet restoration are operator-gated live work.
- No test in this implementation session may intentionally create load or memory/disk pressure, kill runners, stop/restart Colima, reload/restart services, trigger panic/OOM, or reboot the host.
- Work stays in the current dirty checkout because the approved host-survival WIP is not portable to a clean worktree. Writers own disjoint files and must not revert unrelated changes.

## Failure ladder

| Layer | Trigger | Automatic response | Recovery |
|---|---|---|---|
| Job | Workflow/process failure inside a runner | Existing container limits terminate only the offending process/container | Ephemeral runner replacement |
| Slot/container | Repeated local start failures for one slot within a bounded window | Persistently open that slot's circuit; continue servicing other slots | Cooldown expires or a successful start resets the slot |
| Fleet admission | Several distinct slot circuits open concurrently | Pause all new runner starts; existing jobs keep running; alert once per state transition | Cooldown expires and eligible slots are retried gradually |
| VM | Sustained host PSI after admission is closed and managed containers are shed | Root-owned repair script requests bounded Colima stop | Operator/system service may later restore VM and fleet |
| Host | Runner load, PSI, or watchdog repair | No reboot vote or host lifecycle action exists | Host stays available for diagnosis and recovery |
| Kernel fault | Oops/panic unrelated to runner pressure | `panic=10` plus armed kdump after operator reboot | vmcore, then reboot; tracked separately from runner-load survival |

## Task 1: Consolidate the contract and remove overclaims

**Files:**

- Modify: `README.md`
- Modify: `DESIGN.md`
- Modify: `roadmap/host-uncrashable-goal-ironclad-2026-08-26.md`
- Test: `tests/host_control_artifacts_test.sh`

1. Add fixture/static assertions that the docs distinguish cgroup containment from a literal host-survival proof.
2. Replace claims that one container "cannot" exhaust the host with precise statements about finite container, guest aggregate, and QEMU boundaries.
3. Add the failure-ladder ownership table and keep the overall live verdict FAIL until all externally anchored checks pass together.
4. Run only static shell checks for this task.

## Task 2: Make watchdog no-reboot proof injectable and mandatory

**Files:**

- Modify: `scripts/host/assert-no-host-reboot-vote.sh`
- Modify: `docs/verify-exit-criteria.sh`
- Modify: `tests/assert_no_host_reboot_vote_test.sh`
- Modify: `tests/host_control_artifacts_test.sh`

1. First add fixtures for missing, nonzero, duplicate, and zero `repair-maximum` values.
2. Allow the live watchdog config path to be injected for fixture tests while retaining `/etc/watchdog.conf` as the live default.
3. Add a Linux host-survival verifier subcheck that invokes the assertion in live mode. It must only read files; it must never reload watchdog.
4. Keep deployment in `apply-watchdog-no-reboot-vote.sh` operator-only and dry-run-testable.

## Task 3: Add a persistent generic failure circuit

**Files:**

- Create: `src/failure_ladder.rs`
- Modify: `src/config.rs`
- Modify: `src/main.rs`
- Modify: `src/docker_backend.rs`

1. Write unit tests for default policy, threshold opening, rolling-window expiry, successful-start reset, slot cooldown, fleet pause after distinct slot circuits open, persisted round trip, and fail-closed corrupt state handling.
2. Add `[failure_ladder]` configuration with conservative defaults and validation:
   - 3 failed starts per slot within 10 minutes;
   - 15-minute slot cooldown;
   - 3 simultaneously open distinct slots trigger fleet admission pause;
   - 10-minute fleet cooldown.
3. Record only local container/JIT start failures. Do not consume GitHub job conclusions.
4. Exclude open slots from allocation, persist transitions atomically, reset a slot on successful start, and return an explicit admission-paused outcome rather than an error that would trigger backend restart.
5. Keep existing `Locked422` quarantine semantics intact; generic circuits are a separate ledger and policy.
6. Alert on state transitions, not every reconcile tick. Never call VM or host lifecycle commands.

## Task 4: Reconcile the finite host/VM envelope

**Files:**

- Modify only if inconsistent: `systemd/app-lima-vm.slice`
- Modify only if inconsistent: `systemd/lima-vm@colima.service.d/99-memory-ceiling.conf`
- Modify only if inconsistent: `systemd/lima-vm-cpu-ceiling.service`
- Modify: `scripts/host/assert-qemu-cpu-ceiling.sh`
- Modify: `tests/assert_qemu_cpu_ceiling_test.sh`
- Modify: `tests/host_control_artifacts_test.sh`

1. Add fixtures proving the assertion resolves and checks the QEMU process's actual leaf cgroup.
2. Require finite CPU, memory, swap, and task bounds with the tracked 34G/38G/2G/4096/1600% contract.
3. Do not lower the envelope or edit the live Colima profile in this session.
4. Verify the three tracked systemd representations remain equal using static tests.

## Task 5: Make every reconcile outcome fail loud

**Files:**

- Modify: `src/main.rs`
- Modify: `config/README.md`

1. Keep the structured `EnsureCountOutcome` through both `start` and `serve`; never collapse a pause, partial start, readiness error, or remaining shortage into an empty started list.
2. Print "already at capacity" only when the local recount proves zero remaining shortage. Return a nonzero result for admission pauses, no-progress shortages, start failures, and incomplete readiness evidence.
3. Advance the backend failure alert streak for real start failures even when the same outcome closes admission; preserve (rather than reset) an existing streak during a deliberate pause with no new failure.
4. Credit the dead-man clock only when an ensure cycle has no pause, no start failure, no readiness error, and no remaining shortage.
5. Document that restoring the temporary live count of 5 to the 10-runner contract must not use `install.sh`, which also rebuilds the image and restarts the service. Inspect the persistent failure ledger and use a minimal operator-authorized deployment sequence instead.

## Task 6: Verify safely and review independently

**Permitted checks:**

- Rust unit tests targeting configuration, the failure ladder, and injected starter behavior.
- `cargo fmt --check`, `cargo check`, and narrowly scoped `cargo test` commands that do not invoke Docker or systemd.
- Shell syntax, fixture/stub tests, dry-run apply scripts, and `git diff --check`.
- Read-only assertions against current cgroup files.

**Forbidden checks:**

- Full exit criteria if it mutates or restarts anything.
- Docker runner creation/removal, `doctor-runner` workload proof, fleet bursts, disk filling, memory pressure, PSI injection, OOM, panic/kdump trigger, watchdog reload, service restart, Colima stop/start, reboot, or `cargo install`.

1. Run the permitted focused checks and capture exact results.
2. Dispatch an inspection-only semantic review and a separate focused verifier.
3. Fix findings and repeat safe checks until code/static criteria are green.
4. Leave the ironclad goal FAIL with an operator checklist for live watchdog deployment, reboot into `nohz=off` with one armed crashkernel, 9p resolution, restore to 10 Linux, and later controlled survival proof.

## Completion boundary

Implementation is code-complete when the persistent admission circuits, watchdog no-reboot verifier, finite-envelope assertions, documentation, and safe tests agree. The Borg goal itself remains live-unproven until the operator-gated criteria pass simultaneously. Do not label the host "uncrashable" and do not close the goal issue from repository-only evidence.
