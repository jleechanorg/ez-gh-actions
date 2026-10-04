#!/usr/bin/env bash
# Reject a configured or running Colima guest above 8 GiB before applying the
# host-docker 10 GiB QEMU ceiling. The ceiling reserves QEMU overhead above
# the guest size.
#
# Configured size: `memory:` in the lima.yaml lima-vm@colima starts from.
# Running size: the `-m <MiB>` of the colima QEMU process (the one whose
# cmdline references the instance directory). `limactl list --json` .memory
# mirrors lima.yaml, not the running VM: it is validated as a third
# (configured) source, and limactl's status decides whether a QEMU must exist.
# Any state this cannot establish (failed limactl query, absent/malformed
# .memory, missing lima.yaml, Running VM without a readable QEMU, unparseable
# size) refuses with a diagnostic. No instance directory and no colima QEMU
# passes.
# LIMACTL / LIMA_YAML / LIMA_PROC_ROOT override the sources for fixtures.
set -euo pipefail

LIMIT=8589934592
LIMACTL="${LIMACTL:-limactl}"
LIMA_YAML="${LIMA_YAML:-${LIMA_HOME:-${HOME}/.lima}/colima/lima.yaml}"
INSTANCE_DIR="$(dirname "$LIMA_YAML")"
PROC_ROOT="${LIMA_PROC_ROOT:-/proc}"

refuse() {
  echo "FAIL lima guest memory $1 > 8GiB: resize the guest and restart the VM once before lowering the QEMU ceiling" >&2
  exit 1
}
unknown() {
  echo "FAIL lima guest memory unknown ($1): cannot prove the colima guest runs at <= 8GiB; not lowering the QEMU ceiling" >&2
  exit 1
}

yaml_to_bytes() { # 8GiB | 4096MiB | "8GiB"
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
      mem="$(qemu_m_to_bytes "${args[$((i + 1))]}")" || mem=""
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
[ -f "$LIMA_YAML" ] || unknown "instance ${INSTANCE_DIR} exists but ${LIMA_YAML} is missing"
yaml_mem="$(awk '/^memory:/ {print $2; exit}' "$LIMA_YAML")"
[ -n "$yaml_mem" ] || unknown "${LIMA_YAML} has no memory: line"
bytes="$(yaml_to_bytes "$yaml_mem")" || bytes=""
[ -n "$bytes" ] || unknown "unparseable memory: ${yaml_mem} in ${LIMA_YAML}"
values+=("$bytes")

command -v "$LIMACTL" >/dev/null 2>&1 || unknown "limactl not found for instance ${INSTANCE_DIR}"
command -v python3 >/dev/null 2>&1 || unknown "python3 not found; cannot parse limactl list --json"
# Lima's concrete states include Uninitialized, Installing, Broken, Stopped,
# and Running. Only exact Stopped can lack a QEMU process; exact Running must
# have one. Parse and validate both fields in Python so shell word splitting
# cannot turn an otherwise unsupported status such as "Stopped " into Stopped.
limactl_out="$("$LIMACTL" list --json colima 2>/dev/null)" || unknown "limactl list --json colima failed"
limactl_fields="$(python3 -c 'import json,sys
try:
    rows = [json.loads(line) for line in sys.stdin if line.strip()]
except (json.JSONDecodeError, TypeError):
    raise SystemExit(1)
if len(rows) != 1 or not isinstance(rows[0], dict):
    raise SystemExit(1)
status = rows[0].get("status")
mem = rows[0].get("memory")
if type(status) is not str or status not in ("Stopped", "Running"):
    raise SystemExit(1)
if type(mem) is not int or mem <= 0:
    raise SystemExit(1)
print(f"{status}|{mem}")' <<<"$limactl_out")" \
  || unknown "limactl list --json colima has unsupported status or invalid .memory"
IFS='|' read -r status limactl_mem extra <<<"$limactl_fields"
[ -n "${status:-}" ] && [ -n "${limactl_mem:-}" ] && [ -z "${extra:-}" ] \
  || unknown "limactl list --json colima has malformed validated fields"
values+=("$limactl_mem")
if [ "$status" = Running ] && [ "${#running[@]}" -eq 0 ]; then
  unknown "colima is Running but no colima QEMU process was found"
fi
values+=("${running[@]}")

for value in "${values[@]}"; do
  [ "$value" -le "$LIMIT" ] || refuse "$value"
done
echo "OK: lima guest memory <= 8GiB (status=${status}; ${values[*]})"
