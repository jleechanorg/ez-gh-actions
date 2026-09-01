# Runner Crash Containment Design

**Date:** 2026-08-31
**Status:** Revised after second `/advice` review; implementation not started
**Primary goal:** Keep the physical Ubuntu host, desktop session, Warp, and operator tools responsive while ten Linux GitHub Actions runners execute concurrently.

## Problem Statement

The production fleet currently runs ten runner containers through the host Docker daemon. Each container has a finite memory, CPU, and PID limit, but the shared host `actions.slice` has infinite aggregate limits. The tracked finite `actions.slice` is installed only inside Colima, so it does not constrain host-Docker containers. At the same time, a local `agents.slice` drop-in overrides the tracked finite values with infinity, while Ubuntu's vendor `user@.service` policy monitors the entire user manager for memory pressure.

That topology inverts the intended failure order. During runner refill bursts, `systemd-oomd` can kill the deploy owner's `user@UID.service`, taking Warp, tmux, Codex, and the desktop session together, while the runner aggregate remains unbounded. Colima is not the root requirement: the availability requirement is that lower-priority workloads fail before the operator session and physical host.

## Goals

1. Keep exactly ten Linux runner slots configured and available; reducing runner count is not an accepted containment mechanism.
2. Make runner memory, CPU, swap, and process use finite in one host-level aggregate in addition to existing per-container limits.
3. Make interactive agent and automation aggregates finite so they cannot consume the host reserve.
4. Ensure runner and agent pressure is handled inside explicit workload roots while the desktop user manager is not a direct `systemd-oomd` monitoring root.
5. Refuse new runner admission when required containment is missing or infinite.
6. Keep every production control, installer, verifier, and policy statement git-tracked and portable to a fresh Ubuntu machine.
7. Preserve operator-only authority over physical-host reboot, shutdown, VM teardown, and other broad lifecycle actions.

## Non-Goals

- Containing deliberately malicious workflow code or kernel exploits. Host Docker shares the host kernel and is accepted for this trusted-workload threat model.
- Making Colima a required Linux backend.
- Adding another watchdog, polling daemon, or automatic host/VM restart loop.
- Reducing the ten-runner Linux capacity contract.
- Reworking runner registration, GitHub API reconciliation, or per-job lifecycle behavior.

## Assumptions and Recommended Defaults

| Question considered | Auto-picked answer | Rationale |
|---|---|---|
| Is the primary threat malicious workflow code or resource exhaustion? | Resource exhaustion and host responsiveness. | The operator explicitly prioritized crash containment over security isolation. |
| Must Linux use Colima? | No; use host Docker when its resource envelope is proven. | Colima adds QEMU memory and KVM boot failure modes without replacing the need for host cgroups. |
| May containment reduce runner count? | No; retain ten Linux runners. | Ten runners are an explicit capacity requirement. |
| What should die first under runner pressure? | An eligible descendant of the monitored runner root; the desktop user manager is not a direct pressure target. | `systemd-oomd` selects within each monitored root, so the design guarantees workload-local candidate selection but does not claim a total order across independent runner, agent, and automation roots. |
| How much host RAM remains outside hard workload caps? | Budget about 8.8 GiB on the 62.8 GiB host. | `actions.slice` 28 GiB + `agents.slice` 20 GiB + `automation.slice` 6 GiB = 54 GiB. This is headroom for uncapped desktop, kernel, Docker, and system use, not a proof that global OOM is impossible. |
| What initial runner aggregate limits apply? | `MemoryHigh=26G`, `MemoryMax=28G`, `MemorySwapMax=0`, `TasksMax=6000`, `CPUQuota=2000%`. | Ten 2500-MiB container limits total about 24.4 GiB, so 26 GiB avoids permanent reclaim at full declared capacity. Ten 2-CPU container limits total 20 CPUs, so the aggregate quota preserves the declared fleet sum while reserving 12 of 32 logical CPUs for the host. |
| Does this lower the live per-runner memory limit? | No; Jeff-Ubuntu already has `count=10`, `runner_floor_mb=2500`, and `limits.memory_mb=2500`. | The tracked Linux example still says 3000 MiB. Aligning it to the deployed 2500-MiB profile changes the fresh-machine default by 16.7%, so the release gate records job outcomes and refuses to silently lower any live host that differs. |
| What initial agent aggregate limits apply? | `MemoryHigh=18G`, `MemoryMax=20G`, `MemorySwapMax=2G`, `TasksMax=8192`. | Fresh read-only cgroup evidence was about 16.3 GiB current and 17.1 GiB peak, with about 1.1 GiB anon+kernel and most of the remainder reclaimable file cache. The high boundary preserves the required 1-GiB margin against enforced current usage; the hard cap prevents another 36.7-GiB single-agent event. |
| What host hardware may use this fixed profile? | At least 62 GiB RAM and 32 logical CPUs. | The numeric budgets are sized for the current 62.8-GiB, 32-thread host; a smaller machine must fail closed until it has a reviewed profile. |
| How is runner I/O contained portably? | `IOWeight=25` when the cgroup I/O controller is available; no guessed bandwidth cap. | Relative weight preserves interactive priority without hard-coding a device-specific throughput value. |
| Should an unavailable Colima VM fall back to host Docker? | Backend selection may use host Docker only when host containment passes; missing containment must fail closed. | Availability must not be restored by silently deleting the resource boundary. |
| Should another monitor repair failures? | No. | Previous monitors and watchdogs created competing mutation paths; installation, startup preflight, and verification are sufficient. |
| How broad should this change be? | Policy, systemd artifacts, one assertion/installer path, and existing diagnostics only. | This is the smallest scope that makes the live boundary tracked and enforceable; no runner scheduler, registration, or Rust backend rewrite is planned unless a failing test proves it necessary. |
| How should implementation be parallelized? | Parallelize disjoint policy, systemd, preflight, and verifier lanes; use one integration owner for shared installer and final deployment. | This follows `/parallel` while preserving single-writer ownership of the live fleet and shared files. |

## Approaches Considered

### 1. Host Docker with a fail-closed host resource envelope (recommended)

Keep the existing host Docker execution path. Add a real system-level `actions.slice`, directly enroll workload slices with `systemd-oomd`, disable broad monitoring of `user@.service`, and require a startup preflight before runner admission.

This has the fewest runtime layers, avoids QEMU overhead, and directly fixes the observed failure: unbounded workload aggregates combined with a desktop-wide OOM target. It does not provide a separate kernel security boundary, which is outside this design's threat model.

### 2. Colima-only Linux runners

Repair `/dev/kvm` boot ordering, converge the legacy and canonical Colima profiles, remove writable host-home mounts, size QEMU, and run Docker inside the VM. This provides a stronger security boundary, but QEMU remains a large host process requiring the same cgroup/OOM policy. It also introduces VM boot, disk, socket, and lifecycle failure modes that do not advance the primary crash-containment goal.

### 3. Colima primary with host-Docker fallback

Prefer Colima but silently switch to host Docker when the VM is unavailable. This is rejected. The August 27 host-Docker drop-in was created immediately after repeated Colima failures and bypassed the only tracked aggregate limit. A topology-changing fallback makes the active safety contract unknowable during an incident.

## Architecture

### Resource hierarchy

The host uses three workload aggregates with non-overlapping ownership:

```text
-.slice
├── actions.slice                 system scope, Docker container scopes
│   └── docker-*.scope            one ephemeral runner per scope
├── ezghaproof.slice              system scope, synthetic proofs only
│   ├── ezghaproof-hardlimit.slice
│   └── ezghaproof-oomd.slice
├── user.slice
│   └── user-1000.slice
│       └── user@UID.service
│           ├── agents.slice      interactive coding agents and descendants
│           ├── automation.slice  AO and factory daemons
│           ├── app.slice         Warp and desktop applications
│           └── session.slice     GNOME session services
└── system.slice                  Docker daemon and host services
```

`actions.slice` is a root-owned system slice because Docker creates container scopes through the system manager. Installing a user-scoped unit with the same name does not constrain those scopes and is forbidden as evidence of containment.

### OOM ownership

- `actions.slice`, `agents.slice`, and `automation.slice` set `ManagedOOMMemoryPressure=kill` with an explicit 50% pressure limit.
- Tracked system drop-ins force both `ManagedOOMMemoryPressure=auto` and `ManagedOOMSwap=auto` on `-.slice` and Ubuntu's vendor `user@.service` default. This prevents either a broad root or the whole desktop user manager from becoming a pressure or swap monitoring root through vendor policy.
- Hard `MemoryMax` limits remain the deterministic last boundary even if `systemd-oomd` is unavailable or slow.
- No workload receives `OOMScoreAdjust=-1000`. Protected workload exemptions invert the intended kill order and are removed from the host-Docker topology.
- Supported agent launchers have no environment escape hatch around `agents.slice`; every detected supported agent CLI process must be a descendant of the finite aggregate before deployment proceeds. Existing unscoped processes are reported and allowed to exit or be relaunched, never killed automatically.
- Independent monitored roots have no global priority order. The contract is local: an `actions.slice` pressure action chooses an eligible runner descendant, while agent and automation pressure is handled inside their own roots.
- `MemorySwapMax=0` prevents runner swap thrash but can make pressure rise faster than `systemd-oomd` reacts. Kernel hard limits are therefore the final containment mechanism, not a claim of deterministic oomd timing.

### Backend topology

Host Docker at `unix:///var/run/docker.sock` is an allowed production backend. It is not described as VM-contained. One endpoint-aware `BackendTopology` classifier, owned by `src/backend.rs` and exposed as structured `ezgha topology --json`, combines the normalized configured endpoint with Docker daemon metadata: the canonical host socket plus a same-kernel Linux daemon is `HostDocker`; a recognized explicit Colima, Lima, or Docker Desktop socket plus VM daemon metadata is `VmDocker`; contradictory metadata, remote endpoints, and unknown sockets are `Indeterminate`. `Platform.daemon_in_vm` is only one metadata input and is never the classifier by itself. Shell gates consume the structured Rust result and do not duplicate the endpoint decision table. A Linux install/start gate rejects `Indeterminate`, while existing Mac and pre-existing runtime paths preserve their non-fatal warning/no-op behavior. The generated unit always persists the classifier's explicit endpoint, including `unix:///var/run/docker.sock`, and clears inherited `DOCKER_CONTEXT`; Rust Docker subprocesses use the same endpoint and remove `DOCKER_CONTEXT`. The generated Linux service has no unconditional `lima-vm@colima.service` dependency, and backend recovery must never start Lima for `HostDocker`. `VmDocker` may use the existing bounded VM recovery path. An inactive legacy Lima unit may be disabled after the backend endpoint is proven; no VM disk is deleted.

For the `HostDocker` branch, the service may start only after the containment preflight establishes all of the following; `VmDocker` reports this host profile as not applicable and proceeds only through its separate VM gate:

1. The configured endpoint is exactly the canonical host socket, not a Colima/Lima or remote endpoint.
2. Docker reports cgroup v2 with the `systemd` cgroup driver.
3. The configured cgroup parent is `actions.slice`.
4. `/sys/fs/cgroup/actions.slice` exists under the system manager.
5. Its memory, swap, CPU, and task limits exactly match the declared fixed profile.
6. `actions.slice` is enrolled for memory-pressure handling.
7. The deploy owner's `user@UID.service` is not actively monitored for memory pressure or swap and no ancestor is enrolled with `kill` for either policy.
8. The tracked finite `agents.slice` is effective and no unlimited local override is active.
9. Neither the installed `ezgha.service.d/10-oomd-omit.conf` nor its effective `ManagedOOMPreference=omit`/`OOMScoreAdjust=-1000` remains.
10. Unprivileged bounded `oomctl` queries work and list the intended workload roots, including effective user-manager `agents.slice` and `automation.slice` enrollment.
11. The host has at least 62 GiB RAM and 32 logical CPUs; this fixed hardware profile is rejected on a smaller machine instead of silently consuming its reserve.

Any failed invariant blocks new runner admission and emits a diagnostic naming the mismatched property. It does not restart Docker, Colima, the desktop, or the physical host.

## Components and Ownership

### Repository policy

`CLAUDE.md` owns the full crash-containment tenet. `AGENTS.md` contains a concise pointer because both files exist independently. `README.md` describes the user-visible topology accurately and stops claiming that Jeff-Ubuntu runners are inside Colima when host Docker is active. `/up` writes a short receipt under `roadmap/`.

### System policy artifacts

`systemd/host/actions.slice` owns the host runner aggregate. A separate top-level `systemd/host/ezghaproof.slice` contains `ezghaproof-hardlimit.slice` and `ezghaproof-oomd.slice`, so a synthetic proof is never a descendant of the monitored production runner root. Fixed root-owned `ezgha-hard-limit-proof.service` and `ezgha-oomd-proof.service` units are the only proof launchers; they use a repository-owned Python-stdlib allocator, have no Docker socket or credentials, and cannot accept an arbitrary command. Hard-limit mode deliberately exceeds its child `MemoryMax`. Oomd mode allocates and continuously touches an anonymous working set above its child `MemoryHigh` but below `MemoryMax` for 75 seconds. Because systemd exposes pressure duration only as the global `DefaultMemoryPressureDurationSec`, the harness reads and records the effective merged oomd configuration, rejects a missing/unparseable duration or one above 45 seconds, and requires the child's exact `memory.pressure` `full avg10` value to stay at least 20% continuously for that duration before accepting a correctly named journal victim. Allocator exit without both the continuous measured interval and victim never passes. The proof harness uses privileged `systemctl` only with those literal unit names and never permits `systemd-run` or a shell. `systemd/host/-.slice.d/90-ezgha-oomd-boundary.conf` and `systemd/host/user@.service.d/90-ezgha-oomd-boundary.conf` own the broad vendor-policy overrides. Existing `systemd/agents.slice` and `systemd/automation.slice` own user workload limits.

### Installation

`scripts/host/install-crash-containment.sh` installs and verifies system-scope artifacts with explicit privilege escalation. It supports a read-only capability/current-use `--preflight`, a read-only installed-state `--check`, and an applying `--install` mode. `install.sh` invokes the installer on systemd Linux hosts and fails rather than claiming success when the configured host-Docker fleet lacks the required system controls.

After an allowed local candidate build, but before image acquisition or any Docker/live mutation, installation proves endpoint/daemon topology, Docker cgroup v2 with the `systemd` driver, hardware capacity, unprivileged `oomctl` access, required privilege, current runtime-cgroup usage, and sufficient rollback storage. Indeterminate Linux hosts exit without building/pulling images or changing Docker, the generated service, config, helpers, or live limits. The supported portable target is a fresh systemd Ubuntu host meeting the declared 62-GiB/32-CPU profile; scaled profiles are a separate reviewed design, not an implicit fallback.

Installation removes the known `agents.slice.d/99-local-unlimited.conf` drift file and the live `~/.config/systemd/user/ezgha.service.d/10-oomd-omit.conf`, disables and removes the obsolete `psi-oom-watcher` service/timer plus its installed stable script, and reloads the appropriate managers without restarting the desktop or physical host. It verifies the exemption's unit configuration is gone before restart, then verifies the new MainPID's `/proc/<pid>/oom_score_adj` and effective properties after restart. Before lowering an active hard limit, it records `memory.current` and `memory.stat` for the actual system and user cgroups, but uses the enforceable `memory.current` value without discounting file cache to prove use fits below the proposed `MemoryHigh` with a workload-specific activation margin: 1 GiB for actions, 1 GiB for agents, and 512 MiB for automation; otherwise it leaves the live policy unchanged and fails. The actions margin permits the declared ten-container maximum of about 24.4 GiB below `MemoryHigh=26G`. The single `install.sh` transaction snapshots the live config, all replaced system/user policy and helper files, the generated `ezgha.service`, the legacy watcher service/timer/stable script, the live exemption, and prior active/enabled state for every affected unit. It atomically installs a mode-`0600` proposed config only after preflight. Any config, containment, assertion, service regeneration, restart, or post-start verification failure restores every file byte-for-byte, reloads both managers, restores enabled/disabled and active/inactive state, and verifies the effective restored state before returning failure. It installs only persistent tracked units and never creates overriding `systemctl set-property` drop-ins. It never deletes VM data.

### Startup preflight

`scripts/host/assert-crash-containment.sh` is a read-only executable installed under `~/.local/libexec/ezgha/`. The generated `ezgha.service` uses a tracked startup wrapper as its main `ExecStart`, passing the exact binary path returned by `current_exe()` and the exact config path: it runs the assertion, exits `78` for a proven policy violation, returns the assertion's transient exit `75`, and `exec`s the real `ezgha serve` process after success. The assertion itself performs three Docker queries over at most 15 seconds; with `RestartSec=30`, five failed starts fit inside the preserved `StartLimitIntervalSec=300`/`StartLimitBurst=5` window and then stop. `RestartPreventExitStatus=78` applies to the main process, and `TimeoutStartSec=150` bounds the 15-second assertion plus the daemon's existing 120-second readiness window. Backend classification uses the configured Docker endpoint plus daemon metadata, not kernel-version comparison alone. Host Docker requires the host profile above; VM Docker reports that this particular preflight is not applicable and leaves VM-specific verification to a mutually exclusive VM gate. Installed helper digests must match the tracked sources.

The assertion returns distinct statuses for a proven policy violation and a transient inability to query Docker. The generated service permits recovery from a short transient failure within its existing bounded start window, while a proven policy violation remains fail-closed and clearly logged. This is normal service recovery, not a second repair daemon and never mutates containment policy.

### Verification

`docs/verify-exit-criteria.sh` verifies effective values rather than file presence. Host-Docker and Colima gates are mutually exclusive: the host path checks the system `actions.slice`, the `systemd` Docker cgroup driver, actual cgroup ancestry for every managed container, user workload caps, the `user@` OOM policy and ancestors, effective `oomctl` roots, and the absence of unlimited/runtime overrides and `ezgha.service` OOM exemptions. It does not include an inactive Lima slice in host-Docker budget arithmetic or require a live guest. `doctor-runner` reports the same topology without mutating it.

## Data Flow

1. `install.sh` may build the exact local candidate binary, then runs the immutable topology/capability/current-usage preflight before image acquisition, endpoint recovery, or any Docker/live mutation; only a successful preflight permits image work and transaction snapshots.
2. The host containment installer copies tracked units and the root-owned proof allocator to their system and user destinations, atomically retires the old watcher and both source/live exemption state, reloads managers, and checks effective properties including `oomctl` roots.
3. Only after containment is effective, `ezgha install-service` regenerates the active user unit with the exact binary, config, startup gate, and normalized endpoint. The startup wrapper runs the read-only preflight and then replaces itself with `ezgha serve`; any failure restores the prior unit and active state together with the containment transaction.
4. The endpoint-aware topology enum controls budgeting: `HostDocker` ignores VM-only guest-reserve fields and delegates the aggregate ceiling to system `actions.slice`; `VmDocker` retains the existing guest reserve and VM envelope; `Indeterminate` is rejected by new Linux install/start gates while preserving the existing non-fatal Mac/runtime path.
5. `ezgha` creates each runner with `--cgroup-parent=actions.slice` plus per-container memory, CPU, PID, swap, and security limits.
6. The system manager accounts every runner beneath the finite aggregate.
7. Under ordinary pressure, `MemoryHigh` throttles and reclaims workload memory.
8. Under sustained pressure, `systemd-oomd` may kill an eligible descendant of that monitored workload root; at the hard boundary, the kernel enforces `MemoryMax` within the limited cgroup.
9. Separate hard-limit, oomd-selection, ten-worker execution, and live desktop-survival proofs record what actually happened instead of inferring behavior from configuration.

## Residual Risks

- The 8.8-GiB remainder is not reserved memory. Docker, the kernel, desktop applications, and other system services remain outside the three hard caps and can still trigger global kernel OOM.
- Independent oomd monitoring roots do not provide a global runner-before-agent order. Each root selects only among its own eligible descendants.
- `MemorySwapMax=0` avoids runner swap thrash but reduces the time available for PSI-based oomd action during an abrupt allocation burst; `MemoryMax` is the final boundary.
- `CPUQuota=2000%` equals the ten configured 2-CPU container maxima and reserves 12 of 32 logical CPUs for the host; the capacity proof still checks real ten-job execution.
- Portable block-device bandwidth caps require a measured device baseline. `IOWeight=25` gives runner I/O lower relative priority where the controller is available; the verifier reports unavailable controllers rather than asserting protection.

## Failure Handling

| Failure | Required behavior |
|---|---|
| Host `actions.slice` missing or infinite | The main startup wrapper exits `78`; no new runners start and systemd does not restart the policy violation. |
| Docker query is temporarily unavailable | The assertion retries for at most 15 seconds and returns `75`; normal service restart retries at 30-second intervals and the existing five-start/300-second limiter stops a persistent outage. No separate timer or daemon is created. |
| One runner exceeds its limit | The cgroup-local OOM is contained to that runner scope. Whole-container exit is claimed only when effective `memory.oom.group` or observed exit behavior proves it. |
| Runner aggregate exceeds `MemoryHigh` | Reclaim/throttle occurs inside `actions.slice`. |
| Sustained runner pressure | An eligible runner descendant is selected within `actions.slice`; no cross-root runner-before-agent order is claimed. |
| Agent aggregate exceeds its envelope | Pressure handling remains within `agents.slice`; desktop survival is a live integration result, not a static guarantee. |
| `systemd-oomd` inactive | Hard cgroup limits still contain workloads; verifier reports degraded defense in depth. |
| Host Docker selected while Lima unit is enabled | Verification fails with topology drift; installation may disable an already inactive Lima unit but never stops a live VM automatically. |
| System privilege, topology, driver, hardware, or `oomctl` preflight unavailable | Installation fails before mutation with the exact unmet prerequisite; it does not deploy a falsely green user-only approximation or restart the fleet. |
| Post-mutation verification or gated restart fails | Restore system/user policy, helper files, the previous generated service, retired watcher/exemption files, and every prior active/enabled state; verify the rollback before returning failure. |
| Pressure proof harms the desktop or host | Test fails immediately and blocks deployment; no threshold is accepted from synthetic unit tests alone. |

## Testing Strategy

### Static and fixture tests

- Validate systemd unit syntax with `systemd-analyze verify`.
- Test the installer in a temporary root with stubbed `systemctl`, `sudo`, Docker endpoint, and cgroup files.
- Cover host Docker, VM Docker, contradictory endpoint/daemon metadata, missing slice, infinite limit, wrong cgroup parent, inaccessible `oomctl`, vendor user OOM policy still active, unlimited agent override, an unscoped supported agent PID, any `AGENT_SLICE_OPT_OUT` path, and a live `ezgha.service` OOM exemption.
- Verify generated service/drop-in installation and removal behavior without touching the live fleet.
- Verify README, `CLAUDE.md`, and `AGENTS.md` contain one canonical semantic rule plus pointers rather than duplicated policy bodies.

### Integration checks

- Run Rust tests and focused shell tests.
- Run the containment assertion against the live host before restarting `ezgha`.
- After deployment, dispatch `capacity-proof.yml` with the confirmed live Linux-primary label intersection `[self-hosted, self-hosted-mikey, ezgha, ez-runner-c]` and prove ten managed containers simultaneously run `Runner.Worker` under `actions.slice`; idle slot presence or a workflow scheduled to a different fleet is not capacity proof.
- Record actual cgroup paths and `memory.oom.group` for all managed containers.
- Run separately labeled checks: a bounded `ezghaproof-hardlimit.slice` `MemoryMax` test, an isolated `ezghaproof-oomd.slice` `systemd-oomd` PSI/victim-selection test, an exact-run-ID ten-worker execution proof using direct `docker top`, and a host/desktop survival observation. None substitutes for another. Both synthetic tests use only fixed tracked system services and verify production runner scopes are outside the proof subtree before allocation.
- Record host and user-manager boot IDs/PIDs before and after live proofs. The desktop, Warp, user manager, Docker daemon, and unrelated runner slots must remain alive.
- Run `doctor-runner` and the exit-criteria harness. Fleet capacity remains ten Linux runners; full job execution proof follows the repository's existing capacity gate.

## Acceptance Criteria

1. Host Docker is explicitly reported and accepted as the Linux production backend.
2. Ten Linux runners remain configured; every live runner container is under system `/actions.slice`.
3. Docker uses cgroup v2 with the `systemd` driver; effective runner aggregate limits are `MemoryHigh=26G`, `MemoryMax=28G`, `MemorySwapMax=0`, `TasksMax=6000`, `CPUQuota=2000%`, and `IOWeight=25` where the I/O controller is available.
4. Effective agent aggregate limits are `MemoryHigh=18G`, `MemoryMax=20G`, `MemorySwapMax=2G`, and `TasksMax=8192`; no unlimited override or launcher opt-out remains, and every detected supported agent PID is beneath the slice.
5. Effective automation aggregate limits remain `MemoryHigh=4G`, `MemoryMax=6G`, `MemorySwapMax=1G`, and `TasksMax=4096`.
6. Gate 8 proves the finite host aggregate is exactly `28G + 20G + 6G = 54G`, requires at least 62 GiB physical RAM, reports the remainder, and excludes inactive Lima capacity from host-Docker arithmetic.
7. Workload aggregates are enrolled for memory-pressure handling at 50%; `-.slice` and the deploy owner's `user@UID.service` report both `ManagedOOMMemoryPressure=auto` and `ManagedOOMSwap=auto`, no ancestor enrolls the desktop indirectly, unprivileged `oomctl` lists the intended system and user workload roots plus the empty proof root when a proof is active, and `ezgha.service` has neither `ManagedOOMPreference=omit` nor `OOMScoreAdjust=-1000`.
8. `ezgha.service` refuses startup on a proven host-Docker containment violation and can recover from a transient Docker query failure without exhausting its start limit.
9. Separate executable evidence proves child hard-limit containment, isolated oomd descendant selection, ten simultaneous `Runner.Worker` processes tied by in-container run markers to one successful capacity workflow run selected by the full Linux-primary label intersection, and host/desktop survival; claims are limited to the proof that produced them.
10. The shared endpoint-aware topology classifier makes Host-Docker runtime and doctor paths ignore VM-only `vm_total_mb` and guest-reserve arithmetic, preserves those checks for explicit VM topology, preserves existing non-fatal Mac/runtime behavior for indeterminate topology, and lets new Linux install/start gates reject contradictory or unknown topology.
11. No new watchdog, host restart authority, VM fallback, or runner-count reduction is introduced.
12. All controls, installation steps, verification logic, and the crash-containment tenet are git-tracked and reproducible on a fresh Ubuntu host.

## Implementation Preconditions

- The deploy owner must have non-interactive or interactive `sudo` authority to install system units under `/etc/systemd/system`; user-only installation cannot enforce Docker's system cgroup hierarchy.
- The live deployment must follow the repository's single-writer checks before restarting `ezgha.service` or running the live harness.
- The bounded pressure proof requires privilege to start the two fixed tracked proof services by literal name; arbitrary transient units and commands are prohibited. The repository supplies the fixed bounded allocator rather than depending on `stress-ng` behavior.
- Live activation requires current usage to fit below each proposed `MemoryHigh` with the declared workload-specific margin: 1 GiB for actions, 1 GiB for agents, and 512 MiB for automation; otherwise deployment stops before installing or reloading units.
