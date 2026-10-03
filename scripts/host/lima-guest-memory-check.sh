#!/usr/bin/env bash
# Fail closed before the host-docker QEMU ceiling (4608M/5G) is applied: the
# colima Lima guest must be configured AND running at <= 4 GiB, otherwise a
# 5G cap on an 8 GiB guest would OOM-kill QEMU (bead ez-gh-actions-154k).
#
# Configured size: `memory:` in the lima.yaml lima-vm@colima starts from.
# Running size: the `-m <MiB>` of the colima QEMU process (the one whose
# cmdline references the instance directory). `limactl list --json` .memory
# mirrors lima.yaml, not the running VM, so limactl is only used for status.
# Any state this cannot establish (failed limactl query, Running VM without a
# readable QEMU) refuses. No instance directory and no colima QEMU passes.
# LIMACTL / LIMA_YAML / LIMA_PROC_ROOT override the sources for fixtures.
set -euo pipefail

LIMIT=4294967296
LIMACTL="${LIMACTL:-limactl}"
LIMA_YAML="${LIMA_YAML:-${LIMA_HOME:-${HOME}/.lima}/colima/lima.yaml}"
INSTANCE_DIR="$(dirname "$LIMA_YAML")"
PROC_ROOT="${LIMA_PROC_ROOT:-/proc}"

refuse() {
  echo "FAIL lima guest memory $1 > 4GiB: resize the guest and restart the VM once before lowering the QEMU ceiling" >&2
  exit 1
}
unknown() {
  echo "FAIL lima guest memory unknown ($1): cannot prove the colima guest runs at <= 4GiB; not lowering the QEMU ceiling" >&2
  exit 1
}

yaml_to_bytes() { # 4GiB | 4096MiB | "4GiB"
  local v="${1//\"/}"
  v="${v//\'/}"
  case "$v" in
    *GiB) [[ "${v%GiB}" =~ ^[0-9]+$ ]] && echo $(( ${v%GiB} * 1073741824 )) ;;
    *MiB) [[ "${v%MiB}" =~ ^[0-9]+$ ]] && echo $(( ${v%MiB} * 1048576 )) ;;
    *) [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" ;;
  esac
}
qemu_m_to_bytes() { # QEMU -m: 8192 (MiB) | 8192M | 8G | size=8192M[,...]
  local v="${1#size=}"
  v="${v%%,*}"
  case "$v" in
    *G) [[ "${v%G}" =~ ^[0-9]+$ ]] && echo $(( ${v%G} * 1073741824 )) ;;
    *M) [[ "${v%M}" =~ ^[0-9]+$ ]] && echo $(( ${v%M} * 1048576 )) ;;
    *) [[ "$v" =~ ^[0-9]+$ ]] && echo $(( v * 1048576 )) ;;
  esac
}

# Running colima QEMU processes (cmdline references the instance directory).
running=()
for comm in "$PROC_ROOT"/[0-9]*/comm; do
  [ -r "$comm" ] || continue
  case "$(cat "$comm" 2>/dev/null)" in qemu-system-*) ;; *) continue ;; esac
  cmdline_file="${comm%/comm}/cmdline"
  mapfile -d '' args < "$cmdline_file" 2>/dev/null || continue
  case " ${args[*]} " in *"${INSTANCE_DIR}/"*) ;; *) continue ;; esac
  mem=""
  for ((i = 0; i < ${#args[@]}; i++)); do
    if [ "${args[$i]}" = -m ] && [ $((i + 1)) -lt ${#args[@]} ]; then
      mem="$(qemu_m_to_bytes "${args[$((i + 1))]}")"
    fi
  done
  [ -n "$mem" ] || unknown "colima QEMU ${comm%/comm} has no parseable -m"
  running+=("$mem")
done

if [ ! -e "$INSTANCE_DIR" ] && [ "${#running[@]}" -eq 0 ]; then
  echo "OK: no colima instance (${INSTANCE_DIR} absent, no colima QEMU running)"
  exit 0
fi

values=()
if [ -f "$LIMA_YAML" ]; then
  yaml_mem="$(awk '/^memory:/ {print $2; exit}' "$LIMA_YAML")"
  [ -n "$yaml_mem" ] || unknown "${LIMA_YAML} has no memory: line"
  bytes="$(yaml_to_bytes "$yaml_mem")"
  [ -n "$bytes" ] || unknown "unparseable memory: ${yaml_mem} in ${LIMA_YAML}"
  values+=("$bytes")
fi

command -v "$LIMACTL" >/dev/null 2>&1 || unknown "limactl not found for instance ${INSTANCE_DIR}"
status="$("$LIMACTL" list --json colima 2>/dev/null \
  | python3 -c 'import json,sys
rows = [json.loads(l) for l in sys.stdin if l.strip()]
print(rows[0]["status"] if len(rows) == 1 and rows[0].get("status") else "")' 2>/dev/null)" \
  || unknown "limactl list --json colima failed"
[ -n "$status" ] || unknown "limactl list --json colima returned no status"
if [ "$status" = Running ] && [ "${#running[@]}" -eq 0 ]; then
  unknown "colima is Running but no colima QEMU process was found"
fi
values+=("${running[@]}")

for value in "${values[@]}"; do
  [ "$value" -le "$LIMIT" ] || refuse "$value"
done
echo "OK: lima guest memory <= 4GiB (status=${status}; ${values[*]})"
