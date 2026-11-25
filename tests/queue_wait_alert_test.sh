#!/usr/bin/env bash
# queue_wait_alert_test.sh — Layer 1/2 tests for scripts/queue-wait-alert.sh using stub gh/gcloud.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/queue-wait-alert.sh"
POLICY="$HERE/../launchd/queue-wait-alert-policy.json"
T="$(mktemp -d "${TMPDIR:-/tmp}/qwa-test.XXXXXX")"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

# stub gcloud: record "logging write" severity + payload to $GLOG
cat > "$T/gcloud" <<'EOF'
#!/usr/bin/env bash
if [ "$1 $2" = "logging write" ]; then
  sev=""; for a in "$@"; do case "$a" in --severity=*) sev="${a#--severity=}" ;; esac; done
  printf '%s\t%s\n' "$sev" "$4" >> "$GLOG"
fi
EOF
chmod +x "$T/gcloud"
# stub gh: one queued run whose single queued job was created $JOB_AGE_MIN minutes ago
cat > "$T/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"/jobs"*) date -u -d "${JOB_AGE_MIN} minutes ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-"${JOB_AGE_MIN}"M +%Y-%m-%dT%H:%M:%SZ ;;
  *"status=queued"*) printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" 4242 ;;
esac
EOF
chmod +x "$T/gh"
export GLOG="$T/glog" GCLOUD_BIN="$T/gcloud" STATE_FILE="$T/state.json" ALERT_REPOS="o/r" COOLDOWN_SEC=1800
run() { : > "$GLOG.tmp"; "$SCRIPT" "$@" >"$T/out" 2>&1; }
count() { [ -f "$GLOG" ] && { grep -c "^$1" "$GLOG" || true; } || echo 0; }

export QUEUE_WAIT_SIMULATE_MIN=5; run
check "below threshold writes nothing" "$(count ERROR)" 0
export QUEUE_WAIT_SIMULATE_MIN=30; run
check "first breach is held back (sustain 2)" "$(count ERROR)" 0
check "breach counter is 1" "$(jq -r .breaches "$STATE_FILE")" 1
run
check "second consecutive breach alerts" "$(count ERROR)" 1
check "alert payload status" "$(grep ^ERROR "$GLOG" | cut -f2 | jq -r .status)" QUEUE_BACKED_UP
check "alert payload source" "$(grep ^ERROR "$GLOG" | cut -f2 | jq -r .source)" queue-wait-alert
run
check "third breach is inside cooldown (no repeat)" "$(count ERROR)" 1
export QUEUE_WAIT_SIMULATE_MIN=1; run
check "recovery resets the breach counter" "$(jq -r .breaches "$STATE_FILE")" 0

# real gh path: a 45-minute-old queued job breaches
unset QUEUE_WAIT_SIMULATE_MIN; rm -f "$STATE_FILE" "$GLOG"
export GH_BIN="$T/gh" JOB_AGE_MIN=45
run; run
check "gh path: 45m job alerts after 2 cycles" "$(count ERROR)" 1
check "gh path: wait computed >= 44" "$([ "$(grep ^ERROR "$GLOG" | cut -f2 | jq -r .oldest_wait_min)" -ge 44 ] && echo yes || echo no)" yes
rm -f "$STATE_FILE" "$GLOG"; export JOB_AGE_MIN=3; run; run
check "gh path: 3m job stays quiet" "$(count ERROR)" 0

# API failure: WARNING BLIND only, never ERROR
rm -f "$STATE_FILE" "$GLOG"; export GH_BIN=false MAX_API_FAILURES=3
run; run; run
check "api failure x3 writes one WARNING" "$(count WARNING)" 1
check "api failure never writes ERROR (no SMS)" "$(count ERROR)" 0
check "blind payload status" "$(grep ^WARNING "$GLOG" | cut -f2 | jq -r .status)" BLIND

# --test-alert writes one ERROR TEST entry
rm -f "$STATE_FILE" "$GLOG"; run --test-alert
check "test-alert writes ERROR TEST" "$(grep ^ERROR "$GLOG" | cut -f2 | jq -r .status)" TEST

# dry run never calls gcloud logging write
rm -f "$GLOG" "$STATE_FILE"; export QUEUE_WAIT_SIMULATE_MIN=40 SUSTAIN_CYCLES=1; run --dry-run
check "dry-run writes no log entries" "$(count ERROR)" 0
check "dry-run prints would-write" "$(grep -c 'would write ERROR' "$T/out")" 1

# policy routes to BOTH Slack and SMS channels, metric matches the emitted statuses
check "policy has 2 channels" "$(jq '.notificationChannels|length' "$POLICY")" 2
check "policy includes Slack channel" "$(jq -r '.notificationChannels[]' "$POLICY" | grep -c 14071650426226468737)" 1
check "policy includes SMS channel" "$(jq -r '.notificationChannels[]' "$POLICY" | grep -c 17167119139665448890)" 1
check "policy metric is queue_wait_alert_count" "$(jq -r '.conditions[0].conditionThreshold.filter' "$POLICY" | grep -c queue_wait_alert_count)" 1
check "script metric filter covers QUEUE_BACKED_UP and TEST" "$(grep -c 'status="QUEUE_BACKED_UP" OR jsonPayload.status="TEST"' "$SCRIPT")" 1

echo "queue_wait_alert_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
