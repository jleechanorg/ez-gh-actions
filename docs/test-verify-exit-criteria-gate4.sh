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
  local config="$1" expected="$2" output
  output=$(VERIFY_EXIT_CRITERIA_TEST_MODE=1 \
    VERIFY_EXIT_CRITERIA_TEST_CASE=canary \
    VERIFY_EXIT_CRITERIA_CANARY_CONFIG="$config" \
    VERIFY_EXIT_CRITERIA_EZGHA_BIN="$TMP/bin/ezgha" \
    bash "$ROOT/docs/verify-exit-criteria.sh" 2>&1)
  grep -Fq "$expected" <<<"$output"
  grep -Fq "using $config" <<<"$output"
}

run_fixture "$DEFAULT_CONFIG" "Fresh canary run 776 started on ez-runner-test-2 in 10s"
run_fixture "$CANARY_CONFIG" "Fresh canary run 777 started on ez-canary-test-1 in 10s"

echo "VERIFY_EXIT_GATE4_TEST: PASS"
