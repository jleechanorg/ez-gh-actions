# Runner Crash Containment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the Ubuntu host and operator desktop alive under a full ten-runner workload by enforcing finite workload aggregates and workload-local pressure handling on host Docker.

**Architecture:** Host Docker remains the Linux execution backend. Docker runner scopes live under a root-owned finite `actions.slice`; coding agents and automation retain separate finite user slices; `systemd-oomd` monitors those workload roots instead of the whole desktop user manager. One Rust-owned admission implementation performs bounded full attestation off the reconciliation thread and issues a fresh short-lived permit at every Linux runner-creation boundary; the generated main-process wrapper and shell assertion provide an earlier defense-in-depth check. Ordinary stop/removal remains available outside deployment, and a tracked fenced emergency-abort command remains available while the transaction holds `serve.lock`.

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
- `scripts/host/install-crash-containment.sh`: nonprivileged read-only checks plus private candidate/manifest staging.
- `scripts/host/prove-crash-containment.sh`: separately labeled hard-limit and isolated oomd proofs.
- `install.sh`: public preflight/build/stage dispatcher that `exec`s the private Rust install transaction.
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
- **Guard every admission path:** the Rust admission guard must run before direct `start`, direct or service-managed `serve`, image pre-pull, and every admission-side reconciliation mutation. Long-lived service admission uses a bounded background full attestor plus a fresh cheap permit at each runner-creation boundary; it must not put Docker, systemd, oomctl, or digest probes in the reconciliation thread. Pre-daemon recovery has a separate Rust decision that can start only an explicitly configured Colima/Lima backend through the existing bounded command; Docker Desktop is never auto-started. Recovery can never authorize runners or turn HostDocker into VM fallback. A shell wrapper is defense in depth, not the authority.
- **Pressure relief remains independent:** outside a transaction, ordinary planned stop remains `systemctl --user stop ezgha.service` followed by `ezgha stop`. Urgent relief at any time uses tracked `ezgha emergency-stop --confirm`, which durably latches all later start/install/handoff until exact verified clearance; add `--cancel-running` only for proven-local managed containers. Relief never starts a backend/service, refills runners, or calls GitHub.
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

Create fixed `ezgha-hard-limit-proof.service` and `ezgha-oomd-proof.service` system units. Each has the corresponding proof `Slice=`, `Type=oneshot`, `DynamicUser=yes`, `NoNewPrivileges=yes`, `PrivateTmp=yes`, `ProtectSystem=strict`, `ProtectHome=yes`, no capabilities, no credentials, no Docker socket, and a literal `ExecStart=/usr/local/libexec/ezgha/proof-allocator.sh MODE`. The services accept no arbitrary command or environment override. The tracked allocator validates its literal mode and uses only `/usr/bin/python3` stdlib allocation. Hard-limit mode grows a touched anonymous working set beyond the 512-MiB child `MemoryMax`. Oomd mode grows to a fixed 640 MiB, above `MemoryHigh=384M` but below `MemoryMax=768M`, then continuously retouches every page for 75 seconds. The harness reads the effective global `DefaultMemoryPressureDurationSec` through `systemd-analyze cat-config systemd/oomd.conf`, records it, and accepts only an unambiguous integral whole-second value in `1..=45`; missing, malformed, zero, negative, fractional, unit-suffixed, or larger values fail. It samples the child cgroup's exact `memory.pressure` `full avg10` field every second and requires a continuous at-or-above-20% interval spanning that effective duration plus a new journal victim beneath the exact proof slice; a single PSI sample, `some`, another averaging window, allocator completion, or a kernel OOM alone cannot pass oomd-selection. Fixtures pin failure for `0`, negative, fractional, unit-suffixed, ambiguous, and unparseable values; exact `1` and `45` still require continuous PSI plus the victim. The proof script may invoke privileged `systemctl` only with literal lifecycle operations and these exact service names; do not permit `systemd-run`, a shell, wildcard unit names, or command/environment overrides.

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

When invoked from the installed stable path, validate the versioned deployment receipt rather than comparing with a mutable checkout. The atomically written receipt records the deployed Git SHA, explicit `startup_handoff_protocol = 1`, and, for final `config.toml`, the `ezgha` binary, `assert-crash-containment.sh`, `ezgha-start-gate.sh`, root-owned `proof-allocator.sh`, generated `ezgha.service`, and generated `ezgha-alert@.service`, the artifact role, candidate/source path, installed absolute path, mode, and SHA-256. Protocol 1 requires the exact private wrapper plus peer-proven Unix-socket `SCM_RIGHTS` lock transfer, helper-side and receiver-side close-on-exec, two-phase ACK/cleanup, and fixed connect/ready deadlines; absent, unknown, or inconsistent protocol is pre-baton for rollback. The config entry additionally records parsed `runner.count`, which must equal `10` on the fixed Linux profile, and requires mode `0600`. A missing/malformed receipt or any installed path, mode, digest, parsed-count, or supported-protocol mismatch is a policy violation. Changing checkout files after installation does not invalidate an otherwise intact deployment; rollback restores or removes the receipt and every listed artifact, including config, together.

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

### Task 4: Build the Rust Deployment Core and Generated Service

**Files:**
- Create: `scripts/host/ezgha-start-gate.sh`
- Modify: `src/alert.rs`
- Modify: `src/backend.rs`
- Modify: `src/canary.rs`
- Create: `src/containment.rs`
- Modify: `src/config.rs`
- Modify: `src/service.rs`
- Modify: `src/main.rs`
- Modify: `src/docker_backend.rs`
- Modify: `src/failure_ladder.rs`
- Modify: `src/github.rs`
- Modify: `src/lima_convergence.rs`
- Modify: `src/platform.rs`
- Modify: `src/queue_monitor.rs`
- Modify: `src/quarantine.rs`
- Modify: `src/reaper.rs`
- Modify: `src/shutdown.rs`
- Modify: `config/config.toml.linux.example`

**Interfaces:**
- Consumes: Task 2 unit files and Task 3 assertion.
- Produces: canonical topology and three read-only containment verdicts; synchronous `RuntimeAdmission`; background non-capability `RuntimeAttestation`; `AdmissionIssuer` plus the sole `EffectCoordinator`; one-use `AdmissionMutation`; narrow `ReliefCleanup`; non-capability `AuditStateWrite`; private `TransactionAdmission`; deployment classifier; canonical runner/control locks; durable effect/relief/recovery state; receipt-bound descriptor handoff; primitive containment install/rollback; and the endpoint-correct private systemd startup gate. Static/dynamic verdicts remain non-capabilities; only one exact explicit Colima/Lima start may recover. Runtime proof binds final artifacts/count, background refresh stays outside foreground budgets, and the coordinator exposes noninterchangeable `AdmissionGate`, `DeploymentGate`, `RecoveryGate`, and `ReliefGate` scopes that linearize every forward commit/spawn against the durable latch. Transaction admission can only install/reload staged units, and the handoff gate transfers the continuously locked FD only to the proven systemd peer. No capability is CLI-serialized. Task 4 owns the private Rust install transaction, quiescence/fence/state ordering, `EffectCoordinator`, every gate/state type, the privileged deployment/rollback executor, generated-unit code, Rust recovery primitives, the complete private Rust `handoff-service` implementation including socket/FD transfer, deadlines, terminal-owner resolution, and failure transitions, and every admission, relief, or audit integration in the Rust modules listed above. Task 4 does not edit `install.sh`, expose recovery as a public shell command, or retire legacy state; Task 5 owns public shell preflight/build/stage/dispatch grammar and removal of external mutating reapers.

- [ ] **Step 1: Write Rust deployment-executor fixtures before implementation**

In `src/containment.rs` tests, stub system and user `systemctl`, Docker, final-path operations, and the clock. Invoke the private Rust install transaction with a fixture-created receipt-enumerated candidate manifest and typed admission. Assert that Rust executes these logical operations in order, with every live line below recorded as its own `DeploymentGate` effect:

```text
reject /run/systemd/*control overrides that would shadow tracked units
before any mutation prove proposed endpoint, >=62GiB/32CPU, privilege, classified deployment state, applicable current-use margins, and rollback storage
for an explicit recoverable Colima/Lima endpoint only, permit one exact backend start; then prove reachable topology, cgroup v2/systemd driver, and unprivileged oomctl
before image work or live policy mutation require both static and dynamic verdicts
classify upgrade versus fresh state; upgrades read all three real memory.current files and require 1G/1G/512M margins
stage and syntax-check every persistent unit before the Rust executor may touch /etc or ~/.config
Rust DeploymentGate: install systemd/host/actions.slice and fixed proof units -> /etc/systemd/system
Rust DeploymentGate: install root/user@ overrides -> /etc/systemd/system/{-.slice.d,user@.service.d}
Rust DeploymentGate: systemctl daemon-reload
Rust DeploymentGate: systemctl start actions.slice
Rust DeploymentGate: remove ~/.config/systemd/user/agents.slice.d/99-local-unlimited.conf
Rust DeploymentGate: systemctl --user daemon-reload
verify effective values; on mismatch Rust uses separate ReliefGate restore/reload effects, starts nothing, and verifies restored effective values
```

Assert that VM Docker skips the system host profile; contradictory endpoint/daemon metadata, cgroupfs, inaccessible `oomctl`, less than 62 GiB RAM, current use above an activation margin, a control drop-in, or missing privilege causes a nonzero exit before any file write/reload/restart and without printing success. Classify from the proposed config plus committed artifacts, not config existence alone:

- `Bootstrap`: mode-`0600` proposed config with explicit endpoint; no receipt/helper set, generated units, active/enabled main service, managed-prefix container, or registered-prefix runner. The active config may be absent or byte-identical to the candidate.
- `ManagedUpgrade`: complete receipt and helpers, both generated units, active config, and all three expected effective cgroups; exact current-use margins are mandatory.
- `LegacyMigration`: a recognized complete pre-receipt service/config/runtime signature; it is never silently adopted as bootstrap.
- `Mixed`: partial receipt/helper/unit/cgroup state, an unexplained differing active config, orphaned prefix runner, or any other incomplete combination; fail before image, Docker runner, policy, config, or service mutation.

Receipt-bound units present only in the candidate directory are a transaction-internal transition, valid solely with the exact held lock and candidate proof. Without it, including after interruption, the state is `Mixed`, runtime admission fails, no service starts, and rollback restores or removes the complete receipt/artifact set.

A `RecoveredInactive` archive is retry metadata, not deployment evidence. Verify its nonce, saved-snapshot digest, byte-exact completed rollback, absent socket, inactive service, and disabled pre-baton state, then classify restored artifacts normally; any mismatch is `Mixed`. A clean retry replaces the archive only after publishing a new `Preparing` nonce. Add fixtures for recovered `LegacyMigration` retry and every archive mismatch.

The dynamic topology/driver/`oomctl` checks run only after the daemon is reachable, including after the sole allowed exact Colima/Lima start. Include config-only bootstrap success where no managed receipt exists yet, config path/mode/digest/parsed-count mismatch, post-lock config replacement, complete managed upgrade, every partial-artifact rejection, recognized legacy migration, orphaned registration, mixed-state rejection, and 60-GiB/61.99-GiB rejection fixtures. The Task 4 receipt records the final config artifact plus both `is-active` and `is-enabled`; rollback fixtures cover config restoration/removal and disabled/inactive, enabled/inactive, and enabled/active prior states.

- [ ] **Step 2: Run deployment-executor fixtures and confirm the red state**

Run:

```bash
cargo test containment::tests::deployment_executor
```

Expected: FAIL because the Rust deployment executor does not exist.

- [ ] **Step 3: Implement the idempotent installer**

The Rust static/dynamic verdict implementation remains read-only. Static validates proposed endpoint, hardware, privilege, deployment state, applicable current use, and rollback storage; dynamic proves topology, cgroup v2/systemd driver, and unprivileged `oomctl`. A local locked release build may produce the probe but cannot contact or mutate Docker/service managers. Only successful static verdict for explicit Colima/Lima authorizes one exact stopped-VM start before dynamic proof; other endpoints are `NoRecovery`. Task 5 owns the shell `--preflight`, `--check`, and `--stage` surfaces. Rust accepts only Task 5's private receipt-enumerated candidate manifest containing final targets, expected prior/new modes and digests, and staged source identities. Managed upgrades enforce the 1 GiB/1 GiB/512 MiB activation margins using unadjusted `memory.current`; bootstrap may lack new cgroups.

Implement a private Rust install transaction that accepts the candidate directory and proposed-config identity. Before static revalidation or any state, lock, gate, backend, manager, or final-path access, it opens `/proc/self/exe` with close-on-exec, `fstat`s and hashes that descriptor, resolves its canonical target, and requires its path, owner, regular-file mode, digest, and candidate role to equal the private manifest. Missing self identity, old installed binary, alternate copy, post-shell pathname replacement/deletion, or any mismatch exits with zero effects. Only then may it revalidate typed verdicts, snapshot replaced policies/helpers/generated units plus active/enabled intent, acquire and retain the canonical transaction-lock FD, and become the sole owner of privileged live mutation. No gate accepts an arbitrary command, path, callback, or shell-produced capability. Each final artifact rename/mode/owner change, policy/unit install/removal, manager reload/enable, and allowed service-start spawn is one separately prepared `DeploymentGate` effect. Each rollback/stop/restore/reload is a separate latch-bound `ReliefGate` effect, starts nothing, and leaves durable `RecoveryRequired`/`Mixed` state rather than shell-retrying an ambiguous result. Neither shell surface calls `systemctl set-property`, and compatible prior active state may return only through receipt-proven descriptor handoff; pre-baton rollback remains disabled/inactive `RecoveryRequired`.

Do not stop or restart a live Lima VM. When host Docker is proven and `lima-vm@colima.service` is inactive, disable its future auto-start without `--now`; when it is active, report topology drift and leave it untouched for operator review.

- [ ] **Step 4: Generate the gated service with the actual binary path**

Create `scripts/host/ezgha-start-gate.sh` and update `src/service.rs` so the generated Linux unit invokes it with exact receipt-bound `current_exe()` and config paths. The wrapper passes that binary to the assertion, propagates all nonzero statuses, and on success uses exactly `exec "$binary" --config "$config" serve --systemd-private`. The hidden flag is valid only after Rust proves exact systemd provenance. With a matching reservation it is the sole baton-claim path; with no transaction, handoff, or latch it follows the ordinary serialized systemd boot/restart path. Plain direct `start`/`serve` cannot claim. The assertion remains bounded to 15 seconds, and the wrapper is neither a timer/background authority nor the sole admission guard. Generated-unit/CLI tests pin the hidden argument, normal no-reservation systemd startup, and rejection outside exact `ezgha.service`.

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

Implement the compatibility resolver's bounded, injectable active-context and recognized-socket evidence in `src/lima_convergence.rs`, consumed by the classifier in `src/backend.rs`; runtime admission never uses its diagnostic ambient/default fallback, and the existing explicit `LimaConverge --write-backup` mutation remains isolated from runtime admission. Change `src/platform.rs` so Docker capability and kernel-metadata probes receive the normalized explicit endpoint and remove `DOCKER_CONTEXT`, or move those probes behind the endpoint-aware backend classifier; no bare ambient Docker invocation may influence topology. Remote daemon metadata alone never satisfies VM isolation or recovery. Tests cover bounded context lookup, conflicting/no/remote evidence, endpoint propagation, and absence of ambient Docker commands.

Make the config field, not ambient `DOCKER_HOST` or `DOCKER_CONTEXT`, the single source for the generated service and every Rust Docker subprocess after migration. For host Docker, emit the explicit `Environment=DOCKER_HOST=unix:///var/run/docker.sock` plus `UnsetEnvironment=DOCKER_CONTEXT`. For recognized Colima/Lima/Docker Desktop, emit the correctly escaped explicit endpoint and also unset `DOCKER_CONTEXT`. All Rust Docker subprocesses use the same endpoint with `env_remove("DOCKER_CONTEXT")`; canonical host commands must never start Lima, only explicit Colima/Lima endpoints may use the existing bounded recovery, and Docker Desktop remains non-recoverable when stopped. Preserve `WatchdogSec=300`, `NotifyAccess=all`, `StartLimitIntervalSec=300`, `StartLimitBurst=5`, `Restart=on-failure`, and `RestartSec=30`. Five 15-second assertion failures plus four 30-second restart delays fit within 300 seconds, so persistent exit `75` reaches the existing limiter. `TimeoutStartSec=150` covers the assertion plus the daemon's existing 120-second readiness window; systemd watchdog timing starts after `READY=1`, and a source comment plus generated-unit test pins that distinction. README and `config/README.md` pin the manual recovery after a persistent transient: fix the prerequisite, require `ezgha containment-check --admission --json`, then `reset-failed` and `start`; no monitor resets the limiter.

Update `src/service.rs::install_systemd` so direct Linux installation obtains fresh `RuntimeAdmission` before writing, enabling, or starting a unit; direct `ezgha install-service` cannot install a bypass when containment is missing. Transactional deferred installation instead requires private `TransactionAdmission` and cannot enable or start. Both paths route each live artifact commit and manager reload/enable/start spawn separately through `DeploymentGate`; shell only stages and reads. The ordinary path records both unit bytes plus active/enabled intent, commits/reloads/enables, and restarts the new private-mode unit when previously active. On failure, restore both units and reload through latch-bound `ReliefGate`. Restart prior state only when its receipt/wrapper proves the supported private startup contract and no latch exists; otherwise disable the restored pre-baton main unit, record prior intent in `RecoveryRequired`, and leave it inactive. Add latch-first/gate-first, no-wait-under-lock, generated-unit, no-admission zero-write, active regeneration, receipt-proven prior restart, and pre-baton disabled/inactive recovery fixtures. Backend tests prove zero VM commands for Host Docker/Desktop/remote and at most one exact stopped Colima/Lima start through `RecoveryGate`.

Promote canonical `serve.lock` to the installation fence. `start`, `serve`, `stop`, and the transaction use active `state_dir`; static verdict JSON returns it. Release builds reject `EZGHA_SKIP_LOCK`; upgrades reject state/target/scope/prefix drift. Task 4's private Rust install transaction releases `emergency.lock` before stop/wait, reacquires it to publish `Preparing`, opens and retains the exclusive `serve.lock` description, validates bounds/inode plus second-description contention, and owns every subsequent handoff state and protocol operation. Task 5's shell `exec`s this transaction after staging and therefore cannot race it with a second shell control loop. Legacy drain is bounded; deferred install requires the FD and cannot start. Final candidate or compatible rollback uses a mode-`0600` reserved Unix socket, exact systemd peer proof, `SCM_RIGHTS`, and receiver close-on-exec to transfer that same locked description before `HandoffLocked`/`FD_ACCEPTED`; no Rust transaction copy closes earlier, cleanup precedes ownership, and fixed deadlines fit `TimeoutStartSec`. Pre-baton rollback restores bytes but remains disabled/inactive. Task 4 fixtures pin FD continuity/noninheritance, peer/socket/artifact proof, boot-stamped ordinary restart, all death/emergency boundaries, and selected-state start.

Implement the complete private Rust handoff protocol in Task 4. After final admission, `handoff-service --transaction-lock-fd <n>` revalidates the inherited fence, sets and verifies `FD_CLOEXEC` on its own descriptor copy before spawning any child, and leaves the transaction owner's separate descriptor flag untouched. It requires canonical `state_dir` to be a non-symlink deploy-UID-owned mode-`0700` directory, creates a fresh mode-`0600` `state_dir/handoff.sock` without following/replacing an existing path, and publishes `HandoffReserved` with socket identity, protocol, nonce, transaction-owner/helper identities, `connect_deadline_boottime = reserve + 25s`, mode, unit, and exact artifact digests. The five-second no-block/fail systemd submission, 15-second wrapper assertion, and five-second aggregate provenance/claim/connect budget are non-additive and must finish by that deadline. `HandoffClaimed` records `ready_deadline_boottime = claimant entry + 120s` for peer proof, FD transfer, cleanup, admission, ownership, pre-pull, and `READY=1`. Worst case is 145 seconds, leaving five seconds inside `TimeoutStartSec=150`; no retry, rollback, or transition refreshes either deadline.

Private mode uses one five-second aggregate read-only manager-query budget to prove exact lowercase invocation ID, MainPID, normalized unified-v2 cgroup path ending in `ezgha.service`, FragmentPath, executable/config, receipt artifacts, and live transaction-owner/helper identities. The helper submits exactly one no-block/fail systemd job through `DeploymentGate::spawn`: it holds `emergency.lock` only through latch/capability recheck, prepared-record fsync, and exact spawn/identity registration, then releases before the five-second wait. Private mode CASes matching `Reserved -> Claimed`, connects to the reserved socket, and sends nonce/PID-start/invocation evidence. The helper requires matching `SO_PEERCRED` plus `/proc`, state, receipt, cgroup, and digest proof, then transfers the already-locked FD with `SCM_RIGHTS`. The claimant uses `recvmsg(MSG_CMSG_CLOEXEC)`, rejects ancillary truncation or extra/missing FDs, verifies `FD_CLOEXEC`, validates bounds/`fstat` identity, requires idempotent nonblocking flock success on the received shared open-file description and `EWOULDBLOCK` on an independent canonical description, CASes `Claimed -> HandoffLocked`, and sends `FD_ACCEPTED`. Only after verified acknowledgment/state may the Rust transaction close its copy. The helper closes the listener, identity-checks/unlinks only the reserved socket path, fsyncs its parent, verifies absence, and sends nonce-bound `CLEANUP_COMPLETE`; the claimant independently proves absence before `ServiceOwned`. On EOF/timeout, claimant cleanup additionally requires proof that the reserved helper PID/start identity is dead; otherwise state becomes `RecoveryRequired`.

`ServiceOwned` records boot ID, PID/start, invocation, lock, admission/artifact, socket-cleanup, and typed origin evidence: handoff origin has transaction/ready deadline, ordinary origin has owner-start boot time and no handoff deadline. With no transaction/nonterminal handoff/latch, ordinary private boot, direct `start`, and direct `serve` acquire `serve.lock` and invoke one shared terminal-owner resolver before backend work. Under `emergency.lock` it reads one generation and performs at most one exact CAS: no record proceeds after blocker recheck; a complete receipt-matching different-boot record archives as `PriorBoot`; a complete same-boot record with absent/reused PID-start archives as `SameBootDead`. Archival additionally requires the manager unit inactive, except for the exact private systemd caller proving self MainPID/invocation/cgroup. A live valid owner, contradictory lock evidence, foreign active MainPID, malformed/missing boot ID or origin/deadline, artifact/lock/invocation mismatch, residual socket, or failed CAS/fsync fails `78` without archive/start; only an independently valid transaction snapshot may become `RecoveryRequired`. Archival fsyncs state/parent and rechecks blockers before admission; one CAS conflict restarts once, a second exits `75`. Every successful ordinary caller publishes new boot-stamped ordinary ownership before pre-pull.

On ambiguous submission, matching unclaimed reservation becomes `SubmissionUnknown`; a fully matching claimed/connected peer may finish the bounded transfer, while any latch, mismatch, or failed peer proof becomes `RecoveryRequired`. No FD is sent after invalid proof or latch. Before-ACK failure retains the Rust transaction fence until state is unclaimable, then releases it, performs bounded query/stop/inactive verification without either lock, and reacquires before rollback. After-transfer/before-ownership failure stops the service, verifies its received FD closed, cleans only matching socket state, and reacquires. The claimant rechecks reservation/latch/deadlines, runs full admission, and only after cleanup proof CASes `HandoffLocked -> ServiceOwned` before pre-pull or runner mutation. Expiry or any post-ownership/pre-READY failure first CASes that exact ownership to `RecoveryRequired`, then exits without runner mutation. Compatible rollback uses the identical transfer; pre-baton rollback remains disabled/inactive until verified recovery. Task 4 Rust tests cover every peer/FD/death/CAS/deadline branch, exact `5/15/5/120` boundaries and one-millisecond overruns, child noninheritance, socket cleanup, supported rollback transfer, ordinary restart, and no lock during READY, stop, or reacquisition polling.

Preserve the existing alert contract while regenerating the service: `OnFailure=ezgha-alert@%N.service` and the fail-open `ExecStopPost=-ACTUAL_EXE --config ACTUAL_CONFIG systemd-alert-hook --source exec-stop-post --unit %n` remain on `ezgha.service`. The companion template remains a 30-second `Type=oneshot` invoking the same exact binary/config with `systemd-alert-hook --source on-failure --unit %i`, and inherits the explicit endpoint/context-clearing environment. Generated-unit tests pin both directives, both hook argument sets, the alert timeout, and byte-exact rollback of both units.

Own `BackendTopology` and `ezgha topology --json` in `src/backend.rs`. The normalized explicit endpoint plus daemon metadata produce `HostDocker`, `VmDocker` (recognized Colima, Lima, or Docker Desktop), or `Indeterminate`; `Platform.daemon_in_vm` is only metadata input. Create `src/containment.rs` as the single Rust owner of the three explicit `ezgha containment-check` modes and scoped permits; bare `containment-check --json` is rejected. Static-install, dynamic-install, and admission CLI modes expose typed read-only verdict JSON only. `RuntimeAdmission` requires the exact effective host invariants and every final installed receipt artifact. `TransactionAdmission` additionally requires the validated inherited lock FD and candidate directory, checks final non-unit artifacts plus staged unit modes/digests, and exposes only atomic two-unit installation/verification and manager reload; its type cannot call start, pre-pull, reconciliation, registration, or runner creation.

On the fixed Linux profile, the receipt records the final config path, mode, digest, and parsed `runner.count`; both receipt and config must equal `10`. `start` computes `--count.unwrap_or(config.runner.count)` and rejects any value not equal to both receipt/config counts and `10` with status `78` immediately after config load, before lock/backend/admission/Docker/GitHub/ledger access or mutation. `--count 10` is accepted but is not an override. After the lock, full runtime admission repeats the count and identity check to close the race. Legacy non-Linux count behavior is unchanged. Tests use operation spies to prove `start --count 9`, `start --count 11`, receipt/config disagreement, and a post-lock config swap perform zero runner mutation; omitted count and `--count 10` reach reconciliation as exactly 10.

Direct `start`, `serve`, `install-service`, and `canary-once` perform one bounded full `RuntimeAdmission` synchronously before their first mutation; direct `serve` does so before pre-pull. A long-lived `serve` then owns one non-overlapping background full-attestation worker. A new read-only run starts no later than 20 seconds after prior completion, has its own 15-second deadline, and checks Docker, systemd, `oomctl`, effective cgroups, receipt/config modes and SHA-256 digests, endpoint/topology, fixed count, and policy. It publishes a non-capability snapshot with observation generation, revocation epoch, status/class, completion time, boot ID, endpoint/count, and receipt/config metadata identity. A successful snapshot expires 45 seconds after completion; the foreground never joins the worker or charges it to reconciliation or the shared 75-second monitor budget.

Type every Linux runner-resource or external control-plane side effect as `AdmissionMutation` or `ReliefCleanup`; forbid untyped Docker, GitHub, ledger, quarantine, workspace, and runner-control writes. Add non-capability `AuditStateWrite` for bounded local audit/history, alert, and failure-counter persistence only; its API cannot reach Docker/GitHub, runner ledger/quarantine/resource mutation, retry, dispatch, dead-man credit, or permit issuance. `AdmissionMutation` includes every automatic slot reserve/record/release, quarantine write, workspace reset, Docker pull/run/rm, JIT POST, runner DELETE, workflow cancel/force-cancel, canary dispatch, and stale/zombie reconciliation action. Thread `AdmissionIssuer` and the sole `EffectCoordinator` through `ensure_count_outcome`, `release_stale_slots`, `start_missing_runners`, `start_one_with_generate_at_slot`, GitHub retry helpers, zombie reaper, and service canary scheduler; remove Linux overloads that lack them. Each atomic local write or actual child spawn calls `mint_mutation()` and consumes its own permit through `AdmissionGate::{local,spawn}`; no permit covers a batch, callback, retry loop, sleep, or second command. GitHub helpers mint independently before every backoff POST/DELETE and every JIT conflict delete/retry.

No production free function in `alert`, `canary`, `failure_ladder`, `queue_monitor`, or `quarantine` may initiate an untyped runner/control-plane mutation. `CanaryDaemonState` and direct `canary-once` receive the issuer and coordinator; immediately before each workflow-dispatch POST they mint a fresh `AdmissionMutation::CanaryDispatch` and consume it through `AdmissionGate::spawn`, while correlation and polling remain read-only. Make `save_quarantine_for` private and callable only as `AdmissionGate::local(AdmissionMutation::QuarantineWrite { path, table_digest })`; its one logical atomic replacement includes directory creation, temporary write, sync, and rename, and denied, revoked, stale, or reused admission leaves every quarantine path unchanged. Failure-ladder persistence, completed-canary and invariant history, alert cooldown/log persistence, and alert delivery receive only a non-forgeable `AuditStateWrite` context whose API cannot construct or receive an issuer, any effect gate, Docker/GitHub runner client, slot/quarantine ledger handle, retry callback, or dead-man credit. Queue/invariant sampling stays read-only and bounded; `AdmissionControl` checkpoints prevent its 75-second budget from delaying required cancellation. `shutdown` supplies only the interrupt signal; SIGTERM drain and explicit `stop` route exact receipt/ledger-proven owned container, registration, and slot targets through `ReliefGate`, and no relief path can dispatch, retry, refill, or invoke reaper reconciliation.

There is exactly one automatic mutating queue/reaper executor: `serve`'s private `ReconciliationCoordinator`. `ReaperPlanner` and `ezgha reaper-plan` are read-only; `ReaperExecutor` is private to the coordinator and receives the issuer/gate. Move queued-run and zombie cleanup into that loop, execute at most one candidate chain per iteration, and gate workflow cancel, optional force-cancel, runner-registration delete, ledger release, and later refill separately. A denied, cancelled, expired, failed, or indeterminate primitive ends the chain and iteration; a later iteration must rediscover state read-only and never generically replay an unknown remote outcome. Split the current reaper API so planner/docker modules cannot call GitHub mutation functions except through the private coordinator. Task 5 owns removal of the shell apply mode and every external scheduler artifact after this Rust path exists.

Minting reads the latest successful snapshot, checks boot/config/receipt metadata, and returns a one-use permit bound to the current revocation epoch for at most five seconds and never beyond snapshot expiry. `EffectCoordinator` exposes noninterchangeable `AdmissionGate`, `DeploymentGate`, `RecoveryGate`, and latch-bound `ReliefGate`. Each forward gate acquires `emergency.lock`, rereads the full latch set, revalidates/consumes its typed capability, assigns an effect ID/target fingerprint, and fsyncs `EffectInFlight::Prepared`. While still locked, `local` performs exactly one named atomic commit and records its result; `spawn` starts exactly one already-built command in a dedicated process group with `PR_SET_PDEATHSIG=SIGKILL` plus the post-`prctl` parent check, then records PID/start/process-group and `Spawned`. It releases the lock before every wait, network result, child-output read, poll, sleep, retry, cancellation grace, or Docker readiness query. Completion resolves the durable record after unlock. Latch-first yields zero commit/spawn; gate-first yields at most its one registered primitive, which emergency snapshots and cancels after publishing its fsynced latch, while all later forward gates reject. Prepared/spawned/local-result ambiguity after death is never replayed; read-only outcome proof quarantines admission resources, leaves deployment `RecoveryRequired`/`Mixed`, or reclassifies the exact VM endpoint without respawn. Shell writes only staging files; live artifact/policy/unit commits, manager reload/enable/start, and the exact VM-start spawn use their typed gates separately. Exact stop/rollback restoration after a latch uses `ReliefGate`, starts nothing, and also releases before waiting. A successful refresh advances observation generation without changing the revocation epoch; `PolicyFailed`, `StaleSince`, boot change, or metadata mismatch increments the epoch. Thus a serialized ten-runner batch lasting over 300 seconds remints across healthy generations, but drift between any two side effects blocks the next. `ExpiredWhileHealthy` retries one remint and never affects failure streak, alerts, dead-man credit, backend restart, or failure ladder. One-shot direct `start` performs new full admission between mutation boundaries if its snapshot expires.

`ReliefCleanup` covers only explicit `stop`, SIGTERM drain, emergency cancellation, and compensation for an exact earlier admitted JIT transition. Compensation requires an in-memory `TransitionReceipt` bound to the transition, exact ID/slot, and already-completed action; it can finish exact bookkeeping or remove that resource after revocation but cannot retry or expand. Relief proves exact ownership and can never pull/run/create, start/restart a backend, reserve/refill, retry JIT, dispatch, or cancel unrelated work. Emergency makes zero GitHub calls. Automatic stale/quarantine/zombie cleanup remains admission-gated. Pre-start `docker rm -f` additionally requires immutable managed label, exact configured name/slot, recorded runner ID, and local ownership; ambiguity skips removal and fails the start. Compile-time/API tests make untyped mutations and transaction-scoped runner calls unreachable.

Make slot-ledger parsing read-only: corrupt input returns typed `CorruptLedger` with no directory create, rename, truncate, or reconciliation. Only an issuer-owning caller can mint `AdmissionMutation::QuarantineCorruptLedger` immediately before one exact no-replace rename, then end that iteration without refill. Stale/revoked admission leaves the file untouched. Fixtures cover corrupt ledger with denied admission and zero file/resource mutation, healthy one-rename quarantine followed by no same-iteration refill, and a later fresh-permit reconcile.

Use an instrumented fake side-effect sink to assert that revoked/stale admission produces zero `AdmissionMutation` and zero `ReliefCleanup` unless explicitly invoked. Separately prove capability-isolated failure-ladder and completed-canary `AuditStateWrite` persists while Docker/GitHub/slot/quarantine effects remain zero. Fixtures require distinct permits for initial JIT POST, owned conflict DELETE, and retry POST; revocation after DELETE blocks runner-ID record and retry. Force a backoff retry past expiry and prove no second child spawn. Cover pull, disk/controller probe containers, owned pre-rm, workspace reset, runner create, stale/orphan/quarantine/zombie paths, reaper cancel/force-cancel/delete, and canary dispatch independently. Barrier tests prove latch-first produces zero local commit/external spawn; gate-first registers one primitive, lets latch publication proceed while its child blocks, cancels that group, and blocks the second primitive. Repeat the barriers for admission rename/cancel, live artifact rename, deferred unit install, manager reload/enable/candidate-start, and exact VM recovery; prove latch-bound rollback restoration/reload remains available but never starts a service. Death before spawn, after spawn/before result, and after local commit/before result leaves a durable scope-typed indeterminate record, kills child descendants, performs zero replay, and applies the specified quarantine/RecoveryRequired/Mixed/endpoint-reclassification outcome. After an admitted JIT plus Docker failure and revocation, exact transition compensation may delete only that runner ID/release only that slot and may not refill. Permanent admission failure still permits proven-owned explicit stop, SIGTERM, and emergency cleanup with zero pull/run/start/refill calls and zero emergency GitHub calls.

Add module-local fixtures for every owned boundary. Canary latch-first, expired/revoked permits, and denied retry produce zero workflow dispatch; gate-first emergency cancels the registered dispatch process group; each successful dispatch has a distinct effect record. Quarantine denial/revocation changes no directory, temporary file, or final file; success records one local effect, and stale/second-use permits cannot replace it or refill in the same iteration. Failure-ladder, canary/invariant history, and alert audit writes remain available while admission is denied but cannot mint permits, retry, refill, or reach runner-control APIs. Reaper cancel, force-cancel, and delete each consume a distinct permit. SIGTERM drain and `stop` remove only proven-owned targets through `ReliefGate`; denial outside that gate and emergency cleanup both make zero unrelated workflow calls.

`AdmissionControl` is an interrupt channel, not a replacement timeout: healthy Docker commands retain 45 seconds, backend readiness/recovery 120 seconds, local readiness its existing budgets, and queue monitoring 75 seconds. Child helpers wait on unchanged normal deadline or explicit cancellation; cancellation terminates the process group with bounded grace/force-kill and returns a distinct typed result. Sleeps/polls checkpoint at most once per second. `PolicyFailed` increments the revocation epoch, alerts once, hard-cancels foreground work, and exits `78` within 15 seconds without shortening healthy budgets. `StaleSince` initially blocks only new runner mutations; first observation emits dedicated `containment.attestation.stale`, while ensure streak notification remains supplemental. A second denied observation or 75 seconds escalates to hard cancellation and exit `75`; a fresh pass before escalation clears stale. Tests cover a >300-second ten-runner batch across refreshes, healthy permit remint with unchanged counters, drift between runners, unchanged normal timeouts, child/descendant cancellation, stale recovery/escalation, no worker `process::exit`, fast-guard p99, and direct-start re-attestation.

Thread the scoped permit into every admission-capable helper, keep `start_one` private, and add compile-time/API fixtures that reject unguarded or transaction-scoped runner calls. A canonical host endpoint that is temporarily unreachable returns transient failure and never starts Lima; only an explicit recognized Colima/Lima endpoint may receive the separate bounded recovery decision below, after which full classification must succeed. Docker Desktop produces `NoRecovery` when stopped. The shell wrapper calls `--admission --json` for early failure but is defense in depth.

Define the pre-daemon `RecoveryDecision` separately from admission as the sole backend-start authority. Derived only from the persisted normalized endpoint and platform, it may be consumed once by `RecoveryGate` to spawn at most one bounded start of the exact configured stopped Colima/Lima backend on a supported platform; it cannot restart a running VM and is never retried by a generic recovery loop. Latch-first starts nothing; gate-first registers at most that one child for relief cancellation, and an indeterminate result is reclassified read-only without respawn. Canonical host, Docker Desktop, remote, inherited-context, indeterminate, and unsupported-platform endpoints always produce `NoRecovery`; tests pin zero VM commands for them and at most one exact start for stopped Colima/Lima. After a permitted VM start makes the daemon reachable, Rust reruns full topology classification and obtains `RuntimeAdmission` before pre-pull or any `AdmissionMutation`.

Add `ezgha emergency-stop --confirm [--cancel-running]` as the only tracked relief command that bypasses `serve.lock`. Under `emergency.lock` it writes and fsyncs a durable mode-`0600` `ReliefLatched` request with schema, request ID, timestamp, boot ID, optional observed transaction identity, operator intent, and digest and snapshots every registered external-effect process group after PID/start verification, then releases the lock before signalling, waiting, or cleanup. Missing/stale/mismatched/malformed nonce never discards intent. Every direct start/serve/install, startup gate, transaction phase, handoff claim, and forward effect gate rejects any unresolved latch before backend/service/runner mutation. A transaction checks before `Preparing`, during fence acquisition, before/after every operation, before deferred install, throughout handoff, and before `READY=1`; it records request ID/digest, rolls back applied bytes through `ReliefGate`, leaves the service inactive, and never candidate- or rollback-starts while latched. Repeated requests are losslessly retained. Without `--cancel-running`, no container is removed. `ReliefCleanup` uses latch-bound `ReliefGate`, obeys the no-wait-under-control-lock rule, and never clears or reinterprets forward-effect records.

With `--cancel-running`, the command has a 30-second removal deadline and requires Docker inspection to prove `ezgha=managed`, a valid `ezgha.runner_id`, exact configured prefix/slot name, and ID equality with the persisted slot assignment. Inspect failure, invalid/empty assignment, label/name mismatch, ambiguity, or sibling-host evidence skips the container. Docker inspect and approved `docker rm -f` are the only backend operations allowed; partial relief reports removed/skipped/failed IDs distinctly.

Latch acknowledgment changes transaction state to `ReliefLatched`; no runner-capable operation begins afterward. Emergency waits at most 35 seconds for acknowledgment, may stop `ezgha.service`, and leaves every durable request on timeout. Task 4 owns all transaction and recovery ordering plus the typed Rust proof/state transitions; neither recovery form starts a backend, service, or runner. Task 5 owns only the public `install.sh` command grammar and shell-to-Rust `exec` wiring for the two confirmation forms.

Thread `BackendTopology`, not raw `daemon_in_vm`, into `effective_limits_with_capacity`, `resolve_and_log_memory_budget`, and `preview_memory_budget`. `HostDocker` returns `MemoryBudgetPreview::NotApplicable`, ignores VM-only fields, skips `validate_host_envelope`, and clamps per-runner requests only to raw daemon capacity while system `actions.slice` owns the aggregate. `VmDocker` preserves the existing VM ceiling, 4-GiB reserve, floor, and preview. `Indeterminate` preserves the existing non-fatal `Ok(None)`/warning runtime behavior on Mac and other pre-existing installs; new Linux admission rejects it before any runner mutation. `ezgha init` persists `vm_total_mb` only for `VmDocker`. Add table-driven Linux and Mac tests proving canonical host behavior, recognized Docker Desktop/Colima/Lima behavior, no Mac startup regression, host fields ignored, the existing 2,754-MiB VM result, preserved indeterminate no-op behavior, fixed Linux count rejection, direct `serve` rejection before pre-pull, bounded background drift detection and tick revocation, and host Docker's inability to invoke Lima recovery.

The Rust deployment executor also installs staged `scripts/host/proof-allocator.sh` atomically to root-owned `/usr/local/libexec/ezgha/proof-allocator.sh` through a separate `DeploymentGate` effect before verifying the proof services. Fixture tests require mode `0755`, the receipt-recorded installed digest, fixed service paths, and `ReliefGate` rollback removal/restoration; a missing allocator is a failed install, never deferred to the live proof.

- [ ] **Step 5: Correct the Linux host-Docker example**

In `config/config.toml.linux.example`, retain `count = 10`, set `[backend].docker_endpoint = "unix:///var/run/docker.sock"`, and preserve standard selectors while adding the confirmed fleet selector, so labels become `[self-hosted, self-hosted-mikey, ezgha, ez-runner-c, Linux, X64]`. Set `runner_floor_mb = 2500`, set `limits.memory_mb = 2500`, and remove the explicit Colima-only `vm_total_mb`, `guest_reserve_mb`, and `host_reserve_mb` claims. The capacity proof deliberately selects the confirmed four-label subset `[self-hosted, self-hosted-mikey, ezgha, ez-runner-c]`; `ez-runner-c` is absent from both Mac and Linux-canary examples, so those jobs cannot escape to another fleet after the registry collision check, while the additive `Linux`/`X64` labels preserve normal fresh-host consumers. Update config/JIT payload fixtures to prove the endpoint and all six labels are persisted and registered. State the blast radius explicitly: this aligns the tracked fresh-machine default from 3000 to the already-live Jeff-Ubuntu value of 2500 MiB, a 16.7% reduction for new hosts that may expose memory-heavy jobs, additively migrates the live four-label fleet to six labels, and persists the already-effective host socket without removing a selector. Explain that the sum of tracked workload hard caps leaves about 8.5 GiB of budgeted headroom but does not cap desktop, kernel, Docker, or other system memory. Activation records the existing live value and must stop for reviewed profile sizing rather than silently lowering a host above 2500 MiB; release evidence requires the bounded job-outcome sample and ten-worker proof.

- [ ] **Step 6: Verify install behavior and commit**

Run:

```bash
cargo test containment::tests
cargo test alert::tests
cargo test backend::tests
cargo test canary::tests
cargo test config::tests
cargo test service::tests
cargo test docker_backend::tests
cargo test failure_ladder::tests
cargo test github::tests
cargo test lima_convergence::tests
cargo test platform::tests
cargo test queue_monitor::tests
cargo test quarantine::tests
cargo test reaper::tests
cargo test shutdown::tests
cargo test backend_restart
cargo test memory_budget
cargo test
bash tests/assert_crash_containment_test.sh
git diff --check
git add scripts/host/ezgha-start-gate.sh src/alert.rs src/backend.rs src/canary.rs src/containment.rs src/config.rs src/service.rs src/main.rs src/docker_backend.rs src/failure_ladder.rs src/github.rs src/lima_convergence.rs src/platform.rs src/queue_monitor.rs src/quarantine.rs src/reaper.rs src/shutdown.rs config/config.toml.linux.example
git commit -m "codex/gpt-5.6-sol: install host crash-containment policy"
git push origin HEAD
```

Expected: all focused installer and assertion tests PASS.

### Task 5: Make Doctor and Exit Gates Verify Effective Containment

**Files:**
- Modify: `install.sh`
- Create: `scripts/host/install-crash-containment.sh`
- Modify: `scripts/cleanup-stuck-runs.sh`
- Modify: `doctor-runner`
- Modify: `docs/verify-exit-criteria.sh`
- Modify: `docs/host-ops-sudo-block-0725.md`
- Modify: `.github/workflows/ci.yml`
- Delete: `systemd/ezgha.service.d/10-oomd-omit.conf`
- Delete: `systemd/psi-oom-watcher.service`
- Delete: `systemd/psi-oom-watcher.timer`
- Delete: `scripts/host/psi-oom-watcher.sh`
- Delete: `systemd/ezgha-queue-reaper.service`
- Delete: `systemd/ezgha-queue-reaper.timer`
- Delete: `scripts/queue-reaper-stopgap.sh`
- Delete: `launchd/org.jleechanorg.ezgha-queue-reaper-stopgap.plist.template`
- Modify: `docs/test-cleanup-stuck-runs.sh`
- Modify: `tests/install_watchdog_gate_test.sh`
- Modify: `tests/install_uninstall_aux_units_test.sh`
- Modify: `tests/host_control_artifacts_test.sh`
- Modify: `tests/host_ops_0725_test.sh`
- Modify: `tests/doctor_runner_host_pressure_test.sh`
- Modify: `tests/verify_exit_gate8_test.sh`
- Create: `tests/crash_containment_suite.sh`
- Create: `tests/install_transaction_recovery_test.sh`
- Create: `tests/install_crash_containment_test.sh`

**Interfaces:**
- Consumes: Task 3 assertion output and Task 4's installed paths, typed Rust deployment/relief/recovery primitives, and complete Rust handoff protocol.
- Produces: one public atomic installation entrypoint, shell-owned preflight/local-build/staging/dispatch ordering, explicit recovery-confirmation routing, retirement of the conflicting watcher/exemption stack and every independently scheduled mutating queue reaper, read-only topology/reaper diagnostics, and a CI-enforced hard harness gate. Task 5 owns `install.sh` command grammar and its final `exec` into Task 4 Rust, including `--recover-transaction --confirm-transaction <nonce>` and `--recover-transaction --confirm-request <id>`; it never owns quiescence, control locks, durable state, Rust handoff logic, or any live mutation primitive.

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

Retire the old watcher stack atomically in this task. In the same commit: delete the four tracked watcher/exemption artifacts; remove their ordinary install and uninstall loops; add their exact final paths and prior state to the staging manifest so Task 4's Rust transaction disables/removes the installed timer, service, stable script, and live `~/.config/systemd/user/ezgha.service.d/10-oomd-omit.conf` through typed gates; verify `ManagedOOMPreference` is not `omit` and `OOMScoreAdjust` is not `-1000`; remove any legacy `systemctl set-property --runtime actions.slice` path; update every active test and operator document; and replace Gate 7/8 watcher checks with effective `systemd-oomd` root enrollment and finite-cgroup checks. Rewrite `docs/host-ops-sudo-block-0725.md` to name the watcher and exemption as retired and point to the tracked containment transaction. Add a regression scan that fails when active surfaces (`install.sh`, `docs/verify-exit-criteria.sh`, `docs/host-ops-sudo-block-0725.md`, `README.md`, or `CLAUDE.md`) instruct users to install, enable, or depend on `psi-oom-watcher` or `10-oomd-omit.conf`; historical activity logs may retain incident references. Add a Task 5-owned forced-failure integration fixture that begins with byte-distinct installed watcher units/script and live exemption, plus active/enabled watcher state; inject failure after Rust retirement and prove exact file bytes, prior enabled/active states, and effective exemption properties are restored through Task 4 `ReliefGate`. No intermediate commit may delete a source artifact while the Rust transaction, verifier, or test still depends on it.

Retire the independent queue-reaper stack in the same transaction. Task 5 deletes the tracked source artifacts, removes staging loops that recreate them, removes `cleanup-stuck-runs.sh --apply`, and adds exact installed service/timer/launchd/script targets plus prior state to the manifest. Task 4's Rust transaction stops/disables and removes those installed targets through typed gates. Verify no matching systemd unit or launchd job is active/enabled and no active source invokes the removed apply path. Forced-failure fixtures restore prior external reaper bytes/state exactly through `ReliefGate`; successful installation leaves only the supervisor-owned gated reaper. No intermediate commit may remove a source while the Rust transaction or an active test still references it.

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

Make `install.sh` the single public deployment entrypoint and sole shell preflight/build/stage dispatcher; Task 4's Rust transaction remains the sole owner of quiescence, locks, durable state, live commit/rollback ordering, and manager effects. Update `CLAUDE.md` Gate 0 so Linux deployment invokes this entrypoint and removes raw `cargo install --path .` plus direct restart as an accepted substitute. Remove the current config-exists auto-install/restart branch: a first pass with no config performs only `cargo build --locked --release` and prints `target/release/ezgha init` plus second-`./install.sh` bootstrap steps. It does not replace an installed binary or build/pull/run a Docker image. Bootstrap `init` may query endpoint/daemon metadata read-only but cannot start/recover a backend; it writes only the mode-`0600` starter config and creates canonical `state_dir` as a non-symlink directory owned by the deploy UID with exact mode `0700`. After the read-only static verdict and private staging, `install.sh` verifies the newly built candidate path/mode/digest equals the manifest and uses `exec` to replace itself with that exact candidate, so no shell coordinator survives to race or retry it. Rust revalidates static, consumes any exact `RecoveryDecision`, and obtains the dynamic verdict before image or live mutation. `EZGHA_PROPOSED_CONFIG`, or the explicit config-only bootstrap path when that variable is absent, must resolve to a mode-`0600` regular proposed file; every install/handoff rejects a foreign-owned, symlinked, or group/world-writable state directory. Config existence alone is staged data, not upgrade evidence; Rust uses the four-state classifier and rejects `Mixed` before Docker image or installed/live mutation. Fixtures begin from no config and prove the first pass records only the local Cargo build plus guidance, with zero service-manager, Docker, installed-binary, or live-config mutation.

Implement `scripts/host/install-crash-containment.sh` here with exactly `--preflight`, `--check`, and `--stage`; remove or fail closed on legacy `--install`. `--stage` writes only beneath a newly created private candidate directory and emits the receipt-bound manifest consumed by Rust. Add a static shell scan plus an execution trace proving `install.sh` and the stager contain no direct `sudo`, mutating `systemctl`, Docker image/runtime mutation, final-path write/remove, or rollback command. Normal install must end with exact `exec` of the newly built candidate whose path/mode/digest matches the manifest; either recovery form must end with exact `exec` of the receipt-bound installed binary and reject missing or mismatched receipt evidence.

After an allowed local `cargo build --locked --release` creates the exact candidate binary, require the static install verdict against the proposed config, stage privately, and `exec` Rust. The Rust transaction revalidates static and, for a recognized explicit Colima/Lima endpoint on a supported platform only, may consume one `RecoveryDecision` through `RecoveryGate` to start that exact VM; Docker Desktop returns `NoRecovery`, and the dynamic Docker-backed verdict must then pass. Host Docker never recovers a VM, and shell never invokes a VM command. Add an ordered fixture whose Docker stub records build, pull, start, restart, and run: the recoverable Colima/Lima VM start is allowed only between successful static and dynamic checks, while image/Docker runner mutation requires both; every forbidden call fails the test. A failed phase exits without image work or policy/service mutation. Neither verdict is an admission permit.

Once `install.sh` has `exec`d the candidate, Rust obtains the dynamic verdict; after both verdicts pass, Rust snapshots the installed binary bytes/path/mode/digest; live config; every old policy/helper file; the deployment receipt; exact generated `ezgha.service` and `ezgha-alert@.service` units; retired watcher/exemption files; and applicable active/enabled states. Before image or installed/live mutation, Rust verifies preserved `state_dir`/target/scope/prefix, acquires `emergency.lock` only to reject any relief latch, releases it, stops active `ezgha.service`, and verifies inactive/MainPID exit without either lock. It then reacquires `emergency.lock`, rechecks all latches, publishes `Preparing`, and releases it before bounded `serve.lock` acquisition and the `Fenced` transition. It never waits for service stop, process exit, or the fence while holding the control lock; any latch instead records `ReliefLatched`, restores no active service, and starts nothing. Managed-upgrade containers may remain only when their actual cgroups are already beneath `actions.slice`. Legacy migration drains under the Rust-held FD without cancelling busy jobs. Rust validates numeric bounds/inode, requires `EWOULDBLOCK` on a second canonical descriptor, and never unlocks/closes the retained FD before terminal transfer or fail-closed recovery. Task 4 fixtures cover latch races, no control lock during waits, descriptor identity/contention, zero admission between fence and handoff, and release-build lock-bypass rejection; Task 5 fixtures prove the normal candidate identity/`exec` arguments and absence of a surviving shell coordinator.

Only after quiescence, `Preparing`, fence acquisition, and nonce-matched `Fenced` may Rust acquire/build the image and commit the already-staged candidate binary, mode-`0600` config, helpers, policy, both units, and receipt manifest. Before `exec`, the shell performs reads and private staging only: it never runs `sudo`, a mutating `systemctl`, a final-path write/remove, Docker image mutation, socket/peer operations, or lock/latch/state mutation. Task 4's Rust executor revalidates the manifest and routes every live artifact/policy/unit commit and manager reload/enable/start spawn separately through `DeploymentGate`, with `TransactionAdmission` additionally required for deferred unit commits. Config and receipt artifacts are one Rust-owned rollback unit. Rust checks durable relief before/after each bounded operation, before deferred install, at least once per second during drain, and through handoff. Latch acknowledgment atomically records `ReliefLatched`, blocks every later forward gate, rolls back under `serve.lock` through `ReliefGate`, and leaves the supervisor inactive. Stale/malformed/mismatched transaction or latch state remains fail-closed until exact verified recovery/clearance; shell never retries an unknown live result.

Implement both recovery entrypoints in `install.sh`. The shell validates mutually exclusive exact syntax plus the existing deployment receipt and `exec`s its exact installed binary with only the confirmation value; a missing or path/mode/digest-mismatched receipt fails before recovery. It performs no lock, latch, state, socket, service-manager, or live-file mutation itself. Before any state, lock, gate, backend, manager, or final-path access, the Rust recovery entrypoint opens, `fstat`s, and hashes its own `/proc/self/exe` descriptor and requires canonical target, owner, regular-file mode, digest, and recovery-capable role to equal the installed receipt. Missing identity, an alternate copy, or pathname replacement/deletion exits with zero effects. Non-emergency `./install.sh --recover-transaction --confirm-transaction <nonce>` then causes Rust to acquire `serve.lock` without holding `emergency.lock`, reject any unresolved request, require the service inactive, prove no live transaction/service owner, and accept only matching `Preparing`, `Fenced`, `HandoffReserved`, `HandoffClaimed`, `HandoffLocked`, `SubmissionUnknown`, or `RecoveryRequired`. Rust completes/verifies saved rollback or proves no mutation, removes only identity-proven stale socket state, fsyncs `RecoveredInactive`, and leaves pre-baton state disabled/inactive while permitting a later clean transaction retry.

Relief `./install.sh --recover-transaction --confirm-request <id>` routes through the same receipt-bound installed binary to the Rust fence, inactivity, dead-owner, and rollback/no-mutation proof, validates that exact request ID/digest, then tombstones only that request under `emergency.lock` and fsyncs the collection. Other requests remain durable and keep every startup/admission path blocked. Clearing the final request archives `RecoveredInactive` only when a valid transaction snapshot exists; with no prior transaction it fsyncs `no_transaction_mutation`, creates no recovery archive, and a later ordinary start independently performs full admission. Busy fence, live owner, active service, wrong identity, malformed/unknown state, or inconsistent snapshot remains fail-closed. Task 5 fixtures cover both routes, missing/conflicting confirmations, exact installed-binary/receipt arguments and digests, every stranded state, wrong nonce, repeated-request order, remaining-request blocking, no-transaction clearance, and zero direct shell `sudo`/`systemctl`/live-write/GitHub/backend-start/refill/create calls.

After `install.sh` `exec`s, Task 4's Rust transaction internally invokes deferred unit installation, final admission, and `handoff-service`; it alone owns the transaction FD, typed state, effect gates, wait/deadline handling, and rollback. Task 5 ends at exact `exec` dispatch. Its integration fixtures prove only private staging, the distinct normal candidate versus recovery installed-binary paths/modes/digests and exact `exec` argv, exit-status propagation, and no surviving shell or shell-side live effect. Task 4 additionally invokes the transaction through the old installed binary and an alternate copy, replaces/deletes the candidate pathname after shell verification, and performs the equivalent recovery-binary replacement; every case must prove zero lock/state/gate/backend/manager/final-path effect. FD preservation, `READY`, typed handoff outcomes, rollback, peer proof, `SCM_RIGHTS`, close-on-exec, socket cleanup, terminal-owner CAS, death windows, and deadline boundaries are Task 4 Rust tests committed with its Rust files.

Create `tests/crash_containment_suite.sh` as the CI entrypoint for every non-live containment fixture. It runs the policy, artifact, assertion, installer, transaction-recovery, installation-consumer, doctor, Gate 8, and proof-script fixture tests using a deterministic explicit list plus the narrowly scoped `*crash_containment*_test.sh` glob with de-duplication. Add that suite to `.github/workflows/ci.yml` now; Task 6's future `tests/prove_crash_containment_test.sh` must be picked up without Task 6 editing the shared workflow. CI never starts live proof services.

Run the bounded job-outcome monitor before and after applying `CPUQuota=2000%` with the exact repository and thresholds below. It measures attributed job conclusions, not duration; treat `UNHEALTHY` or `UNKNOWN` as a deployment gate failure even when container liveness passes. The aggregate quota equals the ten configured 2-CPU maxima, so the plan makes no undefined latency-regression claim.

- [ ] **Step 5: Verify and commit**

Run:

```bash
bash -n doctor-runner docs/verify-exit-criteria.sh
bash -n install.sh scripts/host/install-crash-containment.sh tests/install_crash_containment_test.sh tests/install_transaction_recovery_test.sh
bash tests/install_crash_containment_test.sh
bash tests/install_transaction_recovery_test.sh
bash tests/doctor_runner_host_pressure_test.sh
bash tests/verify_exit_gate8_test.sh
bash tests/host_control_artifacts_test.sh
bash tests/host_ops_0725_test.sh
bash tests/crash_containment_policy_test.sh
bash tests/install_watchdog_gate_test.sh
bash tests/install_uninstall_aux_units_test.sh
bash tests/crash_containment_suite.sh
git diff --check
git add install.sh scripts/host/install-crash-containment.sh scripts/cleanup-stuck-runs.sh doctor-runner docs/verify-exit-criteria.sh docs/host-ops-sudo-block-0725.md docs/test-cleanup-stuck-runs.sh .github/workflows/ci.yml tests/install_crash_containment_test.sh tests/install_transaction_recovery_test.sh tests/install_watchdog_gate_test.sh tests/install_uninstall_aux_units_test.sh tests/host_control_artifacts_test.sh tests/host_ops_0725_test.sh tests/doctor_runner_host_pressure_test.sh tests/verify_exit_gate8_test.sh tests/crash_containment_suite.sh
git add -u systemd/ezgha.service.d/10-oomd-omit.conf systemd/psi-oom-watcher.service systemd/psi-oom-watcher.timer scripts/host/psi-oom-watcher.sh systemd/ezgha-queue-reaper.service systemd/ezgha-queue-reaper.timer scripts/queue-reaper-stopgap.sh launchd/org.jleechanorg.ezgha-queue-reaper-stopgap.plist.template
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
effective DefaultMemoryPressureDurationSec outside integral 1..=45 seconds => preflight FAIL
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
4. In `--oomd` mode, parse and record effective `DefaultMemoryPressureDurationSec` from `systemd-analyze cat-config systemd/oomd.conf`; accept only an unambiguous integral whole-second value in `1..=45` and reject missing, malformed, zero, negative, fractional, unit-suffixed, or larger values before allocation. Use `${SUDO_BIN:-sudo} systemctl start ezgha-oomd-proof.service` for the fixed tracked unit and wait at most 90 seconds. Sample the child `memory.pressure` once per second while the fixed 640-MiB working set is continuously retouched for up to 75 seconds. Require the exact `full avg10` value to remain at least 20% continuously for the discovered effective duration and require a new `systemd-oomd` journal record naming a descendant of `ezghaproof-oomd.slice`; `some`, `avg60`/`avg300`, a lone above-threshold sample, allocator exit, a kernel OOM, or a victim record without the continuous measured interval is not evidence.
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
         tests/install_transaction_recovery_test.sh \
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

Expected: after candidate build, `install.sh` obtains the static verdict, stages a private manifest, verifies candidate path/mode/digest, and `exec`s that exact candidate before any live mutation. Rust obtains the dynamic verdict, snapshots all artifacts, checks the relief latch under `emergency.lock`, releases that lock before stopping/waiting for the old supervisor, then reacquires/rechecks it to publish `Preparing`. Rust acquires canonical `serve.lock`, drains legacy containers without cancelling jobs, and commits each candidate artifact and hierarchy operation through `DeploymentGate` without starting the candidate prematurely. Final admission validates every receipt artifact; the Rust handoff helper queues exact private mode while fenced, proves the claimed systemd peer, and transfers the continuously locked FD with `SCM_RIGHTS`/receiver close-on-exec inside the fixed connect/ready deadlines. The claimant sends `FD_ACCEPTED` before the transaction closes its copy, then proves listener closure plus matching socket cleanup before recording boot-stamped `ServiceOwned`, pre-pull, `READY=1`, or runner work. Ordinary restart resolves and archives only a proven dead same/prior-boot owner after taking the lock; live/malformed evidence fails closed. Failure before ownership stops candidate, verifies transferred-FD closure, reacquires, and restores through `ReliefGate`. Compatible rollback repeats descriptor handoff; pre-baton rollback remains disabled/inactive and the receipt-bound installed recovery binary makes it retryable without starting it.

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
  src/alert.rs src/backend.rs src/canary.rs src/containment.rs src/config.rs src/docker_backend.rs src/failure_ladder.rs src/github.rs src/lima_convergence.rs src/main.rs src/platform.rs src/queue_monitor.rs src/quarantine.rs src/reaper.rs src/service.rs src/shutdown.rs \
  scripts/host/agent-scoped-launch.sh \
  scripts/host/agent-cli-scoped.sh \
  scripts/host/agent-auto-migrate.sh \
  scripts/host/assert-crash-containment.sh \
  scripts/host/ezgha-start-gate.sh \
  scripts/host/proof-allocator.sh \
  scripts/host/install-crash-containment.sh \
  scripts/host/prove-crash-containment.sh \
  install.sh scripts/cleanup-stuck-runs.sh config/README.md config/config.toml.linux.example doctor-runner \
  docs/verify-exit-criteria.sh docs/host-ops-sudo-block-0725.md docs/test-cleanup-stuck-runs.sh \
  .github/workflows/ci.yml \
  tests/crash_containment_policy_test.sh \
  tests/host_control_artifacts_test.sh \
  tests/host_ops_0725_test.sh \
  tests/host_crash_containment_artifacts_test.sh \
  tests/assert_crash_containment_test.sh \
  tests/install_crash_containment_test.sh \
  tests/install_transaction_recovery_test.sh \
  tests/install_watchdog_gate_test.sh \
  tests/install_uninstall_aux_units_test.sh \
  tests/doctor_runner_host_pressure_test.sh \
  tests/verify_exit_gate8_test.sh \
  tests/crash_containment_suite.sh \
  tests/prove_crash_containment_test.sh \
  "$EVIDENCE_DIR"
git add -u systemd/ezgha.service.d/10-oomd-omit.conf systemd/psi-oom-watcher.service systemd/psi-oom-watcher.timer scripts/host/psi-oom-watcher.sh systemd/ezgha-queue-reaper.service systemd/ezgha-queue-reaper.timer scripts/queue-reaper-stopgap.sh launchd/org.jleechanorg.ezgha-queue-reaper-stopgap.plist.template
git commit -m "codex/gpt-5.6-sol: enforce workload crash containment"
git push origin HEAD
git status --short --branch
```

Expected: push succeeds, the branch is synchronized with its upstream, and unrelated `.playwright-mcp/` content remains untouched.
