#!/usr/bin/env bash
# regression test: .githooks/pre-push (GH#103 / bead jleechan-zs0j)
# Proves the pre-push hook:
#   (a) BLOCKS push when Rust files changed AND installed binary SHA differs
#       from HEAD (binary-drift detected)  -> exits 1
#   (b) IS BYPASSABLE via EZGHA_SKIP_BINARY_DRIFT_CHECK=1  -> exits 0
#   (c) IS SKIPPED (exit 0) when no Rust files changed in the latest commit
#       (bash/docs-only commit is not a binary-drift concern)
#   (d) WARNS (exit 0) when the installed binary is missing (fresh-host)
#
# Stubs `git`, `ezgha`, and `cargo` on PATH so the test never touches the
# live host. Each test case builds a synthetic one-commit repo and invokes
# the hook directly with the right environment.
#
# Usage: bash tests/install_binary_drift_test.sh

set -u  # do NOT add -e: bash returns nonzero from stub `git` cases we never invoke, which would short-circuit the script. Pipefail omitted for the same reason.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_ROOT/.githooks/pre-push"

PASS=true
fail() {
  echo "FAIL: $1" >&2
  PASS=false
}

# Working tree for the test. Everything here is throwaway.
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# ── Stub dir on PATH ──────────────────────────────────────────────────────
STUB="${WORK}/bin"
mkdir -p "${STUB}"

# A second stub dir containing ONLY git/cargo (no ezgha stub) for tests
# that want to exercise the "fresh-host: ezgha binary missing" code path
# without the stub ezgha shadowing the assertion.
STUB_NO_EZGHA="${WORK}/bin_no_ezgha"
mkdir -p "${STUB_NO_EZGHA}"

# Stable fake SHA the stubbed `ezgha --version` will report as installed.
# HEAD SHA will be different (`1234567...`) when we want to assert drift.
FAKE_INSTALLED_SHA_PREFIX="deadbeef"   # intentionally distinct from HEAD below

# Stub git: everything routes through a stateful fake. We need:
#   rev-parse HEAD  -> echo HEAD_SHA
#   rev-parse --short HEAD -> echo short HEAD_SHA
#   diff --name-only HEAD~1..HEAD -- <pathspec> -> echo names of files
#                                                  changed in latest commit
#   log -1 --format=%s HEAD -> echo subject
# All other commands return 0.
cat > "${STUB}/git" <<'STUB_EOF'
#!/usr/bin/env bash
# Configurable via env: FAKE_HEAD_SHA, FAKE_RUST_CHANGED_FILES (newline-separated)
: "${FAKE_HEAD_SHA:=1234567890abcdef1234567890abcdef12345678}"
case "$1" in
  rev-parse)
    shift
    case "$1" in
      HEAD)
        printf '%s\n' "${FAKE_HEAD_SHA}"
        exit 0
        ;;
      --short|HEAD)
        # rev-parse --short HEAD
        if [ "${1:-}" = "--short" ] && [ "${2:-}" = "HEAD" ]; then
          printf '%s\n' "${FAKE_HEAD_SHA:0:7}"
          exit 0
        fi
        printf '%s\n' "${FAKE_HEAD_SHA}"
        exit 0
        ;;
    esac
    printf '%s\n' "${FAKE_HEAD_SHA}"
    exit 0
    ;;
  diff)
    # diff --name-only HEAD~1..HEAD -- path... -> echo FAKE_RUST_CHANGED_FILES
    shift
    if [ "${1:-}" = "--name-only" ]; then
      # emit every fake changed file
      if [ -n "${FAKE_RUST_CHANGED_FILES:-}" ]; then
        printf '%s\n' "${FAKE_RUST_CHANGED_FILES}"
      fi
      exit 0
    fi
    exit 0
    ;;
  log)
    shift
    printf 'synthetic test commit\n'
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
STUB_EOF
chmod +x "${STUB}/git"

# Stub `ezgha`: prints a fake version string of the form the real binary
# uses: `ezgha <version>-<7-to-40 hex SHA>-<rest>`.
cat > "${STUB}/ezgha" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  --version)
    printf 'ezgha 0.0.0-${FAKE_INSTALLED_SHA_PREFIX}1234567890abcdef1234-x86_64-unknown-linux-gnu\n'
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "${STUB}/ezgha"

# Stub `cargo`: never touches anything.
cat > "${STUB}/cargo" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${STUB}/cargo"

# Copy the git/cargo stubs (NOT ezgha) into STUB_NO_EZGHA for the
# fresh-host case. This way the hook can run its `git diff` step under
# our stub while `command -v ezgha` finds nothing (no stub, no real
# binary on /usr/bin or /bin).
cp "${STUB}/git"   "${STUB_NO_EZGHA}/git"
cp "${STUB}/cargo" "${STUB_NO_EZGHA}/cargo"
chmod +x "${STUB_NO_EZGHA}/git" "${STUB_NO_EZGHA}/cargo"

# Helper: run the hook under our stub PATH, with optional env overrides,
# and return its exit code. Stdout/stderr captured into two separate files.
# Extra env NAME=VALUE pairs may be passed after the label and expected_rc.
# If PATH is passed, it OVERRIDES the entire PATH (rather than getting
# appended after our stub dir) -- this lets the fresh-host case strip the
# stub off PATH so `command -v ezgha` cannot find our fake.
run_hook() {
  local label="$1"
  local expected_rc="$2"
  shift 2
  local stdout_file="${WORK}/${label}.out"
  local stderr_file="${WORK}/${label}.err"
  local rc=0
  (
    # First pass: scan args for an explicit PATH override. If we find one,
    # use it as the final PATH (so the test can hide our stub from
    # `command -v ezgha`). Otherwise prepend our stub dir.
    local path_override=""
    local kv
    for kv in "$@"; do
      [ "$kv" = "env" ] && continue
      case "$kv" in
        PATH=*) path_override="${kv#PATH=}" ;;
      esac
    done
    if [ -n "${path_override}" ]; then
      export PATH="${path_override}"
    else
      export PATH="${STUB}:${PATH}"
    fi
    for kv in "$@"; do
      [ "$kv" = "env" ] && continue
      export "$kv"
    done
    bash "$HOOK" >"$stdout_file" 2>"$stderr_file"
  ) || rc=$?
  if [ "$rc" != "$expected_rc" ]; then
    echo "FAIL [$label]: expected rc=$expected_rc got rc=$rc" >&2
    echo "  stdout: $(cat "$stdout_file")" >&2
    echo "  stderr: $(cat "$stderr_file")" >&2
    return 1
  fi
  return 0
}

# Pre-condition: the hook must exist by the time we assert GREEN. If it
# doesn't, every case should fail -- which is exactly the RED state we
# want before Phase 2 lands the hook.
if [ ! -x "$HOOK" ]; then
  fail "pre-push hook missing or not executable: $HOOK"
  echo "RED state confirmed: hook does not exist; running the test will"
  echo "  fail every assertion until the hook is implemented."
  # Continue anyway so we get a complete FAIL report, not a hard exit.
fi

# ── Case (a) BLOCKS push when Rust files changed AND SHA differs ──────────
if [ -x "$HOOK" ]; then
  export FAKE_HEAD_SHA="1234567890abcdef1234567890abcdef12345678"
  export FAKE_RUST_CHANGED_FILES="src/main.rs"
  # FAKE_INSTALLED_SHA_PREFIX is "deadbeef" -> differs from HEAD -> drift
  if run_hook "drift_blocks" 1 \
      "FAKE_HEAD_SHA=${FAKE_HEAD_SHA}" \
      "FAKE_RUST_CHANGED_FILES=${FAKE_RUST_CHANGED_FILES}" \
      "FAKE_INSTALLED_SHA_PREFIX=${FAKE_INSTALLED_SHA_PREFIX}"; then
    # exit 1 is right; ALSO verify stderr contains the helpful message
    if ! grep -q "binary-drift" "${WORK}/drift_blocks.err"; then
      echo "FAIL [drift_blocks]: stderr did not mention 'binary-drift'" >&2
      cat "${WORK}/drift_blocks.err" >&2
      PASS=false
    else
      echo "PASS: binary-drift detected: pre-push exits 1 when Rust files changed and installed SHA differs"
    fi
  else
    PASS=false
  fi
fi

# ── Case (b) BYPASS via EZGHA_SKIP_BINARY_DRIFT_CHECK=1 ───────────────────
if [ -x "$HOOK" ]; then
  export FAKE_HEAD_SHA="1234567890abcdef1234567890abcdef12345678"
  export FAKE_RUST_CHANGED_FILES="src/main.rs"
  if run_hook "bypass_ok" 0 \
      "FAKE_HEAD_SHA=${FAKE_HEAD_SHA}" \
      "FAKE_RUST_CHANGED_FILES=${FAKE_RUST_CHANGED_FILES}" \
      "FAKE_INSTALLED_SHA_PREFIX=${FAKE_INSTALLED_SHA_PREFIX}" \
      "EZGHA_SKIP_BINARY_DRIFT_CHECK=1"; then
    echo "PASS: binary-drift bypassed: pre-push exits 0 when EZGHA_SKIP_BINARY_DRIFT_CHECK=1"
  else
    PASS=false
  fi
fi

# ── Case (c) SKIPPED when no Rust files changed (bash/docs-only commit) ───
if [ -x "$HOOK" ]; then
  export FAKE_HEAD_SHA="1234567890abcdef1234567890abcdef12345678"
  # No Rust files in the changed set -> hook must early-exit 0.
  # The git stub only emits FAKE_RUST_CHANGED_FILES when it is non-empty,
  # so unsetting it produces an empty diff list = hook short-circuits.
  unset FAKE_RUST_CHANGED_FILES
  if run_hook "no_rust_ok" 0 \
      "FAKE_HEAD_SHA=${FAKE_HEAD_SHA}" \
      "FAKE_INSTALLED_SHA_PREFIX=${FAKE_INSTALLED_SHA_PREFIX}"; then
    echo "PASS: binary-drift skipped: pre-push exits 0 when no Rust files changed (bash-only commit)"
  else
    PASS=false
  fi
fi

# ── Case (d) FRESH-HOST: binary missing -> warn and exit 0 ────────────────
if [ -x "$HOOK" ]; then
  export FAKE_HEAD_SHA="1234567890abcdef1234567890abcdef12345678"
  export FAKE_RUST_CHANGED_FILES="src/main.rs"
  # PATH keeps our stub dir (so the stub `git` runs and reports a Rust
  # file change), but the stub `ezgha` is omitted by pointing PATH at the
  # parent dir of the stub. We also point EZGHA_BIN at a non-existent
  # path so the explicit override check also misses. The hook must warn
  # to stderr and still exit 0.
  if run_hook "fresh_host_ok" 0 \
      "FAKE_HEAD_SHA=${FAKE_HEAD_SHA}" \
      "FAKE_RUST_CHANGED_FILES=${FAKE_RUST_CHANGED_FILES}" \
      "FAKE_INSTALLED_SHA_PREFIX=${FAKE_INSTALLED_SHA_PREFIX}" \
      "EZGHA_BIN=${WORK}/no_such_binary/ezgha" \
      "PATH=${STUB_NO_EZGHA}:/usr/bin:/bin"; then
    # Should have printed a fresh-host warning to stderr but still exit 0
    if ! grep -qi "fresh-host\|binary not installed" "${WORK}/fresh_host_ok.err"; then
      echo "FAIL [fresh_host_ok]: stderr did not contain a fresh-host warning" >&2
      cat "${WORK}/fresh_host_ok.err" >&2
      PASS=false
    else
      echo "PASS: binary-drift fresh-host: pre-push exits 0 with warning when binary missing"
    fi
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