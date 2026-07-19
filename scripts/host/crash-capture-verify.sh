#!/usr/bin/env bash
# scripts/host/crash-capture-verify.sh
# LABELED: human-gated (triggers a controlled kernel panic via sysrq-c)
#
# DO NOT auto-invoke. The operator must run this script manually AFTER:
#   (a) sudo bash scripts/host/configure-grub-kdump.sh && sudo reboot
#   (b) confirming kexec_crash_loaded == 1 (verifier Gate 3 will pass)
#
# Recovery flow:
#   1. scripts/host/crash-capture-verify.sh --dry-run         # confirm preconditions + print stamp
#   2. scripts/host/crash-capture-verify.sh --force           # panic; reboots via kdump
#   3. After reboot: scripts/host/crash-capture-verify.sh --verify <stamp> --no-trigger
#
# Part of bead ez-gh-actions-gam1 (lane K — crash-capture verification harness).

set -euo pipefail

# -------- argument parsing -----------------------------------------------------

DRY_RUN=0
DO_FORCE=0
DO_TRIGGER=1
VERIFY_STAMP=""

usage() {
    cat <<EOF
Usage: $0 [--dry-run | --force | --verify <stamp> --no-trigger]

Modes:
  --dry-run                  Check preconditions, print the trigger stamp,
                             do NOT panic the host.
  --force                    Trigger a controlled kernel panic via
                             /proc/sysrq-trigger. Reboots via the loaded
                             crash kernel. Prints the stamp first so the
                             operator can copy it for the post-reboot
                             --verify step.
  --verify <stamp> --no-trigger
                             Post-reboot check: locate vmcore in
                             /var/crash/<stamp>/ and report size.
                             Exits 0 on non-zero vmcore, exits 4 on missing.

Safety:
  --force is required to panic. Without --force, the trigger path refuses
  to run. --no-trigger is mandatory on the --verify path so a re-run after
  reboot cannot accidentally panic again.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            DO_TRIGGER=0
            ;;
        --force)
            DO_FORCE=1
            ;;
        --no-trigger)
            DO_TRIGGER=0
            ;;
        --verify)
            shift
            if [ "$#" -lt 1 ]; then
                echo "Error: --verify requires a stamp argument." >&2
                usage >&2
                exit 64
            fi
            VERIFY_STAMP="$1"
            DO_TRIGGER=0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: unknown argument: $1" >&2
            usage >&2
            exit 64
            ;;
    esac
    shift
done

STAMP=$(date -u +%Y%m%d%H%M%S)

# -------- precondition checks -------------------------------------------------

check_kexec_loaded() {
    local f="/sys/kernel/kexec_crash_loaded"
    if [ ! -f "$f" ]; then
        echo "Error: $f not found. kexec/kdump is not supported on this kernel." >&2
        exit 2
    fi
    local v
    v=$(cat "$f" 2>/dev/null || echo 0)
    if [ "$v" != "1" ]; then
        cat >&2 <<EOF
Error: kdump is NOT armed (kexec_crash_loaded=$v).
This means the running kernel does NOT have a crash kernel loaded.
Most likely cause: scripts/host/configure-grub-kdump.sh was run but the
host has not been rebooted into the new GRUB config (crashkernel=2G).

Remediation:
  1. Confirm configure-grub-kdump.sh ran cleanly:
     grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub
     # expect to see crashkernel=2G
  2. Reboot: sudo reboot
  3. After reboot, re-run this script with --dry-run.
EOF
        exit 2
    fi
}

check_var_crash() {
    local d="/var/crash"
    if [ ! -d "$d" ]; then
        cat >&2 <<EOF
Error: $d does not exist.
kdump-tools writes vmcore here on panic. Without this directory, no
vmcore can be captured.

Remediation:
  sudo mkdir -p $d
  sudo chmod 755 $d
  # /var/crash must be on a supported filesystem (ext4, xfs, btrfs).
  # If rootfs is btrfs/zfs, see kdump.conf(5) and consider an
  # explicit path on a separate ext4 filesystem.
EOF
        exit 3
    fi
    if [ ! -w "$d" ]; then
        echo "Error: $d exists but is not writable by uid=$(id -u). kdump needs write access here." >&2
        exit 3
    fi
}

# -------- verify path ----------------------------------------------------------

do_verify() {
    local stamp="$1"
    local d="/var/crash/${stamp}"
    local vmcore="${d}/vmcore"
    local json=""
    # kdump-tools in newer releases writes a *.json alongside vmcore.
    if [ -f "${d}.json" ]; then
        json="${d}.json"
    elif ls "${d}"/*.json >/dev/null 2>&1; then
        json=$(ls -1 "${d}"/*.json | head -n 1)
    fi

    echo "=== crash-capture-verify --verify ============================"
    echo "stamp:           $stamp"
    echo "expected dir:    $d"
    echo "vmcore:          $vmcore"
    if [ -n "$json" ]; then
        echo "metadata json:   $json"
    fi
    echo "=============================================================="

    if [ ! -e "$vmcore" ]; then
        # Fall back: dump landed under a slightly different name (kernel
        # convention is sometimes vmcore or vmcore.incomplete, or the
        # directory has a different timestamp suffix).
        local latest
        latest=$(ls -1dt /var/crash/*/ 2>/dev/null | head -n 1 || true)
        if [ -n "$latest" ] && [ -f "${latest}vmcore" ]; then
            echo "Note: vmcore not at expected stamp dir; latest found at ${latest}"
            vmcore="${latest}vmcore"
            d="${latest%/}"
        else
            cat >&2 <<EOF
Error (exit 4): no vmcore at $vmcore and no recent /var/crash/*/vmcore.

The panic did NOT result in a captured core. Remediation:
  1. systemctl status kdump-tools.service    # confirm running + enabled
  2. cat /etc/default/kdump-tools            # confirm USE_KDUMP=1
  3. journalctl -b -u kdump-tools.service    # last boot's kdump log
  4. Confirm /var/crash is on ext4/xfs/btrfs (NOT 9p, NFS, tmpfs).
  5. journalctl -t crash-capture-verify      # confirm the panic was tagged here
  6. dmesg | grep -iE 'crash|kexec'          # confirm crash kernel loaded
Re-run: $0 --verify $stamp --no-trigger
EOF
            exit 4
        fi
    fi

    if [ ! -s "$vmcore" ]; then
        echo "Error (exit 4): vmcore exists but is empty (0 bytes) at $vmcore." >&2
        exit 4
    fi

    local size
    size=$(stat -c '%s' "$vmcore")
    local size_h
    size_h=$(numfmt --to=iec --suffix=B "$size" 2>/dev/null || echo "${size} bytes")
    echo "PASS: vmcore captured at $vmcore (size=$size_h)."

    if [ -n "$json" ] && [ -f "$json" ]; then
        echo "PASS: metadata JSON present at $json."
    else
        echo "Note: no *.json metadata file alongside vmcore (older kdump-tools release or missed copy)."
    fi

    echo "GREEN: crash capture verified. Bead ez-gh-actions-gam1 may advance once doctor-check is also green."
    exit 0
}

# -------- main -----------------------------------------------------------------

case "$DO_TRIGGER$DO_FORCE$DRY_RUN" in
    110)  # --force
        check_kexec_loaded
        check_var_crash
        cat <<EOF
[TRIGGER] STAMP=$STAMP  (copy this for the post-reboot --verify step)
[WARN] This script triggers a CONTROLLED kernel panic on this host using
       /proc/sysrq-trigger. The system will reboot via kdump's loaded
       crash kernel. After reboot, run this script again with
       --verify $STAMP --no-trigger to confirm a vmcore landed.
EOF
        # Best-effort journal breadcrumb so post-reboot searches find us.
        if command -v systemd-cat >/dev/null 2>&1; then
            echo "crash-capture-verify triggered panic at $STAMP (kexec_crash_loaded=1, /var/crash writable)" | systemd-cat -t crash-capture-verify || true
        elif command -v logger >/dev/null 2>&1; then
            echo "crash-capture-verify triggered panic at $STAMP" | logger -t crash-capture-verify || true
        fi
        sync
        echo c > /proc/sysrq-trigger
        # Unreachable: the kernel has now panic'd and the script's process is gone.
        ;;
    100)  # bare invocation, no --force, no --dry-run, no --verify
        echo "Refusing to panic without --force. Use --dry-run to check preconditions." >&2
        usage >&2
        exit 64
        ;;
    010)  # --dry-run
        check_kexec_loaded
        check_var_crash
        echo "[DRY-RUN] STAMP would be $STAMP"
        echo "[DRY-RUN] kexec_crash_loaded=1, /var/crash writable. Panicking now would:"
        echo "          - write journal tag 'crash-capture-verify' at $STAMP"
        echo "          - sync"
        echo "          - echo c > /proc/sysrq-trigger"
        echo "[DRY-RUN] After reboot: $0 --verify $STAMP --no-trigger"
        exit 0
        ;;
    001)  # --verify <stamp> --no-trigger
        if [ -z "$VERIFY_STAMP" ]; then
            echo "Error: --verify requires a stamp value." >&2
            usage >&2
            exit 64
        fi
        do_verify "$VERIFY_STAMP"
        ;;
    *)
        echo "Error: mutually-exclusive flags combined. Use --dry-run, --force, or --verify." >&2
        usage >&2
        exit 64
        ;;
esac
