#!/usr/bin/env bash
# Root-invoked, bounded repair ladder for host memory pressure (issue #75).
# This file is a policy artifact: it never reboots. A non-zero result means
# watchdog may consider reboot only after every bounded stage was attempted.
set -u -o pipefail

DEADLINE_SECONDS="${REPAIR_DEADLINE_SECONDS:-110}"
START_EPOCH="$(date +%s)"
DEADLINE=$((START_EPOCH + DEADLINE_SECONDS))
LOG_FILE="${REPAIR_LOG_FILE:-/var/log/ezgha-watchdog-repair.jsonl}"
MEMINFO="${REPAIR_MEMINFO_FILE:-/proc/meminfo}"
PSI="${REPAIR_PSI_FILE:-/proc/pressure/memory}"
DRY_RUN="${REPAIR_DRY_RUN:-${DRY_RUN:-0}}"
RECLAIM_BYTES="${REPAIR_RECLAIM_BYTES:-1073741824}"
MIN_AVAILABLE_KB="${REPAIR_MIN_AVAILABLE_KB:-8388608}"
MAX_PSI_AVG10="${REPAIR_MAX_PSI_AVG10:-20}"
MAX_PSI_TOTAL_DELTA="${REPAIR_MAX_PSI_TOTAL_DELTA:-1000000}"
VERIFY_WINDOW_SECONDS="${REPAIR_VERIFY_WINDOW_SECONDS:-5}"
VERIFY_INTERVAL_SECONDS="${REPAIR_VERIFY_INTERVAL_SECONDS:-1}"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

infer_user() {
  if [ -n "${REPAIR_USER:-}" ]; then printf '%s' "$REPAIR_USER"; return; fi
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then printf '%s' "$SUDO_USER"; return; fi
  for run_dir in /run/user/[1-9]*; do
    [ -d "$run_dir" ] || continue
    uid="${run_dir##*/}"
    getent passwd "$uid" | cut -d: -f1
    return
  done
  id -un
}

REPAIR_USER="$(infer_user)"
REPAIR_USER_HOME="${REPAIR_USER_HOME:-$(getent passwd "$REPAIR_USER" | cut -d: -f6)}"
REPAIR_USER_HOME="${REPAIR_USER_HOME:-$HOME}"
DOCKER_BIN="${REPAIR_DOCKER_BIN:-$(command -v docker 2>/dev/null || printf docker)}"

resolve_docker_host() {
  local context_host="" candidate
  if [ -n "${REPAIR_DOCKER_HOST:-}" ]; then
    printf '%s' "$REPAIR_DOCKER_HOST"
    return
  fi
  if [ "$(id -u)" -eq 0 ] && [ "$REPAIR_USER" != root ]; then
    context_host="$(runuser -u "$REPAIR_USER" -- env -u DOCKER_HOST -u DOCKER_CONTEXT -u DOCKER_CONFIG \
      HOME="$REPAIR_USER_HOME" \
      "$DOCKER_BIN" context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null | head -1 || true)"
  else
    context_host="$(env -u DOCKER_HOST -u DOCKER_CONTEXT -u DOCKER_CONFIG HOME="$REPAIR_USER_HOME" \
      "$DOCKER_BIN" context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null | head -1 || true)"
  fi
  if [ -n "$context_host" ]; then
    printf '%s' "$context_host"
    return
  fi
  for candidate in \
    "$REPAIR_USER_HOME/.lima/colima/sock/docker.sock" \
    "$REPAIR_USER_HOME/.colima/default/docker.sock"; do
    if [ -S "$candidate" ]; then
      printf 'unix://%s' "$candidate"
      return
    fi
  done
  printf 'unix://%s/.lima/colima/sock/docker.sock' "$REPAIR_USER_HOME"
}

DOCKER_HOST="$(resolve_docker_host)"
if [ -n "${REPAIR_LIMACTL_BIN:-}" ]; then
  LIMACTL_BIN="$REPAIR_LIMACTL_BIN"
elif [ -x "$REPAIR_USER_HOME/.local/bin/limactl" ]; then
  LIMACTL_BIN="$REPAIR_USER_HOME/.local/bin/limactl"
else
  LIMACTL_BIN="$(command -v limactl 2>/dev/null || printf '%s/.local/bin/limactl' "$REPAIR_USER_HOME")"
fi

run_as_repair_user() {
  if [ "$(id -u)" -eq 0 ] && [ "$REPAIR_USER" != root ]; then
    runuser -u "$REPAIR_USER" -- env -u DOCKER_CONTEXT -u DOCKER_CONFIG \
      HOME="$REPAIR_USER_HOME" DOCKER_HOST="$DOCKER_HOST" "$@"
  else
    env -u DOCKER_CONTEXT -u DOCKER_CONFIG HOME="$REPAIR_USER_HOME" DOCKER_HOST="$DOCKER_HOST" "$@"
  fi
}

QEMU_PID="${REPAIR_QEMU_PID:-}"
# Match the kernel comm name, not full argv. `pgrep -f` can select the repair
# shell itself because its command line contains this search text.
if [ -z "$QEMU_PID" ]; then QEMU_PID="$(pgrep -n -x 'qemu-system-(x86|aar)' 2>/dev/null || true)"; fi

resolve_qemu_cgroup() {
  if [ -n "${REPAIR_QEMU_CGROUP:-}" ]; then printf '%s' "$REPAIR_QEMU_CGROUP"; return; fi
  if [[ "$QEMU_PID" =~ ^[0-9]+$ ]] && [ -r "/proc/$QEMU_PID/cgroup" ]; then
    cgroup_path="$(awk -F: '$1 == "0" {print $3; exit}' "/proc/$QEMU_PID/cgroup")"
    [ -n "$cgroup_path" ] && printf '/sys/fs/cgroup%s' "$cgroup_path"
  fi
}

QEMU_CGROUP="$(resolve_qemu_cgroup)"
QEMU_CGROUP="${QEMU_CGROUP%/}"

qemu_cgroup_verified() {
  [[ "$QEMU_CGROUP" == /sys/fs/cgroup/* ]] || return 1
  [ "$QEMU_CGROUP" != /sys/fs/cgroup ] || return 1
  [ -e "$QEMU_CGROUP/memory.reclaim" ] || return 1
  [ -e "$QEMU_CGROUP/cgroup.procs" ] || return 1
  if [ "${REPAIR_QEMU_CGROUP_VERIFIED:-0}" = 1 ]; then return 0; fi
  [[ "${QEMU_PID:-}" =~ ^[0-9]+$ ]] || return 1
  [ -r "/proc/$QEMU_PID/comm" ] || return 1
  grep -Eq '^qemu-system-(x86|aar)$' "/proc/$QEMU_PID/comm"
}

log() {
  local stage="$1" status="$2" detail="$3"
  stage="${stage//\\/\\\\}"; stage="${stage//\"/\\\"}"
  status="${status//\\/\\\\}"; status="${status//\"/\\\"}"
  detail="${detail//\\/\\\\}"; detail="${detail//\"/\\\"}"
  detail="${detail//$'\n'/\\n}"; detail="${detail//$'\r'/\\r}"; detail="${detail//$'\t'/\\t}"
  printf '{"ts":"%s","stage":"%s","status":"%s","detail":"%s"}\n' \
    "$(date -u +%FT%TZ)" "$stage" "$status" "$detail" >> "$LOG_FILE" 2>/dev/null || true
}

PSI_SEQUENCE_INDEX=0
read_psi_metrics() {
  local line avg total
  if [ -n "${REPAIR_PSI_SEQUENCE_FILE:-}" ] && [ -f "$REPAIR_PSI_SEQUENCE_FILE" ]; then
    # Command substitution runs functions in a subshell, so persist the
    # fixture cursor in a sibling file for deterministic injected samples.
    local index_file="${REPAIR_PSI_SEQUENCE_FILE}.index" index=0
    [ -f "$index_file" ] && index="$(cat "$index_file")"
    index=$((index + 1))
    printf '%s\n' "$index" > "$index_file"
    line="$(sed -n "${index}p" "$REPAIR_PSI_SEQUENCE_FILE")"
    avg="${line%% *}"; total="${line#* }"
    printf '%s|%s' "$avg" "$total"
    return
  fi
  awk '/^some / {for (i=1;i<=NF;i++) {if ($i ~ /^avg10=/) {a=$i; sub("avg10=","",a)}; if ($i ~ /^total=/) {t=$i; sub("total=","",t)}}} END {if (a != "" && t != "") printf "%s|%s", a, t}' "$PSI" 2>/dev/null || true
}

remaining() {
  local left=$((DEADLINE - $(date +%s)))
  [ "$left" -gt 0 ] && printf '%s' "$left" || printf '0'
}

run_bounded() {
  local stage="$1"; shift
  local left
  left="$(remaining)"
  if [ "$left" -le 0 ]; then log "$stage" "deadline" "total deadline reached"; return 124; fi
  if [ "$DRY_RUN" = "1" ]; then
    log "$stage" "dry-run" "$*"
    return 0
  fi
  if [ "${1:-}" = run_as_repair_user ]; then
    shift
    if [ "$(id -u)" -eq 0 ] && [ "$REPAIR_USER" != root ]; then
      timeout --signal TERM --kill-after=2s "${left}s" runuser -u "$REPAIR_USER" -- \
        env -u DOCKER_CONTEXT -u DOCKER_CONFIG HOME="$REPAIR_USER_HOME" DOCKER_HOST="$DOCKER_HOST" "$@"
    else
      timeout --signal TERM --kill-after=2s "${left}s" env -u DOCKER_CONTEXT -u DOCKER_CONFIG \
        HOME="$REPAIR_USER_HOME" DOCKER_HOST="$DOCKER_HOST" "$@"
    fi
  else
    timeout --signal TERM --kill-after=2s "${left}s" "$@"
  fi
}

if [ "$(id -u)" -ne 0 ] && [ "$DRY_RUN" != "1" ] && [ "${REPAIR_ALLOW_NONROOT:-0}" != "1" ]; then
  log preflight blocked "root required"
  exit 2
fi

overall_ok=1
baseline_mem="$(awk '/^MemAvailable:/ {print $2; exit}' "$MEMINFO" 2>/dev/null || true)"
baseline_psi_metrics="$(read_psi_metrics)"
baseline_psi="${baseline_psi_metrics%%|*}"
baseline_psi_total="${baseline_psi_metrics#*|}"
log preflight begin "deadline=${DEADLINE_SECONDS}s mem_available_kb=${baseline_mem:-unknown} psi_avg10=${baseline_psi:-unknown}"

# 1. freeze/close admission asynchronously. --no-block is deliberate: stopping the
# service must not prevent direct container shedding from starting promptly.
close_admission() {
  if [ "${REPAIR_ADMISSION_FORCE_DEGRADED:-0}" = "1" ]; then
    log admission degraded "test-injected admission timeout; shedding continues"
    return 1
  fi
  if ! run_bounded freeze-admission systemctl --user --machine="${REPAIR_USER}@.host" stop --no-block ezgha.service; then
    log admission failed "close request failed; continuing"
    return 1
  fi
  if [ "$DRY_RUN" = "1" ]; then
    log admission dry-run "would poll ezgha inactive before container snapshot"
    return 0
  fi
  local poll_status poll_deadline=$(( $(date +%s) + ${REPAIR_ADMISSION_POLL_SECONDS:-15} ))
  while [ "$(date +%s)" -lt "$poll_deadline" ] && [ "$(remaining)" -gt 0 ]; do
    poll_status="$(timeout --signal TERM --kill-after=1s "${REPAIR_ADMISSION_POLL_COMMAND_TIMEOUT_SECONDS:-2}s" \
      systemctl --user --machine="${REPAIR_USER}@.host" is-active ezgha.service 2>/dev/null || true)"
    case "$poll_status" in
      inactive|dead|failed|unknown|not-found|'')
        log admission complete "ezgha inactive before container snapshot (status=${poll_status:-unknown})"
        return 0 ;;
      active|activating|deactivating)
        sleep 1 ;;
      *)
        sleep 1 ;;
    esac
  done
  log admission degraded "ezgha did not become inactive before bounded poll deadline; shedding continues"
  return 1
}

if ! close_admission; then overall_ok=0; fi

# 2. kill/remove managed runners directly, independent of daemon shutdown.
containers="${REPAIR_MANAGED_CONTAINERS:-}"
container_query_ok=1
if [ -z "$containers" ] && [ "$DRY_RUN" != "1" ]; then
  if ! containers="$(run_as_repair_user "$DOCKER_BIN" ps -q --filter label=ezgha=managed 2>/dev/null)"; then
    container_query_ok=0
    overall_ok=0
    log containers failed "managed container discovery failed via ${DOCKER_HOST}; continuing"
  fi
fi
if [ "$DRY_RUN" = "1" ] && [ -z "$containers" ]; then
  containers="managed-containers"
fi
if [ "$container_query_ok" -eq 0 ]; then
  :
elif [ -n "$containers" ]; then
  if run_bounded containers run_as_repair_user "$DOCKER_BIN" rm -f $containers; then log containers complete "managed containers removed"; else overall_ok=0; log containers failed "container removal failed; continuing"; fi
else
  log containers complete "no managed containers (idempotent)"
fi

# 3. Ask the QEMU cgroup to reclaim memory. This is advisory and safe to
# repeat; it does not kill the VM.
reclaim="${QEMU_CGROUP:+$QEMU_CGROUP/memory.reclaim}"
if qemu_cgroup_verified; then
  if [ "$DRY_RUN" = "1" ]; then log qemu-reclaim dry-run "would write ${RECLAIM_BYTES} to $reclaim";
  elif printf '%s' "$RECLAIM_BYTES" > "$reclaim" 2>/dev/null; then log qemu-reclaim complete "requested ${RECLAIM_BYTES}-byte cgroup reclaim";
  else overall_ok=0; log qemu-reclaim failed "memory.reclaim write failed; continuing"; fi
else
  log qemu-reclaim skipped "no verified live QEMU cgroup under /sys/fs/cgroup"
fi

# 4. Verify improvement before escalating to VM shutdown. PSI avg10 is a
# rolling 10-second metric, so sample for a bounded window rather than making
# a decision from one read immediately after shedding.
verify_recovery() {
  local phase="$1" verify_deadline previous_psi_total after_mem after_psi_metrics after_psi after_psi_total psi_delta_ok
  verify_improved=0
  if [ "$DRY_RUN" = "1" ]; then
    log verify dry-run "phase=${phase}; would compare MemAvailable and memory PSI"
    return 0
  fi
  if [ "$phase" = post-stop ]; then
    # VM shutdown is itself an action; establish a fresh post-action baseline
    # so the proof measures bounded decay after that action, not its historical
    # total-stall accumulation.
    baseline_mem="$(awk '/^MemAvailable:/ {print $2; exit}' "$MEMINFO" 2>/dev/null || true)"
    baseline_psi_metrics="$(read_psi_metrics)"
    baseline_psi="${baseline_psi_metrics%%|*}"
    baseline_psi_total="${baseline_psi_metrics#*|}"
  fi
  verify_deadline=$(( $(date +%s) + VERIFY_WINDOW_SECONDS ))
  previous_psi_total="$baseline_psi_total"
  after_mem=""; after_psi=""; after_psi_total=""
  while [ "$(date +%s)" -le "$verify_deadline" ] && [ "$(remaining)" -gt 0 ]; do
    after_mem="$(awk '/^MemAvailable:/ {print $2; exit}' "$MEMINFO" 2>/dev/null || true)"
    after_psi_metrics="$(read_psi_metrics)"
    after_psi="${after_psi_metrics%%|*}"
    after_psi_total="${after_psi_metrics#*|}"
    psi_delta_ok=0
    if [[ "$after_psi_total" =~ ^[0-9]+$ && "$previous_psi_total" =~ ^[0-9]+$ ]] \
      && [ "$after_psi_total" -ge "$previous_psi_total" ] \
      && [ $((after_psi_total - previous_psi_total)) -le "$MAX_PSI_TOTAL_DELTA" ]; then
      psi_delta_ok=1
    fi
    if [[ "$baseline_mem" =~ ^[0-9]+$ && "$baseline_psi" =~ ^[0-9]+([.][0-9]+)?$ && "$baseline_psi_total" =~ ^[0-9]+$ ]] \
      && [[ "$after_mem" =~ ^[0-9]+$ && "$after_psi" =~ ^[0-9]+([.][0-9]+)?$ ]] \
      && [ "$after_mem" -ge "$MIN_AVAILABLE_KB" ] \
      && [ "$psi_delta_ok" -eq 1 ] \
      && awk "BEGIN {exit !($after_psi <= $MAX_PSI_AVG10)}"; then
      verify_improved=1
      break
    fi
    previous_psi_total="$after_psi_total"
    [ "$VERIFY_INTERVAL_SECONDS" -gt 0 ] 2>/dev/null && sleep "$VERIFY_INTERVAL_SECONDS" || true
  done
  log verify "$([ "$verify_improved" -eq 1 ] && echo improved || echo insufficient)" "phase=${phase} mem_before=${baseline_mem:-unknown} mem_after=${after_mem:-unknown} mem_floor=${MIN_AVAILABLE_KB} psi_before=${baseline_psi:-unknown} psi_after=${after_psi:-unknown} psi_max=${MAX_PSI_AVG10} psi_total_delta_max=${MAX_PSI_TOTAL_DELTA}"
}

verify_recovery pre-stop

# 5. Only stop the VM after verification says pressure remains. This is the
# final bounded shedding stage; watchdog decides separately whether reboot is
# warranted from our non-zero result.
if [ "$verify_improved" -eq 0 ]; then
  if run_bounded limactl run_as_repair_user timeout --signal TERM --kill-after=2s \
    "${REPAIR_LIMA_STOP_TIMEOUT_SECONDS:-30}s" "$LIMACTL_BIN" --tty=false stop "${REPAIR_LIMA_INSTANCE:-colima}"; then
    log limactl complete "bounded VM stop requested"
    verify_recovery post-stop
  else
    overall_ok=0; log limactl failed "bounded VM stop failed or timed out"
  fi
else
  log limactl skipped "pressure improved; VM stop not required"
fi

if [ "$DRY_RUN" = "1" ]; then log result recovered "dry-run plan completed without mutation"; exit 0; fi
if [ "$verify_improved" -eq 1 ]; then log result recovered "recovery thresholds verified"; exit 0; fi
if [ "$(remaining)" -le 0 ]; then overall_ok=0; log result deadline "all stages reached total deadline"; fi
log result reboot-eligible "all bounded stages attempted; caller may consider reboot"
exit 1
