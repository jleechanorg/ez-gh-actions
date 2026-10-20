# Design Specification: Runner Fleet CPU & Resource Optimization (Revised)

- **Topic:** Runner Fleet CPU & Resource Optimization
- **Date:** 2026-10-04
- **Author:** Antigravity / Pair Programming Agent
- **Target Repository:** `jleechanorg/ez-gh-actions` (with cross-repo recommendations for `jleechanorg/worldarchitect.ai`)
- **Scope:** Daemon resource limits, Colima VM host-envelope protection, CI test worker concurrency, git clone shallowing, and crash recovery runbooks.

---

## 1. Assumptions and Recommended Defaults

Per the `/superpowers-quick` specification, all design questions and forks encountered during planning have been resolved autonomously using repository empirical evidence and best engineering practices.

| # | Question Considered | Auto-Picked Choice | Rationale |
|---|---------------------|--------------------|-----------|
| 1 | **CPU Enforcement Model**: How should CPU limits be enforced across ephemeral runner containers? | **Hard-Cap Per-Container vCPUs (`cpus = 1.0`) in `Limits` and omit `cpu_burst`.** | The deployed binary on this host (`657476f` from branch `codex/runner-throughput-20261003`) honored `cpu_burst = true`, bypassing the `ncpu / count` clamp (`8 / 6 = 1.33`) and assigning `--cpus 4.0` (`NanoCpus: 4000000000`) to every runner container. Across 6 runners, this permitted a cumulative 24.0 vCPUs of configured container quota on an 8-vCPU Colima VM; it coincided with high load and could have contributed to the `VirtualMachineStateError` crash. Setting `cpus = 1.0` and removing `cpu_burst` caps configured container CFS quota to 6.0 vCPUs. The 2.0 vCPU arithmetic difference is not a reservation for guest or I/O work. Furthermore, omitting `cpu_burst` ensures compatibility across branches (`HEAD` rejects unknown fields via `#[serde(deny_unknown_fields)]`). |
| 2 | **Test Concurrency inside Runners**: How should CI pytest suites behave regarding multiprocessing? | **Enforce explicit worker ceilings (`TEST_MAX_WORKERS=1` or `max_workers=1` on heavy shards in `worldarchitect.ai`).** | Inside Ubuntu 24.04 containers, Python 3.12 may report the VM's CPU count rather than the container quota. Unconstrained multiprocessing or `pytest -n auto` can spawn 8 child processes per runner. Spawning 8 workers inside a 1.0-vCPU container increases CFS throttling and process-scheduling overhead. A single worker supplies a serial baseline with less xdist overhead. Note: `-n 1` still invokes xdist; `-n 0` or single-worker execution provides the cleanest serial baseline. |
| 3 | **Git Clone Depth**: How should repository checkouts be configured in workflow runs? | **Use blobless partial clones (`filter: blob:none`) or audited `fetch-depth: 1` in `worldarchitect.ai`.** | Unconditional `fetch-depth: 1` breaks jobs requiring commit history (such as `git diff origin/main...`, changed-file detection, or setuptools_scm). A blobless partial clone retains the commit graph while deferring blob transfer; measure the resulting I/O reduction for each workflow rather than assuming a fixed percentage. Full clones (`fetch-depth: 0`) should be audited and avoided where unnecessary. |
| 4 | **Ghost Runner Lock Decoupling**: How should daemon crash recovery handle runners locked by GitHub with HTTP 422? | **Retain existing daemon per-slot quarantine; document prefix bump as an operator-only manual runbook step.** | Per-slot quarantine (`docker_backend.rs:698-808`, bead `ghd2.2`) already handles isolated 422 errors by backing off and auto-recovering when GitHub releases the lock. Automatic prefix rollover in daemon code would leak registrations in the orphan reaper (`{name_prefix}-`), cause desync with `doctor-runner`, and mutate daemon configuration in memory. Therefore, prefix rollover is explicitly designated an **operator-only runbook procedure** for ungraceful VM crash recovery. |
| 5 | **Host Envelope Attribution**: What drove the host 1-minute load average to 42–73? | **Multi-process host contention (Colima VZ + cmux + WindowServer + Aside + background searches).** | A host `ps aux -r` snapshot showed concurrent load from `cmux DEV` (~48%), `WindowServer` (~44%), `Aside Helper` (~32%), `Codex (Service)` (~25%), and an unthrottled background `grep` process (~11.5%). That snapshot does not establish a sole cause for the load average. Capping runner containers to 1.0 vCPU reduces their configured contribution during peak development activity. |

---

## 2. Problem Statement & Baseline Telemetry

### 2.1 The Colima Crash Incident
At `2026-10-03T23:06:48-07:00`, the Colima VM stopped unexpectedly:
```
VirtualMachineStateError: Virtual machine stopped unexpectedly
```
Captured in `/Users/jleechan/.colima/_lima/colima/ha.stderr.log` line 893.
At crash time:
- 6 runner containers were active on the Mac host.
- Colima's `com.apple.Virtualization.VirtualMachine` process was consuming >750% CPU.
- Host load average was between 42.0 and 73.0 across 14 cores.

### 2.2 Root Cause Analysis
1. **Installed Binary Discrepancy & CPU Over-Burst**:
   `/Users/jleechan/.cargo/bin/ezgha` was running commit `657476f` (from `origin/codex/runner-throughput-20261003`), where `cpu_burst` was implemented. With `cpu_burst = true` and `cpus = 4.0`, containers were launched with `--cpus 4.00` (`NanoCpus: 4000000000`). All 6 containers combined could burst up to 24 cores of compute inside an 8-core VM.
2. **Ghost Runner HTTP 422 Lockout**:
   When the VM crashed, GitHub retained 4 runners in `status: "offline", busy: true`. On restart, JIT generation failed with HTTP 409 (`Already exists`).
3. **Container Multiprocessing**:
   Python 3.12 reported `os.cpu_count() == 8`, causing test suites to spawn multiple workers per container against a throttled CFS quota.

---

## 3. Detailed Component Design

### 3.1 Daemon Limit Enforcement & VM Headroom
- The tracked example currently records `memory_mb = 8192`, `cpus = 1.0`, and `min_free_disk_gb = 10` in `config/config.toml.mac.example`. A historical live-host sample used for incident analysis reported `memory_mb = 3072` and `min_free_disk_gb = 7`; those values are deployed-state evidence, not the tracked example or a current contract. Verify the active `--config` path before making a production claim:
  ```toml
  [limits]
  memory_mb = 8192
  cpus = 1.0
  pids = 512
  min_free_disk_gb = 10
  ```
- In `src/docker_backend.rs`:
  - `effective_limits(cfg)` evaluates:
    $$\text{effective\_cpus} = \min(\text{cfg.limits.cpus}, \frac{\text{ncpu}}{\text{count}}) = \min(1.0, 1.33) = 1.0$$
  - Every container is spawned with `--cpus 1.00`, setting Docker `HostConfig.NanoCpus = 1000000000`.
  - For 6 runners, total configured container CFS quota is bounded to:
    $$\sum_{i=1}^6 1.0 = 6.0 \text{ vCPUs}$$
  - If the Colima VM has 8 vCPUs, the arithmetic difference is:
    $$8.0 - 6.0 = 2.0 \text{ vCPUs (25\% of the VM total by arithmetic)}$$
  - This is a configured quota difference, not a reserved-core or host-headroom guarantee; guest, Docker, virtiofs, and other host workloads still compete for CPU.

### 3.2 Operator Runbook: Ghost Runner Recovery via Prefix Bump
Use the operator-only procedure in
[`docs/runbooks/ghost-runner-recovery.md`](../../runbooks/ghost-runner-recovery.md).
It resolves the active plist/unit configuration and state paths, backs them up,
records and quiesces every watchdog/timer that can restart the daemon,
re-inventories every current-prefix container after quiescence, verifies that
every explicitly selected local container lacks `Runner.Worker`, and removes
only those named stopped containers. A partial ghost incident must not trigger
a blanket container or slot-state deletion. Old-prefix registrations are
deleted by their exact GitHub runner ID only after `busy=false`; the daemon does
not automatically harvest registrations outside its active prefix.

### 3.3 CI Workload Optimization (Cross-Repo: `worldarchitect.ai`)
- **Worker Concurrency**: Set `TEST_MAX_WORKERS: 1` in workflows for CPU-intensive shards.
- **Git Checkouts**: Use `filter: blob:none` for shards requiring git diffs; reserve full clones (`fetch-depth: 0`) only for explicit changelog or tagging jobs.

---

## 4. Verification Checklist

- [x] All design forks resolved and documented with rationale.
- [x] Provenance of `cpu_burst` and binary versions documented.
- [x] Full absolute file paths used throughout.
- [x] Host load attribution and CFS quota distinctions clarified.
- [x] Operator runbook replaces automated prefix rollover to avoid orphan leakage.
