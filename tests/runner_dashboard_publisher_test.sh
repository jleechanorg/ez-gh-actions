#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBLISHER="$ROOT/scripts/publish_runner_dashboard.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PROBES="$WORK/probes"
mkdir -p "$PROBES"

# The queue probe shells out to `gh`. Stub it so this test stays hermetic: it must
# exercise the publisher's DEFAULT path (queue probe enabled) without reaching the
# network. An empty queue payload is a valid probe result.
# The queue probe needs gh, and this host ships a gh wrapper that re-execs the real
# binary, so stubbing `gh` on PATH does not take effect. Inject a fixture probe
# instead, which exercises the publisher's DEFAULT (probe-enabled) path hermetically.
QUEUE_FIXTURE="$WORK/queue-fixture.py"
cat > "$QUEUE_FIXTURE" <<'FIXTURE'
#!/usr/bin/env python3
import json, sys
args = sys.argv[1:]
out = args[args.index("--output") + 1] if "--output" in args else None
payload = {"schema_version": 1, "ok": True, "fresh": 0, "ghosts": 0,
           "oldest_fresh_wait_minutes": None,
           "repos": [{"repo": "jleechanorg/worldarchitect.ai", "ok": True,
                      "fresh": 0, "ghosts": 0,
                      "oldest_fresh_wait_minutes": None, "error": None}]}
encoded = json.dumps(payload, indent=2, sort_keys=True) + "\n"
if out:
    open(out, "w").write(encoded)
else:
    sys.stdout.write(encoded)
FIXTURE
chmod +x "$QUEUE_FIXTURE"
export EZGHA_DASHBOARD_QUEUE_PROBE_CMD="python3 $QUEUE_FIXTURE"

LATENCY_FIXTURE="$WORK/latency-fixture.py"
cat > "$LATENCY_FIXTURE" <<'FIXTURE'
#!/usr/bin/env python3
import json, sys
args = sys.argv[1:]
out = args[args.index("--output") + 1] if "--output" in args else None
payload = {
    "schema_version": 1,
    "ok": True,
    "generated_at": "2026-11-18T09:11:59Z",
    "overall": {
        "queue_wait": {"n": 10, "avg_s": 120.0, "p50_s": 90.0, "p90_s": 240.0, "p99_s": 300.0},
        "execution": {"n": 10, "avg_s": 60.0, "p50_s": 45.0, "p90_s": 120.0, "p99_s": 180.0},
        "e2e": {"n": 10, "avg_s": 180.0, "p50_s": 135.0, "p90_s": 360.0, "p99_s": 480.0},
    },
    "cancellation": {"cancelled_runs": 1, "total_non_skipped_runs": 10, "cancelled_rate_pct": 10.0},
    "workflows": [],
}
encoded = json.dumps(payload, indent=2, sort_keys=True) + "\n"
if out:
    open(out, "w").write(encoded)
else:
    sys.stdout.write(encoded)
FIXTURE
chmod +x "$LATENCY_FIXTURE"
export EZGHA_DASHBOARD_LATENCY_PROBE_CMD="python3 $LATENCY_FIXTURE"

write_probe() {
  local path="$1" host_class="$2" configured="$3" executing="$4"
  sed -n '1,$p' > "$path" <<EOF
#!/usr/bin/env bash
echo '{"schema_version":1,"host_class":"$host_class","sources":{"config":{"ok":true},"service":{"ok":true},"docker":{"ok":true},"process_probe":{"ok":true},"disk":{"ok":true},"watchdog_state":{"ok":true}},"fleet":{"configured":$configured,"executing":$executing,"idle":1,"cycling":0,"down":0,"reserved":$configured},"disk":{"status":"healthy"},"watchdog":{"consecutive_misses":0,"restart_after":3},"raw":"must-not-publish","host":"secret-host"}'
EOF
  chmod +x "$path"
}
# Real fleet shapes (2026-11-17): 4 Mac, 20 Linux. The snapshot fails closed when a
# host's configured count disagrees with EXPECTED_CONFIGURED, so these fixtures must
# track the live fleet or a healthy probe renders as UNKNOWN.
write_probe "$PROBES/mac.sh" mac 4 3   # 3 executing + 1 idle = 4
write_probe "$PROBES/linux.sh" linux 20 19   # 19 executing + 1 idle = 20

SITE="$WORK/site"
EZGHA_DASHBOARD_PROBE_DIR="$PROBES" \
EZGHA_DASHBOARD_ASSET_DIR="$ROOT/dashboard" \
EZGHA_DASHBOARD_LOCK_DIR="$WORK/collect.lock" \
bash "$PUBLISHER" --collect-only "$SITE"
for file in .nojekyll index.html style.css dashboard.js status.json; do
  test -f "$SITE/$file"
done
SITE="$SITE" python3 - <<'PY'
import json
import os
from pathlib import Path

payload = json.loads((Path(os.environ["SITE"]) / "status.json").read_text())
assert payload["sources"] == {
    "mac_host": {"ok": True},
    "linux_host": {"ok": True},
}
serialized = json.dumps(payload)
assert "must-not-publish" not in serialized
assert "secret-host" not in serialized
# The queue block is present in the default publish path and carries its own ok.
assert payload["queue"]["ok"] is True, payload["queue"]
assert payload["queue"]["fresh"] == 0 and payload["queue"]["ghosts"] == 0
assert payload["latency"]["ok"] is True, payload["latency"]
assert payload["latency"]["overall"]["queue_wait"]["p50_s"] == 90.0
assert payload["reconciliation"]["active_job_slots_occupied"] == 22
PY

DEFAULT_HOME="$WORK/default-home"
mkdir -p "$DEFAULT_HOME"
HOME="$DEFAULT_HOME" \
EZGHA_DASHBOARD_PROBE_DIR="$PROBES" \
EZGHA_DASHBOARD_ASSET_DIR="$ROOT/dashboard" \
bash "$PUBLISHER" --collect-only "$WORK/default-lock-site"
DEFAULT_STATE_DIR="$DEFAULT_HOME/.local/state/ezgha"
test -d "$DEFAULT_STATE_DIR"
if MODE="$(stat -f %Lp "$DEFAULT_STATE_DIR" 2>/dev/null)"; then
  :
else
  MODE="$(stat -c %a "$DEFAULT_STATE_DIR")"
fi
test "$MODE" = "700"

printf 'keep until replacement succeeds\n' > "$SITE/sentinel.txt"
set +e
OUTPUT="$({
  EZGHA_DASHBOARD_PROBE_DIR="$PROBES" \
  EZGHA_DASHBOARD_ASSET_DIR="$WORK/missing-assets" \
  EZGHA_DASHBOARD_LOCK_DIR="$WORK/failing-collect.lock" \
  bash "$PUBLISHER" --collect-only "$SITE"
} 2>&1)"
STATUS=$?
set -e
test "$STATUS" -ne 0
test "$(cat "$SITE/sentinel.txt")" = "keep until replacement succeeds"

EZGHA_DASHBOARD_PROBE_DIR="$PROBES" \
EZGHA_DASHBOARD_ASSET_DIR="$ROOT/dashboard" \
EZGHA_DASHBOARD_LOCK_DIR="$WORK/recollect.lock" \
bash "$PUBLISHER" --collect-only "$SITE"
test ! -e "$SITE/sentinel.txt"

REMOTE="$WORK/dashboard.git"
git init -q --bare "$REMOTE"
GIT_CONFIG_GLOBAL="$WORK/gitconfig"
git config -f "$GIT_CONFIG_GLOBAL" user.name "Runner Dashboard Test"
git config -f "$GIT_CONFIG_GLOBAL" user.email "jleechan2015@users.noreply.github.com"

publish() {
  GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" \
  GIT_CONFIG_NOSYSTEM=1 \
  EZGHA_DASHBOARD_ALLOW_LOCAL_REMOTE=1 \
  EZGHA_DASHBOARD_PUBLISH_REMOTE="$REMOTE" \
  EZGHA_DASHBOARD_PROBE_DIR="$PROBES" \
  EZGHA_DASHBOARD_ASSET_DIR="$ROOT/dashboard" \
  EZGHA_DASHBOARD_LOCK_DIR="$WORK/publish.lock" \
  bash "$PUBLISHER" --publish
}
publish

EXPECTED="$(printf '%s\n' \
  .ezgha-runner-dashboard-owned \
  .nojekyll \
  dashboard.js \
  index.html \
  status.json \
  style.css | LC_ALL=C sort)"
ACTUAL="$(git --git-dir="$REMOTE" ls-tree -r --name-only gh-pages | LC_ALL=C sort)"
test "$ACTUAL" = "$EXPECTED"
test "$(git --git-dir="$REMOTE" show gh-pages:.ezgha-runner-dashboard-owned)" = \
  "ezgha-runner-dashboard:v1"
publish
test "$(git --git-dir="$REMOTE" ls-tree -r --name-only gh-pages | LC_ALL=C sort)" = \
  "$EXPECTED"

SEED="$WORK/seed"
git init -q "$SEED"
git -C "$SEED" config user.name "Runner Dashboard Test"
git -C "$SEED" config user.email "jleechan2015@users.noreply.github.com"
printf 'existing public content\n' > "$SEED/existing.html"
git -C "$SEED" add existing.html
git -C "$SEED" commit -qm "seed unowned branch"
git -C "$SEED" remote add origin "$REMOTE"
git -C "$SEED" push -q origin HEAD:legacy-pages
set +e
OUTPUT="$({
  EZGHA_DASHBOARD_PUBLISH_BRANCH=legacy-pages publish
} 2>&1)"
STATUS=$?
set -e
test "$STATUS" -ne 0
[[ "$OUTPUT" == *"ownership marker"* ]]
test "$(git --git-dir="$REMOTE" show legacy-pages:existing.html)" = "existing public content"

TREE_PROBES="$WORK/tree-probes"
mkdir -p "$TREE_PROBES"
cat > "$TREE_PROBES/mac.sh" <<'SH'
#!/usr/bin/env bash
bash -c 'trap "" TERM; sleep 60' &
child=$!
printf '%s\n' "$child" > "${TREE_CHILD_PID:?}"
wait "$child"
SH
chmod +x "$TREE_PROBES/mac.sh"
cp "$PROBES/linux.sh" "$TREE_PROBES/linux.sh"
TREE_CHILD_PID="$WORK/tree-child.pid" \
EZGHA_DASHBOARD_PROBE_TIMEOUT_SECONDS=1 \
EZGHA_DASHBOARD_PROBE_DIR="$TREE_PROBES" \
EZGHA_DASHBOARD_ASSET_DIR="$ROOT/dashboard" \
EZGHA_DASHBOARD_LOCK_DIR="$WORK/tree-timeout.lock" \
bash "$PUBLISHER" --collect-only "$WORK/tree-timeout-site"
CHILD_PID="$(cat "$WORK/tree-child.pid")"
if kill -0 "$CHILD_PID" 2>/dev/null; then
  echo "timed-out probe descendant survived: $CHILD_PID" >&2
  kill "$CHILD_PID" 2>/dev/null || true
  exit 1
fi

FAILING_LATENCY_PROBE="$WORK/failing_latency_probe.sh"
cat > "$FAILING_LATENCY_PROBE" <<'SH'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--output" ]]; then
    out="$2"
    shift 2
  else
    shift
  fi
done
[[ -n "$out" ]] && printf '{partial' > "$out"
exit 1
SH
chmod +x "$FAILING_LATENCY_PROBE"

/bin/bash -c '
  EZGHA_DASHBOARD_QUEUE_PROBE=0 \
  EZGHA_DASHBOARD_LATENCY_PROBE=1 \
  EZGHA_DASHBOARD_LATENCY_PROBE_CMD="$1" \
  EZGHA_DASHBOARD_CMUX_PROBE_CMD="" \
  EZGHA_DASHBOARD_PROBE_DIR="$2" \
  EZGHA_DASHBOARD_ASSET_DIR="$3" \
  EZGHA_DASHBOARD_LOCK_DIR="$4" \
  /bin/bash "$5" --collect-only "$6"
' _ "$FAILING_LATENCY_PROBE" "$PROBES" "$ROOT/dashboard" "$WORK/bash32.lock" "$PUBLISHER" "$WORK/bash32-site"
test -s "$WORK/bash32-site/status.json"
python3 - "$WORK/bash32-site/status.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    doc = json.load(fh)
assert doc["latency"]["ok"] is False, doc["latency"]
assert doc["queue"]["ok"] is False, doc["queue"]
assert doc["cmux"]["ok"] is False, doc["cmux"]
PY

ARGS_QUEUE_PROBE="$WORK/args_queue_probe.sh"
ARGS_LATENCY_PROBE="$WORK/args_latency_probe.sh"
QUEUE_ARGS_LOG="$WORK/queue_args.log"
LATENCY_ARGS_LOG="$WORK/latency_args.log"
cat > "$ARGS_QUEUE_PROBE" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${QUEUE_ARGS_LOG:?}"
out=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--output" ]]; then out="$2"; shift 2; else shift; fi
done
[[ -n "$out" ]] && printf '{"ok":true,"repos":[]}\n' > "$out"
SH
cat > "$ARGS_LATENCY_PROBE" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${LATENCY_ARGS_LOG:?}"
out=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--output" ]]; then out="$2"; shift 2; else shift; fi
done
[[ -n "$out" ]] && printf '{"ok":true,"overall":{},"workflows":[]}\n' > "$out"
SH
chmod +x "$ARGS_QUEUE_PROBE" "$ARGS_LATENCY_PROBE"

for qmax in 0100 0999 08 0 abc -5; do
  QUEUE_ARGS_LOG="$QUEUE_ARGS_LOG" LATENCY_ARGS_LOG="$LATENCY_ARGS_LOG" \
  EZGHA_DASHBOARD_QUEUE_PROBE=1 \
  EZGHA_DASHBOARD_QUEUE_PROBE_CMD="$ARGS_QUEUE_PROBE" \
  EZGHA_DASHBOARD_QUEUE_MAX_REQUESTS="$qmax" \
  EZGHA_DASHBOARD_LATENCY_PROBE=1 \
  EZGHA_DASHBOARD_LATENCY_PROBE_CMD="$ARGS_LATENCY_PROBE" \
  EZGHA_DASHBOARD_CMUX_PROBE_CMD="" \
  EZGHA_DASHBOARD_PROBE_DIR="$PROBES" \
  EZGHA_DASHBOARD_ASSET_DIR="$ROOT/dashboard" \
  EZGHA_DASHBOARD_LOCK_DIR="$WORK/clamp-${qmax}.lock" \
  /bin/bash "$PUBLISHER" --collect-only "$WORK/clamp-${qmax}-site"
done
python3 - "$QUEUE_ARGS_LOG" "$LATENCY_ARGS_LOG" <<'PY'
import re, sys
from pathlib import Path
q_lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
expected = ["80", "80", "8", "1", "80", "80"]
assert len(q_lines) == len(expected), q_lines
for line, want in zip(q_lines, expected):
    m = re.search(r"--max-requests\s+(\S+)", line)
    assert m and m.group(1) == want, f"expected --max-requests {want}, got {line}"
l_lines = Path(sys.argv[2]).read_text(encoding="utf-8").splitlines()
assert len(l_lines) == len(expected)
for line in l_lines:
    assert "--limit 30 --job-run-limit 20" in line, line
PY

PARTIAL_QUEUE_PROBE="$WORK/partial_queue_probe.sh"
cat > "$PARTIAL_QUEUE_PROBE" <<'SH'
#!/usr/bin/env bash
out=""
max_req=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    --max-requests) max_req="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cat > "$out" <<JSON
{"schema_version":1,"ok":false,"partial":true,"unverified_runs":5,"fresh":null,"ghosts":null,"oldest_fresh_wait_minutes":null,"in_progress_runs":null,"errors":["budget exhausted at ${max_req}"],"repos":[{"repo":"org/r1","ok":true,"fresh":2,"ghosts":1,"partial":false},{"repo":"org/r2","ok":false,"fresh":null,"ghosts":null,"partial":true,"unverified_runs":5}]}
JSON
exit 1
SH
chmod +x "$PARTIAL_QUEUE_PROBE"
EZGHA_DASHBOARD_QUEUE_PROBE=1 \
EZGHA_DASHBOARD_QUEUE_PROBE_CMD="$PARTIAL_QUEUE_PROBE" \
EZGHA_DASHBOARD_QUEUE_MAX_REQUESTS=1 \
EZGHA_DASHBOARD_LATENCY_PROBE=0 \
EZGHA_DASHBOARD_CMUX_PROBE_CMD="" \
EZGHA_DASHBOARD_PROBE_DIR="$PROBES" \
EZGHA_DASHBOARD_ASSET_DIR="$ROOT/dashboard" \
EZGHA_DASHBOARD_LOCK_DIR="$WORK/partial-exhaust.lock" \
  /bin/bash "$PUBLISHER" --collect-only "$WORK/partial-exhaust-site"
python3 - "$WORK/partial-exhaust-site/status.json" <<'PY'
import json, sys
doc = json.loads(open(sys.argv[1], encoding="utf-8").read())
assert doc["queue"]["ok"] is False, doc["queue"]
assert doc["queue"]["partial"] is True, doc["queue"]
assert doc["queue"]["unverified_runs"] == 5, doc["queue"]
assert len(doc["queue"]["repos"]) == 2, doc["queue"]
PY

BAD_NESTED_QUEUE="$WORK/bad_nested_queue_probe.sh"
cat > "$BAD_NESTED_QUEUE" <<'SH'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--output" ]]; then out="$2"; shift 2; else shift; fi
done
printf '{"schema_version":1,"repos":[],"queue":{"repos":"invalid"}}\n' > "$out"
exit 1
SH
chmod +x "$BAD_NESTED_QUEUE"
EZGHA_DASHBOARD_QUEUE_PROBE=1 \
EZGHA_DASHBOARD_QUEUE_PROBE_CMD="$BAD_NESTED_QUEUE" \
EZGHA_DASHBOARD_LATENCY_PROBE=0 \
EZGHA_DASHBOARD_CMUX_PROBE_CMD="" \
EZGHA_DASHBOARD_PROBE_DIR="$PROBES" \
EZGHA_DASHBOARD_ASSET_DIR="$ROOT/dashboard" \
EZGHA_DASHBOARD_LOCK_DIR="$WORK/bad-nested-q.lock" \
  /bin/bash "$PUBLISHER" --collect-only "$WORK/bad-nested-q-site"
python3 - "$WORK/bad-nested-q-site/status.json" <<'PY'
import json, sys
doc = json.loads(open(sys.argv[1], encoding="utf-8").read())
assert doc["sources"]["mac_host"]["ok"] is True
assert doc["queue"]["ok"] is False, doc["queue"]
PY

EXIT0_NONLIST_QUEUE="$WORK/exit0_nonlist_queue_probe.sh"
cat > "$EXIT0_NONLIST_QUEUE" <<'SH'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--output" ]]; then out="$2"; shift 2; else shift; fi
done
printf '{"schema_version":1,"ok":true,"repos":"invalid"}\n' > "$out"
exit 0
SH
chmod +x "$EXIT0_NONLIST_QUEUE"
EZGHA_DASHBOARD_QUEUE_PROBE=1 \
EZGHA_DASHBOARD_QUEUE_PROBE_CMD="$EXIT0_NONLIST_QUEUE" \
EZGHA_DASHBOARD_LATENCY_PROBE=0 \
EZGHA_DASHBOARD_CMUX_PROBE_CMD="" \
EZGHA_DASHBOARD_PROBE_DIR="$PROBES" \
EZGHA_DASHBOARD_ASSET_DIR="$ROOT/dashboard" \
EZGHA_DASHBOARD_LOCK_DIR="$WORK/exit0-nonlist-q.lock" \
  /bin/bash "$PUBLISHER" --collect-only "$WORK/exit0-nonlist-q-site"
python3 - "$WORK/exit0-nonlist-q-site/status.json" <<'PY'
import json, sys
doc = json.loads(open(sys.argv[1], encoding="utf-8").read())
assert doc["sources"]["mac_host"]["ok"] is True
assert doc["queue"]["ok"] is False, doc["queue"]
PY

EXIT0_MIXED_QUEUE="$WORK/exit0_mixed_queue_probe.sh"
cat > "$EXIT0_MIXED_QUEUE" <<'SH'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--output" ]]; then out="$2"; shift 2; else shift; fi
done
printf '{"schema_version":1,"ok":true,"repos":[{"repo":"org/a","ok":true,"fresh":1,"ghosts":0},"bad"]}\n' > "$out"
exit 0
SH
chmod +x "$EXIT0_MIXED_QUEUE"
EZGHA_DASHBOARD_QUEUE_PROBE=1 \
EZGHA_DASHBOARD_QUEUE_PROBE_CMD="$EXIT0_MIXED_QUEUE" \
EZGHA_DASHBOARD_LATENCY_PROBE=0 \
EZGHA_DASHBOARD_CMUX_PROBE_CMD="" \
EZGHA_DASHBOARD_PROBE_DIR="$PROBES" \
EZGHA_DASHBOARD_ASSET_DIR="$ROOT/dashboard" \
EZGHA_DASHBOARD_LOCK_DIR="$WORK/exit0-mixed-q.lock" \
  /bin/bash "$PUBLISHER" --collect-only "$WORK/exit0-mixed-q-site"
python3 - "$WORK/exit0-mixed-q-site/status.json" <<'PY'
import json, sys
doc = json.loads(open(sys.argv[1], encoding="utf-8").read())
assert doc["sources"]["mac_host"]["ok"] is True
assert doc["queue"]["ok"] is False, doc["queue"]
PY

echo "runner dashboard publisher tests passed"
