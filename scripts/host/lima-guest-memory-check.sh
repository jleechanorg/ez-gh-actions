#!/usr/bin/env bash
# Fail closed before the host-docker QEMU ceiling (4608M/5G) is applied: the
# colima Lima guest must be configured AND running at <= 4 GiB, otherwise a
# 5G cap on an 8 GiB guest would OOM-kill QEMU (bead ez-gh-actions-154k).
# Reads `limactl list --json colima` (.memory, bytes) and the lima.yaml
# lima-vm@colima starts from. No colima instance at all passes (nothing to cap).
# LIMACTL / LIMA_YAML override both sources for fixtures.
set -euo pipefail

LIMIT=4294967296
LIMACTL="${LIMACTL:-limactl}"
LIMA_YAML="${LIMA_YAML:-${LIMA_HOME:-${HOME}/.lima}/colima/lima.yaml}"

to_bytes() { # 4GiB | 4096MiB | "4GiB" | 4294967296
  local v="${1//\"/}"
  v="${v//\'/}"
  case "$v" in
    *GiB) echo $(( ${v%GiB} * 1073741824 )) ;;
    *MiB) echo $(( ${v%MiB} * 1048576 )) ;;
    *[!0-9]*|'') echo invalid ;;
    *) echo "$v" ;;
  esac
}

values=()
if [ -f "$LIMA_YAML" ]; then
  yaml_mem="$(awk '/^memory:/ {print $2; exit}' "$LIMA_YAML")"
  [ -z "$yaml_mem" ] || values+=("$(to_bytes "$yaml_mem")")
fi
if command -v "$LIMACTL" >/dev/null 2>&1; then
  live_mem="$("$LIMACTL" list --json colima 2>/dev/null \
    | python3 -c 'import json,sys
for line in sys.stdin:
    line = line.strip()
    if line:
        print(json.loads(line).get("memory", "")); break' 2>/dev/null || true)"
  [ -z "$live_mem" ] || values+=("$(to_bytes "$live_mem")")
fi
for value in "${values[@]}"; do
  if [ "$value" = invalid ] || [ "$value" -gt "$LIMIT" ]; then
    echo "FAIL lima guest memory ${value} > 4GiB: resize the guest and restart the VM once before lowering the QEMU ceiling" >&2
    exit 1
  fi
done
echo "OK: lima guest memory <= 4GiB (${values[*]:-no colima instance})"
