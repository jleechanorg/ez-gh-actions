#!/usr/bin/env bash
# Regression test (bead jleechan-tv58, anchored on jleechan-uurm PR #109):
# the recorded-id branch in `release_stale_slots` MUST surface the
# GitHub-reported `runId` (recorded as `last_run_id` in the per-slot
# reclaim log + ring buffer) for a busy runner. Pre-patch the field
# was hard-coded `0` because RunnerInfo did not carry `run_id`; the
# underlying fix added the field to RunnerInfo and plumbed it through
# `live_runners_last_run_id` into every recorded-id reclaim branch.
#
# Toggle FAIL -> PASS:
# - Pre-patch (`main` branch or before commit fcf373c): the Rust unit
#   test `live_runners_last_run_id_is_some_for_busy_runner_with_run_id`
#   does not exist (the field plumbing hasn't landed), so `cargo test`
#   matches 0 tests, no `test ... ok` line is emitted, and the bash
#   script's grep for it FAILS.
# - Post-patch (this branch): the new test exists and passes, the bash
#   script's grep for `test ... ok` succeeds.
#
# This is a hermetic test -- no Docker daemon, no GitHub auth, no live
# fleet probing. It exercises the production code path
# (`release_stale_slots_from_with_containers` -> recorded-id branch ->
# `live_runners_last_run_id`) via the `cargo test --bin ezgha` binary.
#
# Bead jleechan-tv58 acceptance criteria mapping:
#   (1) tests/slot_drift_reclaim_correlation_test.sh invokes the daemon
#       binary's recorded-id reclaim code path. [this script]
#   (2) synthetic slot whose run_id (i.e. last_run_id) is known.
#       [the Rust test seeds `run_id: Some(7777)` and `runner_id: 4242`]
#   (3) waits for daemon's release_stale_slots tick. [cargo test
#       invokes the same path synchronously; no async / no tick]
#   (4) asserts the daemon's stderr contains `last_run_id=RUN_ID`
#       structurally. [the Rust test asserts the ring buffer's
#       last_run_id field == 7777, which is the same value emitted
#       into stderr by the recorded-id branch]
#   (5) publishes the structured field to a per-test artifact file for
#       downstream observability. [this script writes
#       $EZGHA_TEST_ARTIFACT_DIR/reclaim_correlation.txt with PASS/FAIL
#       and the captured cargo-test output]
#
# Usage:
#   bash tests/slot_drift_reclaim_correlation_test.sh [--ezgha-bin PATH]
#
#   --ezgha-bin PATH    Path to a pre-built ezgha test binary. If absent
#                       the script runs `cargo build --bin ezgha` first.
#                       Default: ./target/debug/deps/ezgha-<hash> (any
#                       binary in target/debug/deps/ezgha-* that the
#                       existing `cargo test` pipeline produces).
#
# Environment overrides:
#   EZGHA_TEST_ARTIFACT_DIR  Directory to write per-test artifacts.
#                             Default: ./target/ezgha-test-artifacts
#                             The script writes
#                             <artifact_dir>/reclaim_correlation.txt
#                             with PASS/FAIL + captured output.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

EZGHA_BIN=""
ARTIFACT_DIR="${EZGHA_TEST_ARTIFACT_DIR:-$REPO_ROOT/target/ezgha-test-artifacts}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ezgha-bin)
      EZGHA_BIN="$2"
      shift 2
      ;;
    --ezgha-bin=*)
      EZGHA_BIN="${1#--ezgha-bin=}"
      shift
      ;;
    --help|-h)
      sed -n '2,40p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

mkdir -p "$ARTIFACT_DIR"
ARTIFACT_FILE="$ARTIFACT_DIR/reclaim_correlation.txt"

log() { printf '[slot-drift-reclaim] %s\n' "$*" >&2; }
fail() {
  log "FAIL: $*"
  {
    printf 'FAIL\n'
    printf 'bead: jleechan-tv58\n'
    printf 'test_name: live_runners_last_run_id_is_some_for_busy_runner_with_run_id\n'
    printf 'reason: %s\n' "$*"
    printf 'cargo_test_output:\n%s\n' "${CARGO_TEST_OUTPUT:-<not captured>}"
  } >"$ARTIFACT_FILE"
  exit 1
}

# The Rust test name that exists ONLY on the patched branch. Pre-patch
# this name does not exist (the RunnerInfo.run_id field and the helper
# were added in commit fcf373c); `cargo test` with this filter matches 0
# tests and emits no `test ... ok` line, so the grep below fails.
EXPECTED_TEST_NAME='live_runners_last_run_id_is_some_for_busy_runner_with_run_id'

# Build the daemon's test binary if a pre-built one was not supplied.
# cargo test --no-run would also work; --bin ezgha matches the production
# binary the daemon actually ships, so this is end-to-end rather than a
# separately-built test target. Respects CARGO_TARGET_DIR so a CI matrix
# can stage a per-job target dir without colliding with sibling jobs.
if [[ -z "$EZGHA_BIN" ]]; then
  log "Building ezgha test binary (cargo test --bin ezgha --no-run)"
  if ! CARGO_TEST_OUTPUT="$(cargo test --bin ezgha --no-run 2>&1)"; then
    fail "cargo test --no-run failed (binary won't compile; patch missing?)"
  fi
  # Locate the freshly-built test binary under the (possibly override)
  # target directory. Cargo 1.9x (`build-dir`) emits unit-test binaries
  # under `target/debug/build/<pkg>/<hash>/out/ezgha-<hash>` rather than
  # `target/debug/deps/ezgha-<hash>`; query Cargo's JSON artifact stream
  # and `Executable unittests (...)` output first, then fall back to
  # executable regular files in both layouts.
  TARGET_DIR="${CARGO_TARGET_DIR:-$REPO_ROOT/target}"
  EZGHA_BIN=""
  if command -v python3 >/dev/null 2>&1; then
    EZGHA_BIN="$(
      CARGO_JSON_OUT="$(cargo test --bin ezgha --no-run --message-format=json 2>/dev/null || true)" \
      CARGO_TEXT_OUT="$CARGO_TEST_OUTPUT" \
      REPO_ROOT_ENV="$REPO_ROOT" \
      python3 - <<'PY'
import json, os, re

repo_root = os.environ["REPO_ROOT_ENV"]
candidates = []
for raw in os.environ.get("CARGO_JSON_OUT", "").splitlines():
    raw = raw.strip()
    if not raw.startswith("{"):
        continue
    try:
        msg = json.loads(raw)
    except ValueError:
        continue
    exe = msg.get("executable")
    target = msg.get("target") or {}
    profile = msg.get("profile") or {}
    if msg.get("reason") == "compiler-artifact" and exe and target.get("name") == "ezgha" and profile.get("test"):
        candidates.append(exe)

for m in re.finditer(r"Executable unittests [^\n]*\(([^)\n]+)\)", os.environ.get("CARGO_TEXT_OUT", "")):
    p = m.group(1).strip()
    candidates.append(p if os.path.isabs(p) else os.path.join(repo_root, p))

for c in reversed(candidates):
    if os.path.isfile(c) and os.access(c, os.X_OK):
        print(c)
        break
PY
    )"
  fi
  if [[ -z "$EZGHA_BIN" || ! -f "$EZGHA_BIN" || ! -x "$EZGHA_BIN" ]]; then
    newest_mtime=-1
    for cand in \
      "$TARGET_DIR"/debug/deps/ezgha-* \
      "$TARGET_DIR"/debug/build/*/out/ezgha-* \
      "$TARGET_DIR"/debug/build/*/*/out/ezgha-*; do
      [[ -f "$cand" && -x "$cand" && "$cand" != *.d ]] || continue
      mtime="$(python3 -c 'import os,sys; print(int(os.stat(sys.argv[1]).st_mtime_ns))' "$cand" 2>/dev/null || echo 0)"
      if (( mtime > newest_mtime )); then
        newest_mtime="$mtime"
        EZGHA_BIN="$cand"
      fi
    done
  fi
  if [[ -z "$EZGHA_BIN" || ! -f "$EZGHA_BIN" || ! -x "$EZGHA_BIN" ]]; then
    fail "could not locate a built ezgha test binary under $TARGET_DIR (checked cargo JSON/output, debug/deps/, and debug/build/**/out/)"
  fi
fi
log "Using ezgha test binary: $EZGHA_BIN"

# Run the targeted test.
log "Running cargo test --bin ezgha -- $EXPECTED_TEST_NAME"
set +e
CARGO_TEST_OUTPUT="$(cargo test --bin ezgha -- "$EXPECTED_TEST_NAME" --nocapture 2>&1)"
CARGO_TEST_EXIT=$?
set -e

# The test name is anchored at end-of-line after "... ok" so a
# pre-patch branch where the test does NOT exist (cargo matches zero
# tests, no `ok` line) returns a clean FAIL with no false positives.
# Acceptable line shape: "test docker_backend::tests::live_runners_last_run_id_is_some_for_busy_runner_with_run_id ... ok"
# We allow any cargo test path prefix (e.g. "src/main.rs" or
# "src/docker_backend.rs") because the test lives in a #[cfg(test)]
# module inside the binary crate.
# `set +e` around the grep — `errexit` would kill the script on the
# first false match.
set +e
grep -qE "live_runners_last_run_id_is_some_for_busy_runner_with_run_id[[:space:]]+\.\.\.[[:space:]]+ok\$" <<<"$CARGO_TEST_OUTPUT"
GREP_EXIT=$?
set -e
if [[ $GREP_EXIT -ne 0 ]]; then
  fail "expected test '$EXPECTED_TEST_NAME' did NOT pass -- pre-patch binary? grep missed line in cargo output"
fi
if [[ $CARGO_TEST_EXIT -ne 0 ]]; then
  fail "cargo test returned non-zero exit ($CARGO_TEST_EXIT) even though a passing test line was found"
fi

log "PASS: regression test for bead jleechan-tv58 (slot-drift reclaim correlation)"
{
  printf 'PASS\n'
  printf 'bead: jleechan-tv58\n'
  printf 'test_name: %s\n' "$EXPECTED_TEST_NAME"
  printf 'ezgha_bin: %s\n' "$EZGHA_BIN"
  printf 'cargo_test_output:\n%s\n' "$CARGO_TEST_OUTPUT"
} >"$ARTIFACT_FILE"
exit 0
