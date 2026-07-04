# Ephemeral Runner PR Trigger Verification Proof (2026-07-04)

This bundle provides E2E evidence verifying that the self-hosted `ezgha` runner fleet successfully triggers, registers, and executes CI workflow jobs on pull requests, with graceful degradation when individual slots fail to spawn.

## 1. Dispatch & Execution Context

* **Pull Request**: [jleechanorg/ez-gh-actions#5](https://github.com/jleechanorg/ez-gh-actions/pull/5)
* **Branch**: `test/trigger-ezgha-pr`
* **Trigger Event**: `pull_request` (PR creation/push)
* **Workflow Run**: [Run 28716749348](https://github.com/jleechanorg/ez-gh-actions/actions/runs/28716749348)
* **Workflow Status**: `success` (Completed)
* **Runner Assigned**: `ez-org-runner-16` on host `85436641225b`

---

## 2. Loop Resilience & Graceful Spawning Proof

Prior to our fix, if any slot JIT registration failed (e.g. slot 13 having a busy offline runner conflict on GitHub), the spawn cycle aborted sequentially, preventing slots 14, 15, and 16 from starting.

As proven in [journal.txt](file:///home/jleechan/projects/ez-gh-actions/evidence/pr-trigger-proof-20260704/journal.txt):
1. The daemon starts `ensure_count`.
2. Slot 13 JIT registration returns HTTP 409 because `ez-org-runner-13` is still busy on GitHub executing a stale run.
3. The daemon emits a warning `warning: failed to start runner: ... (HTTP 409)` but continues execution rather than aborting.
4. The daemon successfully spawns slots 14, 15, and 16.
5. The container for `ez-org-runner-16` starts and immediately connects to GitHub to execute the pending PR job.

---

## 3. Resource Limits & Cgroups Proof

The container successfully enforced hard resource limits as configured:
* **Memory Limit**: `memory.max` set to `6267338752` bytes (~5.84 GB, clamping half of host capacity).
* **PID Limit**: `pids.max` set to `512` PIDs.

From the workflow job log ([run_log.txt](file:///home/jleechan/projects/ez-gh-actions/evidence/pr-trigger-proof-20260704/run_log.txt)):
```
runner: ez-org-runner-16 on 85436641225b
memory.max: 6267338752
pids.max: 512
Verify operating system and CPU context:
Linux 85436641225b 6.8.0-134-generic #134-Ubuntu SMP PREEMPT_DYNAMIC Fri Jun 26 18:43:11 UTC 2026 x86_64 x86_64 x86_64 GNU/Linux
4
Self-hosted runner execution verified successfully!
```
