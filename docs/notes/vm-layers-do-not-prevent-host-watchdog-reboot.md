# VM/container layers do not prevent host crashes on Jeff-Ubuntu

Date: 2026-08-25. Question: given host → Lima/QEMU → Docker-in-VM → 10 runner
containers, should those layers stop the host from crashing?

**No.** Namespaces and a guest kernel isolate *identity and syscalls*, not
host RAM, host load-average, or the host scheduler. The Colima VM is a
~32–36 GiB QEMU process on the host; runner work shows up there. The 17:34
PDT event was userspace `watchdog(8)` rebooting after repair failed. The
22:46 PDT event was a host kernel panic in idle-balance (`swapper/1`),
which no container, VM, or repair script can contain. kdump is still
unarmed (`kexec_crash_loaded=0`), so that panic left the box hung ~57
minutes until the 23:43 boot.

## Live stack (this host, after the 23:43 boot)

| Layer | What it actually is | Host-visible cost |
| --- | --- | --- |
| Jeff-Ubuntu | kernel 6.17.0-29-generic, 62 GiB RAM, 32 threads | watchdog(8) + PSI watcher run here |
| `lima-colima` | QEMU/KVM, 24 vCPU, 36 GiB, 120 GiB disk | cgroup current ~32 GiB, `MemoryHigh=34G`, `MemoryMax=38G` on `lima-vm@colima.service` |
| Docker in the VM | socket `unix:///home/jleechan/.lima/colima/sock/docker.sock` (context `lima-colima`) | not the host's `/var/run/docker.sock` (0 managed containers there) |
| Runners | `ez-runner-c-*` labeled `ezgha=managed` | guest `actions.slice` `MemoryMax=32G` (inside the VM only) |

Sources: `limactl list`; `docker context ls`;
`/proc/<qemu>/cgroup` + `memory.{high,max,current}`;
`systemd/app-lima-vm.slice`; `systemd/guest/actions.slice`;
`systemd/lima-vm@colima.service.d/99-memory-ceiling.conf`.

Two extra sockets exist and are why repair can look at the wrong daemon:

- Live: `~/.lima/colima/sock/docker.sock` (current context).
- Stale Colima path: `~/.config/colima/default/docker.sock` (context `colima`, not current).
- Hardcoded *wrong* path in the pre-[511c4b6](https://github.com/jleechanorg/ez-gh-actions/commit/511c4b62b093100f28047c766f2f0ea59a68152a) repair script: `~/.colima/default/docker.sock` (does not exist on this box).

## Why a VM does not fence the host

1. **QEMU is a host process.** Guest allocations are host pages owned by
   `qemu-system-x86`. systemd `MemoryMax=` is a cgroup limit on that
   process, not a hypervisor force-field. `man systemd.resource-control`:
   `MemoryMax` is the last line of defense; exceeding it invokes the
   *unit* OOM killer, which can kill QEMU (taking the whole fleet) but
   does not stop host kernel bugs or host load-average from other tasks.
2. **Docker cgroups live in the guest.** `actions.slice` `MemoryMax=32G`
   (`systemd/guest/actions.slice`) caps runners *inside* the 36 GiB VM.
   Host `watchdog(8)` never sees those cgroups. It sees load-average of
   the host, including QEMU's 24 vCPU threads.
3. **Overcommit math.** Host 62 GiB. QEMU allowed up to 38 GiB. Remaining
   ~24 GiB must cover the kernel, Chrome, Codex/Claude, file cache, and
   16 GiB swap. A runner burst that fills the VM still pushes host PSI
   and load. That is the 17:34 path (repair log: `psi_avg10=96.88` with
   `MemAvailable` ~14 GiB).
4. **Colima-on-Linux is extra surface, not extra safety.** Native Linux
   Docker would be one daemon, one socket. Lima adds a 36 GiB VM *and* a
   second Docker context. Repair targeting the wrong socket is that
   design showing up as a bug, not a freak accident.

## What `watchdog(8)` actually does

Local `man watchdog` / `man watchdog.conf` (watchdog 5.16 on this box):

- It is a **userspace daemon**. It can pet `/dev/watchdog` and/or run
  tests (load, memory, ping, `repair-binary`).
- `max-load-1` / `max-load-5` / `max-load-15`: if load-average exceeds
  the configured value, the daemon treats that as failure.
- `repair-binary`: run instead of shutting down; if it does not clear the
  fault, the daemon still shuts the system down.
- Live `/etc/watchdog.conf`: `max-load-1=96`, `max-load-5=72`,
  `max-load-15=48`, `repair-binary=/home/jleechan/.local/bin/watchdog-load-repair.sh`,
  `repair-timeout=120`. `watchdog-device` is commented out. Journal:
  `alive=[none] heartbeat=[none]` — **no hardware keepalive**.
- A watchdog reboot is an orderly userspace-initiated shutdown, not a
  kernel panic. It leaves no pstore. Grep the dead boot for
  `shutting down the system because of error 253` (see
  `~/.claude/projects/-home-jleechan-projects-other-user-scope/memory/project_2026-07-07_watchdog_self_shutdowns.md`).

Repo policy copy: `config/watchdog.conf`. Script contract:
`scripts/host/watchdog-load-repair.sh` header — shedder only; always
exit 0. `repair-maximum = 0` so watchdog cannot reboot after a
successful shed that has not yet dropped loadavg.

## Two failure classes on 2026-08-25 (do not collapse them)

### A. 17:34 PDT — watchdog reboot (repair bugs)

Evidence: `/var/log/ezgha-watchdog-repair.jsonl` at `2026-08-26T00:34:40Z`
(`psi_avg10=96.88`), then `no managed containers (idempotent)`, then
`limactl failed`, then `reboot-eligible`. PSI watcher log still has the
old line `CRIT threshold sustained but cooldown active (273s/600s)`.

Mechanism in [511c4b6](https://github.com/jleechanorg/ez-gh-actions/commit/511c4b62b093100f28047c766f2f0ea59a68152a):

1. `scripts/host/psi-oom-watcher.sh` — staged runner/QEMU shed used to
   stamp `COOLDOWN_MARKER` (600s) shared with arbitrary-process SIGTERM.
   First shed of c-9/c-10 armed the cooldown; rebound PSI did nothing.
   Current code runs `run_shed_stages` **before** the cooldown check and
   does not stamp the marker on shed success (`scripts/host/psi-oom-watcher.sh`
   around the `ACTION(staged-shed)` / `COOLDOWN_MARKER` block).
2. `scripts/host/watchdog-load-repair.sh` — `DOCKER_HOST` was
   `unix://${HOME}/.colima/default/docker.sock`. Live context is
   `lima-colima`. `docker ps` against a missing/wrong socket returned
   empty; old code treated that as idempotent zero. Current code
   `resolve_docker_host()` inspects the user context, prefers the lima
   socket if it exists, and fails the query explicitly.
3. `limactl stop --timeout=…` is **not a real flag**. Live
   `limactl help stop` (Lima 1.2.0): `--force`, `--help`, global `--tty`.
   Current script wraps `limactl --tty=false stop colima` in
   `timeout --signal TERM --kill-after=2s`.

Bead: `ez-gh-actions-e0z0.5`.

### B. 22:46 PDT — kernel panic (then 23:43 boot)

pstore `/var/lib/systemd/pstore/1787723187` and `1787723188`
(wall 2026-08-25 22:46:27 PDT):

```
kernel tried to execute NX-protected page
Oops: 0011 [#1] SMP NOPTI
CPU: 1 PID: 0 Comm: swapper/1 Tainted: P OE  6.17.0-29-generic
RIP: 0010:0xffff8c6086c34a00
  __update_blocked_fair
  sched_balance_update_blocked_averages
  _nohz_idle_balance.isra.0
  sched_balance_softirq
Kernel panic - not syncing: Fatal exception in interrupt
```

Same signature as pstore `1787656577` (04:16 PDT the same day) and the
Jun–Jul series documented in
`project_2026-07-07_watchdog_self_shutdowns.md`. Journal on that boot
stops uncleanly at 22:45:56 (`ezgha` settling 7/10). Next boot 23:43:51
— ~57 min hung because kdump is unarmed and userspace watchdog cannot
run during a panic.

Bead: `ez-gh-actions-e0z0.4`.

## What *would* isolate the host

| Control | What it does | Status here |
| --- | --- | --- |
| `MemoryHigh`/`MemoryMax` on `lima-vm@colima.service` | throttle then OOM-kill QEMU | deployed: 34G / 38G; live current ~32 GiB |
| Guest `actions.slice` | cap runners inside the VM | 28G high / 32G max |
| PSI staged shed | stop runners *before* watchdog | code fixed in 511c4b6; 17:34 used the old cooldown |
| Repair script on the **lima** socket | actually `docker rm` the fleet | `~/.local/bin` matches 511c4b6; `~/.local/libexec/ezgha/watchdog-load-repair.sh` is still the old hardcoded socket |
| Native Docker on Linux (no Lima) | remove 36 GiB QEMU + dual sockets | not done; portability choice |
| kdump/`crashkernel` | capture panics, reboot instead of 57 min hang | `kexec_crash_loaded=0` |
| Kernel not 6.17 CFS/nohz NX bug | stop class B | open; hardware is i9-13900K + nvidia proprietary (`Tainted: P`) |

Program intent is already explicit in bead `ez-gh-actions-e0z0`: security
isolation exists; host-first accounting is the missing layer. The layers
were never a crash fence.

## Deploy check for 511c4b6 (2026-08-25 ~23:54)

- `origin/main` == `511c4b62b093100f28047c766f2f0ea59a68152a`.
- `/home/jleechan/.local/bin/watchdog-load-repair.sh` sha256 matches
  `scripts/host/watchdog-load-repair.sh` (this is the path in
  `/etc/watchdog.conf`).
- `/home/jleechan/.local/libexec/ezgha/watchdog-load-repair.sh` does
  **not** match (still hardcoded `~/.colima/default/docker.sock`).
- `/home/jleechan/.local/libexec/ezgha/psi-oom-watcher.sh` matches the
  repo (this is `ExecStart=` of `psi-oom-watcher.service`).
- Host after 23:43 boot: load ~5.6, `MemAvailable` ~30 GiB, memory PSI
  0.00, 8/10 runners coming up.

## Tests vs live assumptions

- `tests/host_ops_0725_test.sh` **is** in `.github/workflows/ci.yml` and
  now asserts shed-before-cooldown and that success does not stamp
  `COOLDOWN_MARKER`.
- `tests/host_control_artifacts_test.sh` asserts context-derived
  `DOCKER_HOST`, `--tty=false stop colima`, and no `--timeout`. It is
  **not referenced** from `ci.yml` (bead `ez-gh-actions-iqcg`). Stubs
  still cannot see a live Colima socket; that is the same class of gap
  `.github/workflows/mac-virtiofs-canary.yml` documents for virtiofs.

## Primary sources

- `man watchdog`, `man watchdog.conf` on this host (watchdog 5.16).
- `man systemd.resource-control` (`MemoryHigh=`, `MemoryMax=`).
- `limactl help stop` (no `--timeout`).
- `/proc/pressure/memory` (PSI).
- pstore dumps cited above.
- Repo scripts and units cited above.
- Commit [511c4b6](https://github.com/jleechanorg/ez-gh-actions/commit/511c4b62b093100f28047c766f2f0ea59a68152a).
