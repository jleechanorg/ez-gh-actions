#!/usr/bin/env bash
# Hermetic coverage for the bounded, sanitized Docker-probe diagnostic
# (`jsonPayload.probe_diag`) added to scripts/ezgha-host-health-alert.sh.
#
# Why: a blind row that said only "local: Docker runner inventory or process
# evidence incomplete" cost a full manual classification pass (2026-11-24,
# Jeff-Ubuntu, 49 rows/24h: cause=blind, blind_source=docker, container_count=null).
# The probe now names its failing leg and container on stderr and this script
# carries a bounded excerpt into the row.
#
# What this asserts (all through the emitted payload / persisted state, never by
# grepping the source):
#   1. A successful probe is unchanged and emits no diagnostic.
#   2. Every original failure classification is preserved: same status, cause,
#      blind_source, failed_checks, container_count=null and the same
#      WARNING→ERROR escalation on a second consecutive blind poll.
#   3. The failing leg and container id reach the row (docker-ps, docker-top,
#      process-table, all-vanished).
#   4. stderr unavailable (unusable/read-only TMPDIR, failed reservation write)
#      never blinds a healthy probe: capture disables itself.
#   5. Truncation is bounded and never SIGPIPEs/deadlocks the producer (200 KB
#      of daemon noise, wall-clock bounded).
#   6. Control characters, multi-line text and credential-shaped fragments are
#      stripped/redacted before they can reach the row.
#   7. The 10s probe timeout and its classification are unchanged.
#   8. Only owned scratch artifacts are removed, and unrelated files survive.
#   9. Non-Docker blind sources never carry the Docker diagnostic.
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
fixture="${DOCKER_FIXTURE:-healthy}"
if [ "${1:-}" = ps ]; then
  case "$fixture" in
    ps-fail)
      printf 'Error response from daemon: Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?\n' >&2
      exit 1 ;;
    flood)
      # 200 KB of daemon noise: the read-back must stay bounded and the
      # producer must not be SIGPIPE-killed by a truncated read.
      head -c 200000 /dev/zero 2>/dev/null | tr '\0' 'x' >&2 || :
      printf '\nprobe-noise-end\n' >&2
      exit 1 ;;
    control)
      printf 'WARN\033[31mred\033[0m\r\n\tmulti\nline\ttext\nAuthorization: Bearer SUPERSECRET123\npassword=hunter2\nhttps://user:pw@example.invalid/x\n' >&2
      exit 1 ;;
    slow)
      sleep 30
      exit 0 ;;
    all-vanished) printf '%s\n%s\n' "$ID1" "$ID2"; exit 0 ;;
    *) printf '%s\n' "$ID1"; exit 0 ;;
  esac
fi
if [ "${1:-}" = top ]; then
  case "$fixture" in
    top-fail)
      printf 'Error response from daemon: transient rpc error while reading pid table\n' >&2
      exit 1 ;;
    malformed)
      printf 'PID COMMAND\nnot-a-pid Runner.Worker\n' ;;
    all-vanished)
      printf 'Error response from daemon: No such container: %s\n' "$2" >&2
      exit 1 ;;
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
mkdir -p "$W/failhead"
cat > "$W/failhead/head" <<'STUB'
#!/usr/bin/env bash
# Reservation-write failure: the script's capacity proof uses `head -c` only.
if [ "${1:-}" = "-c" ]; then exit 1; fi
exec /usr/bin/head "$@"
STUB
chmod +x "$W/gcloud" "$W/docker" "$W/systemctl" "$W/df-fail" "$W/failhead/head"

# ── harness ────────────────────────────────────────────────────────────────
run() { # case [VAR=value ...]
  local name="$1"; shift
  local tmp="$W/tmp-$name"
  mkdir -p "$tmp"
  : > "$W/log-$name"
  env GCLOUD_BIN="$W/gcloud" STUB_LOG="$W/log-$name" DOCKER_BIN="$W/docker" \
    TMPDIR="$tmp" \
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

# ── 2/3. docker-top failure: classification preserved, leg + container named ─
rc=$(run top-fail DOCKER_FIXTURE=top-fail)
[ "$rc" = 0 ] || { echo "FAIL: top-fail first poll exited $rc"; FAILED=1; }
expect top-fail 'length == 1
  and (.[0].status == "BLIND" and .[0].cause == "blind" and .[0].blind_source == "docker")
  and .[0].severity == "WARNING" and .[0].dispatch == "--severity=WARNING"
  and .[0].container_count == null
  and (.[0].failed_checks == ["local: Docker runner inventory or process evidence incomplete"])
  and (.[0].probe_diag | test("leg=docker-top container=([0-9a-f]{64}|unknown) detail="))
  and (.[0].probe_diag | contains("transient rpc error"))' \
  "top failure: blind/WARNING/null count and failed_checks are unchanged, and the row names its leg and container"
if [ "$MONITOR_BASH_MAJOR" -ge 4 ]; then
  expect top-fail '.[0].probe_diag | contains("container=0000000000000000000000000000000000000000000000000000000000000001")' \
    "top failure: the specific failing container id is recorded"
fi
jq -e '.docker_blind == 1' "$W/state-top-fail/host-health-alert-$HOSTNAME_FIXTURE.json" >/dev/null 2>&1 \
  && echo "PASS: top failure: persisted docker_blind=1 is unchanged" \
  || { echo "FAIL: top failure: persisted docker_blind=1 is unchanged"; FAILED=1; }
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
  and (.[0].probe_diag | test("leg=process-table container=([0-9a-f]{64}|unknown)$"))' \
  "malformed table: classification unchanged, leg=process-table and the container id are recorded"

# ── 3. docker ps failure names the inventory leg and the daemon text ───────
run ps-fail DOCKER_FIXTURE=ps-fail >/dev/null
expect ps-fail 'length == 1 and .[0].cause == "blind" and .[0].container_count == null
  and (.[0].probe_diag | contains("leg=docker-ps"))
  and (.[0].probe_diag | contains("Cannot connect to the Docker daemon"))' \
  "docker ps failure: classification unchanged, leg=docker-ps and the daemon text are recorded"

# ── 3. every container vanished keeps unknown capacity and says so ─────────
run all-vanished DOCKER_FIXTURE=all-vanished >/dev/null
expect all-vanished 'length == 1 and .[0].cause == "blind" and .[0].container_count == null
  and (.[0].probe_diag | contains("leg=all-vanished")) and (.[0].probe_diag | contains("vanished=2"))' \
  "all-vanished inventory: never a live zero, and the vanish count is recorded"

# ── 5. bounded read: 200 KB of producer noise, no deadlock, no SIGPIPE hang ─
SECONDS=0
rc=$(run flood DOCKER_FIXTURE=flood)
elapsed=$SECONDS
[ "$rc" = 0 ] || { echo "FAIL: flood run exited $rc"; FAILED=1; }
if [ "$elapsed" -le 20 ]; then
  echo "PASS: 200KB of daemon noise does not deadlock the bounded read (${elapsed}s)"
else
  echo "FAIL: 200KB of daemon noise does not deadlock the bounded read (${elapsed}s)"; FAILED=1
fi
expect flood 'length == 1 and .[0].cause == "blind" and .[0].container_count == null
  and (.[0].probe_diag | endswith("...[truncated]"))
  and ((.[0].probe_diag | length) <= 540)' \
  "truncation is marked and stays inside the configured bound"
# The producer must have finished on its own (no SIGPIPE): its final marker
# appears only if the whole 200KB write completed.
expect flood 'length == 1' "flood row is valid JSON after truncation"

# ── 6. control text and credential shapes never reach the row ──────────────
run control DOCKER_FIXTURE=control >/dev/null
expect control 'length == 1 and .[0].cause == "blind"
  and (.[0].probe_diag | test("^[[:print:]]*$"))
  and ((.[0].probe_diag | contains("\u001b")) | not)
  and ((.[0].probe_diag | contains("SUPERSECRET123")) | not)
  and ((.[0].probe_diag | contains("hunter2")) | not)
  and ((.[0].probe_diag | contains(":pw@")) | not)
  and (.[0].probe_diag | contains("<redacted>"))' \
  "control text is flattened and credential-shaped text is redacted in the row"

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

# (b) TMPDIR exists but the capacity reservation write fails.
rc=$(run reserve-fail PATH="$W/failhead:$PATH")
[ "$rc" = 0 ] || { echo "FAIL: reserve-fail run exited $rc"; FAILED=1; }
expect reserve-fail 'length == 0' "failed reservation write: no blind row is produced"
expect_out_re reserve-fail 'Local: [1-9][0-9]* containers' "failed reservation write: a healthy probe still counts the runner"
expect_no_scratch reserve-fail "failed reservation write: the owned temp file is still removed"

# (c) TMPDIR exists but is not writable -> mktemp fails.
mkdir -p "$W/ro-tmp"
chmod 500 "$W/ro-tmp"
rc=$(run tmpdir-readonly TMPDIR="$W/ro-tmp")
chmod 700 "$W/ro-tmp"
[ "$rc" = 0 ] || { echo "FAIL: tmpdir-readonly run exited $rc"; FAILED=1; }
expect tmpdir-readonly 'length == 0' "read-only TMPDIR: no blind row is produced"
expect_out_re tmpdir-readonly 'Local: [1-9][0-9]* containers' "read-only TMPDIR: a healthy probe still counts the runner"

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

# ── result ─────────────────────────────────────────────────────────────────
if [ "$FAILED" = 0 ]; then
  echo "=== ALL PROBE-DIAG CELLS PASS ==="
  exit 0
fi
echo "=== PROBE-DIAG CELLS FAILED ===" >&2
exit 1
