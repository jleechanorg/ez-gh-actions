#!/usr/bin/env bash
# Hermetic regression coverage for the Mac Colima trim guard. All platform,
# Colima, filesystem, and timeout commands are stubbed; this never trims a VM.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="${REPO_ROOT}/scripts/colima-trim-guard.sh"
WORK="$(mktemp -d)"
SOCKET_PID=""
cleanup() {
  if [[ -n "${SOCKET_PID}" ]]; then kill "${SOCKET_PID}" 2>/dev/null || true; fi
  rm -rf "${WORK}"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

HOME_T="${WORK}/home"
STUB_BIN="${WORK}/bin"
mkdir -p "${HOME_T}/.colima/default" \
  "${HOME_T}/.colima/_lima/_disks/colima" \
  "${HOME_T}/.colima/_lima/colima" \
  "${HOME_T}/Library/LaunchAgents" "${STUB_BIN}"
touch "${HOME_T}/.colima/_lima/_disks/colima/datadisk" \
  "${HOME_T}/.colima/_lima/colima/diffdisk" \
  "${HOME_T}/Library/LaunchAgents/org.jleechanorg.ezgha.plist"

python3 - "${HOME_T}/.colima/default/docker.sock" <<'PY' &
import socket, sys, time
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
s.listen(1)
time.sleep(300)
PY
SOCKET_PID=$!
for _ in $(seq 1 50); do [[ -S "${HOME_T}/.colima/default/docker.sock" ]] && break; sleep 0.1; done
[[ -S "${HOME_T}/.colima/default/docker.sock" ]] || fail "fixture socket was not created"

cat > "${STUB_BIN}/uname" <<'EOF'
#!/usr/bin/env bash
echo Darwin
EOF
cat > "${STUB_BIN}/timeout" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_TIMEOUT_LOG:?}"
while [[ "$1" == --* ]]; do
  if [[ "$1" == "--kill-after" ]]; then shift 2; else shift; fi
done
duration="$1"
shift
if [[ "${STUB_TIMEOUT_FAIL_SECONDS:-}" == "${duration}" ]]; then
  exit 124
fi
exec "$@"
EOF
cat > "${STUB_BIN}/shlock" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f) lock_file="$2"; shift 2 ;;
    -p) shift 2 ;;
    *) exit 2 ;;
  esac
done
[[ -e "${lock_file}" ]] && exit 1
printf '%s\n' "$$" > "${lock_file}"
EOF
cat > "${STUB_BIN}/PlistBuddy" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${STUB_DOCKER_HOST:?}"
EOF
cat > "${STUB_BIN}/df" <<'EOF'
#!/usr/bin/env bash
count=0
[[ -f "${STUB_DF_COUNT}" ]] && count="$(cat "${STUB_DF_COUNT}")"
count=$((count + 1)); printf '%s' "${count}" > "${STUB_DF_COUNT}"
free="${STUB_HOST_FREE_BEFORE_KIB}"
[[ "${count}" -gt 1 ]] && free="${STUB_HOST_FREE_AFTER_KIB}"
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/disk 100000000 1 %s 1%% /System/Volumes/Data\n' "${free}"
EOF
cat > "${STUB_BIN}/stat" <<'EOF'
#!/usr/bin/env bash
path="${@: -1}"
case "${path}" in
  */datadisk) echo "${STUB_DATA_BLOCKS}" ;;
  */diffdisk) echo "${STUB_ROOT_BLOCKS}" ;;
  *) exit 2 ;;
esac
EOF
cat > "${STUB_BIN}/colima" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_COLIMA_LOG}"
case "$1" in
  status) printf '{"docker_socket":"%s"}\n' "${STUB_STATUS_DOCKER_HOST:-${STUB_DOCKER_HOST}}" ;;
  ssh)
    if [[ "$*" == *fstrim* ]]; then
      [[ "${STUB_TRIM_FAIL:-0}" == 1 ]] && exit 1
      printf '/mnt/lima-colima: 5 GiB trimmed\n/: 1 GiB trimmed\n'
    else
      printf 'DATA_USED_KIB=%s\nROOT_USED_KIB=%s\n' \
        "${STUB_DATA_USED_KIB}" "${STUB_ROOT_USED_KIB}"
    fi
    ;;
  *) exit 2 ;;
esac
EOF
cat > "${STUB_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_DOCKER_LOG:?}"
exit 99
EOF
chmod +x "${STUB_BIN}"/*

export HOME="${HOME_T}"
export PATH="${STUB_BIN}:/usr/bin:/bin"
export EZGHA_PLISTBUDDY_BIN="${STUB_BIN}/PlistBuddy"
export EZGHA_MAIN_PLIST="${HOME_T}/Library/LaunchAgents/org.jleechanorg.ezgha.plist"
export EZGHA_NOW_EPOCH=2000
export STUB_DOCKER_HOST="unix://${HOME_T}/.colima/default/docker.sock"
export STUB_HOST_FREE_BEFORE_KIB=$((39 * 1024 * 1024))
export STUB_HOST_FREE_AFTER_KIB=$((45 * 1024 * 1024))
export STUB_DATA_BLOCKS=$((10 * 1024 * 1024 * 2))
export STUB_ROOT_BLOCKS=$((2 * 1024 * 1024 * 2))
export STUB_DATA_USED_KIB=$((6 * 1024 * 1024))
export STUB_ROOT_USED_KIB=$((1 * 1024 * 1024))
export STUB_TIMEOUT_LOG="${WORK}/timeout.log"
: > "${STUB_TIMEOUT_LOG}"

reset_case() {
  CASE_DIR="${WORK}/case-$1"
  rm -rf "${CASE_DIR}"; mkdir -p "${CASE_DIR}"
  export XDG_STATE_HOME="${CASE_DIR}/state"
  export EZGHA_LOG_PATH="${CASE_DIR}/guard.jsonl"
  export STUB_COLIMA_LOG="${CASE_DIR}/colima.log"
  export STUB_DF_COUNT="${CASE_DIR}/df.count"
  export STUB_DOCKER_LOG="${CASE_DIR}/docker.log"
  : > "${STUB_COLIMA_LOG}"
  : > "${STUB_DOCKER_LOG}"
}

reset_case trims
"${GUARD}"
if [[ "$(grep -c 'fstrim' "${STUB_COLIMA_LOG}")" -ne 1 ]]; then
  cat "${STUB_COLIMA_LOG}" >&2
  cat "${EZGHA_LOG_PATH}" >&2
  fail "eligible pressure did not run exactly one trim command"
fi
grep -Fq 'sudo fstrim --verbose /mnt/lima-colima' "${STUB_COLIMA_LOG}" || fail "data mount trim target missing"
grep -Fq 'sudo fstrim --verbose /' "${STUB_COLIMA_LOG}" || fail "root trim target missing"
grep -Fq '"event":"trim_complete"' "${EZGHA_LOG_PATH}" || fail "structured completion log missing"
grep -Fq '"host_free_before_kib":40894464' "${EZGHA_LOG_PATH}" || fail "before value missing from log"
grep -Fq '"host_free_after_kib":47185920' "${EZGHA_LOG_PATH}" || fail "after value missing from log"
pass "39 GiB host pressure with conservative estimate >=1 GiB trims fixed mounts and logs before/after"
grep -Fq -- '--signal=TERM --kill-after=5 55' "${STUB_TIMEOUT_LOG}" || fail "TERM+KILL budget was not bounded at 60 seconds"
pass "the whole controller is bounded by a 60-second supervisor"
grep -Fq -- '--signal=TERM --kill-after=2 10' "${STUB_TIMEOUT_LOG}" || fail "Colima status lacked its own timeout"
grep -Fq -- '--signal=TERM --kill-after=2 15' "${STUB_TIMEOUT_LOG}" || fail "guest probe lacked its own timeout"
grep -Fq -- '--signal=TERM --kill-after=2 30' "${STUB_TIMEOUT_LOG}" || fail "guest trim lacked its own timeout"
pass "each external Colima stage has a diagnostic timeout below the supervisor ceiling"

reset_case floor
STUB_HOST_FREE_BEFORE_KIB=$((40 * 1024 * 1024)) "${GUARD}"
! grep -q fstrim "${STUB_COLIMA_LOG}" || fail "exact 40 GiB boundary trimmed"
grep -Fq '"reason":"host_free_above_trigger"' "${EZGHA_LOG_PATH}" || fail "40 GiB skip reason missing"
pass "exact 40 GiB boundary does not trim"

reset_case estimate
STUB_DATA_BLOCKS=$((6 * 1024 * 1024 * 2)) \
STUB_ROOT_BLOCKS=$((1 * 1024 * 1024 * 2)) \
  "${GUARD}"
! grep -q fstrim "${STUB_COLIMA_LOG}" || fail "sub-1 GiB estimate trimmed"
grep -Fq '"reason":"reclaim_estimate_below_minimum"' "${EZGHA_LOG_PATH}" || fail "estimate skip reason missing"
pass "conservative reclaim estimate below 1 GiB fails closed"

reset_case probe-only
EZGHA_PROBE_ONLY=1 "${GUARD}"
! grep -q fstrim "${STUB_COLIMA_LOG}" || fail "probe-only mode trimmed"
grep -Fq '"event":"trim_probe_complete"' "${EZGHA_LOG_PATH}" || fail "probe-only completion missing"
[[ ! -e "${XDG_STATE_HOME}/ezgha/colima-trim.last-attempt" ]] || fail "probe-only mode mutated cooldown state"
pass "probe-only mode exercises guard probes without trim or cooldown mutation"

reset_case profile
STUB_DOCKER_HOST="unix://${HOME_T}/.colima/ci/docker.sock" "${GUARD}" || true
[[ ! -s "${STUB_COLIMA_LOG}" ]] || fail "unsupported profile reached Colima"
grep -Fq '"reason":"unsupported_profile"' "${EZGHA_LOG_PATH}" || fail "profile rejection missing"
pass "non-default persisted profile fails closed before Colima access"

reset_case socket-mismatch
STUB_STATUS_DOCKER_HOST="unix://${HOME_T}/.colima/other/docker.sock" "${GUARD}"
! grep -q fstrim "${STUB_COLIMA_LOG}" || fail "mismatched status socket trimmed"
grep -Fq '"reason":"profile_socket_mismatch"' "${EZGHA_LOG_PATH}" || fail "status socket mismatch rejection missing"
pass "running-profile status must report the persisted Docker socket"

reset_case singleton
mkdir -p "${XDG_STATE_HOME}/ezgha"
printf '%s\n' "$$" > "${XDG_STATE_HOME}/ezgha/colima-trim.lock"
"${GUARD}"
[[ ! -s "${STUB_COLIMA_LOG}" ]] || fail "singleton-locked run reached Colima"
grep -Fq '"reason":"singleton_locked"' "${EZGHA_LOG_PATH}" || fail "singleton rejection missing"
pass "atomic singleton lock suppresses overlapping runs"

reset_case stale-singleton
mkdir -p "${XDG_STATE_HOME}/ezgha"
printf '%s\n' '99999999' > "${XDG_STATE_HOME}/ezgha/colima-trim.lock"
"${GUARD}"
grep -Fq '"event":"stale_lock_recovered"' "${EZGHA_LOG_PATH}" || fail "dead-PID lock recovery was not logged"
grep -Fq '"event":"trim_complete"' "${EZGHA_LOG_PATH}" || fail "dead-PID lock prevented the eligible trim"
[[ ! -e "${XDG_STATE_HOME}/ezgha/colima-trim.lock" ]] || fail "recovered singleton lock remained after exit"
pass "a dead-PID shlock file is recovered before singleton acquisition"

reset_case status-timeout
STUB_TIMEOUT_FAIL_SECONDS=10 "${GUARD}"
grep -Fq '"event":"stage_failed","stage":"colima_status","exit_code":124' "${EZGHA_LOG_PATH}" || fail "status timeout lacked stage evidence"
grep -Fq '"reason":"profile_not_running"' "${EZGHA_LOG_PATH}" || fail "status timeout did not fail closed"
! grep -q fstrim "${STUB_COLIMA_LOG}" || fail "status timeout reached trim"
pass "a hung status probe is bounded and names the failed stage"

reset_case cooldown
STUB_HOST_FREE_AFTER_KIB=$((35 * 1024 * 1024)) "${GUARD}"
STUB_HOST_FREE_AFTER_KIB=$((35 * 1024 * 1024)) EZGHA_NOW_EPOCH=2100 "${GUARD}"
[[ "$(grep -c 'fstrim' "${STUB_COLIMA_LOG}")" -eq 1 ]] || fail "15-minute cooldown did not suppress second trim"
grep -Fq '"reason":"cooldown_active"' "${EZGHA_LOG_PATH}" || fail "cooldown skip reason missing"
pass "15-minute cooldown prevents repeated trim attempts"

reset_case emergency
STUB_HOST_FREE_AFTER_KIB=$((29 * 1024 * 1024)) "${GUARD}"
STUB_HOST_FREE_AFTER_KIB=$((29 * 1024 * 1024)) EZGHA_NOW_EPOCH=2100 "${GUARD}"
[[ "$(grep -c 'fstrim' "${STUB_COLIMA_LOG}")" -eq 2 ]] || fail "emergency pressure did not bypass success cooldown"
grep -Fq '"reason":"emergency_pressure_bypass"' "${EZGHA_LOG_PATH}" || fail "emergency bypass event missing"
pass "host pressure below 30 GiB bypasses the success cooldown"

reset_case failed-attempt
if STUB_TRIM_FAIL=1 STUB_HOST_FREE_AFTER_KIB=$((35 * 1024 * 1024)) "${GUARD}"; then
  fail "stubbed trim failure returned success"
fi
STUB_HOST_FREE_AFTER_KIB=$((35 * 1024 * 1024)) EZGHA_NOW_EPOCH=2100 "${GUARD}"
grep -Fq '"reason":"previous_attempt_retry"' "${EZGHA_LOG_PATH}" || fail "failed attempt was not retryable"
[[ "$(grep -c fstrim "${STUB_COLIMA_LOG}")" -eq 2 ]] || fail "real failed attempt was not retried"
pass "a prior failed attempt is retryable on the next poll"

reset_case no-timeout
if EZGHA_TIMEOUT_BIN="${WORK}/missing-timeout" "${GUARD}" 2>/dev/null; then
  fail "missing timeout primitive did not fail closed"
fi
[[ ! -s "${STUB_COLIMA_LOG}" && ! -s "${STUB_DOCKER_LOG}" ]] || fail "missing timeout reached Colima or Docker"
pass "missing timeout primitive fails before external runtime access"

if grep -Eq '^(start|stop|restart|delete)( |$)' "${STUB_COLIMA_LOG}"; then
  fail "guard invoked a prohibited destructive or lifecycle command"
fi
[[ ! -s "${STUB_DOCKER_LOG}" ]] || fail "guard invoked Docker"
pass "no Docker command or Colima lifecycle command is invoked"
