#!/usr/bin/env bash
# regression test: install.sh must emit a structured restart-attribution line
# for every restart path it drives (Linux systemd restart; macOS install-service
# regeneration). An unattributed clean restart of ezgha.service occurred
# 2026-07-09 18:01:13 with no identifiable invoking session; the acceptance
# criteria for GH#42 are:
#   - every restart of ezgha.service logs invoking session / PID / reason
#   - a future unattributed restart is traceable to its origin from logs alone
#
# This drives install.sh's REAL restart code paths end-to-end with
# `systemctl`/`launchctl`/`ezgha`/`date`/`logname`/`shasum`/`cargo`/`git`/`gh`/`docker`/`uname`
# stubbed out on PATH -- it never touches the live system, never builds the
# real binary, and (by copying install.sh into a docs/-less temp tree) never
# reaches the live ./docs/verify-exit-criteria.sh post-deploy gate.
#
# Usage: bash tests/install_restart_attribution_test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

PASS=true
fail() {
  echo "FAIL: $1" >&2
  PASS=false
}

# ── 1. Build a minimal, docs/-less copy of the tree install.sh needs ─────
TEMP_REPO="${WORK}/repo"
mkdir -p "${TEMP_REPO}/systemd" "${TEMP_REPO}/scripts"
cp "${REPO_ROOT}/install.sh" "${TEMP_REPO}/install.sh"
cp "${REPO_ROOT}"/systemd/ezgha-*.service "${REPO_ROOT}"/systemd/ezgha-*.timer "${TEMP_REPO}/systemd/" 2>/dev/null || true
printf '[package]\nname = "ez-gh-actions"\nversion = "0.0.0"\n' > "${TEMP_REPO}/Cargo.toml"
for name in ezgha-fleet-watchdog.sh refresh_gh_app_token.sh cleanup-stuck-runs.sh; do
  printf '#!/usr/bin/env bash\ntrue\n' > "${TEMP_REPO}/scripts/${name}"
  chmod +x "${TEMP_REPO}/scripts/${name}"
done

# ── 2. Stub PATH ─────────────────────────────────────────────────────────
STUB_BIN="${WORK}/bin"
mkdir -p "${STUB_BIN}"

cat > "${STUB_BIN}/git" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  branch) echo "main" ;;
  status) exit 0 ;;
  fetch) exit 0 ;;
  rev-parse) echo "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" ;;
  *) exit 0 ;;
esac
EOF

cat > "${STUB_BIN}/cargo" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "${STUB_BIN}/rustc" <<'EOF'
#!/usr/bin/env bash
echo "rustc 1.0.0 (stub)"
EOF

cat > "${STUB_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "${STUB_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "${STUB_BIN}/shasum" <<'EOF'
#!/usr/bin/env bash
echo "da39a3ee5e6b4b0d3255bfef95601890afd80709"
EOF

cat > "${STUB_BIN}/date" <<'EOF'
#!/usr/bin/env bash
# Deterministic stub: always returns 2026-07-09T18:01:13Z for -u +FORMAT.
# For other invocations just pass through. Installed last on PATH so it
# shadows the real /bin/date -- install.sh's helper uses `date -u +...`.
case "$*" in
  *"-u +"*) echo "2026-07-09T18:01:13Z" ;;
  *) exec /bin/date "$@" ;;
esac
EOF

cat > "${STUB_BIN}/logname" <<'EOF'
#!/usr/bin/env bash
echo "testuser"
EOF

cat > "${STUB_BIN}/id" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  -un) echo "testuser" ;;
  *) exec /usr/bin/id "$@" ;;
esac
EOF

# Stateful stub: log every invocation to SYSTEMCTL_LOG; the test asserts
# that a restart_attribution line was emitted BEFORE the restart was logged
# (i.e. attribution precedes the action it describes).
cat > "${STUB_BIN}/systemctl" <<'EOF'
#!/usr/bin/env bash
: "${SYSTEMCTL_LOG:?SYSTEMCTL_LOG must be exported}"
echo "systemctl $*" >> "${SYSTEMCTL_LOG}"
if [ "${1:-}" = "--user" ]; then shift; fi
sub="${1:-}"
shift || true
case "${sub}" in
  is-active)
    # default: report inactive so we exercise the install-service path
    exit 1
    ;;
  enable|disable|daemon-reload) exit 0 ;;
  restart) exit 0 ;;
  *) exit 0 ;;
esac
EOF

cat > "${STUB_BIN}/launchctl" <<'EOF'
#!/usr/bin/env bash
: "${LAUNCHCTL_LOG:?LAUNCHCTL_LOG must be exported}"
echo "launchctl $*" >> "${LAUNCHCTL_LOG}"
case "$1" in
  list)
    # default: empty list -- exercises the install-service path on Mac
    exit 0
    ;;
  load|unload) exit 0 ;;
  *) exit 0 ;;
esac
EOF

# Stub for the cargo-installed binary install.sh invokes as
# "${CARGO_BIN}/${BIN} install-service". We never want this to actually run;
# it's just a stub whose argv is logged to BINARY_LOG.
cat > "${STEMP_BIN_DIR:-${STUB_BIN}/ezgha}" <<'EOF'
#!/usr/bin/env bash
: "${BINARY_LOG:?BINARY_LOG must be exported}"
echo "ezgha $*" >> "${BINARY_LOG}"
exit 0
EOF
mv "${STUB_BIN}/ezgha" "${STUB_BIN}/ezgha.tmp" 2>/dev/null || true
cat > "${STUB_BIN}/ezgha" <<'EOF'
#!/usr/bin/env bash
: "${BINARY_LOG:?BINARY_LOG must be exported}"
echo "ezgha $*" >> "${BINARY_LOG}"
exit 0
EOF

cat > "${STUB_BIN}/uname" <<'EOF'
#!/usr/bin/env bash
case "${UNAME_REPORT:-Linux}" in
  Linux) echo Linux ;;
  Darwin) echo Darwin ;;
  *) echo "${UNAME_REPORT}" ;;
esac
EOF

chmod +x "${STUB_BIN}"/*
export PATH="${STUB_BIN}:${PATH}"

# Helper: run install.sh with our stubbed PATH and a per-test HOME.
run_install() {
  local temp_home="$1"
  local reason="${2:-}"
  local uname_report="${3:-Linux}"
  shift 3 || true
  mkdir -p "${temp_home}"
  : > "${temp_home}/install.stdout"
  : > "${temp_home}/install.stderr"
  HOME="${temp_home}" \
    SYSTEMCTL_LOG="${temp_home}/systemctl.log" \
    LAUNCHCTL_LOG="${temp_home}/launchctl.log" \
    BINARY_LOG="${temp_home}/ezgha.log" \
    UNAME_REPORT="${uname_report}" \
    bash "${TEMP_REPO}/install.sh" --dev "$@" \
      > "${temp_home}/install.stdout" 2> "${temp_home}/install.stderr"
}

# Helper: extract restart_attribution lines (stderr) from a run. We require
# the helper to log to stderr so journalctl captures it under systemd.
extract_attribution_lines() {
  local stderr_file="$1"
  grep -E '^INFO ezgha restart_attribution ' "${stderr_file}" || true
}

# ── Case 1: Linux restart logs attribution ────────────────────────────────
HOME_1="${WORK}/home_1"
run_install "${HOME_1}"

LINUX_ATTR="$(extract_attribution_lines "${HOME_1}/install.stderr")"
if [ -z "${LINUX_ATTR}" ]; then
  fail "Case 1: Linux restart path did not emit a restart_attribution line on stderr"
else
  # Exactly one attribution line per restart path (a single restart of ezgha
  # is one attribution event, not multiple).
  LINUX_COUNT=$(printf '%s\n' "${LINUX_ATTR}" | wc -l | tr -d ' ')
  if [ "${LINUX_COUNT}" != "1" ]; then
    fail "Case 1: expected exactly 1 restart_attribution line on Linux restart, got ${LINUX_COUNT}"
  else
    echo "PASS: Case 1: Linux restart path emits a single restart_attribution line on stderr"
  fi

  LINE="${LINUX_ATTR}"
  for required in "ts=" "pid=" "ppid=" "session=" "reason=" "invocation="; do
    case "${LINE}" in
      *"${required}"*)
        echo "PASS: Case 1: attribution line contains ${required}"
        ;;
      *)
        fail "Case 1: attribution line missing ${required}: ${LINE}"
        ;;
    esac
  done

  # Attribution must be logged BEFORE the actual restart command, so a reader
  # can correlate the two.
  ATTR_LINE_NO=$(grep -n '^INFO ezgha restart_attribution ' "${HOME_1}/install.stderr" | head -1 | cut -d: -f1)
  RESTART_LINE_NO=$(grep -n 'systemctl.*restart ezgha.service' "${HOME_1}/systemctl.log" | head -1 | cut -d: -f1)
  if [ -n "${ATTR_LINE_NO}" ] && [ -n "${RESTART_LINE_NO}" ] && [ "${ATTR_LINE_NO}" -lt "${RESTART_LINE_NO}" ]; then
    echo "PASS: Case 1: attribution line precedes the systemctl restart call"
  else
    fail "Case 1: attribution line ${ATTR_LINE_NO} must precede restart line ${RESTART_LINE_NO}"
  fi
fi

# ── Case 2: Mac install-service path logs attribution ─────────────────────
HOME_2="${WORK}/home_2"
run_install "${HOME_2}" "" "Darwin"

MAC_ATTR="$(extract_attribution_lines "${HOME_2}/install.stderr")"
if [ -z "${MAC_ATTR}" ]; then
  fail "Case 2: Mac install-service path did not emit a restart_attribution line on stderr"
else
  MAC_COUNT=$(printf '%s\n' "${MAC_ATTR}" | wc -l | tr -d ' ')
  if [ "${MAC_COUNT}" -lt "1" ]; then
    fail "Case 2: Mac install-service path emitted 0 attribution lines (want >=1)"
  else
    echo "PASS: Case 2: Mac install-service path emits restart_attribution line(s) on stderr"
  fi

  # The Mac attribution must precede the ezgha install-service invocation,
  # so a future incident reader can correlate the log line to the actual
  # install-service call.
  ATTR_LINE_NO=$(grep -n '^INFO ezgha restart_attribution ' "${HOME_2}/install.stderr" | head -1 | cut -d: -f1)
  INSTALL_LINE_NO=$(grep -n 'ezgha install-service' "${HOME_2}/ezgha.log" | head -1 | cut -d: -f1)
  if [ -n "${ATTR_LINE_NO}" ] && [ -n "${INSTALL_LINE_NO}" ] && [ "${ATTR_LINE_NO}" -lt "${INSTALL_LINE_NO}" ]; then
    echo "PASS: Case 2: Mac attribution line precedes the ezgha install-service call"
  else
    fail "Case 2: Mac attribution line ${ATTR_LINE_NO} must precede install-service call ${INSTALL_LINE_NO}"
  fi
fi

# ── Case 3: reason defaults to 'install-sh auto-restart' when env unset ──
HOME_3="${WORK}/home_3"
run_install "${HOME_3}"

LINUX_ATTR_3="$(extract_attribution_lines "${HOME_3}/install.stderr")"
# Force the Linux restart path (systemctl is-active returns 1 -> install-service branch
# in our stub, so we need a different mechanism). Re-run with systemctl active.
cat > "${STUB_BIN}/systemctl" <<'EOF'
#!/usr/bin/env bash
: "${SYSTEMCTL_LOG:?SYSTEMCTL_LOG must be exported}"
echo "systemctl $*" >> "${SYSTEMCTL_LOG}"
if [ "${1:-}" = "--user" ]; then shift; fi
sub="${1:-}"
shift || true
case "${sub}" in
  is-active) exit 0 ;;
  enable|disable|daemon-reload|restart) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "${STUB_BIN}/systemctl"
run_install "${HOME_3}"
LINUX_ATTR_3="$(extract_attribution_lines "${HOME_3}/install.stderr")"
if [ -z "${LINUX_ATTR_3}" ]; then
  fail "Case 3: no attribution line on Linux restart (is-active=0)"
else
  if printf '%s' "${LINUX_ATTR_3}" | grep -q 'reason="install-sh auto-restart"'; then
    echo "PASS: Case 3: default reason is 'install-sh auto-restart' when EZGHA_RESTART_REASON is unset"
  else
    fail "Case 3: default reason not 'install-sh auto-restart': ${LINUX_ATTR_3}"
  fi
fi

# ── Case 4: EZGHA_RESTART_REASON override surfaces in the log ─────────────
HOME_4="${WORK}/home_4"
: > "${HOME_4}/install.stderr"
HOME="${HOME_4}" \
  SYSTEMCTL_LOG="${HOME_4}/systemctl.log" \
  LAUNCHCTL_LOG="${HOME_4}/launchctl.log" \
  BINARY_LOG="${HOME_4}/ezgha.log" \
  UNAME_REPORT="Linux" \
  EZGHA_RESTART_REASON="host pressure" \
  bash "${TEMP_REPO}/install.sh" --dev \
    > "${HOME_4}/install.stdout" 2> "${HOME_4}/install.stderr"
LINUX_ATTR_4="$(extract_attribution_lines "${HOME_4}/install.stderr")"
if [ -z "${LINUX_ATTR_4}" ]; then
  fail "Case 4: no attribution line when EZGHA_RESTART_REASON=host pressure is set"
else
  if printf '%s' "${LINUX_ATTR_4}" | grep -q 'reason="host pressure"'; then
    echo "PASS: Case 4: EZGHA_RESTART_REASON=host pressure surfaces verbatim in attribution line"
  else
    fail "Case 4: EZGHA_RESTART_REASON override not reflected: ${LINUX_ATTR_4}"
  fi
fi

# ── Case 5: attribution logs to stderr, not stdout ───────────────────────
HOME_5="${WORK}/home_5"
run_install "${HOME_5}"

STDOUT_HITS=$(grep -c '^INFO ezgha restart_attribution ' "${HOME_5}/install.stdout" || true)
STDERR_HITS=$(grep -c '^INFO ezgha restart_attribution ' "${HOME_5}/install.stderr" || true)

if [ "${STDOUT_HITS}" = "0" ] && [ "${STDERR_HITS}" -ge "1" ]; then
  echo "PASS: Case 5: attribution goes to stderr (not stdout) so journalctl captures it under systemd"
elif [ "${STDOUT_HITS}" -ge "1" ]; then
  fail "Case 5: attribution line appeared on stdout ${STDOUT_HITS} time(s) (must be 0)"
else
  fail "Case 5: attribution went to stderr ${STDERR_HITS} time(s) but stdout had 0 -- no attribution line was emitted at all"
fi

if [ "${PASS}" = true ]; then
  echo "ALL PASS"
  exit 0
else
  echo "ONE OR MORE ASSERTIONS FAILED" >&2
  exit 1
fi