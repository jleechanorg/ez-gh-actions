#!/usr/bin/env bash
# Reclaim discarded blocks from the exact Colima VM backing ezgha before the
# host reaches the runner-admission floor. This controller never prunes Docker
# state and never changes the VM lifecycle.
set -euo pipefail

PATH="${PATH:-/usr/bin:/bin}:/opt/homebrew/bin:/usr/local/bin:${HOME}/.local/bin"
export PATH

if [[ "${1:-}" != "--bounded" ]]; then
  if [[ -n "${EZGHA_TIMEOUT_BIN+x}" ]]; then
    timeout_bin="${EZGHA_TIMEOUT_BIN}"
  else
    timeout_bin="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
  fi
  if [[ -z "${timeout_bin}" || ! -x "${timeout_bin}" ]]; then
    echo "colima-trim-guard: timeout/gtimeout unavailable; refusing an unbounded run" >&2
    exit 1
  fi
  exec "${timeout_bin}" --signal=TERM --kill-after=5 55 "$0" --bounded
fi

STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/ezgha"
LOG_PATH="${EZGHA_LOG_PATH:-${STATE_DIR}/colima-trim.jsonl}"
LOCK_FILE="${STATE_DIR}/colima-trim.lock"
COOLDOWN_FILE="${STATE_DIR}/colima-trim.last-attempt"
MAIN_PLIST="${EZGHA_MAIN_PLIST:-${HOME}/Library/LaunchAgents/org.jleechanorg.ezgha.plist}"
PLISTBUDDY_BIN="${EZGHA_PLISTBUDDY_BIN:-/usr/libexec/PlistBuddy}"
HOST_TRIGGER_KIB=$((40 * 1024 * 1024))
EMERGENCY_BYPASS_KIB=$((30 * 1024 * 1024))
MIN_RECLAIM_KIB=$((1024 * 1024))
COOLDOWN_SECONDS=900

mkdir -p "${STATE_DIR}"

log_skip() {
  local reason="$1" profile="${2:-unknown}" host_free="${3:-0}" estimate="${4:-0}"
  printf '{"timestamp_epoch":%s,"event":"trim_skipped","reason":"%s","profile":"%s","host_free_kib":%s,"estimated_reclaimable_kib":%s}\n' \
    "${NOW_EPOCH}" "${reason}" "${profile}" "${host_free}" "${estimate}" >> "${LOG_PATH}"
}

is_uint() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

NOW_EPOCH="${EZGHA_NOW_EPOCH:-$(date +%s)}"
if [[ "$(uname -s)" != "Darwin" ]]; then
  log_skip "not_macos"
  exit 0
fi

shlock_bin="$(command -v shlock 2>/dev/null || true)"
if [[ -z "${shlock_bin}" ]]; then
  log_skip "singleton_primitive_unavailable"
  exit 0
fi
if ! "${shlock_bin}" -f "${LOCK_FILE}" -p "$$"; then
  log_skip "singleton_locked"
  exit 0
fi
trap 'rm -f "${LOCK_FILE}"' EXIT

if [[ ! -f "${MAIN_PLIST}" || ! -x "${PLISTBUDDY_BIN}" ]]; then
  log_skip "persisted_docker_host_unavailable"
  exit 0
fi
docker_host="$(${PLISTBUDDY_BIN} -c 'Print :EnvironmentVariables:DOCKER_HOST' "${MAIN_PLIST}" 2>/dev/null || true)"

host_prefix="unix://${HOME}/.colima/"
host_suffix="/docker.sock"
case "${docker_host}" in
  "${host_prefix}"*"${host_suffix}")
    profile="${docker_host#"${host_prefix}"}"
    profile="${profile%"${host_suffix}"}"
    ;;
  *)
    log_skip "untrusted_docker_host"
    exit 0
    ;;
esac
case "${profile}" in
  default) ;;
  *)
    log_skip "unsupported_profile" "${profile}"
    exit 0
    ;;
esac

socket_path="${HOME}/.colima/${profile}/docker.sock"
data_disk="${HOME}/.colima/_lima/_disks/colima/datadisk"
root_disk="${HOME}/.colima/_lima/colima/diffdisk"
if [[ ! -S "${socket_path}" || -L "${socket_path}" || ! -f "${data_disk}" || -L "${data_disk}" || ! -f "${root_disk}" || -L "${root_disk}" ]]; then
  log_skip "profile_identity_ambiguous" "${profile}"
  exit 0
fi

host_free_kib="$(df -kP /System/Volumes/Data 2>/dev/null | awk 'NR == 2 {print $4}')"
if ! is_uint "${host_free_kib}"; then
  log_skip "host_free_probe_failed" "${profile}"
  exit 0
fi
if (( host_free_kib >= HOST_TRIGGER_KIB )); then
  log_skip "host_free_above_trigger" "${profile}" "${host_free_kib}"
  exit 0
fi

if [[ -f "${COOLDOWN_FILE}" ]]; then
  read -r last_attempt last_result < "${COOLDOWN_FILE}" || true
  if is_uint "${last_attempt}" && (( NOW_EPOCH - last_attempt < COOLDOWN_SECONDS )); then
    if [[ "${last_result:-attempt}" == "success" && host_free_kib -ge EMERGENCY_BYPASS_KIB ]]; then
      log_skip "cooldown_active" "${profile}" "${host_free_kib}"
      exit 0
    fi
    reason="previous_attempt_retry"
    [[ "${last_result:-attempt}" == "success" ]] && reason="emergency_pressure_bypass"
    printf '{"timestamp_epoch":%s,"event":"trim_cooldown_bypassed","reason":"%s","profile":"%s","host_free_kib":%s}\n' \
      "${NOW_EPOCH}" "${reason}" "${profile}" "${host_free_kib}" >> "${LOG_PATH}"
  fi
fi

colima_bin="$(command -v colima 2>/dev/null || true)"
if [[ -z "${colima_bin}" ]]; then
  log_skip "colima_unavailable" "${profile}" "${host_free_kib}"
  exit 0
fi
if ! status_json="$(${colima_bin} status --profile "${profile}" --json 2>/dev/null)"; then
  log_skip "profile_not_running" "${profile}" "${host_free_kib}"
  exit 0
fi
if ! grep -Fq "\"docker_socket\":\"${docker_host}\"" <<<"${status_json}"; then
  log_skip "profile_socket_mismatch" "${profile}" "${host_free_kib}"
  exit 0
fi

# Keep this program literal: it executes inside the selected Colima guest.
# shellcheck disable=SC2016
probe_script='set -eu
data_target=$(findmnt -n -o TARGET --target /mnt/lima-colima)
data_dev=$(findmnt -n -o SOURCE --target /mnt/lima-colima)
root_dev=$(findmnt -n -o SOURCE --target /)
[ "$data_target" = /mnt/lima-colima ]
data_discard=$(lsblk -bndo DISC-MAX "$data_dev" | head -n 1)
root_discard=$(lsblk -bndo DISC-MAX "$root_dev" | head -n 1)
[ -n "$data_discard" ] && [ "$data_discard" != 0 ]
[ -n "$root_discard" ] && [ "$root_discard" != 0 ]
printf "DATA_USED_KIB=%s\n" "$(df -kP /mnt/lima-colima | awk '\''NR == 2 {print $3}'\'')"
printf "ROOT_USED_KIB=%s\n" "$(df -kP / | awk '\''NR == 2 {print $3}'\'')"'
probe="$(${colima_bin} ssh --profile "${profile}" -- sh -c "${probe_script}" 2>/dev/null || true)"
data_used_kib="$(awk -F= '$1 == "DATA_USED_KIB" {print $2}' <<<"${probe}")"
root_used_kib="$(awk -F= '$1 == "ROOT_USED_KIB" {print $2}' <<<"${probe}")"
if ! is_uint "${data_used_kib}" || ! is_uint "${root_used_kib}"; then
  log_skip "guest_mount_or_discard_probe_failed" "${profile}" "${host_free_kib}"
  exit 0
fi

data_blocks="$(stat -f %b "${data_disk}" 2>/dev/null || true)"
root_blocks="$(stat -f %b "${root_disk}" 2>/dev/null || true)"
if ! is_uint "${data_blocks}" || ! is_uint "${root_blocks}"; then
  log_skip "sparse_allocation_probe_failed" "${profile}" "${host_free_kib}"
  exit 0
fi
data_alloc_kib=$((data_blocks / 2))
root_alloc_kib=$((root_blocks / 2))
data_reclaim_kib=$((data_alloc_kib > data_used_kib ? data_alloc_kib - data_used_kib : 0))
root_reclaim_kib=$((root_alloc_kib > root_used_kib ? root_alloc_kib - root_used_kib : 0))
estimated_reclaimable_kib=$((data_reclaim_kib + root_reclaim_kib))
if (( estimated_reclaimable_kib < MIN_RECLAIM_KIB )); then
  log_skip "reclaim_estimate_below_minimum" "${profile}" "${host_free_kib}" "${estimated_reclaimable_kib}"
  exit 0
fi

printf '%s attempt\n' "${NOW_EPOCH}" > "${COOLDOWN_FILE}"
printf '{"timestamp_epoch":%s,"event":"trim_started","profile":"%s","host_free_before_kib":%s,"data_alloc_before_kib":%s,"root_alloc_before_kib":%s,"guest_data_used_kib":%s,"guest_root_used_kib":%s,"estimated_reclaimable_kib":%s}\n' \
  "${NOW_EPOCH}" "${profile}" "${host_free_kib}" "${data_alloc_kib}" "${root_alloc_kib}" \
  "${data_used_kib}" "${root_used_kib}" "${estimated_reclaimable_kib}" >> "${LOG_PATH}"

trim_script='set -eu; sudo fstrim --verbose /mnt/lima-colima; sudo fstrim --verbose /'
if ! ${colima_bin} ssh --profile "${profile}" -- sh -c "${trim_script}" >/dev/null; then
  printf '{"timestamp_epoch":%s,"event":"trim_failed","profile":"%s","host_free_before_kib":%s,"estimated_reclaimable_kib":%s}\n' \
    "${NOW_EPOCH}" "${profile}" "${host_free_kib}" "${estimated_reclaimable_kib}" >> "${LOG_PATH}"
  exit 1
fi
printf '%s success\n' "${NOW_EPOCH}" > "${COOLDOWN_FILE}"

host_free_after_kib="$(df -kP /System/Volumes/Data 2>/dev/null | awk 'NR == 2 {print $4}')"
data_blocks_after="$(stat -f %b "${data_disk}" 2>/dev/null || echo "${data_blocks}")"
root_blocks_after="$(stat -f %b "${root_disk}" 2>/dev/null || echo "${root_blocks}")"
is_uint "${host_free_after_kib}" || host_free_after_kib="${host_free_kib}"
is_uint "${data_blocks_after}" || data_blocks_after="${data_blocks}"
is_uint "${root_blocks_after}" || root_blocks_after="${root_blocks}"
printf '{"timestamp_epoch":%s,"event":"trim_complete","profile":"%s","host_free_before_kib":%s,"host_free_after_kib":%s,"data_alloc_before_kib":%s,"data_alloc_after_kib":%s,"root_alloc_before_kib":%s,"root_alloc_after_kib":%s,"estimated_reclaimable_kib":%s}\n' \
  "${NOW_EPOCH}" "${profile}" "${host_free_kib}" "${host_free_after_kib}" \
  "${data_alloc_kib}" "$((data_blocks_after / 2))" "${root_alloc_kib}" "$((root_blocks_after / 2))" \
  "${estimated_reclaimable_kib}" >> "${LOG_PATH}"
