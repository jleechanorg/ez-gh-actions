#!/usr/bin/env bash
# Layer-2 characterization harness for the persisted local-start failure
# ladder.  Every external command below is either the freshly compiled ezgha
# binary or a temp-local shim; the shims default-fail and never invoke Docker,
# GitHub, a network client, a supervisor, or a VM tool.
#
# Production mutations this catches:
# - moving JIT parsing after `docker run`, or treating a local docker failure
#   as a control-plane failure (the first three invocations would not record a
#   slot failure / open the circuit);
# - dropping any hard Docker resource/security argument;
# - failing to persist finite slot/fleet deadlines, or bypassing serve.lock;
# - issuing another JIT registration or detached docker run after admission is
#   paused (the fourth invocation must be local-only).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO_ROOT/target/debug/ezgha"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ezgha-layer2.XXXXXX")"
SHIM_DIR="$TMP_ROOT/shim"
STATE_DIR="$TMP_ROOT/state"
LOG_DIR="$TMP_ROOT/log"
CONFIG="$TMP_ROOT/config.toml"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'FAIL [layer2 failure ladder]: %s\n' "$*" >&2
  exit 1
}

require_file_contains() {
  local file="$1"
  local needle="$2"
  local explanation="$3"
  grep -F -- "$needle" "$file" >/dev/null || fail "$explanation (missing $needle in $file)"
}

mkdir -p "$SHIM_DIR" "$STATE_DIR" "$LOG_DIR" "$TMP_ROOT/home" "$TMP_ROOT/xdg-config" "$TMP_ROOT/xdg-state" "$TMP_ROOT/xdg-cache"

cat >"$SHIM_DIR/docker" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
: "${EZGHA_LAYER2_DOCKER_LOG:?}"
printf 'docker' >>"$EZGHA_LAYER2_DOCKER_LOG"
printf ' <%s>' "$@" >>"$EZGHA_LAYER2_DOCKER_LOG"
printf '\n' >>"$EZGHA_LAYER2_DOCKER_LOG"

case "${1:-}" in
  version)
    [[ "${2:-}" == "--format" && "${3:-}" == '{{.Server.Version}}' ]] || exit 91
    printf '27.0.0\n'
    ;;
  info)
    [[ "${2:-}" == "--format" ]] || exit 91
    case "${3:-}" in
      '{{.KernelVersion}}') printf 'layer2-isolated-daemon-kernel\n' ;;
      '{{json .Runtimes}}') printf '{}\n' ;;
      '{{.NCPU}} {{.MemTotal}}') printf '4 8589934592\n' ;;
      '{{.ServerVersion}}') printf '27.0.0\n' ;;
      *) exit 91 ;;
    esac
    ;;
  ps)
    # The fake daemon has no managed containers before or after each failed
    # detached run.  JSON mode's empty stream is a valid empty list.
    [[ " $* " == *' --format json '* ]] || exit 91
    ;;
  rm)
    [[ "${2:-}" == "-f" && $# -eq 3 ]] || exit 91
    ;;
  run)
    case " $* " in
      *' -d '*)
        # This is the only intentionally failing Docker action.  It is a
        # temp shim, never a daemon call; capture the exact real argv above.
        printf 'layer2: deterministic detached runner refusal\n' >&2
        exit 37
        ;;
      *' --entrypoint df '*)
        printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
        printf 'overlay 4194304 1 4194303 1%% /\n'
        ;;
      *' --cgroupns=host '*)
        # Satisfy the real CPU-controller proof without starting a container.
        printf 'cpuset cpu io memory pids\n'
        ;;
      *) exit 91 ;;
    esac
    ;;
  *) exit 91 ;;
esac
SHIM

cat >"$SHIM_DIR/gh" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
: "${EZGHA_LAYER2_GH_LOG:?}"
: "${EZGHA_LAYER2_SHIM_STATE:?}"
printf 'gh' >>"$EZGHA_LAYER2_GH_LOG"
printf ' <%s>' "$@" >>"$EZGHA_LAYER2_GH_LOG"
printf '\n' >>"$EZGHA_LAYER2_GH_LOG"

[[ "${1:-}" == api ]] || exit 92
all=" $* "
case "$all" in
  *' /actions/runners?per_page=100 '*)
    # `gh api --paginate --slurp` returns one complete, empty page.
    printf '[{"total_count":0,"runners":[]}]\n'
    ;;
  *' -X POST '*'/actions/runners/generate-jitconfig '*)
    counter="$EZGHA_LAYER2_SHIM_STATE/jit-count"
    count=0
    [[ -f "$counter" ]] && count="$(<"$counter")"
    count=$((count + 1))
    printf '%s\n' "$count" >"$counter"
    # A syntactically valid JIT response proves the real CLI parsed it before
    # it attempted the detached Docker invocation.
    printf '{"encoded_jit_config":"layer2-jit-%s","runner":{"id":%s}}\n' "$count" "$((1000 + count))"
    ;;
  *' -X DELETE '*'/actions/runners/'*)
    # The production failure cleanup may deregister the temp JIT id; let that
    # cleanup succeed so the sole causal failure is the detached docker run.
    ;;
  *) exit 92 ;;
esac
SHIM

chmod 700 "$SHIM_DIR/docker" "$SHIM_DIR/gh"

cat >"$CONFIG" <<EOF
version = 1
state_dir = "$STATE_DIR"

[github]
scope = "repo"
target = "layer2/example"

[runner]
labels = ["self-hosted", "layer2"]
count = 1
image = "layer2-runner:never-pulled"
name_prefix = "layer2-runner"
serve_tick_seconds = 5
guest_reserve_mb = 1
host_reserve_mb = 0
runner_floor_mb = 512

[limits]
memory_mb = 512
cpus = 0.5
pids = 32
min_free_disk_gb = 1

[policy]
minimum_isolation = "container"

[failure_ladder]
slot_failure_threshold = 3
slot_failure_window_secs = 60
slot_cooldown_secs = 120
fleet_open_slot_threshold = 1
fleet_cooldown_secs = 120

[alert]
failure_alert_threshold = 99
alert_cooldown_secs = 60
deadman_threshold_seconds = 0

[queue_monitor]
enabled = false
tail_warn_minutes = 1
check_interval_seconds = 60
stale_hours = 1
consecutive_alert_threshold = 1
rest_budget_floor = 1

[canary]
enabled = false
check_interval_seconds = 60
workflow = "layer2.yml"
ref_name = "main"
slo_start_seconds = 1
poll_timeout_seconds = 1
poll_interval_seconds = 1

[invariant_sampler]
enabled = false
check_interval_seconds = 60
EOF

printf 'Building real target/debug/ezgha...\n' >&2
cargo build --bin ezgha
[[ -x "$BIN" ]] || fail "cargo build did not produce $BIN"

run_start() {
  local n="$1"
  local output="$LOG_DIR/start-$n.out"
  set +e
  env -i \
    PATH="$SHIM_DIR:/usr/bin:/bin" \
    HOME="$TMP_ROOT/home" \
    XDG_CONFIG_HOME="$TMP_ROOT/xdg-config" \
    XDG_STATE_HOME="$TMP_ROOT/xdg-state" \
    XDG_CACHE_HOME="$TMP_ROOT/xdg-cache" \
    GH_CONFIG_DIR="$TMP_ROOT/gh-config" \
    DOCKER_HOST='unix:///layer2-no-daemon.sock' \
    EZGHA_LAYER2_DOCKER_LOG="$LOG_DIR/docker.log" \
    EZGHA_LAYER2_GH_LOG="$LOG_DIR/gh.log" \
    EZGHA_LAYER2_SHIM_STATE="$TMP_ROOT/shim-state" \
    timeout --foreground 15s "$BIN" --config "$CONFIG" start >"$output" 2>&1
  local rc=$?
  set -e
  printf '%s\n' "$rc" >"$LOG_DIR/start-$n.rc"
  # Snapshot cleanup mutations after every invocation.  The fourth snapshot
  # must equal the third, proving admission-paused performs no extra DELETE.
  grep -c ' <-X> <DELETE> ' "$LOG_DIR/gh.log" >"$LOG_DIR/start-$n.delete-count" || true
}

mkdir -p "$TMP_ROOT/shim-state"
: >"$LOG_DIR/docker.log"
: >"$LOG_DIR/gh.log"
for n in 1 2 3 4; do
  run_start "$n"
done

# The first three are all true production start commands, not helper calls.
# The first two must surface the structured incomplete-refill disposition.
# The third has the same local Docker failure, but is also the precise event
# that opens this one-slot fleet's admission circuit, so it correctly reports
# admission-paused instead.
for n in 1 2; do
  [[ "$(<"$LOG_DIR/start-$n.rc")" != 0 ]] || fail "start $n unexpectedly succeeded"
  require_file_contains "$LOG_DIR/start-$n.out" 'runner refill incomplete' \
    "start $n did not report the incomplete-refill disposition"
  if grep -F 'unexpected generate-jitconfig response' "$LOG_DIR/start-$n.out" >/dev/null; then
    fail "start $n did not parse the shimmed JIT response before Docker"
  fi
done

[[ "$(<"$LOG_DIR/start-3.rc")" != 0 ]] || fail 'start 3 unexpectedly succeeded'
require_file_contains "$LOG_DIR/start-3.out" 'runner admission paused' \
  'circuit-opening start 3 did not report admission-paused'
require_file_contains "$LOG_DIR/start-3.out" 'fleet admission circuit opened after 1 distinct slot circuits' \
  'circuit-opening start 3 did not report its local fleet-circuit reason'
if grep -F 'unexpected generate-jitconfig response' "$LOG_DIR/start-3.out" >/dev/null; then
  fail 'start 3 did not parse the shimmed JIT response before Docker'
fi

[[ "$(<"$LOG_DIR/start-4.rc")" != 0 ]] || fail 'fourth start unexpectedly succeeded'
require_file_contains "$LOG_DIR/start-4.out" 'runner admission paused' \
  'fourth start did not stop at the persisted fleet admission circuit'

JIT_POSTS="$(grep -c 'generate-jitconfig' "$LOG_DIR/gh.log" || true)"
[[ "$JIT_POSTS" -eq 3 ]] || fail "expected exactly 3 JIT POSTs before admission pause, got $JIT_POSTS"
DETACHED_RUNS="$(grep -c ' <run>.* <-d>' "$LOG_DIR/docker.log" || true)"
[[ "$DETACHED_RUNS" -eq 3 ]] || fail "expected exactly 3 detached runner runs before admission pause, got $DETACHED_RUNS"
DELETE_CALLS="$(grep -c ' <-X> <DELETE> .*actions/runners/' "$LOG_DIR/gh.log" || true)"
[[ "$DELETE_CALLS" -eq 3 ]] || fail "expected exactly 3 JIT cleanup DELETEs, got $DELETE_CALLS"

# Every successfully parsed/minted JIT registration must be cleaned up after
# its detached Docker run fails.  Exact IDs catch cleanup of the wrong runner;
# exact one-per-ID counts catch missing or repeated cleanup.
for runner_id in 1001 1002 1003; do
  ID_DELETE_COUNT="$(grep ' <-X> <DELETE> ' "$LOG_DIR/gh.log" | grep -cF -- "/actions/runners/$runner_id>" || true)"
  [[ "$ID_DELETE_COUNT" -eq 1 ]] \
    || fail "expected exactly one cleanup DELETE for minted runner $runner_id, got $ID_DELETE_COUNT"
done
for n in 1 2 3; do
  [[ "$(<"$LOG_DIR/start-$n.delete-count")" -eq "$n" ]] \
    || fail "expected $n cumulative cleanup DELETE(s) after start $n, got $(<"$LOG_DIR/start-$n.delete-count")"
done
[[ "$(<"$LOG_DIR/start-4.delete-count")" -eq 3 ]] \
  || fail "fourth admission-paused invocation added a cleanup DELETE (cumulative count $(<"$LOG_DIR/start-4.delete-count"))"

# Prove that all security/resource arguments arrived on each *real* detached
# runner argv.  A production mutation removing a flag makes this fail even if
# Docker would otherwise accept the launch.
for argument_pair in \
  '<--memory> <512m>' \
  '<--memory-swap> <512m>' \
  '<--cpus> <0.50>' \
  '<--pids-limit> <32>' \
  '<--security-opt> <no-new-privileges>'
do
  PAIR_COUNT="$(grep ' <run>.* <-d>' "$LOG_DIR/docker.log" | grep -cF -- "$argument_pair" || true)"
  [[ "$PAIR_COUNT" -eq 3 ]] \
    || fail "expected $argument_pair on all 3 detached runner argv values, got $PAIR_COUNT"
done

LEDGER="$STATE_DIR/failure_ladder.toml"
LOCK="$STATE_DIR/serve.lock"
[[ -f "$LOCK" ]] || fail 'normal serve.lock was not created (EZGHA_SKIP_LOCK is intentionally absent)'
[[ -f "$LEDGER" ]] || fail 'failure ladder ledger was not persisted'
require_file_contains "$LEDGER" 'open_until_epoch_secs =' 'slot circuit deadline missing from ledger'
require_file_contains "$LEDGER" 'fleet_open_until_epoch_secs =' 'fleet circuit deadline missing from ledger'

NOW="$(date +%s)"
SLOT_DEADLINE="$(sed -nE 's/^[[:space:]]*open_until_epoch_secs = ([0-9]+)$/\1/p' "$LEDGER" | head -n1)"
FLEET_DEADLINE="$(sed -nE 's/^fleet_open_until_epoch_secs = ([0-9]+)$/\1/p' "$LEDGER")"
[[ "$SLOT_DEADLINE" =~ ^[0-9]+$ && "$FLEET_DEADLINE" =~ ^[0-9]+$ ]] || fail 'ledger deadlines are not finite integer epochs'
[[ "$SLOT_DEADLINE" -gt "$NOW" && "$SLOT_DEADLINE" -le $((NOW + 180)) ]] || fail "slot deadline is not a bounded 120-second future deadline: $SLOT_DEADLINE"
[[ "$FLEET_DEADLINE" -gt "$NOW" && "$FLEET_DEADLINE" -le $((NOW + 180)) ]] || fail "fleet deadline is not a bounded 120-second future deadline: $FLEET_DEADLINE"

printf 'PASS [layer2 failure ladder]: 3 parsed JITs -> 3 deterministic detached-run failures -> persisted fleet admission pause\n' >&2
printf 'mock command surface: docker version/info/ps/rm/run(df,cgroup-probe,detached-fail); gh api runner-list/JIT-POST/runner-DELETE; all other argv fail\n' >&2
