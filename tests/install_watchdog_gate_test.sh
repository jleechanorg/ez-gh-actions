#!/usr/bin/env bash
# regression test: install.sh must NOT unconditionally arm the fleet
# watchdog. Watchdog re-arm is gated on beads ez-gh-actions-30p (P0: no
# SIGTERM handling -- watchdog restarts orphan in-flight registrations),
# uh2, lxn -- see ez-gh-actions-sa1t. A default `./install.sh` run must:
#   (a) still render/copy the ezgha-watchdog.timer/.service unit files
#       (repo is source, ~/.config/systemd/user is what systemctl reads),
#   (b) but SKIP `systemctl --user enable --now` for the watchdog timer,
#   (c) and heal drift: if the watchdog timer is already enabled (e.g. an
#       out-of-band re-arm), disable it.
# `./install.sh --with-watchdog` must enable it.
#
# This drives install.sh's REAL Linux watchdog-gating code path end-to-end
# with `systemctl`/`docker`/`gh`/`cargo`/`git` stubbed out on PATH -- it
# never touches the live system, never builds the real binary, and (by
# copying install.sh into a docs/-less temp tree) never reaches the live
# ./docs/verify-exit-criteria.sh post-deploy gate. Per CLAUDE.md: "Do NOT
# run install.sh against the live system -- stubs only."
#
# Usage: bash tests/install_watchdog_gate_test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

PASS=true
fail() {
  echo "FAIL: $1" >&2
  PASS=false
}

INSTALLED_MAC_HOST_ARG="$(
  sed -n 's/.*ezgha-fleet-watchdog\.sh" "--host \([^" ]*\)".*/\1/p' \
    "$REPO_ROOT/install.sh"
)"
PARSER_HOSTS="$(
  sed -n 's/.*argument (\([^)]*\)).*/\1/p' \
    "$REPO_ROOT/scripts/ezgha-fleet-watchdog.sh" | head -1
)"
if printf '%s\n' "$PARSER_HOSTS" | tr '|' '\n' | grep -Fxq "$INSTALLED_MAC_HOST_ARG"; then
  echo "PASS: Mac watchdog install host '$INSTALLED_MAC_HOST_ARG' matches parser"
else
  fail "Mac watchdog install host '$INSTALLED_MAC_HOST_ARG' is outside parser contract '$PARSER_HOSTS'"
fi

# ── 1. Build a minimal, docs/-less copy of the tree install.sh needs ─────────
# (docs/-less so the live post-deploy verify-exit-criteria.sh gate is never
# reached -- see header comment.)
TEMP_REPO="${WORK}/repo"
mkdir -p "${TEMP_REPO}/systemd" "${TEMP_REPO}/scripts"
cp "${REPO_ROOT}/install.sh" "${TEMP_REPO}/install.sh"
cp "${REPO_ROOT}"/systemd/ezgha-*.service "${REPO_ROOT}"/systemd/ezgha-*.timer "${TEMP_REPO}/systemd/"
printf '[package]\nname = "ez-gh-actions"\nversion = "0.0.0"\n' > "${TEMP_REPO}/Cargo.toml"
for name in ezgha-fleet-watchdog.sh refresh_gh_app_token.sh cleanup-stuck-runs.sh; do
  printf '#!/usr/bin/env bash\ntrue\n' > "${TEMP_REPO}/scripts/${name}"
  chmod +x "${TEMP_REPO}/scripts/${name}"
done

# ── 2. Stub PATH ───────────────────────────────────────────────────────────
# git/cargo/rustc/docker/gh: always succeed, never touch anything real.
# systemctl: a stateful fake that remembers per-unit enable/disable state in
# $SYSTEMCTL_STATE_DIR so the test can assert on it afterward.
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

cat > "${STUB_BIN}/uname" <<'EOF'
#!/usr/bin/env bash
echo Linux
EOF

cat > "${STUB_BIN}/systemctl" <<'EOF'
#!/usr/bin/env bash
# Stateful stub: enable/disable/is-enabled tracked as touch-files under
# $SYSTEMCTL_STATE_DIR/<unit>.enabled -- SYSTEMCTL_STATE_DIR is exported by
# the test harness.
: "${SYSTEMCTL_STATE_DIR:?SYSTEMCTL_STATE_DIR must be exported}"
if [ "${1:-}" = "--user" ]; then shift; fi
sub="${1:-}"
shift || true
case "${sub}" in
  enable)
    [ "${1:-}" = "--now" ] && shift
    touch "${SYSTEMCTL_STATE_DIR}/${1}.enabled"
    exit 0
    ;;
  disable)
    [ "${1:-}" = "--now" ] && shift
    rm -f "${SYSTEMCTL_STATE_DIR}/${1}.enabled"
    exit 0
    ;;
  is-enabled)
    [ -f "${SYSTEMCTL_STATE_DIR}/${1}.enabled" ] && exit 0 || exit 1
    ;;
  is-active)
    exit 1
    ;;
  daemon-reload)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF

chmod +x "${STUB_BIN}"/*
export PATH="${STUB_BIN}:${PATH}"

run_install() {
  # $1 = temp HOME, $2 = systemctl state dir, remaining = install.sh args
  local temp_home="$1" state_dir="$2"
  shift 2
  mkdir -p "${state_dir}"
  HOME="${temp_home}" SYSTEMCTL_STATE_DIR="${state_dir}" \
    bash "${TEMP_REPO}/install.sh" --dev "$@" >"${temp_home}/install.log" 2>&1
}

# ── Case A: default run (no --with-watchdog) ─────────────────────────────────
HOME_A="${WORK}/home_a"
STATE_A="${WORK}/state_a"
mkdir -p "${HOME_A}"
run_install "${HOME_A}" "${STATE_A}"

if [ -f "${STATE_A}/ezgha-watchdog.timer.enabled" ]; then
  fail "Case A: default run armed ezgha-watchdog.timer (must stay disabled without --with-watchdog)"
else
  echo "PASS: Case A: default run left ezgha-watchdog.timer disabled"
fi

if [ ! -f "${STATE_A}/ezgha-token-refresh.timer.enabled" ] || [ ! -f "${STATE_A}/ezgha-queue-reaper.timer.enabled" ]; then
  fail "Case A: default run failed to enable token-refresh/queue-reaper timers (only watchdog should be gated)"
else
  echo "PASS: Case A: default run still enabled token-refresh + queue-reaper timers"
fi

rendered_unit="${HOME_A}/.config/systemd/user/ezgha-watchdog.timer"
if [ ! -f "${rendered_unit}" ]; then
  fail "Case A: default run did not render ezgha-watchdog.timer unit file (unit files must always be rendered; only enable/load is gated)"
else
  echo "PASS: Case A: default run still rendered ezgha-watchdog.timer unit file"
fi

if ! grep -q "watchdog arming skipped" "${HOME_A}/install.log"; then
  fail "Case A: install.sh did not print the watchdog-gated skip message"
else
  echo "PASS: Case A: install.sh printed the watchdog-gated skip message"
fi

# ── Case B: heal drift -- a pre-enabled watchdog timer must be disabled ──────
HOME_B="${WORK}/home_b"
STATE_B="${WORK}/state_b"
mkdir -p "${HOME_B}" "${STATE_B}"
touch "${STATE_B}/ezgha-watchdog.timer.enabled"   # simulate out-of-band re-arm
run_install "${HOME_B}" "${STATE_B}"

if [ -f "${STATE_B}/ezgha-watchdog.timer.enabled" ]; then
  fail "Case B: default run did NOT heal a pre-enabled (out-of-band) ezgha-watchdog.timer"
else
  echo "PASS: Case B: default run disabled a drifted-enabled ezgha-watchdog.timer"
fi

# ── Case C: --with-watchdog arms it ───────────────────────────────────────────
HOME_C="${WORK}/home_c"
STATE_C="${WORK}/state_c"
mkdir -p "${HOME_C}"
run_install "${HOME_C}" "${STATE_C}" --with-watchdog

if [ ! -f "${STATE_C}/ezgha-watchdog.timer.enabled" ]; then
  fail "Case C: --with-watchdog did not enable ezgha-watchdog.timer"
else
  echo "PASS: Case C: --with-watchdog enabled ezgha-watchdog.timer"
fi

if [ ! -f "${STATE_C}/ezgha-token-refresh.timer.enabled" ] || [ ! -f "${STATE_C}/ezgha-queue-reaper.timer.enabled" ]; then
  fail "Case C: --with-watchdog run failed to also enable token-refresh/queue-reaper timers"
else
  echo "PASS: Case C: --with-watchdog run still enabled token-refresh + queue-reaper timers"
fi

# ── Case D: flag composes with --dev (already exercised via run_install,
#            which always passes --dev) -- verify --with-watchdog placed
#            BEFORE --dev also works (order independence) ──────────────────
HOME_D="${WORK}/home_d"
STATE_D="${WORK}/state_d"
mkdir -p "${HOME_D}" "${STATE_D}"
HOME="${HOME_D}" SYSTEMCTL_STATE_DIR="${STATE_D}" \
  bash "${TEMP_REPO}/install.sh" --with-watchdog --dev >"${HOME_D}/install.log" 2>&1
if [ ! -f "${STATE_D}/ezgha-watchdog.timer.enabled" ]; then
  fail "Case D: '--with-watchdog --dev' (flag order swapped) did not enable ezgha-watchdog.timer"
else
  echo "PASS: Case D: flags compose regardless of order"
fi

if [ "${PASS}" = true ]; then
  echo "ALL PASS"
  exit 0
else
  echo "ONE OR MORE ASSERTIONS FAILED" >&2
  exit 1
fi
