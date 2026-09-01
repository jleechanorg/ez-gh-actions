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
- `automation.slice` is exactly `MemoryHigh=4G`, `MemoryMax=6G`, `MemorySwapMax=1G`, and `TasksMax=4096`.
- All three workload slices set `ManagedOOMMemoryPressure=auto` and `ManagedOOMSwap=auto`.
- System `-.slice`, `user.slice`, `user-.slice`, `user@.service` and user-manager `app.slice`, `session.slice` set both managed-OOM policies to `auto`.
- The `user@.service` drop-in also sets `ManagedOOMPreference=none` and `OOMScoreAdjust=0`.
- Remove the runner OOM exemption and the supported agent-launch opt-out. Do not move or terminate existing interactive agent sessions during activation.
- A Linux HostDocker create attempt fails before slot, JIT, workspace, removal, or Docker mutation when containment is not exact.
- After create, actual container PID ancestry must be below `/actions.slice`; mismatch compensates only the just-created transition.
- Activation is single-writer, never stops a runner container, and leaves `ezgha.service` inactive on any uncontained result.
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
- Modify `tests/install_uninstall_aux_units_test.sh` and focused installer/doctor/exit-gate tests.

## Parallel Execution Map

After this plan and spec have an approved exact SHA:

- Lane A owns Task 1 only.
- Lane B owns Task 2 only.
- Lane C owns Task 3 only.
- The primary agent owns Task 5 while A-C run.
- Task 4 starts after Task 1 and Task 3 interfaces are merged because it consumes their exact paths and assertion contract.
- Integration, live activation, and production verification are serialized under the primary deploy owner.

Each writer uses an isolated worktree pinned to the approved SHA. No worker may run `cargo install`, restart `ezgha.service`, invoke the live exit gate, modify the Docker daemon, or deploy host files. The primary agent integrates commits in dependency order and is the only live deploy owner.

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
- Produces `require_host_containment(&Config) -> anyhow::Result<()>` for the Linux HostDocker create path.
- Produces `require_container_actions_ancestry(container_id: &str) -> anyhow::Result<()>` after Docker start.
- Produces `DockerCommandTarget` with `CanonicalLinuxHost` and existing-platform variants, plus one `docker_command(target: DockerCommandTarget) -> Command` factory. `CanonicalLinuxHost` clears both selector variables and adds `--host unix:///var/run/docker.sock`; Mac and explicit VM variants preserve their existing endpoint behavior.
- Produces a fixed maintenance-intent check used by every `start`, `serve`, and `stop` mutation path before and after `serve.lock` acquisition.
- Produces a stable containment-admission failure event through the existing alert/journal API; repeated guard failure is visible without a separate monitor.
- Produces fixed-profile backend-recovery suppression: no `lima-vm@colima.service`, `limactl`, Colima, or Docker lifecycle command from startup or retry.
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

Inventory every production Docker call in `src/platform.rs`, `src/main.rs`, and `src/docker_backend.rs`. Add a structural test that rejects direct production `Command::new("docker")` outside the single factory, including reachability, platform detection, DockerSysbox classification, probe-image pre-pull, capacity probes, container peak RSS, inventory, inspect/top, cleanup, and create paths.

- [ ] **Step 4: Run the focused Rust tests and confirm failure**

```bash
cargo test host_containment -- --nocapture
cargo test configured_cgroup_parent_is_emitted_on_runner_start -- --nocapture
```

Expected: new tests fail because the admission and ancestry functions do not exist.

- [ ] **Step 5: Implement the fixed admission profile and probes**

Read only canonical system paths and command output. Do not accept path arguments or environment-variable overrides in production code. Split OS detection from Docker probing: on Linux reject selectors, choose `CanonicalLinuxHost`, and use that target for platform/backend discovery and every later Docker operation, including DockerSysbox. Move `prepull_probe_image` after `require_host_containment`; no pull or reachability probe may use an ambient endpoint. Update generated Linux HostDocker units with `UnsetEnvironment=DOCKER_HOST DOCKER_CONTEXT`, with a focused service-unit test; do not change Mac or explicit VM units. Return contextual errors without changing the host.

- [ ] **Step 6: Place the guard before every create-side effect**

At the single shared Linux HostDocker/DockerSysbox create entry, call `require_host_containment` before slot bookkeeping, old-container removal, workspace changes, JIT registration, or runner Docker execution. The only Docker calls allowed before admission are canonical-endpoint read-only topology/containment probes. Keep the existing `--cgroup-parent actions.slice` argument.

Add a test command recorder that proves a failed guard records no `docker rm`, `docker run`, JIT request, or slot mutation.

Add serve-order tests proving selector rejection happens before platform Docker probing and the probe-image pull happens after a successful containment verdict. Assert every recorded Linux Docker argv begins with `docker --host unix:///var/run/docker.sock`, while Mac/explicit VM tests retain their existing argv.

Add a focused test that a failed containment verdict emits the stable alert event once per existing cooldown semantics and never credits backend recovery or admission success.

Change `backend_restart_can_help`/`maybe_restart_backend` and startup wait policy to accept the resolved profile. For fixed Linux HostDocker/DockerSysbox they return passive-retry/no-action without calling `backend_restart_commands`; generated service units omit Lima `Wants=`/`After=`. Add regression tests for initial unreachability and repeated serve failures that record zero VM/backend lifecycle commands. Preserve existing Mac and explicit VM recovery tests.

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

Stub `docker`, `systemctl`, and `systemd-run` through a fixture `PATH`. Cover exact pass, one wrong slice value, `max`, wrong Docker driver, active exemption, present unlimited override, nine containers, eleven containers, and one wrong PID ancestry.

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
- Success means finite policy is active and either the same ten migration containers remain or a zero-container bootstrap converges to ten contained containers.
- Any failure that cannot prove containment leaves `ezgha.service` inactive.

- [ ] **Step 1: Write state-machine fixture tests**

Test command order and final state for:

```text
clean success
zero-container bootstrap success
zero-container bootstrap with absent actions.slice
non-Linux invocation
root invocation
missing exact sudo authorization
unreachable deploy-user manager
preflight failure
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
```

For every failure after stop, assert the final command log does not contain a later uncontained service start. Assert no test command stops, pauses, removes, or recreates a runner container. Permit deregistration only for a registration proven to have no local container. After the actions-boundary commit point, assert recovery never restores it to infinity.

- [ ] **Step 2: Confirm tests fail before implementation**

```bash
bash tests/apply_host_containment_release1_test.sh
```

- [ ] **Step 3: Implement the Linux gate and immutable preflight**

Run `uname -s` first and require exact `Linux`, then reject effective UID 0. Resolve the fixed deploy UID from real/effective UID equality and its canonical home through `getent passwd`; require `HOME` equality, the user bus at `/run/user/<uid>/bus`, a successful bounded read-only `systemctl --user show-environment`, and no secondary `ezgha serve` or canary service. Require at least 8 GiB `MemAvailable`, swap use at most 50%, memory PSI `full avg10 < 1.00`, at least 1 GiB free on the target filesystem, `agents.slice/memory.current < 18G`, `automation.slice/memory.current < 4G`, unset Docker selector variables, Docker 29-compatible systemd/cgroup-v2 at `unix:///var/run/docker.sock`, exact count 10, 2500-MiB runner memory, and `actions.slice` parent. Accept only zero total `ezgha=managed` containers with absent/empty `actions.slice` for bootstrap, or exactly ten total managed containers with exact expected names/ancestry plus `actions.slice/memory.current < 26G` for migration. Construct every later elevated argv, pre-authorize each with `sudo -n -l -- <exact argv>`, and fail without intent/service mutation if any is denied.

- [ ] **Step 4: Freeze mutations and snapshot before the reconciler stop**

Acquire the deploy-user activation lock and atomically create the deploy-user maintenance intent with PID and boot ID. Snapshot every target file and prior manager state as that user. In migration mode stop only the deploy user's `ezgha.service`; in bootstrap mode require it already inactive. Acquire and retain the deploy-user `serve.lock`, then recheck the zero-or-ten state and ancestry. The Task 2 double-check makes direct `start`, `serve`, and `stop` refuse the maintenance interval. Existing graceful shutdown may clean only proven container-less registrations.

- [ ] **Step 5: Install and commit the finite actions boundary first**

As the deploy user, leave the preflight-verified active config unchanged and install the fixed user-manager files. Before unlinking any watcher file, run `systemctl --user disable --now psi-oom-watcher.timer` followed by `systemctl --user stop psi-oom-watcher.service`; any failure retains intent and prevents `ezgha.service` restart. Use separate fixed `sudo -n` commands only to install/remove the enumerated system-manager files, reload the system manager, and apply/query `actions.slice`. Remove only:

```text
<deploy-home>/.config/systemd/user/ezgha.service.d/10-oomd-omit.conf
<deploy-home>/.config/systemd/user/agents.slice.d/99-local-unlimited.conf
<deploy-home>/.config/systemd/user/psi-oom-watcher.service
<deploy-home>/.config/systemd/user/psi-oom-watcher.timer
<deploy-home>/.local/lib/ezgha/host-controls/psi-oom-watcher.sh
```

Reload the system manager. In bootstrap invoke the pre-authorized exact `sudo -n systemctl start actions.slice`; migration requires it already active. Apply the six exact properties and verify the live cgroup before runner admission. In migration also verify the existing ten PID ancestries. This verified point is forward-only: later recovery retains the persistent and runtime finite actions boundary.

- [ ] **Step 6: Apply the remaining policy and prove the unchanged fleet**

Reload the user manager, apply and verify agent, automation, and all six oomd boundary properties. In migration mode invoke Task 3 with `--require-fleet` while maintenance intent and `serve.lock` remain held and require the same ten IDs. In bootstrap mode invoke it without the fleet requirement and require zero managed containers.

- [ ] **Step 7: Release maintenance and restart only after proof**

After the policy assertion passes, remove the maintenance intent, release `serve.lock`, and start `ezgha.service`. Require service readiness within 210 seconds. Migration repeats Task 3 `--require-fleet` against the same ten IDs; bootstrap requires ten contained containers within 600 seconds.

- [ ] **Step 8: Implement explicit recovery states**

Before mutation, exit without live effect. Snapshot failure leaves the service running. Before the actions commit point, restore exact bytes and reload managers. After that commit point, retain the finite actions policy, leave the service inactive on any mismatch, retain the intent, and emit `RecoveryRequired`; never weaken the actions boundary automatically.

- [ ] **Step 9: Assert forbidden operations never occur**

Fixture tests reject `docker stop`, `docker pause`, `docker rm`, `docker run`, deregistration of a container-backed runner, `limactl`, `colima`, Docker restart, reboot/shutdown, Mac paths, launchctl, and caller-selected systemd destinations. They prove root invocation fails before mutation, absent-slice bootstrap starts and verifies the slice before any runner creation, a denied exact sudo authorization or failed user-manager probe causes zero intent/service mutation, the system-scope-only exemption path is insufficient, every `systemctl --user`/config/lock operation retains the validated deploy UID/home/bus, watcher disable/stop precedes file removal, no watcher enablement symlink or active unit survives, the user service has no effective omit/-1000 values, and only the pre-authorized identical system argv cross `sudo -n`.

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
- `install.sh` delegates the compatible Linux HostDocker path to Task 4 after staging an inactive service, and never installs the Colima-guest slice or PSI watcher on that path.
- Gate 4 and `canary-once` use the main ten-runner Linux config/labels; no separate Linux canary supervisor or reserved eleventh runner remains documented.
- Repo guidance states crash containment and operator availability are primary; VM layering and security are not substitutes for a finite host boundary.

- [ ] **Step 1: Write focused failing tests**

Add tests proving a single containment mismatch makes both `doctor-runner` and the exit gate bad, while a passing stub preserves existing fleet verdict behavior. Assert containment admission failure invokes the existing high-severity alert/journal path. Assert docs and example config say Linux count 10, HostDocker, `actions.slice`, and fixed profile.

Add installer tests proving the compatible Linux HostDocker path does not call `limactl`, install `systemd/guest/actions.slice`, or install/enable the PSI watcher; it stages the binary/config/service inactive and `exec`s the fixed Task 4 entrypoint. Mac and explicit VM install fixtures retain their existing behavior.

Add config/docs tests proving `config/config.toml.linux-canary.example` is gone, `config/README.md` contains no separate `systemd-run ... serve` instructions, the main Linux example includes the canary repo/workflow dispatch settings and main fleet labels, and Gate 4 defaults to that main config. A `canary-once` fixture must dispatch without Docker while `serve` on a one-runner verifier config fails before Docker.

- [ ] **Step 2: Run the focused tests and confirm failure**

```bash
bash tests/doctor_runner_host_pressure_test.sh
bash tests/verify_exit_gate8_test.sh
```

- [ ] **Step 3: Integrate the assertion without mutation**

Add a bounded call to Task 3. Do not duplicate its policy parser in `doctor-runner` or the exit gate. Preserve existing Mac and job-activity checks.

Verify and document Task 2's stable containment alert event and journal diagnostic so fail-closed fleet drain cannot be silent; Task 5 does not duplicate or reimplement that Rust path.

- [ ] **Step 4: Update portable operator guidance**

Document one user-facing `install.sh` entrypoint, the delegated activation entrypoint, one assertion entrypoint, exact prerequisites, exact limits, failure behavior, and rollback stance. Remove claims that Colima/VM layering is the Linux crash boundary and remove fixed-Linux remediation that starts Lima/Colima. Replace fixed-profile exit-gate QEMU/Colima requirements with Task 3's host-containment assertion. On compatible Linux HostDocker, remove the current guest-slice `limactl` block and legacy watcher install; stage an inactive service and `exec` Task 4 rather than starting an uncontained daemon. Delete the separate Linux canary example/instructions and route canary proof through the main fleet config without changing runner count or labels. Do not add Release 2 instructions to the immediate install path.

- [ ] **Step 5: Run focused checks**

```bash
bash tests/doctor_runner_host_pressure_test.sh
bash tests/verify_exit_gate8_test.sh
bash tests/install_uninstall_aux_units_test.sh
bash -n install.sh doctor-runner docs/verify-exit-criteria.sh
```

- [ ] **Step 6: Commit the isolated unit**

```bash
git add install.sh doctor-runner docs/verify-exit-criteria.sh README.md config CLAUDE.md AGENTS.md tests
git commit -m "docs: make host containment a fleet invariant [codex/gpt-5.6-sol]"
```

---

### Task 6: Integrate, Prove, Deploy, And Record

**Files:** all Release 1 files after isolated commits are integrated.

**Interfaces:** The primary agent is the sole integration and deploy owner.

- [ ] **Step 1: Integrate in dependency order**

Cherry-pick Task 1, Task 2, Task 3, Task 5, then Task 4. Resolve only task-owned conflicts; preserve unrelated `.playwright-mcp/` and user changes.

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
bash tests/install_uninstall_aux_units_test.sh
bash tests/doctor_runner_host_pressure_test.sh
bash tests/verify_exit_gate8_test.sh
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

Record Docker version, `CgroupDriver=systemd`, `CgroupVersion=2`, exact `unix:///var/run/docker.sock` resolution, CPU/RAM, current ten container IDs, PID ancestry, exact current system/user slice values, `actions.slice/memory.current`, free memory/swap/disk, and PSI. Abort activation on any fixed threshold or profile mismatch.

- [ ] **Step 6: Run the tracked activation entrypoint**

```bash
./scripts/host/apply-host-containment-release1.sh
```

Run it as the deploy user, never through top-level `sudo`. Do not run ad hoc `systemctl`, Docker, or filesystem mutations around it. Preserve its receipt/log output as deployment evidence.

- [ ] **Step 7: Prove the live result**

```bash
./scripts/host/assert-host-containment-release1.sh --require-fleet
./doctor-runner
```

Require the same ten local Linux container IDs and ten actual PIDs under `/actions.slice`. Confirm no runner container was stopped or recreated and the desktop session and operator terminal remained alive. Run the repo exit gate only after this proof.

- [ ] **Step 8: Record durable evidence and follow-up**

Update the existing Bead/GitHub issue with exact commit, deployment time, assertion output, ten PID cgroups, slice values, and any failed state. Create separate Release 2 beads for deferred broker/image/attestation work without blocking Release 1 closure.

- [ ] **Step 9: Push the final evidence unit**

Commit tracked evidence/docs with the CLI/model suffix, perform a normal push, and report the full remote commit URL.

## Release 2 Boundary

Do not pull these items into Release 1 even if encountered during implementation: privileged broker, `SCM_RIGHTS` handoff, general effect coordinator, immutable image publisher, automated Docker driver remediation, synthetic pressure scheduler, 100-cycle calibration, queue/reaper redesign, Darwin migration, or security isolation. File or update separate beads with concrete evidence instead.
