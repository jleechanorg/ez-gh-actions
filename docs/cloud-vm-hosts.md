# Cloud microVM runner hosts

A cloud microVM (a cmux Cloud machine, or any VM you own where Docker runs
*inside* the VM) is a third host shape next to macOS/Colima and bare-metal Linux.

| Host shape | Docker daemon | Isolation boundary | Config |
|---|---|---|---|
| macOS + Colima | inside the Lima guest (different kernel) | the guest VM | `config/config.toml.mac.example` |
| Bare-metal Linux | on the host kernel | `actions.slice` cgroup | `config/config.toml.linux.example` |
| Cloud microVM | on the VM's own kernel | **the VM itself** | `config/config.toml.cloud-vm.example` |

## Why the daemon needs to be told

`require_host_containment` fails closed on a native-Docker Linux host unless the
runners are pinned under `limits.cgroup_parent = "actions.slice"`, because on bare
metal a runner container that escapes its cgroup is a host-level problem. Inside a
microVM that reasoning does not hold: the VM is the boundary, `actions.slice` does
not exist, and the fixed 10/14/20-runner HostDocker profile does not fit an
8–16 GiB machine.

`policy.host_containment = "vm"` declares the VM boundary. It is not a bypass:

- it is honored **only** when the kernel reports virtualization (`hypervisor` CPUID
  flag in `/proc/cpuinfo`, or `/sys/hypervisor/type`);
- on a host that reports no virtualization, `serve` refuses to start with
  `policy.host_containment = "vm" requires a virtualized host …`;
- the probe proves the machine *is* a VM, not that the VM belongs to the runners. Set
  this only on a VM dedicated to runner work — on shared hardware another tenant's
  container is outside the boundary you are claiming. (A Xen dom0 also exposes
  `/sys/hypervisor/type` while effectively being the host, so the probe alone is not a
  licence to relax anything on bare metal);
- the default (`auto`) keeps the existing `actions.slice` requirement, so nothing
  changes for the established bare-metal fleet;
- a daemon whose Docker runs on a different kernel (Colima/Lima) is unaffected —
  that case was already treated as VM-contained.

When the VM boundary is in effect, host PID-ancestry assertions and host admission
pacing are skipped (guest PIDs are not visible in the host `/proc`), exactly as for
the Colima case.

## Bring-up

```sh
# on the VM, after placing ~/.config/ezgha/app_private_key.pem (mode 600)
# and a GitHub token at ~/.config/ezgha/gh_token
HOST_TAG=a RUNNER_COUNT=4 NAME_PREFIX=ez-cloud-runner-a \
  REF=main ./scripts/cloud/bootstrap-cloud-vm-host.sh
```

Sizing: see [Capacity](#capacity-how-many-runners-fit). `doctor-runner` from the
controlling host is the authoritative health check; container count alone is not proof
of a working fleet.

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
per-container mem = min(limits.memory_mb, fleet_budget_mb / count)   (floor 512 MB)
per-container cpu = min(limits.cpus,     max(NCPU / count, 0.5))
```

`resolve_and_log_memory_budget` downgrades that refusal to a warning when `vm_total_mb`
is unset **and** the `docker info` probe fails, so a host whose Docker is unreachable at
startup is not proof of a valid budget.

Below the ceiling, raising `count` has two effects: more slots, and a **smaller CPU and
memory share for every runner** (the formulas above). Above it, `serve` will not start
at all.

Values measured on four cmux Cloud microVMs (2026-10-28) with `runner_floor_mb = 1400`
and `guest_reserve_mb = 512` — 1400 because it is the per-job figure the 20-runner Linux
fleet runs, and going below the floor reproduces the under-floor clamp OOM class (bead
`ez-gh-actions-yz6b`). "Measured" here means MemTotal and NCPU were read from
`docker info` and the count was derived from the formulas; 26 dispatched jobs then
completed across the resulting slots (a 5-second workflow, so this is not evidence of 26
*simultaneous* long jobs):

| host | mem total | NCPU | count | count ceiling | per-job mem / cpus |
|---|---|---|---|---|---|
| 16 GiB | 16203 MB | 8 | 11 | 11 | 1400 MB / 0.73 |
| 8 GiB | 8011 MB | 4 | 5 | 5 | 1400 MB / 0.8 |

Rules of thumb:
- Keep `guest_reserve_mb` non-zero. It is the memory set aside for dockerd, the guest OS
  and the daemon itself, and a cloud VM still runs all three. At 11 × 1400 of 16203 MB
  only ~800 MB would remain; 512 MB is the smallest reserve that still fits those counts.
  The Linux fleet's 1400 MB runners are safe for a different reason — they run inside a
  pinned 28 GiB `actions.slice` with `memory.high`/`memory.max` caps on a much larger
  host — which a microVM has neither.
- **Disk is the other ceiling.** A running job needs roughly 0.5-1.5 GB of workspace
  churn. Admission pauses when free space is strictly below `limits.min_free_disk_gb`
  (default 10 GB) on the host filesystem or Docker's; only **new** spawns stop, running
  jobs continue, and a critical alert fires. Size the volume for
  `count × ~1.5 GB` above the floor, not for the memory budget alone.
- `dockerd` caches `NCPU` at start. A VM booted at a smaller size keeps reporting that
  smaller count until the daemon restarts, which silently halves per-runner CPU.

## Verification that actually counts

A registered runner is not a working runner. Acceptance for a new host is a real
GitHub Actions job started and completed on one of its slots, read back from the
runner's own container:

```sh
gh workflow run ezgha-selftest.yml -R jleechanorg/ez-gh-actions \
  -f runs_on_json='["self-hosted","cmux-cloud"]'
docker top <slot-container>                # Runner.Worker while the job runs
gh run list -R jleechanorg/ez-gh-actions --limit 5
```
