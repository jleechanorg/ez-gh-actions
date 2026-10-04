#!/usr/bin/env bash
# Regression test: `ezgha stop` is a server-owned state mutator and must
# refuse to run while another stateful command holds serve.lock.  The test is
# binary-level and uses only strict temp-local command shims; no Docker,
# GitHub, systemd, VM, or runner state is touched.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO_ROOT/target/debug/ezgha"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ezgha-stop-lock.XXXXXX")"
SHIM_DIR="$TMP_ROOT/shim"
STATE_DIR="$TMP_ROOT/state"
CONFIG="$TMP_ROOT/config.toml"
DOCKER_LOG="$TMP_ROOT/docker.log"
GH_LOG="$TMP_ROOT/gh.log"
LOCK_READY="$TMP_ROOT/lock-ready"
HOLDER_PID=""

cleanup() {
  if [[ -n "$HOLDER_PID" ]]; then
    kill "$HOLDER_PID" 2>/dev/null || true
    wait "$HOLDER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'FAIL [stop serve.lock]: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$SHIM_DIR" "$STATE_DIR"

cat >"$SHIM_DIR/docker" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
: "${EZGHA_STOP_LOCK_DOCKER_LOG:?}"
printf 'docker' >>"$EZGHA_STOP_LOCK_DOCKER_LOG"
printf ' <%s>' "$@" >>"$EZGHA_STOP_LOCK_DOCKER_LOG"
printf '\n' >>"$EZGHA_STOP_LOCK_DOCKER_LOG"
# An empty managed-container listing lets an unlocked stop proceed to its
# GitHub listing without touching a real Docker daemon.
[[ " $* " == *' --format json '* ]] || exit 91
SHIM

cat >"$SHIM_DIR/gh" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
: "${EZGHA_STOP_LOCK_GH_LOG:?}"
printf 'gh' >>"$EZGHA_STOP_LOCK_GH_LOG"
printf ' <%s>' "$@" >>"$EZGHA_STOP_LOCK_GH_LOG"
printf '\n' >>"$EZGHA_STOP_LOCK_GH_LOG"
[[ "${1:-}" == api ]] || exit 92
# Empty runner inventory lets an unlocked stop complete without GitHub.
printf '[{"total_count":0,"runners":[]}]\n'
SHIM

chmod 700 "$SHIM_DIR/docker" "$SHIM_DIR/gh"

cat >"$CONFIG" <<EOF
version = 1
state_dir = "$STATE_DIR"

[github]
scope = "repo"
target = "lock/example"

[runner]
labels = ["self-hosted"]
count = 1
image = "lock-test-runner:never-pulled"

[limits]
memory_mb = 512
cpus = 0.5
pids = 1

[policy]
minimum_isolation = "container"
EOF

cargo build --quiet --bin ezgha
[[ -x "$BIN" ]] || fail "cargo build did not produce $BIN"

# Hold the same lock path used by acquire_serve_lock in a separate process.
flock -n "$STATE_DIR/serve.lock" -c "touch '$LOCK_READY'; sleep 15" &
HOLDER_PID=$!
for _ in $(seq 1 100); do
  [[ -f "$LOCK_READY" ]] && break
  sleep 0.01
done
[[ -f "$LOCK_READY" ]] || fail "lock holder did not acquire serve.lock"

set +e
STOP_OUTPUT="$(
  env -i \
    PATH="$SHIM_DIR:/usr/bin:/bin" \
    HOME="$TMP_ROOT/home" \
    XDG_CONFIG_HOME="$TMP_ROOT/xdg-config" \
    XDG_STATE_HOME="$TMP_ROOT/xdg-state" \
    XDG_CACHE_HOME="$TMP_ROOT/xdg-cache" \
    EZGHA_STOP_LOCK_DOCKER_LOG="$DOCKER_LOG" \
    EZGHA_STOP_LOCK_GH_LOG="$GH_LOG" \
    timeout --foreground 5s "$BIN" --config "$CONFIG" stop 2>&1
)"
STOP_RC=$?
set -e

[[ "$STOP_RC" -ne 0 ]] || fail "stop unexpectedly succeeded while serve.lock was held; output: $STOP_OUTPUT"
grep -F 'stateful ezgha runner command is active' <<<"$STOP_OUTPUT" >/dev/null \
  || fail "stop did not report the held state lock (rc=$STOP_RC): $STOP_OUTPUT"
[[ ! -s "$DOCKER_LOG" ]] || fail "stop reached Docker while serve.lock was held: $(<"$DOCKER_LOG")"
[[ ! -s "$GH_LOG" ]] || fail "stop reached GitHub while serve.lock was held: $(<"$GH_LOG")"

printf 'PASS [stop serve.lock]: stop refused before Docker/GitHub side effects while serve.lock was held\n' >&2
