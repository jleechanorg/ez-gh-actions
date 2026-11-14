#!/usr/bin/env bash
# tests/queued_status_fleet_truth_test.sh
#
# Regression for a live misdiagnosis: ezgha-queued-status reported a DEAD fleet as
# "healthy but busy".
#
# Observed 2026-11-14T20:17Z: the script printed
#   "online 27 / total 39 — busy 27, idle 0 (100.0% utilized)"
#   "saturated: zero idle runners while jobs wait — genuine capacity pressure"
# while EVERY ez-runner-c-* Linux runner was offline (jeff-ubuntu unreachable by
# ICMP, LAN SSH, tailscale SSH; tailscale reported "offline, last seen 1h ago").
# The 27 "online" were 24 cmux-* plus mac-smtp-egress.
#
# AGENTS.md: "The GitHub API CANNOT be trusted for fleet state... Use LOCAL
# docker top / docker ps... never API counts." The script converted API
# registrations into a confident CAPACITY verdict — the exact inversion this test
# forbids.
#
# Asserts:
#   1. the fleet section is labelled as REGISTRATIONS, not live capacity
#   2. no capacity verdict is emitted from API-only data
#   3. a fully-offline configured prefix is surfaced as a possible host outage
#   4. ./doctor-runner is named as the authority to confirm locally
#
# Usage: bash tests/queued_status_fleet_truth_test.sh
set -uo pipefail
unset BASH_ENV || true

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

SCRIPT=".claude/skills/ezgha-queued-status/scripts/queued_status.py"
FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILS=$((FAILS+1)); }

W="$(mktemp -d)"
trap 'rm -rf "${W:?}"' EXIT
mkdir -p "$W/bin"

# Stub gh: all ez-runner-c-* OFFLINE, a few cmux-* online+busy, queued jobs present.
# This is the exact shape that produced the wrong verdict.
cat > "$W/bin/gh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
args="$*"
case "$args" in
  # fleet registrations
  *"/actions/runners"*)
    cat <<'JSON'
{"total_count":6,"runners":[
 {"id":1,"name":"ez-runner-c-1","status":"offline","busy":false},
 {"id":2,"name":"ez-runner-c-2","status":"offline","busy":false},
 {"id":3,"name":"ez-runner-c-3","status":"offline","busy":false},
 {"id":4,"name":"cmux-gleeful-1","status":"online","busy":true},
 {"id":5,"name":"cmux-gleeful-2","status":"online","busy":true},
 {"id":6,"name":"cmux-bashful-1","status":"online","busy":true}]}
JSON
    exit 0 ;;
  # job list for a live run
  *"/jobs"*)
    cat <<'JSON'
{"total_count":2,"jobs":[
 {"id":1,"name":"j1","status":"queued","created_at":"2020-01-01T00:00:00Z","started_at":null,"labels":["self-hosted"]},
 {"id":2,"name":"j2","status":"queued","created_at":"2020-01-01T00:00:00Z","started_at":null,"labels":["self-hosted"]}]}
JSON
    exit 0 ;;
  # run LIST (paginated) — must be matched before the per_page=1 probes
  *"--paginate"*)
    cat <<'JSON'
{"total_count":1,"workflow_runs":[
 {"id":9001,"name":"P","path":".github/workflows/p.yml","head_branch":"b",
  "created_at":"2020-01-01T00:00:00Z","status":"queued","run_attempt":1,
  "updated_at":"2020-01-01T01:00:00Z","head_sha":"aaa"}]}
JSON
    exit 0 ;;
  # scalar total_count probes
  *"status=in_progress"*) printf '{"total_count":0}'; exit 0 ;;
  *"per_page=1"*)         printf '{"total_count":1}'; exit 0 ;;
  *) printf '{}'; exit 0 ;;
esac
SH
chmod +x "$W/bin/gh"

set +e
OUT="$(env -u BASH_ENV PATH="$W/bin:$PATH" python3 "$SCRIPT" --repo acme/one 2>&1)"
RC=$?
set -e
echo "--- script output ---"
printf '%s\n' "$OUT" | head -20
echo "---------------------"

if [ "$RC" -ne 0 ]; then
  fail "script exited $RC on a stub that should be well-formed"
fi

# 1. labelled as registrations, not capacity
grep -qi "registration" <<<"$OUT" \
  && pass "1 fleet section is labelled as registrations" \
  || fail "1 fleet numbers are still presented as live capacity"

# 2. no capacity verdict from API-only data. Reject ANY affirmative capacity
#    claim, not just the original phrase — the review showed that swapping
#    "genuine capacity pressure" for another HEALTHY/saturation claim passed.
if grep -qiE "genuine capacity pressure|genuine saturation|= *no capacity problem|capacity: *(healthy|saturated|ok)" <<<"$OUT"; then
  fail "2 still asserts a capacity verdict from GitHub-API data: $(grep -oiE 'genuine capacity pressure|genuine saturation|= *no capacity problem|capacity: *(healthy|saturated|ok)' <<<"$OUT" | head -1)"
else
  pass "2 no capacity verdict claimed from API-only data"
fi
grep -qi "capacity: \*\*UNKNOWN\*\*\|capacity: UNKNOWN" <<<"$OUT" \
  && pass "2b capacity is explicitly reported UNKNOWN" \
  || fail "2b capacity is not explicitly UNKNOWN"

# 3. whole-prefix offline is surfaced
# 3. Require the outage warning line AND the specific affected prefix. A loose
#    regex matched the generic UNKNOWN explanation even with the warning removed.
grep -qE "WHOLE-PREFIX OFFLINE" <<<"$OUT" \
  && pass "3 the whole-prefix-offline warning line is present" \
  || fail "3 the whole-prefix-offline warning line is missing"
grep -qE "WHOLE-PREFIX OFFLINE.*ez-runner-c \(3/3 offline\)" <<<"$OUT" \
  && pass "3b the warning names the affected prefix with its counts" \
  || fail "3b the warning does not name ez-runner-c with counts"

# 4. names doctor-runner as the local authority
grep -q "doctor-runner" <<<"$OUT" \
  && pass "4 points at ./doctor-runner as the local authority" \
  || fail "4 does not direct the reader to ./doctor-runner"

# ---- 5. a PARKED leg must NOT be reported as a host outage ---------------
# AGENTS.md: "a deliberately parked platform is DISABLED, not DOWN". The Mac leg is
# an intentional opt-out (MAC_RUNNER_DISABLED=1). If that fired the outage warning,
# a healthy parked leg would page forever.
mkdir -p "$W/bin-parked"
cat > "$W/bin-parked/gh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
case "$*" in
  *"/actions/runners"*)
    cat <<'JSON'
{"total_count":3,"runners":[
 {"id":1,"name":"ez-mac-runner-h-1","status":"offline","busy":false},
 {"id":2,"name":"ez-mac-runner-h-2","status":"offline","busy":false},
 {"id":3,"name":"cmux-gleeful-1","status":"online","busy":false}]}
JSON
    exit 0 ;;
  *"--paginate"*) printf '{"total_count":0,"workflow_runs":[]}'; exit 0 ;;
  *) printf '{"total_count":0}'; exit 0 ;;
esac
SH
chmod +x "$W/bin-parked/gh"

set +e
OUTP="$(env -u BASH_ENV PATH="$W/bin-parked:$PATH" MAC_RUNNER_DISABLED=1         python3 "$SCRIPT" --repo acme/one 2>&1)"
RCP=$?
set -e
[ "$RCP" -eq 0 ] || fail "5 parked-leg run exited $RCP"
if grep -qi "possible host outage" <<<"$OUTP"; then
  fail "5 a PARKED leg (MAC_RUNNER_DISABLED=1) was reported as a host outage"
else
  pass "5 parked leg is not reported as a host outage"
fi
grep -qi "parked" <<<"$OUTP" \
  && pass "5b parked leg is named as intentional, not silent" \
  || fail "5b parked leg was silently omitted instead of labelled"

# ---- 6. API error / empty response must not read as 'all offline' --------
mkdir -p "$W/bin-err"
printf '#!/usr/bin/env bash\necho "{\"message\":\"API rate limit exceeded\"}"\nexit 1\n' > "$W/bin-err/gh"
chmod +x "$W/bin-err/gh"
set +e
OUTE="$(env -u BASH_ENV PATH="$W/bin-err:$PATH" python3 "$SCRIPT" --repo acme/one 2>&1)"
RCE=$?
set -e
if [ "$RCE" -eq 0 ]; then
  fail "6 an API error was treated as a successful measurement (rc=0)"
else
  pass "6 API error exits non-zero (rc=$RCE), not a zero/all-offline reading"
fi
grep -qi "MEASUREMENT FAILED" <<<"$OUTE" \
  && pass "6b API error is labelled MEASUREMENT FAILED" \
  || fail "6b API error was not labelled MEASUREMENT FAILED"

# ---- 7. --json must carry the verification boundary -----------------------
# The human render carries the caveat; --json serialised measure() directly and
# dropped it, so a machine consumer kept reading utilization as verified capacity.
set +e
OUTJ="$(env -u BASH_ENV PATH="$W/bin:$PATH" python3 "$SCRIPT" --repo acme/one --json 2>&1)"
RCJ=$?
set -e
[ "$RCJ" -eq 0 ] || fail "7 --json exited $RCJ"
printf '%s' "$OUTJ" > "$W/out.json"
if python3 - "$W/out.json" <<'PYJSON'
import json, sys
d = json.load(open(sys.argv[1]))
fe = d.get("fleet_evidence") or {}
assert fe.get("capacity_verdict") == "UNKNOWN", fe
assert fe.get("not_verified") is True, fe
assert "doctor-runner" in (fe.get("verify_locally_with") or ""), fe
PYJSON
then
  pass "7 --json carries fleet_evidence (capacity UNKNOWN, not_verified)"
else
  fail "7 --json drops the fleet verification boundary"
fi

# ---- 8. opt-out parsing must match doctor-runner exactly ('1' only) -------
# Accepting any non-empty value let "false" suppress a REAL outage warning.
set +e
OUTF="$(env -u BASH_ENV PATH="$W/bin:$PATH" REMOTE_LINUX_DISABLED=false \
        python3 "$SCRIPT" --repo acme/one 2>&1)"
set -e
grep -qE "WHOLE-PREFIX OFFLINE.*ez-runner-c" <<<"$OUTF" \
  && pass "8 REMOTE_LINUX_DISABLED=false does NOT suppress the outage warning" \
  || fail "8 a non-'1' opt-out value suppressed a real outage warning"

echo
if [ "$FAILS" -ne 0 ]; then
  echo "FAILED: $FAILS assertion(s)" >&2
  exit 1
fi
echo "ALL TESTS PASSED!"
