#!/usr/bin/env bash
# Regression test: prevent shell-interpreted Markdown bodies when creating PRs/comments.
# Usage: bash tests/integrate_pr_payload_regression_test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INTEGRATE_SCRIPT="${REPO_ROOT}/integrate.sh"
PASS=true

fail() {
  echo "FAIL: $1"
  PASS=false
}

echo "Running static lint checks..."

if rg -n --pcre2 'gh\s+pr\s+create\b[^\n]*--body(?!-)' "$INTEGRATE_SCRIPT"; then
  fail "Unsafe inline --body argument detected in integrate.sh gh pr create path."
else
  echo "PASS: No inline --body argument in integrate.sh PR create command."
fi

if rg -q --pcre2 'gh\s+pr\s+create\b[^\n]*--body-file\b' "$INTEGRATE_SCRIPT"; then
  echo "PASS: integrate.sh uses --body-file for PR body text."
else
  fail "Expected integrate.sh to use --body-file for PR body payloads."
fi

echo "Running safe payload exercise against a stub gh command..."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PAYLOAD_FILE="${WORK}/payload.md"
cat << 'EOF' > "$PAYLOAD_FILE"
This is a disposable Markdown payload for regression evidence.

It contains backticks: `hostname`

It contains command-substitution syntax: $(printf "should_not_run")
EOF

SENT_BODY="${WORK}/sent-body.md"
STUB_GH="${WORK}/gh"
cat > "$STUB_GH" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "pr" && "${2:-}" == "create" ]]; then
  while [[ $# -gt 0 ]]; do
    if [[ "${1:-}" == "--body-file" ]]; then
      shift
      cat "$1" > "$SENT_BODY_CAPTURE"
      break
    fi
    shift
  done
  echo "https://github.com/jleechanorg/ez-gh-actions/pull/9999"
  exit 0
fi

echo "unexpected gh invocation: $*" >&2
exit 1
EOF
chmod +x "$STUB_GH"

SENT_BODY_CAPTURE="${WORK}/sent-body.md"
export SENT_BODY_CAPTURE
export PATH="${WORK}:${PATH}"

bash -c '
  pr_title="Regression payload test"
  pr_body_file="$(mktemp)"
  {
    printf "Auto-generated PR body for regression test.\n\n"
    cat "$0" || true
    printf "Please review and close the test PR."
  } > "$pr_body_file"
  gh pr create --title "$pr_title" --body-file "$pr_body_file" >/dev/null
  rm -f "$pr_body_file"
' "$PAYLOAD_FILE"

if ! grep -Fq '`hostname`' "$SENT_BODY_CAPTURE"; then
  fail "Captured body lost backtick content during payload flow."
fi

if ! grep -Fq '$(printf "should_not_run")' "$SENT_BODY_CAPTURE"; then
  fail "Captured body lost command-substitution syntax during payload flow."
fi

if [ "$PASS" = true ]; then
  echo "REPRO_TEST: PASS"
  exit 0
fi

echo "REPRO_TEST: FAIL"
exit 1
