# Runner Crash Containment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the Ubuntu host and operator desktop alive under a full ten-runner workload by enforcing finite workload aggregates and workload-local pressure handling on host Docker.

**Architecture:** Host Docker remains the Linux execution backend. Docker runner scopes live under a root-owned finite `actions.slice`; coding agents and automation retain separate finite user slices; `systemd-oomd` monitors those workload roots instead of the whole desktop user manager. A read-only `ExecStartPre` assertion blocks runner admission on a proven policy violation and distinguishes transient Docker-query failure so the normal service can recover.

**Tech Stack:** Bash, systemd/cgroup v2, Docker, Rust-generated user service, `tomllib`, shell fixture tests

**Spec:** `docs/superpowers/specs/2026-08-31-runner-crash-containment-design.md`

## Global Constraints

- Keep exactly 10 Linux runner slots; runner-count reduction is not a containment mechanism.
- Host Docker at `unix:///var/run/docker.sock` is allowed only when the host containment preflight passes.
- Runner aggregate: `MemoryHigh=26G`, `MemoryMax=28G`, `MemorySwapMax=0`, `TasksMax=6000`, `CPUQuota=1600%`, `IOWeight=25` where supported.
- Agent aggregate: `MemoryHigh=14G`, `MemoryMax=16G`, `MemorySwapMax=2G`, `TasksMax=8192`.
- Automation aggregate: `MemoryHigh=4G`, `MemoryMax=6G`, `MemorySwapMax=1G`, `TasksMax=4096`.
- Workload slices use `ManagedOOMMemoryPressure=kill` and `ManagedOOMMemoryPressureLimit=50%`; `user@1000.service` uses `ManagedOOMMemoryPressure=auto`.
- Docker must use cgroup v2 with the `systemd` driver. Endpoint classification and actual cgroup ancestry are both verified.
- The fixed profile requires at least 60 GiB RAM and 32 logical CPUs; smaller hosts fail closed and require a reviewed profile.
- The 12.8-GiB arithmetic remainder is budgeted headroom, not a proof against global kernel OOM.
- No `systemctl set-property` runtime or persistent control drop-in may shadow tracked unit files.
- No new watchdog, polling repair loop, VM fallback, host reboot authority, or VM deletion is permitted.
- Every live mutation is performed by one deploy owner after the repository's load/container preflight.
- Use `/parallel` only for disjoint files/worktrees; `install.sh`, live systemd state, and final verification have one integration owner.
- Keep implementation scoped to policy, systemd artifacts, one assertion/installer path, and existing diagnostics; do not rewrite runner scheduling, registration, or the Rust Docker backend unless a failing test proves it is required.

## File Structure

- `CLAUDE.md`: canonical crash-containment tenets for agents working in this repository.
- `AGENTS.md`: concise pointer to the canonical `CLAUDE.md` section.
- `README.md`: user-visible host-Docker topology and resource-boundary description.
- `roadmap/up-changelog-20260831-crash-containment.md`: `/up` receipt.
- `systemd/host/actions.slice`: root-owned runner aggregate.
- `systemd/host/actions-hardlimit.slice`: empty child used only for bounded kernel-limit proof.
- `systemd/host/actions-oomdproof.slice`: empty monitored child used only for bounded oomd proof.
- `systemd/host/user@.service.d/90-ezgha-crash-containment.conf`: disable broad desktop-user pressure monitoring.
- `systemd/agents.slice`: finite interactive-agent aggregate and direct OOM enrollment.
- `systemd/automation.slice`: finite automation aggregate and direct OOM enrollment.
- `systemd/ezgha.service.d/20-crash-containment-preflight.conf`: read-only startup assertion.
- `scripts/host/assert-crash-containment.sh`: host-versus-VM detection and effective-property checks.
- `scripts/host/install-crash-containment.sh`: idempotent privileged and user-scope installation.
- `scripts/host/prove-crash-containment.sh`: separately labeled hard-limit and isolated oomd proofs.
- `install.sh`: invoke the containment installer on Linux and install stable helper paths.
- `config/config.toml.linux.example`: host-Docker ten-runner configuration.
- `doctor-runner`: read-only topology and containment report.
- `docs/verify-exit-criteria.sh`: live host-Docker containment gate.
- Focused tests under `tests/`: artifact, assertion, installer, doctor, verifier, and pressure-proof behavior.

## Parallel Execution Map

The first three tasks are independent and should start together in isolated worktrees:

| Lane | Ownership | Resource profile | Ceiling |
|---|---|---|---|
| A | Task 1 policy/docs only | light | one in-process worker |
| B | Task 2 systemd artifacts/tests only | light | one in-process worker |
| C | Task 3 assertion script/tests only | light | one in-process worker |

Create isolated branches/worktrees `codex/crash-policy`, `codex/crash-systemd`, and `codex/crash-assertion` before dispatch. Each lane commits and pushes only its branch; no lane pushes the integration branch. Task 4 begins after B and C because it integrates both through `install.sh`. Task 5 begins after Task 4 because verifier fixtures must match installed paths. Task 6 begins after Tasks 2-5 because its live proofs consume the final hierarchy. Task 7 is strictly serial and belongs to the deploy owner.

### Task 1: Persist the Crash-Containment Tenets with `/up`

**Files:**
- Modify: `CLAUDE.md`
- Modify: `AGENTS.md`
- Modify: `README.md`
- Create: `roadmap/up-changelog-20260831-crash-containment.md`
- Test: `tests/host_control_artifacts_test.sh`

**Interfaces:**
- Consumes: the accepted goals and limits from the design specification.
- Produces: one canonical agent-policy section named `Crash-containment contract` and two narrow pointers.

- [ ] **Step 1: Back up the instruction owner outside the repository**

Run:

```bash
cp CLAUDE.md /tmp/ezgha-CLAUDE.md.pre-crash-containment
```

Expected: `/tmp/ezgha-CLAUDE.md.pre-crash-containment` exists and `git status --short` remains unchanged.

- [ ] **Step 2: Extend the policy regression test first**

Add assertions to `tests/host_control_artifacts_test.sh` for one full canonical copy in `CLAUDE.md`, a pointer in `AGENTS.md`, and accurate host-Docker wording in `README.md`:

```bash
assert_line "$REPO_ROOT/CLAUDE.md" "## Crash-containment contract"
assert_line "$REPO_ROOT/CLAUDE.md" "Ten Linux runners remain the capacity contract"
assert_line "$REPO_ROOT/CLAUDE.md" "Backend choice is subordinate to effective crash containment"
assert_line "$REPO_ROOT/AGENTS.md" "See \`CLAUDE.md\` section \"Crash-containment contract\""
assert_line "$REPO_ROOT/README.md" "Jeff-Ubuntu uses host Docker with a system-scope runner aggregate"
[ "$(rg -l 'Backend choice is subordinate to effective crash containment' CLAUDE.md AGENTS.md README.md | wc -l)" -eq 1 ] \
  || fail "crash-containment policy must have one canonical semantic copy"
```

- [ ] **Step 3: Run the focused test and confirm the red state**

Run:

```bash
bash tests/host_control_artifacts_test.sh
```

Expected: FAIL because the canonical section and pointers do not exist.

- [ ] **Step 4: Add the canonical `/up` policy**

Add this section to `CLAUDE.md` immediately before `Safety & Monitoring Principles`:

```markdown
## Crash-containment contract
- **Primary goal:** keep the physical host, desktop session, terminal, and operator recovery tools alive under a full runner workload. Ten Linux runners remain the capacity contract; reducing runner count is not a containment fix.
- **Workload-local pressure handling:** runner, agent, and automation pressure is handled within separately monitored finite roots. The whole `user@.service` is not a direct oomd pressure root. Do not claim a global kill order across independent roots or claim desktop survival without live evidence.
- **Backend choice is subordinate to effective crash containment:** host Docker is valid when the system `actions.slice` and workload-first OOM policy are effective. Colima is neither required nor sufficient. Never switch backends as a recovery fallback if doing so bypasses a required resource boundary.
- **Fail closed on missing limits:** do not start or refill runners when the effective aggregate is absent, infinite, installed in the wrong manager scope, or weaker than the tracked profile.
- **Portable controls only:** every limit, installer action, preflight, and verifier must be git-tracked and reproducible from this repository. A live-only drop-in or one-off `systemctl set-property` is incident evidence, not a completed fix.
- **No competing repair authority:** observation and verification may report drift, but no new watchdog or monitor may restart Docker, Colima, the desktop, or the host.
- **Evidence is claim-specific:** hard-limit containment, oomd victim selection, and desktop survival are separate proofs; none substitutes for another.
```

In `AGENTS.md`, add only:

```markdown
- **Crash containment:** See `CLAUDE.md` section "Crash-containment contract"; it is the canonical statement of backend, capacity, kill-order, and portability requirements.
```

Update `README.md` to state that Jeff-Ubuntu uses host Docker with a system-scope runner aggregate and remove claims that its active daemon necessarily runs inside Colima.

- [ ] **Step 5: Write the `/up` receipt**

Create `roadmap/up-changelog-20260831-crash-containment.md` with exactly:

```markdown
| Surface | Status | One-line reason |
|---|---|---|
| `CLAUDE.md` | Updated | Canonical crash-containment goal and invariants. |
| `AGENTS.md` | Updated | Pointer to the canonical repository contract. |
| `README.md` | Updated | Active host-Docker topology described accurately. |
```

- [ ] **Step 6: Verify and commit the policy unit**

Run:

```bash
bash tests/host_control_artifacts_test.sh
rg -n 'Crash-containment contract|Backend choice is subordinate' CLAUDE.md AGENTS.md README.md
git diff --check
git add CLAUDE.md AGENTS.md README.md roadmap/up-changelog-20260831-crash-containment.md tests/host_control_artifacts_test.sh
git commit -m "codex/gpt-5.6-sol: codify runner crash-containment contract"
git push origin HEAD
```

Expected: focused test PASS; the distinctive full rule occurs only in `CLAUDE.md`; push succeeds.

### Task 2: Add the Systemd Resource Policy Artifacts

**Files:**
- Create: `systemd/host/actions.slice`
- Create: `systemd/host/actions-hardlimit.slice`
- Create: `systemd/host/actions-oomdproof.slice`
- Create: `systemd/host/user@.service.d/90-ezgha-crash-containment.conf`
- Modify: `systemd/agents.slice`
- Modify: `systemd/automation.slice`
- Delete: `systemd/ezgha.service.d/10-oomd-omit.conf`
- Delete: `systemd/psi-oom-watcher.service`
- Delete: `systemd/psi-oom-watcher.timer`
- Create: `tests/host_crash_containment_artifacts_test.sh`

**Interfaces:**
- Consumes: exact budgets from the specification.
- Produces: persistent unit files consumed by the installer and assertion script.

- [ ] **Step 1: Write the failing artifact test**

Create `tests/host_crash_containment_artifacts_test.sh` to assert exact directives:

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
expect() { grep -Fqx "$2" "$ROOT/$1" || { echo "FAIL: $1 missing $2" >&2; exit 1; }; }

expect systemd/host/actions.slice MemoryHigh=26G
expect systemd/host/actions.slice MemoryMax=28G
expect systemd/host/actions.slice MemorySwapMax=0
expect systemd/host/actions.slice TasksMax=6000
expect systemd/host/actions.slice CPUQuota=1600%
expect systemd/host/actions.slice IOWeight=25
expect systemd/host/actions.slice ManagedOOMMemoryPressure=kill
expect systemd/host/actions.slice ManagedOOMMemoryPressureLimit=50%
expect systemd/host/actions-hardlimit.slice MemoryMax=512M
expect systemd/host/actions-oomdproof.slice MemoryMax=768M
expect systemd/host/actions-oomdproof.slice ManagedOOMMemoryPressure=kill
expect systemd/host/user@.service.d/90-ezgha-crash-containment.conf ManagedOOMMemoryPressure=auto
expect systemd/agents.slice MemoryHigh=14G
expect systemd/agents.slice MemoryMax=16G
expect systemd/agents.slice ManagedOOMMemoryPressure=kill
expect systemd/automation.slice ManagedOOMMemoryPressure=kill
test ! -e "$ROOT/systemd/ezgha.service.d/10-oomd-omit.conf" || { echo "FAIL: stale OOM exemption remains" >&2; exit 1; }
test ! -e "$ROOT/systemd/psi-oom-watcher.service" || { echo "FAIL: competing PSI repair service remains" >&2; exit 1; }
test ! -e "$ROOT/systemd/psi-oom-watcher.timer" || { echo "FAIL: competing PSI repair timer remains" >&2; exit 1; }
echo "PASS: crash-containment artifacts"
```

- [ ] **Step 2: Run the artifact test and confirm the red state**

Run:

```bash
bash tests/host_crash_containment_artifacts_test.sh
```

Expected: FAIL because `systemd/host/actions.slice` is absent.

- [ ] **Step 3: Create the root-owned runner slice**

Create `systemd/host/actions.slice`:

```ini
[Unit]
Description=GitHub Actions runner aggregate - host crash containment
Before=slices.target

[Slice]
MemoryHigh=26G
MemoryMax=28G
MemorySwapMax=0
TasksMax=6000
CPUQuota=1600%
MemoryAccounting=yes
CPUAccounting=yes
IOAccounting=yes
IOWeight=25
ManagedOOMMemoryPressure=kill
ManagedOOMMemoryPressureLimit=50%
```

Create `actions-hardlimit.slice` with `MemoryHigh=384M`, `MemoryMax=512M`, and `MemorySwapMax=0`, but no `ManagedOOM*` policy. Create `actions-oomdproof.slice` with `MemoryHigh=384M`, `MemoryMax=768M`, `MemorySwapMax=0`, `ManagedOOMMemoryPressure=kill`, and `ManagedOOMMemoryPressureLimit=20%`. By systemd slice naming rules both are direct descendants of `actions.slice`; the rejected name `actions-pressure-proof.slice` would instead nest below nonexistent `actions-pressure.slice`.

- [ ] **Step 4: Create the desktop-user monitoring override**

Create `systemd/host/user@.service.d/90-ezgha-crash-containment.conf`:

```ini
[Service]
ManagedOOMMemoryPressure=auto
```

- [ ] **Step 5: Update user workload slices and retire the inverted exemption**

Change `systemd/agents.slice` to `MemoryHigh=14G`, `MemoryMax=16G`, retain `MemorySwapMax=2G` and `TasksMax=8192`, then add:

```ini
ManagedOOMMemoryPressure=kill
ManagedOOMMemoryPressureLimit=50%
```

Add the same OOM directives to `systemd/automation.slice` without changing its 4G/6G/1G/4096 envelope. Update the stale peak and budget comments in both user slice files. Delete `systemd/ezgha.service.d/10-oomd-omit.conf`; host-Docker runner scopes are not descendants of `ezgha.service`, so exempting that service does not protect the runner aggregate and encodes the wrong policy.

Delete the tracked `psi-oom-watcher.service` and timer. Their SIGTERM shed path is a second pressure-remediation authority and their verifier assumptions depend on broad `user.slice` monitoring, which this design intentionally removes. Task 4 disables any installed copies without running them.

- [ ] **Step 6: Validate units and commit**

Run:

```bash
bash tests/host_crash_containment_artifacts_test.sh
systemd-analyze verify systemd/host/actions.slice systemd/host/actions-hardlimit.slice systemd/host/actions-oomdproof.slice systemd/agents.slice systemd/automation.slice
git diff --check
git add systemd/host/actions.slice systemd/host/actions-hardlimit.slice systemd/host/actions-oomdproof.slice systemd/host/user@.service.d/90-ezgha-crash-containment.conf systemd/agents.slice systemd/automation.slice tests/host_crash_containment_artifacts_test.sh
git add -u systemd/ezgha.service.d/10-oomd-omit.conf systemd/psi-oom-watcher.service systemd/psi-oom-watcher.timer
git commit -m "codex/gpt-5.6-sol: define workload-first systemd limits"
git push origin HEAD
```

Expected: test PASS and `systemd-analyze verify` exits zero.

### Task 3: Build the Read-Only Containment Assertion

**Files:**
- Create: `scripts/host/assert-crash-containment.sh`
- Create: `tests/assert_crash_containment_test.sh`

**Interfaces:**
- Consumes: systemd properties from Task 2 and `[limits].cgroup_parent` from the TOML config.
- Produces: `assert-crash-containment.sh --config PATH`, exit 0 for a valid topology, exit 78 for a proven policy violation, and exit 75 for a transient/indeterminate Docker query.

- [ ] **Step 1: Create fixture tests for every decision branch**

Build temporary `docker` and `systemctl` stubs plus a fake cgroup tree. Use these environment seams:

```bash
EZGHA_DOCKER_BIN="$BIN/docker"
EZGHA_SYSTEMCTL_BIN="$BIN/systemctl"
EZGHA_CGROUP_ROOT="$TMP/cgroup"
```

Cover:

```text
host socket + systemd cgroup v2 + exact finite values        => exit 0
host profile on <60 GiB RAM or <32 logical CPUs              => exit 78
Colima/Lima socket endpoint                                 => exit 0, reports vm-contained
remote or unknown endpoint                                  => exit 78
host socket + Docker cgroup driver cgroupfs                  => exit 78
host socket + transient docker-info failure after retries    => exit 75
host Docker + missing actions.slice                          => exit 78
host Docker + memory.high=max/infinity                       => exit 78
host Docker + wrong cpu.max                                  => exit 78
host Docker + cgroup_parent != actions.slice                 => exit 78
host Docker + user@ or an ancestor enrolled with kill        => exit 78
host Docker + agents.slice MemoryMax=infinity                => exit 78
installed helper digest differs from tracked source          => exit 78
```

- [ ] **Step 2: Run the new test and confirm the red state**

Run:

```bash
bash tests/assert_crash_containment_test.sh
```

Expected: FAIL because the assertion script is absent.

- [ ] **Step 3: Implement structured configuration and topology detection**

Read TOML with Python's structured parser:

```bash
cgroup_parent="$({ python3 - "$config" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    print(tomllib.load(fh).get("limits", {}).get("cgroup_parent", ""))
PY
} 2>/dev/null)"
```

Classify the backend from the normalized configured endpoint: `/var/run/docker.sock` is host Docker, known Colima/Lima sockets are VM Docker, and remote or unknown endpoints are rejected until an explicit profile exists. For host Docker, retry `docker info` three times over at most 15 seconds, require `CgroupVersion=2` and `CgroupDriver=systemd`, then compare cgroup files to exact byte/CPU values:

```text
memory.high      27917287424
memory.max       30064771072
memory.swap.max  0
pids.max         6000
cpu.max          1600000 100000
```

Use `systemctl show actions.slice` and `systemctl --user show agents.slice automation.slice` for OOM and effective-property assertions. Use system `systemctl show user@$(id -u).service` and require `ManagedOOMMemoryPressure=auto`; walk its ancestor cgroups and reject any `ManagedOOMMemoryPressure=kill` root. Require `oomctl` to list the intended workload roots and no broad user root. Resolve each managed container's actual `/proc/<pid>/cgroup` path and require it below `/actions.slice`; Docker's configured `CgroupParent` alone is not sufficient.

Require at least 60 GiB `MemTotal` and 32 logical CPUs before accepting this fixed profile. Verify `io.weight=25` when the I/O controller is present in `cgroup.controllers`; otherwise report `io_controller=unavailable` without claiming I/O protection.

When invoked from the installed stable path, compare its SHA-256 digest with the tracked source recorded at install time. A mismatch is a policy violation, not a warning.

- [ ] **Step 4: Keep the assertion mutation-free**

Reject `systemctl start`, `restart`, `set-property`, `sudo`, `docker run`, and file writes in the script with a test scan:

```bash
if rg -n 'systemctl .*\b(start|restart|set-property)\b|sudo |docker run|(^|[;&|])[[:space:]]*(rm|mv|cp|install)[[:space:]]' scripts/host/assert-crash-containment.sh; then
  echo "FAIL: assertion script contains mutation" >&2
  exit 1
fi
```

- [ ] **Step 5: Verify and commit**

Run:

```bash
bash -n scripts/host/assert-crash-containment.sh tests/assert_crash_containment_test.sh
bash tests/assert_crash_containment_test.sh
git diff --check
git add scripts/host/assert-crash-containment.sh tests/assert_crash_containment_test.sh
git commit -m "codex/gpt-5.6-sol: fail closed on missing host containment"
git push origin HEAD
```

Expected: all assertion fixtures PASS.

### Task 4: Install and Activate the Tracked Hierarchy

**Files:**
- Create: `scripts/host/install-crash-containment.sh`
- Create: `systemd/ezgha.service.d/20-crash-containment-preflight.conf`
- Modify: `install.sh`
- Modify: `config/config.toml.linux.example`
- Create: `tests/install_crash_containment_test.sh`
- Modify: `tests/install_watchdog_gate_test.sh`
- Modify: `tests/install_uninstall_aux_units_test.sh`

**Interfaces:**
- Consumes: Task 2 unit files and Task 3 assertion.
- Produces: `install-crash-containment.sh --check|--install` and an installed `ExecStartPre` gate.

- [ ] **Step 1: Write installer fixtures before implementation**

Stub `sudo`, system and user `systemctl`, Docker, and `install`. Assert that host-Docker `--install` executes these logical operations in order:

```text
reject /run/systemd/*control overrides that would shadow tracked units
read actions/agents/automation memory.current and require current + 2 GiB <= proposed MemoryHigh
stage and syntax-check every persistent unit before touching /etc or ~/.config
install systemd/host/actions.slice -> /etc/systemd/system/actions.slice
install user@ override -> /etc/systemd/system/user@.service.d/90-ezgha-crash-containment.conf
disable --now psi-oom-watcher.timer and psi-oom-watcher.service
systemctl daemon-reload
systemctl start actions.slice
remove ~/.config/systemd/user/agents.slice.d/99-local-unlimited.conf
systemctl --user daemon-reload
verify effective values; restore prior persistent files and reload on mismatch
```

Assert that VM Docker skips the system host profile, current usage above the activation margin makes no live change, a control drop-in causes a hard diagnostic, and missing privilege causes a nonzero exit without printing success.

- [ ] **Step 2: Run installer fixtures and confirm the red state**

Run:

```bash
bash tests/install_crash_containment_test.sh
```

Expected: FAIL because the installer does not exist.

- [ ] **Step 3: Implement the idempotent installer**

`--check` delegates to `assert-crash-containment.sh` and never mutates. `--install` uses `${SUDO_BIN:-sudo}` for `/etc/systemd/system` and supports fixture roots through explicit test-only environment variables already established by repository shell tests. Before installing, it rejects shadowing control drop-ins and requires `memory.current + 2 GiB <= proposed MemoryHigh` for every active workload slice. It stages and verifies persistent files, snapshots replaced files, installs atomically, reloads managers, and verifies effective properties. A verification failure restores the snapshots and reloads. It never calls `systemctl set-property`, so tracked files remain the only resource-policy owner.

Disable and remove installed `psi-oom-watcher.timer` and `psi-oom-watcher.service` before changing oomd enrollment. Do not invoke either watcher during removal. Record this retirement in installer and uninstaller fixtures.

Do not stop or restart a live Lima VM. When host Docker is proven and `lima-vm@colima.service` is inactive, disable its future auto-start without `--now`; when it is active, report topology drift and leave it untouched for operator review.

- [ ] **Step 4: Add the service preflight drop-in**

Create:

```ini
[Unit]
StartLimitIntervalSec=0

[Service]
ExecStartPre=%h/.local/libexec/ezgha/assert-crash-containment.sh --config %h/.config/ezgha/config.toml
Restart=on-failure
RestartSec=30s
RestartPreventExitStatus=78
```

Update `install.sh` to install both helper scripts, a SHA-256 receipt for the installed assertion, and this drop-in before `ezgha.service` is enabled. On host-Docker Linux, invoke `install-crash-containment.sh --install`; abort the install if the system profile cannot be applied. Test that exit 75 is recoverable without a five-attempt wedge and exit 78 remains stopped until policy is repaired.

- [ ] **Step 5: Correct the Linux host-Docker example**

In `config/config.toml.linux.example`, retain `count = 10`, set `runner_floor_mb = 2500`, set `limits.memory_mb = 2500`, and remove the explicit Colima-only `vm_total_mb`, `guest_reserve_mb`, and `host_reserve_mb` claims. Explain that the sum of tracked workload hard caps leaves about 12.8 GiB of budgeted headroom but does not cap desktop, kernel, Docker, or other system memory.

- [ ] **Step 6: Verify install behavior and commit**

Run:

```bash
bash -n scripts/host/install-crash-containment.sh install.sh tests/install_crash_containment_test.sh
bash tests/install_crash_containment_test.sh
bash tests/install_watchdog_gate_test.sh
bash tests/install_uninstall_aux_units_test.sh
bash tests/assert_crash_containment_test.sh
git diff --check
git add scripts/host/install-crash-containment.sh systemd/ezgha.service.d/20-crash-containment-preflight.conf install.sh config/config.toml.linux.example tests/install_crash_containment_test.sh tests/install_watchdog_gate_test.sh tests/install_uninstall_aux_units_test.sh
git commit -m "codex/gpt-5.6-sol: install host crash-containment policy"
git push origin HEAD
```

Expected: all focused installer and assertion tests PASS.

### Task 5: Make Doctor and Exit Gates Verify Effective Containment

**Files:**
- Modify: `doctor-runner`
- Modify: `docs/verify-exit-criteria.sh`
- Modify: `tests/doctor_runner_host_pressure_test.sh`
- Modify: `tests/verify_exit_gate8_test.sh`

**Interfaces:**
- Consumes: Task 3 assertion output and Task 4 installed paths.
- Produces: read-only topology diagnostics and a hard harness gate.

- [ ] **Step 1: Add failing doctor fixtures**

Extend `tests/doctor_runner_host_pressure_test.sh` with host-Docker fixtures requiring these fields:

```text
backend_topology=host-docker
docker_cgroup_version=2
docker_cgroup_driver=systemd
runner_cgroup_parent=actions.slice
runner_cgroup_path=/actions.slice/...
actions_memory_high=26G
actions_memory_max=28G
actions_oomd=kill@50%
desktop_user_oomd=auto
desktop_ancestor_oomd=none
control_dropin_drift=none
verdict=PASS
```

Add an infinite `actions.slice` fixture expecting `verdict=FAIL` and a diagnostic naming `MemoryMax`.

- [ ] **Step 2: Add failing Gate 8 fixtures**

Extend `tests/verify_exit_gate8_test.sh` with mutually exclusive host-Docker and Colima fixtures. The host fixture passes only when Docker uses cgroup v2/systemd, every managed container both reports `actions.slice` and has an actual PID cgroup path below `/actions.slice`, system values match the profile, workload OOM enrollment is effective, `user@` and its ancestors are not monitored roots, no control drop-in shadows the tracked policy, and the unlimited agent override is absent. In host mode, exclude `app-lima-vm.slice` from budget arithmetic and never invoke `limactl`; retain the existing guest checks only in explicit Colima mode.

- [ ] **Step 3: Run both tests and confirm the red state**

Run:

```bash
bash tests/doctor_runner_host_pressure_test.sh
bash tests/verify_exit_gate8_test.sh
```

Expected: both FAIL on missing host-Docker aggregate verification.

- [ ] **Step 4: Implement read-only reporting and the hard gate**

Reuse `assert-crash-containment.sh --config ...` for the shared invariant verdict. `doctor-runner` prints the fields above and remains non-mutating. Gate 8 independently records effective `systemctl`, `oomctl`, Docker, actual cgroup paths, `memory.oom.group`, and cgroup values as evidence, then invokes the assertion for the final pass/fail decision. It reports whether whole-container OOM behavior is configured or only process-local cgroup OOM behavior can be claimed.

Do not infer containment from the presence of `systemd/guest/actions.slice` or a file under `~/.config/systemd/user`; only `/sys/fs/cgroup/actions.slice` and the system manager count for host Docker.

Before and after applying `CPUQuota=1600%`, run the bounded job-outcome monitor with the exact repository and thresholds below. It measures attributed job conclusions, not duration; treat `UNHEALTHY` or `UNKNOWN` as a deployment gate failure even when container liveness passes. Record duration separately from the controlled ten-job execution sample.

- [ ] **Step 5: Verify and commit**

Run:

```bash
bash -n doctor-runner docs/verify-exit-criteria.sh
bash tests/doctor_runner_host_pressure_test.sh
bash tests/verify_exit_gate8_test.sh
bash tests/host_control_artifacts_test.sh
git diff --check
git add doctor-runner docs/verify-exit-criteria.sh tests/doctor_runner_host_pressure_test.sh tests/verify_exit_gate8_test.sh
git commit -m "codex/gpt-5.6-sol: verify effective runner containment"
git push origin HEAD
```

Expected: doctor and Gate 8 fixtures PASS.

### Task 6: Add Claim-Specific Bounded Live Proofs

**Files:**
- Create: `scripts/host/prove-crash-containment.sh`
- Create: `tests/prove_crash_containment_test.sh`
- Modify: `docs/verify-exit-criteria.sh`

**Interfaces:**
- Consumes: effective system hierarchy and the Task 3 assertion.
- Produces: a timestamped evidence directory under `evidence/crash-containment/<timestamp>/` with separate `hard-limit`, `oomd-selection`, and `survival` verdicts.

- [ ] **Step 1: Write fixture tests for proof safety**

Stub `systemd-run`, `systemctl`, `loginctl`, cgroup files, and boot ID. Cover:

```text
hard-limit child memory.events increments oom_kill                 => hard-limit PASS
oomd journal names descendant under actions-oomdproof.slice        => oomd-selection PASS
oomd child exits without a matching oomd victim record             => oomd-selection FAIL
boot ID changes                                                     => survival FAIL
user-manager PID changes                                            => survival FAIL
unrelated managed runner disappears                                 => survival FAIL
preflight fails                                                      => FAIL before allocation
either allocator exceeds 90 seconds                                 => FAIL and terminate only its proof unit
```

- [ ] **Step 2: Run the proof test and confirm the red state**

Run:

```bash
bash tests/prove_crash_containment_test.sh
```

Expected: FAIL because the proof script is absent.

- [ ] **Step 3: Implement separate hard-limit and oomd-selection modes**

The script must:

1. Run the read-only containment assertion and require the two tracked proof slices to be empty.
2. Record boot ID, `user@UID.service` MainPID, Warp PID set, managed runner IDs, memory/PSI snapshots, `oomctl`, relevant journal cursors, and workload `memory.events`.
3. In `--hard-limit` mode, run `ezgha-hard-limit-proof.service` under `actions-hardlimit.slice` for at most 90 seconds. Require that slice's `oom`/`oom_kill` counter to increment and label the result only as kernel hard-limit containment.
4. In `--oomd` mode, run `ezgha-oomd-proof.service` under `actions-oomdproof.slice` long enough to exceed the tracked 20% PSI threshold, but for at most 90 seconds. Require a new `systemd-oomd` journal record naming a descendant of that proof slice; allocator exit alone is not evidence.
5. For both modes, require the boot ID, user-manager PID, Warp PID set, Docker daemon, and unrelated runner containers to remain alive. Record this separately as the survival verdict.
6. Stop and reset only the named proof services; leave the empty tracked proof slices in place. Never touch `actions.slice`, Docker, `ezgha.service`, or the host lifecycle.
7. Inspect effective `memory.oom.group` for runner scopes. Do not claim whole-container hard-limit death when it is `0`; separately observe container exit and fleet replenishment during the ten-runner test.

- [ ] **Step 4: Add an opt-in harness gate**

Gate the live proofs behind `EZGHA_RUN_PRESSURE_PROOF=1`. The normal harness reports each live verdict as `NOT RUN (explicit live proof required)` rather than claiming containment from fixtures or configuration. A release/deployment acceptance run requires both proof modes plus the ten-runner survival observation.

- [ ] **Step 5: Verify and commit**

Run:

```bash
bash -n scripts/host/prove-crash-containment.sh tests/prove_crash_containment_test.sh
bash tests/prove_crash_containment_test.sh
bash tests/verify_exit_gate8_test.sh
git diff --check
git add scripts/host/prove-crash-containment.sh tests/prove_crash_containment_test.sh docs/verify-exit-criteria.sh
git commit -m "codex/gpt-5.6-sol: prove bounded workload failure"
git push origin HEAD
```

Expected: fixture proof PASS; no live pressure is generated during unit tests.

### Task 7: Integrate, Deploy, and Prove the Live Ten-Runner Contract

**Files:**
- Modify: `~/.config/ezgha/config.toml` during deployment only
- Evidence: `evidence/crash-containment/<timestamp>/`
- Beads: update `ez-gh-actions-sa8c`, `ez-gh-actions-kdne`, and duplicate-related containment issues through `br`

**Interfaces:**
- Consumes: all prior green commits.
- Produces: one deployed SHA, effective live containment, pressure evidence, ten-runner execution proof, and durable issue status.

- [ ] **Step 1: Integrate parallel lanes in one worktree**

The integration owner fetches each lane, cherry-picks only its green commits, resolves shared-file conflicts centrally, and runs:

```bash
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
for t in tests/host_control_artifacts_test.sh \
         tests/host_crash_containment_artifacts_test.sh \
         tests/assert_crash_containment_test.sh \
         tests/install_crash_containment_test.sh \
         tests/doctor_runner_host_pressure_test.sh \
         tests/verify_exit_gate8_test.sh \
         tests/prove_crash_containment_test.sh; do bash "$t"; done
git diff --check
```

Expected: all commands exit zero.

- [ ] **Step 2: Update the live config through a structured edit**

Back up `~/.config/ezgha/config.toml`, then use a TOML-aware editor or the repository configuration serializer to set:

```toml
[runner]
count = 10
runner_floor_mb = 2500

[limits]
memory_mb = 2500
cgroup_parent = "actions.slice"

[policy]
minimum_isolation = "container"
```

Remove VM-only `vm_total_mb` from the host-Docker profile. Do not expose or rewrite credentials or alert URLs.

- [ ] **Step 3: Perform the repository deployment and activation preflight**

Run before changing a live limit:

```bash
uptime
docker ps --filter label=ezgha=managed --format '{{.ID}}' | wc -l
cat /sys/fs/cgroup/actions.slice/memory.current
cat "$HOME/.config/systemd/user/agents.slice/memory.current" 2>/dev/null || true
```

Proceed only when load is at most 12, at least 8 of 10 containers are present unless the documented low-load draining exception is proven, no target cgroup is already under pressure, and every active target has current use plus 2 GiB below its proposed `MemoryHigh`. Record current files and effective values for rollback evidence.

- [ ] **Step 4: Apply persistent containment without restarting the desktop**

Run as the deploy owner:

```bash
bash scripts/host/install-crash-containment.sh --install
bash scripts/host/assert-crash-containment.sh --config "$HOME/.config/ezgha/config.toml"
```

Expected: system `actions.slice` and user workload properties match the specification; no systemd control drop-in exists; `user@UID.service` retains the same live MainPID and reports `ManagedOOMMemoryPressure=auto`; installed helper digests match the deployed commit. If verification fails, the installer restores the prior persistent files and reports the rollback result.

- [ ] **Step 5: Install the exact committed binary and restart only ezgha**

Run:

```bash
cargo install --path .
systemctl --user daemon-reload
systemctl --user restart ezgha.service
systemctl --user status ezgha.service --no-pager -l
```

Expected: `ExecStartPre` succeeds and `ezgha.service` is active. Do not start Colima.

- [ ] **Step 6: Verify ten runner scopes and effective budgets**

Run:

```bash
bash scripts/host/assert-crash-containment.sh --config "$HOME/.config/ezgha/config.toml"
docker ps --filter label=ezgha=managed --format '{{.Names}}' | sort
for id in $(docker ps -q --filter label=ezgha=managed); do
  docker inspect --format '{{.Name}} {{.HostConfig.CgroupParent}} {{.HostConfig.Memory}} {{.HostConfig.MemorySwap}} {{.HostConfig.PidsLimit}}' "$id"
  pid=$(docker inspect --format '{{.State.Pid}}' "$id")
  cat "/proc/$pid/cgroup"
done
./doctor-runner
```

Expected: ten slots converge, Docker reports cgroup v2 with the `systemd` driver, every container reports `actions.slice`, every actual PID cgroup is beneath `/actions.slice`, memory and swap values are 2,621,440,000 bytes, and PID limit is 512. Record `memory.oom.group` and limit whole-container claims to its effective value and observed behavior.

- [ ] **Step 7: Run the bounded pressure proof and full harness**

Run:

```bash
EZGHA_RUN_PRESSURE_PROOF=1 bash scripts/host/prove-crash-containment.sh --hard-limit
EZGHA_RUN_PRESSURE_PROOF=1 bash scripts/host/prove-crash-containment.sh --oomd
./docs/verify-exit-criteria.sh
python3 scripts/job_outcome_monitor.py \
  --repo jleechanorg/ez-gh-actions \
  --window-hours 24 \
  --minimum-jobs 10 \
  --minimum-success-rate 0.90 \
  --sample-target 20
```

Expected: the hard-limit proof records a local cgroup OOM; the oomd proof records a `systemd-oomd` victim beneath `actions-oomdproof.slice`; boot ID, user-manager PID, Warp, Docker, and unrelated runners survive both; the host-Docker Gate 8 passes without invoking Lima; the monitor verdict is `HEALTHY`; and the controlled ten-job sample has no material duration or retry regression against its recorded pre-deploy baseline.

- [ ] **Step 8: Update Beads and land the integration unit**

Use `br search` to avoid duplicates, append the exact deployed SHA and evidence path to `ez-gh-actions-sa8c`, update `ez-gh-actions-kdne` with the corrected host-Docker architecture, and close only criteria proven by the live artifacts.

Set `EVIDENCE_DIR` to the directory printed by the successful pressure proof, then run:

```bash
git status --short
git add CLAUDE.md AGENTS.md README.md roadmap/up-changelog-20260831-crash-containment.md \
  systemd/host/actions.slice \
  systemd/host/actions-hardlimit.slice \
  systemd/host/actions-oomdproof.slice \
  systemd/host/user@.service.d/90-ezgha-crash-containment.conf \
  systemd/agents.slice systemd/automation.slice \
  systemd/ezgha.service.d/20-crash-containment-preflight.conf \
  scripts/host/assert-crash-containment.sh \
  scripts/host/install-crash-containment.sh \
  scripts/host/prove-crash-containment.sh \
  install.sh config/config.toml.linux.example doctor-runner \
  docs/verify-exit-criteria.sh \
  tests/host_control_artifacts_test.sh \
  tests/host_crash_containment_artifacts_test.sh \
  tests/assert_crash_containment_test.sh \
  tests/install_crash_containment_test.sh \
  tests/install_watchdog_gate_test.sh \
  tests/install_uninstall_aux_units_test.sh \
  tests/doctor_runner_host_pressure_test.sh \
  tests/verify_exit_gate8_test.sh \
  tests/prove_crash_containment_test.sh \
  "$EVIDENCE_DIR"
git add -u systemd/ezgha.service.d/10-oomd-omit.conf systemd/psi-oom-watcher.service systemd/psi-oom-watcher.timer
git commit -m "codex/gpt-5.6-sol: enforce workload crash containment"
git push origin HEAD
git status --short --branch
```

Expected: push succeeds, the branch is synchronized with its upstream, and unrelated `.playwright-mcp/` content remains untouched.
