# Runner Crash Containment Design

**Date:** 2026-08-31
**Status:** Release 1 redesign after formal `/advice`; implementation not started
**Primary goal:** Keep the physical Ubuntu host, desktop session, Warp, and operator tools responsive while ten Linux GitHub Actions runners execute concurrently.

## Live Evidence

The 2026-09-01 read-only target-host probe established the facts needed for this release:

- Docker 29.4.3 uses cgroup v2 with `CgroupDriver=systemd` on Ubuntu 24.04.4, kernel 6.17.0-29.
- All ten current `ez-runner-c-1..10` container PIDs are already descendants of `/actions.slice`.
- The effective host `actions.slice` is active but has infinite memory, swap, CPU, and task limits.
- Effective `agents.slice` memory limits are infinite because `99-local-unlimited.conf` overrides the tracked unit.
- Fresh cgroup evidence shows `agents.slice` at about 8.10 GiB current and 17.14 GiB historical peak, with zero current/peak swap; `automation.slice` is about 171 MiB current and 258 MiB peak.
- `automation.slice` is finite at `MemoryHigh=4G`, `MemoryMax=6G`, and `MemorySwapMax=1G`.
- `user@1000.service` is an active `systemd-oomd` pressure target with `ManagedOOMMemoryPressure=kill`, a 2-GiB pressure limit, `OOMScoreAdjust=100`, and no tracked local override.
- The legacy `psi-oom-watcher` is currently inactive and disabled but remains installed and is reinstalled by `install.sh`; its sustained-PSI action can SIGTERM a deploy-user process.

No Docker daemon restart is needed on this host. A different host whose Docker daemon is not cgroup v2/systemd fails Release 1 preflight and requires a separately reviewed maintenance change.

## Release 1 Decision

Release 1 fixes only the immediate crash path:

1. Make the existing host `/actions.slice` finite.
2. Make agent and automation aggregates finite.
3. Remove broad production and desktop `systemd-oomd` kill roots.
4. Refuse every new Linux runner creation when the host boundary is missing, infinite, or wrong.
5. Activate the policy in place with runner mutations frozen, preserve and prove every surviving snapshotted runner during that interval, then after release prove ten contained slots/PIDs regardless of normal ephemeral ID churn.

This release does not redesign deployment security. Root brokers, bundle authorization, descriptor handoff, immutable image publishing, typed effect frameworks, Mac receipts, queue refactors, and attestation calibration are deferred. They must not delay the finite host boundary.

## Execution Ceiling

Release 1 has three outcome milestones and no fourth planning gate:

1. Tracked finite slice/OOM policy plus a hermetic read-only assertion.
2. Fail-closed fixed-Linux runner admission plus post-create `/actions.slice` ancestry proof.
3. One canonical installer/activation path that reaches ten contained slot names/PIDs or leaves `ezgha.service` inactive.

Implementation proceeds test-first in that order. Every 30 minutes must produce an executable RED or GREEN result in the active milestone. Once a failure is concrete, fix and rerun only its affected checks; do not restart design or full review. No new feature, criterion, reviewer, roadmap, memory, deployment redesign, or 24-hour monitoring work may delay the next RED-to-GREEN increment. After two complete gate cycles or three total hours without all three milestones green, stop the loop and report the exact failing command and blocker.

## Goals

- Keep exactly ten Linux runner slots; reducing capacity is not containment.
- Preserve the current host-Docker backend and existing per-container memory, CPU, swap, and PID limits.
- Bound aggregate runner memory, CPU, swap, and tasks at the host system manager.
- Bound supported agent CLI descendants and automation under separate user slices.
- Keep the desktop, user manager, and production workload roots out of `systemd-oomd` victim selection.
- Fail closed before slot mutation, JIT registration, Docker removal, or Docker creation when effective containment is invalid.
- Keep every control and activation step git-tracked and portable to another compatible Ubuntu host with at least 62 GiB `MemTotal` and 32 online logical CPUs.

## Non-Goals

- Security isolation from malicious workflow code.
- Replacing host Docker with Colima or adding a VM fallback.
- Changing the runner image, labels, JIT lifecycle, scheduling, queue cleanup, or Mac fleet.
- Adding a watchdog, pressure repair daemon, host reboot authority, automatic Docker restart, or VM/backend recovery for the fixed HostDocker profile.
- Rebuilding `install.sh` around a privileged broker or transaction protocol.
- Proving that global kernel OOM is impossible; uncapped desktop, kernel, Docker-daemon, and other system use remain residual risks.

## Resource Policy

| Aggregate | MemoryHigh | MemoryMax | MemorySwapMax | TasksMax | CPUQuota | IOWeight |
|---|---:|---:|---:|---:|---:|---:|
| system `actions.slice` | 26G | 28G | 0 | 6000 | 2000% | 25 |
| user `agents.slice` | 18G | 20G | 2G | 8192 | unchanged | unchanged |
| user `automation.slice` | 4G | 6G | 1G | 4096 | unchanged | unchanged |

Release 1 aligns the Linux example to the active 2500-MiB-per-runner config and requires exact equality at activation. Ten limits total about 24.41 GiB, below `actions.slice` `MemoryHigh=26G`. The three hard caps total 54 GiB on the measured 62.48-GiB host, leaving about 8.48 GiB outside those workload caps. Release 1 hard-refuses `MemTotal < 62 GiB` (65,011,712 KiB), preserving at least 8 GiB of arithmetic headroom above the cap sum. That remainder is headroom, not a reservation or a global-OOM proof.

The agent cap is intentionally higher than the old tracked 10G/12G unit because the measured 17.14-GiB peak would violate that old hard limit. `MemoryHigh=18G` sits about 0.86 GiB above the recorded peak and `MemoryMax=20G` about 2.86 GiB above it, while still preventing the prior 36.7-GiB agent event. Activation also requires current agent use below 18G and automation use below 4G before lowering limits.

On the measured 32-logical-CPU host, the actions quota of 2000% equals the ten existing 2-CPU container quotas, and `TasksMax=6000` is above their 5120-PID sum. Release 1 hard-refuses fewer than 32 online logical CPUs, so the 2000% aggregate runner quota cannot exceed total host capacity and the measured 12-CPU margin remains available outside it. Those aggregate values are defense against drift and aggregate overhead, not new CPU/task headroom below the already-declared per-container sum. Likewise, 28G exceeds the 24.41-GiB declared memory sum. The immediate crash-path change is the effective finite hierarchy, zero aggregate runner swap, finite agent/automation roots, and removal of broad oomd/watcher victim selection; the design does not credit the actions CPU/task numbers as a newly tighter per-job limit.

All three production workload slices set both `ManagedOOMMemoryPressure=auto` and `ManagedOOMSwap=auto`. Six tracked boundary drop-ins do the same for:

- system `-.slice`
- system `user.slice`
- dynamic system `user-.slice`
- system `user@.service`
- user-manager `app.slice`
- user-manager `session.slice`

The `user@.service` drop-in also resets `ManagedOOMPreference=none` and `OOMScoreAdjust=0`. Release 1 removes the installed and tracked `ezgha.service.d/10-oomd-omit.conf`; protecting the runner subtree with `omit` and `-1000` is the inverse of workload-local containment.

## Runtime Admission

Add one Linux HostDocker guard, `require_host_containment`, called at the fixed-Linux full-reconciliation entry and again by the shared runner-creation path before any slot reservation, pre-start removal, workspace mutation, JIT request, or Docker creation. It requires:

1. Linux with configured count exactly 10.
2. `limits.cgroup_parent = "actions.slice"`.
3. `DOCKER_HOST` and `DOCKER_CONTEXT` are unset, the resolved default endpoint is exactly `unix:///var/run/docker.sock`, and every Linux HostDocker or DockerSysbox CLI call is explicitly bound to that socket. Remote, Darwin, VM, inherited, and ambient-context endpoints are rejected.
4. Docker cgroup v2 with the `systemd` driver.
5. Effective `/sys/fs/cgroup/actions.slice` values equal the fixed profile and are not infinite.
6. Effective production managed-OOM policies are `auto`.
7. Effective `user@UID.service` is not a pressure or swap kill target and is neutral.

One endpoint-aware Rust Docker-command factory clears `DOCKER_HOST` and `DOCKER_CONTEXT` and passes `--host unix:///var/run/docker.sock` for every Linux HostDocker/DockerSysbox runtime call. This includes platform/backend discovery, reachability, `docker info`, runtime classification, pre-pull, capacity, inventory, metrics, inspect, top, removal, and run; no direct production `Command::new("docker")` remains outside the factory. OS detection and selector rejection happen before the first Docker probe, and the probe-image pre-pull moves after full containment admission. For the fixed Linux profile, admission is the first `ensure_count_outcome` reconciliation operation after profile resolution: failure returns the paused/fail-closed outcome and cooldown-governed alert before `release_stale_slots`, GitHub deregistration/cancellation, local slot or quarantine writes, cleanup, or creation. Mac and explicit-VM reconciliation ordering is unchanged. The generated service also unsets both inherited variables. The existing `docker run --cgroup-parent actions.slice` emission remains. Task 4's fixed no-argument shell bootstrap builder is the sole non-Rust Docker interface; it has one exact canonical-socket/build argv and a separate fixture. After each container starts, the existing error-compensation path is extended to inspect its PID and require `/proc/<pid>/cgroup` beneath `/actions.slice` before treating the runner as ready. Wrong ancestry removes only that just-created managed container and compensates its exact JIT transition.

The fixed Linux profile suppresses every backend lifecycle recovery call. Docker unreachability reports the existing containment/backend alert and retries passively; it never invokes `lima-vm@colima.service`, `limactl`, Colima, or a Docker restart. Generated Linux HostDocker service units have no Lima `Wants=`/`After=` dependency. Existing Mac and explicit VM profiles retain their current recovery policy.

The former one-runner Linux canary config is retired because it creates an eleventh, differently budgeted HostDocker runner outside the fixed aggregate arithmetic. `canary-once` and Gate 4 dispatch through the main ten-runner config and labels without starting a second supervisor. Nonmutating canary dispatch may load a verifier config, but any Linux `start` or `serve` config that is not the exact ten-runner profile fails before its first Docker command.

Mac and explicit VM-Docker behavior remain unchanged. The guard is mandatory only for the fixed Linux HostDocker profile.

## Tracked Artifacts

Release 1 owns this bounded set:

- `systemd/host/actions.slice`
- `systemd/host/-.slice.d/99-ezgha-containment.conf`
- `systemd/host/user.slice.d/99-ezgha-containment.conf`
- `systemd/host/user-.slice.d/99-ezgha-containment.conf`
- `systemd/host/user@.service.d/99-ezgha-containment.conf`
- `systemd/user/app.slice.d/99-ezgha-containment.conf`
- `systemd/user/session.slice.d/99-ezgha-containment.conf`
- `systemd/agents.slice`
- `systemd/automation.slice`
- deletion of `systemd/ezgha.service.d/10-oomd-omit.conf`
- `scripts/host/assert-host-containment-release1.sh`
- `scripts/host/apply-host-containment-release1.sh`
- deletion of `systemd/psi-oom-watcher.service`, `systemd/psi-oom-watcher.timer`, and `scripts/host/psi-oom-watcher.sh`
- focused Rust admission and endpoint changes in `src/config.rs`, `src/platform.rs`, `src/backend.rs`, `src/docker_backend.rs`, and `src/main.rs`
- Linux service generation changes in `src/service.rs`, including stdout-only `render-release1-service` and `render-release1-alert-service`
- Linux HostDocker delegation changes in `install.sh`
- `config/config.toml.linux.example`
- deletion of `config/config.toml.linux-canary.example`
- `tests/host_crash_containment_release1_artifacts_test.sh`
- `tests/assert_host_containment_release1_test.sh`
- `tests/apply_host_containment_release1_test.sh`
- bounded Release 1 comparison extensions in `scripts/job_outcome_monitor.py` and `tests/job_outcome_monitor_test.py`
- concise policy/docs and live verifier integration

Release 1 deletes the tracked runner OOM exemption and removes the `AGENT_SLICE_OPT_OUT` bypass for future supported CLI launches. It does not move or kill an existing interactive agent session during installation.

## Activation

Compatible Linux HostDocker has one deployment command, `./install.sh`. After local tests it uses `cargo build --release --locked`, stages a private versioned bundle containing the built binary, stdout-rendered inactive main service at `systemd/ezgha.service`, fixed policy files at their tracked relative paths, activation as bundle-root `apply-host-containment-release1.sh`, assertion as bundle-root `assert-host-containment-release1.sh`, Dockerfile, wrapper input, and the explicit Linux auxiliary closure below, then writes/verifies a source-HEAD/mode/SHA-256 manifest. It verifies the staged binary version, service `ExecStart`, exact root script manifest keys, auxiliary closure, and build context before atomically replacing a temporary symlink with `$HOME/.local/libexec/ezgha/release1`; failure leaves the prior link/unit/service untouched. This Linux branch occurs before legacy image build, `install-service`, service start/restart, live auxiliary installation, or Docker/VM action and ends with exactly one `exec` of the installed activation script. Task 5 stages but never installs/enables the closure; Task 4 alone installs the rendered files while frozen, then enables/starts the main service and converges auxiliary state only after containment proof.

The Linux auxiliary closure is allowlisted rather than glob-installed: stdout-rendered `ezgha-alert@.service`; `agents.slice`, `automation.slice`, and the three AO automation drop-ins; `agent-scoped-launch.sh`, `agent-cli-scoped.sh`, and `agent-scope-reaper.sh`; token-refresh service/timer plus `refresh_gh_app_token.sh` and `mint_gh_app_token.py`; mission-output-cleanup service/timer plus `cleanup-mission-output.sh`; queue-reaper service/timer plus `cleanup-stuck-runs.sh`; and fleet-alert service/timer plus `ezgha-fleet-alert.sh`. Activation contains the fixed future-invocation wrapper-generation logic. No PSI watcher or Linux Lima/Colima/QEMU/trim artifact is staged or required.

The installed `$HOME/.local/libexec/ezgha/release1/apply-host-containment-release1.sh` is the only Release 1 live entrypoint and invokes only the sibling bundle-root `assert-host-containment-release1.sh`. The stable bundle preserves tracked policy paths, remaps only those two scripts to the root, and includes `systemd/ezgha.service`, the auxiliary closure, `Dockerfile.runner`, and executable `docker/tar-workspace-wrapper.sh`; the exact manifest keys are `apply-host-containment-release1.sh` and `assert-host-containment-release1.sh`, both mode `0755`. The verifier rejects a missing key, wrong mode/hash, absolute or `..` key, resolved path outside `BUNDLE_ROOT`, and old `scripts/host/` production keys. The installer stages the complete bundle before delegation. Activation runs as the deploy user, rejects effective UID 0, and accepts no caller-selected unit path, build path, profile, service, or command. Its first operation is `uname -s`; any result other than exact `Linux` exits before path creation, config access, service commands, or other mutation. After that check, root invocation also exits before mutation. The fixed deployment identity is the current real/effective UID with canonical home from `getent passwd`; the script requires `HOME` to equal that home and uses `/run/user/<uid>/bus` for that user's manager. Only fixed internal `sudo -n` operations may install the enumerated system artifacts, reload the system manager, and apply/query the system `actions.slice`; all config, snapshot, intent, lock, `systemctl --user`, and user-manager work retains the deploy UID and canonical home. Release 1 does not edit sudoers: every exact system argv must already be noninteractively authorized or preflight emits `SUDOERS_PREREQUISITE_MISSING` before mutation. The sequence is:

1. Read-only preflight requires the complete canonical release bundle and manifest, including both exact root script keys, `systemd/ezgha.service`, the auxiliary closure, and the Dockerfile's relative wrapper input, plus a working deploy-user manager connection, `MemTotal >= 65,011,712 KiB`, at least 32 online logical CPUs from `/sys/devices/system/cpu/online`, no secondary Linux runner supervisor or canary service, at least 8 GiB `MemAvailable`, at most 50% swap use, memory PSI `full avg10 < 1.00`, at least 1 GiB free on the target filesystem, cgroup v2 root controllers containing `cpu`, `io`, `memory`, and `pids`, Docker systemd/cgroup-v2, and the exact socket and ten-runner/2500-MiB profile. Missing, malformed, or SHA-mismatched bundle content or host-size input fails with stable `FAIL:` output before intent or service mutation. Fleet state is either bootstrap (zero managed containers; absent/inactive actions, agent, and automation slice cgroups are recorded as zero) or in-place migration (all three slice cgroups readable, agent current below 18G, automation current below 4G, and exactly ten managed containers named `ez-runner-c-1..10` below `/actions.slice` with actions current below 26G); every partial, extra-prefix, or wrong-ancestry state fails before mutation. Before publishing intent or stopping a service, `sudo -n -l -- <exact argv>` must authorize every later enumerated system command; the activation executes those identical argument vectors and no other elevated command.
2. Acquire the fixed activation lock and atomically publish a maintenance intent containing PID and boot ID. Every `start`, `serve`, and `stop` path rejects a live intent both before and after acquiring the existing `serve.lock`; stale intent is rejected for operator recovery rather than silently removed.
3. Snapshot every replaced/removed file, prior manager state, and each managed slot's name/container ID/PID/cgroup before stopping the reconciler. In migration mode stop `ezgha.service`, then acquire and hold `serve.lock` for this activation process; in bootstrap require it already inactive. Both activation and `serve.lock` flocks are process-lifetime exclusion only and the kernel releases them on every exit. The maintenance intent is the sole durable recovery gate. Until maintenance release, activation's Docker ledger contains inventory/inspect/event reads only and no `run`, `stop`, `pause`, `rm`, `kill`, `restart`, or prune. A snapshotted ID may independently disappear because each JIT runner is ephemeral; record the departure without claiming its cause, require every survivor unchanged beneath `/actions.slice`, and reject any new managed ID while frozen. Existing graceful service shutdown may remove only registrations proven to lack a local container.
4. Install the rendered main/alert units, fixed policy units/drop-ins, and auxiliary closure; leave the exact active config unchanged. Watcher teardown first records load/active/unit-file/path/symlink state. Exact already-absent state issues no disable/stop; otherwise disable only an enabled/active timer, stop only an active service, remove known paths, reload, and require exact absence. A nonzero command is fatal only if the absent post-state is not achieved; any residual watcher retains intent and blocks service restart. Remove the unlimited agent and runner-omit drop-ins, then reload both managers. Bootstrap starts actions, agent, and automation slices; migration requires them active. Apply and verify effective CPU/IO/memory/swap/task/oomd values plus current-use thresholds before admission. Install future-invocation agent wrappers without relaunching existing sessions. The user service must have neither omit nor `-1000`.
5. Apply and verify the other slice and oomd properties. While frozen, both modes run the default read-only policy assertion; migration separately proves the live ID set is a contained subset of its snapshot with recorded departures, and bootstrap requires zero managed containers. In bootstrap only, the no-argument builder derives its fixed context from the validated bundle and executes exactly `env -u DOCKER_HOST -u DOCKER_CONTEXT DOCKER_BUILDKIT=0 docker --host unix:///var/run/docker.sock build --cgroup-parent actions.slice -f "$BUNDLE_ROOT/Dockerfile.runner" -t ezgha-runner:latest "$BUNDLE_ROOT"` after the finite actions boundary is effective. Migration requires the existing local image and does not rebuild it.
6. Remove maintenance intent and release `serve.lock` only after policy/image proof. Enable/start `ezgha.service`, then converge auxiliary state: enable token-refresh and mission-output-cleanup timers; disable/stop queue- and agent-scope-reaper timers/services; preserve prior fleet-alert enablement; require all PSI watcher state absent. Migration requires exactly the ten distinct managed slot names, no extra managed container, and ten actual PIDs beneath `/actions.slice` within 210 seconds; bootstrap uses 600 seconds. After release, IDs may churn normally and no snapshot-ID equality or departure mapping applies.

In migration, reconciler interruption is bounded by its existing 30-second systemd stop timeout plus 210 seconds for service readiness. Bootstrap has no prior reconciler to interrupt and uses the separate 600-second ten-runner convergence deadline. Runner jobs are not interrupted by this sequence.

## Failure And Recovery

- Failure before the reconciler stop or any file mutation has zero live effect.
- Snapshot failure before the reconciler stop leaves prior files unchanged and the service running.
- Failure after the reconciler stop but before the actions commit point restores exact bytes/reloads managers, deliberately leaves the service inactive with durable maintenance intent retained, and emits stable high-severity `activation_precommit_failed` with phase/recovery state; process locks release on exit and are never claimed durable.
- Once the exact runtime `actions.slice` limit is verified, it is a forward-only safety commit point: later recovery never restores that aggregate to infinity while runner containers exist.
- Failure while installing or verifying the remaining policy persists maintenance intent with boot ID, phase, and `RecoveryRequired`, leaves the service inactive, retains the finite actions boundary, and restores only files whose restoration cannot weaken that boundary; process locks release on exit.
- A stale maintenance intent or incomplete snapshot is an explicit operator-recovery state; automatic activation refuses it.
- Any failure after maintenance release, including auxiliary-state or 210-second fleet-convergence proof, emits `activation_postrelease_proof_failed` and keeps the release issue open, but does not stop, disable, or restart `ezgha.service`, mutate containers, or roll back the finite boundary; the running reconciler may continue normal ephemeral refill.
- The activation script never invokes `limactl`, starts Colima, restarts Docker, changes the physical host lifecycle, or touches Mac launchd/config/image state. It never runs wholesale under `sudo` or redirects deploy-user operations through root's home or user manager.

## Verification

The read-only assertion and exit gate require:

- Docker reports cgroup v2/systemd.
- `/proc/meminfo` `MemTotal` is at least 65,011,712 KiB and `/sys/devices/system/cpu/online` resolves to at least 32 online logical CPUs.
- root cgroup controllers include `cpu`, `io`, `memory`, and `pids`.
- the deploy-user manager answers a bounded read-only connectivity probe.
- `actions.slice`, `agents.slice`, and `automation.slice` have the exact finite values.
- all six broad boundary roots report both managed-OOM policies as `auto`.
- `user@UID.service` is neutral and not a kill target.
- no `ezgha.service` OOM exemption or unlimited agent override remains.
- no legacy PSI watcher file, active unit, or enabled timer remains.
- the frozen migration ledger proves activation preserved every then-live snapshotted ID and issued no lifecycle mutation; after release both migration and bootstrap require exactly ten contained slot names/PIDs with no extras regardless of container IDs.
- no secondary Linux `ezgha serve`, canary service, or extra `ezgha=managed` container exists.
- every managed PID is actually beneath `/actions.slice`.
- `doctor-runner` remains read-only and reports a failing containment verdict on any mismatch.
- containment admission failure emits the existing high-severity alert/journal path as well as the failing doctor verdict; fail-closed capacity loss is not silent.
- on fixed Linux, Gate 0 verifies the selected release bundle binary SHA rather than `~/.cargo/bin/ezgha`; Mac and explicit VM paths retain their existing binary check.
- immediately after activation and live containment proof, deployment records the preceding 24-hour bounded outcome baseline and the following 24-hour outcomes for the two tracked workload repos; a new exact runner-lost signature/count or any infrastructure OOM keeps the release open even when containers remain healthy. Evidence collection never stops, restarts, or rolls back the contained fleet.

The existing bounded `scripts/job_outcome_monitor.py` gains opt-in Release 1 baseline/post modes; its default six-hour sampled success-rate CLI, schema, and causally-undetermined verdict do not change. Release modes use a private injectable raw-byte `ReleaseTransport` for GET-only JSON/log calls and `LocalEvidence` for fixed boot/cgroup/journal reads; legacy `GithubApi` remains unchanged. Only Release modes fix 99 completed runs per repo, 100 total requests, and 75 seconds, while legacy defaults remain 20/50/75 and Release modes reject those override flags. They require exactly `jleechanorg/worldarchitect.ai` and `jleechanorg/ez-gh-actions`, cap each failed-job log at 2 MiB and total logs at 32 MiB, and treat any reached bound as `INCONCLUSIVE`. Population membership requires both run `created_at` and job `completed_at` in the same half-open window. Baseline captures local anchors before its first network request; post refuses before `T+24h` and fails closed on missing/truncated/repeated pages, missing logs, reboot/counter reset, or incomplete journal evidence. Versioned exact GitHub service diagnostics classify runner-loss; an actions-slice OOM counter increase or kernel OOM record classifies infrastructure OOM. Canonical JSON uses `report_kind="release1_outcome_window"` and `release_schema_version=1`; post rejects other baseline kinds/versions. Other conclusions remain causally unclassified, and legacy reports never emit the Release-only fields. This is bounded evidence for two monitored repos, not org-complete proof; evidence failure keeps the issue open but never changes the fleet.

A bounded capacity proof may show ten simultaneous `Runner.Worker` processes, but Release 1 does not add a new workflow, image, attestation scheduler, or synthetic pressure allocator.

## Deferred Release 2

The following are valid hardening work but not Release 1 prerequisites:

- privileged broker and bundle authorization
- deployment receipts, rollback state machine, and `SCM_RIGHTS` service-lock handoff
- typed effect coordinator and closed executable-effect inventory
- immutable two-platform image publisher and local image receipt
- full attestation scheduler, 100-cycle calibration, and synthetic pressure proofs
- queue/reaper architecture changes
- automated Docker cgroup-driver remediation
- Darwin candidate, image receipt, and six-runner Mac migration

Release 2 must treat an already-active Release 1 host policy as its starting state and preserve it throughout any later migration.

## Acceptance Criteria

1. Exactly ten Linux runners remain configured.
2. Live Docker is recorded as cgroup v2/systemd before activation; no daemon restart is performed.
3. Effective system `/actions.slice` matches the fixed finite profile.
4. Effective agent and automation slices match their finite profiles, with no unlimited opt-out/drop-in.
5. No production or broad desktop root is a `systemd-oomd` kill target; `user@UID.service` is neutral.
6. Every fixed-Linux runner reconciliation and creation path fails before mutation when containment is absent, infinite, or wrong.
7. Every created managed runner proves actual PID ancestry beneath `/actions.slice`.
8. Activation never starts a VM, restarts Docker, changes Mac state, stops/removes a runner container, cancels a busy job, or reduces runner count.
9. During frozen migration, activation issues no lifecycle mutation, preserves every survivor, records independent ephemeral departures, and admits no new ID; after release normal JIT ID churn is allowed while migration converges to ten contained slot names/PIDs within 210 seconds and bootstrap within 600 seconds. Either failure remains contained and explicit.
10. The implementation, stable activation bundle, rollback, assertion, documented exact sudo authorization prerequisite, and focused tests are git-tracked and reproducible on a compatible fresh Ubuntu host with at least 62 GiB RAM and 32 online logical CPUs; undersized hosts fail read-only preflight.
11. Before legacy service/image/live-auxiliary or Docker/VM actions, `install.sh` builds and verifies a versioned complete release bundle, atomically selects it, and execs activation once; only activation installs the allowlisted Linux service/auxiliary closure, converges timer state, starts the fixed service, and performs a fresh bootstrap image build after finite-boundary proof.
12. Fixed-profile startup/recovery performs no VM or backend lifecycle action, and canary proof dispatch uses the existing ten-runner fleet rather than a separate daemon.
13. A bounded 24-hour post-activation report for the two tracked workload repos shows no new exact runner-lost signature/count and local evidence shows no infrastructure OOM relative to baseline; the deployment issue closes only on a passing verdict and remains open on failure or `INCONCLUSIVE`.
