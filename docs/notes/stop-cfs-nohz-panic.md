# Stop Jeff-Ubuntu CFS/nohz NX panics

Date: 2026-08-26. This is the **panic class**, not watchdog.

## What just happened (08:55 boot)

| | |
| --- | --- |
| Previous boot | 00:38 PDT |
| Oops | kernel t=7376s ≈ **02:41 PDT** |
| pstore | `/var/lib/systemd/pstore/1787737288` |
| Signature | `Oops: 0011` `swapper/3` `_nohz_idle_balance` NX execute (RIP in zeros) |
| Then | host **hung until 08:55** (~6h14m) because `kernel.panic=0` and `kexec_crash_loaded=0` |
| Watchdog | no SIGTERM; journal still healthy at 02:41 |

Same bug as 08:24, 22:46, 00:37. **count=5 did not stop it.**

## What actually stops it

1. **This boot, no reboot (sudo):** `sysctl -w kernel.panic=10 kernel.panic_on_oops=1`
   Next Oops reboots in 10s instead of hanging for hours. Does **not** prevent the Oops.
2. **Next boot (sudo + reboot):** `nohz=off` on the host cmdline so idle CPUs do not run
   `_nohz_idle_balance` (the crashing path).
3. **Same reboot:** dedupe `crashkernel=` (remove grub:10 `crashkernel=512M`, keep
   kdump-tools.cfg). Then `kexec_crash_loaded=1` can dump vmcore.

OPERATOR-ONLY: `sudo bash scripts/host/apply-cfs-nohz-panic-stop.sh`
then OPERATOR-ONLY: `sudo reboot`

Never run `ez-gh-actions-8rx2` or `scripts/host/configure-grub-kdump.sh` (adds another `crashkernel=`).

## What will not stop it

- More cgroup caps, 5 vs 10 runners, repair-script `exit 0` — those are the **watchdog** class (17:34).
- This Oops is host kernel idle-balance on 6.17.0-29-generic, i9-13900K, `Tainted: P` (nvidia).
