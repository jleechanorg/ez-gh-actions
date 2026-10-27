#!/usr/bin/env bash
# Hermetic coverage for runner-offline-queued-alert.sh: gh and gcloud are stubbed, but the
# stub applies the script's real --jq filters to fixture JSON so the filters are exercised.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$ROOT/scripts/runner-offline-queued-alert.sh"
W="$(mktemp -d)"
trap 'rm -rf "${W:?}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }; pass() { echo "PASS: $*"; }
cat > "$W/gh" <<'STUB'
#!/usr/bin/env bash
[ -z "${STUB_GH_FAIL:-}" ] || exit 1
filter=""; prev=""
for a in "$@"; do [ "$prev" = --jq ] && filter="$a"; prev="$a"; done
case "$*" in
  *actions/runners*) printf '%s' "${STUB_RUNNERS_JSON:-{\"runners\":[]\}}" | jq -r "$filter" ;;
  *actions/runs*) printf '%s' "${STUB_RUNS_JSON:-{\"workflow_runs\":[]\}}" | jq -r "$filter" ;;
esac
STUB
cat > "$W/gcloud" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
STUB
chmod +x "$W/gh" "$W/gcloud"
run() { # name args...
  STATE_FILE="$W/state-$1.json" STUB_LOG="$W/log-$1" GH_BIN="$W/gh" GCLOUD_BIN="${GCLOUD_OVERRIDE-$W/gcloud}" "$S" "${@:2}" >/dev/null 2>&1 || true
}
sent() { if [ -f "$W/log-$1" ]; then grep -c "severity=ERROR" "$W/log-$1" || true; else echo 0; fi; }
old=$(date -u -v-30M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
new=$(date -u +%Y-%m-%dT%H:%M:%SZ)
runner() { echo "{\"runners\":[{\"name\":\"worldai-testflight-native-mac\",\"status\":\"$1\"},{\"name\":\"other\",\"status\":\"online\"}]}"; }
runs() { echo "{\"workflow_runs\":[{\"name\":\"$1\",\"created_at\":\"$2\"}]}"; }
export STUB_RUNS_JSON STUB_RUNNERS_JSON

STUB_RUNNERS_JSON=$(runner offline) STUB_RUNS_JSON=$(runs "iOS TestFlight" "$old") run a
[ "$(sent a)" = 1 ] || fail "offline + old queued TestFlight run must alert"; pass "offline + old queue alerts"
STUB_RUNNERS_JSON=$(runner offline) STUB_RUNS_JSON=$(runs "iOS TestFlight" "$old") run a
[ "$(sent a)" = 1 ] || fail "second run inside cooldown must be throttled"; pass "throttled within cooldown"
jq '.last_sent = 1' "$W/state-a.json" > "$W/s.tmp" && mv "$W/s.tmp" "$W/state-a.json"
STUB_RUNNERS_JSON=$(runner offline) STUB_RUNS_JSON=$(runs "iOS TestFlight" "$old") run a
[ "$(sent a)" = 2 ] || fail "alert must repeat after cooldown expiry"; pass "re-alerts after cooldown"
STUB_RUNNERS_JSON=$(runner online) STUB_RUNS_JSON=$(runs "iOS TestFlight" "$old") run a
grep -q "severity=INFO" "$W/log-a" || fail "recovery must write INFO"; pass "recovery logged"
STUB_RUNNERS_JSON=$(runner online) STUB_RUNS_JSON=$(runs "iOS TestFlight" "$old") run b
[ "$(sent b)" = 0 ] || fail "online runner must not alert"; pass "online no alert"
STUB_RUNNERS_JSON=$(runner offline) STUB_RUNS_JSON='{"workflow_runs":[]}' run c
[ "$(sent c)" = 0 ] || fail "empty queue must not alert"; pass "offline + empty queue no alert"
STUB_RUNNERS_JSON=$(runner offline) STUB_RUNS_JSON=$(runs "iOS TestFlight" "$new") run d
[ "$(sent d)" = 0 ] || fail "young queue must not alert"; pass "young queue no alert"
STUB_RUNNERS_JSON=$(runner offline) STUB_RUNS_JSON=$(runs "Mobile Check" "$old") run i
[ "$(sent i)" = 0 ] || fail "queued run of an unrelated workflow must not alert"; pass "other workflow ignored"
STUB_RUNNERS_JSON='{"runners":[]}' STUB_RUNS_JSON=$(runs "iOS TestFlight" "$old") run e
[ "$(sent e)" = 1 ] || fail "unregistered runner (missing) must alert"; pass "missing runner alerts"
STUB_RUNNERS_JSON=$(runner online) run f --simulate-offline
[ "$(sent f)" = 1 ] || fail "--simulate-offline must alert"; pass "simulate-offline alerts"
run g --test-sms; grep -q TEST "$W/log-g" || fail "--test-sms must write a TEST entry"; pass "test-sms writes TEST entry"
STUB_RUNNERS_JSON=$(runner offline) STUB_RUNS_JSON=$(runs "iOS TestFlight" "$old") run h --dry-run
[ ! -f "$W/log-h" ] || fail "--dry-run must not call gcloud"; pass "dry-run silent"
# gh outage: silent below 3 consecutive failures, one BLIND alert at 3
for _ in 1 2; do STUB_GH_FAIL=1 run j; done
[ "$(sent j)" = 0 ] || fail "two gh failures must not alert"
STUB_GH_FAIL=1 run j
grep -q "BLIND" "$W/log-j" || fail "third consecutive gh failure must emit a BLIND alert"; pass "gh outage escalates after 3"
# missing gcloud must fail loudly (exit 3) and leave no throttle state
rc=0
STATE_FILE="$W/state-k.json" GH_BIN="$W/gh" GCLOUD_BIN="" PATH=/usr/bin:/bin \
  STUB_RUNNERS_JSON=$(runner offline) STUB_RUNS_JSON=$(runs "iOS TestFlight" "$old") "$S" >/dev/null 2>&1 || rc=$?
[ "$rc" = 3 ] || fail "missing gcloud must exit 3, got $rc"
[ ! -f "$W/state-k.json" ] || fail "missing gcloud must not write throttle state"
pass "missing gcloud fails loudly with no state"
# --ensure-gcp-policy must invoke stub gcloud to ensure logging metric and monitoring policy
run l --ensure-gcp-policy
grep -q "logging metrics create runner_offline_queued_alert_count" "$W/log-l" || fail "--ensure-gcp-policy must ensure logging metric"
grep -q "alpha monitoring policies create" "$W/log-l" || fail "--ensure-gcp-policy must ensure monitoring policy"
pass "ensure-gcp-policy ensures metric and policy"
