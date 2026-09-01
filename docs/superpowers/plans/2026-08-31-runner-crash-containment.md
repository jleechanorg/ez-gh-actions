# Runner Crash Containment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the Ubuntu host and operator desktop alive under a full ten-runner workload by enforcing finite workload aggregates and workload-local pressure handling on host Docker.

**Architecture:** Host Docker remains the Linux execution backend. Docker runner scopes live under a root-owned finite `actions.slice`; coding agents and automation retain separate finite user slices; `systemd-oomd` monitors those workload roots instead of the whole desktop user manager. One Rust-owned admission guard issues a short-lived opaque permit and is required before every Linux runner-admission-side Docker mutation; the generated main-process wrapper and shell assertion provide an earlier defense-in-depth check. Stop/removal remains available for pressure relief.

**Tech Stack:** Bash, systemd/cgroup v2, Docker, Rust-generated user service, `tomllib`, shell fixture tests

**Spec:** `docs/superpowers/specs/2026-08-31-runner-crash-containment-design.md`

## Global Constraints

- Keep exactly 10 Linux runner slots; runner-count reduction is not a containment mechanism.
- Host Docker at `unix:///var/run/docker.sock` is allowed only when the host containment preflight passes.
- Runner aggregate: `MemoryHigh=26G`, `MemoryMax=28G`, `MemorySwapMax=0`, `TasksMax=6000`, `CPUQuota=2000%`, `IOWeight=25` where supported.
- Agent aggregate: `MemoryHigh=18G`, `MemoryMax=20G`, `MemorySwapMax=2G`, `TasksMax=8192`.
- Automation aggregate: `MemoryHigh=4G`, `MemoryMax=6G`, `MemorySwapMax=1G`, `TasksMax=4096`.
- Workload slices use `ManagedOOMMemoryPressure=kill` and `ManagedOOMMemoryPressureLimit=50%`; both `-.slice` and `user@UID.service` for the deploy owner explicitly use `ManagedOOMMemoryPressure=auto` and `ManagedOOMSwap=auto`, while the broad user service is neutral with `ManagedOOMPreference=none` and `OOMScoreAdjust=0`.
- Docker must use cgroup v2 with the `systemd` driver. Endpoint classification and actual cgroup ancestry are both verified.
- The fixed profile requires at least 62 GiB RAM and 32 logical CPUs; smaller hosts fail closed and require a reviewed profile.
- The roughly 8.5-GiB arithmetic remainder on this host's measured 62.48 GiB is budgeted headroom, not a proof against global kernel OOM.
- No `systemctl set-property` runtime or persistent control drop-in may shadow tracked unit files.
- No new watchdog, polling repair loop, VM fallback, host reboot authority, or VM deletion is permitted.
- Every live mutation is performed by one deploy owner after the repository's load/container preflight.
- Use `/parallel` only for disjoint files/worktrees; `install.sh`, live systemd state, and final verification have one integration owner.
- Keep implementation scoped to policy, systemd artifacts, one assertion/installer path, existing diagnostics, and a narrow Rust containment seam for endpoint config/classification, install verdicts, recovery decisions, and admission guards at existing mutation boundaries; do not change runner scheduling policy or registration semantics.

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
- `systemd/host/user@.service.d/90-ezgha-oomd-boundary.conf`: disable broad desktop-user pressure/swap monitoring and clear subtree-wide oomd/kernel exemptions.
- `systemd/agents.slice`: finite interactive-agent aggregate and direct OOM enrollment.
- `systemd/automation.slice`: finite automation aggregate and direct OOM enrollment.
- `scripts/host/assert-crash-containment.sh`: mutation-free consumer of the Rust topology/containment verdict plus independent effective-property evidence.
- `scripts/host/ezgha-start-gate.sh`: main-process gate that retries only transient assertion failures.
- `scripts/host/proof-allocator.sh`: fixed bounded allocator used by the two proof services.
- `scripts/host/install-crash-containment.sh`: idempotent privileged and user-scope installation.
- `scripts/host/prove-crash-containment.sh`: separately labeled hard-limit and isolated oomd proofs.
- `install.sh`: invoke the containment installer on Linux and install stable helper paths.
- `config/config.toml.linux.example`: host-Docker ten-runner configuration.
- `config/README.md`: staged bootstrap, managed upgrade, and endpoint migration workflow.
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

Create isolated branches/worktrees `codex/crash-policy`, `codex/crash-systemd`, and `codex/crash-assertion` before dispatch. Each lane commits and pushes only its branch; no lane pushes the integration branch. Task 4 begins after B and C because its installer and generated service consume both outputs. Task 5 begins after Task 4 and is the single writer for `install.sh`, watcher retirement, shared operational tests, and CI wiring. Task 6 begins after Tasks 2-5 because its live proofs consume the final hierarchy; Task 5's CI suite discovers Task 6's fixture without another shared-workflow edit. Task 7 is strictly serial and belongs to the deploy owner.

### Task 1: Persist the Crash-Containment Tenets with `/up`

**Files:**
- Modify: `CLAUDE.md`
- Modify: `AGENTS.md`
- Modify: `README.md`
- Modify: `config/README.md`
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

Create `tests/crash_containment_policy_test.sh` with assertions for one full canonical copy in `CLAUDE.md`, a pointer in `AGENTS.md`, accurate host-Docker wording in `README.md`, and the staged bootstrap/start-limit recovery pointers in `README.md` and `config/README.md`:

```bash
assert_line "$REPO_ROOT/CLAUDE.md" "## Crash-containment contract"
assert_line "$REPO_ROOT/CLAUDE.md" "Ten Linux runners remain the capacity contract"
assert_line "$REPO_ROOT/CLAUDE.md" "Backend choice is subordinate to effective crash containment"
assert_line "$REPO_ROOT/AGENTS.md" "See \`CLAUDE.md\` section \"Crash-containment contract\""
assert_line "$REPO_ROOT/README.md" "Jeff-Ubuntu uses host Docker with a system-scope runner aggregate"
assert_line "$REPO_ROOT/README.md" "systemctl --user reset-failed ezgha.service"
assert_line "$REPO_ROOT/config/README.md" "A config-only host is staged bootstrap state"
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
- **Fail closed on missing limits:** do not start or refill runners when the effective aggregate is absent, infinite, installed in the wrong manager scope, or differs from the tracked fixed profile.
- **Guard every admission path:** the Rust admission guard must run before direct `start`, direct or service-managed `serve`, image pre-pull, and every admission-side reconciliation mutation. Pre-daemon recovery has a separate Rust decision that can start only an explicitly configured Colima/Lima backend through the existing bounded command; Docker Desktop is never auto-started. Recovery can never authorize runners or turn HostDocker into VM fallback. A shell wrapper is defense in depth, not the authority; stop/removal stays available for pressure relief.
- **Pressure relief remains independent:** containment drift must not block `systemctl --user stop ezgha.service` followed by `ezgha stop`. Container removal alone is not called durable relief while a supervisor can refill it.
- **One Linux deployment entrypoint:** deploy with `./install.sh`; do not replace it with raw `cargo install` plus `systemctl --user restart`, because the binary, helpers, receipt, config, policy, and generated unit are one transaction.
- **Portable controls only:** every limit, installer action, preflight, and verifier must be git-tracked and reproducible from this repository. A live-only drop-in or one-off `systemctl set-property` is incident evidence, not a completed fix.
- **No competing repair authority:** observation and verification may report drift, but no new watchdog or monitor may restart Docker, Colima, the desktop, or the host.
- **Evidence is claim-specific:** hard-limit containment, oomd victim selection, and desktop survival are separate proofs; none substitutes for another.
```

In `AGENTS.md`, add only:

```markdown
- **Crash containment:** See `CLAUDE.md` section "Crash-containment contract"; it is the canonical statement of backend, capacity, kill-order, and portability requirements.
```

Update `README.md` to state that Jeff-Ubuntu uses host Docker with a system-scope runner aggregate and remove claims that its active daemon necessarily runs inside Colima. Replace the Linux quick start with the two-pass portable bootstrap: the first `./install.sh` only builds `target/release/ezgha` when no config exists, that candidate runs `init` to write a mode-`0600` explicit-endpoint starter config, and the second `./install.sh` atomically installs the binary as part of the sole containment/service transaction. Update `config/README.md` to say a config-only host is staged bootstrap state rather than a managed upgrade. Both documents include the bounded recovery after a persistent transient: inspect status/journal, fix the prerequisite, require `ezgha containment-check --admission --json`, then run `systemctl --user reset-failed ezgha.service` followed by `systemctl --user start ezgha.service`; no automatic limiter reset is introduced.

- [ ] **Step 5: Write the `/up` receipt**

Create `roadmap/up-changelog-20260831-crash-containment.md` with exactly:

```markdown
| Surface | Status | One-line reason |
|---|---|---|
| `CLAUDE.md` | Updated | Canonical crash-containment goal and invariants. |
| `AGENTS.md` | Updated | Pointer to the canonical repository contract. |
| `README.md` | Updated | Active host-Docker topology described accurately. |
| `config/README.md` | Updated | Portable staged-bootstrap and recovery sequence documented. |
```

- [ ] **Step 6: Verify and commit the policy unit**

Run:

```bash
bash tests/crash_containment_policy_test.sh
rg -n 'Crash-containment contract|Backend choice is subordinate|reset-failed ezgha.service|staged bootstrap state' CLAUDE.md AGENTS.md README.md config/README.md
git diff --check
git add CLAUDE.md AGENTS.md README.md config/README.md roadmap/up-changelog-20260831-crash-containment.md tests/crash_containment_policy_test.sh
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
- Modify: `scripts/host/agent-scoped-launch.sh`
- Modify: `scripts/host/agent-cli-scoped.sh`
- Modify: `scripts/host/agent-auto-migrate.sh`
- Create: `tests/host_crash_containment_artifacts_test.sh`
- Modify: `tests/host_control_artifacts_test.sh`
- Modify: `tests/host_ops_0725_test.sh`

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
expect systemd/host/actions.slice CPUQuota=2000%
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
expect systemd/host/user@.service.d/90-ezgha-oomd-boundary.conf ManagedOOMPreference=none
expect systemd/host/user@.service.d/90-ezgha-oomd-boundary.conf OOMScoreAdjust=0
expect systemd/agents.slice MemoryHigh=18G
expect systemd/agents.slice MemoryMax=20G
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
CPUQuota=2000%
MemoryAccounting=yes
CPUAccounting=yes
IOAccounting=yes
IOWeight=25
ManagedOOMMemoryPressure=kill
ManagedOOMMemoryPressureLimit=50%
```

Create a top-level `ezghaproof.slice` with finite `MemoryMax=1G`, `MemorySwapMax=0`, `TasksMax=128`, and both `ManagedOOM*` policies set to `auto`. Create `ezghaproof-hardlimit.slice` with `MemoryHigh=384M`, `MemoryMax=512M`, and `MemorySwapMax=0`, but no `ManagedOOM*` policy. Create `ezghaproof-oomd.slice` with `MemoryHigh=384M`, `MemoryMax=768M`, `MemorySwapMax=0`, `ManagedOOMMemoryPressure=kill`, and `ManagedOOMMemoryPressureLimit=20%`. By systemd slice naming rules both are descendants only of the top-level proof slice, which is a sibling of production `actions.slice`.

Create fixed `ezgha-hard-limit-proof.service` and `ezgha-oomd-proof.service` system units. Each has the corresponding proof `Slice=`, `Type=oneshot`, `DynamicUser=yes`, `NoNewPrivileges=yes`, `PrivateTmp=yes`, `ProtectSystem=strict`, `ProtectHome=yes`, no capabilities, no credentials, no Docker socket, and a literal `ExecStart=/usr/local/libexec/ezgha/proof-allocator.sh MODE`. The services accept no arbitrary command or environment override. The tracked allocator validates its literal mode and uses only `/usr/bin/python3` stdlib allocation. Hard-limit mode grows a touched anonymous working set beyond the 512-MiB child `MemoryMax`. Oomd mode grows to a fixed 640 MiB, above `MemoryHigh=384M` but below `MemoryMax=768M`, then continuously retouches every page for 75 seconds. The harness reads the effective global `DefaultMemoryPressureDurationSec` through `systemd-analyze cat-config systemd/oomd.conf`, records it, and rejects values above 45 seconds because they cannot leave safe setup/cleanup slack inside the outer 90-second timeout. It samples the child cgroup's exact `memory.pressure` `full avg10` field every second and requires a continuous at-or-above-20% interval spanning that effective duration plus a new journal victim beneath the exact proof slice; a single PSI sample, `some`, another averaging window, allocator completion, or a kernel OOM alone cannot pass oomd-selection. The proof script may invoke privileged `systemctl` only with literal lifecycle operations and these exact service names; do not permit `systemd-run`, a shell, wildcard unit names, or command/environment overrides.

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
ManagedOOMPreference=none
OOMScoreAdjust=0
```

The root override closes vendor drift that could otherwise monitor every system and desktop cgroup for swap. The assertion walks `-.slice`, `user.slice`, `user-$UID.slice`, and `user@UID.service` and rejects either `ManagedOOMMemoryPressure=kill` or `ManagedOOMSwap=kill` on the desktop path. It also rejects `ManagedOOMPreference=avoid|omit` or negative `OOMScoreAdjust` on the broad user service. Do not implement the earlier `99-protect-ui.conf` proposal from `bd-a7c`: `ManagedOOMMemoryPressureLimit=0%` is ignored in `auto` mode, while `omit` plus `OOMScoreAdjust=-500` protects the entire session subtree and displaces victims instead of containing the runner source.

- [ ] **Step 5: Update user workload slices and retire the inverted exemption**

Change `systemd/agents.slice` to `MemoryHigh=18G`, `MemoryMax=20G`, retain `MemorySwapMax=2G` and `TasksMax=8192`, then add:

```ini
ManagedOOMMemoryPressure=kill
ManagedOOMMemoryPressureLimit=50%
```

Add the same OOM directives to `systemd/automation.slice` without changing its 4G/6G/1G/4096 envelope. Update stale peak/budget comments from fresh read-only evidence: `agents.slice` was about 16.3 GiB current, 17.1 GiB peak, and about 1.1 GiB anon+kernel with the remainder primarily reclaimable file cache on 2026-08-31. `MemoryHigh=18G` therefore preserves the 1-GiB activation margin against enforceable `memory.current`, while `MemoryMax=20G` contains later growth.

Remove the `AGENT_SLICE_OPT_OUT` short-circuit and its documentation from both supported launch wrappers and the migration helper. Missing `agents.slice` remains fail-closed; an agent command must not silently run in `app.slice` or directly under `user@.service`. Update the existing wrapper fixtures in `tests/host_control_artifacts_test.sh` to require scoped launch and to fail when any opt-out path or documentation remains. Update only the exact `agents.slice` 10G/12G expectations in `tests/host_control_artifacts_test.sh` and `tests/host_ops_0725_test.sh` to 18G/20G in this same lane; leave their watcher sections intact for the serial integration task. Legacy watcher/exemption removal belongs to Task 5 with all consumers, so this Task 2 commit remains independently green.

- [ ] **Step 6: Validate units and commit**

Run:

```bash
bash tests/host_crash_containment_artifacts_test.sh
systemd-analyze verify systemd/host/actions.slice systemd/host/ezghaproof.slice systemd/host/ezghaproof-hardlimit.slice systemd/host/ezghaproof-oomd.slice systemd/host/ezgha-hard-limit-proof.service systemd/host/ezgha-oomd-proof.service systemd/agents.slice systemd/automation.slice
git diff --check
git add systemd/host/actions.slice systemd/host/ezghaproof.slice systemd/host/ezghaproof-hardlimit.slice systemd/host/ezghaproof-oomd.slice systemd/host/ezgha-hard-limit-proof.service systemd/host/ezgha-oomd-proof.service systemd/host/-.slice.d/90-ezgha-oomd-boundary.conf systemd/host/user@.service.d/90-ezgha-oomd-boundary.conf scripts/host/proof-allocator.sh systemd/agents.slice systemd/automation.slice scripts/host/agent-scoped-launch.sh scripts/host/agent-cli-scoped.sh scripts/host/agent-auto-migrate.sh tests/host_crash_containment_artifacts_test.sh tests/host_control_artifacts_test.sh tests/host_ops_0725_test.sh
git commit -m "codex/gpt-5.6-sol: define workload-first systemd limits"
git push origin HEAD
```

Expected: test PASS and `systemd-analyze verify` exits zero.

### Task 3: Build the Read-Only Containment Assertion

**Files:**
- Create: `scripts/host/assert-crash-containment.sh`
- Create: `tests/assert_crash_containment_test.sh`

**Interfaces:**
- Consumes: systemd properties from Task 2, `[limits].cgroup_parent` from the TOML config, and canonical topology JSON from an exact `ezgha topology` probe path implemented in Task 4.
- Produces: `assert-crash-containment.sh --config PATH --ezgha-binary PATH`, exit 0 for a valid topology, exit 78 for a proven policy violation, and exit 75 for a transient/indeterminate probe. It consumes, but does not replace, the canonical Rust `ezgha containment-check --admission --json` verdict.

- [ ] **Step 1: Create fixture tests for every decision branch**

Build temporary topology-probe, `systemctl`, and `oomctl` stubs plus a fake cgroup tree. The topology stub implements the future `ezgha topology --config PATH --json` contract. Use these environment seams:

```bash
EZGHA_TOPOLOGY_PROBE="$BIN/ezgha"
EZGHA_SYSTEMCTL_BIN="$BIN/systemctl"
EZGHA_OOMCTL_BIN="$BIN/oomctl"
EZGHA_CGROUP_ROOT="$TMP/cgroup"
```

Cover:

```text
host socket + systemd cgroup v2 + exact finite values        => exit 0
host profile on <62 GiB RAM or <32 logical CPUs              => exit 78
Colima/Lima socket endpoint                                 => exit 0, reports vm-contained
canonical endpoint + VM daemon metadata                     => exit 78, contradictory topology
remote or unknown endpoint                                  => exit 78
host socket + Docker cgroup driver cgroupfs                  => exit 78
host socket + transient docker-info failure after retries    => exit 75
host socket + inaccessible oomctl after bounded retry         => exit 75
host Docker + missing actions.slice                          => exit 78
host Docker + memory.high=max/infinity                       => exit 78
host Docker + wrong cpu.max                                  => exit 78
host Docker + cgroup_parent != actions.slice                 => exit 78
host Docker + root/user@/ancestor pressure or swap kill      => exit 78
host Docker + broad user@ avoid/omit or negative OOM score   => exit 78
host Docker + agents.slice MemoryMax=infinity                => exit 78
host Docker + live 10-oomd-omit or effective omit/-1000      => exit 78
installed binary/helper/unit receipt path, mode, or SHA mismatch => exit 78
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

Do not duplicate endpoint policy in Bash. Invoke the exact passed binary as `ezgha topology --config PATH --json` with three bounded attempts over at most 15 seconds, parse its structured `kind`, normalized endpoint, OS, daemon kernel relation, cgroup version, and cgroup driver, and branch only on that canonical result. `HostDocker` continues with the host checks below, `VmDocker` reports the host profile not applicable, `Indeterminate` on Linux is a proven installation/startup policy violation, and a transient probe failure returns `75`. Then compare host cgroup files to exact byte/CPU values:

```text
memory.high      27917287424
memory.max       30064771072
memory.swap.max  0
pids.max         6000
cpu.max          2000000 100000
```

Use `systemctl show actions.slice` and `systemctl --user show agents.slice automation.slice ezgha.service` for OOM and effective-property assertions. Use system `systemctl show -- -.slice user.slice user-$(id -u).slice user@$(id -u).service` plus user-manager `systemctl --user show app.slice session.slice`, and require both `ManagedOOMMemoryPressure=auto` and `ManagedOOMSwap=auto` along every desktop ancestor; reject either policy at `kill`. Require `user@UID.service` to report `ManagedOOMPreference=none` and `OOMScoreAdjust=0`, rejecting the broad-session `avoid`/`omit` plus negative-score proposal. Reject the live `~/.config/systemd/user/ezgha.service.d/10-oomd-omit.conf`, `ManagedOOMPreference=omit`, or `OOMScoreAdjust=-1000` on `ezgha.service`. Run unprivileged `oomctl --no-pager` through a bounded injectable binary and require it to list the intended system `actions.slice` plus user-manager `agents.slice` and `automation.slice`, with no broad root, user root, app root, or session root; inability to query is transient exit `75`, and missing effective roots are policy exit `78`. Resolve each managed container's actual `/proc/<pid>/cgroup` path and require it below `/actions.slice`; Docker's configured `CgroupParent` alone is not sufficient.

Require at least 62 GiB `MemTotal` and 32 logical CPUs before accepting this fixed profile. Add boundary fixtures that reject 60 GiB and 61.99 GiB while accepting 62 GiB. Verify `io.weight=25` when the I/O controller is present in `cgroup.controllers`; otherwise report `io_controller=unavailable` without claiming I/O protection.

When invoked from the installed stable path, validate the versioned deployment receipt rather than comparing with a mutable checkout. The atomically written receipt records the deployed Git SHA and, for the `ezgha` binary, `assert-crash-containment.sh`, `ezgha-start-gate.sh`, root-owned `proof-allocator.sh`, generated `ezgha.service`, and generated `ezgha-alert@.service`, the artifact role, candidate/source path, installed absolute path, mode, and SHA-256. A missing/malformed receipt or any installed path, mode, or digest mismatch is a policy violation. Changing checkout files after installation does not invalidate an otherwise intact deployment; rollback restores the receipt and every listed artifact together.

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

### Task 4: Build the Installer and Generated Service

**Files:**
- Create: `scripts/host/install-crash-containment.sh`
- Create: `scripts/host/ezgha-start-gate.sh`
- Modify: `src/backend.rs`
- Create: `src/containment.rs`
- Modify: `src/config.rs`
- Modify: `src/service.rs`
- Modify: `src/main.rs`
- Modify: `src/docker_backend.rs`
- Modify: `config/config.toml.linux.example`
- Create: `tests/install_crash_containment_test.sh`

**Interfaces:**
- Consumes: Task 2 unit files and Task 3 assertion.
- Produces: canonical `ezgha topology --json`, canonical read-only `ezgha containment-check --install-static|--install-dynamic|--admission --json` verdicts, opaque short-lived `RuntimeAdmission` and private `TransactionAdmission` scopes from one in-memory `AdmissionPermit` implementation, a deployment-state classifier, a canonical lock primitive, primitive `install-crash-containment.sh --preflight|--check|--install|--rollback RECEIPT`, and a generated, endpoint-correct main-process startup gate. Static install preflight proves the proposed endpoint, hardware, privilege, `Bootstrap`/`ManagedUpgrade`/`LegacyMigration`/`Mixed` state, current use where applicable, and rollback storage without requiring a reachable VM daemon. Only a recognized proposed Colima/Lima endpoint on a supported platform may then start that exact VM; Docker Desktop returns `NoRecovery`. Dynamic preflight proves the reachable daemon topology/driver and `oomctl` before image work. Neither verdict is an admission capability. Runtime admission requires the effective installed profile and every final receipt artifact. Transaction admission additionally requires the inherited lock FD and candidate directory, validates final non-unit artifacts plus staged receipt-bound units, and can authorize only unit installation/reload. Neither scope is serialized through the CLI. Task 4 does not edit `install.sh` or retire legacy watcher/exemption state; Task 5 is the sole transaction and quiescence orchestrator and extends the primitive rollback receipt serially.

- [ ] **Step 1: Write installer fixtures before implementation**

Stub `sudo`, system and user `systemctl`, Docker, and `install`. Assert that host-Docker `--install` executes these logical operations in order:

```text
reject /run/systemd/*control overrides that would shadow tracked units
before any mutation prove proposed endpoint, >=62GiB/32CPU, privilege, classified deployment state, applicable current-use margins, and rollback storage
for an explicit recoverable Colima/Lima endpoint only, permit one exact backend start; then prove reachable topology, cgroup v2/systemd driver, and unprivileged oomctl
before image work or live policy mutation require both static and dynamic verdicts
classify upgrade versus fresh state; upgrades read all three real memory.current files and require 1G/1G/512M margins
stage and syntax-check every persistent unit before touching /etc or ~/.config
install systemd/host/actions.slice and fixed proof units -> /etc/systemd/system
install root/user@ overrides -> /etc/systemd/system/{-.slice.d,user@.service.d}
systemctl daemon-reload
systemctl start actions.slice
remove ~/.config/systemd/user/agents.slice.d/99-local-unlimited.conf
systemctl --user daemon-reload
verify effective values; restore prior persistent files, reload again, and verify restored effective values on mismatch
```

Assert that VM Docker skips the system host profile; contradictory endpoint/daemon metadata, cgroupfs, inaccessible `oomctl`, less than 62 GiB RAM, current use above an activation margin, a control drop-in, or missing privilege causes a nonzero exit before any file write/reload/restart and without printing success. Classify from the proposed config plus committed artifacts, not config existence alone:

- `Bootstrap`: mode-`0600` proposed config with explicit endpoint; no receipt/helper set, generated units, active/enabled main service, managed-prefix container, or registered-prefix runner. The active config may be absent or byte-identical to the candidate.
- `ManagedUpgrade`: complete receipt and helpers, both generated units, active config, and all three expected effective cgroups; exact current-use margins are mandatory.
- `LegacyMigration`: a recognized complete pre-receipt service/config/runtime signature; it is never silently adopted as bootstrap.
- `Mixed`: partial receipt/helper/unit/cgroup state, an unexplained differing active config, orphaned prefix runner, or any other incomplete combination; fail before image, Docker runner, policy, config, or service mutation.

Receipt-bound units present only in the candidate directory are a transaction-internal transition, valid solely with the exact held lock and candidate proof. Without it, including after interruption, the state is `Mixed`, runtime admission fails, no service starts, and rollback restores or removes the complete receipt/artifact set.

The dynamic topology/driver/`oomctl` checks run only after the daemon is reachable, including after the sole allowed exact Colima/Lima start. Include config-only bootstrap success, config mismatch, complete managed upgrade, every partial-artifact rejection, recognized legacy migration, orphaned registration, mixed-state rejection, and 60-GiB/61.99-GiB rejection fixtures. The Task 4 receipt records both `is-active` and `is-enabled`; rollback fixtures cover disabled/inactive, enabled/inactive, and enabled/active prior states.

- [ ] **Step 2: Run installer fixtures and confirm the red state**

Run:

```bash
bash tests/install_crash_containment_test.sh
```

Expected: FAIL because the installer does not exist.

- [ ] **Step 3: Implement the idempotent installer**

`--preflight` is read-only and composes the static and dynamic phases when the configured daemon is already reachable. Static phase validates the mode-`0600` proposed endpoint, fixed hardware profile, required privilege, classified deployment state, runtime-cgroup paths/current use for `ManagedUpgrade`, and enough rollback storage before mutation. Dynamic phase proves endpoint-aware daemon topology, Docker cgroup v2/systemd driver, and unprivileged `oomctl`. A local `cargo build --locked --release` may produce the exact candidate topology probe before static preflight; it may not contact, start, restart, or mutate Docker or either service manager. On an explicit recognized Colima/Lima endpoint with an unreachable daemon, only a successful static verdict may authorize starting that exact VM, and dynamic preflight must then pass before image or policy work. Canonical host, Docker Desktop, remote, inherited-only, indeterminate, and unsupported-platform endpoints produce `NoRecovery`; stopped Docker Desktop returns a typed transient dynamic-preflight failure. `--check` runs the installed-state branch and then delegates to `assert-crash-containment.sh`; neither mode mutates. `--install` must pass both applicable phases and the Task 5-owned upgrade fence before its first image/file/policy mutation and uses `${SUDO_BIN:-sudo}` for `/etc/systemd/system` with fixture roots through explicit test-only environment variables already established by repository shell tests. Managed upgrades reject missing runtime cgroups and require an activation margin below each proposed `MemoryHigh`: 1 GiB for `actions.slice`, 1 GiB for `agents.slice`, and 512 MiB for `automation.slice`. They record both `memory.current` and `memory.stat`; the enforceable admission decision uses `memory.current` and must not discount file cache. Bootstrap may lack not-yet-installed cgroups because config-only staged data is not deployment evidence. The 1-GiB actions margin permits the declared ten-container maximum of about 24.4 GiB below `MemoryHigh=26G`; a 2-GiB margin would incorrectly reject the full supported fleet. It stages and verifies persistent files, snapshots all replaced system/user units and helpers plus generated `ezgha.service`, companion `ezgha-alert@.service`, and their applicable active/enabled states, installs atomically, reloads managers, and verifies effective properties. A failure restores every snapshot, reloads both managers again, restores enabled/disabled state, restarts the prior service only if it was active, and verifies the effective restored state before returning failure. It never calls `systemctl set-property`, so tracked files remain the only resource-policy owner.

Do not stop or restart a live Lima VM. When host Docker is proven and `lima-vm@colima.service` is inactive, disable its future auto-start without `--now`; when it is active, report topology drift and leave it untouched for operator review.

- [ ] **Step 4: Generate the gated service with the actual binary path**

Create `scripts/host/ezgha-start-gate.sh` and update `src/service.rs` so the generated Linux unit invokes it as the main process. Pass the exact `current_exe()` value and config path already owned by `install-service`; do not hard-code `~/.local/bin/ezgha` or assume a Cargo install prefix. The wrapper passes that same binary to the assertion's `--ezgha-binary`, so topology and the authoritative containment verdict have one Rust owner. Exit `0` uses `exec "$binary" --config "$config" serve`, while exits `75`, `78`, and unexpected nonzero statuses return unchanged. The assertion's probes are bounded to 15 seconds. The wrapper is not a timer, background process, independent daemon, or sole admission guard.

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

Remove the unconditional `After=lima-vm@colima.service` and `Wants=lima-vm@colima.service` lines from the generated unit. Add a backward-compatible defaulted `BackendConfig` in `src/config.rs` with `docker_endpoint: Option<String>` serialized as `[backend].docker_endpoint`. Linux install/admission requires a recognized explicit value in the proposed/live config and rejects missing, inherited-only, remote, or ambiguous context. `ezgha init` persists the normalized recognized endpoint it actually classified, and table tests cover old-config parsing plus new Linux persistence.

For legacy Mac configs only, add a bounded Darwin compatibility resolver. In order, it considers a nonempty explicit override, the installed launchd plist endpoint, the active Docker context, and recognized Colima/Lima/Docker Desktop sockets; it accepts one normalized consistent endpoint and returns `Indeterminate` on conflict, unknown transport, or no evidence. Direct legacy runtime uses that in-memory result nonfatally until `ezgha init` or `install-service` atomically persists it; after persistence the config wins over ambient state. Only a uniquely proven Colima/Lima endpoint may recover. Reachable Docker Desktop classifies as `VmDocker`, stopped Docker Desktop returns `NoRecovery`, and ambiguity starts nothing. Linux never invokes this resolver. Tests cover every precedence/conflict branch and prove legacy Mac Colima recovery does not regress.

Make the config field, not ambient `DOCKER_HOST` or `DOCKER_CONTEXT`, the single source for the generated service and every Rust Docker subprocess after migration. For host Docker, emit the explicit `Environment=DOCKER_HOST=unix:///var/run/docker.sock` plus `UnsetEnvironment=DOCKER_CONTEXT`. For recognized Colima/Lima/Docker Desktop, emit the correctly escaped explicit endpoint and also unset `DOCKER_CONTEXT`. All Rust Docker subprocesses use the same endpoint with `env_remove("DOCKER_CONTEXT")`; canonical host commands must never start Lima, only explicit Colima/Lima endpoints may use the existing bounded recovery, and Docker Desktop remains non-recoverable when stopped. Preserve `WatchdogSec=300`, `NotifyAccess=all`, `StartLimitIntervalSec=300`, `StartLimitBurst=5`, `Restart=on-failure`, and `RestartSec=30`. Five 15-second assertion failures plus four 30-second restart delays fit within 300 seconds, so persistent exit `75` reaches the existing limiter. `TimeoutStartSec=150` covers the assertion plus the daemon's existing 120-second readiness window; systemd watchdog timing starts after `READY=1`, and a source comment plus generated-unit test pins that distinction. README and `config/README.md` pin the manual recovery after a persistent transient: fix the prerequisite, require `ezgha containment-check --admission --json`, then `reset-failed` and `start`; no monitor resets the limiter.

Update `src/service.rs::install_systemd` so direct Linux installation obtains fresh `RuntimeAdmission` before writing, enabling, or starting a unit; direct `ezgha install-service` cannot install a bypass when containment is missing. Transactional deferred installation instead requires the private `TransactionAdmission` scope described below and cannot enable or start. The ordinary path records the full previous `ezgha.service` and companion `ezgha-alert@.service` bytes plus applicable active/enabled states, writes both units, reloads, enables, and restarts the main unit when previously active; this makes later integration regenerate an active unit instead of silently leaving the old `ExecStart` running. If enable, restart, or post-start verification fails, restore both previous units and enabled state, reload, restart the previous main unit only when it was active, and report whether rollback verification succeeded. Add Rust unit tests proving the generated unit uses the passed executable path, contains no Lima dependency, preserves the bounded restart settings, uses the wrapper, always emits the explicit classified `DOCKER_HOST`, unsets `DOCKER_CONTEXT`, and correctly escapes recognized VM endpoints. Add service-install fixtures proving missing containment causes zero unit writes, an already-active unit is regenerated/restarted, and a failed gated restart restores both prior units plus the prior main `ExecStart` and active/enabled state. Backend-recovery tests prove host Docker never invokes Lima, an explicit Colima/Lima socket retains bounded recovery on supported platforms, and a stopped Docker Desktop endpoint produces `NoRecovery`.

Promote the existing canonical `serve.lock` to the installation fence. `start`, `serve`, `stop`, and the transaction all use the active config's `state_dir`; the static-verdict JSON returns the normalized lock path, so shell does not parse TOML or reconstruct it. Release builds ignore/reject `EZGHA_SKIP_LOCK`, with test injection available only under `cfg(test)`. Managed and legacy upgrades reject proposed changes to `state_dir`, target/scope, or runner prefix before quiescence. Task 5 stops the old unit, requires inactive/MainPID exit within 30 seconds, opens a fixed inheritable descriptor, explicitly clears `FD_CLOEXEC`, acquires exclusive `flock` within 15 seconds, and retains that open-file description through success or rollback. The drain primitive and deferred service installer accept its number only through `--transaction-lock-fd <n>`. Rust bounds-checks the descriptor, matches `fstat` identity against a freshly opened canonical lock file, and requires nonblocking exclusive `flock` on a second open-file description to fail, proving live contention without reacquiring through the inherited FD. Reject unlocked, wrong-inode, closed, or exec-lost descriptors. Legacy drain has a fixed 30-minute ceiling and never cancels a busy job. Add `install-service --defer-start --transaction-lock-fd <n> --unit-candidate-dir <path>`, valid only with the inherited FD, receipt-bound staged unit candidates, and a fresh transaction-scoped permit, to install both units without starting them. Fixtures pin `stop -> inactive -> lock -> first mutation`, exact timeouts, successful FD inheritance, all four FD rejection branches, no nested-lock deadlock, busy-job preservation, lock-timeout zero-write behavior, deferred generation, one final start after release, and restoration/start only for a formerly active service.

Preserve the existing alert contract while regenerating the service: `OnFailure=ezgha-alert@%N.service` and the fail-open `ExecStopPost=-ACTUAL_EXE --config ACTUAL_CONFIG systemd-alert-hook --source exec-stop-post --unit %n` remain on `ezgha.service`. The companion template remains a 30-second `Type=oneshot` invoking the same exact binary/config with `systemd-alert-hook --source on-failure --unit %i`, and inherits the explicit endpoint/context-clearing environment. Generated-unit tests pin both directives, both hook argument sets, the alert timeout, and byte-exact rollback of both units.

Own `BackendTopology` and `ezgha topology --json` in `src/backend.rs`. The normalized explicit endpoint plus daemon metadata produce `HostDocker`, `VmDocker` (recognized Colima, Lima, or Docker Desktop), or `Indeterminate`; `Platform.daemon_in_vm` is only metadata input. Create `src/containment.rs` as the single Rust owner of the three explicit `ezgha containment-check` modes and scoped `AdmissionPermit`; bare `containment-check --json` is rejected. Static-install, dynamic-install, and admission CLI modes expose typed read-only verdict JSON only. The permit has private fields, records topology, normalized endpoint, scope, and check time, expires quickly, cannot be constructed by callers, and is returned only to internal Rust callers. `RuntimeAdmission` requires the exact effective host invariants and every final installed receipt artifact. `TransactionAdmission` additionally requires the validated inherited lock FD and candidate directory, checks final non-unit artifacts plus staged unit modes/digests, and exposes only atomic two-unit installation/verification and manager reload; its type cannot call start, pre-pull, reconciliation, registration, or runner creation. On Linux, require fresh runtime admission before `prepull_probe_image` and inside `ensure_count_outcome` before stale-container removal, JIT registration, or `docker run`. Thread that scope into every admission-capable helper, keep `start_one` private, and add compile-time/API fixtures that fail if runner functions accept an unguarded or transaction-scoped call. `Commands::Start` therefore cannot bypass the guard, `Commands::Serve` obtains an initial permit before pre-pull and renews inside every reconciliation tick, and direct `ezgha serve` is no less protected than systemd startup. A canonical host endpoint that is temporarily unreachable returns transient failure and never starts Lima; only an explicit recognized Colima/Lima endpoint may receive the separate bounded recovery decision below, after which full classification must succeed. Docker Desktop produces `NoRecovery` when stopped. The shell wrapper calls `--admission --json` for early failure but is defense in depth.

Define the pre-daemon `RecoveryDecision` separately from admission: it is derived only from the persisted normalized endpoint and platform, is not a runner capability, and can authorize only the existing bounded start of the exact configured Colima/Lima backend on a supported platform. Canonical host, Docker Desktop, remote, inherited-context, indeterminate, and unsupported-platform endpoints always produce `NoRecovery`; tests pin the stopped-Docker-Desktop transient failure. After a permitted VM start makes the daemon reachable, Rust must rerun full topology classification and obtain `RuntimeAdmission` before pre-pull, stale reconciliation, JIT registration, or runner creation. Tests prove the recovery decision cannot reach Docker runner commands or convert a failed HostDocker admission into VM fallback.

Do not gate pressure relief. The documented durable sequence is `systemctl --user stop ezgha.service` followed by `ezgha stop`; both remain callable when admission fails. A bare `ezgha stop` while `serve` remains active is documented as temporary because the next reconciliation may refill.

Thread `BackendTopology`, not raw `daemon_in_vm`, into `effective_limits_with_capacity`, `resolve_and_log_memory_budget`, and `preview_memory_budget`. `HostDocker` returns `MemoryBudgetPreview::NotApplicable`, ignores VM-only fields, skips `validate_host_envelope`, and clamps per-runner requests only to raw daemon capacity while system `actions.slice` owns the aggregate. `VmDocker` preserves the existing VM ceiling, 4-GiB reserve, floor, and preview. `Indeterminate` preserves the existing non-fatal `Ok(None)`/warning runtime behavior on Mac and other pre-existing installs; new Linux admission rejects it before any runner mutation. `ezgha init` persists `vm_total_mb` only for `VmDocker`. Add table-driven Linux and Mac tests proving canonical host behavior, recognized Docker Desktop/Colima/Lima behavior, no Mac startup regression, host fields ignored, the existing 2,754-MiB VM result, preserved indeterminate no-op behavior, direct `start` rejection, direct `serve` rejection before pre-pull, per-tick drift rejection, and host Docker's inability to invoke Lima recovery.

The privileged installer also installs `scripts/host/proof-allocator.sh` atomically to root-owned `/usr/local/libexec/ezgha/proof-allocator.sh` before verifying the proof services. Fixture tests require mode `0755`, the receipt-recorded installed digest, fixed service paths, and rollback removal/restoration; a missing allocator is a failed install, never deferred to the live proof.

- [ ] **Step 5: Correct the Linux host-Docker example**

In `config/config.toml.linux.example`, retain `count = 10`, set `[backend].docker_endpoint = "unix:///var/run/docker.sock"`, and preserve standard selectors while adding the confirmed fleet selector, so labels become `[self-hosted, self-hosted-mikey, ezgha, ez-runner-c, Linux, X64]`. Set `runner_floor_mb = 2500`, set `limits.memory_mb = 2500`, and remove the explicit Colima-only `vm_total_mb`, `guest_reserve_mb`, and `host_reserve_mb` claims. The capacity proof deliberately selects the confirmed four-label subset `[self-hosted, self-hosted-mikey, ezgha, ez-runner-c]`; `ez-runner-c` is absent from both Mac and Linux-canary examples, so those jobs cannot escape to another fleet after the registry collision check, while the additive `Linux`/`X64` labels preserve normal fresh-host consumers. Update config/JIT payload fixtures to prove the endpoint and all six labels are persisted and registered. State the blast radius explicitly: this aligns the tracked fresh-machine default from 3000 to the already-live Jeff-Ubuntu value of 2500 MiB, a 16.7% reduction for new hosts that may expose memory-heavy jobs, additively migrates the live four-label fleet to six labels, and persists the already-effective host socket without removing a selector. Explain that the sum of tracked workload hard caps leaves about 8.5 GiB of budgeted headroom but does not cap desktop, kernel, Docker, or other system memory. Activation records the existing live value and must stop for reviewed profile sizing rather than silently lowering a host above 2500 MiB; release evidence requires the bounded job-outcome sample and ten-worker proof.

- [ ] **Step 6: Verify install behavior and commit**

Run:

```bash
bash -n scripts/host/install-crash-containment.sh scripts/host/ezgha-start-gate.sh tests/install_crash_containment_test.sh
cargo test backend::tests
cargo test service::tests
cargo test backend_restart
cargo test memory_budget
bash tests/install_crash_containment_test.sh
bash tests/assert_crash_containment_test.sh
git diff --check
git add scripts/host/install-crash-containment.sh scripts/host/ezgha-start-gate.sh src/backend.rs src/containment.rs src/config.rs src/service.rs src/main.rs src/docker_backend.rs src/github.rs config/config.toml.linux.example tests/install_crash_containment_test.sh
git commit -m "codex/gpt-5.6-sol: install host crash-containment policy"
git push origin HEAD
```

Expected: all focused installer and assertion tests PASS.

### Task 5: Make Doctor and Exit Gates Verify Effective Containment

**Files:**
- Modify: `install.sh`
- Modify: `scripts/host/install-crash-containment.sh`
- Modify: `doctor-runner`
- Modify: `docs/verify-exit-criteria.sh`
- Modify: `docs/host-ops-sudo-block-0725.md`
- Modify: `.github/workflows/ci.yml`
- Delete: `systemd/ezgha.service.d/10-oomd-omit.conf`
- Delete: `systemd/psi-oom-watcher.service`
- Delete: `systemd/psi-oom-watcher.timer`
- Delete: `scripts/host/psi-oom-watcher.sh`
- Modify: `tests/install_watchdog_gate_test.sh`
- Modify: `tests/install_uninstall_aux_units_test.sh`
- Modify: `tests/host_control_artifacts_test.sh`
- Modify: `tests/host_ops_0725_test.sh`
- Modify: `tests/doctor_runner_host_pressure_test.sh`
- Modify: `tests/verify_exit_gate8_test.sh`
- Create: `tests/crash_containment_suite.sh`

**Interfaces:**
- Consumes: Task 3 assertion output and Task 4 installed paths.
- Produces: one atomic installation path, retirement of the conflicting watcher/exemption stack, read-only topology diagnostics, and a CI-enforced hard harness gate.

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
agents_memory_high=18G
agents_memory_max=20G
actions_oomd=kill@50%
desktop_user_oomd=auto
desktop_ancestor_oomd=none
ezgha_oom_preference=none
ezgha_oom_score_adjust=0
oomctl_user_roots=agents.slice,automation.slice
control_dropin_drift=none
verdict=PASS
```

Add an infinite `actions.slice` fixture expecting `verdict=FAIL` and a diagnostic naming `MemoryMax`.

- [ ] **Step 2: Add failing monitoring and Gate 8 fixtures**

Extend `tests/verify_exit_gate8_test.sh` with mutually exclusive host-Docker and Colima fixtures. The host fixture passes only when Docker uses cgroup v2/systemd, every managed container both reports `actions.slice` and has an actual PID cgroup path below `/actions.slice`, system values exactly match the profile, workload OOM enrollment is effective, `-.slice`, `user.slice`, `user-UID.slice`, `user@UID.service`, `app.slice`, and `session.slice` are `auto` for both pressure and swap, `user@UID.service` is neutral with `ManagedOOMPreference=none` and `OOMScoreAdjust=0`, and unprivileged `oomctl` lists only the intended finite workload roots rather than the broad user manager or desktop. This intentionally replaces Ubuntu's vendor `user@.service ManagedOOMMemoryPressure=kill`, the observed whole-session crash blast radius, with direct finite workload roots; it does not claim that an uncapped desktop application can never cause global OOM. The fixture also requires no control drop-in shadows the tracked policy, the unlimited agent override is absent, every detected supported agent CLI PID is beneath the effective finite `agents.slice`, no `AGENT_SLICE_OPT_OUT` code/documentation remains, and `ezgha.service` has neither `ManagedOOMPreference=omit` nor `OOMScoreAdjust=-1000`. Its admission arithmetic must read and require the exact finite aggregate `actions.slice MemoryMax=28G + agents.slice MemoryMax=20G + automation.slice MemoryMax=6G = 54G`, require at least 62 GiB physical RAM, and report the measured roughly 8.5-GiB remainder explicitly; wrong, missing, or infinite values fail. In host mode, exclude inactive `app-lima-vm.slice` from arithmetic and never invoke `limactl`; retain guest checks only in explicit Colima mode.

Retire the old watcher stack atomically in this task. In the same commit: delete the four tracked watcher/exemption artifacts; remove their ordinary install and uninstall loops; extend the installer to disable/remove the installed timer, service, stable script, and live `~/.config/systemd/user/ezgha.service.d/10-oomd-omit.conf`; verify `ManagedOOMPreference` is not `omit` and `OOMScoreAdjust` is not `-1000`; remove any legacy `systemctl set-property --runtime actions.slice` path; update every active test and operator document; and replace Gate 7/8 watcher checks with effective `systemd-oomd` root enrollment and finite-cgroup checks. Rewrite `docs/host-ops-sudo-block-0725.md` to name the watcher and exemption as retired and point to the tracked containment installer. Add a regression scan that fails when active surfaces (`install.sh`, `docs/verify-exit-criteria.sh`, `docs/host-ops-sudo-block-0725.md`, `README.md`, or `CLAUDE.md`) instruct users to install, enable, or depend on `psi-oom-watcher` or `10-oomd-omit.conf`; historical activity logs may retain incident references. Add a Task 5-owned forced-failure fixture that begins with byte-distinct installed watcher units/script and live exemption, plus active/enabled watcher state; inject failure after retirement and prove exact file bytes, prior enabled/active states, and effective exemption properties are restored. No intermediate commit may delete a source artifact while an installer, verifier, or test still depends on it.

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

Make `install.sh` the single deployment transaction and the sole owner of commit/rollback ordering; update `CLAUDE.md` Gate 0 so Linux deployment invokes this entrypoint and removes raw `cargo install --path .` plus direct restart as an accepted substitute. Remove the current config-exists auto-install/restart branch: a first pass with no config performs only `cargo build --locked --release` and prints `target/release/ezgha init` plus second-`./install.sh` bootstrap steps. It does not replace an installed binary or build/pull/run a Docker image. Bootstrap `init` may query endpoint/daemon metadata read-only but cannot start/recover a backend; it writes only the mode-`0600` starter config. Task 4 exposes idempotent primitives and a receipt but never commits a partial transaction independently. `EZGHA_PROPOSED_CONFIG`, or the explicit config-only bootstrap path when that variable is absent, must resolve to a mode-`0600` regular proposed file. Config existence alone is staged data, not upgrade evidence; the transaction uses the four-state classifier above and rejects `Mixed` before Docker image or installed/live mutation. Fixtures begin from no config and prove the first pass records only the local Cargo build plus guidance, with zero service-manager, Docker, installed-binary, or live-config mutation.

After an allowed local `cargo build --locked --release` creates the exact candidate binary, require the static install verdict against the proposed config. For a recognized explicit Colima/Lima endpoint on a supported platform only, static success may authorize starting that exact VM; Docker Desktop returns `NoRecovery`, and the dynamic Docker-backed verdict must then pass. Host Docker never recovers a VM. Add an ordered fixture whose Docker stub records build, pull, start, restart, and run: the recoverable Colima/Lima VM start is allowed only between successful static and dynamic checks, while image/Docker runner mutation requires both; every forbidden call fails the test. A failed phase exits without image work or policy/service mutation. Neither verdict is an admission permit.

After both verdicts, the transaction snapshots the installed binary bytes/path/mode/digest; live config; every old policy/helper file; the deployment receipt; exact generated `ezgha.service` and `ezgha-alert@.service` units; the live `10-oomd-omit.conf`; the installed legacy watcher service unit, timer unit, and stable script; and the applicable active/enabled states of `ezgha.service`, `ezgha-alert@.service`, `psi-oom-watcher.service`, and `psi-oom-watcher.timer`. Before image acquisition or binary/config/helper/receipt/policy/manager mutation, it performs upgrade quiescence: verify the proposed upgrade preserves `state_dir`, target/scope, and runner prefix; stop the old `ezgha.service` only when active; verify inactive and old MainPID exit; use the static verdict's canonical path to open a fixed inheritable `serve.lock` descriptor with a bounded timeout; explicitly clear `FD_CLOEXEC`; and retain that open-file description through the transaction. Managed-upgrade containers may remain only after proving their actual cgroups are beneath `actions.slice`. Legacy migration invokes the drain primitive with `--transaction-lock-fd <n>` for a bounded zero-container drain, never cancels a busy job, and removes only idle managed containers/registrations after busy work finishes; Rust validates numeric bounds, canonical inode identity, and live lock contention without reacquiring through the inherited FD. Drain/lock/FD-validation failure restores the formerly active old service and exits before image or installed/containment mutation. Fixtures prove successful inheritance and rejection of unlocked, wrong-inode, closed, or exec-lost descriptors; no refill/JIT/GitHub/Docker admission call can occur after lock acquisition and before the new service starts; no nested-lock deadlock exists; and release `EZGHA_SKIP_LOCK=1` cannot bypass the fence.

Only after quiescence may the transaction acquire/build the image; atomically install the candidate binary, proposed config, and stable assertion/gate helpers; render both generated units without installing them; verify every installed or staged path/mode/SHA-256; atomically commit a versioned deployment receipt containing the final unit paths and staged candidate digests; invoke the privileged installer including atomic watcher/exemption retirement; and verify effective containment and `oomctl` roots. Ordinary runtime admission must fail at this transitional point because the final units are absent. The transaction then calls endpoint-preserving `ezgha install-service --defer-start --transaction-lock-fd <n> --unit-candidate-dir <path>`. That Rust command validates the inherited FD and receipt-bound staged units, obtains and consumes private `TransactionAdmission`, atomically installs and verifies both units, reloads the user manager, and has no type-level path to start, pre-pull, reconcile, register, or create runners. A subsequent ordinary `ezgha containment-check --admission --json` must validate every final receipt path before the transaction releases `serve.lock` for the single final `systemctl --user start` handoff. It starts only when the selected prior/final state requires it and post-start verifies the unit, new MainPID, lock ownership, `/proc/<pid>/oom_score_adj`, and all receipt-bound digests. Any post-quiescence failure restores every recorded file byte-for-byte, including the old binary, helpers, receipt, and both generated units, reloads the relevant system and user managers, restores each unit's prior enabled/disabled state while retaining the lock, then releases it immediately before starting only units that were formerly active, and verifies rollback. Fixtures cover bootstrap, managed upgrade, legacy migration, mixed state, binary/helper/receipt/unit tampering, checkout changes after install, companion alert-unit rollback, stopped-Docker-Desktop `NoRecovery`, quiescence timeout, successful inherited-FD handoff plus every rejection branch, busy-job preservation, transaction-mode rejection of missing/wrong candidate path/mode/digest/FD, type-level runner-call rejection, deferred service generation, staged-to-installed digest equality, pre-install runtime-admission failure, post-install runtime-admission success, interrupted receipt-before-unit state returning `Mixed` with no start and exact rollback, single-start handoff, and exact rollback. An ordered fixture proves the restored old binary and `ExecStart`, not a failed generated command cached before reload, are launched. A failed rollback is reported distinctly and never as installation success. Do not add an unconditional Lima dependency or a second service-start path; an unrelated obsolete binary is explicitly outside the supported rolling-upgrade surface.

Create `tests/crash_containment_suite.sh` as the CI entrypoint for every non-live containment fixture. It runs the policy, artifact, assertion, installer, installation-consumer, doctor, Gate 8, and proof-script fixture tests using a deterministic explicit list or a narrowly scoped `*crash_containment*_test.sh` glob with de-duplication. Add that suite to `.github/workflows/ci.yml` now; Task 6's future `tests/prove_crash_containment_test.sh` must be picked up without Task 6 editing the shared workflow. CI never starts live proof services.

Run the bounded job-outcome monitor before and after applying `CPUQuota=2000%` with the exact repository and thresholds below. It measures attributed job conclusions, not duration; treat `UNHEALTHY` or `UNKNOWN` as a deployment gate failure even when container liveness passes. The aggregate quota equals the ten configured 2-CPU maxima, so the plan makes no undefined latency-regression claim.

- [ ] **Step 5: Verify and commit**

Run:

```bash
bash -n doctor-runner docs/verify-exit-criteria.sh
bash tests/doctor_runner_host_pressure_test.sh
bash tests/verify_exit_gate8_test.sh
bash tests/host_control_artifacts_test.sh
bash tests/host_ops_0725_test.sh
bash tests/crash_containment_policy_test.sh
bash tests/install_watchdog_gate_test.sh
bash tests/install_uninstall_aux_units_test.sh
bash tests/crash_containment_suite.sh
git diff --check
git add install.sh scripts/host/install-crash-containment.sh doctor-runner docs/verify-exit-criteria.sh docs/host-ops-sudo-block-0725.md .github/workflows/ci.yml tests/install_watchdog_gate_test.sh tests/install_uninstall_aux_units_test.sh tests/host_control_artifacts_test.sh tests/host_ops_0725_test.sh tests/doctor_runner_host_pressure_test.sh tests/verify_exit_gate8_test.sh tests/crash_containment_suite.sh
git add -u systemd/ezgha.service.d/10-oomd-omit.conf systemd/psi-oom-watcher.service systemd/psi-oom-watcher.timer scripts/host/psi-oom-watcher.sh
git commit -m "codex/gpt-5.6-sol: verify effective runner containment"
git push origin HEAD
```

Expected: doctor and Gate 8 fixtures PASS.

### Task 6: Add Claim-Specific Bounded Live Proofs

**Files:**
- Create: `scripts/host/prove-crash-containment.sh`
- Create: `tests/prove_crash_containment_test.sh`
- Modify: `.github/workflows/capacity-proof.yml`

**Interfaces:**
- Consumes: effective system hierarchy and the Task 3 assertion.
- Produces: a timestamped evidence directory under `evidence/crash-containment/<timestamp>/` with separate `hard-limit`, `oomd-selection`, `ten-worker`, and `survival` verdicts.

- [ ] **Step 1: Write fixture tests for proof safety**

Stub the narrowly scoped `sudo systemctl` interface, `systemctl`, `loginctl`, cgroup files, and boot ID. Cover:

```text
hard-limit child memory.events increments oom_kill                 => hard-limit PASS
oomd journal names descendant under ezghaproof-oomd.slice          => oomd-selection PASS
oomd child exits without a matching oomd victim record             => oomd-selection FAIL
oomd journal victim exists but child PSI never crosses 20%          => oomd-selection FAIL
effective DefaultMemoryPressureDurationSec exceeds 45 seconds        => preflight FAIL
full avg10 is >=20% for less than the effective duration             => oomd-selection FAIL
boot ID changes                                                     => survival FAIL
user-manager PID changes                                            => survival FAIL
unrelated managed runner disappears                                 => survival FAIL
preflight fails                                                      => FAIL before allocation
either allocator exceeds 90 seconds                                 => FAIL and terminate only its proof unit
capacity dispatch produces no unique new run ID                      => ten-worker FAIL
fewer than 10 concurrent containers show Runner.Worker               => ten-worker FAIL
10 workers exist but one exact-run marker is missing/wrong           => ten-worker FAIL
exact dispatched run completes success with 10 concurrent workers    => ten-worker PASS
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
4. In `--oomd` mode, parse and record effective `DefaultMemoryPressureDurationSec` from `systemd-analyze cat-config systemd/oomd.conf`; reject missing/unparseable values and values above 45 seconds before allocation. Use `${SUDO_BIN:-sudo} systemctl start ezgha-oomd-proof.service` for the fixed tracked unit and wait at most 90 seconds. Sample the child `memory.pressure` once per second while the fixed 640-MiB working set is continuously retouched for up to 75 seconds. Require the exact `full avg10` value to remain at least 20% continuously for the discovered effective duration and require a new `systemd-oomd` journal record naming a descendant of `ezghaproof-oomd.slice`; `some`, `avg60`/`avg300`, a lone above-threshold sample, allocator exit, a kernel OOM, or a victim record without the continuous measured interval is not evidence.
5. For both modes, require the boot ID, user-manager PID, Warp PID set, Docker daemon, and unrelated runner containers to remain alive. Record this separately as the survival verdict.
6. Stop and reset only the named proof services with privileged `systemctl` calls whose unit names are literal in the script. Never use `systemd-run`, a shell passed through privilege escalation, arbitrary unit names, or command/environment overrides. Leave the empty tracked proof slices in place and never touch `actions.slice`, Docker, `ezgha.service`, or the host lifecycle.
7. Inspect effective `memory.oom.group` for runner scopes. Do not claim whole-container hard-limit death when it is `0`; separately observe container exit and fleet replenishment during the ten-runner test.
8. Change the existing 24-job, 240-second `capacity-proof.yml` matrix to select `[self-hosted, self-hosted-mikey, ezgha, ez-runner-c]`; repository fixtures prove the Mac and canary examples do not contain `ez-runner-c`. Before calling this subset fleet-unique or dispatching, query every runner in the actual GitHub registration scope and require the selector to match exactly the expected ten `ez-runner-c-1..10` IDs/names and no other runner; record the full collision-query result and fail on an extra or missing match. Replace the separate hold step with one shell step that writes `/tmp/ezgha-capacity-proof.marker` containing its `GITHUB_RUN_ID`, `GITHUB_RUN_ATTEMPT`, and matrix number, installs an exit trap, sleeps for 240 seconds while the marker remains present, and removes it on that same shell's exit. The proof fixture fails unless the exact selector, registry-wide collision check, and same-step marker/hold contract are present. In `--ten-workers --ref REF` mode, verify all ten local and registry-matched runners advertise the proposed six-label set `[self-hosted, self-hosted-mikey, ezgha, ez-runner-c, Linux, X64]`, snapshot recent capacity run IDs, dispatch with `gh workflow run capacity-proof.yml -R jleechanorg/ez-gh-actions --ref "$REF"`, and resolve exactly one new run ID. Poll direct host Docker until ten distinct managed containers simultaneously show `Runner.Worker` in `docker top`; require `docker exec` in each observed container to return a marker for that captured run ID/attempt with ten distinct matrix numbers; record each container's actual PID cgroup path beneath `/actions.slice`; and fail on timeout, fewer than ten, or any missing/mismatched marker. Watch only the captured run ID to successful completion and require its job metadata to name those same matrix jobs; do not cancel it, because cancellation would contaminate the job-outcome monitor. Bind evidence to the exact run ID, attempt, workflow SHA, ref, selector subset, registration-scope runner IDs/names/labels, container IDs, markers, process samples, job metadata, and timestamps.

- [ ] **Step 4: Add an opt-in harness gate**

Use the Task 5 verifier's existing proof-result interface and gate live execution behind `EZGHA_RUN_PRESSURE_PROOF=1`. The normal harness reports each live verdict as `NOT RUN (explicit live proof required)` rather than claiming containment from fixtures or configuration. A release/deployment acceptance run requires both proof modes plus the ten-runner survival observation. Do not modify `docs/verify-exit-criteria.sh` in this task.

Task 5's containment-suite glob must discover this task's new fixture without editing `.github/workflows/ci.yml`. CI runs proof-script fixtures but never starts the live proof services or dispatches GitHub workflows.

- [ ] **Step 5: Verify and commit**

Run:

```bash
bash -n scripts/host/prove-crash-containment.sh tests/prove_crash_containment_test.sh
bash tests/prove_crash_containment_test.sh
bash tests/verify_exit_gate8_test.sh
git diff --check
git add scripts/host/prove-crash-containment.sh tests/prove_crash_containment_test.sh .github/workflows/capacity-proof.yml
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

- [ ] **Step 2: Prepare the proposed config without changing live state**

For the existing Jeff-Ubuntu legacy migration, create a mode-`0600` temporary proposed config from `~/.config/ezgha/config.toml`, then use a TOML-aware editor or the repository configuration serializer to set:

```toml
[runner]
count = 10
runner_floor_mb = 2500
labels = ["self-hosted", "self-hosted-mikey", "ezgha", "ez-runner-c", "Linux", "X64"]

[backend]
docker_endpoint = "unix:///var/run/docker.sock"

[limits]
memory_mb = 2500
cgroup_parent = "actions.slice"

[policy]
minimum_isolation = "container"
```

Remove VM-only `vm_total_mb` from the proposed host-Docker profile. Do not expose or rewrite credentials or alert URLs, and do not replace the live config in this step.

Before preparing the proposed config, record the existing effective Docker endpoint plus `runner.count`, `runner_floor_mb`, `runner.labels`, and `limits.memory_mb`. The confirmed Jeff-Ubuntu values are the canonical host socket, `10`, `2500`, `[self-hosted, self-hosted-mikey, ezgha, ez-runner-c]`, and `2500`. The reviewed changes persist that already-effective endpoint and add only `Linux` and `X64`; any endpoint change, label removal/other addition, higher memory value, or count change stops for profile review. Set `PROPOSED_CONFIG` to the temporary path; the transaction in Step 4 owns live replacement and rollback.

On a fresh host with no config, run `./install.sh` once to build only `target/release/ezgha`, run `target/release/ezgha init --target owner/repo` to create the explicit-endpoint mode-`0600` starter config, then rerun `./install.sh`. The config-only state is `Bootstrap`, not `ManagedUpgrade`; it may be used directly as the proposed file because no receipt, generated unit, service, container, or registered prefix exists. The candidate binary is installed only inside the second-pass transaction. Any other partial artifact combination is `Mixed` and stops for diagnosis.

- [ ] **Step 3: Perform the repository deployment and activation preflight**

Run before changing a live limit:

```bash
uptime
docker ps --filter label=ezgha=managed --format '{{.ID}}' | wc -l
bash scripts/host/install-crash-containment.sh --preflight --config "$PROPOSED_CONFIG"
docker info --format 'cgroup_version={{.CgroupVersion}} cgroup_driver={{.CgroupDriver}} kernel={{.KernelVersion}}'
cat /sys/fs/cgroup/actions.slice/memory.current
user_cgroup="/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service"
test -r "$user_cgroup/agents.slice/memory.current"
test -r "$user_cgroup/automation.slice/memory.current"
cat "$user_cgroup/agents.slice/memory.current"
cat "$user_cgroup/automation.slice/memory.current"
oomctl --no-pager
systemctl --user cat ezgha.service
systemctl --user show ezgha.service -p ActiveState -p UnitFileState -p ExecStart -p ManagedOOMPreference -p OOMScoreAdjust
```

Proceed only when the preflight exits zero before mutation, Docker reports cgroup v2/systemd, unprivileged `oomctl` works, and the classified state matches the intended deployment. For Jeff-Ubuntu `LegacyMigration`, require load at most 12, at least 8 of 10 containers unless the documented low-load drain exception is proven, no target cgroup under pressure, and sufficient current-use margins for any already-existing cgroups. `ManagedUpgrade` requires every runtime cgroup plus the Task 4 margins: 1 GiB for actions, 1 GiB for agents, and 512 MiB for automation. `Bootstrap` permits absent not-yet-installed cgroups but no runtime/deployment artifacts. Record checksums of the current binary, policy, helpers, and both generated user units plus active/enabled state for rollback evidence. Any failed prerequisite stops here without changing live state.

- [ ] **Step 4: Run the tracked deployment entrypoint**

Run as the deploy owner:

```bash
EZGHA_PROPOSED_CONFIG="$PROPOSED_CONFIG" ./install.sh
bash scripts/host/assert-crash-containment.sh --config "$HOME/.config/ezgha/config.toml"
```

Expected: after a local candidate build, `install.sh` classifies the deployment and reruns both immutable verdicts against the proposed config before mutation. It snapshots transaction state including the installed binary, stops the old supervisor, verifies inactive/MainPID exit, acquires canonical `serve.lock`, and drains legacy containers without cancelling busy jobs; no refill can occur. Only then does it acquire the image, atomically install the candidate binary and proposed config, install exact helpers, render receipt-bound unit candidates, apply and verify the persistent hierarchy, and install both generated user units with the actual binary and normalized endpoint without starting them. Installed binary/helper/unit paths, modes, and digests match the committed receipt before final admission and lock release. System `actions.slice` and user workload properties match the specification; no systemd control drop-in or live `10-oomd-omit.conf` exists; effective `ezgha.service` OOM preference/score and `/proc/$MainPID/oom_score_adj` are normal; and `user@UID.service` retains the same live MainPID and reports `ManagedOOMMemoryPressure=auto`. Any quiescence, binary, config, containment, generated-unit, restart, or post-start verification failure restores the prior binary, config, system/user policy, helpers and receipt, exact prior user units, retired watcher/exemption files, and every prior active/enabled state, verifies rollback, restarts only a formerly active old service, and does not claim success.

- [ ] **Step 5: Verify the generated service and exact binary**

Run:

```bash
systemctl --user status ezgha.service --no-pager -l
systemctl --user show ezgha.service -p ExecStart -p Environment -p NRestarts --no-pager
sha256sum "$HOME/.local/libexec/ezgha/assert-crash-containment.sh" \
          "$HOME/.local/libexec/ezgha/ezgha-start-gate.sh" \
          "$(command -v ezgha)" \
          "$HOME/.config/systemd/user/ezgha.service" \
          "$HOME/.config/systemd/user/ezgha-alert@.service"
```

Expected: `ExecStart` names the stable gate, the actual installed Cargo binary, and the active config; the environment preserves the canonical host endpoint; binary/helper/unit hashes match the receipt; the gate succeeds and replaces itself with `ezgha`; and the service is active. Lima remains inactive.

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
EZGHA_RUN_PRESSURE_PROOF=1 bash scripts/host/prove-crash-containment.sh --ten-workers --ref "$(git branch --show-current)"
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

Expected: the proof dispatches exactly one captured `capacity-proof.yml` run, records ten simultaneous managed containers whose direct `docker top` output includes `Runner.Worker`, correlates each container to the captured run/attempt through its exact marker and unique matrix number, proves actual cgroups are beneath `/actions.slice`, and watches that run to success without cancellation. The hard-limit proof records a local cgroup OOM; the oomd proof records both child pressure above threshold and a `systemd-oomd` victim beneath `ezghaproof-oomd.slice`; boot ID, user-manager PID, Warp, Docker, and unrelated runners survive both; the host-Docker Gate 8 passes without invoking Lima; and the monitor verdict is `HEALTHY`. No undefined duration-regression claim is made because the 2000% aggregate quota equals the ten configured 2-CPU maxima.

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
  src/backend.rs src/containment.rs src/config.rs src/docker_backend.rs src/github.rs src/service.rs src/main.rs \
  scripts/host/agent-scoped-launch.sh \
  scripts/host/agent-cli-scoped.sh \
  scripts/host/agent-auto-migrate.sh \
  scripts/host/assert-crash-containment.sh \
  scripts/host/ezgha-start-gate.sh \
  scripts/host/proof-allocator.sh \
  scripts/host/install-crash-containment.sh \
  scripts/host/prove-crash-containment.sh \
  install.sh config/README.md config/config.toml.linux.example doctor-runner \
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
  tests/crash_containment_suite.sh \
  tests/prove_crash_containment_test.sh \
  "$EVIDENCE_DIR"
git add -u systemd/ezgha.service.d/10-oomd-omit.conf systemd/psi-oom-watcher.service systemd/psi-oom-watcher.timer scripts/host/psi-oom-watcher.sh
git commit -m "codex/gpt-5.6-sol: enforce workload crash containment"
git push origin HEAD
git status --short --branch
```

Expected: push succeeds, the branch is synchronized with its upstream, and unrelated `.playwright-mcp/` content remains untouched.
