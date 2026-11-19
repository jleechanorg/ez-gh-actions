#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE="$ROOT/scripts/runner_dashboard_host_probe.sh"
WORK="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT
HOME_T="$WORK/home"
BIN="$WORK/bin"
mkdir -p "$HOME_T/.config/ezgha" "$HOME_T/.local/state/ezgha/watchdog" "$BIN"

sed -n '1,$p' > "$HOME_T/.config/ezgha/config.toml" <<'CONFIG'
version = 1
[github]
scope = "org"
target = "secret-org"
[runner]
labels = ["secret-label"]
count = 2
image = "secret-image"
name_prefix = "secret-prefix"
[limits]
memory_mb = 1
cpus = 1.0
pids = 1
min_free_disk_gb = 1
[policy]
minimum_isolation = "container"
CONFIG
sed -n '1,$p' > "$HOME_T/.config/ezgha/slot_assignments.toml" <<'SLOTS'
[assignments]
"secret-prefix-1" = 1
"secret-prefix-2" = 2
[registered_at]
"secret-prefix-1" = 1
SLOTS
printf '0\n' > "$HOME_T/.local/state/ezgha/watchdog/linux.miss_count"
printf '5\n' > "$HOME_T/.local/state/ezgha/watchdog/linux.miss_threshold"

sed -n '1,$p' > "$BIN/uname" <<'SH'
#!/usr/bin/env bash
echo "${STUB_UNAME:-Linux}"
SH
sed -n '1,$p' > "$BIN/journalctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${STUB_JOURNALCTL_LINES:-}"
SH
sed -n '1,$p' > "$BIN/systemctl" <<'SH'
#!/usr/bin/env bash
echo "${STUB_SYSTEMCTL_STATE:-active}"
SH
sed -n '1,$p' > "$BIN/docker" <<'SH'
#!/usr/bin/env bash
case "$1" in
  info) exit 0 ;;
  run)
    echo "dashboard probe must not create or pull a container" >&2
    exit 99
    ;;
  exec)
    [[ "${STUB_DOCKER_EXEC_FAIL:-0}" != 1 ]] || exit 3
    [[ "$2" == "secret-prefix-1" && "$3" == "df" && "$4" == "-Pk" && "$5" == "/" ]] || exit 2
    echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'
    echo "/dev/test 99999999 1 ${STUB_DAEMON_FREE_KB:-99999998} 1% /"
    ;;
  inspect)
    if [[ "${STUB_ALL_DOWN:-0}" == 1 ]]; then echo false; exit 0; fi
    if [[ "${STUB_ONE_DOWN:-0}" == 1 && "$*" == *-2* ]]; then echo false; exit 0; fi
    echo true
    ;;
  top)
    if [[ "${STUB_TOP_FAIL:-0}" == 1 ]]; then exit 1; fi
    if [[ "$*" == *"-eo pid,etimes,comm,args"* ]]; then
      echo 'PID ELAPSED COMMAND'
      case "$2" in
        *-1)
          echo '10 420 Runner.Worker /home/runner/bin/Runner.Worker'
          echo '25 180 python3 python3 -m pytest tests/'
          ;;
      esac
      exit 0
    fi
    echo 'PID COMMAND'
    case "$2" in
      *-1) echo '10 Runner.Worker' ;;
      *-2) echo '11 Runner.Listener' ;;
    esac
    ;;
  *) exit 1 ;;
esac
SH
sed -n '1,$p' > "$BIN/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${STUB_LAUNCHCTL_LIST:-}"
SH
sed -n '1,$p' > "$BIN/df" <<'SH'
#!/usr/bin/env bash
[[ "${STUB_HOST_DF_FAIL:-0}" != 1 ]] || exit 3
echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'
echo "/dev/test 99999999 1 ${STUB_HOST_FREE_KB:-99999998} 1% /"
SH
for forbidden in gh ssh; do
  sed -n '1,$p' > "$BIN/$forbidden" <<'SH'
#!/usr/bin/env bash
echo "forbidden command invoked" >&2
exit 99
SH
done
chmod +x "$BIN"/*

PATH="$BIN:$PATH" HOME="$HOME_T" EZGHA_DASHBOARD_DOWN_WAIT_SECONDS=0 \
  bash "$PROBE" --host-class linux > "$WORK/healthy.json"
WORK="$WORK" python3 - <<'PY'
import json
import os
from pathlib import Path

payload = json.loads((Path(os.environ["WORK"]) / "healthy.json").read_text())
assert payload["sources"]["config"]["ok"] is True
assert payload["sources"]["service"]["ok"] is True
assert payload["sources"]["docker"]["ok"] is True
assert payload["sources"]["process_probe"]["ok"] is True
assert payload["sources"]["watchdog_state"]["ok"] is True
assert payload["fleet"] == {
    "configured": 2,
    "executing": 1,
    "idle": 1,
    "cycling": 0,
    "down": 0,
    "reserved": 2,
}
assert payload["disk"] == {"status": "healthy"}
assert payload["watchdog"] == {"consecutive_misses": 0, "restart_after": 5}
assert payload["parked"] is False
assert isinstance(payload["slots"], list) and len(payload["slots"]) == 2
assert payload["slots"][0]["slot_id"] == "linux-1"
assert payload["slots"][0]["state"] == "EXECUTING"
assert payload["slots"][0]["elapsed_minutes"] == 7.0
assert payload["slots"][0]["phase_badge"] == "pytest"
assert payload["slots"][1]["slot_id"] == "linux-2"
assert payload["slots"][1]["state"] == "IDLE"
serialized = json.dumps(payload)
for forbidden in ("secret-prefix", "secret-org", "secret-label", "secret-image"):
    assert forbidden not in serialized
PY

# Explicit PARKED opt-out (MAC_RUNNER_DISABLED=1 / EZGHA_DASHBOARD_MAC_DISABLED=1)
# reports parked=true without down=2 while keeping skipped probe sources honest.
STUB_UNAME=Darwin STUB_ALL_DOWN=1 MAC_RUNNER_DISABLED=1 \
  STUB_LAUNCHCTL_LIST='' \
  PATH="$BIN:$PATH" HOME="$HOME_T" EZGHA_DASHBOARD_DOWN_WAIT_SECONDS=0 \
  bash "$PROBE" --host-class mac > "$WORK/mac-parked.json"
STUB_UNAME=Darwin STUB_ALL_DOWN=1 EZGHA_DASHBOARD_MAC_DISABLED=1 \
  STUB_LAUNCHCTL_LIST='' \
  PATH="$BIN:$PATH" HOME="$HOME_T" EZGHA_DASHBOARD_DOWN_WAIT_SECONDS=0 \
  bash "$PROBE" --host-class mac > "$WORK/mac-parked-ezgha-env.json"
WORK="$WORK" python3 - <<'PY'
import json
import os
from pathlib import Path

for name in ("mac-parked.json", "mac-parked-ezgha-env.json"):
    payload = json.loads((Path(os.environ["WORK"]) / name).read_text())
    assert payload["parked"] is True
    assert payload["parked_slots"] == 2
    assert payload["parked_reason"] == "operator_disabled"
    assert payload["fleet"]["down"] == 0
    assert payload["sources"]["service"]["ok"] is False
    assert payload["sources"]["process_probe"]["ok"] is False
    assert "disk_free_gb" not in payload
    assert all(s["state"] == "PARKED" for s in payload["slots"])
    assert "secret-prefix" not in json.dumps(payload)
PY

printf '0\n' > "$HOME_T/.local/state/ezgha/watchdog/mac.miss_count"
printf '5\n' > "$HOME_T/.local/state/ezgha/watchdog/mac.miss_threshold"
STUB_UNAME=Darwin STUB_ALL_DOWN=1 \
  STUB_LAUNCHCTL_LIST='123 0 org.jleechanorg.ezgha' \
  PATH="$BIN:$PATH" HOME="$HOME_T" EZGHA_DASHBOARD_DOWN_WAIT_SECONDS=0 \
  bash "$PROBE" --host-class mac > "$WORK/mac-old-respawn.json"
WORK="$WORK" python3 - <<'PY'
import json
import os
from pathlib import Path

payload = json.loads((Path(os.environ["WORK"]) / "mac-old-respawn.json").read_text())
assert payload["fleet"]["cycling"] == 0
assert payload["fleet"]["down"] == 2
PY

STUB_DAEMON_FREE_KB=1 PATH="$BIN:$PATH" HOME="$HOME_T" EZGHA_DASHBOARD_DOWN_WAIT_SECONDS=0 \
  bash "$PROBE" --host-class linux > "$WORK/daemon-disk-critical.json"
WORK="$WORK" python3 - <<'PY'
import json
import os
from pathlib import Path

payload = json.loads((Path(os.environ["WORK"]) / "daemon-disk-critical.json").read_text())
assert payload["sources"]["disk"]["ok"] is True
assert payload["disk"] == {"status": "critical"}
PY

# No Mac-specific 40GB floor bump: min_free_disk_gb (1 GB in this fixture's
# config.toml) is the sole admission floor on every platform, matching
# src/docker_backend.rs commit f388a8b ("honor configured Mac disk floor") —
# a hardcoded 40GB Mac floor previously flapped the fleet all day 2026-07-14
# because it sat inside the 926GB Mac host's normal 35-46GB free range.
# 39GB free is comfortably above the configured 1GB floor, so this must
# report healthy, not critical.
STUB_UNAME=Darwin STUB_LAUNCHCTL_LIST='123 0 org.jleechanorg.ezgha' \
  STUB_HOST_FREE_KB=$((39 * 1024 * 1024)) PATH="$BIN:$PATH" HOME="$HOME_T" \
  EZGHA_DASHBOARD_DOWN_WAIT_SECONDS=0 \
  bash "$PROBE" --host-class mac > "$WORK/host-disk-healthy-above-configured-floor.json"
WORK="$WORK" python3 - <<'PY'
import json
import os
from pathlib import Path

payload = json.loads((Path(os.environ["WORK"]) / "host-disk-healthy-above-configured-floor.json").read_text())
assert payload["sources"]["disk"]["ok"] is True
assert payload["disk"] == {"status": "healthy"}
PY

# A Mac host below the *configured* floor (not a hardcoded Mac-only value)
# must still report critical.
STUB_UNAME=Darwin STUB_LAUNCHCTL_LIST='123 0 org.jleechanorg.ezgha' \
  STUB_HOST_FREE_KB=1 PATH="$BIN:$PATH" HOME="$HOME_T" \
  EZGHA_DASHBOARD_DOWN_WAIT_SECONDS=0 \
  bash "$PROBE" --host-class mac > "$WORK/host-disk-critical.json"
WORK="$WORK" python3 - <<'PY'
import json
import os
from pathlib import Path

payload = json.loads((Path(os.environ["WORK"]) / "host-disk-critical.json").read_text())
assert payload["sources"]["disk"]["ok"] is True
assert payload["disk"] == {"status": "critical"}
PY

STUB_HOST_DF_FAIL=1 PATH="$BIN:$PATH" HOME="$HOME_T" EZGHA_DASHBOARD_DOWN_WAIT_SECONDS=0 \
  bash "$PROBE" --host-class linux > "$WORK/host-disk-unknown.json"
WORK="$WORK" python3 - <<'PY'
import json
import os
from pathlib import Path

payload = json.loads((Path(os.environ["WORK"]) / "host-disk-unknown.json").read_text())
assert payload["sources"]["disk"]["ok"] is False
assert payload["disk"] == {"status": "unknown"}
PY

STUB_DOCKER_EXEC_FAIL=1 PATH="$BIN:$PATH" HOME="$HOME_T" EZGHA_DASHBOARD_DOWN_WAIT_SECONDS=0 \
  bash "$PROBE" --host-class linux > "$WORK/daemon-disk-unknown.json"
WORK="$WORK" python3 - <<'PY'
import json
import os
from pathlib import Path

payload = json.loads((Path(os.environ["WORK"]) / "daemon-disk-unknown.json").read_text())
assert payload["sources"]["disk"]["ok"] is False
assert payload["disk"] == {"status": "unknown"}
PY

assert_service_state() {
  local fixture="$1" expected="$2" actual
  actual="$(STUB_UNAME=Darwin STUB_LAUNCHCTL_LIST="$fixture" PATH="$BIN:$PATH" \
    bash "$PROBE" --service-state)"
  [[ "$actual" == "$expected" ]]
}
assert_service_state '123 0 org.jleechanorg.ezgha' active
assert_service_state '123 9 org.jleechanorg.ezgha' active
assert_service_state '- 0 org.jleechanorg.ezgha' inactive
assert_service_state '- 9 org.jleechanorg.ezgha' failed
assert_service_state '' not-loaded
[[ "$(STUB_SYSTEMCTL_STATE=failed PATH="$BIN:$PATH" bash "$PROBE" --service-state)" == failed ]]

STUB_TOP_FAIL=1 PATH="$BIN:$PATH" HOME="$HOME_T" EZGHA_DASHBOARD_DOWN_WAIT_SECONDS=0 \
  bash "$PROBE" --host-class linux > "$WORK/top-failure.json"
WORK="$WORK" python3 - <<'PY'
import json
import os
from pathlib import Path

payload = json.loads((Path(os.environ["WORK"]) / "top-failure.json").read_text())
assert payload["sources"]["process_probe"]["ok"] is False
for key in ("executing", "idle", "cycling", "down"):
    assert payload["fleet"][key] is None
PY

rm "$HOME_T/.local/state/ezgha/watchdog/linux.miss_count"
PATH="$BIN:$PATH" HOME="$HOME_T" EZGHA_DASHBOARD_DOWN_WAIT_SECONDS=0 \
  bash "$PROBE" --host-class linux > "$WORK/no-watchdog.json"
WORK="$WORK" python3 - <<'PY'
import json
import os
from pathlib import Path

payload = json.loads((Path(os.environ["WORK"]) / "no-watchdog.json").read_text())
assert payload["sources"]["watchdog_state"]["ok"] is False
assert payload["watchdog"]["consecutive_misses"] is None
PY

printf '1oops2\n' > "$HOME_T/.local/state/ezgha/watchdog/linux.miss_count"
PATH="$BIN:$PATH" HOME="$HOME_T" EZGHA_DASHBOARD_DOWN_WAIT_SECONDS=0 \
  bash "$PROBE" --host-class linux > "$WORK/malformed-watchdog.json"
WORK="$WORK" python3 - <<'PY'
import json
import os
from pathlib import Path

payload = json.loads((Path(os.environ["WORK"]) / "malformed-watchdog.json").read_text())
assert payload["sources"]["watchdog_state"]["ok"] is False
assert payload["watchdog"]["consecutive_misses"] is None
PY

# Regression: a valid, present miss_count with a MISSING miss_threshold
# (exactly the live jeff-ubuntu state that made a healthy 10/10 linux fleet
# report linux_host.ok:false) must not leak a numeric consecutive_misses
# alongside watchdog_state.ok:false — both watchdog fields must be null
# together, per the snapshot builder's explicit-degraded-telemetry contract.
printf '0\n' > "$HOME_T/.local/state/ezgha/watchdog/linux.miss_count"
rm -f "$HOME_T/.local/state/ezgha/watchdog/linux.miss_threshold"
PATH="$BIN:$PATH" HOME="$HOME_T" EZGHA_DASHBOARD_DOWN_WAIT_SECONDS=0 \
  bash "$PROBE" --host-class linux > "$WORK/missing-threshold-only.json"
WORK="$WORK" python3 - <<'PY'
import json
import os
from pathlib import Path

payload = json.loads((Path(os.environ["WORK"]) / "missing-threshold-only.json").read_text())
assert payload["sources"]["watchdog_state"]["ok"] is False
assert payload["watchdog"]["consecutive_misses"] is None
assert payload["watchdog"]["restart_after"] is None
PY
printf '5\n' > "$HOME_T/.local/state/ezgha/watchdog/linux.miss_threshold"

set +e
DOCTOR_OUTPUT="$(bash "$ROOT/doctor-runner" --json 2>&1)"
DOCTOR_STATUS=$?
set -e
test "$DOCTOR_STATUS" -eq 2
[[ "$DOCTOR_OUTPUT" == *"unsupported"* ]]
grep -Fq 'runner_dashboard_host_probe.sh" --service-state' "$ROOT/doctor-runner"

STUB_UNAME=Linux STUB_ONE_DOWN=1 STUB_HOST_FREE_KB=1 \
  STUB_JOURNALCTL_LINES='other message' \
  PATH="$BIN:$PATH" HOME="$HOME_T" EZGHA_DASHBOARD_DOWN_WAIT_SECONDS=0 \
  bash "$PROBE" --host-class linux > "$WORK/critical-down-no-log.json"
STUB_UNAME=Linux STUB_ONE_DOWN=1 STUB_HOST_FREE_KB=1 \
  STUB_JOURNALCTL_LINES='only 0.5 GB free — refusing to spawn runners' \
  PATH="$BIN:$PATH" HOME="$HOME_T" EZGHA_DASHBOARD_DOWN_WAIT_SECONDS=0 \
  bash "$PROBE" --host-class linux > "$WORK/critical-down-paused-log.json"
WORK="$WORK" python3 - <<'PY'
import json
import os
from pathlib import Path

no_log = json.loads((Path(os.environ["WORK"]) / "critical-down-no-log.json").read_text())
assert no_log["pause_reason"] == "disk_critical_with_down", no_log
with_log = json.loads((Path(os.environ["WORK"]) / "critical-down-paused-log.json").read_text())
assert with_log["pause_reason"] == "disk_floor_paused", with_log
PY

echo "runner dashboard host probe tests passed"
