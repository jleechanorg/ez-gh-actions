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
case "$DOCKER_FIXTURE" in
  timeout) exit 124 ;;
  partial) printf '%064d\n' 1; exit 1 ;;
  malformed) echo 'incomplete docker output' ;;
  blank) echo ;;
  duplicate) printf '%064d\n' 1 1 ;;
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
exec /bin/bash -c "${@: -1}"
STUB
cat > "$W/systemctl" <<'STUB'
#!/usr/bin/env bash
echo active
STUB
chmod +x "$W/gcloud" "$W/docker" "$W/df" "$W/ssh" "$W/systemctl"

NOW=$(date +%s)
crit() { # case event_key age_seconds
  printf '{"severity":"CRITICAL","event_key":"%s","ts_unix":%s}\n' "$2" "$(( NOW - $3 ))" >> "$W/$1.jsonl"
}
run() { # case [env overrides]
  local name="$1"; shift
  : > "$W/log-$name"
  env GCLOUD_BIN="$W/gcloud" STUB_LOG="$W/log-$name" DOCKER_BIN="$W/docker" \
    HEALTH_ALERT_HOST=test-page-boundary HEALTH_ALERT_PLATFORM=Linux \
    HEALTH_ALERT_STATE_DIR="$W/state-$name" HEALTH_ALERT_SERVICE_OK=1 HEALTH_ALERT_PEER_OK=1 \
    HEALTH_ALERT_FREE_GB=100 HEALTH_ALERT_CONTAINER_COUNT=20 \
    HEALTH_ALERT_ALERTS_FILE="$W/$name.jsonl" MAC_RUNNER_DISABLED=0 REMOTE_LINUX_DISABLED=0 \
    "$@" /bin/bash "$S" > "$W/out-$name" 2>&1
}
expect() { # case jq assertion description
  if jq -es "$2" "$W/log-$1" >/dev/null; then
    echo "PASS: $3"
  else
    echo "FAIL: $3"; FAILED=1
  fi
}

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

exit "$FAILED"
