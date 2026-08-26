# GOAL: Borg-style host survival (Jeff-Ubuntu)

Literal ask: utilize VM/container layers so runner load, PSI repair, and watchdog
handling do not crash, restart, or reboot the host. This is an operational survival
target, not a literal claim that hardware, kernel faults, or every VM escape is
impossible.

Stronger intent: the **smallest layer** fails and recovers (job → container → VM). The physical host does not reboot for runner load/PSI. Ten Linux runners remain the capacity contract. Kernel panics dump a vmcore instead of hanging.

### Failure-ladder authority

| Scope | Owner | Permitted automatic action |
|---|---|---|
| Job/container | Runner limits and ephemeral lifecycle | Fail the job/container. |
| Repeated local start failure | `ezgha` persistent slot circuit | Temporarily open that slot only. |
| Several open slot circuits | `ezgha` fleet admission circuit | Pause new starts while existing work drains. |
| Sustained host pressure | Root-owned watchdog repair | Shed managed containers, then request bounded Colima stop. |
| Physical host | Watchdog config/operator controls | No reboot vote from runner pressure repair. |

The Rust daemon may quarantine a slot, pause admission, or make its existing bounded
backend-start request after a genuine Docker reachability failure. Admission guards and
local runner-start failures must not enter that path. It has no VM-stop, host, panic,
reboot, shutdown, or watchdog-repair authority. The production capacity contract is
10 Linux + 6 Mac; the current temporary Linux count of 5 remains a failure.

Default verdict: **FAIL** until every criterion below is proven on the live host at the same time.

| # | Criterion | Check command | External anchor | Independent verifier |
|---|---|---|---|---|
| 1 | Watchdog repair cannot vote reboot, **on the live daemon config**, not only git | Repo: `bash scripts/host/assert-no-host-reboot-vote.sh`. Live host: `ASSERT_LIVE_WATCHDOG=1 bash scripts/host/assert-no-host-reboot-vote.sh` (must include `/etc/watchdog.conf`); `grep -E '^[ ]*repair-maximum' /etc/watchdog.conf` shows `= 0`; `journalctl -u watchdog` after a load event has **no** `Received SIGTERM from PID .* (watchdog)` | Live `/etc/watchdog.conf`, live `~/.local/bin/watchdog-load-repair.sh`, watchdog journal | Different agent greps live files; tests-only PASS is FAIL |
| 2 | A runner burst kills jobs/containers (or the VM), **not** the host | After burst: `last -x \| head -5` is not a new `shutdown` from watchdog; `./doctor-runner` still has 10 slots EXECUTING or IDLE-OK (not a 0-runner “fix”) | `last`, `doctor-runner`, watchdog journal vs pstore | Second agent classifies the stop: watchdog vs panic vs power |
| 3 | QEMU has a **CPU** (and memory) ceiling so host load-1 cannot be 139 from guest threads with `cpu.max=max` | `QPID=$(pgrep -n -x qemu-system-x86); CG=$(awk -F: '$1==0{print $3}' /proc/$QPID/cgroup); cat /sys/fs/cgroup${CG}/cpu.max /sys/fs/cgroup${CG}/memory.max` — `cpu.max` finite, `memory.max` finite and ≤ 38G | Live cgroup files on `lima-vm@colima.service` | MemoryMax-only while `cpu.max` missing = FAIL (current live gap) |
| 4 | Guest I/O cannot bypass caps via whole-home 9p | Either QEMU virtfs path is not `$HOME`, or 9p/page-cache is charged inside the lima-vm cgroup; A/B in [ez-gh-actions-ji5h](https://github.com/jleechanorg/ez-gh-actions) | `pgrep -af qemu` virtfs line; cgroup `memory.stat` | Claiming “VM isolates host RAM” while virtfs is `/home/jleechan` = FAIL |
| 5 | Kernel panic path recovers: **one** `crashkernel=` , `kexec_crash_loaded=1`, vmcore proof | `tr ' ' '\\n' </proc/cmdline \| grep crashkernel` has exactly one line; `cat /sys/kernel/kexec_crash_loaded` is `1`; bd-bth controlled dump exists | `/proc/cmdline`, kexec, vmcore | **Never** run the old `8rx2` sed that adds a third param; duplicate `512M` + `512M,high` = FAIL (live today) |
| 6 | Capacity is not “saved” by emptying the fleet | `./doctor-runner` configured Linux count is 10; after shed, slots return to 10 without a host reboot | doctor-runner, config count | 0-runner or 3-runner host looks crash-free = FAIL |

**Do not close this goal** if: repo tests pass but `/etc/watchdog.conf` still lacks `repair-maximum=0`; kdump still `0`; QEMU `cpu.max` is `max`/missing; or the next host stop is unclassified.

Related beads: [`ez-gh-actions-fkbm`](https://github.com/jleechanorg/ez-gh-actions/issues/126) (GOAL), `ez-gh-actions-oyxh`, `ez-gh-actions-e0z0`, `ez-gh-actions-ji5h`, `ez-gh-actions-8rx2`, `ez-gh-actions-e0z0.4`, `bd-bth` ([user_scope #27](https://github.com/jleechanorg/user_scope/issues/27)).

## Live status 2026-08-26 00:48 PDT (default FAIL)

| # | Evidence | Verdict |
|---|---|---|
| 1 | `apply-watchdog-no-reboot-vote.sh` → `NEED_SUDO` (sudo -n password required). `/etc/watchdog.conf` still `#repair-maximum = 1`. Repo+user copies PASS. | **FAIL** |
| 2 | 00:37 panic this boot; no classified runner-burst survival. | **FAIL** (unproven) |
| 3 | Live `cpu.max=1600000 100000`. `lima-vm-cpu-ceiling.service` enabled so the next Colima start reapplies `CPUQuota=1600%` without a VM restart. | **PASS** |
| 4 | virtfs still `$HOME`. Arm B 512MiB guest `dd`: lima `file` Δ=537MiB ≈ probe, host Cached Δ=558MiB (same bucket). Single-probe charge-to-cgroup, **not** multi-runner A/B. | **FAIL** (path still `$HOME`; one dd ≠ burst proof) |
| 5 | Duplicate `crashkernel=`; `kexec_crash_loaded=0`. Not applied (needs reboot). | **FAIL** |
| 6 | TEMP `count=5`, live 5/5 `ez-runner-c-1..5`. Ironclad still requires 10 (`qyyt`). | **FAIL** |

**08:55 PDT boot:** fourth CFS/nohz NX panic (`pstore/1787737288`, t=7376s ≈ **02:41**, then hung until 08:55). count=5 did not stop it. Stop path: `docs/notes/stop-cfs-nohz-panic.md` / `scripts/host/apply-cfs-nohz-panic-stop.sh` (sudo: `panic=10` now, `nohz=off` next boot).

**10:58 PDT `/nextsteps` refresh:** C1 still FAIL (`/etc` `#repair-maximum = 1`). C3 still PASS. C5 still FAIL on **this** boot (`kexec_crash_loaded=0`; cmdline still has both `crashkernel=` values) even though 09:58 stripped `/etc/default/grub` `crashkernel=512M` and ran `update-grub`. Live `kernel.panic=10` / `panic_on_oops=1`. `nohz=off` is GRUB-only until reboot. TEMP count=5 (C6 FAIL). Fault site: inlined `update_tg_load_avg` after `sched_clock_cpu`. Agent-scope-reaper timer **disabled** (conversation kill, not a Borg criterion). Goal wording recovered via `/history`: smallest layer crashes and recovers (Borg/K8s). Afternoon nextsteps: `~/roadmap/nextsteps-2026-08-26-cfs-nohz-reaper.md`.

Overall: **FAIL**. Open live gaps include whole-home 9p/virtfs, deployment of live
`repair-maximum=0`, one armed `crashkernel=` with `kexec_crash_loaded=1` on the current
boot, and restoring 10 Linux runners. Blocked on operator reboot (`nohz=off` + kdump
arm) + live `repair-maximum=0`. Sudo for panic sysctls is done.
