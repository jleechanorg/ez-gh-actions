# Runner Crash Containment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the Ubuntu host and operator desktop alive under a full ten-runner workload by enforcing finite workload aggregates and workload-local pressure handling on host Docker.

**Architecture:** Host Docker remains the Linux execution backend. Docker runner scopes live under a root-owned finite `actions.slice`; coding agents and automation retain separate finite user slices; `systemd-oomd` monitors those workload roots instead of the whole desktop user manager. A main-process startup wrapper runs a read-only assertion, stops permanently on a proven violation, retries only transient Docker-query failures, and then replaces itself with `ezgha serve`.

**Tech Stack:** Bash, systemd/cgroup v2, Docker, Rust-generated user service, `tomllib`, shell fixture tests

**Spec:** `docs/superpowers/specs/2026-08-31-runner-crash-containment-design.md`

## Global Constraints

- Keep exactly 10 Linux runner slots; runner-count reduction is not a containment mechanism.
- Host Docker at `unix:///var/run/docker.sock` is allowed only when the host containment preflight passes.
- Runner aggregate: `MemoryHigh=26G`, `MemoryMax=28G`, `MemorySwapMax=0`, `TasksMax=6000`, `CPUQuota=1600%`, `IOWeight=25` where supported.
- Agent aggregate: `MemoryHigh=14G`, `MemoryMax=16G`, `MemorySwapMax=2G`, `TasksMax=8192`.
- Automation aggregate: `MemoryHigh=4G`, `MemoryMax=6G`, `MemorySwapMax=1G`, `TasksMax=4096`.
- Workload slices use `ManagedOOMMemoryPressure=kill` and `ManagedOOMMemoryPressureLimit=50%`; both `-.slice` and `user@1000.service` explicitly use `ManagedOOMMemoryPressure=auto` and `ManagedOOMSwap=auto`.
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
- `systemd/host/ezghaproof.slice`: empty top-level synthetic-proof boundary, separate from production runners.
- `systemd/host/ezghaproof-hardlimit.slice`: bounded kernel-limit proof child.
- `systemd/host/ezghaproof-oomd.slice`: bounded oomd proof child.
- `systemd/host/ezgha-hard-limit-proof.service`: fixed hard-limit proof launcher.
- `systemd/host/ezgha-oomd-proof.service`: fixed oomd proof launcher.
- `systemd/host/-.slice.d/90-ezgha-oomd-boundary.conf`: disable broad root pressure and swap monitoring.
- `systemd/host/user@.service.d/90-ezgha-oomd-boundary.conf`: disable broad desktop-user pressure and swap monitoring.
- `systemd/agents.slice`: finite interactive-agent aggregate and direct OOM enrollment.
- `systemd/automation.slice`: finite automation aggregate and direct OOM enrollment.
- `scripts/host/assert-crash-containment.sh`: host-versus-VM detection and effective-property checks.
- `scripts/host/ezgha-start-gate.sh`: main-process gate that retries only transient assertion failures.
- `scripts/host/proof-allocator.sh`: fixed bounded allocator used by the two proof services.
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
- Test: `tests/crash_containment_policy_test.sh`

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

Create `tests/crash_containment_policy_test.sh` with assertions for one full canonical copy in `CLAUDE.md`, a pointer in `AGENTS.md`, and accurate host-Docker wording in `README.md`:

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
bash tests/crash_containment_policy_test.sh
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
bash tests/crash_containment_policy_test.sh
rg -n 'Crash-containment contract|Backend choice is subordinate' CLAUDE.md AGENTS.md README.md
git diff --check
git add CLAUDE.md AGENTS.md README.md roadmap/up-changelog-20260831-crash-containment.md tests/crash_containment_policy_test.sh
git commit -m "codex/gpt-5.6-sol: codify runner crash-containment contract"
git push origin HEAD
```

Expected: focused test PASS; the distinctive full rule occurs only in `CLAUDE.md`; push succeeds.

### Task 2: Add the Systemd Resource Policy Artifacts

**Files:**
- Create: `systemd/host/actions.slice`
- Create: `systemd/host/ezghaproof.slice`
- Create: `systemd/host/ezghaproof-hardlimit.slice`
- Create: `systemd/host/ezghaproof-oomd.slice`
- Create: `systemd/host/ezgha-hard-limit-proof.service`
- Create: `systemd/host/ezgha-oomd-proof.service`
- Create: `systemd/host/-.slice.d/90-ezgha-oomd-boundary.conf`
- Create: `systemd/host/user@.service.d/90-ezgha-oomd-boundary.conf`
- Create: `scripts/host/proof-allocator.sh`
- Modify: `systemd/agents.slice`
- Modify: `systemd/automation.slice`
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
expect systemd/host/ezghaproof-hardlimit.slice MemoryMax=512M
expect systemd/host/ezghaproof-oomd.slice MemoryMax=768M
expect systemd/host/ezghaproof-oomd.slice ManagedOOMMemoryPressure=kill
expect systemd/host/-.slice.d/90-ezgha-oomd-boundary.conf ManagedOOMMemoryPressure=auto
expect systemd/host/-.slice.d/90-ezgha-oomd-boundary.conf ManagedOOMSwap=auto
expect systemd/host/user@.service.d/90-ezgha-oomd-boundary.conf ManagedOOMMemoryPressure=auto
expect systemd/host/user@.service.d/90-ezgha-oomd-boundary.conf ManagedOOMSwap=auto
expect systemd/agents.slice MemoryHigh=14G
expect systemd/agents.slice MemoryMax=16G
expect systemd/agents.slice ManagedOOMMemoryPressure=kill
expect systemd/automation.slice ManagedOOMMemoryPressure=kill
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

Create a top-level `ezghaproof.slice` with finite `MemoryMax=1G`, `MemorySwapMax=0`, `TasksMax=128`, and both `ManagedOOM*` policies set to `auto`. Create `ezghaproof-hardlimit.slice` with `MemoryHigh=384M`, `MemoryMax=512M`, and `MemorySwapMax=0`, but no `ManagedOOM*` policy. Create `ezghaproof-oomd.slice` with `MemoryHigh=384M`, `MemoryMax=768M`, `MemorySwapMax=0`, `ManagedOOMMemoryPressure=kill`, and `ManagedOOMMemoryPressureLimit=20%`. By systemd slice naming rules both are descendants only of the top-level proof slice, which is a sibling of production `actions.slice`.

Create fixed `ezgha-hard-limit-proof.service` and `ezgha-oomd-proof.service` system units. Each has the corresponding proof `Slice=`, `Type=oneshot`, `DynamicUser=yes`, `NoNewPrivileges=yes`, `PrivateTmp=yes`, `ProtectSystem=strict`, `ProtectHome=yes`, no capabilities, no credentials, no Docker socket, and a literal `ExecStart=/usr/local/libexec/ezgha/proof-allocator.sh MODE`. The services accept no arbitrary command or environment override. The tracked allocator validates its literal mode and stays within the outer 90-second timeout. The proof script may invoke privileged `systemctl` only with literal lifecycle operations and these exact service names; do not permit `systemd-run`, a shell, wildcard unit names, or command/environment overrides.

- [ ] **Step 4: Create the desktop-user monitoring override**

Create `systemd/host/-.slice.d/90-ezgha-oomd-boundary.conf`:

```ini
[Slice]
ManagedOOMMemoryPressure=auto
ManagedOOMSwap=auto
```

Create `systemd/host/user@.service.d/90-ezgha-oomd-boundary.conf`:

```ini
[Service]
ManagedOOMMemoryPressure=auto
ManagedOOMSwap=auto
```

The root override closes vendor drift that could otherwise monitor every system and desktop cgroup for swap. The assertion walks `-.slice`, `user.slice`, `user-$UID.slice`, and `user@UID.service` and rejects either `ManagedOOMMemoryPressure=kill` or `ManagedOOMSwap=kill` on the desktop path.

- [ ] **Step 5: Update user workload slices and retire the inverted exemption**

Change `systemd/agents.slice` to `MemoryHigh=14G`, `MemoryMax=16G`, retain `MemorySwapMax=2G` and `TasksMax=8192`, then add:

```ini
ManagedOOMMemoryPressure=kill
ManagedOOMMemoryPressureLimit=50%
```

Add the same OOM directives to `systemd/automation.slice` without changing its 4G/6G/1G/4096 envelope. Update the stale peak and budget comments in both user slice files. Legacy watcher/exemption removal belongs to Task 4 with the install-loop changes, so this Task 2 commit remains independently green.

- [ ] **Step 6: Validate units and commit**

Run:

```bash
bash tests/host_crash_containment_artifacts_test.sh
systemd-analyze verify systemd/host/actions.slice systemd/host/ezghaproof.slice systemd/host/ezghaproof-hardlimit.slice systemd/host/ezghaproof-oomd.slice systemd/host/ezgha-hard-limit-proof.service systemd/host/ezgha-oomd-proof.service systemd/agents.slice systemd/automation.slice
git diff --check
git add systemd/host/actions.slice systemd/host/ezghaproof.slice systemd/host/ezghaproof-hardlimit.slice systemd/host/ezghaproof-oomd.slice systemd/host/ezgha-hard-limit-proof.service systemd/host/ezgha-oomd-proof.service systemd/host/-.slice.d/90-ezgha-oomd-boundary.conf systemd/host/user@.service.d/90-ezgha-oomd-boundary.conf scripts/host/proof-allocator.sh systemd/agents.slice systemd/automation.slice tests/host_crash_containment_artifacts_test.sh
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
host Docker + root/user@/ancestor pressure or swap kill      => exit 78
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

Use `systemctl show actions.slice` and `systemctl --user show agents.slice automation.slice` for OOM and effective-property assertions. Use system `systemctl show -- -.slice user.slice user-$(id -u).slice user@$(id -u).service` and require both `ManagedOOMMemoryPressure=auto` and `ManagedOOMSwap=auto` along the desktop path; reject either policy at `kill`. Require `oomctl` to list the intended workload roots and no broad root or user root. Resolve each managed container's actual `/proc/<pid>/cgroup` path and require it below `/actions.slice`; Docker's configured `CgroupParent` alone is not sufficient.

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
- Create: `scripts/host/ezgha-start-gate.sh`
- Modify: `src/service.rs`
- Modify: `src/main.rs`
- Modify: `install.sh`
- Modify: `config/config.toml.linux.example`
- Delete: `systemd/ezgha.service.d/10-oomd-omit.conf`
- Delete: `systemd/psi-oom-watcher.service`
- Delete: `systemd/psi-oom-watcher.timer`
- Delete: `scripts/host/psi-oom-watcher.sh`
- Create: `tests/install_crash_containment_test.sh`
- Modify: `tests/install_watchdog_gate_test.sh`
- Modify: `tests/install_uninstall_aux_units_test.sh`
- Modify: `tests/host_control_artifacts_test.sh`
- Modify: `tests/host_ops_0725_test.sh`

**Interfaces:**
- Consumes: Task 2 unit files and Task 3 assertion.
- Produces: `install-crash-containment.sh --check|--install` and a generated, endpoint-correct main-process startup gate.

- [ ] **Step 1: Write installer fixtures before implementation**

Stub `sudo`, system and user `systemctl`, Docker, and `install`. Assert that host-Docker `--install` executes these logical operations in order:

```text
reject /run/systemd/*control overrides that would shadow tracked units
read actions/agents/automation memory.current and require their 2G/1G/512M margins below proposed MemoryHigh
stage and syntax-check every persistent unit before touching /etc or ~/.config
install systemd/host/actions.slice and fixed proof units -> /etc/systemd/system
install root/user@ overrides -> /etc/systemd/system/{-.slice.d,user@.service.d}
disable --now psi-oom-watcher.timer and psi-oom-watcher.service
systemctl daemon-reload
systemctl start actions.slice
remove ~/.config/systemd/user/agents.slice.d/99-local-unlimited.conf
systemctl --user daemon-reload
verify effective values; restore prior persistent files, reload again, and verify restored effective values on mismatch
```

Assert that VM Docker skips the system host profile, current usage above the activation margin makes no live change, a control drop-in causes a hard diagnostic, and missing privilege causes a nonzero exit without printing success.

- [ ] **Step 2: Run installer fixtures and confirm the red state**

Run:

```bash
bash tests/install_crash_containment_test.sh
```

Expected: FAIL because the installer does not exist.

- [ ] **Step 3: Implement the idempotent installer**

`--check` delegates to `assert-crash-containment.sh` and never mutates. `--install` uses `${SUDO_BIN:-sudo}` for `/etc/systemd/system` and supports fixture roots through explicit test-only environment variables already established by repository shell tests. Before installing, it rejects shadowing control drop-ins and requires an activation margin below each proposed `MemoryHigh`: 2 GiB for `actions.slice`, 1 GiB for `agents.slice`, and 512 MiB for `automation.slice`. These margins keep an unrelated transient agent peak from blocking the runner boundary while still preventing a live hard-limit cut at the threshold. It stages and verifies persistent files, snapshots replaced files, installs atomically, reloads managers, and verifies effective properties. A verification failure restores the snapshots, reloads both managers again, and verifies the effective restored state before returning failure. It never calls `systemctl set-property`, so tracked files remain the only resource-policy owner.

Disable and remove installed `psi-oom-watcher.timer` and `psi-oom-watcher.service` before changing oomd enrollment, then remove the legacy stable copy at `~/.local/libexec/ezgha/psi-oom-watcher.sh`. Do not invoke the watcher during removal. Add an upgrade fixture that starts with all three installed artifacts and proves all three are absent after containment activation, plus the same assertion in uninstall fixtures.

In this same task, delete the tracked watcher service, timer, script, and `systemd/ezgha.service.d/10-oomd-omit.conf`; remove them from normal install source loops before running any tests; and update `tests/host_control_artifacts_test.sh` and `tests/host_ops_0725_test.sh` to require the new policy instead of deleted artifacts. Keeping deletion and consumer updates in one commit prevents the intermediate hard failure caused by an install loop referencing an absent source.

Do not stop or restart a live Lima VM. When host Docker is proven and `lima-vm@colima.service` is inactive, disable its future auto-start without `--now`; when it is active, report topology drift and leave it untouched for operator review.

- [ ] **Step 4: Generate the gated service with the actual binary path**

Create `scripts/host/ezgha-start-gate.sh` and update `src/service.rs` so the generated Linux unit invokes it as the main process. Pass the exact `current_exe()` value and config path already owned by `install-service`; do not hard-code `~/.local/bin/ezgha` or assume a Cargo install prefix. The wrapper invokes the assertion once; exit `0` uses `exec "$binary" --config "$config" serve`, while exits `75`, `78`, and unexpected nonzero statuses return unchanged. The assertion's own three queries are bounded to 15 seconds. The wrapper is not a timer, background process, or independent daemon.

The generated service contains:

```ini
[Unit]
After=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
ExecStart=%h/.local/libexec/ezgha/ezgha-start-gate.sh ACTUAL_CURRENT_EXE ACTUAL_CONFIG_PATH
Restart=on-failure
RestartSec=30
RestartPreventExitStatus=78
TimeoutStartSec=150
```

Remove the unconditional `After=lima-vm@colima.service` and `Wants=lima-vm@colima.service` lines from the generated unit. Make the installer-classified endpoint the single source for the generated service: on Linux, invoke `install-service` with normalized `DOCKER_HOST="${DOCKER_HOST_OVERRIDE:-${DOCKER_HOST:-}}"`, have `src/service.rs` read that value, and emit a correctly escaped `Environment=DOCKER_HOST=...` only when an explicit endpoint exists. An absent value means the canonical host socket. In `src/main.rs`, make backend restart commands endpoint-aware: an unset endpoint or canonical `unix:///var/run/docker.sock` is host Docker and must never start Lima; only an explicit recognized Colima/Lima socket may use the existing bounded VM recovery commands. Preserve `WatchdogSec=300`, `NotifyAccess=all`, `StartLimitIntervalSec=300`, `StartLimitBurst=5`, `Restart=on-failure`, and `RestartSec=30`. Five 15-second assertion failures plus four 30-second restart delays fit within 300 seconds, so persistent exit `75` actually reaches the existing limiter. `TimeoutStartSec=150` covers the assertion plus the daemon's existing 120-second readiness window; systemd watchdog timing starts after `READY=1`, and a source comment plus generated-unit test pins that distinction.

Update `install.sh` to install the assertion, wrapper, and SHA-256 receipts before invoking `ezgha install-service`. The Linux path must always regenerate the unit even when `ezgha.service` is already active; `src/service.rs::install_systemd` records prior active state, writes the unit, reloads, enables it, and restarts it when previously active so the new `ExecStart` takes effect. Complete unrelated image acquisition/recovery before the containment activation phase; on host-Docker Linux, a failed `install-crash-containment.sh --install` blocks only service generation/restart and prints the exact policy diagnostic, not prior image recovery. Add Rust unit tests proving the generated unit uses the passed executable path, contains no Lima dependency, preserves the bounded restart settings, uses the wrapper, omits `DOCKER_HOST` for the default host endpoint, and preserves correctly escaped canonical-host and recognized-VM endpoints. Add a service-install fixture proving an already-active unit is regenerated and restarted, plus backend-recovery tests proving host Docker never invokes Lima while an explicit VM socket retains bounded recovery.

- [ ] **Step 5: Correct the Linux host-Docker example**

In `config/config.toml.linux.example`, retain `count = 10`, set `runner_floor_mb = 2500`, set `limits.memory_mb = 2500`, and remove the explicit Colima-only `vm_total_mb`, `guest_reserve_mb`, and `host_reserve_mb` claims. State the blast radius explicitly: this aligns the tracked fresh-machine default from 3000 to the already-live Jeff-Ubuntu value of 2500 MiB, a 16.7% reduction for new hosts that may expose memory-heavy jobs. Explain that the sum of tracked workload hard caps leaves about 12.8 GiB of budgeted headroom but does not cap desktop, kernel, Docker, or other system memory. Activation records the existing live value and must stop for reviewed profile sizing rather than silently lowering a host above 2500 MiB; release evidence requires the bounded job-outcome and duration sample.

- [ ] **Step 6: Verify install behavior and commit**

Run:

```bash
bash -n scripts/host/install-crash-containment.sh scripts/host/ezgha-start-gate.sh install.sh tests/install_crash_containment_test.sh
cargo test service::tests
cargo test backend_restart
bash tests/install_crash_containment_test.sh
bash tests/install_watchdog_gate_test.sh
bash tests/install_uninstall_aux_units_test.sh
bash tests/assert_crash_containment_test.sh
git diff --check
git add scripts/host/install-crash-containment.sh scripts/host/ezgha-start-gate.sh src/service.rs src/main.rs install.sh config/config.toml.linux.example tests/install_crash_containment_test.sh tests/install_watchdog_gate_test.sh tests/install_uninstall_aux_units_test.sh tests/host_control_artifacts_test.sh tests/host_ops_0725_test.sh
git add -u systemd/ezgha.service.d/10-oomd-omit.conf systemd/psi-oom-watcher.service systemd/psi-oom-watcher.timer scripts/host/psi-oom-watcher.sh
git commit -m "codex/gpt-5.6-sol: install host crash-containment policy"
git push origin HEAD
```

Expected: all focused installer and assertion tests PASS.

### Task 5: Make Doctor and Exit Gates Verify Effective Containment

**Files:**
- Modify: `doctor-runner`
- Modify: `docs/verify-exit-criteria.sh`
- Modify: `docs/host-ops-sudo-block-0725.md`
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

- [ ] **Step 2: Add failing monitoring and Gate 8 fixtures**

Extend `tests/verify_exit_gate8_test.sh` with mutually exclusive host-Docker and Colima fixtures. The host fixture passes only when Docker uses cgroup v2/systemd, every managed container both reports `actions.slice` and has an actual PID cgroup path below `/actions.slice`, system values match the profile, workload OOM enrollment is effective, root, `user@`, and the desktop ancestors are `auto` for both pressure and swap, no control drop-in shadows the tracked policy, and the unlimited agent override is absent. Remove legacy PSI-watcher checks and remediation text from both Gate 7 monitoring and Gate 8 pressure admission; replace them with effective `systemd-oomd` root enrollment and finite-cgroup checks. Rewrite the active installation procedure in `docs/host-ops-sudo-block-0725.md` to mark the watcher and OOM exemption retired and point to the tracked crash-containment installer. Add a regression scan that fails when active surfaces (`install.sh`, `docs/verify-exit-criteria.sh`, `docs/host-ops-sudo-block-0725.md`, `README.md`, or `CLAUDE.md`) instruct users to install, enable, or depend on `psi-oom-watcher` or `10-oomd-omit.conf`; historical activity logs may retain incident references. In host mode, exclude `app-lima-vm.slice` from budget arithmetic and never invoke `limactl`; retain the existing guest checks only in explicit Colima mode.

- [ ] **Step 3: Run both tests and confirm the red state**

Run:

```bash
bash tests/doctor_runner_host_pressure_test.sh
bash tests/verify_exit_gate8_test.sh
```

Expected: both FAIL on missing host-Docker aggregate verification.

- [ ] **Step 4: Implement read-only reporting and the hard gate**

Reuse `assert-crash-containment.sh --config ...` for the shared invariant verdict. `doctor-runner` prints the fields above and remains non-mutating. Gate 8 independently records effective `systemctl`, `oomctl`, Docker, actual cgroup paths, `memory.oom.group`, and cgroup values as evidence, then invokes the assertion for the final pass/fail decision. It reports whether whole-container OOM behavior is configured or only process-local cgroup OOM behavior can be claimed. This task is the sole owner of `docs/verify-exit-criteria.sh`; it adds the opt-in proof-result interface consumed by Task 6.

Do not infer containment from the presence of `systemd/guest/actions.slice` or a file under `~/.config/systemd/user`; only `/sys/fs/cgroup/actions.slice` and the system manager count for host Docker.

Before and after applying `CPUQuota=1600%`, run the bounded job-outcome monitor with the exact repository and thresholds below. It measures attributed job conclusions, not duration; treat `UNHEALTHY` or `UNKNOWN` as a deployment gate failure even when container liveness passes. Record duration separately from the controlled ten-job execution sample.

- [ ] **Step 5: Verify and commit**

Run:

```bash
bash -n doctor-runner docs/verify-exit-criteria.sh
bash tests/doctor_runner_host_pressure_test.sh
bash tests/verify_exit_gate8_test.sh
bash tests/host_control_artifacts_test.sh
bash tests/host_ops_0725_test.sh
bash tests/crash_containment_policy_test.sh
git diff --check
git add doctor-runner docs/verify-exit-criteria.sh docs/host-ops-sudo-block-0725.md tests/doctor_runner_host_pressure_test.sh tests/verify_exit_gate8_test.sh
git commit -m "codex/gpt-5.6-sol: verify effective runner containment"
git push origin HEAD
```

Expected: doctor and Gate 8 fixtures PASS.

### Task 6: Add Claim-Specific Bounded Live Proofs

**Files:**
- Create: `scripts/host/prove-crash-containment.sh`
- Create: `tests/prove_crash_containment_test.sh`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: effective system hierarchy and the Task 3 assertion.
- Produces: a timestamped evidence directory under `evidence/crash-containment/<timestamp>/` with separate `hard-limit`, `oomd-selection`, and `survival` verdicts.

- [ ] **Step 1: Write fixture tests for proof safety**

Stub the narrowly scoped `sudo systemctl` interface, `systemctl`, `loginctl`, cgroup files, and boot ID. Cover:

```text
hard-limit child memory.events increments oom_kill                 => hard-limit PASS
oomd journal names descendant under ezghaproof-oomd.slice          => oomd-selection PASS
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

1. Run the read-only containment assertion; require `/ezghaproof.slice` and both proof children to contain no process; and require every production runner path to remain below `/actions.slice`, outside the proof subtree.
2. Record boot ID, `user@UID.service` MainPID, Warp PID set, managed runner IDs, memory/PSI snapshots, `oomctl`, relevant journal cursors, and workload `memory.events`.
3. In `--hard-limit` mode, use `${SUDO_BIN:-sudo} systemctl start ezgha-hard-limit-proof.service` for the fixed tracked unit and wait at most 90 seconds. Require `ezghaproof-hardlimit.slice`'s `oom`/`oom_kill` counter to increment and label the result only as kernel hard-limit containment.
4. In `--oomd` mode, use `${SUDO_BIN:-sudo} systemctl start ezgha-oomd-proof.service` for the fixed tracked unit and wait at most 90 seconds. Require a new `systemd-oomd` journal record naming a descendant of `ezghaproof-oomd.slice`; allocator exit alone is not evidence.
5. For both modes, require the boot ID, user-manager PID, Warp PID set, Docker daemon, and unrelated runner containers to remain alive. Record this separately as the survival verdict.
6. Stop and reset only the named proof services with privileged `systemctl` calls whose unit names are literal in the script. Never use `systemd-run`, a shell passed through privilege escalation, arbitrary unit names, or command/environment overrides. Leave the empty tracked proof slices in place and never touch `actions.slice`, Docker, `ezgha.service`, or the host lifecycle.
7. Inspect effective `memory.oom.group` for runner scopes. Do not claim whole-container hard-limit death when it is `0`; separately observe container exit and fleet replenishment during the ten-runner test.

- [ ] **Step 4: Add an opt-in harness gate**

Use the Task 5 verifier's existing proof-result interface and gate live execution behind `EZGHA_RUN_PRESSURE_PROOF=1`. The normal harness reports each live verdict as `NOT RUN (explicit live proof required)` rather than claiming containment from fixtures or configuration. A release/deployment acceptance run requires both proof modes plus the ten-runner survival observation. Do not modify `docs/verify-exit-criteria.sh` in this task.

Add every new non-live fixture test, including `tests/prove_crash_containment_test.sh`, to `.github/workflows/ci.yml`. CI runs proof-script fixtures but never starts the live proof services.

- [ ] **Step 5: Verify and commit**

Run:

```bash
bash -n scripts/host/prove-crash-containment.sh tests/prove_crash_containment_test.sh
bash tests/prove_crash_containment_test.sh
bash tests/verify_exit_gate8_test.sh
git diff --check
git add scripts/host/prove-crash-containment.sh tests/prove_crash_containment_test.sh .github/workflows/ci.yml
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
for t in tests/crash_containment_policy_test.sh \
         tests/host_control_artifacts_test.sh \
         tests/host_ops_0725_test.sh \
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

Before writing, record the existing `runner.count`, `runner_floor_mb`, and `limits.memory_mb`. The expected Jeff-Ubuntu values are already `10`, `2500`, and `2500`; if any memory value is higher, stop and require a reviewed aggregate/profile adjustment rather than silently lowering it.

- [ ] **Step 3: Perform the repository deployment and activation preflight**

Run before changing a live limit:

```bash
uptime
docker ps --filter label=ezgha=managed --format '{{.ID}}' | wc -l
cat /sys/fs/cgroup/actions.slice/memory.current
cat "$HOME/.config/systemd/user/agents.slice/memory.current" 2>/dev/null || true
cat "$HOME/.config/systemd/user/automation.slice/memory.current" 2>/dev/null || true
```

Proceed only when load is at most 12, at least 8 of 10 containers are present unless the documented low-load draining exception is proven, no target cgroup is already under pressure, and current use fits below the proposed `MemoryHigh` with the Task 4 margins: 2 GiB for actions, 1 GiB for agents, and 512 MiB for automation. Record current files and effective values for rollback evidence.

- [ ] **Step 4: Run the tracked deployment entrypoint**

Run as the deploy owner:

```bash
./install.sh
bash scripts/host/assert-crash-containment.sh --config "$HOME/.config/ezgha/config.toml"
```

Expected: `install.sh` completes image acquisition before containment activation, installs the exact helpers and receipts, applies the persistent hierarchy, regenerates the user unit with the actual installed binary and normalized endpoint, and restarts the previously active service only after the gate is installed. System `actions.slice` and user workload properties match the specification; no systemd control drop-in exists; `user@UID.service` retains the same live MainPID and reports `ManagedOOMMemoryPressure=auto`; installed helper digests match the deployed commit. If containment verification fails, the installer restores the prior persistent files and reports the rollback result without claiming the service restart succeeded.

- [ ] **Step 5: Verify the generated service and exact binary**

Run:

```bash
systemctl --user status ezgha.service --no-pager -l
systemctl --user show ezgha.service -p ExecStart -p Environment -p NRestarts --no-pager
sha256sum "$HOME/.local/libexec/ezgha/assert-crash-containment.sh" \
          "$HOME/.local/libexec/ezgha/ezgha-start-gate.sh"
```

Expected: `ExecStart` names the stable gate, the actual installed Cargo binary, and the active config; the environment preserves the canonical host endpoint; helper hashes match receipts; the gate succeeds and replaces itself with `ezgha`; and the service is active. Lima remains inactive.

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

Expected: the hard-limit proof records a local cgroup OOM; the oomd proof records a `systemd-oomd` victim beneath `ezghaproof-oomd.slice`; boot ID, user-manager PID, Warp, Docker, and unrelated runners survive both; the host-Docker Gate 8 passes without invoking Lima; the monitor verdict is `HEALTHY`; and the controlled ten-job sample has no material duration or retry regression against its recorded pre-deploy baseline.

- [ ] **Step 8: Update Beads and land the integration unit**

Use `br search` to avoid duplicates, append the exact deployed SHA and evidence path to `ez-gh-actions-sa8c`, update `ez-gh-actions-kdne` with the corrected host-Docker architecture, and close only criteria proven by the live artifacts.

Set `EVIDENCE_DIR` to the directory printed by the successful pressure proof, then run:

```bash
git status --short
git add CLAUDE.md AGENTS.md README.md roadmap/up-changelog-20260831-crash-containment.md \
  systemd/host/actions.slice \
  systemd/host/ezghaproof.slice \
  systemd/host/ezghaproof-hardlimit.slice \
  systemd/host/ezghaproof-oomd.slice \
  systemd/host/ezgha-hard-limit-proof.service \
  systemd/host/ezgha-oomd-proof.service \
  systemd/host/-.slice.d/90-ezgha-oomd-boundary.conf \
  systemd/host/user@.service.d/90-ezgha-oomd-boundary.conf \
  systemd/agents.slice systemd/automation.slice \
  src/service.rs src/main.rs \
  scripts/host/assert-crash-containment.sh \
  scripts/host/ezgha-start-gate.sh \
  scripts/host/proof-allocator.sh \
  scripts/host/install-crash-containment.sh \
  scripts/host/prove-crash-containment.sh \
  install.sh config/config.toml.linux.example doctor-runner \
  docs/verify-exit-criteria.sh docs/host-ops-sudo-block-0725.md \
  .github/workflows/ci.yml \
  tests/crash_containment_policy_test.sh \
  tests/host_control_artifacts_test.sh \
  tests/host_ops_0725_test.sh \
  tests/host_crash_containment_artifacts_test.sh \
  tests/assert_crash_containment_test.sh \
  tests/install_crash_containment_test.sh \
  tests/install_watchdog_gate_test.sh \
  tests/install_uninstall_aux_units_test.sh \
  tests/doctor_runner_host_pressure_test.sh \
  tests/verify_exit_gate8_test.sh \
  tests/prove_crash_containment_test.sh \
  "$EVIDENCE_DIR"
git add -u systemd/ezgha.service.d/10-oomd-omit.conf systemd/psi-oom-watcher.service systemd/psi-oom-watcher.timer scripts/host/psi-oom-watcher.sh
git commit -m "codex/gpt-5.6-sol: enforce workload crash containment"
git push origin HEAD
git status --short --branch
```

Expected: push succeeds, the branch is synchronized with its upstream, and unrelated `.playwright-mcp/` content remains untouched.
