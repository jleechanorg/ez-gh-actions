# Cloud microVM runner hosts

A cloud microVM (a cmux Cloud machine, or any VM you own where Docker runs
*inside* the VM) is a third host shape next to macOS/Colima and bare-metal Linux.

| Host shape | Docker daemon | Isolation boundary | Config |
|---|---|---|---|
| macOS + Colima | inside the Lima guest (different kernel) | the guest VM | `config/config.toml.mac.example` |
| Bare-metal Linux | on the host kernel | `actions.slice` cgroup | `config/config.toml.linux.example` |
| Cloud microVM | on the VM's own kernel | **the VM itself** | `config/config.toml.cloud-vm.example` |

## Why the daemon needs to be told

`require_host_containment` fails closed on a native-Docker Linux host:
`policy.minimum_isolation` must be `container`, runners must be pinned under
`limits.cgroup_parent = "actions.slice"` with an exact `memory_mb`/`pids` for the
10/14/20-runner HostDocker profile, `validate_host_actions_slice` must pass, and the
user manager must be OOM-neutral. Inside a microVM none of that exists — the VM is the
boundary — so `policy.host_containment = "vm"` declares that instead.

It is not a bypass:

- it is honored **only** when the kernel reports virtualization (`hypervisor` CPUID flag
  in `/proc/cpuinfo`, or `/sys/hypervisor/type`);
- on a host that reports no virtualization, `serve` refuses to start with
  `policy.host_containment = "vm" requires a virtualized host …`;
- the probe proves the machine *is* a VM, not that the VM belongs to the runners. Use it
  only on a VM dedicated to runner work — another tenant's workload is outside the
  boundary you are claiming. (A Xen dom0 also exposes `/sys/hypervisor/type` while
  effectively being the host, so the probe alone is not a licence to relax anything on
  bare metal.);
- the default (`auto`) keeps the existing `actions.slice` requirement, so bare-metal and
  Colima hosts are unchanged (a daemon on a different kernel was already treated as
  VM-contained and is checked first).

### What `vm` actually waives — know what you are giving up

Everything the bare-metal branch enforces is skipped, not just the slice name:

- `policy.minimum_isolation = container` (the fail-closed backend assertion);
- `limits.cgroup_parent = "actions.slice"` and the fixed 10/14/20-runner count profile
  with its exact `memory_mb`/`pids` values;
- `validate_host_actions_slice` (the live cgroup cap check);
- `require_user_manager_oom_neutrality` (the OOM-preference check);
- the post-start container PID-ancestry assertion;
- host admission pacing.

The admission memory-pressure gate also degrades: it falls back to system-wide PSI
instead of sampling the runner cgroup, because the runner cgroup does not exist here.
On these VMs the PSI file is missing entirely, so that gate is inactive and the daemon
logs it every tick.

## Bring-up

The bootstrap clones the repository itself, so get the script onto the VM first (any
transport works — for cmux Cloud, `cmux vm push`):

```sh
# on the VM, after placing ~/.config/ezgha/app_private_key.pem (mode 600) and a
# GitHub token at ~/.config/ezgha/gh_token
HOST_TAG=a RUNNER_COUNT=4 NAME_PREFIX=ez-cloud-runner-a \
  REF=main ./scripts/cloud/bootstrap-cloud-vm-host.sh
```

`RUNNER_COUNT` must not exceed the host's ceiling. The script checks that before
restarting the daemon and fails with the arithmetic instead of a restart loop. It also
installs the 45-minute GitHub App token-refresh timer — without it the one-hour
installation token expires, every `gh` call returns `Bad credentials (HTTP 401)`, and the
fleet silently shrinks.

## Capacity: how many runners fit

**The operator picks `runner.count`; the daemon does not compute one.** `serve` refuses
to start when the configured fleet does not fit the memory budget
(`derive_memory_budget`, `src/docker_backend.rs`):

```
refusing to start: memory budget shortfall: … required_mb=… shortfall_mb=…
```

so the largest count it will accept is

```
fleet_budget_mb   = vm_total_mb - guest_reserve_mb      (vm_total_mb auto-detected when unset)
count_ceiling     = floor(fleet_budget_mb / runner_floor_mb)
per-container mem = min(limits.memory_mb, fleet_budget_mb / count)   (floor 512)
per-container cpu = min(limits.cpus, max(NCPU / count, 0.5))
```

`resolve_and_log_memory_budget` downgrades that refusal to a warning when `vm_total_mb`
is unset **and** the `docker info` probe fails, so a successful start is not by itself
proof of a valid budget. `cpu_burst = true` is refused unless `platform::daemon_in_vm()`
verifies a VM, and that detection only compares kernels — a same-kernel microVM does not
qualify, so leave `cpu_burst` off here.

Below the ceiling, raising `count` has two effects: more slots, and a **smaller CPU and
memory share for every runner**. Above it, `serve` will not start at all.

**Defaults vs the example.** Code defaults are `runner_floor_mb = 3072` and
`guest_reserve_mb = 4096`; with those a 16 GiB host caps at
`(16203 - 4096) / 3072 = 3` runners. `config/config.toml.cloud-vm.example` instead
ships `runner_floor_mb = 1400`, `guest_reserve_mb = 512`, `limits.memory_mb = 1400` and
`limits.cpus = 1.6`, and keeps `count = 4` as a deliberately conservative starting
point. The table below is the arithmetic for **that** example on the hosts measured on
2026-10-28 (totals in MiB, as `docker info` reports them):

| host | MemTotal | NCPU | count | ceiling | per-job mem / cpus |
|---|---|---|---|---|---|
| 16 GiB (2 hosts) | 16203 MiB | 8 | 11 | 11 | 1400 MiB / 0.73 |
| 8 GiB (2 hosts) | 8011 MiB | 4 | 5 | 5 | 1400 MiB / 0.8 |

1400 is the per-job figure the 20-runner Linux fleet runs; going below the floor
reproduces the under-floor clamp OOM class (bead `ez-gh-actions-yz6b`). "Measured" means
MemTotal and NCPU came from `docker info` and the counts follow the formulas; 26
dispatched jobs then completed across the resulting 26 slots. The selftest workflow runs
for seconds, so that is **not** evidence of 26 simultaneous long jobs.

### Guest reserve

`guest_reserve_mb` is memory set aside for dockerd, the guest OS and the daemon itself —
a cloud VM still runs all three, so zero is the wrong value even though the 4 GiB Lima
reserve is too big here. 512 MiB is a **chosen** value, not a minimum: any reserve up to
`total - count × floor` still admits the same counts (up to ~800 MiB on the 16 GiB host
and ~1000 MiB on the 8 GiB host for 11 and 5). The Linux fleet's 1400 MiB runners are
safe for a different reason — they sit inside a pinned 28 GiB `actions.slice` with
`memory.high`/`memory.max` caps on a much larger host — which a microVM has neither.

### Disk is the other ceiling

A running job needs roughly 0.5-1.5 GB of workspace churn. Admission pauses when free
space is **strictly below** `limits.min_free_disk_gb` (default 10 GB, whole GB) on the
host filesystem or on Docker's filesystem, or when the measurement itself fails
(`host_disk_measurement_unavailable`). Only **new** spawns stop — running jobs continue —
and a `Critical` alert fires. Size the volume for `count × ~1.5 GB` above the floor plus
the runner image (~4 GB), not for the memory budget alone.

Recovering from a pause: **do not prune Docker images** — that deletes
`ezgha-runner:latest` and the daemon cannot spawn until it is rebuilt. Free space with
builder-cache and stopped-container/log cleanup, or grow the volume
(`cmux vm resize <id> --disk <N>G`; disk is per-machine and is not part of the vCPU or
memory pool).

### `dockerd` caches NCPU

`docker info --format '{{.NCPU}}'` is fixed at daemon start. A VM created small and
resized later keeps reporting the old value — observed as `NCPU=2` on 8-vCPU hosts, which
silently cut every runner to `2/count` CPUs. Compare against `nproc`; on a mismatch,
restarting `docker` re-reads the real count, but that is a deploy-owner action that
restarts every runner on the host (and their jobs).

### Labels

The example carries `self-hosted`, `self-hosted-mikey`, `ezgha`, `Linux`, `X64` and
`cmux-cloud`. Because of the first four, cloud runners **join the general pool** and
receive any workflow that targets them, not just `cmux-cloud` ones. If you need to
target one specific host, add a host-specific label (for example
`cmux-cloud-gleeful`) rather than relying on `cmux-cloud`, which every cloud VM shares.

## Verification that actually counts

A registered runner is not a working runner, and `cmux-cloud` is shared by every cloud
VM, so a job is not proof about *this* host until its placement is confirmed. The
selftest also finishes in seconds, which makes `docker top` a race.

```sh
gh workflow run selftest.yml -R jleechanorg/ez-gh-actions \
  -f runs_on_json='["self-hosted","cmux-cloud"]'
# then confirm WHICH host took it (must match this host's NAME_PREFIX):
gh run view <run-id> -R jleechanorg/ez-gh-actions --log | grep 'Runner name:'
```

For a per-host health read, run the container check on the VM itself:

```sh
docker ps --filter label=ezgha=managed --format '{{.Names}}'
docker top <slot-container>            # Runner.Worker present while a job runs
```

`doctor-runner` does **not** cover this host shape: it probes the local host plus one
remote (`REMOTE_LINUX_HOST`, default jeff-ubuntu, from a macOS controller;
`EXPLICIT_WORK_HOST`, default macbook, from a Linux controller), and a cloud VM is
neither.
