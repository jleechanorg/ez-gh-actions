#!/usr/bin/env bash
# Hermetic coverage for the bounded, ALLOWLISTED Docker-probe diagnostic
# (`jsonPayload.probe_diag`) added to scripts/ezgha-host-health-alert.sh.
#
# Why: a blind row that said only "local: Docker runner inventory or process
# evidence incomplete" cost a full manual classification pass (2026-11-24,
# Jeff-Ubuntu, 49 rows/24h: cause=blind, blind_source=docker, container_count=null).
# The probe now reports its failing leg, the container id and a fixed error
# classification on fd 8, and this script carries that one line into the row.
#
# What this asserts (through the emitted payload / persisted state / retained
# storage — never by grepping the source):
#   1. A successful probe is unchanged and emits no diagnostic.
#   2. Every original failure classification is preserved: same status, cause,
#      blind_source, failed_checks, container_count=null and the same
#      WARNING->ERROR escalation on a second consecutive blind poll.
#   3. The failing leg, container id and an ALLOWLISTED detail reach the row;
#      raw docker text never does (the secrets fixture proves it).
#   4. Retained storage is bounded by the probe's own line, not by producer
#      output: a 2 MB docker error burst retains <= 256 bytes, measured on the
#      real file via HEALTH_ALERT_PROBE_DIAG_KEEP=1.
#   5. Capture cannot blind a healthy probe: an unusable TMPDIR falls back.
#   6. The monitor's own stderr stays visible after a capture-on probe (guards
#      the `exec ... 2>/dev/null` redirection-leak class).
#   7. The 10s probe timeout and its classification are unchanged.
#   8. Only owned scratch artifacts are removed; unrelated files survive.
#   9. Non-Docker blind sources never carry the Docker diagnostic.
#  10. The sanitizer strips control text, bounds size and redacts credential
#      labels case-insensitively (UPPERCASE TOKEN=/PASSWORD: included).
#
# Reproduce a RED run against any other revision of the script:
#   git show <sha>:scripts/ezgha-host-health-alert.sh > /tmp/base.sh
#   HEALTH_ALERT_SCRIPT_UNDER_TEST=/tmp/base.sh bash tests/ezgha_host_health_alert_probe_diag_test.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="${HEALTH_ALERT_SCRIPT_UNDER_TEST:-$ROOT/scripts/ezgha-host-health-alert.sh}"
[ -s "$S" ] || { echo "FAIL: script not found: $S" >&2; exit 1; }
# The monitor injects probe_runner_count with `declare -f` into a bounded
# `bash -c`. Bash 3.2 (macOS /bin/bash) rewrites `$'\n'` inside that function as
# ANSI-C quoting, which corrupts the injected probe — a PRE-EXISTING shell
# round-trip limitation, unrelated to the diagnostic added here and deliberately
# not changed in this patch (it would touch probe mechanics). Run the monitor
# under a bash that round-trips faithfully so the cells assert this patch.
MONITOR_BASH="${HEALTH_ALERT_TEST_BASH:-}"
if [ -z "$MONITOR_BASH" ]; then
  for cand in /opt/homebrew/bin/bash /usr/local/bin/bash /bin/bash; do
    if [ -x "$cand" ] && [ "$("$cand" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null)" -ge 4 ] 2>/dev/null; then
      MONITOR_BASH="$cand"; break
    fi
  done
fi
if [ -z "$MONITOR_BASH" ]; then
  # No bash >= 4 on this host: the count/identity-sensitive assertions below are
  # relaxed (see MONITOR_BASH_MAJOR) rather than skipped entirely.
  MONITOR_BASH=/bin/bash
fi
MONITOR_BASH_MAJOR="$("$MONITOR_BASH" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null || echo 0)"
W="$(mktemp -d)"
trap 'rm -rf "${W:?}"' EXIT
FAILED=0
HOSTNAME_FIXTURE=test-probe-diag

# ── stubs ──────────────────────────────────────────────────────────────────
cat > "$W/gcloud" <<'STUB'
#!/usr/bin/env bash
jq -c --arg severity "$6" '. + {dispatch: $severity}' <<<"$4" >> "$STUB_LOG"
STUB
cat > "$W/docker" <<'STUB'
#!/usr/bin/env bash
ID1=$(printf '%064d' 1)
ID2=$(printf '%064d' 2)
if [ -n "${CALL_DIR:-}" ]; then printf '.' >> "$CALL_DIR/${1:-unknown}" 2>/dev/null || :; fi
fixture="${DOCKER_FIXTURE:-healthy}"
if [ "${1:-}" = ps ]; then
  case "$fixture" in
    ps-fail)
      printf 'Error response from daemon: Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?\n' >&2
      exit 1 ;;
    flood)
      # 2 MB of producer noise. None of it may be retained, and the producer must
      # not be killed by a truncated read (it finishes and exits on its own).
      # Real 2 MB of producer noise (portable awk: no NUL/tr escape assumptions).
      # None of it may be retained, and the producer must not be killed by a
      # truncated read: it finishes and exits on its own.
      awk 'BEGIN{s="";for(i=0;i<100;i++)s=s"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";for(i=0;i<200;i++)printf "%s",s}' >&2
      awk 'BEGIN{s="";for(i=0;i<100;i++)s=s"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";print length(s)*200}' > "${FLOOD_BYTES_FILE:-/dev/null}" 2>/dev/null || :
      printf '
Error response from daemon: Cannot connect to the Docker daemon
' >&2
      exit 1 ;;
    secrets)
      # Adversarial provider text: control chars, an UPPERCASE credential label,
      # a mixed-case one and a URL with inline credentials. None may reach the row.
      printf 'WARN[31mred[0m
	TOKEN=credential-sentinel
PASSWORD: hunter2
Authorization: Bearer SECRETBEARER
https://user:pw@example.invalid/x
' >&2
      exit 1 ;;
    slow)
      sleep 30
      exit 0 ;;
    blank) echo; exit 0 ;;
    all-vanished|vanished-long) printf '%s\n%s\n' "$ID1" "$ID2"; exit 0 ;;
    *) printf '%s\n' "$ID1"; exit 0 ;;
  esac
fi
if [ "${1:-}" = top ]; then
  case "$fixture" in
    top-fail)
      printf 'Error response from daemon: context deadline exceeded
' >&2
      exit 1 ;;
    malformed)
      printf 'PID COMMAND\nnot-a-pid Runner.Worker\n' ;;
    all-vanished)
      printf 'Error response from daemon: No such container: %s\n' "$2" >&2
      exit 1 ;;
    vanished-long)
      # One container is gone with the daemon's absence line followed by 200 KB of
      # trailing junk; the other is healthy. The authoritative classifier must
      # still call the first ABSENT even though no diagnostic excerpt can hold
      # the whole text, and the surviving container must still be counted.
      if [ "$2" = "$ID2" ]; then
        printf 'Error response from daemon: No such container: %s\n' "$2" >&2
        awk 'BEGIN{s="";for(i=0;i<100;i++)s=s"jjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjj";for(i=0;i<2000;i++)printf "%s",s}' >&2
        exit 1
      fi
      printf 'PID COMMAND\n1 Runner.Listener\n' ;;
    *)
      printf 'PID COMMAND\n1 Runner.Listener\n' ;;
  esac
  exit 0
fi
exit 1
STUB
cat > "$W/systemctl" <<'STUB'
#!/usr/bin/env bash
echo active
STUB
cat > "$W/df-fail" <<'STUB'
#!/usr/bin/env bash
printf 'Filesystem 1G-blocks Used Available Use%% Mounted on\n/dev/test 100G 90G 10G 90%% /\n'
exit 1
STUB
chmod +x "$W/gcloud" "$W/docker" "$W/systemctl"

# ── harness ────────────────────────────────────────────────────────────────
run() { # case [VAR=value ...]
  local name="$1"; shift
  local tmp="$W/tmp-$name"
  mkdir -p "$tmp" "$W/calls-$name"
  : > "$W/log-$name"
  env GCLOUD_BIN="$W/gcloud" STUB_LOG="$W/log-$name" DOCKER_BIN="$W/docker" \
    TMPDIR="$tmp" CALL_DIR="$W/calls-$name" \
    HEALTH_ALERT_HOST="$HOSTNAME_FIXTURE" HEALTH_ALERT_PLATFORM=Linux \
    HEALTH_ALERT_STATE_DIR="$W/state-$name" HEALTH_ALERT_SERVICE_OK=1 \
    HEALTH_ALERT_PEER_OK=1 HEALTH_ALERT_FREE_GB=100 HEALTH_ALERT_CONTAINER_COUNT= \
    HEALTH_ALERT_ALERTS_FILE="$W/$name.jsonl" MAC_RUNNER_DISABLED=0 REMOTE_LINUX_DISABLED=0 \
    "$@" "$MONITOR_BASH" "$S" > "$W/out-$name" 2>&1
  echo "$?"
}

expect() { # case jq-assertion description
  if jq -es "$2" "$W/log-$1" >/dev/null 2>&1; then
    echo "PASS: $3"
  else
    echo "FAIL: $3"
    echo "      rows: $(tr '\n' '|' < "$W/log-$1" | head -c 600)"
    FAILED=1
  fi
}

expect_out() { # case needle description
  if grep -Fq "$2" "$W/out-$1"; then
    echo "PASS: $3"
  else
    echo "FAIL: $3 (stdout/stderr: $(tr '\n' '|' < "$W/out-$1" | head -c 300))"
    FAILED=1
  fi
}

expect_out_re() { # case regex description
  if grep -Eq "$2" "$W/out-$1"; then
    echo "PASS: $3"
  else
    echo "FAIL: $3 (stdout/stderr: $(tr '\n' '|' < "$W/out-$1" | head -c 300))"
    FAILED=1
  fi
}
expect_out_absent() { # case needle description
  if grep -Fq "$2" "$W/out-$1"; then
    echo "FAIL: $3 (found '$2' in output)"
    FAILED=1
  else
    echo "PASS: $3"
  fi
}

calls() { # case verb -> count of docker invocations of that verb
  local f="$W/calls-$1/$2"
  if [ -f "$f" ]; then wc -c < "$f" | tr -d ' '; else echo 0; fi
}

expect_calls() { # case verb want description
  local got
  got=$(calls "$1" "$2")
  if [ "$got" = "$3" ]; then
    echo "PASS: $4"
  else
    echo "FAIL: $4 (docker $2 calls: got $got, want $3)"; FAILED=1
  fi
}

expect_no_scratch() { # case description
  local left
  left=$(find "$W/tmp-$1" -maxdepth 1 -name 'ezgha-probe-diag.*' 2>/dev/null | wc -l | tr -d ' ')
  if [ "$left" = 0 ]; then
    echo "PASS: $2"
  else
    echo "FAIL: $2 (leftovers: $left)"; FAILED=1
  fi
}

# ── 1. successful probe: unchanged, no diagnostic ──────────────────────────
rc=$(run healthy)
[ "$rc" = 0 ] || { echo "FAIL: healthy run exited $rc"; FAILED=1; }
expect healthy 'length == 0' "healthy probe dispatches nothing"
expect_out healthy "MUTUAL HEALTH CHECK OK" "healthy probe still reports MUTUAL HEALTH CHECK OK"
expect_out_re healthy 'Local: [1-9][0-9]* containers' "healthy probe still counts a live runner"
if [ "$MONITOR_BASH_MAJOR" -ge 4 ]; then
  expect_out healthy "Local: 1 containers" "healthy probe counts exactly the one managed container"
else
  echo "SKIP: exact container count (monitor bash $MONITOR_BASH_MAJOR cannot round-trip declare -f)"
fi
expect healthy 'all(.probe_diag == null)' "no diagnostic field is emitted on a successful probe"
expect_no_scratch healthy "a successful probe leaves no scratch artifact"
expect_calls healthy ps 1 "a healthy poll issues exactly one docker ps (no added invocation)"
expect_calls healthy top 1 "a healthy poll issues exactly one docker top per container"

# ── 2/3. docker-top failure: classification preserved, leg + container named ─
rc=$(run top-fail DOCKER_FIXTURE=top-fail)
[ "$rc" = 0 ] || { echo "FAIL: top-fail first poll exited $rc"; FAILED=1; }
expect top-fail 'length == 1
  and (.[0].status == "BLIND" and .[0].cause == "blind" and .[0].blind_source == "docker")
  and .[0].severity == "WARNING" and .[0].dispatch == "--severity=WARNING"
  and .[0].container_count == null
  and (.[0].failed_checks == ["local: Docker runner inventory or process evidence incomplete"])
  and (.[0].probe_diag | test("^probe_fail leg=docker-top container=([0-9a-f]{64}|unknown) detail=timeout$"))' \
  "top failure: blind/WARNING/null count and failed_checks are unchanged, and the row names leg, container and allowlisted detail"
if [ "$MONITOR_BASH_MAJOR" -ge 4 ]; then
  expect top-fail '.[0].probe_diag | contains("container=0000000000000000000000000000000000000000000000000000000000000001")' \
    "top failure: the specific failing container id is recorded"
fi
jq -e '.docker_blind == 1' "$W/state-top-fail/host-health-alert-$HOSTNAME_FIXTURE.json" >/dev/null 2>&1 \
  && echo "PASS: top failure: persisted docker_blind=1 is unchanged" \
  || { echo "FAIL: top failure: persisted docker_blind=1 is unchanged"; FAILED=1; }
expect_calls top-fail ps 1 "a failing inventory is read once, never retried"
expect_calls top-fail top 2 "a top failure uses only the pre-existing single error re-read (2 calls, unchanged)"
# Second consecutive blind poll escalates exactly as before.
rc=$(run top-fail DOCKER_FIXTURE=top-fail)
[ "$rc" = 0 ] || { echo "FAIL: top-fail second poll exited $rc"; FAILED=1; }
expect top-fail 'length == 1 and (.[0].dispatch == "--severity=ERROR") and .[0].severity == "ERROR"
  and (.[0].probe_diag | contains("leg=docker-top"))' \
  "top failure: the second consecutive blind poll still escalates to ERROR and stays diagnosable"
expect_no_scratch top-fail "a failed probe leaves no scratch artifact"

# ── 3. malformed table names the process-table leg ─────────────────────────
run malformed DOCKER_FIXTURE=malformed >/dev/null
expect malformed 'length == 1 and .[0].cause == "blind" and .[0].container_count == null
  and (.[0].failed_checks == ["local: Docker runner inventory or process evidence incomplete"])
  and (.[0].probe_diag | test("^probe_fail leg=process-table container=([0-9a-f]{64}|unknown) detail=table-shape$"))' \
  "malformed table: classification unchanged, leg=process-table and the container id are recorded"

# ── 3. docker ps failure names the inventory leg and the daemon text ───────
run ps-fail DOCKER_FIXTURE=ps-fail >/dev/null
expect ps-fail 'length == 1 and .[0].cause == "blind" and .[0].container_count == null
  and (.[0].probe_diag == "probe_fail leg=docker-ps detail=inventory-unavailable")' \
  "docker ps failure: classification unchanged, and the row names leg=docker-ps with a fixed code"
expect_calls ps-fail ps 1 "a docker ps failure spends exactly one inventory call (no diagnostic retry)"
expect_calls ps-fail top 0 "a docker ps failure issues no docker top call"

# ── 3. every container vanished keeps unknown capacity and says so ─────────
run all-vanished DOCKER_FIXTURE=all-vanished >/dev/null
expect all-vanished 'length == 1 and .[0].cause == "blind" and .[0].container_count == null
  and (.[0].probe_diag == "probe_fail leg=all-vanished vanished=2 detail=all-containers-gone")' \
  "all-vanished inventory: never a live zero, and the vanish count is recorded"

# Absence classification must not depend on the diagnostic excerpt: a daemon
# "No such container" line followed by 200 KB of junk is still ABSENT.
run vanished-long DOCKER_FIXTURE=vanished-long >/dev/null
expect vanished-long 'length == 0' \
  "a long error keeps its authoritative absence verdict: no blind row, no fleet page"
expect_out vanished-long "MUTUAL HEALTH CHECK OK" "a long error still resolves to a healthy mutual check"
expect_out vanished-long "Local: 1 containers" "the surviving container is still counted (absence stayed absent)"
expect_calls vanished-long ps 1 "the absence case reads the inventory once"
expect_calls vanished-long top 3 "the absence case performs one top read per container plus the pre-existing single error re-read (3 calls)"

# A blank listing must stay incomplete evidence, never a live zero. This cell is
# the regression guard for this patch: dropping the '.' sentinel in the ps capture
# silently turned a blank row into container_count=0 (a fleet DOWN page).
run blank DOCKER_FIXTURE=blank >/dev/null
expect blank 'length == 1 and .[0].cause == "blind" and .[0].container_count == null' \
  "a blank docker listing stays blind (incomplete evidence), never a live zero"

# ── 4. 2 MB producer burst: bounded payload, no deadlock, nothing retained ─
SECONDS=0
rc=$(run flood DOCKER_FIXTURE=flood FLOOD_BYTES_FILE="$W/flood_bytes")
elapsed=$SECONDS
[ "$rc" = 0 ] || { echo "FAIL: flood run exited $rc"; FAILED=1; }
if [ "$elapsed" -le 20 ]; then
  echo "PASS: a 2MB docker error burst does not deadlock or slow the probe (${elapsed}s)"
else
  echo "FAIL: a 2MB docker error burst does not deadlock or slow the probe (${elapsed}s)"; FAILED=1
fi
flood_bytes=$(cat "$W/flood_bytes" 2>/dev/null || echo "")
if [ "$flood_bytes" = "2000000" ]; then
  echo "PASS: the flood fixture really emitted 2000000 bytes of producer stderr"
else
  echo "FAIL: the flood fixture really emitted 2000000 bytes of producer stderr (got '${flood_bytes:-missing}')"; FAILED=1
fi
expect flood 'length == 1 and .[0].cause == "blind" and .[0].container_count == null
  and (.[0].probe_diag == "probe_fail leg=docker-ps detail=inventory-unavailable")
  and ((.[0].probe_diag | length) <= 160)
  and ((.[0].probe_diag | test("x{64}")) | not)' \
  "2MB of producer noise retains only the probe line: bounded, no raw text, no xx-run"

# Measure the actual retained file (real storage, not a claim).
mkdir -p "$W/tmp-retained"
printf 'keep\n' > "$W/tmp-retained/keepme.txt"
rc=$(run retained DOCKER_FIXTURE=flood FLOOD_BYTES_FILE="$W/retained_flood_bytes" HEALTH_ALERT_PROBE_DIAG_KEEP=1)
[ "$rc" = 0 ] || { echo "FAIL: retained run exited $rc"; FAILED=1; }
retained_bytes=$(sed -n 's/.*probe diag retained: \([0-9][0-9]*\) bytes.*/\1/p' "$W/out-retained" | head -1)
retained_path=$(sed -n 's/.*probe diag retained: [0-9][0-9]* bytes (\(.*\))$/\1/p' "$W/out-retained" | head -1)
if [ -n "${retained_bytes:-}" ] && [ "$retained_bytes" -le 256 ]; then
  echo "PASS: maximum retained storage after a 2MB producer burst is ${retained_bytes}B (<= 256B)"
else
  echo "FAIL: maximum retained storage after a 2MB producer burst is '${retained_bytes:-missing}' (want <= 256B)"; FAILED=1
fi
if [ -n "${retained_path:-}" ] && [ -f "$retained_path" ]; then
  on_disk=$(wc -c < "$retained_path" | tr -d ' ')
  if [ "$on_disk" -le 256 ]; then
    echo "PASS: the owned temp file itself holds ${on_disk}B (no producer output on disk)"
  else
    echo "FAIL: the owned temp file itself holds ${on_disk}B (no producer output on disk)"; FAILED=1
  fi
  rm -f -- "$retained_path"
else
  echo "FAIL: retained temp file was not reported/created for measurement"; FAILED=1
fi
if [ -f "$W/tmp-retained/keepme.txt" ]; then
  echo "PASS: unrelated scratch files survive a keep-mode probe run"
else
  echo "FAIL: unrelated scratch files survive a keep-mode probe run"; FAILED=1
fi

# ── 3/10. raw provider text never reaches the row ──────────────────────────
run secrets DOCKER_FIXTURE=secrets >/dev/null
expect secrets 'length == 1 and .[0].cause == "blind"
  and (.[0].probe_diag == "probe_fail leg=docker-ps detail=inventory-unavailable")
  and ((.[0].probe_diag | contains("credential-sentinel")) | not)
  and ((.[0].probe_diag | contains("hunter2")) | not)
  and ((.[0].probe_diag | contains("SECRETBEARER")) | not)
  and ((.[0].probe_diag | contains("user:pw")) | not)' \
  "adversarial docker text (uppercase TOKEN=, PASSWORD:, BEARER, inline URL creds) never reaches the row"
expect_out_absent secrets "credential-sentinel" "the sentinel never appears in the monitor output either"

# ── 6. the monitor's own stderr stays visible after a capture-on probe ─────
run stderr-visible HEALTH_ALERT_SERVICE_OK=0 DOCKER_FIXTURE=healthy >/dev/null
expect_out stderr-visible "OPERATIONAL NOTE" "monitor stderr is still visible after a capture-on probe (no fd2 leak)"
expect stderr-visible 'length == 1 and .[0].cause == "operational"' "the operational warning still dispatches after the probe"

# ── 7. the 10s probe timeout and its classification are unchanged ──────────
SECONDS=0
rc=$(run slow DOCKER_FIXTURE=slow)
elapsed=$SECONDS
[ "$rc" = 0 ] || { echo "FAIL: slow run exited $rc"; FAILED=1; }
if [ "$elapsed" -le 25 ]; then
  echo "PASS: a hanging docker read is still cut off by the 10s timeout budget (${elapsed}s)"
else
  echo "FAIL: a hanging docker read is still cut off by the 10s timeout budget (${elapsed}s)"; FAILED=1
fi
expect slow 'length == 1 and .[0].cause == "blind" and .[0].container_count == null
  and .[0].dispatch == "--severity=WARNING"' \
  "timeout still classifies as blind/WARNING with unknown capacity"

# ── 4/8. stderr unavailable must never blind a healthy probe ───────────────
# (a) TMPDIR does not exist -> mktemp fails -> fall back to the old behaviour.
rc=$(run tmpdir-missing TMPDIR=/nonexistent-ezgha-scratch/zzz)
[ "$rc" = 0 ] || { echo "FAIL: tmpdir-missing run exited $rc"; FAILED=1; }
expect tmpdir-missing 'length == 0' "missing TMPDIR: no blind row is produced"
expect_out_re tmpdir-missing 'Local: [1-9][0-9]* containers' "missing TMPDIR: a healthy probe still counts the runner"
expect_out tmpdir-missing "MUTUAL HEALTH CHECK OK" "missing TMPDIR: healthy verdict is unchanged"

# (c) TMPDIR exists but is not writable -> mktemp fails.
mkdir -p "$W/ro-tmp"
chmod 500 "$W/ro-tmp"
rc=$(run tmpdir-readonly TMPDIR="$W/ro-tmp")
chmod 700 "$W/ro-tmp"
[ "$rc" = 0 ] || { echo "FAIL: tmpdir-readonly run exited $rc"; FAILED=1; }
expect tmpdir-readonly 'length == 0' "read-only TMPDIR: no blind row is produced"
expect_out_re tmpdir-readonly 'Local: [1-9][0-9]* containers' "read-only TMPDIR: a healthy probe still counts the runner"

# Descriptor-open failure (or a path that disappeared) must not blind a healthy
# probe: fd 8 falls back to /dev/null and the probe still runs exactly once.
rc=$(run open-fail HEALTH_ALERT_PROBE_DIAG_FORCE_OPEN_FAIL=1)
[ "$rc" = 0 ] || { echo "FAIL: open-fail run exited $rc"; FAILED=1; }
expect open-fail 'length == 0' "capture-open failure: no blind row is produced"
expect open-fail 'all(.probe_diag == null)' "capture-open failure: no diagnostic field is emitted"
expect_out_re open-fail 'Local: [1-9][0-9]* containers' "capture-open failure: a healthy probe still counts the runner"
expect_out open-fail "MUTUAL HEALTH CHECK OK" "capture-open failure: healthy verdict is unchanged"
expect_calls open-fail ps 1 "capture-open failure: the inventory is still read exactly once"
expect_calls open-fail top 1 "capture-open failure: the container is still inspected exactly once"

# ── 8. only owned artifacts are touched ────────────────────────────────────
mkdir -p "$W/tmp-keep"
printf 'unrelated\n' > "$W/tmp-keep/keepme.txt"
run keep DOCKER_FIXTURE=top-fail >/dev/null
if [ -f "$W/tmp-keep/keepme.txt" ]; then
  echo "PASS: unrelated scratch files survive a failing probe"
else
  echo "FAIL: unrelated scratch files survive a failing probe"; FAILED=1
fi
expect_no_scratch keep "a failing probe leaves no owned temp file behind"

# ── 9. the Docker diagnostic never appears on another blind source ─────────
cat > "$W/df" <<'STUB'
#!/usr/bin/env bash
printf 'Filesystem 1G-blocks Used Available Use%% Mounted on\n/dev/test 100G 90G 10G 90%% /\n'
exit 1
STUB
chmod +x "$W/df"
run disk-blind PATH="$W:$PATH" HEALTH_ALERT_FREE_GB= DOCKER_FIXTURE=healthy >/dev/null
expect disk-blind 'length == 1 and .[0].cause == "blind" and .[0].blind_source == "disk"
  and .[0].probe_diag == null' \
  "a non-Docker blind source never carries the Docker probe diagnostic"

# ── 10. sanitizer unit: control text, bound, case-insensitive credentials ──
sed -n '/^sanitize_probe_diag()/,/^}/p' "$S" > "$W/sanitize_fn.sh"
if [ -s "$W/sanitize_fn.sh" ]; then
  san() { # text
    PROBE_DIAG_MAX_CHARS=512 PROBE_DIAG_READ_MAX_BYTES=8192 \
      "$MONITOR_BASH" -c "$(cat "$W/sanitize_fn.sh"); sanitize_probe_diag" <<< "$1"
  }
  out=$(san 'TOKEN=credential-sentinel and PASSWORD: hunter2 and API_KEY=abc123 and CREDENTIALS=zzz')
  if printf '%s' "$out" | grep -Eq 'credential-sentinel|hunter2|abc123|zzz'; then
    echo "FAIL: sanitizer redacts UPPERCASE credential labels (got: $out)"; FAILED=1
  else
    echo "PASS: sanitizer redacts UPPERCASE credential labels"
  fi
  out=$(san 'Authorization: BEARER SECRETBEARER; url=https://user:pw@example.invalid/x')
  if printf '%s' "$out" | grep -Eq 'SECRETBEARER|user:pw'; then
    echo "FAIL: sanitizer redacts BEARER tokens and inline URL credentials (got: $out)"; FAILED=1
  else
    echo "PASS: sanitizer redacts BEARER tokens and inline URL credentials"
  fi
  out=$(printf 'line1\r\n\033[31mred\033[0m\tTABbed' | PROBE_DIAG_MAX_CHARS=512 PROBE_DIAG_READ_MAX_BYTES=8192 \
        "$MONITOR_BASH" -c "$(cat "$W/sanitize_fn.sh"); sanitize_probe_diag")
  if printf '%s' "$out" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    echo "FAIL: sanitizer strips control characters"; FAILED=1
  else
    echo "PASS: sanitizer strips control characters and flattens to one line"
  fi
  long=$(printf 'y%.0s' $(seq 1 4096))
  out=$(san "$long")
  if [ "${#out}" -le 540 ] && printf '%s' "$out" | grep -q '\.\.\.\[truncated\]$'; then
    echo "PASS: sanitizer bounds a 4096-byte input to ${#out} chars with a truncation marker"
  else
    echo "FAIL: sanitizer bounds a 4096-byte input (got ${#out} chars)"; FAILED=1
  fi
else
  echo "FAIL: could not extract sanitize_probe_diag from $S"; FAILED=1
fi

# ── result ─────────────────────────────────────────────────────────────────
if [ "$FAILED" = 0 ]; then
  echo "=== ALL PROBE-DIAG CELLS PASS ==="
  exit 0
fi
echo "=== PROBE-DIAG CELLS FAILED ===" >&2
exit 1
