#!/usr/bin/env bash
# Behavioral test for sync_installed_scripts.sh drift detection and synchronization.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SYNC_SCRIPT="$REPO_ROOT/scripts/sync_installed_scripts.sh"

TMP_DIR="$(mktemp -d /tmp/ezgha_sync_test.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

echo "=== EZGHA sync_installed_scripts.sh Test Suite ==="

TARGET_DIR="$TMP_DIR/libexec/ezgha"
mkdir -p "$TARGET_DIR"

# Test 1: Empty target directory detects drift with --check
echo "Test 1: --check on unpopulated target exits 1"
set +e
OUT1="$("$SYNC_SCRIPT" --check --dest "$TARGET_DIR" 2>&1)"
RC1=$?
set -e
if [[ "$RC1" -ne 0 ]] && echo "$OUT1" | grep -q "drifted file"; then
  pass "--check detects missing files"
else
  fail "--check detects missing files (rc=$RC1)"
fi

# Test 2: Sync populates target directory with executable permissions
echo "Test 2: sync populates target with 0755 scripts"
set +e
OUT2="$("$SYNC_SCRIPT" --dest "$TARGET_DIR" 2>&1)"
RC2=$?
set -e
if [[ "$RC2" -eq 0 ]] && [[ -x "$TARGET_DIR/cleanup-stuck-runs.sh" ]]; then
  pass "sync populates executable scripts"
else
  fail "sync populates executable scripts (rc=$RC2)"
fi

# Test 3: --check exits 0 after full sync
echo "Test 3: --check passes with 0 drifted files after sync"
set +e
OUT3="$("$SYNC_SCRIPT" --check --dest "$TARGET_DIR" 2>&1)"
RC3=$?
set -e
if [[ "$RC3" -eq 0 ]] && echo "$OUT3" | grep -q "0 drifted files"; then
  pass "--check passes cleanly after sync"
else
  fail "--check passes cleanly after sync (rc=$RC3)"
fi

# Test 4: Modifying target file causes --check to fail
echo "Test 4: Drifted target file is detected by --check"
echo "# modified" >> "$TARGET_DIR/cleanup-stuck-runs.sh"
set +e
OUT4="$("$SYNC_SCRIPT" --check --dest "$TARGET_DIR" 2>&1)"
RC4=$?
set -e
if [[ "$RC4" -ne 0 ]] && echo "$OUT4" | grep -q "DRIFTED cleanup-stuck-runs.sh"; then
  pass "drifted file detected"
else
  fail "drifted file detected (rc=$RC4)"
fi

# Test 5: Re-sync restores parity
echo "Test 5: Re-sync restores parity"
"$SYNC_SCRIPT" --dest "$TARGET_DIR" >/dev/null 2>&1
if "$SYNC_SCRIPT" --check --dest "$TARGET_DIR" >/dev/null 2>&1; then
  pass "re-sync restores parity and --check exits 0"
else
  fail "re-sync restores parity and --check exits 0"
fi

echo
echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]
