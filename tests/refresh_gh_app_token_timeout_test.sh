#!/usr/bin/env bash
# regression test: hung mint cannot block the wrapper past its timeout
# Usage: bash tests/refresh_gh_app_token_timeout_test.sh

set -euo pipefail

# Portable mtime (seconds since epoch): GNU stat on Linux, BSD stat on macOS.
mtime_of() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"
}

# 1. Set up a temp HOME
TEMP_HOME=$(mktemp -d)
export HOME="$TEMP_HOME"
echo "Using temp HOME: $HOME"

# 2. Pre-seed a fake EXISTING token file
TOKEN_DIR="${HOME}/.config/ezgha"
mkdir -p "$TOKEN_DIR"
TOKEN_PATH="${TOKEN_DIR}/gh_token"
EXPECTED_TOKEN="PRE_EXISTING_TOKEN_DO_NOT_OVERWRITE"
printf '%s\n' "$EXPECTED_TOKEN" > "$TOKEN_PATH"
# Record mtime
ORIG_MTIME=$(mtime_of "$TOKEN_PATH")

# 3. Create a temp copy of the repo's scripts/ directory
TEMP_SCRIPTS_DIR=$(mktemp -d)
cp scripts/refresh_gh_app_token.sh "$TEMP_SCRIPTS_DIR/"

# Create a fake mint_gh_app_token.py that just sleeps
cat << 'EOF' > "${TEMP_SCRIPTS_DIR}/mint_gh_app_token.py"
#!/usr/bin/env bash
sleep 120
EOF
chmod +x "${TEMP_SCRIPTS_DIR}/mint_gh_app_token.py"

STDERR_FILE=$(mktemp)

# shellcheck disable=SC2317  # invoked indirectly via trap on EXIT
cleanup() {
  rm -rf "$TEMP_HOME" "$TEMP_SCRIPTS_DIR" "$STDERR_FILE"
}
trap cleanup EXIT

# 4. Run the real refresh_gh_app_token.sh
echo "Running refresh_gh_app_token.sh (should timeout in ~45s)..."
start=$(date +%s)
set +e
"${TEMP_SCRIPTS_DIR}/refresh_gh_app_token.sh" 2>"$STDERR_FILE"
rc=$?
set -e
end=$(date +%s)
elapsed=$((end - start))

echo "Elapsed time: ${elapsed}s"
echo "Exit code: $rc"
echo "Stderr output:"
cat "$STDERR_FILE"

# 5. Assertions
echo "--- Assertions ---"
PASS=true

# (a) wall-clock elapsed is well under 120s and reasonably close to 45s
# We'll allow some margin, say 40-70 seconds.
if [[ $elapsed -ge 40 && $elapsed -lt 90 ]]; then
  echo "Assertion (a) Timeout fired correctly: PASS"
else
  echo "Assertion (a) Timeout fired correctly: FAIL (elapsed ${elapsed}s not in expected range [40, 90))"
  PASS=false
fi

# (b) script's exit code is nonzero
if [[ $rc -ne 0 ]]; then
  echo "Assertion (b) Exit code is nonzero: PASS"
else
  echo "Assertion (b) Exit code is nonzero: FAIL"
  PASS=false
fi

# (c) token file is BYTE-IDENTICAL and mtime is unchanged
ACTUAL_TOKEN=$(cat "$TOKEN_PATH")
NEW_MTIME=$(mtime_of "$TOKEN_PATH")

if [[ "$ACTUAL_TOKEN" == "$EXPECTED_TOKEN" ]]; then
  echo "Assertion (c1) Token content unchanged: PASS"
else
  echo "Assertion (c1) Token content unchanged: FAIL"
  PASS=false
fi

if [[ "$NEW_MTIME" -eq "$ORIG_MTIME" ]]; then
  echo "Assertion (c2) Token mtime unchanged: PASS"
else
  echo "Assertion (c2) Token mtime unchanged: FAIL"
  PASS=false
fi

if [[ $PASS == true ]]; then
  echo "REGRESSION_TEST: PASS"
  exit 0
else
  echo "REGRESSION_TEST: FAIL"
  exit 1
fi
