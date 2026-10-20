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

PRINT_YAML=0
[ "${1:-}" != "--print-yaml" ] || PRINT_YAML=1
[ "$#" -le 1 ] || { echo "usage: $0 [--print-yaml]" >&2; exit 2; }
LIMIT=8589934592
LIMACTL="${LIMACTL:-limactl}"
PROC_ROOT="${LIMA_PROC_ROOT:-/proc}"

refuse() {
  echo "FAIL lima guest memory $1 > 8GiB: resize the guest and restart the VM once before lowering the QEMU ceiling" >&2
  exit 1
}
unknown() {
  echo "FAIL lima guest memory unknown ($1): cannot prove the colima guest runs at <= 8GiB; not lowering the QEMU ceiling" >&2
  exit 1
}

# Bind admission to the service whose QEMU limit will be changed, including
# nested cgroups. A caller-selected LIMA_HOME cannot hide another live guest.
CAPPED_UNIT_CGROUP=""
CAPPED_UNIT_CGROUP_MISSING=0
check_capped_instance() {
  local unit_cgroup cgroup_dir cgroup_files cgroup_file pid comm_file
  local -a args
  unit_cgroup="$(systemctl --user show -p ControlGroup --value -- lima-vm@colima.service)" \
    || unknown "cannot resolve capped unit cgroup"
  if [ -z "$unit_cgroup" ]; then
    [ -z "${INSTANCE_DIR:-}" ] && return 0
    CAPPED_UNIT_CGROUP_MISSING=1
    return 0
  fi
  case "$unit_cgroup" in
    /|*../*|*/..) unknown "invalid capped unit cgroup" ;;
    /*) ;;
    *) unknown "invalid capped unit cgroup" ;;
  esac
  CAPPED_UNIT_CGROUP="$unit_cgroup"
  cgroup_dir="${QEMU_CGROUP_ROOT:-/sys/fs/cgroup}${unit_cgroup}"
  [ -r "$cgroup_dir/cgroup.procs" ] || unknown "cannot read capped unit processes"
  cgroup_files="$(find "$cgroup_dir" -name cgroup.procs -type f -print)" \
    || unknown "cannot enumerate capped unit descendants"
  while IFS= read -r cgroup_file; do
    while IFS= read -r pid; do
      [[ "$pid" =~ ^[0-9]+$ ]] || unknown "invalid capped unit PID"
      [ -d "$PROC_ROOT/$pid" ] || continue
      comm_file="$PROC_ROOT/$pid/comm"
      [ -r "$comm_file" ] || unknown "cannot inspect capped unit PID $pid"
      case "$(cat "$comm_file")" in qemu-system-*) ;; *) continue ;; esac
      mapfile -d '' args < "$PROC_ROOT/$pid/cmdline" \
        || unknown "cannot inspect capped unit QEMU $pid"
      [ -n "${INSTANCE_DIR:-}" ] || unknown "capped unit QEMU has no resolved Lima instance"
      case " ${args[*]} " in
        *"${INSTANCE_DIR}/"*) ;;
        *) unknown "capped unit QEMU $pid belongs to a different Lima instance" ;;
      esac
    done < "$cgroup_file"
  done <<< "$cgroup_files"
}

# A QEMU discovered from /proc must be in the exact capped unit cgroup (or a
# descendant). The service can have an empty root cgroup while a process runs
# in a sibling; accepting that process would validate a ceiling on another
# service and leave the selected QEMU uncapped.
pid_in_capped_unit() {
  local pid="$1" rel cgroup_procs member
  if [ -z "$CAPPED_UNIT_CGROUP" ]; then
    [ "$CAPPED_UNIT_CGROUP_MISSING" -eq 0 ] \
      || unknown "capped unit has no cgroup"
    return 1
  fi
  [ -r "$PROC_ROOT/$pid/cgroup" ] \
    || unknown "cannot read QEMU $pid cgroup membership"
  rel="$(awk -F: '$1 == "0" {print $3; exit}' "$PROC_ROOT/$pid/cgroup")" \
    || unknown "cannot inspect QEMU $pid cgroup membership"
  case "$rel" in
    /|*../*|*/..) unknown "invalid QEMU $pid cgroup path" ;;
    /*) ;;
    *) unknown "invalid QEMU $pid cgroup path" ;;
  esac
  case "$rel" in
    "$CAPPED_UNIT_CGROUP"|"$CAPPED_UNIT_CGROUP"/*) ;;
    *) return 1 ;;
  esac
  cgroup_procs="${QEMU_CGROUP_ROOT:-/sys/fs/cgroup}${rel}/cgroup.procs"
  [ -r "$cgroup_procs" ] || unknown "cannot read QEMU $pid resolved cgroup membership"
  while IFS= read -r member; do
    [ "$member" = "$pid" ] && return 0
  done < "$cgroup_procs"
  return 1
}

check_print_yaml_qemu_membership() {
  local comm pid cmdline_file
  [ -n "${INSTANCE_DIR:-}" ] || return 0
  for comm in "$PROC_ROOT"/[0-9]*/comm; do
    [ -r "$comm" ] || continue
    case "$(cat "$comm" 2>/dev/null)" in qemu-system-*) ;; *) continue ;; esac
    pid="${comm%/comm}"
    pid="${pid##*/}"
    cmdline_file="$PROC_ROOT/$pid/cmdline"
    mapfile -d '' args < "$cmdline_file" 2>/dev/null || continue
    case " ${args[*]} " in *"${INSTANCE_DIR}/"*) ;; *) continue ;; esac
    if ! pid_in_capped_unit "$pid"; then
      unknown "colima QEMU $pid is outside capped unit ${CAPPED_UNIT_CGROUP:-<unresolved>}"
    fi
  done
}

if [ -n "${LIMA_YAML+x}" ]; then
  INSTANCE_DIR="$(dirname "$LIMA_YAML")"
else
  command -v "$LIMACTL" >/dev/null 2>&1 || { echo "FAIL lima guest memory unknown (limactl not found)" >&2; exit 1; }
  command -v python3 >/dev/null 2>&1 || { echo "FAIL lima guest memory unknown (python3 not found)" >&2; exit 1; }
  instance_dir="$("$LIMACTL" list --json colima 2>/dev/null | python3 -c 'import json,sys
try:
    rows=[json.loads(line) for line in sys.stdin if line.strip()]
    if len(rows) == 0:
        print("NO_INSTANCE")
        raise SystemExit(0)
    value=rows[0].get("dir") if len(rows) == 1 and isinstance(rows[0], dict) else None
    if type(value) is not str or not value.startswith("/") or value.rstrip("/") != value:
        raise ValueError
    print(value)
except (ValueError, json.JSONDecodeError, TypeError, IndexError):
    raise SystemExit(1)')"     || { echo "FAIL lima guest memory unknown (limactl list --json colima has no authoritative dir)" >&2; exit 1; }
  if [ "$instance_dir" = NO_INSTANCE ]; then
    INSTANCE_DIR=""
    check_capped_instance
    for comm in "$PROC_ROOT"/[0-9]*/comm; do
      [ -r "$comm" ] || continue
      case "$(cat "$comm" 2>/dev/null)" in qemu-system-*) ;; *) continue ;; esac
      [ "$(stat -c %u "${comm%/comm}")" = "$(id -u)" ] || continue
      cmdline_file="${comm%/comm}/cmdline"
      [ -r "$cmdline_file" ] || unknown "cannot read QEMU command line"
      mapfile -d '' args < "$cmdline_file" || unknown "cannot read QEMU command line"
      case " ${args[*]} " in
        *"/colima/"*) unknown "limactl reports no instance but an owned colima QEMU is running" ;;
      esac
    done
    [ "$PRINT_YAML" -eq 1 ] && exit 0
    echo "OK: no colima instance reported by limactl and no owned QEMU running"
    exit 0
  fi
  INSTANCE_DIR="$instance_dir"
  LIMA_YAML="${INSTANCE_DIR}/lima.yaml"
fi
check_capped_instance
if [ "$PRINT_YAML" -eq 1 ]; then
  check_print_yaml_qemu_membership
  printf '%s\n' "$LIMA_YAML"
  exit 0
fi

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
running_pids=()
for comm in "$PROC_ROOT"/[0-9]*/comm; do
  [ -r "$comm" ] || continue
  case "$(cat "$comm" 2>/dev/null)" in qemu-system-*) ;; *) continue ;; esac
  pid="${comm%/comm}"
  pid="${pid##*/}"
  cmdline_file="$PROC_ROOT/$pid/cmdline"
  mapfile -d '' args < "$cmdline_file" 2>/dev/null || continue
  case " ${args[*]} " in *"${INSTANCE_DIR}/"*) ;; *) continue ;; esac
  if ! pid_in_capped_unit "$pid"; then
    unknown "colima QEMU $pid is outside capped unit $CAPPED_UNIT_CGROUP"
  fi
  mem=""
  for ((i = 0; i < ${#args[@]}; i++)); do
    if [ "${args[$i]}" = -m ] && [ $((i + 1)) -lt ${#args[@]} ]; then
      mem="$(qemu_m_to_bytes "${args[$((i + 1))]}")" || mem=""
    fi
  done
  [ -n "$mem" ] || unknown "colima QEMU ${comm%/comm} has no parseable -m"
  running+=("$mem")
  running_pids+=("$pid")
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
if [ "$status" = Running ]; then
  [ "$CAPPED_UNIT_CGROUP_MISSING" -eq 0 ] \
    || unknown "capped unit has no cgroup for Running Colima QEMU"
  if [ "${#running[@]}" -eq 0 ]; then
    unknown "colima is Running but no colima QEMU process was found"
  fi
  [ "${#running[@]}" -eq 1 ] \
    || unknown "colima is Running with multiple QEMU processes (${running_pids[*]})"
fi
values+=("${running[@]}")

for value in "${values[@]}"; do
  [ "$value" -le "$LIMIT" ] || refuse "$value"
done
echo "OK: lima guest memory <= 8GiB (status=${status}; ${values[*]})"
