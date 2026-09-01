# Runner Crash Containment Release 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep exactly ten Linux GitHub Actions runners while preventing their aggregate resource use from exhausting or pressure-killing the Ubuntu desktop and operator session.

**Architecture:** Preserve the existing HostDocker backend and per-container limits. Add a fixed finite host `actions.slice`, finite user workload slices, neutral broad desktop OOM boundaries, a fail-closed Rust admission check before runner mutations, post-create PID ancestry verification, and one tracked activation script that cannot restart an uncontained fleet.

**Tech Stack:** Rust, Bash, Docker 29, systemd cgroup v2, systemd-oomd, TOML.

**Spec:** `docs/superpowers/specs/2026-08-31-runner-crash-containment-design.md`

## Global Constraints

- Linux runner count remains exactly 10; Mac behavior and the six-runner Mac fleet do not change.
- Host Docker remains the backend. Release 1 must not start Colima, Lima, or another VM and must not restart Docker.
- Fixed-profile startup/recovery performs no backend lifecycle action; Docker failure alerts and retries passively.
- `DOCKER_HOST` and `DOCKER_CONTEXT` are unset, the resolved Linux Docker endpoint is exactly `unix:///var/run/docker.sock`, and every Linux HostDocker CLI call is explicitly bound to that socket.
- DockerSysbox uses the same canonical host endpoint contract; OS detection and selector rejection precede the first Docker command, and pre-pull occurs only after containment admission.
- The Linux example and active deployment use exactly 2500 MiB per runner.
- `actions.slice` is exactly `MemoryHigh=26G`, `MemoryMax=28G`, `MemorySwapMax=0`, `TasksMax=6000`, `CPUQuota=2000%`, and `IOWeight=25`.
- `agents.slice` is exactly `MemoryHigh=18G`, `MemoryMax=20G`, `MemorySwapMax=2G`, and `TasksMax=8192`.
- The agent limit is justified by fresh 8.10-GiB current and 17.14-GiB historical-peak evidence; activation requires current use below 18G before applying it.
- On the measured 32-CPU host, actions `CPUQuota=2000%` equals the ten per-container CPU sums and `TasksMax=6000` exceeds their 5120-PID sum; these are aggregate drift/overhead bounds, not newly tighter per-job limits.
- `automation.slice` is exactly `MemoryHigh=4G`, `MemoryMax=6G`, `MemorySwapMax=1G`, and `TasksMax=4096`.
- All three workload slices set `ManagedOOMMemoryPressure=auto` and `ManagedOOMSwap=auto`.
- System `-.slice`, `user.slice`, `user-.slice`, `user@.service` and user-manager `app.slice`, `session.slice` set both managed-OOM policies to `auto`.
- The `user@.service` drop-in also sets `ManagedOOMPreference=none` and `OOMScoreAdjust=0`.
- Remove the runner OOM exemption and the supported agent-launch opt-out. Do not move or terminate existing interactive agent sessions during activation.
- A Linux HostDocker create attempt fails before slot, JIT, workspace, removal, or Docker mutation when containment is not exact.
- After create, actual container PID ancestry must be below `/actions.slice`; mismatch compensates only the just-created transition.
- Activation is single-writer, never stops a runner container, and leaves `ezgha.service` inactive on any uncontained result.
- Compatible Linux installation requires noninteractive authorization for the fixed enumerated system-manager commands; a missing authorization is a distinct pre-mutation failure, not an interactive sudo prompt.
- No Release 2 broker, receipt framework, image pipeline, scheduler, queue/reaper refactor, or security feature is implemented here.

## File Map

**Task 1: portable policy artifacts**

- Create `systemd/host/actions.slice`.
- Create `systemd/host/-.slice.d/99-ezgha-containment.conf`.
- Create `systemd/host/user.slice.d/99-ezgha-containment.conf`.
- Create `systemd/host/user-.slice.d/99-ezgha-containment.conf`.
- Create `systemd/host/user@.service.d/99-ezgha-containment.conf`.
- Create `systemd/user/app.slice.d/99-ezgha-containment.conf`.
- Create `systemd/user/session.slice.d/99-ezgha-containment.conf`.
- Modify `systemd/agents.slice` and `systemd/automation.slice`.
- Modify `config/config.toml.linux.example` to use 2500 MiB, the exact HostDocker profile, and dispatch-only canary repo/workflow settings against the main fleet labels.
- Delete `systemd/ezgha.service.d/10-oomd-omit.conf`.
- Delete `systemd/psi-oom-watcher.service`, `systemd/psi-oom-watcher.timer`, and `scripts/host/psi-oom-watcher.sh`.
- Modify `scripts/host/agent-scoped-launch.sh` and `scripts/host/agent-cli-scoped.sh`.
- Modify focused artifact tests that currently require the exemption or opt-out.
- Create `tests/host_crash_containment_release1_artifacts_test.sh`.

**Task 2: runtime admission and ancestry**

- Modify `src/config.rs`, `src/platform.rs`, `src/backend.rs`, `src/docker_backend.rs`, and `src/main.rs`.
- Modify `src/service.rs` to remove Linux HostDocker dependence on VM units and unset `DOCKER_HOST`/`DOCKER_CONTEXT` in generated Linux HostDocker units.
- Add focused Rust unit tests in the owning modules.

**Task 3: read-only live assertion**

- Create `scripts/host/assert-host-containment-release1.sh`.
- Create `tests/assert_host_containment_release1_test.sh`.

**Task 4: atomic activation**

- Create `scripts/host/apply-host-containment-release1.sh`.
- Create `tests/apply_host_containment_release1_test.sh`.

**Task 5: operator surfaces and exit gate**

- Modify `install.sh`, `doctor-runner`, `docs/verify-exit-criteria.sh`, `README.md`, `config/README.md`, `CLAUDE.md`, and `AGENTS.md`.
- Delete `config/config.toml.linux-canary.example`; configure canary dispatch in the main Linux example instead.
- Modify `tests/install_watchdog_gate_test.sh`, `tests/install_uninstall_aux_units_test.sh`, and focused installer/doctor/exit-gate tests.

**Task 6: deterministic organic outcome window**

- Modify `scripts/job_outcome_monitor.py`.
- Modify `tests/job_outcome_monitor_test.py`.

## Parallel Execution Map

After this plan and spec have an approved exact SHA:

- Lane A owns Task 1 only.
- Lane B owns Task 2 only.
- Lane C owns Task 3 only.
- The primary agent owns independent Task 6 while A-C run.
- Integrate green Tasks 1, 2, and 3, then start Task 4 from that integrated base because activation consumes their policy paths, maintenance-intent behavior, and assertion contract.
- Integrate green Task 4, then start Task 5 from the base containing Tasks 1-4 because its installer fixtures stage and execute the actual Task 4 artifact.
- Task 6 may integrate at any point before Task 7 because its two existing files are untouched by Tasks 1-5.
- Integration, live activation, and production verification are serialized under the primary deploy owner.

Tasks 1, 2, 3, and 6 use isolated worktrees pinned to the approved SHA. Dependent Task 4 uses an isolated worktree at the integration commit containing green Tasks 1-3; Task 5 uses one at the integration commit containing green Tasks 1-4. No worker may run `cargo install`, restart `ezgha.service`, invoke the live exit gate, modify the Docker daemon, or deploy host files. The primary agent integrates commits in dependency order and is the only live deploy owner.

---

### Task 1: Add The Fixed Host And User Policy Artifacts

**Files:** Task 1 files from the File Map.

**Interfaces:**

- Produces the fixed files that Task 3 reads and Task 4 installs.
- Produces no dynamic profile, environment override, or caller-selected destination.

- [ ] **Step 1: Write failing artifact tests**

Add structural assertions for exact values and paths:

```bash
assert_line systemd/host/actions.slice 'MemoryHigh=26G'
assert_line systemd/host/actions.slice 'MemoryMax=28G'
assert_line systemd/host/actions.slice 'MemorySwapMax=0'
assert_line systemd/host/actions.slice 'TasksMax=6000'
assert_line systemd/host/actions.slice 'CPUQuota=2000%'
assert_line systemd/host/actions.slice 'IOWeight=25'
```

Assert all three workload slices contain both `ManagedOOMMemoryPressure=auto` and `ManagedOOMSwap=auto`. Assert all six boundary drop-ins exist and contain the same pair. Assert `user@.service` also contains the neutral preference and score.

Update legacy tests to reject, rather than require:

```text
systemd/ezgha.service.d/10-oomd-omit.conf
AGENT_SLICE_OPT_OUT
systemd/psi-oom-watcher.service
systemd/psi-oom-watcher.timer
scripts/host/psi-oom-watcher.sh
```

- [ ] **Step 2: Run the tests and confirm the intended failures**

```bash
bash tests/host_crash_containment_release1_artifacts_test.sh
bash tests/host_ops_0725_test.sh
bash tests/host_control_artifacts_test.sh
```

Expected: the new test fails because files are absent; legacy tests fail where they still encode the exemption and opt-out.

- [ ] **Step 3: Add exact units and drop-ins**

Use ordinary `[Slice]` sections for the three slices and `[Slice]` or `[Service]` as required by the target unit type. Do not add thresholds, watchdogs, restart actions, or host-lifecycle directives.

Update the `agents.slice` comment to record the 8.10-GiB current, 17.14-GiB peak, 18G high, and 20G max arithmetic. Remove the stale 7.4-GiB-p95 justification for the superseded 10G/12G values.

The actions slice must contain:

```ini
[Slice]
MemoryHigh=26G
MemoryMax=28G
MemorySwapMax=0
TasksMax=6000
CPUQuota=2000%
IOWeight=25
ManagedOOMMemoryPressure=auto
ManagedOOMSwap=auto
```

- [ ] **Step 4: Remove both escape paths**

Delete the tracked runner OOM exemption and all three legacy PSI-watcher artifacts. Remove all `AGENT_SLICE_OPT_OUT` execution branches and user-facing help from both supported launcher scripts. Preserve normal scoped execution behavior.

- [ ] **Step 5: Validate artifacts**

```bash
bash tests/host_crash_containment_release1_artifacts_test.sh
bash tests/host_ops_0725_test.sh
bash tests/host_control_artifacts_test.sh
systemd-analyze verify systemd/host/actions.slice
```

Expected: all focused tests pass and `systemd-analyze verify` reports no errors.

- [ ] **Step 6: Commit the isolated unit**

```bash
git add systemd scripts/host/agent-scoped-launch.sh scripts/host/agent-cli-scoped.sh tests
git commit -m "feat: add finite host containment policy [codex/gpt-5.6-sol]"
```

---

### Task 2: Fail Closed Before Linux Runner Mutation

**Files:** `src/config.rs`, `src/platform.rs`, `src/backend.rs`, `src/docker_backend.rs`, `src/main.rs`, focused Rust tests, and `src/service.rs` for both Linux HostDocker VM-unit removal and Docker-selector environment clearing.

**Interfaces:**

- Produces `HostContainmentProfile` with the fixed expected values.
- Produces `require_host_containment(&Config) -> anyhow::Result<()>` for the fixed-Linux full reconciliation entry (`ensure_count_outcome`) and its shared create path.
- Produces `require_container_actions_ancestry(container_id: &str) -> anyhow::Result<()>` after Docker start.
- Produces `DockerCommandTarget` with `CanonicalLinuxHost` and existing-platform variants, plus one `docker_command(target: DockerCommandTarget) -> Command` factory for every Rust runtime Docker operation. `CanonicalLinuxHost` clears both selector variables and adds `--host unix:///var/run/docker.sock`; Mac and explicit VM variants preserve their existing endpoint behavior. Task 4's fixed shell-only bootstrap builder is the sole non-Rust exception and has its own exact argv fixture.
- Produces a fixed maintenance-intent check used by every `start`, `serve`, and `stop` mutation path before and after `serve.lock` acquisition.
- Produces a stable containment-admission failure event through the existing alert/journal API; repeated guard failure is visible without a separate monitor.
- Produces fixed-profile backend-recovery suppression: no `lima-vm@colima.service`, `limactl`, Colima, or Docker lifecycle command from startup or retry.
- Produces nonmutating `ezgha render-release1-service` and `ezgha render-release1-alert-service`. They write the fixed Linux main and `ezgha-alert@.service` unit text to stdout; the main unit uses `ExecStart=%h/.local/libexec/ezgha/release1/bin/ezgha serve --config %h/.config/ezgha/config.toml`, neither command has a Lima dependency or enable/start/reload side effect, Task 5 stages their outputs at fixed bundle paths, and Task 4 installs/enables them only inside activation.
- Mac and explicit VM-Docker paths do not invoke these guards.

- [ ] **Step 1: Write unit tests for profile selection**

Cover these cases:

```text
Linux + HostDocker + count 10 + 2500 MiB + unix:///var/run/docker.sock => Release 1 profile required
Linux + wrong count, memory, parent, or endpoint => error
Mac => no Release 1 profile
explicit VM-Docker => existing behavior
Linux canary-once with verifier config => dispatch-only, no Docker command
Linux start/serve with count 1 or other non-profile config => fail before Docker
```

Confirm the wrong-count and wrong-parent errors name the exact required values.

Apply this profile check only to Linux runner-mutating `start`/`serve` and their shared create path. `canary-once`, status, doctor, and other nonmutating config consumers do not fail merely because a verifier config has a different count; they must remain Docker-free where currently expected.

- [ ] **Step 2: Write unit tests for effective cgroup parsing**

Feed temporary cgroup trees with exact values, `max`, one wrong value at a time, missing files, and unreadable files. The parser must compare normalized kernel values to the fixed byte/quota values and reject every mismatch.

- [ ] **Step 3: Write unit tests for Docker and oomd probes**

Use the module's existing command-test seam to cover:

```text
unset Docker env + default unix:///var/run/docker.sock + CgroupVersion=2 + CgroupDriver=systemd => pass
non-empty DOCKER_HOST or DOCKER_CONTEXT => fail before mutation
driver=cgroupfs or version=1 => fail
all workload policies auto and broad boundaries auto => pass
user@UID.service kill or non-neutral => fail
```

Inventory every Rust production Docker call in `src/platform.rs`, `src/main.rs`, and `src/docker_backend.rs`. Add a structural test that rejects direct production `Command::new("docker")` outside the single factory, including reachability, platform detection, DockerSysbox classification, probe-image pre-pull, capacity probes, container peak RSS, inventory, inspect/top, cleanup, and create paths. The structural scope is explicitly Rust runtime code; Task 4 separately tests its one exact bootstrap build argv.

- [ ] **Step 4: Run the focused Rust tests and confirm failure**

```bash
cargo test host_containment -- --nocapture
cargo test configured_cgroup_parent_is_emitted_on_runner_start -- --nocapture
```

Expected: new tests fail because the admission and ancestry functions do not exist.

- [ ] **Step 5: Implement the fixed admission profile and probes**

Read only canonical system paths and command output. Do not accept path arguments or environment-variable overrides in production code. Split OS detection from Docker probing: on Linux reject selectors, choose `CanonicalLinuxHost`, and use that target for platform/backend discovery and every later Docker operation, including DockerSysbox. Move `prepull_probe_image` after `require_host_containment`; no pull or reachability probe may use an ambient endpoint. Update generated Linux HostDocker units with `UnsetEnvironment=DOCKER_HOST DOCKER_CONTEXT`, with a focused service-unit test; do not change Mac or explicit VM units. Return contextual errors without changing the host.

- [ ] **Step 6: Place the guard before every reconciliation or create-side effect**

At the top of `ensure_count_outcome`, after fixed-profile resolution and before `release_stale_slots`, `managed_containers`, peak-RSS polling, slot/quarantine reads or writes, GitHub deregistration/cancellation, cleanup, JIT registration, old-container removal, workspace changes, or runner Docker execution, call `require_host_containment`. On failure return the paused/fail-closed outcome and emit the stable cooldown-governed alert; execute no reconciliation mutation. The only Docker calls before admission are canonical-endpoint read-only topology/containment probes. Preserve Mac and explicit-VM reconciliation ordering unchanged. Keep a second guard at the shared Linux HostDocker/DockerSysbox create entry as defense in depth and retain `--cgroup-parent actions.slice`.

Add command/API/file recorders proving a failed fixed-Linux guard occurs before `release_stale_slots` and records no GitHub runner removal/cancel, slot or quarantine mutation, peak-RSS cleanup, `docker rm`/`docker run`, JIT request, or workspace mutation. Add positive regression tests that Mac and explicit-VM profiles retain their existing reconciliation ordering and behavior.

Add serve-order tests proving selector rejection happens before platform Docker probing and the probe-image pull happens after a successful containment verdict. Assert every recorded Linux Docker argv begins with `docker --host unix:///var/run/docker.sock`, while Mac/explicit VM tests retain their existing argv.

Add a focused test that a failed containment verdict emits the stable alert event once per existing cooldown semantics and never credits backend recovery or admission success.

Change `backend_restart_can_help`/`maybe_restart_backend` and startup wait policy to accept the resolved profile. For fixed Linux HostDocker/DockerSysbox they return passive-retry/no-action without calling `backend_restart_commands`; generated service units omit Lima `Wants=`/`After=`. Add regression tests for initial unreachability and repeated serve failures that record zero VM/backend lifecycle commands. Preserve existing Mac and explicit VM recovery tests.

Add service-render tests proving both Release 1 render commands are stdout-only, the main unit contains the exact stable bundle binary/config paths and references the rendered alert template, neither output has a Lima dependency or Docker selectors, and neither command performs a `systemctl` operation. Existing `install-service` behavior for Mac and explicit VM profiles remains unchanged.

- [ ] **Step 7: Verify the created PID ancestry**

After `docker run`, inspect the container PID and `/proc/<pid>/cgroup`. Require a cgroup path equal to `/actions.slice/...` or beginning `/actions.slice/`. On mismatch, invoke the existing compensation path for only the just-created container/JIT transition and return an error.

- [ ] **Step 8: Run focused and full Rust checks**

Before the checks, add tests that a live maintenance intent rejects `start`, `serve`, and `stop` before mutation, including the narrow race where intent appears while a command waits on `serve.lock`. A stale or malformed intent also fails closed with an operator-recovery message; runtime code never deletes it.

```bash
cargo fmt --all -- --check
cargo test host_containment -- --nocapture
cargo test configured_cgroup_parent_is_emitted_on_runner_start -- --nocapture
cargo test
cargo clippy --all-targets --all-features -- -D warnings
```

Expected: all pass.

- [ ] **Step 9: Commit the isolated unit**

```bash
git add src
git commit -m "feat: gate Linux runner creation on host containment [codex/gpt-5.6-sol]"
```

---

### Task 3: Add A Hermetic Read-Only Containment Assertion

**Files:** `scripts/host/assert-host-containment-release1.sh`, `tests/assert_host_containment_release1_test.sh`.

**Interfaces:**

- `assert-host-containment-release1.sh` accepts only `--root <fixture-root>` for hermetic tests; production default is `/`.
- Exit 0 means every fixed policy, Docker mode, removal condition, container count, and ancestry assertion passed.
- Nonzero output prints one stable `FAIL:` line per mismatch and performs no mutation.

- [ ] **Step 1: Build a fixture-driven failing test**

Stub `docker`, `systemctl`, and `systemd-run` through a fixture `PATH`. Cover exact pass, one wrong slice value, `max`, wrong Docker driver, each of `cpu`, `io`, `memory`, and `pids` missing independently from root `cgroup.controllers`, active exemption, present unlimited override, nine containers, eleven containers, and one wrong PID ancestry. Every missing-controller case emits a stable `FAIL:` and records no mutation.

Also cover a failed deploy-user manager connectivity probe, an active/enabled/installed PSI watcher, and a `kill` policy on each relevant ancestor boundary independently.

Cover an eleventh `ezgha=managed` container with a different prefix and a secondary `ezgha serve`/`ezgha-canary.service`; each must fail even when the ten expected names are present.

- [ ] **Step 2: Run the test and confirm failure**

```bash
bash tests/assert_host_containment_release1_test.sh
```

Expected: failure because the assertion script is absent.

- [ ] **Step 3: Implement read-only checks**

The script must use `set -euo pipefail`, canonical defaults, stable diagnostics, and no `sudo`. It verifies:

```text
bounded systemctl --user show-environment connectivity
Docker systemd/cgroup-v2
root cgroup.controllers contains cpu, io, memory, and pids
exact three-slice values
exact six broad-boundary policies
neutral user@UID.service
no installed ezgha OOM exemption
no installed agents unlimited override
no installed/active/enabled psi-oom-watcher artifact
exactly ten managed ez-runner-c-* containers when --require-fleet is supplied
no other ezgha=managed container or secondary Linux supervisor
actual PID ancestry for each required container
```

The default pre-policy mode may omit live fleet count so Task 4 can assert the boundary before refill. `--require-fleet` adds the ten-container checks.

- [ ] **Step 4: Prove read-only behavior**

The fixture test records every stubbed command and fails if it sees `start`, `stop`, `restart`, `set-property`, `daemon-reload`, `docker rm`, or `docker run`.

- [ ] **Step 5: Run tests and shell analysis**

```bash
bash -n scripts/host/assert-host-containment-release1.sh
bash tests/assert_host_containment_release1_test.sh
shellcheck scripts/host/assert-host-containment-release1.sh
```

- [ ] **Step 6: Commit the isolated unit**

```bash
git add scripts/host/assert-host-containment-release1.sh tests/assert_host_containment_release1_test.sh
git commit -m "feat: assert live host containment read only [codex/gpt-5.6-sol]"
```

---

### Task 4: Add The Single-Writer Activation Script

**Files:** `scripts/host/apply-host-containment-release1.sh`, `tests/apply_host_containment_release1_test.sh`.

**Interfaces:**

- Consumes Task 1's fixed artifact paths and Task 3's assertion command.
- Accepts no unit-path, profile, count, service, or Docker-socket override in production.
- `--fixture-root` and stub `PATH` exist only when `EZGHA_TEST_MODE=1` for hermetic tests.
- The first operation is exact `uname -s` comparison with `Linux`; non-Linux exits before any other access or mutation.
- The entrypoint runs as the deploy user and rejects effective UID 0 before mutation; only enumerated fixed system operations use internal `sudo -n`.
- Production activation runs only from the fixed `$HOME/.local/libexec/ezgha/release1` bundle staged by Task 5. The bundle preserves the tracked policy/assertion tree, rendered `systemd/ezgha.service`, explicit Linux auxiliary closure, `Dockerfile.runner`, and `docker/tar-workspace-wrapper.sh`. `build_release1_runner_image()` takes no arguments, derives its Dockerfile/context from that canonical bundle, and is the sole shell bootstrap-build interface.
- Success means finite policy is active, activation itself issued no lifecycle mutation against pre-existing runners, and the fleet converges to ten contained slot names; naturally departed ephemeral IDs may be refilled after maintenance release.
- Any failure before maintenance release that cannot prove containment leaves `ezgha.service` inactive; after release, proof failure keeps the already-contained reconciler running and fails the deployment non-destructively.

- [ ] **Step 1: Write state-machine fixture tests**

Test command order and final state for:

```text
clean success
zero-container bootstrap success
zero-container bootstrap with absent actions.slice
bootstrap with absent agents.slice and automation.slice cgroups
each missing cpu/io/memory/pids root controller
watcher already absent
watcher present but inactive/disabled
watcher active/enabled and file-absent loaded drift
bootstrap contained image build after actions commit point
migration preserves existing image without rebuild
migration with one or several snapshotted ephemeral containers departing while locked
non-Linux invocation
root invocation
missing exact sudo authorization
unreachable deploy-user manager
preflight failure
missing, malformed, or SHA-mismatched rendered service/auxiliary bundle file
live maintenance intent
stale or malformed maintenance intent
snapshot failure
runner inventory changes during lock acquisition
file install fails
daemon reload fails
actions.slice runtime property fails
policy assertion fails
service start fails
post-start assertion fails
post-release arbitrary JIT ID churn with ten contained slots
post-release fleet convergence timeout
```

For every failure after reconciler stop but before maintenance release, assert the final command log does not contain a later uncontained service start. Assert no test command stops, pauses, removes, or recreates a runner container. Permit deregistration only for a registration proven to have no local container. After the actions-boundary commit point, assert recovery never restores it to infinity. Post-release proof failures instead assert the already-contained service remains running and is not restarted.

- [ ] **Step 2: Confirm tests fail before implementation**

```bash
bash tests/apply_host_containment_release1_test.sh
```

- [ ] **Step 3: Implement the Linux gate and immutable preflight**

Run `uname -s` first and require exact `Linux`, then reject effective UID 0. Resolve the fixed deploy UID from real/effective UID equality and its canonical home through `getent passwd`; require `HOME` equality, the user bus at `/run/user/<uid>/bus`, a successful bounded read-only `systemctl --user show-environment`, and the exact canonical release bundle/manifest with required policy/assertion files, rendered `systemd/ezgha.service`, the explicit auxiliary closure, `Dockerfile.runner`, and executable `docker/tar-workspace-wrapper.sh`. Missing, malformed, or SHA-mismatched content fails before intent, service stop, or policy mutation. Require no secondary `ezgha serve` or canary service, at least 8 GiB `MemAvailable`, swap use at most 50%, memory PSI `full avg10 < 1.00`, at least 1 GiB free on the target filesystem, cgroup v2 root `cgroup.controllers` containing `cpu`, `io`, `memory`, and `pids`, unset Docker selector variables, Docker 29-compatible systemd/cgroup-v2 at `unix:///var/run/docker.sock`, exact count 10, 2500-MiB runner memory, and `actions.slice` parent. Migration requires readable `agents.slice/memory.current < 18G`, `automation.slice/memory.current < 4G`, and exactly ten total managed containers with the expected names/ancestry plus `actions.slice/memory.current < 26G`. Bootstrap requires zero managed containers and permits the three workload slice cgroups to be absent/inactive; it records absent user-slice use as zero only in this branch and later starts and verifies them before build/admission. Construct every later elevated argv, pre-authorize each with `sudo -n -l -- <exact argv>`, and on any denial emit stable `SUDOERS_PREREQUISITE_MISSING` and fail before intent/service mutation without prompting.

- [ ] **Step 4: Freeze mutations and snapshot before the reconciler stop**

Acquire the deploy-user activation lock and atomically create the deploy-user maintenance intent with PID and boot ID. Snapshot every target file, prior manager state, auxiliary enablement state, and each managed slot's `{name, container_id, pid, cgroup}` as that user. In migration mode stop only the deploy user's `ezgha.service`; in bootstrap mode require it already inactive. Acquire and hold the deploy-user `serve.lock` for this activation process, then recheck fleet ancestry. Both flocks are process-lifetime exclusion and the kernel releases them on every activation exit; the maintenance intent is the sole durable recovery gate. The Task 2 double-check makes direct `start`, `serve`, and `stop` refuse the maintenance interval before and after taking their own fresh lock. Until maintenance release, the activation command ledger permits only Docker inventory/inspect/event reads and forbids `run`, `stop`, `pause`, `rm`, `kill`, `restart`, and prune. A snapshotted ID that disappears is recorded only as an independent ephemeral lifecycle departure; activation does not claim why it exited. Every surviving ID must retain its name and `/actions.slice` ancestry, and no new managed ID may appear while the reconciler is frozen. Existing graceful service shutdown may clean only proven container-less registrations.

- [ ] **Step 5: Install and commit the finite actions boundary first**

As the deploy user, leave the preflight-verified active config unchanged and install the manifested rendered `systemd/ezgha.service`, `ezgha-alert@.service`, fixed user-manager policy files, and auxiliary closure; never re-render from the checkout. Install the slices, AO drop-ins, agent launchers, future-invocation wrappers, token-refresh/mission-cleanup units and scripts, disabled reaper units/scripts, and fleet-alert units/script without relaunching existing agent or automation processes. Watcher teardown is idempotent: read `LoadState`, `ActiveState`, and `UnitFileState` for both watcher units plus their known paths and timer symlink. If both units are `not-found`/inactive/disabled and all paths are absent, issue no disable/stop command. Otherwise disable the timer only when enabled or active, stop the service only when active, remove the known files, and reload; file-absent but loaded/active drift follows the same teardown. A command's nonzero result is fatal only when the required absent post-state is not achieved. Any residual loaded/active/enabled watcher, file, or symlink retains intent and prevents `ezgha.service` restart. Use separate fixed `sudo -n` commands only to install/remove the enumerated system-manager files, reload the system manager, and apply/query `actions.slice`. Remove only:

```text
<deploy-home>/.config/systemd/user/ezgha.service.d/10-oomd-omit.conf
<deploy-home>/.config/systemd/user/agents.slice.d/99-local-unlimited.conf
<deploy-home>/.config/systemd/user/psi-oom-watcher.service
<deploy-home>/.config/systemd/user/psi-oom-watcher.timer
<deploy-home>/.local/lib/ezgha/host-controls/psi-oom-watcher.sh
```

Reload the system manager and user manager. In bootstrap invoke the pre-authorized exact `sudo -n systemctl start actions.slice` and deploy-user `systemctl --user start agents.slice automation.slice`; migration requires all three already active. Apply the exact properties, verify all effective files including `cpu.max`/`io.weight`, then require agent/automation current use below their highs before runner admission. In migration also verify every surviving snapshotted PID ancestry and account for each recorded departure. This verified point is forward-only: later recovery retains the persistent and runtime finite actions boundary.

- [ ] **Step 6: Apply the remaining policy and prove the unchanged fleet**

Reload the user manager, apply and verify agent, automation, and all six oomd boundary properties. While maintenance intent and `serve.lock` remain held, invoke Task 3 without `--require-fleet`. Migration additionally requires the current managed-ID set to be a subset of the snapshot, every survivor unchanged/contained, every disappearance recorded, and no new ID; bootstrap requires zero managed containers.

For bootstrap only, after the full policy assertion succeeds, call the no-argument `build_release1_runner_image()` function. It executes exactly:

```bash
env -u DOCKER_HOST -u DOCKER_CONTEXT DOCKER_BUILDKIT=0 \
  docker --host unix:///var/run/docker.sock build \
  --cgroup-parent actions.slice \
  -f "$BUNDLE_ROOT/Dockerfile.runner" \
  -t ezgha-runner:latest "$BUNDLE_ROOT"
```

`BUNDLE_ROOT` is the already-validated canonical release bundle, not a caller value. Verify the local image before releasing maintenance. Migration requires the existing image ID and never rebuilds while jobs may be active.

- [ ] **Step 7: Release maintenance and restart only after proof**

After the policy and required image assertions pass, remove the maintenance intent, release `serve.lock`, and enable/start `ezgha.service`. Converge auxiliary state by enabling `ezgha-token-refresh.timer` and `ezgha-mission-output-cleanup.timer`, disabling/stopping `ezgha-queue-reaper.timer` and `agent-scope-reaper.timer` plus their services, and preserving the snapshotted fleet-alert enablement state. Migration requires exactly ten distinct live slot names `ez-runner-c-1..10`, no extra managed container, and ten actual PIDs beneath `/actions.slice` within 210 seconds and repeats Task 3 `--require-fleet`; bootstrap uses 600 seconds. After maintenance release, IDs may change normally and no snapshot-membership or departure-to-replacement condition applies.

- [ ] **Step 8: Implement explicit recovery states**

Before mutation, exit without live effect. Snapshot failure leaves the service running. A failure after reconciler stop but before maintenance release atomically persists intent with boot ID, phase, and recovery state before exit; process locks then release automatically. Before the actions commit point, restore exact safe bytes/reload managers, leave `ezgha.service` inactive, and emit `activation_precommit_failed`. After the commit point, retain the finite actions policy, leave the service inactive with intent, and emit `RecoveryRequired`; never weaken the boundary. After intent/lock release, any auxiliary-convergence or fleet-proof failure emits `activation_postrelease_proof_failed` and returns nonzero/keeps the release open, but does not stop, disable, or restart `ezgha.service`, issue a Docker lifecycle command, or roll back policy; the reconciler stays running to refill ephemeral slots.

- [ ] **Step 9: Assert forbidden operations never occur**

Fixture tests reject activation-issued `docker stop`, `pause`, `rm`, `run`, `kill`, `restart`, or prune before maintenance release, deregistration of a container-backed runner, `limactl`, `colima`, Docker restart, reboot/shutdown, Mac paths, launchctl, caller-selected build paths/flags, and caller-selected systemd destinations. They prove root invocation fails before mutation; every missing controller and a denied exact sudo authorization produce zero intent/service mutation; absent-slice bootstrap starts and verifies all three slices before exactly one canonical contained image-build argv or runner creation; migration performs no image build; unchanged frozen migration preserves every ID; frozen one-or-many departure produces only subset/event-ledger records; a surviving frozen ID with wrong ancestry fails; arbitrary post-release JIT ID churn passes when ten correct slot names/PIDs/no extras converge; a convergence timeout emits the postrelease alert without service/Docker/policy mutation; failed user-manager or missing/malformed/SHA-mismatched rendered-unit or auxiliary bundle validation causes zero mutation; the system-scope-only exemption path is insufficient; every user-manager/config/lock operation retains the validated deploy identity; locks release on failed-process exit while durable intent remains; auxiliary closure/timer state matches the fixed contract; absent watcher source never fails installation and absent watcher state issues no disable/stop, while present and loaded-drift cases converge to exact absence; and only pre-authorized identical system argv cross `sudo -n`.

- [ ] **Step 10: Run focused checks**

```bash
bash -n scripts/host/apply-host-containment-release1.sh
bash tests/apply_host_containment_release1_test.sh
shellcheck scripts/host/apply-host-containment-release1.sh
```

- [ ] **Step 11: Commit the isolated unit**

```bash
git add scripts/host/apply-host-containment-release1.sh tests/apply_host_containment_release1_test.sh
git commit -m "feat: activate host containment atomically [codex/gpt-5.6-sol]"
```

---

### Task 5: Encode The Goal In Operator And Verification Surfaces

**Files:** Task 5 files from the File Map.

**Interfaces:**

- `doctor-runner` calls the Task 3 script in read-only mode and includes containment in its final verdict.
- The exit gate requires the Release 1 assertion and ten live contained Linux runners.
- Compatible Linux HostDocker has exactly one deployment command: `./install.sh`. After local tests and `cargo build --release --locked`, it stages a versioned verified bundle and atomically updates `$HOME/.local/libexec/ezgha/release1`, then ends with one `exec` of Task 4. It never invokes legacy `install-service`, starts/restarts the service, builds an image, performs live auxiliary installation/enablement, or runs Docker/VM commands before that exec.
- Gate 4 and `canary-once` use the main ten-runner Linux config/labels; no separate Linux canary supervisor or reserved eleventh runner remains documented.
- Repo guidance states crash containment and operator availability are primary; VM layering and security are not substitutes for a finite host boundary.

- [ ] **Step 1: Write focused failing tests**

Add tests proving a single containment mismatch makes both `doctor-runner` and the exit gate bad, while a passing stub preserves existing fleet verdict behavior. Assert containment admission failure invokes the existing high-severity alert/journal path. Assert docs and example config say Linux count 10, HostDocker, `actions.slice`, and fixed profile.

Add installer tests proving compatible Linux branches before the first existing Docker context discovery, `DOCKER_HOST_OVERRIDE` export, `docker version`, image build, legacy `install-service`, any service start/restart, or live auxiliary installation. It rejects selectors, runs local tests plus `cargo build --release --locked`, and stages an explicit allowlist under a private versioned release directory with preserved paths: `target/release/ezgha` as `bin/ezgha`; stdout of the two Task 2 render commands as `systemd/ezgha.service` and `systemd/ezgha-alert@.service`; all Task 1 policy artifacts; Task 3 assertion; Task 4 activation; `Dockerfile.runner`; executable `docker/tar-workspace-wrapper.sh`; `agents.slice`, `automation.slice`, and the three AO automation drop-ins; `agent-scoped-launch.sh`, `agent-cli-scoped.sh`, and `agent-scope-reaper.sh`; token-refresh units plus `refresh_gh_app_token.sh`/`mint_gh_app_token.py`; mission-output-cleanup units plus `cleanup-mission-output.sh`; queue-reaper units plus `cleanup-stuck-runs.sh`; and fleet-alert units plus `ezgha-fleet-alert.sh`. It never glob-copies or requires deleted PSI watcher sources and stages no Linux Lima/Colima/QEMU/trim artifact. A manifest records source HEAD, mode, and SHA-256 for every allowlisted file. Verify manifest, binary `--version`, both rendered units including exact `ExecStart`/`OnFailure`, auxiliary closure, and build context before atomically replacing a temporary symlink with `$HOME/.local/libexec/ezgha/release1`; manifest/stage failure leaves the old link, unit, and running service untouched. End the Linux branch with exactly one `exec "$BUNDLE_ROOT/apply-host-containment-release1.sh"`. Task 4 alone installs the closure, converges auxiliary state, enables/starts the main service, and builds the bootstrap image after policy proof. Update `tests/install_watchdog_gate_test.sh` so Linux proves deleted watcher sources do not fail staging and delegation precedes Docker/VM/live-auxiliary actions; preserve Mac/explicit-VM expectations. Tasks 1-4 integration bases are development-only and Task 7 must not invoke `install.sh` until Task 5 removes the legacy hard requirement for watcher sources.

Add config/docs tests proving `config/config.toml.linux-canary.example` is gone, `config/README.md` contains no separate `systemd-run ... serve` instructions, the main Linux example includes the canary repo/workflow dispatch settings and main fleet labels, and Gate 4 defaults to that main config. A `canary-once` fixture must dispatch without Docker while `serve` on a one-runner verifier config fails before Docker.

- [ ] **Step 2: Run the focused tests and confirm failure**

```bash
bash tests/doctor_runner_host_pressure_test.sh
bash tests/verify_exit_gate8_test.sh
bash tests/install_watchdog_gate_test.sh
bash tests/install_uninstall_aux_units_test.sh
```

- [ ] **Step 3: Integrate the assertion without mutation**

Add a bounded call to Task 3. Do not duplicate its policy parser in `doctor-runner` or the exit gate. Preserve existing Mac and job-activity checks.

Verify and document Task 2's stable containment alert event and journal diagnostic so fail-closed fleet drain cannot be silent; Task 5 does not duplicate or reimplement that Rust path.

- [ ] **Step 4: Update portable operator guidance**

Document the single `./install.sh` deployment command, installed delegated activation/assertion paths, versioned bundle/manifest, exact prerequisites/limits, failure behavior, and rollback stance. State that compatible Linux requires pre-existing passwordless authorization for enumerated system argv, Release 1 does not edit sudoers, and denial emits `SUDOERS_PREREQUISITE_MISSING` before service/intent mutation. Replace the stale global "no sudo" claim with OS/profile behavior. Remove claims that VM layering is the Linux crash boundary and any fixed-Linux Lima/Colima remediation. Replace fixed-profile exit-gate QEMU/Colima requirements with Task 3's host assertion. Make Gate 0 use `$HOME/.local/libexec/ezgha/release1/bin/ezgha --version` on the fixed Linux profile and retain existing paths elsewhere. Delete the separate Linux canary instructions and route proof through the main fleet without changing count/labels. Do not add Release 2 work to the install path.

- [ ] **Step 5: Run focused checks**

```bash
bash tests/doctor_runner_host_pressure_test.sh
bash tests/verify_exit_gate8_test.sh
bash tests/install_watchdog_gate_test.sh
bash tests/install_uninstall_aux_units_test.sh
bash -n install.sh doctor-runner docs/verify-exit-criteria.sh
```

- [ ] **Step 6: Commit the isolated unit**

```bash
git add install.sh doctor-runner docs/verify-exit-criteria.sh README.md config CLAUDE.md AGENTS.md tests
git commit -m "docs: make host containment a fleet invariant [codex/gpt-5.6-sol]"
```

---

### Task 6: Add A Fixed 24-Hour Outcome Window

**Files:** `scripts/job_outcome_monitor.py`, `tests/job_outcome_monitor_test.py`.

**Interfaces:**

- Extend the existing bounded monitor rather than adding an org crawler. Its current default six-hour success-rate mode, CLI, schema, and causally-undetermined verdict remain backward compatible.
- Add opt-in Release 1 `baseline` and `post` modes that reuse the existing config-prefix parser, `CoverageError`, stale-token clearing, and `--now` test clock. Their private `ReleaseTransport` exposes `get_json(path) -> (status, body_bytes)` and `get_bytes(path) -> (status, body_bytes)`; production delegates only GET `gh api` calls, while tests inject a request-keyed recorded transport. `LocalEvidence.read(path) -> bytes` similarly separates fixed boot/cgroup/journal reads from fixtures. The legacy `GithubApi` and default-mode call graph remain unchanged.
- The tracked monitored repo set is exactly `jleechanorg/worldarchitect.ai` and `jleechanorg/ez-gh-actions`; the report is explicit that it is bounded evidence from those workload repos, not org-complete proof.
- Baseline is invoked by Task 7 immediately after activation/live proof and never controls the service. It captures boot ID, `actions.slice/memory.events`, and journal cursor before its first network request, fixes that instant as `T`, and observes `[T-24h,T)`. Post observes `[T,T+24h)`.
- Both modes are read-only with respect to runners, services, Docker, systemd, and GitHub.

- [ ] **Step 1: Write failing fixture tests**

Extend `tests/job_outcome_monitor_test.py` with request-keyed raw JSON/log responses and injected local-read fixtures. Preserve every existing default-mode test. Cover the exact two-repo requirement, baseline/post parsing, exact request order and response hashes, request and wall-budget exhaustion, the fixed 99-runs-per-repo cap, missing/truncated/repeated pages, a missing or oversized failed-job log, exact half-open boundaries for both run `created_at` and job `completed_at`, the versioned exact GitHub runner-lost templates, similar unmatched text, `memory.events` deltas/resets, an `actions.slice` kernel OOM record, boot change, unavailable journal range, deterministic JSON/hashes, unknown report kind/schema/rule versions, and post before `T+24h`.

Assert a run/job timestamp equal to the window end is excluded, while `completed_at == T` is excluded from baseline and included in post only when its run creation is also in the post window. Assert `INCONCLUSIVE` and nonzero exit for incomplete evidence or any fixed cap. Assert production GitHub requests are GET-only and command inventory contains no GitHub mutation, Docker, `systemctl`, service, or runner command.

- [ ] **Step 2: Confirm the tests fail before implementation**

```bash
python3 -m unittest tests/job_outcome_monitor_test.py
```

- [ ] **Step 3: Implement the fixed baseline command**

The integration owner invokes the existing monitor immediately after live proof; the tool fixes `T` from its first local observation:

```bash
python3 scripts/job_outcome_monitor.py baseline \
  --config "$HOME/.config/ezgha/config.toml" \
  --repo jleechanorg/worldarchitect.ai \
  --repo jleechanorg/ez-gh-actions \
  --output "$HOME/.local/state/ezgha/release1-outcome-baseline.json"
```

Require the fixed org config/prefix and exact repo arguments. Release modes internally fix at most 99 completed runs per repo, 100 total GitHub requests, and 75 seconds; they do not accept the legacy cap override flags, and the legacy defaults remain 20 runs, 50 requests, and 75 seconds. Add fixed 2-MiB-per-log and 32-MiB-total failed-log byte caps. Population membership requires both the workflow run `created_at` and job `completed_at` to fall in the same half-open window; any cap that prevents proving that bounded population yields `INCONCLUSIVE`, never a partial pass/fail. Record repo/workflow/run/job IDs, timestamps, runner name, conclusion, raw response/log hashes, boot ID, journal cursor, and `actions.slice/memory.events` in canonical JSON written atomically. The only Release-mode production configurability is the existing config, exact two repeated `--repo` values, and output/baseline path; caps and classification rules are constants.

- [ ] **Step 4: Implement the fixed post comparison**

```bash
python3 scripts/job_outcome_monitor.py post \
  --baseline "$HOME/.local/state/ezgha/release1-outcome-baseline.json" \
  --output "$HOME/.local/state/ezgha/release1-outcome-post.json"
```

Refuse before `T+24h`, reload the exact repo/config/caps from the baseline, and collect the matching bounded post population. Require a complete log archive for every included non-success job. Classify runner loss only from versioned exact normalized GitHub service diagnostic templates; similar free text remains unclassified. Classify infrastructure OOM only when `actions.slice` `oom`/`oom_kill` increases or the complete journal interval names an actions-slice kernel OOM. This is narrow protocol-signature parsing, not general causal inference.

Emit canonical Release 1 JSON with `report_kind="release1_outcome_window"`, `release_schema_version=1`, mode, capture/window timestamps, exact repos/prefix/config hash, bounded-source coverage, jobs/log hashes, local anchors, rule version, and verdict; post adds baseline hash and comparison and rejects a baseline without that exact kind/version. Return failing when post contains any infrastructure OOM, a runner-lost count above baseline, or a new exact signature. Return `INCONCLUSIVE` and nonzero on any cap, API/log/journal gap, boot change, counter reset, or unknown version. Other conclusions remain reported and causally unclassified. Default monitor mode remains schema-compatible and never emits either Release-only discriminator.

- [ ] **Step 5: Run focused checks**

```bash
python3 -m unittest tests/job_outcome_monitor_test.py
python3 -m py_compile scripts/job_outcome_monitor.py
git diff --check
```

- [ ] **Step 6: Commit the isolated unit**

```bash
git add scripts/job_outcome_monitor.py tests/job_outcome_monitor_test.py
git commit -m "feat: record deterministic runner outcomes [codex/gpt-5.6-sol]"
```

---

### Task 7: Integrate, Prove, Deploy, And Record

**Files:** all Release 1 files after isolated commits are integrated.

**Interfaces:** The primary agent is the sole integration and deploy owner.

- [ ] **Step 1: Integrate in dependency order**

Integrate green Task 1, Task 2, and Task 3; implement/integrate Task 4 from that base; then implement/integrate Task 5 from the base containing Tasks 1-4. Integrate independent Task 6 before the final gate. Resolve only task-owned conflicts; preserve unrelated `.playwright-mcp/` and user changes.

- [ ] **Step 2: Run the complete local quality gate**

```bash
cargo fmt --all -- --check
cargo clippy --all-targets --all-features -- -D warnings
cargo test
bash tests/host_crash_containment_release1_artifacts_test.sh
bash tests/assert_host_containment_release1_test.sh
bash tests/apply_host_containment_release1_test.sh
bash tests/host_ops_0725_test.sh
bash tests/host_control_artifacts_test.sh
bash tests/install_watchdog_gate_test.sh
bash tests/install_uninstall_aux_units_test.sh
bash tests/doctor_runner_host_pressure_test.sh
bash tests/verify_exit_gate8_test.sh
python3 -m unittest tests/job_outcome_monitor_test.py
git diff --check
```

- [ ] **Step 3: Independently review the integrated diff**

Require one semantic reviewer to inspect guard placement, compensation scope, activation failure states, Mac non-regression, and forbidden host lifecycle operations. Resolve every blocker and rerun Step 2.

- [ ] **Step 4: Commit and push the green implementation**

Verify branch, upstream, and explicit target before a normal push. Do not force-push.

```bash
git branch --show-current
git rev-parse --abbrev-ref --symbolic-full-name @{u}
git push origin HEAD:docs/nextsteps-2026-08-30-fleet-churn
```

- [ ] **Step 5: Repeat the live read-only preflight**

Record Docker version, `CgroupDriver=systemd`, `CgroupVersion=2`, exact `unix:///var/run/docker.sock` resolution, 32-CPU/RAM facts, current ten container IDs, PID ancestry, exact current system/user slice values, `actions.slice/memory.current`, free memory/swap/disk, and PSI. Abort activation on any fixed threshold or profile mismatch.

- [ ] **Step 6: Run the single deployment command**

```bash
./install.sh
```

Run it once as the deploy user, never through top-level `sudo`. It builds the release binary, stages/verifies/atomically selects the bundle, and `exec`s activation exactly once. Do not separately invoke the installed activation script or run ad hoc `systemctl`, Docker, or filesystem mutations around it. Preserve staging/activation output as deployment evidence.

- [ ] **Step 7: Prove the live result**

```bash
"$HOME/.local/libexec/ezgha/release1/assert-host-containment-release1.sh" --require-fleet
./doctor-runner
```

Require exactly ten local Linux slot names, no extra managed container, and ten actual PIDs under `/actions.slice`, regardless of post-release IDs. Preserve the frozen-window activation snapshot, Docker read/event ledger, and departure records only as evidence that activation issued no lifecycle mutation and preserved every then-surviving runner; do not compare the later live ID set to that snapshot. Confirm the desktop session/operator terminal remained alive. Run the repo exit gate only after this proof.

Immediately after live proof, run Task 6 baseline mode:

```bash
python3 scripts/job_outcome_monitor.py baseline \
  --config "$HOME/.config/ezgha/config.toml" \
  --repo jleechanorg/worldarchitect.ai \
  --repo jleechanorg/ez-gh-actions \
  --output "$HOME/.local/state/ezgha/release1-outcome-baseline.json"
```

It captures `T` before its first network call. Preserve the canonical baseline JSON with deployment evidence. A failed or inconclusive baseline does not stop, restart, or roll back the contained fleet; it keeps the deployment issue open and blocks Release 1 closure.

- [ ] **Step 8: Record durable evidence and follow-up**

Keep the deployment issue open through the following 24 hours, then run the fixed post command:

```bash
python3 scripts/job_outcome_monitor.py post \
  --baseline "$HOME/.local/state/ezgha/release1-outcome-baseline.json" \
  --output "$HOME/.local/state/ezgha/release1-outcome-post.json"
```

Require its passing verdict; any new runner-lost signature/count or infrastructure OOM is a Release 1 failure even if `doctor-runner` reports healthy containers. Update the existing Bead/GitHub issue with exact commit, deployment time, assertion output, ten PID cgroups, slice values, both canonical JSON artifacts, and any failed or inconclusive state. Close the deployment Bead/issue only after a passing verdict; failure or `INCONCLUSIVE` keeps it open. Create separate Release 2 beads for deferred broker/image/attestation work without blocking the contained fleet.

- [ ] **Step 9: Push the final evidence unit**

Commit tracked evidence/docs with the CLI/model suffix, perform a normal push, and report the full remote commit URL.

## Release 2 Boundary

Do not pull these items into Release 1 even if encountered during implementation: privileged broker, `SCM_RIGHTS` handoff, general effect coordinator, immutable image publisher, automated Docker driver remediation, synthetic pressure scheduler, 100-cycle calibration, queue/reaper redesign, Darwin migration, or security isolation. File or update separate beads with concrete evidence instead.
