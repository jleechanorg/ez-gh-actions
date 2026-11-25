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
# stub gh: returns JSON. RUNS_QUEUED / RUNS_INPROG = number of runs; each run has one queued job
# created $JOB_AGE_MIN minutes ago with labels $JOB_LABELS (comma separated).
cat > "$T/gh" <<'EOF'
#!/usr/bin/env bash
mk() { date -u -d "${1} minutes ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-"${1}"M +%Y-%m-%dT%H:%M:%SZ; }
case "$*" in
  *"/jobs"*) lbl=$(printf '%s' "${JOB_LABELS:-self-hosted,ezgha}" | jq -R 'split(",")')
     jid=$(printf '%s' "$*" | sed -n 's@.*runs/\([0-9]*\)/jobs.*@\1@p'); jq -nc --argjson id "$jid" --arg c "$(mk "${JOB_AGE_MIN}")" --argjson l "$lbl" '{total_count:1,jobs:[{id:$id,status:"queued",created_at:$c,started_at:null,html_url:"https://github.com/o/r/actions/runs/1/job/7",labels:$l}]}' ;;
  *"status=queued"*) n=${RUNS_QUEUED:-1}; jq -nc --arg c "$(mk 1)" --argjson n "$n" '{total_count:$n,workflow_runs:[range($n)|{id:(4000+.),created_at:$c}]}' ;;
  *"status=in_progress"*) n=${RUNS_INPROG:-0}; jq -nc --arg c "$(mk 1)" --argjson n "$n" '{total_count:$n,workflow_runs:[range($n)|{id:(5000+.),created_at:$c}]}' ;;
  *) echo '{"total_count":0,"workflow_runs":[]}' ;;
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

# parked leg: a mac-labelled job must not text while the Mac fleet is parked, and must when it is not
rm -f "$STATE_FILE" "$GLOG"; export JOB_AGE_MIN=60 JOB_LABELS="self-hosted,self-hosted-macos" MAC_RUNNER_DISABLED=1
run; run
check "parked-leg job (Mac disabled) stays quiet" "$(count ERROR)" 0
check "parked-leg exclusion is logged" "$(grep -c 'excluded 1 queued job' "$T/out")" 1
rm -f "$STATE_FILE" "$GLOG"; export MAC_RUNNER_DISABLED=0
run; run
check "mac-labelled job alerts when the Mac fleet is not parked" "$(count ERROR)" 1
unset MAC_RUNNER_DISABLED; export JOB_LABELS="self-hosted,ezgha"

# in-progress run holding a queued job is seen
rm -f "$STATE_FILE" "$GLOG"; export JOB_AGE_MIN=45 RUNS_QUEUED=0 RUNS_INPROG=1
run; run
check "queued job inside an in_progress run alerts" "$(count ERROR)" 1
export RUNS_QUEUED=1 RUNS_INPROG=0

# inspection cap: WARNING TRUNCATED, never ERROR for a quiet queue
rm -f "$STATE_FILE" "$GLOG"; export JOB_AGE_MIN=3 RUNS_QUEUED=5 MAX_RUN_CHECKS=2
run
check "run cap writes WARNING TRUNCATED" "$(grep ^WARNING "$GLOG" | cut -f2 | jq -r .status)" TRUNCATED
check "run cap never writes ERROR for a quiet queue" "$(count ERROR)" 0
unset MAX_RUN_CHECKS; export RUNS_QUEUED=1

# corrupt state must not abort the run
printf '{"breaches":"x","last_sent":"y"}' > "$STATE_FILE"; rm -f "$GLOG"; export JOB_AGE_MIN=3
run
check "corrupt state file does not abort" "$(grep -c 'queue ok' "$T/out")" 1

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

# lock: a fresh lock makes the run skip without touching state; a stale lock (>15 min) is reclaimed
rm -f "$STATE_FILE" "$GLOG"; export QUEUE_WAIT_SIMULATE_MIN=40 SUSTAIN_CYCLES=2; mkdir "$STATE_FILE.lockdir"
run
check "held lock skips the run" "$(grep -c 'holds the lock; skipping' "$T/out")" 1
check "held lock writes no state" "$([ -f "$STATE_FILE" ] && echo yes || echo no)" no
touch -t 202001010000 "$STATE_FILE.lockdir"; run
check "stale lock is reclaimed" "$(grep -c 'queue breach 1/2' "$T/out")" 1
check "lock is released after a run" "$([ -d "$STATE_FILE.lockdir" ] && echo held || echo free)" free

# gh hang is bounded by GH_CALL_TIMEOUT_SEC even without coreutils timeout
cat > "$T/ghhang" <<'EOF'
#!/usr/bin/env bash
exec sleep 30
EOF
chmod +x "$T/ghhang"; rm -f "$STATE_FILE" "$GLOG"; unset QUEUE_WAIT_SIMULATE_MIN
start=$(date +%s); GH_BIN="$T/ghhang" GH_CALL_TIMEOUT_SEC=2 QUEUE_WAIT_FORCE_WATCHDOG=1 run
el=$(( $(date +%s) - start ))
check "hung gh is cut off by the timeout (<15s)" "$([ "$el" -lt 15 ] && echo yes || echo no)" yes
check "hung gh counts as an API failure" "$(jq -r .api_failures "$STATE_FILE")" 1

# whole-run deadline: MAX_RUN_SEC=0 stops inspection at once and warns, never errors
rm -f "$STATE_FILE" "$GLOG"; export JOB_AGE_MIN=3 RUNS_QUEUED=3 GH_BIN="$T/gh"; unset GH_CALL_TIMEOUT_SEC
MAX_RUN_SEC=0 run
check "run deadline writes WARNING TRUNCATED" "$(grep ^WARNING "$GLOG" | cut -f2 | jq -r .status)" TRUNCATED
check "run deadline never writes ERROR" "$(count ERROR)" 0
# a fresh-but-old lock (10 min) is NOT reclaimed any more (stale threshold is 15 min)
rm -f "$STATE_FILE" "$GLOG"; export QUEUE_WAIT_SIMULATE_MIN=40; mkdir "$STATE_FILE.lockdir"; touch -t "$(date -d '10 minutes ago' +%Y%m%d%H%M 2>/dev/null || date -v-10M +%Y%m%d%H%M)" "$STATE_FILE.lockdir"
run
check "10-minute-old lock is still held" "$(grep -c 'holds the lock; skipping' "$T/out")" 1
rmdir "$STATE_FILE.lockdir"

# a failed gcloud write must not advance last_sent (the alert is retried next run) and must say so
cat > "$T/gcloudfail" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$T/gcloudfail"; rm -f "$STATE_FILE" "$GLOG"; export QUEUE_WAIT_SIMULATE_MIN=40 SUSTAIN_CYCLES=2
GCLOUD_BIN="$T/gcloudfail" run; GCLOUD_BIN="$T/gcloudfail" run
check "failed gcloud write is reported" "$(grep -c 'alert not recorded, will retry' "$T/out")" 1
check "failed gcloud write does not advance last_sent" "$(jq -r .last_sent "$STATE_FILE")" 0
run
check "alert is retried and recorded once gcloud works" "$(count ERROR)" 1

echo "queue_wait_alert_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
