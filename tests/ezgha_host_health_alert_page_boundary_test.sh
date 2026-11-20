#!/usr/bin/env bash
# Hermetic regression for the host-health observation-to-page boundary.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$ROOT/scripts/ezgha-host-health-alert.sh"
W="$(mktemp -d)"
trap 'rm -rf "${W:?}"' EXIT
FAILED=0

cat > "$W/gcloud" <<'STUB'
#!/usr/bin/env bash
[ "${FAIL_LOG_WRITE:-0}" != 1 ] || exit 1
jq -c --arg severity "$6" '. + {dispatch: $severity}' <<<"$4" >> "$STUB_LOG"
STUB
cat > "$W/docker" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = info ]; then exit 0; fi
if [ "$1" = top ]; then
  printf 'PID COMMAND\n'
  case "$DOCKER_FIXTURE" in
    zombie) printf '1 sleep\n2 NotRunner.Workerish\n' ;;
    top-failed) printf '1 Runner.Worker\n'; exit 1 ;;
    *) case "$2" in *1) printf '1 Runner.Listener\n' ;; *) printf '1 Runner.Worker\n' ;; esac ;;
  esac
  exit 0
fi
case "$DOCKER_FIXTURE" in
  timeout) exit 124 ;;
  partial) printf '%064d\n' 1; exit 1 ;;
  malformed) echo 'incomplete docker output' ;;
  blank) echo ;;
  duplicate) printf '%064d\n' 1 1 ;;
  zombie|top-failed) printf '%064d\n' 1 ;;
  running) printf '%064d\n' 1 2 ;;
  zero) exit 0 ;;
esac
STUB
cat > "$W/df" <<'STUB'
#!/usr/bin/env bash
printf 'Filesystem 1G-blocks Used Available Use%% Mounted on\n/dev/test 100G 90G 10G 90%% /\n'
exit 1
STUB
cat > "$W/ssh" <<'STUB'
#!/usr/bin/env bash
if [ "${SSH_FIXTURE:-}" = fail ]; then
  echo "1 inactive 0"
  exit 7
fi
exec /bin/bash -c "${@: -1}"
STUB
cat > "$W/systemctl" <<'STUB'
#!/usr/bin/env bash
echo active
STUB
cat > "$W/tail" <<'STUB'
#!/usr/bin/env bash
/bin/cat "$2"
exit 7
STUB
cat > "$W/jq" <<'STUB'
#!/usr/bin/env bash
[ "$1" != -Rr ] || exit 7
exec "${REAL_JQ:?}" "$@"
STUB
chmod +x "$W/gcloud" "$W/docker" "$W/df" "$W/ssh" "$W/systemctl"

NOW=$(date +%s)
crit() { # case event_key age_seconds
  printf '{"severity":"CRITICAL","event_key":"%s","ts_unix":%s}\n' "$2" "$(( NOW - $3 ))" >> "$W/$1.jsonl"
}
run() { # case [env overrides]
  local name="$1" flags=(); shift
  if [ "${MONITOR_ARGS:-}" = --dry-run ]; then flags+=(--dry-run); fi
  : > "$W/log-$name"
  env GCLOUD_BIN="$W/gcloud" STUB_LOG="$W/log-$name" DOCKER_BIN="$W/docker" \
    HEALTH_ALERT_HOST=test-page-boundary HEALTH_ALERT_PLATFORM=Linux \
    HEALTH_ALERT_STATE_DIR="$W/state-$name" HEALTH_ALERT_SERVICE_OK=1 HEALTH_ALERT_PEER_OK=1 \
    HEALTH_ALERT_FREE_GB=100 HEALTH_ALERT_CONTAINER_COUNT=20 \
    HEALTH_ALERT_ALERTS_FILE="$W/$name.jsonl" MAC_RUNNER_DISABLED=0 REMOTE_LINUX_DISABLED=0 \
    "$@" /bin/bash "$S" ${flags[@]+"${flags[@]}"} > "$W/out-$name" 2>&1
}
expect() { # case jq assertion description
  if jq -es "$2" "$W/log-$1" >/dev/null; then
    echo "PASS: $3"
  else
    echo "FAIL: $3"; FAILED=1
  fi
}

# Four independent fixtures can be selected for one-fix revert checks.
p0_capacity() {
  run proof-p0 HEALTH_ALERT_CONTAINER_COUNT= DOCKER_FIXTURE=zombie
  expect proof-p0 'length == 1 and (.[0] | .cause == "fleet" and .container_count == 0)' "P0 capacity: a valid Docker ID without a runner process is zero capacity"
  run proof-peer-p0 PATH="$W:$PATH" HEALTH_ALERT_PLATFORM=Darwin HEALTH_ALERT_PEER_OK= DOCKER_FIXTURE=zombie
  expect proof-peer-p0 'length == 1 and (.[0] | .cause == "peer" and any(.failed_checks[]; contains("0 runner processes ready")))' "P0 capacity: Docker peer shares process proof"
  run proof-p0 HEALTH_ALERT_CONTAINER_COUNT= DOCKER_FIXTURE=top-failed
  expect proof-p0 'length == 1 and (.[0] | .cause == "blind" and .container_count == null and .status != "RECOVERED")' "P0 capacity: failed top with partial runner output is blind, not recovery"
  run proof-p0 HEALTH_ALERT_CONTAINER_COUNT= DOCKER_FIXTURE=running
  expect proof-p0 'length == 1 and (.[0] | .cause == "fleet" and .status == "RECOVERED" and .container_count == 2)' "P0 capacity: an idle Listener and a busy Worker both prove ready capacity"
}

p0_blind() {
  run cool-p0 PATH="$W:$PATH" HEALTH_ALERT_FREE_GB=
  run cool-p0 PATH="$W:$PATH" HEALTH_ALERT_FREE_GB=
  run cool-p0 HEALTH_ALERT_CONTAINER_COUNT= DOCKER_FIXTURE=timeout
  run cool-p0 HEALTH_ALERT_CONTAINER_COUNT= DOCKER_FIXTURE=timeout
  expect cool-p0 'length == 1 and (.[0] | .cause == "blind" and .container_count == null and .dispatch == "--severity=ERROR")' "P0 cooldown: persistent Docker failure is not suppressed by the disk channel"
  run cool-p0 HEALTH_ALERT_CONTAINER_COUNT= DOCKER_FIXTURE=timeout
  expect cool-p0 'length == 0' "P0 cooldown: same-source repeat remains throttled"
}

p0_disk() {
  crit disk-p0 runner_pool.disk_floor 60
  run disk-p0
  : > "$W/disk-p0.jsonl"
  run disk-p0
  expect disk-p0 'all(.status != "RECOVERED")' "P0 disk: host df and disappeared daemon row cannot recover Docker overlay incident"
  run disk-p0 HEALTH_ALERT_FREE_GB=1
  run disk-p0
  expect disk-p0 'map(select(.status == "RECOVERED") | .cause) == ["disk"]' "P0 disk: genuine host recovery remains independent of open Docker incident"
  jq -e '.docker_disk_open == 1 and .disk_open == 0 and .status == "DISK_UNVERIFIED"' "$W/state-disk-p0/host-health-alert-test-page-boundary.json" >/dev/null ||
    { echo "FAIL: P0 disk: persisted Docker and host provenance"; FAILED=1; }
}

p0_dry() {
  mkdir -p "$W/state-dry-p0"
  live="$W/state-dry-p0/host-health-alert-test-page-boundary.json"
  printf '{"status":"DOWN","fleet_open":1,"last_sent_fleet":123}\n' > "$live"
  cp "$live" "$W/unchanged"
  MONITOR_ARGS=--dry-run run dry-p0
  if cmp -s "$live" "$W/unchanged" && ! grep -q '"status":"RECOVERED"' "$W/out-dry-p0" && [ ! -s "$W/log-dry-p0" ]; then
    echo "PASS: P0 dry-run: no reads from or writes to live state and no dispatch"
  else
    echo "FAIL: P0 dry-run: no reads from or writes to live state and no dispatch"; FAILED=1
  fi
  export HEALTH_ALERT_DRY_RUN_STATE_DIR="$W/shadow-p0"
  MONITOR_ARGS=--dry-run run dry-p0 HEALTH_ALERT_CONTAINER_COUNT=0
  MONITOR_ARGS=--dry-run run dry-p0 HEALTH_ALERT_CONTAINER_COUNT=0
  if grep -q 'fleet alert throttled' "$W/out-dry-p0" && cmp -s "$live" "$W/unchanged" && [ ! -s "$W/log-dry-p0" ]; then
    echo "PASS: P0 dry-run: chained shadow polls keep separate cooldown"
  else
    echo "FAIL: P0 dry-run: chained shadow polls keep separate cooldown"; FAILED=1
  fi
  unset HEALTH_ALERT_DRY_RUN_STATE_DIR
}

if [ "${P0_ONLY:-}" ]; then
  "p0_$P0_ONLY"
  exit "$FAILED"
fi
p0_capacity
p0_blind
p0_disk
p0_dry

crit disk-read runner_pool.disk_measurement_unavailable 60
run disk-read
expect disk-read 'length == 1 and (.[0] | .cause == "blind" and .container_count == 20 and .dispatch == "--severity=ERROR")' \
  "daemon disk-read failure with active workers pages blind"

run docker-timeout HEALTH_ALERT_CONTAINER_COUNT= DOCKER_FIXTURE=timeout
expect docker-timeout 'length == 1 and (.[0] | .cause == "blind" and .container_count == null and .dispatch == "--severity=WARNING")' \
  "Docker timeout while workers serve leaves capacity unknown"

crit saturation queue.starvation.tail.critical 120
crit saturation queue.starvation.busy_but_starving 60
run saturation
expect saturation 'length == 1 and (.[0] | .cause == "saturation" and .container_count == 20 and .dispatch == "--severity=WARNING")' \
  "all 20 slots busy with a backlog reports saturation"

crit parked runner_pool.disk_measurement_unavailable 60
run parked REMOTE_LINUX_DISABLED=1 HEALTH_ALERT_CONTAINER_COUNT=0 HEALTH_ALERT_FREE_GB=10 HEALTH_ALERT_SERVICE_OK=0
expect parked 'length == 1 and (.[0] | .cause == "parked" and .dispatch == "--severity=INFO")' \
  "parked leg with critical signals emits only INFO"

crit incomplete runner_pool.future_key 7200
run incomplete HEALTH_ALERT_CONTAINER_COUNT= DOCKER_FIXTURE=partial
run incomplete HEALTH_ALERT_CONTAINER_COUNT= DOCKER_FIXTURE=partial
expect incomplete 'length == 1 and (.[0] | .cause == "blind" and .container_count == null and .dispatch == "--severity=ERROR")' \
  "repeated partial Docker output plus a stale daemon record pages blind"
run incomplete HEALTH_ALERT_CONTAINER_COUNT= DOCKER_FIXTURE=partial
expect incomplete 'length == 0' "persistent blind page has its own cooldown"
run incomplete HEALTH_ALERT_CONTAINER_COUNT= DOCKER_FIXTURE=zero
expect incomplete 'length == 1 and (.[0] | .cause == "fleet" and .container_count == 0 and .dispatch == "--severity=ERROR")' \
  "successful empty Docker listing still pages fleet immediately after blindness"

run malformed HEALTH_ALERT_CONTAINER_COUNT= DOCKER_FIXTURE=malformed
expect malformed 'length == 1 and (.[0] | .cause == "blind" and .container_count == null)' \
  "malformed successful Docker output leaves capacity unknown"
run blank HEALTH_ALERT_CONTAINER_COUNT= DOCKER_FIXTURE=blank
expect blank 'length == 1 and (.[0] | .cause == "blind" and .container_count == null)' \
  "a blank Docker output row is incomplete rather than an empty listing"
run duplicate HEALTH_ALERT_CONTAINER_COUNT= DOCKER_FIXTURE=duplicate
expect duplicate 'length == 1 and (.[0] | .cause == "blind" and .container_count == null)' \
  "duplicate runner IDs leave capacity unknown"
run running HEALTH_ALERT_CONTAINER_COUNT= DOCKER_FIXTURE=running HEALTH_ALERT_FREE_GB=25
expect running 'length == 1 and (.[0] | .cause == "disk" and .container_count == 2 and .dispatch == "--severity=WARNING")' \
  "successful positive Docker listing preserves disk routing"
run failed-df PATH="$W:$PATH" HEALTH_ALERT_FREE_GB=
expect failed-df 'length == 1 and (.[0] | .cause == "blind" and .free_gb == null)' \
  "failed df discards partial disk output"
run peer-failed PATH="$W:$PATH" HEALTH_ALERT_PLATFORM=Darwin HEALTH_ALERT_PEER_OK= DOCKER_FIXTURE=partial
expect peer-failed 'length == 1 and (.[0] | .cause == "peer" and .dispatch == "--severity=WARNING"
  and (.failed_checks | length == 2 and all(contains("unavailable"))))' \
  "partial peer measurements report unavailable values without a fleet page"
run inactive HEALTH_ALERT_SERVICE_OK=0
expect inactive 'length == 1 and (.[0] | .cause == "operational" and .container_count == 20 and .dispatch == "--severity=WARNING")' \
  "inactive supervisor with live containers reports an operational warning"
crit unknown runner_pool.future_key 60
run unknown
expect unknown 'length == 1 and (.[0] | .cause == "operational" and .dispatch == "--severity=WARNING")' \
  "unknown critical key stays operational"

crit stale runner_pool.disk_measurement_unavailable 7200
# A future-dated record must be ignored. The offset must exceed total test
# wall-clock drift: NOW is captured once at start, but the script's own clock
# advances while ~15 prior fixtures run, so a small offset (e.g. -20s) can slip
# back INSIDE the window and make this assertion order-dependent. A large
# offset keeps the record future-dated regardless of how long the suite takes.
crit stale runner_pool.disk_measurement_unavailable -86400
run stale
expect stale 'length == 0' "old and future daemon records do not classify current health"

crit queue-tail queue.starvation.tail.critical 60
run queue-tail
expect queue-tail 'length == 1 and (.[0] | .cause == "operational" and .dispatch == "--severity=WARNING")' \
  "queue starvation alone does not establish saturation or outage"

crit host-disk runner_pool.host_disk_measurement_unavailable 60
run host-disk
expect host-disk 'length == 1 and (.[0] | .cause == "blind" and .dispatch == "--severity=WARNING")' \
  "a single host disk measurement failure warns"

run outage HEALTH_ALERT_CONTAINER_COUNT= DOCKER_FIXTURE=zero FAIL_LOG_WRITE=1
run outage HEALTH_ALERT_CONTAINER_COUNT= DOCKER_FIXTURE=zero
expect outage 'length == 1 and (.[0] | .cause == "fleet" and .dispatch == "--severity=ERROR")' \
  "rejected fleet write is retried on the next verified zero"
run outage HEALTH_ALERT_CONTAINER_COUNT= DOCKER_FIXTURE=timeout
expect outage 'length == 1 and (.[0] | .cause == "blind")' "unknown capacity cannot declare fleet recovery"
run outage HEALTH_ALERT_CONTAINER_COUNT= DOCKER_FIXTURE=running
expect outage 'length == 1 and (.[0] | .cause == "fleet" and .status == "RECOVERED" and .dispatch == "--severity=INFO")' \
  "positive capacity confirms recovery after a blind poll"

crit blind-retry runner_pool.disk_measurement_unavailable 60
run blind-retry FAIL_LOG_WRITE=1
run blind-retry
expect blind-retry 'length == 1 and (.[0] | .cause == "blind" and .dispatch == "--severity=ERROR")' \
  "rejected blind write does not start the cooldown"

# Unknown measurements retain independent recovery obligations.
run disk-recovery HEALTH_ALERT_FREE_GB=1
run disk-recovery PATH="$W:$PATH" HEALTH_ALERT_FREE_GB= HEALTH_ALERT_SERVICE_OK=0
expect disk-recovery 'all(.status != "RECOVERED")' "unknown disk never recovers a disk incident through NOTE"
run disk-recovery
expect disk-recovery 'map(select(.status == "RECOVERED") | .cause) == ["disk"]' "measured disk recovery survives the intervening blind poll"
mkdir -p "$W/state-legacy-fail"
printf '{"status":"FAIL","last_sent":123}\n' >"$W/state-legacy-fail/host-health-alert-test-page-boundary.json"
run legacy-fail
expect legacy-fail 'all(.status != "RECOVERED")' "ambiguous legacy FAIL infers no recovery cause"

run peer-emergency HEALTH_ALERT_FREE_GB=1 HEALTH_ALERT_PEER_OK=0
expect peer-emergency 'length == 2 and (.[0] | .cause == "disk" and .dispatch == "--severity=ERROR") and (.[1] | .cause == "peer" and .dispatch == "--severity=WARNING")' "measured local emergency precedes and does not suppress a peer warning"

run changed-blind HEALTH_ALERT_CONTAINER_COUNT= DOCKER_FIXTURE=timeout
run changed-blind PATH="$W:$PATH" HEALTH_ALERT_FREE_GB=
expect changed-blind 'any(.cause == "blind" and .dispatch == "--severity=WARNING") and all(.dispatch != "--severity=ERROR")' "unrelated consecutive local failures do not page blind"

crit replayed-blind runner_pool.host_disk_measurement_unavailable 60
run replayed-blind
run replayed-blind
expect replayed-blind 'any(.cause == "blind" and .dispatch == "--severity=WARNING") and all(.dispatch != "--severity=ERROR")' "rereading one daemon failure cannot establish persistence"
crit replayed-blind runner_pool.host_disk_measurement_unavailable 10
run replayed-blind
expect replayed-blind 'any(.cause == "blind" and .dispatch == "--severity=ERROR")' "a distinct daemon failure establishes persistence"

run ssh-failed PATH="$W:$PATH" HEALTH_ALERT_PLATFORM=Darwin HEALTH_ALERT_PEER_OK= SSH_FIXTURE=fail
expect ssh-failed 'length == 1 and (.[0] | .cause == "peer" and (.failed_checks | length == 1 and (.[0] | contains("unreachable"))))' "discard peer stdout from failed SSH attempts"
run ssh-duplicate PATH="$W:$PATH" HEALTH_ALERT_PLATFORM=Darwin HEALTH_ALERT_PEER_OK= DOCKER_FIXTURE=duplicate
expect ssh-duplicate 'length == 1 and (.[0] | .cause == "peer" and any(.failed_checks[]; contains("Docker runner count unavailable")))' "reject duplicate peer Docker IDs"

# Make each error supply partial evidence and never classify it.
mkdir -p "$W/fail-tail" "$W/fail-jq"
mv "$W/tail" "$W/fail-tail/tail"
mv "$W/jq" "$W/fail-jq/jq"
chmod +x "$W/fail-tail/tail" "$W/fail-jq/jq"
crit tail-failed runner_pool.disk_measurement_unavailable 60
run tail-failed PATH="$W/fail-tail:$PATH"
expect tail-failed 'length == 1 and (.[0] | .cause == "blind" and .dispatch == "--severity=WARNING")' "failed tail ignores partial producer assertion and warns blind"
crit jq-failed runner_pool.disk_measurement_unavailable 60
run jq-failed PATH="$W/fail-jq:$PATH" REAL_JQ="$(command -v jq)"
expect jq-failed 'length == 1 and (.[0] | .cause == "blind" and .dispatch == "--severity=WARNING")' "failed jq warns blind instead of silence"

exit "$FAILED"
