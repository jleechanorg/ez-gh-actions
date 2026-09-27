# Jeff-Ubuntu Crash Mitigation and Attribution Design

**Date:** 2026-09-26
**Bead:** bd-dea.10 (`br --db /home/jleechan/projects_other/user_scope/.beads/beads.db show bd-dea.10`), parent bd-dea
**Status:** Design complete, revised once after `/advice` (Codex + Opus, 2026-09-26); implementation not started. Every host mutation below needs the sudo password (live: `sudo -n true` → "a password is required"), so execution is human-gated.
**Inputs:** `~/roadmap/nextsteps-2026-08-01-jeff-ubuntu-crash.md` § 2026-09-26 and `~/roadmap/jeff-ubuntu/rootcause-2026-09-26/{crash_census,favored_core_finding,hardware_evidence,history_summary,upstream_research}.md`.
**Roadmap pointer:** `~/roadmap/jeff-ubuntu/design-2026-09-26-crash-mitigation.md`.

## 1. Goal

Deliver, for the four items in bd-dea.10:

- (a) a change that reduces crash probability,
- (b) logging that attributes the next crash to "kernel use-after-free" or "degraded CPU",
- (c) a decision on `kernel.panic_on_oops`,
- (d) one discriminating experiment and a `soakctl` protocol, changing one probability-affecting variable at a time.

Done means: the next crash produces a vmcore that a written triage procedure classifies as SOFTWARE-UAF, HARDWARE-MISEXECUTION, or INCONCLUSIVE, and the box either survives 400 h under the experiment or the vmcore verdict selects the next single-variable step. Criteria are in § 10.

## 2. Evidence (every claim cites a rootcause file or a live command run 2026-09-26 23:10–23:30 PDT)

| # | Fact | Source |
|---|---|---|
| E1 | 26 distinct crashes since 2026-06-04; two signatures, both scheduler-clock call paths: NX-exec on a freed page from `__update_blocked_fair` (14/26) and NULL/near-NULL instruction fetch from `update_rq_clock`/`update_load_avg` (12/26); fault address `0x283` nine times. | crash_census.md § Patterns |
| E2 | 24/26 crashes in `swapper` or a root kworker; #25 in `psi_avgs_work`; #26 inside a runner `.NET TP Worker` (uid 1001) 2.5 s after a veth teardown. | crash_census.md rows 25–26 |
| E3 | 26/26 crashes on CPU0–3, which are the only two 5.8 GHz cores (core_id 0 and 4). P under uniform placement ≈ 3e-24. | favored_core_finding.md |
| E4 | Uptime at crash (seconds, from the census table): max 715,199 (198.7 h); median 71,863 (20.0 h); 9/26 ≥ 48 h; 0/26 ≥ 200 h. | crash_census.md table, column "Uptime (s)" |
| E5 | PL1 = PL2 = 253 W; microcode 0x133; BIOS 3107; no ECC; memtest never completed. | hardware_evidence.md § 1, § 5; live `cat /sys/class/powercap/intel-rapl:0/constraint_{0,1}_power_limit_uw` → 253000000 both |
| E6 | Microcode 0x133 is dated 2025-10-08 and the BIOS-resident revision is 0x12F ("Updated early from: 0x0000012f"). Intel revisions for one CPUID are cumulative, so 0x133 supersedes the May-2025 0x12F idle-crash fix. | live `iucode_tool -l /lib/firmware/intel-ucode/06-b7-01` (sig 0xb0671 rev 0x0133 2025-10-08); live `journalctl -k -b 0 \| grep microcode`; upstream_research.md § Q3 for the 0x12F date |
| E7 | kdump is armed: `kexec_crash_loaded=1`, reserved 640 MiB (`kexec_crash_size=671088640`), `kdump-config show` = "ready to kdump", suggested size 1252 M. | live `/sys/kernel/kexec_crash_loaded`, `/sys/kernel/kexec_crash_size`, `kdump-config show` |
| E8 | Live sysctls: `panic_on_oops=1`, `softlockup_panic=0`, `hardlockup_panic=0`, `panic=0`, `hung_task_panic=0`, `nmi_watchdog=1`, `watchdog_thresh=10`. No `/etc/sysctl.d` file mentions panic or lockup. | live `sysctl -n …`; live `grep -rn panic /etc/sysctl.d` → empty |
| E9 | Zero soft-lockup, hard-lockup, or hung-task lines in any of the 72 pstore dumps or the retained journal; zero `Oops:` lines in the retained journal (every oops ended its boot). | live `grep -rlE "soft lockup\|hard LOCKUP\|hung task" /var/lib/systemd/pstore/` → 0; live `journalctl -k \| grep -c Oops:` → 0 |
| E10 | `cmdline` carries `crashkernel=512M,high crashkernel=128M,low nohz=off`; `/etc/default/grub.d/kdump-tools.cfg` owns the crashkernel words. | live `/proc/cmdline`; live `cat /etc/default/grub.d/kdump-tools.cfg` |
| E11 | Runner churn over the last 4 h: 472 reclaims (118/h) and 285 respawns (71/h), higher than the "~50/h" in the bead. | live `bash docs/measure-churn-rate.sh --since "4 hours ago"` |
| E12 | Runners are not CPU-pinned: `actions.slice` has `AllowedCPUs=` empty and `CPUQuotaPerSecUSec=20s`; `count = 10`, `cpus = 2.0` per runner. | live `systemctl show actions.slice`; live `~/.config/ezgha/config.toml` |
| E13 | `systemd-oomd` monitors no cgroups (no PSI triggers installed by oomd). | live `oomctl` → "Memory Pressure Monitored CGroups:" empty |
| E14 | Ubuntu HWE candidate is `linux-image-generic-hwe-24.04 7.0.0-34.34~24.04.1`. Its changelog contains "sched/psi: fix race between file release and pressure write" (the root dependency `a5b98009f16d`) but zero hits for the July-2026 psimon/`psi_trigger_destroy` patchset or the Sep-2026 `h_curr`/`distribute_cfs_runtime` fix. | live `apt-cache policy linux-image-generic-hwe-24.04`; live `apt-get changelog linux-hwe-7.0 \| grep -iE "psimon\|h_curr\|distribute_cfs"` → 0 hits; upstream_research.md § Q1–Q2 |
| E15 | 6.8 LTS: bd-soak28/bd-falskern say 6.8.0-110 panicked in 25 min on 2026-04-30 with the `__update_blocked_fair` signature. No pstore record predates 2026-06-04 (earliest dir 1780630459); the OS was installed 2026-02-16 (same install); 6.8.0-110 was later removed by apt; 6.8.0-124 is installed and has never booted. | live `ls /var/lib/systemd/pstore \| sort \| head -1`; live `ls /var/log/installer`; live `zgrep 6.8.0-110 /var/log/apt/history.log*`; crash_census.md § Kernel versions |
| E16 | `eno2` (igc, 1000 Mb/s, carrier up) is unconfigured (NetworkManager "disconnected"); the host's LAN address is on Wi-Fi (`wlp0s20f3` 192.168.254.128/24). MacBook `en0` = 192.168.254.199, MAC `ae:2f:22:95:b5:35`. `netconsole.ko` is available; `igc` exports no `ndo_poll_controller` symbol. | live `ethtool eno2`, `nmcli dev status`, `ip -br addr`, `ssh macbook ifconfig en0`, `modinfo netconsole`, `grep igc_netpoll /proc/kallsyms` → 0 |
| E17 | `crash` 8.0.4 and `makedumpfile` are installed; no dbgsym kernel and no ddebs apt source. | live `which crash makedumpfile`; live `apt-cache policy linux-image-6.17.0-29-generic-dbgsym` → not found |
| E18 | `soakctl` exists (`~/.local/bin/soakctl`) but no timer or cron runs `soakctl watch`; one stale failed soak is still listed. | live `soakctl list`; live `systemctl --user list-timers \| grep soak` → empty; `crontab -l \| grep soak` → empty |
| E19 | ez-gh-actions forbids any `kernel.panic`, `panic_on_oops`, or `sysrq-trigger` text in `src/`, `scripts/`, `systemd/`, `install.sh`, and forbids files such as `config/sysctl.d/99-ezgha-oops-reboot.conf`. | `tests/forbid_host_reboot_primitives_test.sh` lines 18–39, 105–117 |
| E20 | user_scope already hosts Jeff-Ubuntu system units and scripts with pytest coverage (`systemd/collect-unclean-boot-evidence.service`, `scripts/queue_memtest.sh`, `scripts/install-memtest-grub-entry.sh`, `tests/test_queue_memtest_script.py`). | live `git -C ~/projects_other/user_scope ls-files` |
| E21 | Both 5.8 GHz cores also carry the highest Intel Turbo Boost Max (ITMT) priority, because intel_pstate derives ITMT priority from each core's HWP highest-performance value and only cpu0–3 report `cpuinfo_max_freq=5800000`. | live `/sys/devices/system/cpu/cpu{0..3}/cpufreq/cpuinfo_max_freq` = 5800000 vs 5500000 for cpu4–15; `intel_pstate/status = active`, `hwp` flag present. The ITMT sysctl does not exist on 6.17 (`kernel.sched_itmt_enabled` → "cannot stat"); the debugfs knob needs root, so this is a documented inference, verified in T4 |

## 3. Problem statement

Two hypotheses survive the four lanes:

- **H-SW (kernel use-after-free in scheduler/cgroup teardown under runner churn).** For: E1 (deterministic small fault addresses, 0x283 ×9), E2 (#26 lands on the runner thread right after veth teardown), E11 (churn is high), upstream PSI/EEVDF fixes (upstream_research.md § Q1). Against: 6d22h survival with `cgroup_disable=cpu` ended in the same code path with no cgroup cfs_rqs (history_summary.md § (b) item 10).
- **H-HW (Raptor Lake Vmin-shift on the favored cores).** For: E3 (26/26 on the two highest-V/f cores), E5 (253 W sustained), history_summary.md § (c) (memtest, C-state, microcode rollback never completed). Against: E6 (0x133 is post-0x12F), no MCE/EDAC/AER-fatal evidence (hardware_evidence.md § Verdict), and E21: the favored cores are also where the scheduler steers work (ITMT), so clustering alone cannot separate the two hypotheses.

Neither hypothesis is falsifiable from pstore text. A vmcore is: it shows whether the memory the CPU should have read still holds a valid value (CPU mis-executed → H-HW) or holds the garbage the CPU used (memory corrupted → H-SW or DRAM). Every design choice below preserves that vmcore.

## 4. Decisions

### D1 — Probability reduction: cap the two favored cores to the common 5.5 GHz bin (single variable)

Set `scaling_max_freq=5500000` on cpu0–3 (runtime, sysfs, reverts in seconds, no reboot, no fleet impact). Rationale:

1. It is the only lever that directly tests E3, the strongest statistical anomaly in the corpus.
2. It keeps ITMT priority unchanged (priority derives from HWP highest-perf, not from `scaling_max_freq`), so scheduler steering toward cpu0–3 is constant and only the V/f point moves. It probes only one H-HW variant: the light-load top-turbo bin, which is exactly the state of an idle favored core woken by a softirq (24/26 crashes). It does not probe the idle/C-state exit-voltage variant; that is S2e (persistent `intel_idle.max_cstate=1`, bd-qy1). If crashes continue on cpu0–3 at 5.5 GHz, only the top-bin variant loses; if they stop for 400 h, H-HW gains strongly. The vmcore, not the cap, is the primary discriminator (§ 5).
4. Prior worth stating: nine identical `0x283` fault addresses (E1) are easier to explain by a stale field read through a freed pointer than by mis-execution, so the software hypothesis starts ahead. The cap is chosen because it is the cheapest reversible H-HW probe, not because H-HW is favoured.
3. Cost: ≤5 % single-thread peak on two cores. Runners are 2-CPU-quota containers and all-core turbo is already ≤5.5 GHz, so CI throughput is unaffected.

Alternatives considered and their disposition:

| Alternative | Disposition | Why |
|---|---|---|
| Fewer runners (count 10 → 5) | Rejected now | CLAUDE.md fleet standard requires 10 Linux slots; memory `feedback_2026-08-26_host_uncrashable_smallest_layer` says "do not leave count=5". Churn only amplifies (history_summary.md § (b) item 8); it does not discriminate. |
| Long-lived runners (container reuse) | Deferred to the H-SW branch (S2b) | ezgha JIT runners are single-job by construction (`src/github.rs:1051`); reuse is a product redesign with its own isolation review. |
| Kernel 7.0.0-34 HWE | Rejected now | E14: it carries neither candidate fix and adds a nvidia/DKMS variable. |
| Kernel 6.8.0-124 LTS | H-SW branch (S2a) | Predates the EEVDF single-runqueue rework (upstream_research.md § Q1), so it tests that anchor; the 2026-04-30 negative result is unverifiable (E15). |
| BIOS PL1 = 125 W, TVB off | Hygiene after S1 (S2c/S3) | Requires physical presence; slows further Vmin wear but discriminates nothing on idle-context faults. |
| `cgroup_disable=cpu` | Rejected | Undoes load-bearing `actions.slice` CPU containment; already failed as a cure (history_summary.md § (b) item 10). |
| `psi=0` | Rejected | Removes 1/26 call site, disables PSI for oomd and the pressure recorder (bd-vjd). |
| Disable ITMT (`/sys/kernel/debug/sched/itmt_enabled=0`) | Reserve as S2d | Tests "crashes follow scheduler steering" — useful only if S1 crashes on cpu0–3 and the vmcore is INCONCLUSIVE. |
| Persistent C-state clamp (`intel_idle.max_cstate=1`) | Reserve as S2e | Probes the idle exit-voltage H-HW variant the cap does not touch (history_summary.md § (c)); needs a reboot, so it follows S1. |

### D2 — Logging

1. **Keep kdump** (E7). Do not change `crashkernel=` before the SysRq-c proof (D4 step W3); raise to `1G,high` only if the proof shows the 640 MiB crash kernel OOMs.
2. **Lockup panics:** `kernel.softlockup_panic=1`, `kernel.hardlockup_panic=1`, `kernel.hung_task_panic=0` (unchanged), via `/etc/sysctl.d/90-jeff-ubuntu-crash-capture.conf` (owned by user_scope, E19/E20). A freeze without an oops then panics into kdump instead of hanging until a human power-cycles. Blast radius in § 7.
3. **`kernel.panic=10`:** after a panic the box reboots itself in 10 s if the crash kernel did not take over. This is a requested operator exception to the CLAUDE.md prohibition, argued in § 8; it is not claimed to be compliant.
4. **netconsole → MacBook** over the idle wired NIC. netpoll builds its own frames on the named device, so `eno2` gets no NetworkManager connection and no routable address: the source address `192.168.254.130` exists only inside the netconsole parameter, the target MAC is omitted (netconsole then uses the Ethernet broadcast address, which avoids the MacBook's rotating private Wi-Fi MAC), and the module is loaded by a small unit ordered after `sys-subsystem-net-devices-eno2.device` that first sets the link up, not by `modules-load.d` (which runs before the link exists). Receiver: a launchd job on the MacBook running `nc -ukl 6666`. Value: last minute of kernel log before a crash and a backup if kdump fails; gap: MacBook sleep loses packets (accepted). netpoll works on NAPI drivers without `ndo_poll_controller`; T3/T4 prove it with a live `/dev/kmsg` probe before the item is marked done.
5. **vmcore triage script** (`scripts/vmcore-triage.sh` in user_scope) that runs `crash` in batch against a dbgsym `vmlinux` and prints the register-versus-memory comparison that decides § 5.

### D3 — `panic_on_oops`: keep 1

`kdump-config` forces it (nextsteps § Executive summary). On this host an oops has never been survivable (E9: zero `Oops:` lines in the retained journal, 26 boots ended by an oops), and every oops was in scheduler core, where continuing means running on freed `rq` state. Overriding it after `kdump-tools` starts would trade the only artifact that can settle H-SW vs H-HW for an unmeasurable chance of limping on. Decision: keep `kernel.panic_on_oops=1` and state it explicitly in the same sysctl file so a future `kdump-tools` change cannot silently flip it.

### D4 — Discriminating experiment and soak protocol

**Variables.** Logging changes (D2) do not alter crash probability, so applying D2 and D1 in one maintenance window changes exactly one probability-affecting variable. The vmcore attributes any crash regardless.

**Maintenance window W (human present, sudo):**

| Step | Action | Proof |
|---|---|---|
| W0 | Drain: `systemctl --user stop ezgha.service`; wait for `docker ps --filter label=ezgha=managed` to reach 0 | live count = 0 |
| W1 | Memtest86+ ≥ 4 passes overnight (bd-memtest501, reuse `scripts/queue_memtest.sh`) | photo/screenshot of pass count |
| W2 | Install D2 sysctl file, netconsole config, receiver; `sysctl --system` | `assert-crash-capture.sh` → `PASS`, MacBook log shows a probe line |
| W3 | SysRq-c proof. OPERATOR-ONLY, human present, fleet drained: write `c` to the SysRq trigger as root; box must dump and return by itself | new `/var/crash/<ts>/dump.<ts>` ≥ 50 MiB and `uptime` < window age; if no dump, raise `crashkernel=1G,high`, reboot, repeat once |
| W4 | Apply D1 cap (`systemctl enable --now favored-core-cap.service`) | `favored-core-cap.sh assert` → `PASS S1-cap` |
| W5 | Start ezgha; `soakctl start favcore-cap-5500-10runners-<date> --target 200 --bead bd-dea.10 --config "6.17.0-29 nohz=off, cpu0-3 capped 5.5GHz, 10 runners, lockup panics on, kdump armed"`; enable the `soak-watch.timer` | `soakctl status` in progress; timer listed |

**Soak targets** (soak skill rules, E4): target 200 h (≥ longest known 198.7 h). Promotion at 400 h crash-free (≥ 2× target and > 1.5× longest ever). A crash is data: record elapsed, do not reset.

**Vmcore triage (run within 24 h of any crash, § 5) and decision tree:**

| S1 outcome | Verdict | Next single-variable step |
|---|---|---|
| Crash, vmcore | MEMORY-CORRUPTION (SOFTWARE-UAF) | S2a: boot `6.8.0-124` (keep cap; it is now known not to matter), soak 200 h/400 h. 6.8 survives → stay on 6.8, file Launchpad bug with vmcore, wait for an HWE build carrying the § E14 fixes. 6.8 crashes → S2b: runner-reuse design bead (churn reduction without losing 10 slots). |
| Crash, vmcore | HARDWARE-MISEXECUTION (first) | Keep S1 running; a second HARDWARE vmcore is required (§ 5). Meanwhile run S2e (C-state clamp) as the next reboot-time variable only if 200 h pass without a second dump. |
| Two vmcores | HARDWARE-MISEXECUTION (second) | S2c: BIOS PL1 = 125 W + TVB off, Intel Processor Diagnostic Tool, open RMA path; keep cap; soak 200 h. |
| Crash, vmcore | MEMORY-CORRUPTION (DRAM-BITFLIP) | Memtest result (W1) decides: errors → RAM path (bd-hwpath28); clean → treat as UNKNOWN and continue S1. |
| Crash, vmcore | INCONCLUSIVE | Fix the capture gap named by the triage (dbgsym mismatch, truncated dump, crashkernel size), restart the same soak. If a second vmcore is also inconclusive, run S2d (ITMT off) as the next discriminator. |
| Crash, no vmcore | — | Capture defect: W3 was not honest, or the failure was a hang without lockup detection. Fix and restart S1; do not change D1. |
| 200 h clean | — | Extend the same soak to 400 h. |
| 400 h clean | H-HW favored-core supported | Reverse test S3: revert the cap; if a crash returns within 200 h on cpu0–3, the cap is the fix (A/B/A). Then make the cap permanent, apply S2c hygiene, and open the RMA bead. |

## 5. Vmcore triage decision procedure

Inputs: `/var/crash/<ts>/dump.<ts>`, `vmlinux` from the matching `-dbgsym` ddeb (E17; fetched and `dpkg -x`'d without root). `scripts/vmcore-triage.sh` prints, in order: `sys`, `log | tail -120`, `bt`, `bt -f`, `bt -r` (the saved `pt_regs` of the faulting context), the disassembly ending at the return address of frame #1 (so the last instruction shown is the call that jumped to the bad `RIP`), `rd -x` of every memory word that instruction or its feeding `mov` reads, `kmem` for the bad `RIP` and for the fault address, `kmem -s` filtered to scheduler/cgroup/PSI caches, `ps -A | head`, `runq`.

**Two timestamps matter.** Registers in `pt_regs` were captured by the exception entry at the fault instant. Memory in the dump was captured later, after the crash NMI stopped the other CPUs, so a concurrent free-and-reuse can rewrite a word between the fault and the dump. The rule therefore compares `RIP` against the *register or immediate that supplied the branch target*, and uses memory only to corroborate.

**Step 1 — classify the transfer instruction** (from `dis -r <return address of frame #1>`; note Ubuntu 6.17 compiles C indirect calls to `call __x86_indirect_thunk_<reg>` and `sched_clock` uses a static-call trampoline, so "looks like a direct call" is not evidence by itself):

| Instruction form | Branch-target source |
|---|---|
| `call *%reg` or `call __x86_indirect_thunk_<reg>` | the named register in `pt_regs` |
| `call *disp(%reg)` | the memory word at `reg+disp`, read with `rd -x` |
| `call <symbol>` to a real function | the rel32 immediate in the text page (re-read with `rd -x` at the call site) |
| `call __SCT__*` (static call) | the trampoline's `jmp` target: `dis __SCT__<name>` |
| `ret` (frame #0 is unreachable from frame #1's call) | the stack slot shown by `bt -f` |

**Step 2 — verdict:**

| Verdict | Rule |
|---|---|
| MEMORY-CORRUPTION (sub-typed SOFTWARE-UAF / DRAM-BITFLIP / UNKNOWN) | The supplying register (or, for memory-sourced forms, the word read now) **equals** the bad `RIP`. The CPU faithfully executed a bad value it was handed. Sub-type: SOFTWARE-UAF if the word lives in a freed or re-used slab page of a scheduler/cgroup/PSI cache (`kmem`), or the containing object is a `cfs_rq`/`task_group`/`psi_group` whose cgroup is gone; DRAM-BITFLIP if the word differs from a valid function address by one bit; otherwise UNKNOWN. |
| HARDWARE-MISEXECUTION | The supplying register in `pt_regs` (or a re-read, intact text immediate / static-call trampoline) holds a **valid kernel text address** and `RIP` does not equal it. The CPU did not jump where its own input said. Record the CPU number; it must be in 0–3 for E3 to keep its weight. Two independent vmcores with this verdict are required before S2c (BIOS/RMA) is opened. |
| INCONCLUSIVE | `crash` cannot load the dump; the transfer instruction cannot be identified; the form is memory-sourced and the word read now is valid (the race above makes that unprovable either way); or the register that supplied the target was clobbered by the thunk. Record the exact gap and continue the soak. |

`scripts/vmcore-triage.sh` never emits MEMORY-CORRUPTION or HARDWARE-MISEXECUTION on its own; it emits the evidence blocks and `VERDICT: INCONCLUSIVE reason=human-review-required` unless the dump is the SysRq proof. The human applies the table and records the verdict in bd-dea.10 (C12). A second reviewer (Codex) re-reads the same report before any S2c action.

## 6. Contradictions resolved

1. **6.8 LTS status.** The 2026-04-30 "identical panic in 25 min" claim cannot be re-derived from any artifact on disk (E15). Treat 6.8 as UNTESTED for the instrumented signature. A 6.8.0-124 boot remains a valid single-variable test because it predates the EEVDF rework, and it is placed in the H-SW branch (S2a), not first. Close bd-postreboot28 into bd-dea.10's S2a and mark bd-py7 as blocked on the S1 verdict.
2. **Microcode 0x133 vs 0x12F.** 0x133 (2025-10-08) is a later cumulative revision than 0x12F (May 2025) for CPUID 0xB0671 (E6). The idle-crash fix is present. bd-microcode ("test pre-2026-04-14 microcode") would move backwards past that fix and is not a discriminator; leave it open but rank it below S2c.

## 7. Blast radius (required by CLAUDE.md § Safety & Monitoring Principles)

| Change | Bounded metric | Normal peak (source) | Trigger threshold | Margin / interaction |
|---|---|---|---|---|
| `softlockup_panic=1` | kernel-mode stalls > 2×`watchdog_thresh` = 20 s | 0 in 72 pstore dumps and retained journal (E9) | 20 s | `actions.slice` CPU quota throttles user space only; cannot produce a kernel-mode stall. A first-ever 20 s stall would now dump and reboot instead of freezing. |
| `hardlockup_panic=1` | NMI-detected stalls (`nmi_watchdog=1`, E8) | 0 (E9) | 10 s | Same; the perf NMI watchdog is already on. |
| `kernel.panic=10` | seconds a dead host stays dead when kdump does not take over | today: unbounded (Sep 26 froze 78 min until a human) | 10 s | Acts only after a panic; creates no panic. |
| `panic_on_oops=1` (explicit) | oopses that previously would not have panicked | 0 survivable oopses (E9) | first oops | No behaviour change from today (kdump-config already forces it). |
| cpu0–3 cap 5.5 GHz | single-thread peak on two cores | 5.8 GHz TVB bin | n/a | −5 % on two cores; all-core turbo unchanged; runners unaffected (E12). Revert: `favored-core-cap.sh revert`. |
| netconsole | UDP broadcast frames per kernel log line on `eno2` | measured in T3 before enabling (journal lines/hour) | n/a | Wired NIC is otherwise idle (E16); Wi-Fi untouched; broadcast frames are seen by every LAN host, so `printk` rate limiting stays default. |
| crashkernel 640 MiB → 1 GiB (conditional) | RAM removed from the running system | 61 GiB total, 49 GiB available (live `free -g`) | only if W3 fails | < 2 % of RAM. |

## 8. Safety principles — requested exception, not compliance

CLAUDE.md § Safety & Monitoring Principles forbids any script, daemon, test, or automation in ez-gh-actions from invoking **or instructing** host reboot, forced-panic, or SysRq primitives, and `tests/forbid_host_reboot_primitives_test.sh` enforces it for active code (E19). This design asks the operator to grant a bounded exception for three host-level settings and one supervised action:

1. `kernel.softlockup_panic=1`, `kernel.hardlockup_panic=1` — turn a frozen host into a captured panic. Never observed to fire here (E9).
2. `kernel.panic=10` — bounds how long a panicked host stays dead if kdump does not take over; `kdump-tools` already reboots after a successful dump.
3. One SysRq-c capture proof (W3), operator-run, drained, watched, never scheduled.

Why the exception is worth asking for: without 1–3 the Sep 26 crash froze the host for 78 minutes until a human arrived, and no vmcore existed; the only artifact that can end the H-SW/H-HW argument is the vmcore these settings guarantee. Why it stays bounded: none of them can fire on a healthy host (§ 7), none run on a schedule, and none give ezgha or any daemon reboot authority. The artifacts live in user_scope so that ezgha never carries host-lifecycle instructions; the ez-gh-actions test keeps passing on its own terms, and these two documents are the only place in this repo that name the settings, each marked `OPERATOR-ONLY`. Self-outage check: a capture setting can only cause an outage through a false-positive lockup (never observed) or a kdump-time failure, which W3 proves before the settings are relied on. If the operator declines the exception, D2 items 2–3 and W3 are dropped, `panic_on_oops` stays at kdump-config's value, and the design still proceeds with D1 and the soak; the next crash then yields pstore text only, and § 5 cannot run.

## 9. Assumptions and Recommended Defaults (auto-picked)

| # | Question | Auto-picked answer | Rationale |
|---|---|---|---|
| Q1 | Which mitigation first? | Favored-core cap (D1) | Only lever that tests E3; runtime-reversible; keeps ITMT constant (E21). |
| Q2 | Reduce runner count or churn now? | No | Fleet standard 10/10; churn amplifies but does not discriminate; reuse design belongs to the S2b bead. |
| Q3 | `panic_on_oops`? | Keep 1 | § D3. |
| Q4 | `kernel.panic`? | 10 | § 7/8; Sep 26 froze 78 min waiting for a human. |
| Q5 | Which lockup panics? | soft=1, hard=1, hung_task=0 | Hung tasks (D-state on IO) are not host death and have benign causes. |
| Q6 | netconsole target and path? | MacBook `en0` via `eno2`, static IP, MAC hardcoded | E16; the only wired idle NIC; Wi-Fi drivers do not support netpoll. |
| Q7 | Change kernel now? | No | E14; 6.8 only in the H-SW branch. |
| Q8 | BIOS PL1/TVB now? | No, after S1 | Physical presence; not a discriminator. |
| Q9 | When does memtest run? | W1, in the same drained window | Box is offline anyway; closes bd-memtest501. |
| Q10 | Raise `crashkernel` pre-emptively? | No; only if W3 fails | Do not touch a booting cmdline before proving need. |
| Q11 | Where do artifacts live? | user_scope (`systemd/`, `scripts/`, `config/`, `tests/`) | E19 forbids them in ez-gh-actions; E20 shows the precedent. |
| Q12 | Soak target / promotion? | 200 h / 400 h | E4 and the soak skill's target rules. |
| Q13 | Two changes in one window? | Yes: D2 (logging) + D1 (cap) | Logging does not change crash probability; vmcore attributes. |
| Q14 | Soak watchdog? | user `soak-watch.timer` every 5 min | E18: `soakctl watch` is not scheduled today. |
| Q15 | Design doc location? | Canonical here; pointer under `~/roadmap/jeff-ubuntu/` | The bead's acceptance path plus a git-reviewable canonical. |
| Q16 | Treat the cap as the discriminator? | No; the vmcore is (revised after `/advice`) | Codex and Opus both flagged the cap as confounded and the original triage rule as unsound. |
| Q17 | Claim compliance with the reboot-primitive prohibition? | No; request a bounded exception (§ 8) | Opus: the prohibition covers "invoke or instruct"; honesty over workaround. |

## 10. Ironclad exit criteria (default FAIL; a verifier re-executes on Jeff-Ubuntu)

Each check prints exactly one `PASS <id>` or `FAIL <id> …` line.

| # | Criterion | Check | Verifier |
|---|---|---|---|
| C1 | Sysctl file installed and effective | `for k in panic_on_oops:1 softlockup_panic:1 hardlockup_panic:1 panic:10 hung_task_panic:0; do [ "$(sysctl -n kernel.${k%%:*})" = "${k##*:}" ] \|\| { echo "FAIL C1 $k"; exit 1; }; done; [ -f /etc/sysctl.d/90-jeff-ubuntu-crash-capture.conf ] && echo PASS C1 \|\| echo FAIL C1-file` | Codex |
| C2 | kdump still armed after every reboot in scope | `[ "$(cat /sys/kernel/kexec_crash_loaded)" = 1 ] && echo PASS C2 \|\| echo FAIL C2` | Codex |
| C3 | SysRq-c produced a real dump | `d=$(ls -d /var/crash/2026* 2>/dev/null \| tail -1); [ -n "$d" ] && [ "$(stat -c %s "$d"/dump.* 2>/dev/null \| sort -n \| tail -1)" -ge 52428800 ] && echo "PASS C3 $d" \|\| echo FAIL C3` | Codex |
| C4 | Box returned by itself after the SysRq-c test | journal of the boot after the test shows `kdump-tools` completed and no `systemctl reboot` by a human: `journalctl -b -1 -u kdump-tools-dump.service --no-pager \| grep -q "saved vmcore" && echo PASS C4 \|\| echo FAIL C4` | Codex |
| C5 | Favored-core cap live and persistent | `/usr/local/libexec/favored-core-cap.sh assert && systemctl is-enabled favored-core-cap.service \| grep -qx enabled && echo PASS C5 \|\| echo FAIL C5` | Codex |
| C6 | ITMT priority unchanged by the cap | `sudo cat /sys/kernel/debug/sched/itmt_enabled` = 1 and `cpuinfo_max_freq` for cpu0–3 still 5800000 → `PASS C6`, else `FAIL C6` | Human (root) |
| C7 | netconsole delivers to the MacBook | on Jeff-Ubuntu `echo "netconsole-probe $(date +%s)" \| sudo tee /dev/kmsg`; within 5 s `ssh macbook grep -c netconsole-probe ~/Library/Logs/netconsole-jeff-ubuntu.log` ≥ 1 → `PASS C7` | Codex |
| C8 | Soak registered with the right target and watchdog | `soakctl status favcore-cap-5500-10runners-* \| grep -q "target=200h" && systemctl --user is-active soak-watch.timer \| grep -qx active && echo PASS C8 \|\| echo FAIL C8` | Codex |
| C9 | Fleet back to 10/10 after W5 | `./doctor-runner` shows 10 slots, none DOWN or IDLE-STARVED, **and** the deploy-owner's `./docs/verify-exit-criteria.sh` Gate 3 passes with a canary job whose `Runner.Worker` is seen by `docker top` → `PASS C9` | Deploy-owner |
| C10 | Triage pipeline yields the § 5 evidence on the W3 dump | report from `scripts/vmcore-triage.sh <dump>` contains a `PANIC:` line, a `bt -r` register block with `RIP:`, and a disassembly block ending at frame #1's return address, and the script prints `VERDICT: INCONCLUSIVE reason=sysrq-induced` → `PASS C10`. This proves the pipeline delivers the inputs; the rule itself is only exercised by a real crash. | Codex |
| C11 | Memtest86+ completed ≥ 4 passes with 0 errors | bead bd-memtest501 comment with a photo/screenshot and pass count → `PASS C11`, else `FAIL C11` | Human |
| C12 | Terminal outcome recorded | bd-dea.10 comment contains one of: `S1 VERDICT MEMORY-CORRUPTION/<subtype>`, `S1 VERDICT HARDWARE-MISEXECUTION <n-of-2>`, `S1 INCONCLUSIVE <gap>`, `S1 CLEAN 400h`, names the report path, and names the next step from § D4; a second reviewer's `br` comment concurs → `PASS C12` | Codex |
| C13 | No forbidden primitive entered ez-gh-actions | `bash tests/forbid_host_reboot_primitives_test.sh` → `PASS` | CI |

## 11. Implementation Preconditions (unmet as of design time)

- **P1 sudo password / root.** Every host mutation (sysctl, unit install, netconsole, SysRq-c, crashkernel) needs it; C6 needs root debugfs. A human runs W0–W5 or supplies the password interactively.
- **P2 Human presence for W1 and W3.** Memtest is a GRUB-menu boot; SysRq-c must be watched to confirm the auto-return.
- **P3 `eno2` L2 adjacency to 192.168.254.0/24 and a free static address.** Unverified: `eno2` has carrier but no address (E16). T3 must `ping -I eno2 192.168.254.199` before enabling netconsole; if it fails, netconsole is recorded as UNAVAILABLE and D2.4 is dropped without blocking the rest.
- **P4 MacBook awake.** Netconsole loses packets during sleep; the receiver is best-effort.
- **P6 Operator exception (§ 8).** D2 items 2–3 and W3 run only after the operator explicitly approves the exception in a live message; otherwise they are skipped and recorded.
- **P5 dbgsym for `crash`.** The `linux-image-unsigned-6.17.0-29-generic-dbgsym` ddeb (≈1 GiB) must be fetched from ddebs.ubuntu.com; no root needed for `dpkg -x` into `~/.local/share/vmlinux/`.

## 12. Out of scope

- The desktop `user@1000` SIGKILL question (bd-dea.7) — separate failure.
- The Aug-24 memory-overcommit incident class (history_summary.md § (b) item 13).
- Runner-reuse product design (S2b) — its own bead if reached.
- Any change to ezgha source.
