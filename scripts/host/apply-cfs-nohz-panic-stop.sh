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

# --- this boot: stop 6-hour hangs ---
run_root "$SYSCTL_BIN" -w kernel.panic=10 kernel.panic_on_oops=1
run_root mkdir -p "$(dirname "$sysctl_dest")"
run_root install -m 0644 "$SYSCTL_SRC" "$sysctl_dest"

# --- next boot: disable NOHZ idle balancing (the Oops path) ---
run_root mkdir -p "$grub_dropin_dir"
run_root install -m 0644 "$GRUB_SRC" "$grub_dropin_dest"

# --- kdump: one effective crashkernel= source only ---
[ -f "$grub" ] || fail "missing $grub"
[ -f "$kdump_source" ] || fail "missing distro kdump source $kdump_source"
source_copy="$(mktemp)"
rewritten="$(mktemp)"
backup=""
grub_committed=0
cleanup() {
  rc=$?
  trap - EXIT
  if [ -n "$backup" ] && [ "$grub_committed" -ne 1 ]; then
    run_root cp -a "$backup" "$grub" \
      || echo "FAIL: could not restore $grub from $backup" >&2
  fi
  rm -f "$source_copy" "$rewritten"
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

ts="$(date +%Y%m%d%H%M%S)"
backup="${grub}.bak.kdump-dedup-${ts}"
run_root cp -a "$grub" "$backup"
run_root cp "$rewritten" "$grub"

count_crashkernel_tokens() {
  awk -F'"' '
    /^GRUB_CMDLINE_LINUX(_DEFAULT)?="/ {
      count = split($2, tokens, /[[:space:]]+/)
      for (i = 1; i <= count; i++) if (tokens[i] ~ /^crashkernel=/) found++
    }
    END { print found + 0 }
  ' "$@"
}

mapfile -t grub_sources < <(find "$grub_dropin_dir" -maxdepth 1 -type f -name '*.cfg' -print | sort)
grub_sources=("$grub" "${grub_sources[@]}")
all_crashkernels="$(count_crashkernel_tokens "${grub_sources[@]}")"
kdump_crashkernels="$(count_crashkernel_tokens "$kdump_source")"
if [ "$all_crashkernels" -ne 1 ] || [ "$kdump_crashkernels" -ne 1 ]; then
  fail "expected exactly one crashkernel token, owned by $kdump_source; found total=$all_crashkernels kdump-tools=$kdump_crashkernels"
fi

run_root "$UPDATE_GRUB_BIN"
grub_committed=1
echo "PASS: panic=10 live; nohz=off + panic=10 in GRUB. Reboot to stop the Oops path."
echo "Verify now:  sysctl kernel.panic kernel.panic_on_oops"
echo "Verify next: tr ' ' '\\n' </proc/cmdline | grep -E 'nohz|panic|crashkernel'"
