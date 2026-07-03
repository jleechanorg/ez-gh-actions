# ez-gh-actions E2E Evidence — real ephemeral runner, real GitHub Actions job

- Repo: https://github.com/jleechanorg/ez-gh-actions
- Commit under test: 5ef5406779925598565c8d277d13b865db78947a (fix c27d389 applied mid-run after E2E caught the daemon-capacity bug)
- Actions run (REAL, on our runner): https://github.com/jleechanorg/ez-gh-actions/actions/runs/28685531107
- Host: Jeff-Ubuntu (linux x86_64, 32 cpus/64GB), docker daemon = 4-cpu/12GB Lima VM

## Proof chain
1. `01_init.txt` — ezgha init: daemon-aware limits (5977 MB / 2 cpus / 512 pids)
2. `02_doctor.txt` — capability detection (docker ok, kvm ok, virsh/tart/sysbox missing, gh auth ok)
3. `03_start.txt` — started ephemeral runner ezgha-Jeff-Ubuntu-6a4833a11c652b
4. `04_status_before_job.txt` — container 1143cf62e74f running; GitHub runner #3 status=online
5. `06_run_watch.txt` — workflow_dispatch run 28685531107 completed success
6. `07_job_log.txt` — job output: runner name = ezgha-Jeff-Ubuntu-6a4833a11c652b; job hostname = 1143cf62e74f (== our container ID); memory.max = 6267338752 (= 5977 MB exactly); pids.max = 512
7. `08_status_after_job.txt` — 0 containers, 0 registered runners (ephemeral: JIT deregistered + --rm cleanup)

## Bug found and fixed by this E2E
`docker run --cpus 16` failed: daemon (Lima VM) has 4 cpus while host has 32.
Fix c27d389: limits derived from `docker info` NCPU/MemTotal + clamped at start.
Failure-path cleanup verified: the orphaned JIT registration was auto-removed.
