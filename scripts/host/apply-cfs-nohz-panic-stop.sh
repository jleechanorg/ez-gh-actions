#!/usr/bin/env bash
# Stop Jeff-Ubuntu CFS/nohz NX panics hanging the box.
# 1) NOW (no reboot): kernel.panic=10 so the next Oops reboots in 10s
# 2) NEXT BOOT: nohz=off (avoid the buggy idle-balance path) + panic=10
# 3) kdump: remove every crashkernel token from /etc/default/grub and retain
#    exactly one distro-owned token in grub.d/kdump-tools.cfg (bd-bth)
# Does NOT reboot. Does NOT run the ez-gh-actions-8rx2 sed.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SYSCTL_SRC="${REPO_ROOT}/config/sysctl.d/99-ezgha-oops-reboot.conf"
GRUB_SRC="${REPO_ROOT}/config/grub.d/zz-ezgha-nohz-panic.cfg"
ROOT_PREFIX="${APPLY_PANIC_STOP_ROOT:-}"
SYSCTL_BIN="${APPLY_PANIC_STOP_SYSCTL:-sysctl}"
UPDATE_GRUB_BIN="${APPLY_PANIC_STOP_UPDATE_GRUB:-update-grub}"
fail() { echo "FAIL: $*" >&2; exit 1; }
need_sudo() { echo "NEED_SUDO: $*" >&2; exit 2; }
root_path() { printf '%s%s' "$ROOT_PREFIX" "$1"; }

[ -f "$SYSCTL_SRC" ] || fail "missing $SYSCTL_SRC"
[ -f "$GRUB_SRC" ] || fail "missing $GRUB_SRC"
grep -q '^kernel.panic = 10$' "$SYSCTL_SRC" || fail "$SYSCTL_SRC missing kernel.panic = 10"
grep -q 'nohz=off' "$GRUB_SRC" || fail "$GRUB_SRC missing nohz=off"

if [ "${APPLY_PANIC_STOP_DRY_RUN:-0}" = "1" ]; then
  echo "DRY_RUN: sysctl -w kernel.panic=10 kernel.panic_on_oops=1"
  echo "DRY_RUN: install $SYSCTL_SRC -> /etc/sysctl.d/99-ezgha-oops-reboot.conf"
  echo "DRY_RUN: install GRUB nohz=off panic=10 -> /etc/default/grub.d/zz-ezgha-nohz-panic.cfg"
  echo "DRY_RUN: remove every crashkernel=* token from /etc/default/grub; require exactly one in grub.d/kdump-tools.cfg; update-grub"
  echo "DRY_RUN: does not reboot; does not run 8rx2 sed"
  exit 0
fi

if [ -n "${APPLY_PANIC_STOP_ROOT_CMD:-}" ]; then
  ROOT_CMD=("$APPLY_PANIC_STOP_ROOT_CMD")
elif [ -n "$ROOT_PREFIX" ]; then
  ROOT_CMD=()
else
  sudo -n true 2>/dev/null || need_sudo "sudo -n required: sysctl kernel.panic=10 (this boot) and grub nohz=off (next boot)"
  ROOT_CMD=(sudo -n)
fi
run_root() { "${ROOT_CMD[@]}" "$@"; }

sysctl_dest="$(root_path /etc/sysctl.d/99-ezgha-oops-reboot.conf)"
grub_dropin_dir="$(root_path /etc/default/grub.d)"
grub_dropin_dest="${grub_dropin_dir}/zz-ezgha-nohz-panic.cfg"
grub="$(root_path /etc/default/grub)"
kdump_source="${grub_dropin_dir}/kdump-tools.cfg"
generated_grub="$(root_path "${APPLY_PANIC_STOP_GENERATED_GRUB:-/boot/grub/grub.cfg}")"

# --- preflight all inputs before changing live or persistent state ---
[ -f "$grub" ] || fail "missing $grub"
[ -f "$kdump_source" ] || fail "missing distro kdump source $kdump_source"
if [ ! -f "$generated_grub" ] || [ -L "$generated_grub" ]; then
  fail "missing or unsafe generated GRUB artifact $generated_grub"
fi
source_copy="$(mktemp)"
rewritten="$(mktemp)"
backup=""
sysctl_backup="$(mktemp)"
grub_dropin_backup="$(mktemp)"
generated_grub_backup="$(mktemp)"
sysctl_had=0
grub_dropin_had=0
grub_had=0
transaction_started=0
transaction_committed=0
sysctl_attempted=0
update_grub_attempted=0
cleanup() {
  rc=$?
  trap - EXIT
  set +e
  if [ "$transaction_started" -eq 1 ] && [ "$transaction_committed" -ne 1 ]; then
    if [ "$grub_had" -eq 1 ]; then
      run_root cp -a "$backup" "$grub" \
        || echo "FAIL: could not restore $grub from $backup" >&2
    else
      run_root rm -f "$grub"
    fi
    if [ "$sysctl_had" -eq 1 ]; then
      run_root cp -a "$sysctl_backup" "$sysctl_dest" \
        || echo "FAIL: could not restore $sysctl_dest" >&2
    else
      run_root rm -f "$sysctl_dest"
    fi
    if [ "$grub_dropin_had" -eq 1 ]; then
      run_root cp -a "$grub_dropin_backup" "$grub_dropin_dest" \
        || echo "FAIL: could not restore $grub_dropin_dest" >&2
    else
      run_root rm -f "$grub_dropin_dest"
    fi
    if [ "$update_grub_attempted" -eq 1 ]; then
      run_root "$UPDATE_GRUB_BIN" \
        || echo "FAIL: could not regenerate GRUB from restored sources" >&2
    fi
    # The updater may partially mutate its generated artifact even when it
    # exits non-zero. Restore the exact pre-transaction bytes after any retry;
    # this is the integrity guarantee if rollback regeneration also fails.
    run_root cp -a "$generated_grub_backup" "$generated_grub" \
      || echo "FAIL: could not restore generated GRUB artifact $generated_grub" >&2
    if [ "$sysctl_attempted" -eq 1 ]; then
      run_root "$SYSCTL_BIN" -w \
        "kernel.panic=$panic_before" "kernel.panic_on_oops=$panic_on_oops_before" \
        || echo "FAIL: could not restore live panic sysctl values" >&2
    fi
  fi
  if [ "$transaction_committed" -ne 1 ] && [ -n "$backup" ]; then
    run_root rm -f "$backup"
  fi
  rm -f "$source_copy" "$rewritten" "$sysctl_backup" "$grub_dropin_backup" "$generated_grub_backup"
  exit "$rc"
}
trap cleanup EXIT
run_root cat "$grub" > "$source_copy"
awk '
  /^GRUB_CMDLINE_LINUX(_DEFAULT)?="[^"]*"[[:space:]]*$/ {
    eq = index($0, "=")
    key = substr($0, 1, eq)
    value = substr($0, eq + 2, length($0) - eq - 2)
    count = split(value, tokens, /[[:space:]]+/)
    output = ""
    for (i = 1; i <= count; i++) {
      if (tokens[i] == "" || tokens[i] ~ /^crashkernel=/) continue
      output = output (output == "" ? "" : " ") tokens[i]
    }
    print key "\"" output "\""
    next
  }
  /^GRUB_CMDLINE_LINUX(_DEFAULT)?=/ {
    print "FAIL: malformed GRUB command-line assignment: " $0 > "/dev/stderr"
    failed = 1
    next
  }
  { print }
  END { if (failed) exit 1 }
' "$source_copy" > "$rewritten" || fail "could not parse $grub safely"

count_crashkernel_tokens() {
  awk -F'"' '
    /^GRUB_CMDLINE_LINUX(_DEFAULT)?="/ {
      count = split($2, tokens, /[[:space:]]+/)
      for (i = 1; i <= count; i++) if (tokens[i] ~ /^crashkernel=/) found++
    }
    END { print found + 0 }
  ' "$@"
}

mapfile -t grub_dropins < <(find "$grub_dropin_dir" -maxdepth 1 -type f -name '*.cfg' -print | sort)
# Count against the prospective rewritten main file, not the still-unchanged
# live file.  This proves the transaction will leave exactly one effective
# crashkernel source before any target is mutated.
all_crashkernels="$(count_crashkernel_tokens "$rewritten" "${grub_dropins[@]}")"
kdump_crashkernels="$(count_crashkernel_tokens "$kdump_source")"
if [ "$all_crashkernels" -ne 1 ] || [ "$kdump_crashkernels" -ne 1 ]; then
  fail "expected exactly one crashkernel token, owned by $kdump_source; found total=$all_crashkernels kdump-tools=$kdump_crashkernels"
fi

# Read the live values before any mutation so every failure path can restore
# them.  Empty/non-numeric output indicates an unsafe or unusable sysctl tool.
panic_before="$(run_root "$SYSCTL_BIN" -n kernel.panic)" \
  || fail "could not read live kernel.panic"
panic_on_oops_before="$(run_root "$SYSCTL_BIN" -n kernel.panic_on_oops)" \
  || fail "could not read live kernel.panic_on_oops"
[[ "$panic_before" =~ ^[0-9]+$ ]] || fail "invalid live kernel.panic value: $panic_before"
[[ "$panic_on_oops_before" =~ ^[0-9]+$ ]] \
  || fail "invalid live kernel.panic_on_oops value: $panic_on_oops_before"

# Snapshot every target before starting the transaction.  Missing targets are
# represented by a flag so rollback removes files created by a partial apply.
if [ -e "$grub" ]; then
  ts="$(date +%Y%m%d%H%M%S)"
  backup="${grub}.bak.kdump-dedup-${ts}"
  run_root cp -a "$grub" "$backup"
  grub_had=1
fi
if [ -e "$sysctl_dest" ]; then
  run_root cp -a "$sysctl_dest" "$sysctl_backup"
  sysctl_had=1
fi
if [ -e "$grub_dropin_dest" ]; then
  run_root cp -a "$grub_dropin_dest" "$grub_dropin_backup"
  grub_dropin_had=1
fi
run_root cp -a "$generated_grub" "$generated_grub_backup" \
  || fail "could not snapshot generated GRUB artifact $generated_grub"

transaction_started=1
run_root mkdir -p "$(dirname "$sysctl_dest")"
run_root install -m 0644 "$SYSCTL_SRC" "$sysctl_dest"

# --- next boot: disable NOHZ idle balancing (the Oops path) ---
run_root mkdir -p "$grub_dropin_dir"
run_root install -m 0644 "$GRUB_SRC" "$grub_dropin_dest"
run_root cp "$rewritten" "$grub"

# Regeneration is part of the transaction.  A non-zero exit restores the
# original GRUB, drop-ins, and live sysctl values in cleanup().
update_grub_attempted=1
run_root "$UPDATE_GRUB_BIN"

# --- this boot: stop 6-hour hangs ---
sysctl_attempted=1
run_root "$SYSCTL_BIN" -w kernel.panic=10 kernel.panic_on_oops=1
transaction_committed=1
echo "PASS: panic=10 live; nohz=off + panic=10 in GRUB. Reboot to stop the Oops path."
echo "Verify now:  sysctl kernel.panic kernel.panic_on_oops"
printf '%s\n' "Verify next: tr ' ' '\\n' </proc/cmdline | grep -E 'nohz|panic|crashkernel'"
