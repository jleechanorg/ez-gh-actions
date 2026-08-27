#!/usr/bin/env bash
# Layer-2 harness for the real `ezgha serve` reconciliation loop. Docker and
# GitHub are replaced only at process boundaries with strict local shims.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO_ROOT/target/debug/ezgha"
ARTIFACT_DIR="${1:-}"
if [[ -z "$ARTIFACT_DIR" ]]; then
  ARTIFACT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ezgha-serve-layer2-artifacts.XXXXXX")"
else
  mkdir -p "$ARTIFACT_DIR"
fi
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ezgha-serve-layer2.XXXXXX")"
SHIM_DIR="$TMP_ROOT/shim"
STATE_DIR="$TMP_ROOT/state"
LOG_DIR="$TMP_ROOT/log"
CONFIG="$TMP_ROOT/config.toml"
DOCKER_LOG="$LOG_DIR/docker.argv.log"
GH_LOG="$LOG_DIR/gh.api.log"
SERVE_OUT="$LOG_DIR/daemon-output.log"
PHASE2_DIR="$TMP_ROOT/phase2"
PHASE2_STATE="$PHASE2_DIR/state"
PHASE2_CONFIG="$PHASE2_DIR/config.toml"
PHASE2_DOCKER_LOG="$PHASE2_DIR/docker.argv.log"
PHASE2_GH_LOG="$PHASE2_DIR/gh.api.log"
PHASE2_ALERT_LOG="$PHASE2_DIR/alerts.jsonl"
write_artifacts() {
  local exit_rc="$1"
  set +e
  local result="FAIL"
  [[ "$exit_rc" -eq 0 ]] && result="PASS"
  local pair src dest
  for pair in \
    "$DOCKER_LOG|docker.argv.log" "$GH_LOG|gh.api.log" "$SERVE_OUT|daemon-output.log" \
    "$LOG_DIR/start-after-pause.out|start-after-pause.out" "$LOG_DIR/alerts.jsonl|alerts.jsonl" \
    "$STATE_DIR/failure_ladder.toml|failure_ladder.toml" "$CONFIG|config.toml" \
    "$LOG_DIR/serve.rc|serve.rc" "$LOG_DIR/serve.elapsed_secs|serve.elapsed_secs" \
    "$PHASE2_DOCKER_LOG|phase2-docker.argv.log" "$PHASE2_GH_LOG|phase2-gh.api.log" \
    "$PHASE2_ALERT_LOG|phase2-alerts.jsonl" "$PHASE2_CONFIG|phase2-config.toml" \
    "$PHASE2_DIR/serve-1.out|phase2-serve-1.out" "$PHASE2_DIR/serve-2.out|phase2-serve-2.out"; do
    src="${pair%%|*}"; dest="${pair#*|}"
    [[ -f "$src" ]] && cp "$src" "$ARTIFACT_DIR/$dest"
  done
  [[ -x "$BIN" ]] && sha256sum "$BIN" >"$ARTIFACT_DIR/binary.sha256"
  cat >"$ARTIFACT_DIR/manifest.txt" <<EOF
test=ezgha_serve_failure_ladder_layer2_test.sh
binary=$BIN
result=$result
coverage=real serve reconciliation; 3-slot configured fleet; 2 distinct open slot circuits; persisted pause; causal repeated partial-refill deadman phase; TERM timeout; JIT cleanup; bounded Docker argv
artifacts=docker.argv.log gh.api.log daemon-output.log start-after-pause.out alerts.jsonl failure_ladder.toml config.toml phase2-docker.argv.log phase2-gh.api.log phase2-alerts.jsonl phase2-config.toml phase2-serve-1.out phase2-serve-2.out binary.sha256 serve.rc serve.elapsed_secs
limitations=no live Docker/GitHub/systemd/VM; strict shims model empty managed fleet and deterministic Docker launch refusal
EOF
  local files=(docker.argv.log gh.api.log daemon-output.log start-after-pause.out alerts.jsonl failure_ladder.toml config.toml binary.sha256 serve.rc serve.elapsed_secs phase2-docker.argv.log phase2-gh.api.log phase2-alerts.jsonl phase2-config.toml phase2-serve-1.out phase2-serve-2.out manifest.txt)
  : >"$ARTIFACT_DIR/checksums.sha256"
  for dest in "${files[@]}"; do
    [[ -f "$ARTIFACT_DIR/$dest" ]] && (cd "$ARTIFACT_DIR" && sha256sum "$dest") >>"$ARTIFACT_DIR/checksums.sha256"
  done
  rm -rf "$TMP_ROOT"
  return "$exit_rc"
}
cleanup() { local rc=$?; trap - EXIT; write_artifacts "$rc"; exit "$rc"; }
trap cleanup EXIT
fail() { printf 'FAIL [layer2 serve failure ladder]: %s\n' "$*" >&2; exit 1; }
require_file_contains() {
  local file="$1" needle="$2" explanation="$3"
  grep -F -- "$needle" "$file" >/dev/null || fail "$explanation (missing $needle in $file)"
}

mkdir -p "$SHIM_DIR" "$STATE_DIR" "$LOG_DIR" "$TMP_ROOT/home" \
  "$TMP_ROOT/xdg-config" "$TMP_ROOT/xdg-state" "$TMP_ROOT/xdg-cache" "$TMP_ROOT/shim-state"

cat >"$SHIM_DIR/docker" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
: "${EZGHA_LAYER2_DOCKER_LOG:?}"
exec 9>>"$EZGHA_LAYER2_DOCKER_LOG"
flock 9
printf 'docker' >&9
printf ' <%s>' "$@" >&9
printf '\n' >&9
flock -u 9
exec 9>&-
case "${1:-}" in
  version)
    [[ "$#" -eq 3 && "${2:-}" == "--format" && "${3:-}" == '{{.Server.Version}}' ]] || exit 91
    printf '27.0.0\n' ;;
  info)
    [[ "$#" -eq 3 && "${2:-}" == "--format" ]] || exit 91
    case "${3:-}" in
      '{{.KernelVersion}}') printf 'layer2-guest-kernel\n' ;;
      '{{json .Runtimes}}') printf '{}\n' ;;
      '{{.ServerVersion}}') printf '27.0.0\n' ;;
      '{{.NCPU}} {{.MemTotal}}') printf '4 4294967296\n' ;;
      *) exit 91 ;;
    esac ;;
  pull) [[ "$#" -eq 2 && "${2:-}" == 'alpine:3.19' ]] || exit 91 ;;
  ps)
    [[ "$#" -eq 5 && "$2" == '--filter' && "$3" == 'label=ezgha=managed' && "$4" == '--format' && "$5" == 'json' ]] || exit 91 ;;
  rm) [[ "${2:-}" == '-f' && "$#" -eq 3 && "${3:-}" =~ ^layer2-serve-runner-[1-3]$ ]] || exit 91 ;;
  run)
    if [[ "$#" -eq 7 && "$2" == '--rm' && "$3" == '--entrypoint' && "$4" == 'df' && "$5" == 'layer2-runner:never-pulled' && "$6" == '-Pk' && "$7" == '/' ]]; then
      printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
      printf 'overlay 4194304 1 4194303 1%% /\n'
    elif [[ "$#" -eq 8 && "$2" == '--rm' && "$3" == '--cgroupns=host' && "$4" == '--network=none' && "$5" == 'alpine:3.19' && "$6" == 'sh' && "$7" == '-c' && "$8" == 'cat /sys/fs/cgroup/cgroup.controllers 2>/dev/null || cat /proc/cgroups 2>/dev/null' ]]; then
      printf 'cpuset cpu io memory pids\n'
    elif [[ "$#" -eq 23 && "$2" == '-d' && "$3" == '--rm' && "$4" == '--name' && "$6" == '--label' && "$7" == 'ezgha=managed' && "$8" == '--label' && "$9" =~ ^ezgha\.runner_id=[0-9]+$ && "${10}" == '--memory' && "${12}" == '--memory-swap' && "${14}" == '--cpus' && "${16}" == '--pids-limit' && "${18}" == '--security-opt' && "${19}" == 'no-new-privileges' && "${20}" == 'layer2-runner:never-pulled' && "${21}" == './run.sh' && "${22}" == '--jitconfig' && "$5" =~ ^layer2-serve-runner-[1-3]$ && "${11}" == '512m' && "${13}" == '512m' && "${15}" == '0.50' && "${17}" == '32' && "${23}" =~ ^layer2-jit-[0-9]+$ ]]; then
      printf 'layer2: deterministic detached runner refusal\n' >&2
      exit 37
    else exit 91
    fi ;;
  *) exit 91 ;;
esac
SHIM

cat >"$SHIM_DIR/gh" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
: "${EZGHA_LAYER2_GH_LOG:?}"
: "${EZGHA_LAYER2_SHIM_STATE:?}"
exec 9>>"$EZGHA_LAYER2_GH_LOG"
flock 9
printf 'gh' >&9
printf ' <%s>' "$@" >&9
printf '\n' >&9
flock -u 9
exec 9>&-
[[ "${1:-}" == api ]] || exit 92
args=" $* "
case "$args" in
  *)
    if [[ "$#" -eq 4 && "$2" == '--paginate' && "$3" == '--slurp' && "$4" == 'repos/layer2/example/actions/runners?per_page=100' ]]; then
      printf '[{"total_count":0,"runners":[]}]\n'
    elif [[ "$#" -eq 12 && "$2" == '-X' && "$3" == 'POST' && "$4" == 'repos/layer2/example/actions/runners/generate-jitconfig' && "$5" == '-f' && "$6" =~ ^name=layer2-serve-runner-[1-3]$ && "$7" == '-F' && "$8" == 'runner_group_id=1' && "$9" == '-f' && "${10}" == 'labels[]=self-hosted' && "${11}" == '-f' && "${12}" == 'labels[]=layer2' ]]; then
      counter="$EZGHA_LAYER2_SHIM_STATE/jit-count"; count=0
      [[ -f "$counter" ]] && count="$(<"$counter")"
      count=$((count + 1)); printf '%s\n' "$count" >"$counter"
      printf '{"encoded_jit_config":"layer2-jit-%s","runner":{"id":%s}}\n' "$count" "$((1000 + count))"
    elif [[ "$#" -eq 4 && "$2" == '-X' && "$3" == 'DELETE' && "$4" =~ ^repos/layer2/example/actions/runners/[0-9]+$ ]]; then
      :
    else
      exit 92
    fi
    ;;
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
count = 3
image = "layer2-runner:never-pulled"
name_prefix = "layer2-serve-runner"
serve_tick_seconds = 5
vm_total_mb = 4096
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
slot_failure_threshold = 1
slot_failure_window_secs = 60
slot_cooldown_secs = 120
fleet_open_slot_threshold = 2
fleet_cooldown_secs = 120
[alert]
failure_alert_threshold = 99
alert_cooldown_secs = 1
log_path = "$LOG_DIR/alerts.jsonl"
deadman_threshold_seconds = 1
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
cargo build --bin ezgha >/dev/null
[[ -x "$BIN" ]] || fail "cargo build did not produce $BIN"
: >"$DOCKER_LOG"; : >"$GH_LOG"

start_epoch="$(date +%s)"
set +e
env -i \
  PATH="$SHIM_DIR:/usr/bin:/bin" HOME="$TMP_ROOT/home" \
  XDG_CONFIG_HOME="$TMP_ROOT/xdg-config" XDG_STATE_HOME="$TMP_ROOT/xdg-state" \
  XDG_CACHE_HOME="$TMP_ROOT/xdg-cache" GH_CONFIG_DIR="$TMP_ROOT/gh-config" \
  DOCKER_HOST='unix:///layer2-no-daemon.sock' \
  EZGHA_LAYER2_DOCKER_LOG="$DOCKER_LOG" EZGHA_LAYER2_GH_LOG="$GH_LOG" \
  EZGHA_LAYER2_SHIM_STATE="$TMP_ROOT/shim-state" \
  timeout --foreground --signal=TERM --kill-after=8s 14s \
  "$BIN" --config "$CONFIG" serve >"$SERVE_OUT" 2>&1
serve_rc=$?
set -e
elapsed=$(( $(date +%s) - start_epoch ))
printf '%s\n' "$serve_rc" >"$LOG_DIR/serve.rc"
printf '%s\n' "$elapsed" >"$LOG_DIR/serve.elapsed_secs"
[[ "$elapsed" -le 24 ]] || fail "serve exceeded bounded timeout (${elapsed}s)"
[[ "$serve_rc" -ne 137 ]] || fail 'serve required SIGKILL after timeout; graceful TERM did not return'

require_file_contains "$SERVE_OUT" 'ensure_count started only 0 of 3 missing runner(s); treating as partial failure' 'serve did not expose structured incomplete-refill failures'
require_file_contains "$SERVE_OUT" 'runner admission remains paused' 'serve did not expose the persisted fleet admission pause'
require_file_contains "$SERVE_OUT" 'fleet admission circuit opened after 2 distinct slot circuits' 'serve did not aggregate distinct slot failures into the fleet circuit'
require_file_contains "$SERVE_OUT" 'shutdown requested; draining in-flight runner registrations' 'serve did not handle bounded TERM shutdown'

# Re-enter through the real `start` command after the persisted pause exists.
# This second process must fail closed before issuing another JIT POST or
# detached Docker admission, proving the pause survives process boundaries.
JIT_BEFORE="$(grep -c 'generate-jitconfig' "$GH_LOG" || true)"
RUN_BEFORE="$(grep -c ' <run>.* <-d>' "$DOCKER_LOG" || true)"
set +e
env -i PATH="$SHIM_DIR:/usr/bin:/bin" HOME="$TMP_ROOT/home" \
  XDG_CONFIG_HOME="$TMP_ROOT/xdg-config" XDG_STATE_HOME="$TMP_ROOT/xdg-state" \
  XDG_CACHE_HOME="$TMP_ROOT/xdg-cache" GH_CONFIG_DIR="$TMP_ROOT/gh-config" \
  DOCKER_HOST='unix:///layer2-no-daemon.sock' \
  EZGHA_LAYER2_DOCKER_LOG="$DOCKER_LOG" EZGHA_LAYER2_GH_LOG="$GH_LOG" \
  EZGHA_LAYER2_SHIM_STATE="$TMP_ROOT/shim-state" \
  "$BIN" --config "$CONFIG" start >"$LOG_DIR/start-after-pause.out" 2>&1
start_rc=$?
set -e
[[ "$start_rc" -ne 0 ]] || fail 'post-pause start unexpectedly succeeded'
require_file_contains "$LOG_DIR/start-after-pause.out" 'runner admission paused' 'post-pause start did not fail closed'
[[ "$(grep -c 'generate-jitconfig' "$GH_LOG" || true)" -eq "$JIT_BEFORE" ]] || fail 'post-pause start issued an unexpected JIT POST'
[[ "$(grep -c ' <run>.* <-d>' "$DOCKER_LOG" || true)" -eq "$RUN_BEFORE" ]] || fail 'post-pause start issued an unexpected detached Docker run'

JIT_POSTS="$(grep -c 'generate-jitconfig' "$GH_LOG" || true)"
[[ "$JIT_POSTS" -eq 2 ]] || fail "expected exactly 2 JIT POSTs (distinct slots) before pause, got $JIT_POSTS"
DETACHED_RUNS="$(grep -c ' <run>.* <-d>' "$DOCKER_LOG" || true)"
[[ "$DETACHED_RUNS" -eq 2 ]] || fail "expected exactly 2 detached runner attempts, got $DETACHED_RUNS"
DELETE_CALLS="$(grep -c ' <-X> <DELETE> .*actions/runners/' "$GH_LOG" || true)"
[[ "$DELETE_CALLS" -eq 2 ]] || fail "expected exactly 2 JIT cleanup DELETEs, got $DELETE_CALLS"
for runner_id in 1001 1002; do
  count="$(grep ' <-X> <DELETE> ' "$GH_LOG" | grep -cF -- "/actions/runners/$runner_id>" || true)"
  [[ "$count" -eq 1 ]] || fail "runner $runner_id cleanup DELETE count was $count, expected 1"
done

DEADMAN_LOG="$LOG_DIR/alerts.jsonl"
[[ -f "$DEADMAN_LOG" ]] || fail 'dead-man alert log was not created'
DEADMAN_COUNT="$(grep -c '"event_key":"alert.pipeline.deadman"' "$DEADMAN_LOG" || true)"
[[ "$DEADMAN_COUNT" -ge 1 ]] || fail 'structured refill failures incorrectly earned dead-man success credit'
LEDGER="$STATE_DIR/failure_ladder.toml"
[[ -f "$LEDGER" ]] || fail 'failure-ladder ledger was not persisted'
require_file_contains "$LEDGER" 'fleet_open_until_epoch_secs =' 'fleet admission deadline missing from persisted ledger'
require_file_contains "$LEDGER" 'open_until_epoch_secs =' 'slot circuit deadline missing from persisted ledger'
for slot in 1 2; do require_file_contains "$LEDGER" "[slots.$slot]" "slot $slot circuit was not persisted distinctly"; done
NOW="$(date +%s)"
FLEET_DEADLINE="$(sed -nE 's/^fleet_open_until_epoch_secs = ([0-9]+)$/\1/p' "$LEDGER")"
[[ "$FLEET_DEADLINE" =~ ^[0-9]+$ && "$FLEET_DEADLINE" -gt "$NOW" && "$FLEET_DEADLINE" -le $((NOW + 180)) ]] || fail "fleet deadline is not finite and bounded: $FLEET_DEADLINE"

for pair in '<--memory> <512m>' '<--memory-swap> <512m>' '<--cpus> <0.50>' '<--pids-limit> <32>' '<--security-opt> <no-new-privileges>'; do
  n="$(grep ' <run>.* <-d>' "$DOCKER_LOG" | grep -cF -- "$pair" || true)"
  [[ "$n" -eq 2 ]] || fail "expected $pair on all detached argv values, got $n"
done
if grep ' <run>.* <-d>' "$DOCKER_LOG" | grep -Eq '<--privileged>|<--pid> <host>|<--network> <host>|<--volume> </>'; then fail 'detached Docker argv contained an unbounded host escape flag'; fi

# Causal deadman phase: a fresh state/config keeps slot/fleet circuits closed
# while two bounded serve processes each observe a structured partial refill.
mkdir -p "$PHASE2_DIR"; : >"$PHASE2_DOCKER_LOG"; : >"$PHASE2_GH_LOG"
cat >"$PHASE2_CONFIG" <<EOF
version = 1
state_dir = "$PHASE2_STATE"
[github]
scope = "repo"
target = "layer2/example"
[runner]
labels = ["self-hosted", "layer2"]
count = 3
image = "layer2-runner:never-pulled"
name_prefix = "layer2-serve-runner"
serve_tick_seconds = 5
vm_total_mb = 4096
guest_reserve_mb = 1
runner_floor_mb = 512
[limits]
memory_mb = 512
cpus = 0.5
pids = 32
min_free_disk_gb = 1
[policy]
minimum_isolation = "container"
[failure_ladder]
slot_failure_threshold = 99
slot_failure_window_secs = 60
slot_cooldown_secs = 120
fleet_open_slot_threshold = 3
fleet_cooldown_secs = 120
[alert]
failure_alert_threshold = 99
alert_cooldown_secs = 1
log_path = "$PHASE2_ALERT_LOG"
deadman_threshold_seconds = 1
[queue_monitor]
enabled = false
[canary]
enabled = false
[invariant_sampler]
enabled = false
EOF
for attempt in 1 2; do
  set +e
  env -i PATH="$SHIM_DIR:/usr/bin:/bin" HOME="$TMP_ROOT/home" \
    XDG_CONFIG_HOME="$TMP_ROOT/xdg-config" XDG_STATE_HOME="$TMP_ROOT/xdg-state" \
    XDG_CACHE_HOME="$TMP_ROOT/xdg-cache" GH_CONFIG_DIR="$TMP_ROOT/gh-config" \
    DOCKER_HOST='unix:///layer2-no-daemon.sock' \
    EZGHA_LAYER2_DOCKER_LOG="$PHASE2_DOCKER_LOG" EZGHA_LAYER2_GH_LOG="$PHASE2_GH_LOG" \
    EZGHA_LAYER2_SHIM_STATE="$TMP_ROOT/shim-state-phase2-$attempt" \
    timeout --foreground --signal=TERM --kill-after=5s 7s \
    "$BIN" --config "$PHASE2_CONFIG" serve >"$PHASE2_DIR/serve-$attempt.out" 2>&1
  phase2_rc=$?
  set -e
  [[ "$phase2_rc" -ne 137 ]] || fail "deadman phase $attempt required SIGKILL"
done
for attempt in 1 2; do
  require_file_contains "$PHASE2_DIR/serve-$attempt.out" 'ensure_count started only 0 of 3 missing runner(s); treating as partial failure' "deadman phase $attempt lacked partial-refill evidence"
  partial_count="$(grep -c 'ensure_count started only 0 of 3 missing runner(s); treating as partial failure' "$PHASE2_DIR/serve-$attempt.out" || true)"
  [[ "$partial_count" -ge 2 ]] || fail "deadman phase $attempt recorded only $partial_count partial refill(s); need repeated non-paused failures"
done
if grep -q 'fleet admission circuit opened' "$PHASE2_DIR"/serve-*.out; then fail 'deadman phase unexpectedly opened fleet admission pause'; fi
DEADMAN_PHASE2_COUNT="$(grep -c '"event_key":"alert.pipeline.deadman"' "$PHASE2_ALERT_LOG" || true)"
[[ "$DEADMAN_PHASE2_COUNT" -ge 2 ]] || fail 'deadman did not fire during repeated partial-refill phase'

trap - EXIT
write_artifacts 0
set -e
(cd "$ARTIFACT_DIR" && sha256sum -c checksums.sha256 >/dev/null) || fail 'artifact checksum self-verification failed'

printf 'PASS [layer2 serve failure ladder]: 3-slot fleet -> 2 distinct open slot circuits -> persisted fleet admission pause; deadman and cleanup verified\n' >&2
printf 'artifacts: %s\n' "$ARTIFACT_DIR" >&2
