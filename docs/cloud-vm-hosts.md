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

Sizing: the fleet budget is `vm_total_mb - guest_reserve_mb` (auto-detected total
when `vm_total_mb` is unset) and each runner reserves `runner_floor_mb` (3072 by
default), so 4 runners fit a 16 GiB / 8 vCPU machine and 2 fit an 8 GiB / 4 vCPU
machine. Set `guest_reserve_mb = 0` there: the 4 GiB Lima guest reserve is
meaningless on a host whose Docker *is* the VM's Docker and it made a 4x3072 MiB
fleet fail admission by 181 MiB. `doctor-runner` from the controlling host is the
authoritative health check; container count alone is not proof of a working fleet.

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
