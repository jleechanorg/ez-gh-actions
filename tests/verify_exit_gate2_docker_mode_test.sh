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

cat > "$BIN/colima" <<'EOF'
#!/usr/bin/env bash
case "${LIMA_STATUS:-Stopped}" in
Running)
    printf 'INFO: Colima is running\n'
    exec python3 -c 'import os, signal; signal.signal(signal.SIGPIPE, signal.SIG_DFL); payload=b"INFO: Colima is running\n" + b"status detail\n" * 200000; exec("while payload:\n n=os.write(1,payload)\n payload=payload[n:]")'
    ;;
Error)
    printf 'INFO: Colima is running despite probe error\n'
    exit 2
    ;;
esac
printf 'INFO: Colima is stopped\n'
EOF
chmod +x "$BIN/colima"

run_case() {
    local label="$1" mode="$2" expected_rc="$3" expected_error="$4" lima_status="$5" platform="${6:-linux}" output rc
    set +e
    output=$(PATH="$BIN:$PATH" VERIFY_EXIT_CRITERIA_TEST_MODE=1 \
        VERIFY_EXIT_CRITERIA_TEST_CASE=gate2_vm_state \
        VERIFY_EXIT_CRITERIA_PLATFORM="$platform" \
        VERIFY_EXIT_CRITERIA_DOCKER_MODE="$mode" \
        LIMA_STATUS="$lima_status" BASH_ENV=/dev/null bash "$VERIFY" 2>&1)
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
run_case "native host Docker" host-docker 0 "" Stopped

# VM-backed Docker still fails closed when its Lima VM is stopped.
run_case "VM-backed Docker stopped" vm-backed 1 "Colima/Lima VM is stopped" Stopped

# A running VM satisfies the same VM-backed check.
run_case "VM-backed Docker running" vm-backed 0 "" Running

# The fake Colima producer emits enough output after its running line for a
# quiet grep to close the pipe early and signal the producer under pipefail.
run_case "Colima VM stopped" vm-backed 1 "Colima VM is not running" Stopped macos
run_case "Colima VM running with verbose status" vm-backed 0 "" Running macos
run_case "Colima status command fails closed" vm-backed 1 "Colima status probe failed" Error macos

echo "VERIFY_EXIT_GATE2_DOCKER_MODE_TEST: PASS"
