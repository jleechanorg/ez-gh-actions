# Maint-window: dedupe `crashkernel=` on Jeff-Ubuntu

Date: 2026-08-26. **Not authorized this session.** This file is the
procedure only. Do not run it from an agent session, a `/nextsteps`
sweep, or a "low-risk sudo" batch. Owner is
[bd-bth / user_scope#27](https://github.com/jleechanorg/user_scope/issues/27).
Goal criterion:
[ez-gh-actions-fkbm](https://github.com/jleechanorg/ez-gh-actions/issues/126)
criterion 5 (one `crashkernel=`, `kexec_crash_loaded=1`, vmcore proof).

Read-only snapshot taken 2026-08-26 on host `Jeff-Ubuntu`
(`6.17.0-29-generic`). Live `/proc/cmdline` has **both**:

```
crashkernel=512M
crashkernel=512M,high
```

and `/sys/kernel/kexec_crash_loaded` is `0`. A panic therefore hangs
instead of dumping vmcore (2026-08-25 22:46 CFS/nohz hung ~57 min until
the 23:43 boot). Duplicate params prevent the crash kernel from
reserving memory; `kdump-config load` cannot fix a cmdline that is
already baked in at boot.

## Why the ez-gh-actions-8rx2 one-liner is forbidden

**Never run the command stored on `ez-gh-actions-8rx2`.** It is refuted.

That bead's sudo block `sed`s `/etc/default/grub.d/kdump-tools.cfg`,
replacing `crashkernel=512M,high` with the same token **plus** a
newline and `crashkernel=256M,low`, then `update-grub` and
`kdump-config load`. On this host that file is the *package* source of
the second param. The first param lives on `/etc/default/grub` line 10
and is untouched. Result after the sed:

- `crashkernel=512M` (grub:10, still present)
- `crashkernel=512M,high` (kdump-tools.cfg, still present)
- `crashkernel=256M,low` (**new third param**)

plus a broken quoted assignment if the `\n` lands inside the
`GRUB_CMDLINE_LINUX_DEFAULT="..."` line. `kdump-config load` cannot
un-reserve a duplicate already on the running cmdline. Criterion 5 of
`ez-gh-actions-fkbm` explicitly says: never run that sed.

Also do **not** run `scripts/host/configure-grub-kdump.sh` for this
window. It strips `crashkernel=` from `/etc/default/grub` and writes
`crashkernel=2G` there, while leaving `kdump-tools.cfg`'s
`crashkernel=512M,high` in place — another duplicate, just with `2G`.

## Live sources (quoted 2026-08-26, read-only)

`/etc/default/grub` line 10 (manual duplicate — **remove this
`crashkernel=` only**):

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash nvidia.NVreg_EnableGpuFirmware=0 crashkernel=512M"
```

`/etc/default/grub.d/kdump-tools.cfg` line 1 (package injection —
**keep this file unchanged**):

```
GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT crashkernel=512M,high"
```

Leave `nvidia.NVreg_EnableGpuFirmware=0` on grub:10. Leave
`GRUB_DEFAULT`, timeout, and every other grub.d drop-in alone.

## Blast radius

This fix **requires a reboot**. `crashkernel=` is a boot-time memory
reservation; editing grub without reboot leaves
`kexec_crash_loaded=0` and the duplicate still on `/proc/cmdline`.

Reboot takes down the whole Jeff-Ubuntu Linux fleet (`ez-runner-c-1..10`
plus the lima-colima VM). Mac runners on the other host are out of
scope. Expect: host down through GRUB, kernel, lima/colima, Docker,
then `ensure_count` respawn. That is production fleet downtime, not a
daemon restart. Do not combine with an `ezgha.service` restart, a
Colima recreate, or other host-watchdog-adjacent work. Schedule a
maint window; do not apply under load or during an in-flight Gate 0
deploy.

## Pre-window confirm (read-only; abort if already unique)

Confirm the duplicate is still the live failure before touching grub:

```
tr ' ' '\n' </proc/cmdline | grep crashkernel
cat /sys/kernel/kexec_crash_loaded
```

Abort if grep prints exactly one line and `kexec_crash_loaded` is
already `1` — then this procedure is stale. Abort if grub:10 no longer
contains `crashkernel=512M` — the sources moved.

## OPERATOR-ONLY steps (bd-bth maint window)

Not authorized this session. Prefix is required so agents do not
execute these.

1. Backup both files.

OPERATOR-ONLY: `sudo cp -a /etc/default/grub /etc/default/grub.bak.kdump-dedup-$(date +%Y%m%d%H%M%S)`

OPERATOR-ONLY: `sudo cp -a /etc/default/grub.d/kdump-tools.cfg /etc/default/grub.d/kdump-tools.cfg.bak.kdump-dedup-$(date +%Y%m%d%H%M%S)`

2. Remove **only** the manual `crashkernel=512M` from grub:10. Keep
   `quiet splash nvidia.NVreg_EnableGpuFirmware=0`. Do not edit
   `kdump-tools.cfg`. Target line after edit:

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash nvidia.NVreg_EnableGpuFirmware=0"
```

OPERATOR-ONLY: edit `/etc/default/grub` line 10 as above (visually
confirm; do not run the 8rx2 sed, and do not `sed` `kdump-tools.cfg`).

3. Confirm `kdump-tools.cfg` is still exactly:

```
GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT crashkernel=512M,high"
```

4. Rebuild GRUB cfg.

OPERATOR-ONLY: `sudo update-grub`

5. Confirm the generated linux cmdline in `/boot/grub/grub.cfg` for the
   default kernel contains **one** `crashkernel=` token
   (`crashkernel=512M,high`) and does not contain a bare
   `crashkernel=512M`.

6. Reboot (this is the downtime).

OPERATOR-ONLY: `sudo reboot`

7. After boot, run the verify commands in the next section. Then
   `kdump-config show` / `systemctl status kdump-tools` as needed so
   `kexec_crash_loaded` is `1`. If it is still `0` with a single
   `crashkernel=` on the cmdline, that is a kdump-tools load failure
   (still bd-bth), not another grub duplicate.

## Verify (criterion 5 — cmdline uniqueness + kexec armed)

Must hold after reboot, on the live kernel:

```
tr ' ' '\n' </proc/cmdline | grep crashkernel
```

Exactly **one** line. Expected: `crashkernel=512M,high`. Two lines
(`512M` and `512M,high`) or three (8rx2 applied) = FAIL. Zero lines =
FAIL (crash kernel not reserved).

```
cat /sys/kernel/kexec_crash_loaded
```

Must be `1`. `0` means panics will hang again.

Vmcore proof remains on bd-bth (controlled dump into `/var/crash`).
This procedure only clears the duplicate that keeps kexec unloaded.
Do not close `ez-gh-actions-fkbm` on unique cmdline alone.

## Rollback

If the box will not boot, or boots with zero `crashkernel=`, or
nvidia firmware policy regresses:

1. From GRUB recovery or a live session, restore the grub backup from
   step 1 (puts `crashkernel=512M` back on line 10). `kdump-tools.cfg`
   should not have changed; restore its backup only if it was edited
   by mistake.

OPERATOR-ONLY: `sudo cp -a /etc/default/grub.bak.kdump-dedup-<timestamp> /etc/default/grub`

2. Rebuild GRUB and reboot.

OPERATOR-ONLY: `sudo update-grub`

OPERATOR-ONLY: `sudo reboot`

Rollback returns the pre-window duplicate (`512M` + `512M,high`) and
`kexec_crash_loaded=0`. That is the known-bad but previously booting
state. Do not "fix" rollback by running the 8rx2 one-liner.

## Session authorization

**Not authorized this session.** No sudo, no `sed` on `/etc`, no
`update-grub`, no reboot, no 8rx2 one-liner, no
`configure-grub-kdump.sh`. Documentation and bead pointers only.
Execute only in a scheduled maint window under bd-bth.
