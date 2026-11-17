#!/usr/bin/env bash
# Hermetic regression test for Gate 4 config selection and fresh canary proof.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
DEFAULT_CONFIG="$TMP/default.toml"
CANARY_CONFIG="$TMP/canary.toml"

for config in "$DEFAULT_CONFIG" "$CANARY_CONFIG"; do
  prefix=ez-runner-test
  [ "$config" = "$CANARY_CONFIG" ] && prefix=ez-canary-test
  printf '[runner]\nname_prefix = "%s"\n' "$prefix" >"$config"
done

cat >"$TMP/bin/ezgha" <<EOF
#!/usr/bin/env bash
printf "warning: could not verify the filesystem type of runner.workspace_host_path '/home/runner/_work' (no filesystem type); continuing without the FUSE workspace guard\\n" >&2
case "\${CANARY_TEST_MODE:-success}" in
  command-failure)
    printf '{"diagnostic":"canary failed"}\\n'
    exit 17
    ;;
  bad-json)
    printf '{"diagnostic":"missing canary identity"}\\n'
    exit 0
    ;;
esac
case "\${2:-}" in
  "$DEFAULT_CONFIG") run_id=776; runner=ez-runner-test-2 ;;
  "$CANARY_CONFIG") run_id=777; runner=ez-canary-test-1 ;;
  *) echo "wrong config: \${2:-missing}" >&2; exit 42 ;;
esac
[ "\${1:-}" = --config ] && [ "\${3:-}" = canary-once ] || exit 43
printf '{"run_id":%s,"runner_name":"%s","time_to_start_seconds":10}\n' "\$run_id" "\$runner"
EOF
chmod +x "$TMP/bin/ezgha"

run_fixture() {
  local config="$1" expected="$2" output rc
  set +e
  output=$(VERIFY_EXIT_CRITERIA_TEST_MODE=1 \
    VERIFY_EXIT_CRITERIA_TEST_CASE=canary \
    VERIFY_EXIT_CRITERIA_CANARY_CONFIG="$config" \
    VERIFY_EXIT_CRITERIA_EZGHA_BIN="$TMP/bin/ezgha" \
    bash "$ROOT/docs/verify-exit-criteria.sh" 2>&1)
  rc=$?
  set -e
  [ "$rc" = 0 ] \
    || { echo "FAIL: verifier exit code $rc (output: $output)" >&2; return 1; }
  grep -Fq "$expected" <<<"$output" \
    || { echo "FAIL: expected '$expected' (got: $output)" >&2; return 1; }
  grep -Fq "using $config" <<<"$output" \
    || { echo "FAIL: output missing config '$config' (got: $output)" >&2; return 1; }
  grep -Fq "could not verify the filesystem type" <<<"$output" \
    || { echo "FAIL: warning was not preserved (got: $output)" >&2; return 1; }
}

run_failure_fixture() {
  local mode="$1" expected="$2"
  if VERIFY_EXIT_CRITERIA_TEST_MODE=1 \
    VERIFY_EXIT_CRITERIA_TEST_CASE=canary \
    VERIFY_EXIT_CRITERIA_CANARY_CONFIG="$CANARY_CONFIG" \
    VERIFY_EXIT_CRITERIA_EZGHA_BIN="$TMP/bin/ezgha" \
    CANARY_TEST_MODE="$mode" \
    bash "$ROOT/docs/verify-exit-criteria.sh" >"$TMP/failure-output" 2>&1; then
    echo "FAIL: $mode should fail Gate 4" >&2
    exit 1
  fi
  grep -Fq "$expected" "$TMP/failure-output" \
    || { cat "$TMP/failure-output" >&2; echo "FAIL: $mode missing '$expected'" >&2; exit 1; }
}

run_fixture "$DEFAULT_CONFIG" "Fresh canary run 776 started on ez-runner-test-2 in 10s"
run_fixture "$CANARY_CONFIG" "Fresh canary run 777 started on ez-canary-test-1 in 10s"
run_failure_fixture command-failure "fresh nonce-tracked canary did not complete successfully"
run_failure_fixture bad-json "canary output lacked run_id or runner_name"

echo "VERIFY_EXIT_GATE4_TEST: PASS"
