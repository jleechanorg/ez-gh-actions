# Runner Fleet CPU & Resource Optimization Implementation Plan (Revised)

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Propose a hard 1.0 vCPU per-container ceiling, document the resulting quota arithmetic, and provide safe operator recovery and workload optimization guidance. Live configuration edits, service restarts, and fleet recovery require a separately authorized deployment step.

**Architecture:** Multi-tiered controls bounding configured container CPU usage across daemon configuration, container cgroups, operator recovery procedures, and cross-repo workflow environment controls. A quota difference is not a reservation or host stability guarantee.

**Tech Stack:** Rust (ezgha CLI), Docker CLI/Cgroups v2, macOS launchd, Colima/Virtualization.framework, GitHub Actions workflows, pytest.

---

### Task 1: Tracked Configuration & Example Alignment

**Files:**
- Inspect: `/Users/jleechan/projects_other/ez-gh-actions/config/config.toml.mac.example`
- Inspect only during this planning unit: the active config path selected by the
  installed service (which may be `/Users/jleechan/Library/Application Support/org.jleechanorg.ezgha/config.toml` on macOS) and `/Users/jleechan/.config/ezgha/config.toml`

**Step 1: Inspect tracked example config**
Run:
```bash
grep -n "cpus" config/config.toml.mac.example
```
Expected: Record the current tracked values exactly. The committed Mac example
currently has `memory_mb = 8192`, `cpus = 1.0`, and `min_free_disk_gb = 10`.

**Step 2: Record the proposed limit without rolling it out**
The proposal is `cpus = 1.0` in `[limits]` and no `cpu_burst` field. Do not
edit active configs or change `name_prefix` in this planning unit. A historical
live sample reported `memory_mb = 3072` and `min_free_disk_gb = 7`; keep that
separate from the tracked example and re-read the active `--config` path before
any deployment claim.

**Step 3: Validate config schema (read-only)**
Run:
```bash
CONFIG_PATH="<exact --config path from the active service>"
ezgha --config "$CONFIG_PATH" doctor
```
Expected: the command only reports the selected configuration. A separate
deployment owner must decide whether any live values change.

---

### Task 2: Service Reload & Container Cgroup Verification (separate rollout)

**Files:**
- Read/Inspect: `/tmp/ezgha-launchd-stdout.log`
- Read/Inspect: `/tmp/ezgha-launchd-stderr.log`

**Step 1: Drain and identify the owning supervisor before any restart**
Do not restart while a same-host `Runner.Worker` is present unless the deploy
owner has explicitly accepted terminating that job. Use `doctor-runner` and
per-slot `docker top` proof to wait for a safe drain. Resolve the supervisor
identity from the active service rather than assuming a fixed user ID.

**Step 2: Restart the owning supervisor after separate deployment approval**
Run:
```bash
launchctl kickstart -k "gui/$(id -u)/org.jleechanorg.ezgha"
```
On Linux, use `systemctl --user restart ezgha.service`. Expected: the daemon
restarts only after the approved config is installed and reads that exact path.

**Step 3: Verify active containers**
Run:
```bash
sleep 8 && docker ps --filter "label=ezgha=managed" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
```
Expected: all configured slots under the active prefix are running.

**Step 4: Verify NanoCpus cgroup limit on every container**
Run:
```bash
CONTAINERS=(container-1 container-2)  # replace with exact active slot names
docker inspect "${CONTAINERS[@]}" --format '{{.Name}}: NanoCpus={{.HostConfig.NanoCpus}}'
```
Expected: Every configured container outputs `NanoCpus=1000000000` (1.00
vCPU). Resolve the exact prefix and slot names from the active configuration;
do not assume a historical prefix.

---

### Task 3: Operator Runbook Documentation for Crash Recovery

**Files:**
- Create/Append: `/Users/jleechan/projects_other/ez-gh-actions/docs/runbooks/ghost-runner-recovery.md`

**Step 1: Use the canonical runbook**
Follow [`docs/runbooks/ghost-runner-recovery.md`](../../runbooks/ghost-runner-recovery.md).
It requires exact runner/container targets, a supervisor quiescence step,
backups before edits, quiescence of every watchdog/timer that can restart the
daemon, a full current-prefix re-inventory, an immediate per-target
`Runner.Worker` check, and no blanket deletion of managed containers or daemon
state. Defer prefix rotation while any same-host container remains running.
Restore only controllers recorded as previously active. This plan does not
authorize a live prefix change, state reset, container removal, or service
restart.

---

### Task 4: Cross-Repo CI Workflow Optimization (worldarchitect.ai)

**Files:**
- Target Repo: `/Users/jleechan/projects/worldarchitect.ai`
- Workflows: `.github/workflows/self-hosted-mvp-shard1.yml`, `.github/workflows/test.yml`

**Step 1: Configure TEST_MAX_WORKERS in workflow environment**
Set `TEST_MAX_WORKERS: 1` on self-hosted macOS test jobs.

**Step 2: Audit git checkout depth**
Replace full clones (`fetch-depth: 0`) with blobless partial clones
(`filter: blob:none`) or `fetch-depth: 1` where commit history is not required.

---

### Task 5: End-to-End Fleet Health & Doctor Audit

**Files:**
- Execute: `/Users/jleechan/projects_other/ez-gh-actions/doctor-runner`

**Step 1: Run comprehensive fleet health check**
Run:
```bash
./doctor-runner
```
Expected: verify the configured capacity from the active config and report each
slot's local state. Do not hardcode a historical fleet total; `doctor-runner`
and `docker top` are the source of truth for current execution state.
