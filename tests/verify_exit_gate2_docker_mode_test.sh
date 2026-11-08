#!/usr/bin/env bash
# Focused Gate-2 regression: native Docker must not require an unrelated Lima
# VM, while a VM-backed Docker endpoint must still require its VM to run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY="$ROOT/docs/verify-exit-criteria.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN"

cat > "$BIN/limactl" <<'EOF'
#!/usr/bin/env bash
printf 'NAME STATUS\ncolima %s\n' "${LIMA_STATUS:-Stopped}"
EOF
chmod +x "$BIN/limactl"

run_case() {
    local label="$1" mode="$2" expected_rc="$3" expected_error="$4" output rc
    set +e
    output=$(PATH="$BIN:$PATH" VERIFY_EXIT_CRITERIA_TEST_MODE=1 \
        VERIFY_EXIT_CRITERIA_TEST_CASE=gate2_vm_state \
        VERIFY_EXIT_CRITERIA_PLATFORM=linux \
        VERIFY_EXIT_CRITERIA_DOCKER_MODE="$mode" \
        LIMA_STATUS="${LIMA_STATUS:-Stopped}" bash "$VERIFY" 2>&1)
    rc=$?
    set -e
    [ "$rc" = "$expected_rc" ] \
      || fail "$label: exit code $rc, expected $expected_rc (output: $output)"
    if [ -n "$expected_error" ]; then
        grep -Fq "$expected_error" <<<"$output" \
          || fail "$label: output missing '$expected_error' (got: $output)"
    fi
}

# Native host Docker succeeds even while an unrelated Lima VM is stopped.
run_case "native host Docker" host-docker 0 ""

# VM-backed Docker still fails closed when its Lima VM is stopped.
run_case "VM-backed Docker stopped" vm-backed 1 "Colima/Lima VM is stopped"

# A running VM satisfies the same VM-backed check.
LIMA_STATUS=Running run_case "VM-backed Docker running" vm-backed 0 ""

echo "VERIFY_EXIT_GATE2_DOCKER_MODE_TEST: PASS"
