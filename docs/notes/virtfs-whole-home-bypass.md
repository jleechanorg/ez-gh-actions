# Bounding Lima 9p whole-home virtfs (jeff-ubuntu)

Date: 2026-08-26. Bead: `ez-gh-actions-ji5h`. Goal criterion:
[`ez-gh-actions-fkbm`](https://github.com/jleechanorg/ez-gh-actions/issues/126)
criterion 4 in `roadmap/host-uncrashable-goal-ironclad-2026-08-26.md`.

This note is **Linux QEMU 9p resource accounting**, not the Mac virtiofs
tar-symlink bug (`workspace_host_path` / bead `jleechan-93cf` /
`docs/design/mac-runner-virtiofs-saga-root-cause-2026-07.md`). Those tracks
are data-correctness on a narrow workspace mount. This track is: guest I/O
against a **whole `$HOME` 9p export** can drive **host** page cache and PSI
around the per-container 2.5G caps and around the intended isolation of
`lima-vm@colima.service` MemoryMax/CPUQuota.

**Do not lima/colima restart in this session.** Do not edit live Lima YAML.
Do not host-reboot to “prove” this. A/B below is observe-only on the running
VM; applying a bound is a later deploy-owner step.

Hypothesis, not cause: 9p whole-home is a plausible untracked pressure
vector. Do not promote it to root cause of a past watchdog reboot until the
A/B in this note has numbers.

## Current live command line

Captured 2026-08-26 via `pgrep -af qemu-system-x86` (pid 18592). The VM name
is `lima-colima`. Relevant fragment:

```
-m 36864 -smp 24 ...
-drive file=/home/jleechan/.lima/colima/diffdisk,if=virtio,discard=on ...
-virtfs local,mount_tag=mount0,path=/home/jleechan,security_model=none ...
-name lima-colima
```

That is QEMU 9p (`-virtfs local`), mount tag `mount0`, **path = host
`$HOME`**, `security_model=none`. Disk I/O for Docker’s data-root is the
separate `diffdisk` drive, not this virtfs.

Same-moment cgroup on `lima-vm@colima.service` (not a claim about 9p
attribution — snapshot only):

| knob | live value |
| --- | --- |
| `memory.current` | ~35.6 GiB |
| `memory.max` | 40802189312 (~38 GiB) |
| `cpu.max` | `1600000 100000` (16 CPUs) |
| `memory.stat` anon | ~23.2 GiB |
| `memory.stat` file / inactive_file | ~11.99 GiB / ~11.99 GiB |

The ~12 GiB `file` bucket is **mixed**: QEMU’s own host file cache
(OVMF, `diffdisk`) plus any 9p pages charged to this cgroup. A/B must
split those. `file ≈ 12 GiB` is **not** proof that 9p is contained.

## Config source (what emits `-virtfs … path=/home/jleechan`)

**Live instance that matches the QEMU `diffdisk` path:**

`~/.lima/colima/lima.yaml` **lines 9–12**:

```yaml
mounts:
- location: "~"
  writable: true
mountType: "9p"
```

Lima expands `location: "~"` to `/home/jleechan` on this box, which is
exactly the live `-virtfs … path=/home/jleechan` argument.

This has been whole-home 9p since at least the 2026-07-07 backup
(`~/.lima/colima/lima.yaml.bak-20260707` lines 9–12: same `~` + `9p`).
Not a new regression.

**Not owned by this repo today.** Grep of `install.sh` and repo lima
templates: no `mounts:` / `mountType:` / `lima.yaml` writer. `install.sh`
deploys `lima-vm@colima.service.d/99-memory-ceiling.conf` and guest
`actions.slice`; it does not provision virtfs.

**Why `~` exists at all:** Colima’s default, not an ezgha requirement.
`~/.config/colima/default/colima.yaml` lines 247–260:

```yaml
# Configure volume mounts for the virtual machine.
# Colima mounts user's home directory by default to provide a familiar
# user experience.
# ...
# Colima default behaviour: $HOME is mounted as writable.
# Default: []
mounts: []
```

Empty `mounts: []` still mounts `$HOME`. The unused canonical Colima
instance (`~/.config/colima/_lima/colima/lima.yaml` lines 13–16) also has
`location: "~"` but `mountType: reverse-sshfs` and is **not** the live
fleet VM (4 CPU / 12 GiB vs live 24 CPU / 36 GiB at `~/.lima/colima`).

## Why this bypasses Borg / layered caps

Stack (see also `docs/notes/vm-layers-do-not-prevent-host-watchdog-reboot.md`):

1. **Per-container 2.5G / 2 CPU** — live `~/.config/ezgha/config.toml`
   `[limits] memory_mb = 2500`, `cpus = 2.0`; `docker inspect` on
   `ez-runner-c-7`: `Memory=2621440000`, `NanoCpus=2000000000`,
   `CgroupParent=actions.slice`. Those cgroups exist **inside the guest**.
   Host 9p page cache is not a guest container page.
2. **Guest `actions.slice`** — caps runners inside the 36 GiB VM. Host
   watchdog and host PSI never see that slice.
3. **`lima-vm@colima.service` MemoryMax=38G / CPUQuota=1600%** —
   `systemd/lima-vm@colima.service.d/99-memory-ceiling.conf` and
   `systemd/app-lima-vm.slice`. These limit the **QEMU process** (guest
   RAM as anon, QEMU overhead). They do **not** automatically include
   every host page touched because the guest walked `$HOME` over 9p:
   - Guest container write to overlay → guest RAM / VM disk (`diffdisk`)
     → charged to QEMU (anon + disk file cache). This path **is** inside
     MemoryMax.
   - Guest read/write of a 9p file under `/home/jleechan` → QEMU 9p
     server opens **host** inodes. Those pages sit in the **host** page
     cache. They are charged to lima-vm **only if** this cgroup is the
     one that instantiated them. Shared cache with host user processes
     (editors, git, browsers using the same `$HOME`) can land in other
     cgroups or in global cache, while still moving host `MemAvailable`
     and `/proc/pressure/memory`. That is the bypass of “the VM isolates
     host RAM.”
4. **`security_model=none`** — no 9p mapped-uid fence; guest I/O is
   raw host filesystem I/O as the QEMU uid.

fkbm criterion 4 PASS is binary: virtfs path is **not** `$HOME`, **or**
measurement shows 9p/page-cache **is** charged inside the lima-vm cgroup.
Live path is `$HOME` → criterion 4 is FAIL until one of those holds.

### Arm B snapshot 2026-08-26 00:48 PDT (512MiB, 5 runners up)

`NINEP_PROBE_MIB=512 bash scripts/host/probe-9p-cgroup-charge.sh`:

- lima `file` Δ = 537 MiB, lima `anon` Δ ≈ 48 KiB, host `Cached` Δ = 558 MiB, probe = 512 MiB, 0.6s.
- Script verdict: 9p read charged inside lima-vm (file Δ ≥ 50% of probe). Host Cached moved by the same amount (same bucket, not unbounded host-only cache).
- **Not** a criterion 4 PASS: one sequential `dd` is not a multi-runner burst, and virtfs path is still `$HOME`. Narrowing the mount still wants a deploy-owner Lima restart.

## Minimum guest paths actually needed (cited, not guessed)

Docker-in-VM bind-mounts are guest paths. The ezgha daemon runs on the
**physical host** and talks to Docker through a **forwarded socket**.

| Need | Required on 9p? | Evidence |
| --- | --- | --- |
| Docker socket | **No** | `~/.lima/colima/lima.yaml` lines 28–30: `portForwards` maps guest `/var/run/docker.sock` → host `{{.Home}}/.lima/colima/sock/docker.sock`. Live context `lima-colima` = `unix:///home/jleechan/.lima/colima/sock/docker.sock`. QEMU `diffdisk` / qmp / serial sockets are host files opened by QEMU, not virtfs. `README.md` ~207–208: runners do **not** get docker.sock mounted. |
| Runner job workspace / overlay | **No, today** | Live `docker inspect ez-runner-c-7`: `Binds=null`, `Mounts=[]`. Live `~/.config/ezgha/config.toml` has **no** `workspace_host_path` / `wheelhouse_host_path` / `pip_cache_host_path`. `config/config.toml.linux.example` likewise omits them. `docker info` `RootDir=/var/lib/docker` inside the guest (VM disk). Job git/checkout/build is overlay on that disk. |
| Optional disk-churn bind mounts | **Only a narrow cache dir, and only if Linux opts in** | `src/docker_backend.rs` (~2592–2676) bind-mounts those three paths when set. `src/config.rs` (~297–343) and `config/config.toml.mac.example` (~21–48) require the path to sit under Colima’s mount allowlist (Mac: e.g. `~/.cache/ezgha-workspace`). Linux has not opted in. If it does, the 9p/virtiofs allowlist needed is that cache subtree, not `$HOME`. |
| Host git / `~/.config/ezgha` / cargo | **No** | Daemon is Layer 4 on the host (`src/config.rs` XDG paths; `install.sh` installs the host binary). Guest does not need host git to run JIT runners. |
| Lima/QEMU itself | **No virtfs** | Firmware, `diffdisk`, cidata ISO, serial/qmp sockets are `-drive` / `-chardev` host paths under `~/.lima/colima/` (live cmdline). |

**Whole-home is not required for the current 10-runner Linux fleet.** It is
Colima’s “familiar UX” default. A documented decision that whole-home must
stay would need a new, cited consumer (a bind-mount, a guest tool that
must see host `$HOME`). None is in the live Linux config or runner
inspect.

## Proposed bound

Three options; pick after A/B, do not apply in this session.

1. **Narrow the virtfs path (preferred if A/B shows 9p host-cache growth).**
   Change Lima `mounts` from `location: "~"` to either **no extra mounts**
   (fleet already runs with `Mounts=[]` and a port-forwarded docker.sock)
   or, if Linux later enables disk-churn mounts, **only**
   `~/.cache/ezgha-workspace` and `~/.cache/ezgha-wheelhouse` (Mac pattern).
   fkbm criterion 4 then PASSes because virtfs path is not `$HOME`.
2. **Keep a mount but change protocol/cache policy.** Replace 9p with
   virtiofs (or keep 9p) with an **explicit** cache mode (`cache=none` /
   documented `mmap`/`loose` tradeoff) so host page cache from this
   channel is bounded or attributable. Whole-home + `cache=none` still
   walks the entire tree; narrowing remains the real blast-radius cut.
3. **Charge-to-cgroup / ceiling headroom (if A/B shows 9p pages are
   outside lima-vm `memory.stat file`).** Treat that as an accounting gap:
   either arrange that 9p file cache is charged to `lima-vm@colima.service`
   (so MemoryMax actually contains it) **or** lower VM `MemoryMax` to leave
   measured host headroom for uncharged 9p cache (related:
   `ez-gh-actions-ah94`). Do not claim “VM isolates host RAM” while
   `path=/home/jleechan` and `file` in the cgroup does not move with 9p I/O.

Repo-owned provisioning (later): a tracked Lima/Colima template or
`install.sh` snippet so a wiped machine does not silently restore
`location: "~"`. Live YAML edit without a git-tracked source is not done
(reproducibility discipline).

## A/B measurement plan (no host reboot)

**This session: do not `limactl`/`colima` stop/start/delete, do not edit
`lima.yaml`, do not drop caches via sudo, do not restart ezgha.**

Goal: numbers that either (a) attribute host cache/PSI growth to 9p
`mount0`, or (b) show 9p I/O is already inside lima-vm `memory.stat file`
1:1. Without that, do not call 9p a cause.

### Shared probes (read-only)

- QEMU pid / virtfs: `pgrep -af qemu-system-x86` must still show
  `path=/home/jleechan`.
- Cgroup: `/sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/app.slice/app-lima\x2dvm.slice/lima-vm@colima.service/memory.stat`
  (`anon`, `file`, `inactive_file`) and `memory.current`.
- Host: `/proc/meminfo` (`MemAvailable`, `Cached`, `Dirty`),
  `/proc/pressure/memory`.
- QEMU I/O: `/proc/<qemu-pid>/io` (`read_bytes`, `write_bytes`).
- Fleet: `docker ps --filter label=ezgha=managed` count = 10; per-slot
  `docker top` / `./doctor-runner`. **Do not empty the fleet to make
  graphs look clean** (fkbm criterion 6).

### Arm A — overlay-only (current production path)

Keep the 10 runners as they are (`Mounts=[]`). During a normal CI burst
(jobs that only touch container overlay + `/var/lib/docker` on
`diffdisk`):

- Record Δ `anon` vs Δ `file` in lima-vm vs Δ host `Cached` / PSI.
- Expectation if 9p is idle: host `Cached` and lima-vm `file` move
  together with **disk-image** cache (`diffdisk`), not with `$HOME`
  walk size.

### Arm B — 9p traffic without changing the mount

Still no VM restart. From the **guest**, read a large file that lives
only on host `$HOME` and is not the VM disk (example class:
`~/projects/...` tarball or a fresh `dd` file created on the **host**
under `$HOME`, then read from guest via the 9p home mount). Size should
be large enough to see (several GiB) but not so large it trips host
watchdog (`max-load-1` / PSI). One sequential read, one pass.

Interpret:

| Observation | Meaning |
| --- | --- |
| lima-vm `file` rises ≈ bytes read, host `Cached` rise is the same bucket | 9p cache **is** charged to lima-vm → criterion 4 can PASS on the “charged inside cgroup” arm **if** this holds under multi-runner load, not one dd |
| host `Cached` / PSI rise, lima-vm `file` does not (or rises much less) | bypass confirmed → bound via **narrow path** (option 1) or cache policy + headroom (options 2–3) |
| lima-vm `anon` rises, `file` flat | guest buffered the read in VM RAM (contained); not the 9p host-cache bug |

Repeat Arm B with **writes** to a throwaway file under the 9p home (guest
create/delete a file under `$HOME` that is not a runner workspace). Dirty
host pages vs lima-vm `file` is the write-side bypass check.

Do **not** use `echo 3 > /proc/sys/vm/drop_caches` (sudo; also a
self-outage risk). Use a **new** filename so the first read is a miss.

### What this plan does not do

- Does not restart Lima to flip `location:` (that is apply-the-bound,
  deploy-owner, after A/B).
- Does not host-reboot.
- Does not treat Mac virtiofs canary / tar wrapper as coverage.
- Does not trust GitHub API runner counts.

## Blast radius (10 Linux runners must remain)

- **Capacity contract:** 10 × `ez-runner-c-*` on jeff-ubuntu. A bound that
  “fixes” pressure by dropping count is a criterion 6 fail.
- **Narrowing mounts today:** live runners have **no** host bind-mounts, so
  removing whole-home 9p should not phantom-empty a workspace (the Mac
  allowlist footgun in `src/config.rs`). Residual risk: some **other**
  guest process (not ezgha) that assumed `/home/jleechan` is host `$HOME`.
  Probe guest `mount | grep 9p` and `docker ps -a` binds **before** apply.
- **If Linux later sets `workspace_host_path`:** that path **must** remain
  inside the narrowed allowlist, or Docker-in-VM will mount an empty
  phantom dir (Mac incident 2026-07-17/18). Put that in the template
  comment when landing the YAML.
- **Applying the bound requires a VM restart** (Lima reads `lima.yaml` at
  start). That is a full fleet interrupt. Drain jobs, keep the unit
  enabled, restart **once** under the single-writer deploy-owner, then
  `./doctor-runner` until 10/10 EXECUTING or IDLE-OK. Load-aware: do not
  stack this on a high load-1 or a draining serve loop (CLAUDE.md Gate 0
  restart rules). **Not this session.**
- **CPUQuota/MemoryMax stay.** Narrowing virtfs is not a license to raise
  QEMU `-m` or drop the 10-runner floor.
- **Wrong VM:** `~/.config/colima/_lima/colima` is the 4 CPU instance.
  Do not “fix” that YAML and think the live 24 vCPU fleet changed.

## Explicit session freeze

**Do not lima restart in this session.** Do not `limactl start|stop|delete`,
`colima start|stop|delete`, live `lima.yaml` edits, `cargo install`,
`systemctl --user restart ezgha.service`, or `./docs/verify-exit-criteria.sh`
as part of this note. Next apply is deploy-owner after Arm A/B numbers
are attached to `ez-gh-actions-ji5h`.
