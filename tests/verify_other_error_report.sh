#!/usr/bin/env bash
set -euo pipefail

TEMP_HOME=$(mktemp -d)
export HOME="$TEMP_HOME"
TEMP_SCRIPTS_DIR=$(mktemp -d)
cp scripts/refresh_gh_app_token.sh "$TEMP_SCRIPTS_DIR/"

# Create a fake mint_gh_app_token.py that fails with code 42
cat << 'EOF' > "${TEMP_SCRIPTS_DIR}/mint_gh_app_token.py"
#!/usr/bin/env bash
exit 42
EOF
chmod +x "${TEMP_SCRIPTS_DIR}/mint_gh_app_token.py"

STDERR_FILE=$(mktemp)

# shellcheck disable=SC2317  # invoked indirectly via trap on EXIT
cleanup() {
  rm -rf "$TEMP_HOME" "$TEMP_SCRIPTS_DIR" "$STDERR_FILE"
}
trap cleanup EXIT

echo "Running refresh_gh_app_token.sh (should fail with code 42)..."
set +e
"${TEMP_SCRIPTS_DIR}/refresh_gh_app_token.sh" 2>"$STDERR_FILE"
rc=$?
set -e

echo "Exit code: $rc"
echo "Stderr output:"
cat "$STDERR_FILE"

if grep -q "exit code 42" "$STDERR_FILE" &&
  grep -Eq "elapsed_seconds=[0-9]+" "$STDERR_FILE"; then
  echo "MINT_OTHER_ERROR_REPORT: PASS"
else
  echo "MINT_OTHER_ERROR_REPORT: FAIL"
  exit 1
fi
