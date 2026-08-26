#!/usr/bin/env bash
# Print the supported operator sequence for the kdump/panic gate.
set -euo pipefail

cat <<'REMEDIATE'
[FAIL] Crash capture is not active on this host. The project's stated goal
       (physical-host availability) cannot be proven without it.

REPRODUCIBLE REMEDIATION:
    1. Review docs/notes/kdump-dedup-maint-window.md
    2. APPLY_PANIC_STOP_DRY_RUN=1 bash scripts/host/apply-cfs-nohz-panic-stop.sh
    3. sudo -v && bash scripts/host/apply-cfs-nohz-panic-stop.sh
    4. sudo reboot
    5. ./docs/verify-exit-criteria.sh

The apply script removes crashkernel tokens from /etc/default/grub only after
backing it up, requires exactly one distro-owned token in
/etc/default/grub.d/kdump-tools.cfg, runs update-grub, and never reboots.

OPERATIONAL PROOF (separate from this gate's check):
    After reboot, first run scripts/host/crash-capture-verify.sh --dry-run.
    A separately authorized controlled --force run must produce a vmcore in
    /var/crash; then verify it with --verify <stamp> --no-trigger.
REMEDIATE
