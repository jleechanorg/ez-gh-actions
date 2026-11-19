#!/usr/bin/env bash
# Hermetic coverage for ezgha-host-health-alert.sh failure classification
# (bead jleechan-v8ms): a host-disk verdict must never page as "runners down".
#
# Every probe is driven by the script's audit-mode env hooks (HEALTH_ALERT_*), so
# no docker/ssh/systemctl/gcloud is touched. The gcloud stub records the exact
# CLI arguments, which is how the emitted severity and payload are asserted.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="${EZGHA_HEALTH_ALERT_TEST_SCRIPT:-$ROOT/scripts/ezgha-host-health-alert.sh}"
W="$(mktemp -d)"
trap 'rm -rf "${W:?}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }; pass() { echo "PASS: $*"; }
cat > "$W/gcloud" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case "$*" in
  *"alpha monitoring policies list"*) exit 0 ;;
  *"alpha monitoring policies create"*)
    policy_file=""
    for arg in "$@"; do case "$arg" in --policy-from-file=*) policy_file="${arg#--policy-from-file=}" ;; esac; done
    if [ -n "${STUB_CAPTURE_DIR:-}" ] && [ -r "$policy_file" ]; then
      mkdir -p "$STUB_CAPTURE_DIR"
      count=$(find "$STUB_CAPTURE_DIR" -name 'policy-*.json' -type f | wc -l | tr -d ' ')
      cp "$policy_file" "$STUB_CAPTURE_DIR/policy-$((count + 1)).json"
    fi
    ;;
esac
STUB
cat > "$W/docker" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  info) exit 0 ;;
  ps) printf 'partial-container-id\n'; exit 124 ;;
  *) exit 99 ;;
esac
STUB
printf '#!/usr/bin/env bash\nshift\nexec "$@"\n' > "$W/timeout"
for bin in systemctl pgrep ssh; do
  printf '#!/usr/bin/env bash\nexit 99\n' > "$W/$bin"
done
chmod +x "$W"/{gcloud,docker,timeout,systemctl,pgrep,ssh}
export PATH="$W:$PATH" DOCKER_BIN="$W/docker"

NOW=$(date +%s)
json_log() { printf '{"status":"%s", "last_sent_fleet":0, "last_sent_disk":0, "disk_breach_since":%s, "updated_at":"x"}\n' "$1" "$2"; }
state_dir() { mkdir -p "$W/state-$1"; }
# fixed base env: fleet + peer healthy, disk under floor unless overridden per case
run() { # case free_gb containers [extra env...]
  local case="$1" free="$2" cnt="$3"; shift 3
  state_dir "$case"
  env \
    GCLOUD_BIN="$W/gcloud" STUB_LOG="$W/log-$case" \
    HEALTH_ALERT_HOST="testhost" HEALTH_ALERT_PLATFORM="Linux" \
    HEALTH_ALERT_STATE_DIR="$W/state-$case" \
    HEALTH_ALERT_SERVICE_OK=1 HEALTH_ALERT_PEER_OK=1 \
    HEALTH_ALERT_PEER_FREE_GB=100 HEALTH_ALERT_PEER_CONTAINERS=4 HEALTH_ALERT_PEER_SERVICE=active \
    HEALTH_ALERT_FREE_GB="$free" HEALTH_ALERT_CONTAINER_COUNT="$cnt" \
    HEALTH_ALERT_ALERTS_FILE="$W/alerts-none.jsonl" \
    "$@" "$S" >"$W/out-$case" 2>"$W/err-$case" || { cat "$W/err-$case" >&2; fail "$case: alert script exited nonzero"; }
}
errors() { if [ -f "$W/log-$1" ]; then grep -c -- "--severity=ERROR" "$W/log-$1" || true; else echo 0; fi; }
warnings() { if [ -f "$W/log-$1" ]; then grep -c -- "--severity=WARNING" "$W/log-$1" || true; else echo 0; fi; }
infos() { if [ -f "$W/log-$1" ]; then grep -c -- "--severity=INFO" "$W/log-$1" || true; else echo 0; fi; }

# ── 1. Disk under floor, first breach: logged at WARNING, never ERROR ────────
run diska 25 18
[ "$(errors diska)" = 0 ] || fail "a fresh disk-floor breach must not page (ERROR) — disk is not a fleet outage"
[ "$(warnings diska)" = 1 ] || fail "a fresh disk-floor breach must still be logged at WARNING"
grep -q '"cause":"disk"' "$W/log-diska" || fail "disk payload must carry cause=disk"
grep -q '"status":"DEGRADED"' "$W/log-diska" || fail "disk-only verdict status must be DEGRADED, not DOWN"
pass "fresh disk-floor breach logs WARNING + cause=disk, no page"

# ── 2. State must live under the configured state dir, never /tmp ────────────
[ -f "$W/state-diska/host-health-alert-testhost.json" ] || fail "state file must be written under HEALTH_ALERT_STATE_DIR"
grep -q 'disk_breach_since' "$W/state-diska/host-health-alert-testhost.json" || fail "state must persist disk_breach_since"
pass "throttle state persists outside /tmp"

# ── 3. Disk breach sustained past the self-heal window: escalates once ───────
state_dir diskb; json_log DEGRADED $(( NOW - 1200 )) > "$W/state-diskb/host-health-alert-testhost.json"
run diskb 25 18
[ "$(errors diskb)" = 1 ] || fail "a disk breach past DISK_PAGE_AFTER_MIN must escalate to ERROR"
grep -q '"cause":"disk"' "$W/log-diskb" || fail "escalated page must be attributed to disk"
grep -q '"disk_breach_min":' "$W/log-diskb" || fail "escalated page must report breach minutes"
pass "sustained disk breach escalates with cause=disk"

# ── 4. Sustained breach repeats are throttled by the persisted cooldown ──────
cat "$W/state-diskb/host-health-alert-testhost.json" > "$W/state-diskb/seed.json"
json_log DISK $(( NOW - 60 )) > "$W/state-diskb/host-health-alert-testhost.json"
sed -i.bak "s/\"last_sent_disk\":0/\"last_sent_disk\":$(( NOW - 60 ))/" "$W/state-diskb/host-health-alert-testhost.json"
run diskb 25 18
[ "$(errors diskb)" = 1 ] || fail "repeat inside the cooldown must be throttled"
pass "repeat page throttled by persisted cooldown"

# ── 5. Emergency floor pages immediately, still as cause=disk ────────────────
run diske 10 18
[ "$(errors diske)" = 1 ] || fail "free space below DISK_EMERGENCY_GB must page immediately"
grep -q '"cause":"disk"' "$W/log-diske" || fail "emergency page must be attributed to disk, not fleet"
pass "emergency disk floor pages immediately with cause=disk"

# ── 6. Real fleet failure pages once, as cause=fleet ────────────────────────
run fleet 100 0
[ "$(errors fleet)" = 1 ] || fail "0 runner containers must page"
grep -q '"cause":"fleet"' "$W/log-fleet" || fail "fleet outage page must carry cause=fleet"
grep -q '"status":"DOWN"' "$W/log-fleet" || fail "fleet outage verdict must be DOWN"
pass "fleet outage pages with cause=fleet"

# ── 7. Fleet failure plus disk pressure still pages fleet (disk listed) ─────
run fleetdisk 20 0
[ "$(errors fleetdisk)" = 1 ] || fail "fleet failure with disk pressure must page once"
grep -q '"cause":"fleet"' "$W/log-fleetdisk" || fail "combined failure must be attributed to fleet"
grep -q "host disk space critical" "$W/log-fleetdisk" || fail "combined page must list the disk check too"
pass "combined fleet+disk pages as fleet with disk detail"

# ── 8. Recovery emits INFO with the recovered cause and clears state ────────
state_dir rec; json_log DOWN 0 > "$W/state-rec/host-health-alert-testhost.json"
run rec 100 18
[ "$(infos rec)" -ge 1 ] || fail "recovery from DOWN must emit an INFO entry"
grep -q '"status":"RECOVERED"' "$W/log-rec" || fail "recovery payload must be RECOVERED"
grep -q '"status":"OK"' "$W/state-rec/host-health-alert-testhost.json" || fail "recovery must reset state to OK"
[ "$(errors rec)" = 0 ] || fail "healthy run must not page"
pass "recovery logs INFO and resets state"

# ── 9. Healthy host is silent ───────────────────────────────────────────────
run healthy 100 18
[ ! -f "$W/log-healthy" ] || fail "healthy run must not call gcloud at all"
pass "healthy run stays silent"

# ── 10. --ensure-policies (dry-run) declares both cause-scoped policies ─────
DRY_OUT=$(GCLOUD_BIN="$W/gcloud" STUB_LOG="$W/log-pol" HEALTH_ALERT_STATE_DIR="$W/state-pol-dry" "$S" --ensure-policies --dry-run 2>&1 || true)
printf '%s' "$DRY_OUT" | grep -q 'Runners Down Alert' || fail "--ensure-policies must declare the fleet policy"
printf '%s' "$DRY_OUT" | grep -q 'host disk below safety floor' || fail "--ensure-policies must declare the disk policy"
[ ! -f "$W/log-pol" ] || fail "--ensure-policies --dry-run must not mutate GCP"
pass "policy ensure (dry-run) declares fleet + disk policies"
# A local gcloud stub exercises generated policy JSON without any GCP writes.
mkdir -p "$W/policy-json"
GCLOUD_BIN="$W/gcloud" STUB_LOG="$W/log-pol-create" STUB_CAPTURE_DIR="$W/policy-json" HEALTH_ALERT_STATE_DIR="$W/state-pol-create" "$S" --ensure-policies > /dev/null 2>&1 || fail "stubbed policy generation failed"
[ "$(find "$W/policy-json" -name 'policy-*.json' -type f | wc -l | tr -d ' ')" = 2 ] || fail "exactly two operational policy documents must be generated"
SLACK_CHANNEL="projects/worldarchitecture-ai/notificationChannels/14071650426226468737"
for policy in "$W"/policy-json/policy-*.json; do
  name=$(jq -r '.displayName' "$policy")
  case "$name" in
    *"Runners Down Alert") cause=fleet ;;
    *"host disk below safety floor") cause=disk ;;
    *) fail "unexpected generated operational policy: $name" ;;
  esac
  jq -e --arg slack "$SLACK_CHANNEL" --arg cause "$cause" \
    '(.notificationChannels == [$slack] and .enabled == true and .severity == "CRITICAL" and .alertStrategy.autoClose == "1800s" and .alertStrategy.notificationRateLimit.period == "300s") and (.conditions[0].conditionMatchedLog.filter | contains("severity>=ERROR") and contains("jsonPayload.cause=\"" + $cause + "\""))' \
    "$policy" > /dev/null || fail "$cause policy must preserve its existing enabled predicate and route only to Slack"
done
pass "generated fleet + disk policies stay enabled and Slack-only with existing filters/rate limits"
grep -q 'jsonPayload.cause=\\"fleet\\"' "$S" || fail "fleet policy filter must be cause-scoped"
grep -q 'jsonPayload.cause=\\"disk\\"' "$S" || fail "disk policy filter must be cause-scoped"
pass "policy filters are cause-scoped"

# ── 11. A degraded PEER must never page as cause=fleet ──────────────────────
# Regression: 2026-11-04 the Mac being down paged "GitHub Actions Runners Down"
# every 30 minutes while 20 healthy Linux containers were running.
run peerdown 100 18 HEALTH_ALERT_PEER_OK=0
[ "$(errors peerdown)" = 0 ] || fail "peer host down must not page the fleet policy"
[ "$(warnings peerdown)" = 1 ] || fail "peer host down must still be recorded at WARNING"
grep -q '"cause":"peer"' "$W/log-peerdown" || fail "peer verdict must carry cause=peer"
grep -q '"status":"DEGRADED"' "$W/log-peerdown" || fail "peer verdict must be DEGRADED, not DOWN"
pass "peer-only failure reports cause=peer at WARNING, never a fleet page"

# ── 12. A disk measurement failure degrades, recovers, or pages ───────────
AL="$W/alerts.jsonl"
printf '{"body":"x","event_key":"runner_pool.disk_measurement_unavailable","severity":"CRITICAL","subject":"paused","ts_unix":%s}\n' "$(( NOW - 120 ))" > "$AL"
run crit 100 18 HEALTH_ALERT_ALERTS_FILE="$AL"
[ "$(errors crit)" = 0 ] || fail "a young disk_measurement_unavailable CRITICAL with live containers must not page at ERROR"
[ "$(warnings crit)" = 1 ] || fail "a young disk measurement failure must emit one WARNING"
grep -q '"status":"DEGRADED", "cause":"operational"' "$W/log-crit" && grep -q 'runner_pool.disk_measurement_unavailable' "$W/log-crit" \
  || fail "the WARNING must name the key and report DEGRADED with cause=operational"
! grep -q '"cause":"fleet"' "$W/log-crit" || fail "a young disk measurement failure must not emit cause=fleet"
CRIT_STATE="$W/state-crit/host-health-alert-testhost.json"
FIRST_SEEN=$(jq -er 'select(.status == "DEGRADED") | .disk_measurement_since | select(. > 0)' "$CRIT_STATE") \
  || fail "state must record DEGRADED and persist the first observed timestamp"
run crit 100 18 HEALTH_ALERT_ALERTS_FILE="$AL"
[ "$(warnings crit)" = 2 ] || fail "a second young poll must still report the operational WARNING"
[ "$(jq -r .disk_measurement_since "$CRIT_STATE")" = "$FIRST_SEEN" ] || fail "consecutive polls must preserve the first observed timestamp"
pass "young disk measurement failure logs WARNING, persists DEGRADED and retains the first observation"

run crit 100 18
grep -q '"status":"RECOVERED", "cause":"operational"' "$W/log-crit" || fail "a healthy poll must recover the operational cause"
jq -e '.status == "OK" and .disk_measurement_since == 0' "$CRIT_STATE" >/dev/null || fail "absence must reset the persistence timer"
run crit 100 18
[ "$(infos crit)" = 1 ] || fail "repeated healthy polls must emit exactly one RECOVERED entry"
run crit 100 18 HEALTH_ALERT_ALERTS_FILE="$AL" HEALTH_ALERT_DISK_MEASUREMENT_PAGE_AFTER_MIN=1
[ "$(errors crit)" = 0 ] || fail "a new episode must start a new timer even if its daemon record is already a minute old"
pass "cleared disk measurement failure recovers once and resets the timer for a new episode"

state_dir persist-29
printf '{"status":"DEGRADED","disk_measurement_since":%s}\n' "$(( NOW - 29 * 60 ))" > "$W/state-persist-29/host-health-alert-testhost.json"
run persist-29 100 18 HEALTH_ALERT_ALERTS_FILE="$AL"
[ "$(errors persist-29)" = 0 ] && [ "$(warnings persist-29)" = 1 ] || fail "29 minutes must still be inside the default warning window"
for minutes in 30 5; do
  case_name="persist-$minutes"
  state_dir "$case_name"
  printf '{"status":"DEGRADED","disk_measurement_since":%s}\n' "$(( NOW - minutes * 60 ))" > "$W/state-$case_name/host-health-alert-testhost.json"
  if [ "$minutes" = 5 ]; then
    run "$case_name" 100 18 HEALTH_ALERT_ALERTS_FILE="$AL" HEALTH_ALERT_DISK_MEASUREMENT_PAGE_AFTER_MIN=5
  else
    run "$case_name" 100 18 HEALTH_ALERT_ALERTS_FILE="$AL"
  fi
  [ "$(errors "$case_name")" = 1 ] || fail "persistence at the $minutes-minute threshold must page at ERROR"
  grep -q '"cause":"fleet"' "$W/log-$case_name" && grep -q 'runner_pool.disk_measurement_unavailable' "$W/log-$case_name" \
    || fail "the persistence page must use cause=fleet and name the key"
done
pass "continued disk measurement failure pages at 30 minutes and honors the threshold override"

run critzero 100 0 HEALTH_ALERT_ALERTS_FILE="$AL"
[ "$(errors critzero)" = 1 ] && grep -q '"cause":"fleet"' "$W/log-critzero" || fail "an observed empty fleet must page immediately"
pass "zero containers pages fleet immediately during a young disk measurement failure"

run critblind 100 18 HEALTH_ALERT_ALERTS_FILE="$AL"
run critblind 100 ''
[ "$(infos critblind)" = 0 ] || fail "a failed docker ps must not emit RECOVERED even with partial output"
jq -e '.disk_measurement_since == 0' "$W/state-critblind/host-health-alert-testhost.json" >/dev/null || fail "absence must reset the timer even on a blind poll"
run critblind 100 18
grep -q '"status":"RECOVERED", "cause":"operational"' "$W/log-critblind" || fail "an unobservable poll must preserve pending operational recovery"
pass "failed container listing defers recovery until a healthy observed poll"

printf '{"body":"x","event_key":"old","severity":"CRITICAL","subject":"old","ts_unix":%s}\n' "$(( NOW - 7200 ))" > "$AL"
run critold 100 18 HEALTH_ALERT_ALERTS_FILE="$AL"
[ "$(errors critold)" = 0 ] || fail "a CRITICAL older than the window must not page"
pass "stale daemon CRITICAL stays silent"

# ── 12b. Both disk-floor CRITICAL keys route to cause=disk ──────────────────
AL_DISK="$W/alerts-disk.jsonl"
for key in host_disk_floor disk_floor; do
  printf '{"body":"x","event_key":"runner_pool.%s","severity":"CRITICAL","subject":"disk floor","ts_unix":%s}\n' "$key" "$(( NOW - 120 ))" > "$AL_DISK"
  run "$key" 100 18 HEALTH_ALERT_ALERTS_FILE="$AL_DISK"
  [ "$(errors "$key")" = 0 ] || fail "fresh daemon $key alert must not page as fleet outage"
  [ "$(warnings "$key")" = 1 ] || fail "fresh daemon $key alert must be recorded at WARNING"
  grep -q '"cause":"disk"' "$W/log-$key" || fail "daemon $key must route to cause=disk"
  pass "recent daemon $key routes to cause=disk"
done

# ── 12c. Emitted entries must be JSON-shaped, matching the policy filters ─────
# Both [CRITICAL] ezgha policies match on jsonPayload.cause. `gcloud logging write`
# defaults to --payload-type=text, which stores the same bytes in textPayload and
# leaves jsonPayload null, so the filters never match and the alert cannot fire.
# Asserting the flag alone is not enough: emit() swallows write failures, so an
# invalid JSON payload would be dropped silently. Check the bytes too, for both
# causes, because the fleet and disk policies each read a different value.
capture_payload() { # case -> $W/payload-<case>
  printf '#!/usr/bin/env bash\necho "$*" >> "$STUB_LOG"\nif [ "$1" = logging ] && [ "$2" = write ]; then printf %%s "$4" > "$STUB_PAYLOAD"; fi\n' > "$W/gcloud-capture"
  chmod +x "$W/gcloud-capture"
}
assert_json_payload() { # case expected-cause free containers
  local case="$1" cause="$2" free="$3" cnt="$4"
  state_dir "$case"; json_log OK 0 > "$W/state-$case/host-health-alert-testhost.json"
  capture_payload "$case"
  run "$case" "$free" "$cnt" GCLOUD_BIN="$W/gcloud-capture" STUB_PAYLOAD="$W/payload-$case"
  [ -s "$W/log-$case" ] || fail "$case: expected a Cloud Logging entry"
  grep -q -- '--payload-type=json' "$W/log-$case" || fail "$case: must pass --payload-type=json so the jsonPayload filters can match"
  grep -q -- '--payload-type=text' "$W/log-$case" && fail "$case: must never request a text payload"
  [ -s "$W/payload-$case" ] || fail "$case: stub captured no payload argument"
  jq -e . "$W/payload-$case" >/dev/null || fail "$case: payload must be valid JSON, or gcloud rejects it and emit() hides the loss"
  jq -e --arg c "$cause" '.cause == $c' "$W/payload-$case" >/dev/null || fail "$case: payload must carry cause=$cause for that policy's filter"
}
assert_json_payload payloaddisk disk 25 18
assert_json_payload payloadfleet fleet 100 0
pass "disk and fleet entries declare --payload-type=json with valid JSON carrying the policy cause"

# ── 12d. A warning that escalates into a page must still close both causes ────
# Review finding on PR #245 (discussion_r4635147366): the 30-minute escalation
# cleared the operational recovery flag, so the WARNING that preceded the fleet
# page was never closed by any RECOVERED entry. The fixtures above separate
# warning->healthy from threshold escalation, so nothing covered the sequence.
state_dir combined
ALC="$W/alerts-combined.jsonl"
crit_key() { # path ts_unix
  printf '{"body":"x","event_key":"runner_pool.disk_measurement_unavailable","severity":"CRITICAL","subject":"paused","ts_unix":%s}\n' "$2" > "$1"
}
crit_key "$ALC" "$(( NOW - 120 ))"
run combined 100 18 HEALTH_ALERT_ALERTS_FILE="$ALC"
[ "$(warnings combined)" = 1 ] && [ "$(errors combined)" = 0 ] \
  || fail "combined: a young failure must warn, not page"
COMBINED_STATE="$W/state-combined/host-health-alert-testhost.json"
jq -e '.disk_measurement_recovery_pending == 1' "$COMBINED_STATE" >/dev/null \
  || fail "combined: the operational WARNING must leave its recovery pending"
# Age the persisted first observation past the escalation window, keeping the
# pending flag exactly as the previous poll wrote it.
AGED="$(jq --argjson since "$(( NOW - 31 * 60 ))" '.disk_measurement_since = $since' "$COMBINED_STATE")"
printf '%s\n' "$AGED" > "$COMBINED_STATE"
run combined 100 18 HEALTH_ALERT_ALERTS_FILE="$ALC"
[ "$(errors combined)" = 1 ] || fail "combined: the sustained failure must page cause=fleet"
grep -q '"status":"DOWN", "cause":"fleet"' "$W/log-combined" || fail "combined: escalation must page cause=fleet"
: > "$ALC"   # the measurement clears
run combined 100 18 HEALTH_ALERT_ALERTS_FILE="$ALC"
grep -q '"status":"RECOVERED", "cause":"fleet"' "$W/log-combined" \
  || fail "combined: the fleet page must recover on the first healthy poll"
grep -q '"status":"RECOVERED", "cause":"operational"' "$W/log-combined" \
  || fail "combined: the operational WARNING that preceded the page must still be closed"
[ "$(infos combined)" = 2 ] \
  || fail "combined: the first healthy poll must emit exactly one fleet and one operational recovery (got $(infos combined))"
run combined 100 18
[ "$(infos combined)" = 2 ] \
  || fail "combined: a second healthy poll must emit neither recovery again (got $(infos combined))"
pass "combined warning->escalation episode closes the fleet and operational causes exactly once"

# Control: an immediate zero-container page never opened an operational cause, so
# only the fleet recovery may follow. Guards against closing a cause that was
# never announced.
state_dir control0
AL0="$W/alerts-control0.jsonl"
crit_key "$AL0" "$(( NOW - 120 ))"
run control0 100 0 HEALTH_ALERT_ALERTS_FILE="$AL0"
[ "$(errors control0)" = 1 ] || fail "control0: an observed empty fleet must page immediately"
: > "$AL0"
run control0 100 18 HEALTH_ALERT_ALERTS_FILE="$AL0"
grep -q '"status":"RECOVERED", "cause":"fleet"' "$W/log-control0" \
  || fail "control0: the immediate fleet page must recover"
! grep -q '"status":"RECOVERED", "cause":"operational"' "$W/log-control0" \
  || fail "control0: no operational WARNING was ever opened, so none may be recovered"
pass "immediate zero-container escalation recovers only the fleet cause"

# ── 13. A verdict is a successful probe: exit 0, so launchd/cron stays green ─
state_dir ex; json_log OK 0 > "$W/state-ex/host-health-alert-testhost.json"
set +e
env GCLOUD_BIN="$W/gcloud" STUB_LOG="$W/log-ex" HEALTH_ALERT_HOST="testhost" HEALTH_ALERT_PLATFORM="Linux" \
  HEALTH_ALERT_STATE_DIR="$W/state-ex" HEALTH_ALERT_SERVICE_OK=1 HEALTH_ALERT_PEER_OK=1 \
  HEALTH_ALERT_FREE_GB=100 HEALTH_ALERT_CONTAINER_COUNT=0 \
  HEALTH_ALERT_ALERTS_FILE="$W/alerts-none.jsonl" "$S" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = 0 ] || fail "a fleet-down verdict must exit 0 (probe succeeded), got rc=$rc"
pass "verdicts exit 0; non-zero is reserved for a probe that could not run"

echo "ALL PASS"
