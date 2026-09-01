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
- `automation.slice` is finite at `MemoryHigh=4G`, `MemoryMax=6G`, and `MemorySwapMax=1G`.
- `user@1000.service` is an active `systemd-oomd` pressure target with `ManagedOOMMemoryPressure=kill`, a 2-GiB pressure limit, `OOMScoreAdjust=100`, and no tracked local override.

No Docker daemon restart is needed on this host. A different host whose Docker daemon is not cgroup v2/systemd fails Release 1 preflight and requires a separately reviewed maintenance change.

## Release 1 Decision

Release 1 fixes only the immediate crash path:

1. Make the existing host `/actions.slice` finite.
2. Make agent and automation aggregates finite.
3. Remove broad production and desktop `systemd-oomd` kill roots.
4. Refuse every new Linux runner creation when the host boundary is missing, infinite, or wrong.
5. Activate the policy in place, with runner mutations frozen, and prove all ten existing runners remain inside it.

This release does not redesign deployment security. Root brokers, bundle authorization, descriptor handoff, immutable image publishing, typed effect frameworks, Mac receipts, queue refactors, and attestation calibration are deferred. They must not delay the finite host boundary.

## Goals

- Keep exactly ten Linux runner slots; reducing capacity is not containment.
- Preserve the current host-Docker backend and existing per-container memory, CPU, swap, and PID limits.
- Bound aggregate runner memory, CPU, swap, and tasks at the host system manager.
- Bound supported agent CLI descendants and automation under separate user slices.
- Keep the desktop, user manager, and production workload roots out of `systemd-oomd` victim selection.
- Fail closed before slot mutation, JIT registration, Docker removal, or Docker creation when effective containment is invalid.
- Keep every control and activation step git-tracked and portable to another compatible Ubuntu host.

## Non-Goals

- Security isolation from malicious workflow code.
- Replacing host Docker with Colima or adding a VM fallback.
- Changing the runner image, labels, JIT lifecycle, scheduling, queue cleanup, or Mac fleet.
- Adding a watchdog, pressure repair daemon, host reboot authority, or automatic Docker restart.
- Rebuilding `install.sh` around a privileged broker or transaction protocol.
- Proving that global kernel OOM is impossible; uncapped desktop, kernel, Docker-daemon, and other system use remain residual risks.

## Resource Policy

| Aggregate | MemoryHigh | MemoryMax | MemorySwapMax | TasksMax | CPUQuota | IOWeight |
|---|---:|---:|---:|---:|---:|---:|
| system `actions.slice` | 26G | 28G | 0 | 6000 | 2000% | 25 |
| user `agents.slice` | 18G | 20G | 2G | 8192 | unchanged | unchanged |
| user `automation.slice` | 4G | 6G | 1G | 4096 | unchanged | unchanged |

Release 1 aligns the Linux example to the active 2500-MiB-per-runner config and requires exact equality at activation. Ten limits total about 24.41 GiB, below `actions.slice` `MemoryHigh=26G`. The three hard caps total 54 GiB on the measured 62.48-GiB host, leaving about 8.48 GiB outside those workload caps. That remainder is headroom, not a reservation or a global-OOM proof.

All three production workload slices set both `ManagedOOMMemoryPressure=auto` and `ManagedOOMSwap=auto`. Six tracked boundary drop-ins do the same for:

- system `-.slice`
- system `user.slice`
- dynamic system `user-.slice`
- system `user@.service`
- user-manager `app.slice`
- user-manager `session.slice`

The `user@.service` drop-in also resets `ManagedOOMPreference=none` and `OOMScoreAdjust=0`. Release 1 removes the installed and tracked `ezgha.service.d/10-oomd-omit.conf`; protecting the runner subtree with `omit` and `-1000` is the inverse of workload-local containment.

## Runtime Admission

Add one Linux HostDocker guard, `require_host_containment`, called by the shared runner-creation path before any slot reservation, pre-start removal, workspace mutation, JIT request, or Docker creation. It requires:

1. Linux with configured count exactly 10.
2. `limits.cgroup_parent = "actions.slice"`.
3. `DOCKER_HOST` and `DOCKER_CONTEXT` are unset, the resolved default endpoint is exactly `unix:///var/run/docker.sock`, and every later Linux HostDocker CLI call is explicitly bound to that socket. Remote, Darwin, VM, inherited, and ambient-context endpoints are rejected.
4. Docker cgroup v2 with the `systemd` driver.
5. Effective `/sys/fs/cgroup/actions.slice` values equal the fixed profile and are not infinite.
6. Effective production managed-OOM policies are `auto`.
7. Effective `user@UID.service` is not a pressure or swap kill target and is neutral.

The Linux HostDocker Docker-command factory clears `DOCKER_HOST` and `DOCKER_CONTEXT` and passes `--host unix:///var/run/docker.sock` for every inventory, removal, inspect, top, and run call; the generated service also unsets both inherited variables. The existing `docker run --cgroup-parent actions.slice` emission remains. After each container starts, the existing error-compensation path is extended to inspect its PID and require `/proc/<pid>/cgroup` beneath `/actions.slice` before treating the runner as ready. Wrong ancestry removes only that just-created managed container and compensates its exact JIT transition.

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
- focused Rust admission changes in `src/config.rs`, `src/docker_backend.rs`, and `src/main.rs`
- Linux service generation changes in `src/service.rs`
- `config/config.toml.linux.example`
- `tests/host_crash_containment_release1_artifacts_test.sh`
- `tests/assert_host_containment_release1_test.sh`
- `tests/apply_host_containment_release1_test.sh`
- concise policy/docs and live verifier integration

Release 1 deletes the tracked runner OOM exemption and removes the `AGENT_SLICE_OPT_OUT` bypass for future supported CLI launches. It does not move or kill an existing interactive agent session during installation.

## Activation

`scripts/host/apply-host-containment-release1.sh` is the only Release 1 live entrypoint. It runs as the deploy user, rejects effective UID 0, and accepts no caller-selected unit path, profile, service, or command. Its first operation is `uname -s`; any result other than exact `Linux` exits before path creation, config access, service commands, or other mutation. After that check, root invocation also exits before mutation. The fixed deployment identity is the current real/effective UID with canonical home from `getent passwd`; the script requires `HOME` to equal that home and uses `/run/user/<uid>/bus` for that user's manager. Only fixed internal `sudo -n` operations may install the enumerated system artifacts, reload the system manager, and apply/query the system `actions.slice`; all config, snapshot, intent, lock, `systemctl --user`, and user-manager work retains the deploy UID and canonical home. The sequence is:

1. Read-only preflight requires at least 8 GiB `MemAvailable`, at most 50% swap use, memory PSI `full avg10 < 1.00`, at least 1 GiB free on the target filesystem, Docker systemd/cgroup-v2, and the exact socket and ten-runner/2500-MiB profile. Fleet state is either bootstrap (zero managed containers and an absent or empty `actions.slice`) or in-place migration (exactly ten, all below `/actions.slice`, with `actions.slice/memory.current < 26G`); every partial or wrong-ancestry state fails before mutation. Before publishing intent or stopping a service, `sudo -n -l -- <exact argv>` must authorize every later enumerated system command; the activation executes those identical argument vectors and no other elevated command.
2. Acquire the fixed activation lock and atomically publish a maintenance intent containing PID and boot ID. Every `start`, `serve`, and `stop` path rejects a live intent both before and after acquiring the existing `serve.lock`; stale intent is rejected for operator recovery rather than silently removed.
3. Snapshot every replaced/removed file and prior manager state before stopping the reconciler. In migration mode stop `ezgha.service`, then acquire and retain `serve.lock` for the remaining policy mutation. In bootstrap mode require it already inactive and acquire the lock. Do not stop, remove, pause, recreate, or deregister any runner container; migration jobs continue inside Docker. Existing graceful service shutdown may remove only registrations already proven to have no local container, which does not affect the ten snapshotted containers or their jobs.
4. Install the fixed tracked units/drop-ins, leave the already-exact active config unchanged, remove `<deploy-home>/.config/systemd/user/agents.slice.d/99-local-unlimited.conf` and `<deploy-home>/.config/systemd/user/ezgha.service.d/10-oomd-omit.conf`, and reload both managers. In bootstrap, run the enumerated `sudo -n systemctl start actions.slice` after the unit is installed; in migration it is already active. Apply the exact `actions.slice` properties and verify the live cgroup before any runner admission or later step. The user-manager assertion requires `ezgha.service` to report neither `ManagedOOMPreference=omit` nor `OOMScoreAdjust=-1000`.
5. Apply and verify the other slice and oomd properties. Run the read-only assertion with its ten-container check while `serve.lock` and maintenance intent still exclude runner mutations.
6. Remove the maintenance intent and release `serve.lock` only after the policy assertion passes. Start `ezgha.service` and require readiness within 210 seconds. Migration mode repeats the assertion against the same ten container IDs; bootstrap mode requires exactly ten newly admitted contained containers within 600 seconds.

The reconciler interruption is bounded by its existing 30-second systemd stop timeout plus 210 seconds for service readiness. Runner jobs are not interrupted by this sequence.

## Failure And Recovery

- Failure before the reconciler stop or any file mutation has zero live effect.
- Snapshot failure leaves prior files unchanged and the service running.
- Once the exact runtime `actions.slice` limit is verified, it is a forward-only safety commit point: later recovery never restores that aggregate to infinity while runner containers exist.
- Failure while installing or verifying the remaining policy keeps `serve.lock` and maintenance intent, leaves the service inactive, retains the finite actions boundary, records `RecoveryRequired`, and restores only files whose restoration cannot weaken that boundary.
- A stale maintenance intent or incomplete snapshot is an explicit operator-recovery state; automatic activation refuses it.
- Failure to restart the reconciler within 210 seconds is a failed release, not a containment success. Existing containers remain inside the finite boundary while the service issue is diagnosed.
- The activation script never invokes `limactl`, starts Colima, restarts Docker, changes the physical host lifecycle, or touches Mac launchd/config/image state. It never runs wholesale under `sudo` or redirects deploy-user operations through root's home or user manager.

## Verification

The read-only assertion and exit gate require:

- Docker reports cgroup v2/systemd.
- `actions.slice`, `agents.slice`, and `automation.slice` have the exact finite values.
- all six broad boundary roots report both managed-OOM policies as `auto`.
- `user@UID.service` is neutral and not a kill target.
- no `ezgha.service` OOM exemption or unlimited agent override remains.
- migration preserves the same ten managed Linux container IDs; bootstrap starts from zero and converges to exactly ten.
- every managed PID is actually beneath `/actions.slice`.
- `doctor-runner` remains read-only and reports a failing containment verdict on any mismatch.

A bounded capacity proof may show ten simultaneous `Runner.Worker` processes, but Release 1 does not add a new workflow, image, attestation scheduler, or synthetic pressure allocator.

## Deferred Release 2

The following are valid hardening work but not Release 1 prerequisites:

- privileged broker and bundle authorization
- deployment receipts, rollback state machine, and `SCM_RIGHTS` service-lock handoff
- typed effect coordinator and closed executable-effect inventory
- immutable two-platform image publisher and local image receipt
- full attestation scheduler, 100-cycle calibration, synthetic pressure proofs, and job-outcome comparison
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
6. Every Linux runner-creation path fails before mutation when containment is absent, infinite, or wrong.
7. Every created managed runner proves actual PID ancestry beneath `/actions.slice`.
8. Activation never starts a VM, restarts Docker, changes Mac state, stops/removes a runner container, cancels a busy job, or reduces runner count.
9. Migration preserves all ten existing containers; fresh bootstrap converges from zero to ten within 600 seconds. Either failure remains contained and explicit.
10. The implementation, activation, rollback, assertion, docs, and focused tests are git-tracked and reproducible on a compatible fresh Ubuntu host.
