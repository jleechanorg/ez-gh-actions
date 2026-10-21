#!/usr/bin/env bash
# regression test: scripts/lint_gh_api_no_shell_interp.sh (GH#58 / bead jleechan-o9s8)
#
# Proves the lint:
#   (a) FAILS on `gh api ... -f body="$BODY"` where BODY contains backticks
#   (b) FAILS on `gh api ... -f body=$(cat file.md)` — command substitution
#   (c) FAILS on `gh api ... --field body=...` where the value contains a
#       backticked command
#   (d) PASSES on the safe `gh api --input -` reading from `jq --rawfile`
#   (e) PASSES on `jq -Rs <<<"$BODY" | gh api --input -`
#   (f) PASSES on a script that never calls `gh api` at all
#   (g) PASSES on a script with `gh api ... -f body="$(...)"` but the line is
#       inside a `#` comment (comment lines don't execute)
#
# The test scans a tempdir of fixture shell scripts and asserts the lint's
# exit code + error message format. Stubs the lint by setting LINT_BIN env
# so we don't depend on the path living in scripts/.
#
# Usage: bash tests/lint_gh_api_no_shell_interp_test.sh

set -u  # do NOT add -e: bash returns nonzero from some negative assertions

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINT="${LINT_BIN:-$REPO_ROOT/scripts/lint_gh_api_no_shell_interp.sh}"

PASS=true
fail() {
  echo "FAIL: $1" >&2
  PASS=false
}

# Working tree for the test. Everything here is throwaway.
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# ── Fixture writers ──────────────────────────────────────────────────────
# Each test case writes a single fixture script that exercises one pattern.

write_unsafe_backticks() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
BODY="some `echo INJECTED` markdown"
gh api repos/foo/bar/issues -f body="$BODY"
SH
}

write_unsafe_cmdsubst() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
BODY="$(cat /tmp/big.md)"
gh api repos/foo/bar/issues -f body="$BODY"
SH
}

write_unsafe_field_backticks() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
gh api repos/foo/bar/issues --field body="see `id` for details"
SH
}

write_safe_rawfile() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
jq --rawfile BODY_FILE '.' "$BODY_FILE" | gh api repos/foo/bar/issues --input -
SH
}

write_safe_jqrs_heredoc() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
jq -Rs '.' <<<"$BODY" | gh api repos/foo/bar/issues --input -
SH
}

write_no_gh_api() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
echo "hello world"
ls /tmp
SH
}

write_comment_only() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
# gh api repos/foo/bar/issues -f body="$(rm -rf /)"  # a tempting comment
echo "no gh api call here"
SH
}

# ── Runner helper ────────────────────────────────────────────────────────
# Runs the lint against the given fixture dir, returns the lint's exit code,
# and captures stdout/stderr. We always pass an absolute fixture dir so the
# lint gets a real path to scan.
run_lint() {
  local label="$1"
  local expected_rc="$2"
  local scan_dir="$3"
  local stdout_file="${WORK}/${label}.out"
  local stderr_file="${WORK}/${label}.err"
  local rc=0
  bash "$LINT" "$scan_dir" >"$stdout_file" 2>"$stderr_file" || rc=$?
  if [ "$rc" != "$expected_rc" ]; then
    echo "FAIL [$label]: expected rc=$expected_rc got rc=$rc" >&2
    echo "  stdout: $(cat "$stdout_file")" >&2
    echo "  stderr: $(cat "$stderr_file")" >&2
    return 1
  fi
  return 0
}

# Pre-condition: if the lint script doesn't exist yet, every case should
# fail — which is exactly the RED state we want before Phase 2 lands the lint.
if [ ! -x "$LINT" ]; then
  fail "lint missing or not executable: $LINT"
  echo "RED state confirmed: lint does not exist yet; running the test will"
  echo "  fail every assertion until the lint is implemented in Phase 2."
fi

# ── Case (a) unsafe: -f body="\$BODY" with backticks ────────────────────
DIR_A="${WORK}/case_a"; mkdir -p "$DIR_A"
write_unsafe_backticks "$DIR_A/unsafe_backticks.sh"
if [ -x "$LINT" ]; then
  if run_lint "case_a" 1 "$DIR_A"; then
    if ! grep -q "unsafe shell-interpolated gh api" "${WORK}/case_a.err"; then
      echo "FAIL [case_a]: stderr did not mention 'unsafe shell-interpolated gh api'" >&2
      cat "${WORK}/case_a.err" >&2
      PASS=false
    else
      echo "PASS: unsafe: gh api with -f body=\"\$BODY\" where BODY has backticks -> lint FAIL"
    fi
  else
    PASS=false
  fi
fi

# ── Case (b) unsafe: -f body=\$(cat file.md) ──────────────────────────────
DIR_B="${WORK}/case_b"; mkdir -p "$DIR_B"
write_unsafe_cmdsubst "$DIR_B/unsafe_cmdsubst.sh"
if [ -x "$LINT" ]; then
  if run_lint "case_b" 1 "$DIR_B"; then
    echo "PASS: unsafe: gh api with -f body=\$(cat file.md) -> lint FAIL"
  else
    PASS=false
  fi
fi

# ── Case (c) unsafe: --field body="...\`cmd\`..." ────────────────────────
DIR_C="${WORK}/case_c"; mkdir -p "$DIR_C"
write_unsafe_field_backticks "$DIR_C/unsafe_field.sh"
if [ -x "$LINT" ]; then
  if run_lint "case_c" 1 "$DIR_C"; then
    echo "PASS: unsafe: gh api with --field body=...where --field body contains \`cmd\` -> lint FAIL"
  else
    PASS=false
  fi
fi

# ── Case (d) safe: jq --rawfile | gh api --input - ──────────────────────
DIR_D="${WORK}/case_d"; mkdir -p "$DIR_D"
write_safe_rawfile "$DIR_D/safe_rawfile.sh"
if [ -x "$LINT" ]; then
  if run_lint "case_d" 0 "$DIR_D"; then
    echo "PASS: safe: gh api --input - reading from jq --rawfile -> lint PASS"
  else
    PASS=false
  fi
fi

# ── Case (e) safe: jq -Rs <<<"\$BODY" | gh api --input - ────────────────
DIR_E="${WORK}/case_e"; mkdir -p "$DIR_E"
write_safe_jqrs_heredoc "$DIR_E/safe_jqrs.sh"
if [ -x "$LINT" ]; then
  if run_lint "case_e" 0 "$DIR_E"; then
    echo "PASS: safe: jq -Rs <<<\"\$BODY\" | gh api --input - -> lint PASS"
  else
    PASS=false
  fi
fi

# ── Case (f) no gh api call: should PASS ────────────────────────────────
DIR_F="${WORK}/case_f"; mkdir -p "$DIR_F"
write_no_gh_api "$DIR_F/no_gh_api.sh"
if [ -x "$LINT" ]; then
  if run_lint "case_f" 0 "$DIR_F"; then
    echo "PASS: no gh api call: a script that doesn't call gh api at all -> lint PASS"
  else
    PASS=false
  fi
fi

# ── Case (g) comment-only: line is inside `# ...` should PASS ───────────
DIR_G="${WORK}/case_g"; mkdir -p "$DIR_G"
write_comment_only "$DIR_G/comment_only.sh"
if [ -x "$LINT" ]; then
  if run_lint "case_g" 0 "$DIR_G"; then
    echo "PASS: comment-allowed: a script with gh api in a # comment -> lint PASS"
  else
    PASS=false
  fi
fi

if [ "${PASS}" = true ]; then
  echo "ALL PASS"
  exit 0
else
  echo "ONE OR MORE ASSERTIONS FAILED" >&2
  exit 1
fi