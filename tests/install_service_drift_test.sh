#!/usr/bin/env bash
# regression test: install.sh must detect & warn when install-service regenerates
# a unit file that differs from the previously-loaded one. The motivating
# incident (GH#15 / bead jleechan-r00n): on 2026-07-06 the systemd --user
# unit was missing WatchdogSec=60 because the binary regenerated it from
# scratch but the operator had no signal that anything changed; the daemon
# was then killed every 60s by systemd watchdog. install.sh now hashes the
# unit file before install-service and warns if the post-call hash differs
# AND the service is not currently active (active services are restarted,
# so the new unit is loaded — no warning needed in that case).
#
# This drives the REAL install.sh code path with all system tools stubbed
# on PATH. Per CLAUDE.md: stubs only — never touches the live system.
#
# Usage: bash tests/install_service_drift_test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORK=$(mktemp -d)
cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT

PASS=true
fail() {
  echo "FAIL: $1" >&2
  PASS=false
}

TEMP_REPO="${WORK}/repo"
mkdir -p "${TEMP_REPO}"
cp "${REPO_ROOT}/install.sh" "${TEMP_REPO}/install.sh"

# ── Stub PATH ────────────────────────────────────────────────────────────
STUB_BIN="${WORK}/bin"
mkdir -p "${STUB_BIN}"

# cargo: always succeeds (we don't run the real binary in this test).
cat > "${STUB_BIN}/cargo" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

# docker: install.sh prereqs check calls `docker version`; succeed silently
# so we reach the install-service code path.
cat > "${STUB_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

# gh: install.sh prereqs check calls `gh auth status`; we want that to fail
# LOUDLY so the test surfaces missing prereq stubs — but install.sh's
# `--dev` flag bypasses production prereqs. Add a stub that always exits 0
# for safety so future prereq changes don't break this test silently.
cat > "${STUB_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

# uname: force Linux so we exercise the systemd branch (the launchd branch
# uses the same shasum-based logic — covered by the same code path with a
# different platform header).
cat > "${STUB_BIN}/uname" <<'EOF'
#!/usr/bin/env bash
echo Linux
EOF

# systemctl: stateful — records calls; is-active returns non-zero unless
# SYSTEMCTL_ACTIVE=1 is exported, which lets each test case pick whether the
# daemon was already running.
cat > "${STUB_BIN}/systemctl" <<'EOF'
#!/usr/bin/env bash
: "${SYSTEMCTL_LOG:?SYSTEMCTL_LOG must be exported}"
echo "systemctl $*" >> "${SYSTEMCTL_LOG}"
if [ "${1:-}" = "--user" ] && [ "${2:-}" = "is-active" ]; then
  if [ "${SYSTEMCTL_ACTIVE:-0}" = "1" ]; then exit 0; else exit 3; fi
fi
exit 0
EOF

# shasum: deterministic; echo `<hash>  <path>` so the awk '{print $1}' in
# install.sh picks up the hash.
cat > "${STUB_BIN}/shasum" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-a" ] && [ "${2:-}" = "256" ]; then
  f="${3:?shasum needs a file}"
  size=$(wc -c < "$f" | tr -d ' ')
  printf 'drift-%s-deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef  %s\n' "$size" "$f"
  exit 0
fi
exit 1
EOF

# ezgha (the binary install.sh would have just installed). This stub
# rewrites the unit file at the canonical path on every `install-service`
# call. We seed the file BEFORE install.sh runs so the "before" hash is
# captured, then let the stub overwrite it with a different content so the
# "after" hash differs. install.sh must notice and warn.
cat > "${STUB_BIN}/ezgha" <<'EOF'
#!/usr/bin/env bash
: "${EZGHA_STUB_LOG:?EZGHA_STUB_LOG must be exported}"
: "${EZGHA_STUB_UNIT:?EZGHA_STUB_UNIT must be exported}"
echo "ezgha $*" >> "${EZGHA_STUB_LOG}"
if [ "${1:-}" = "install-service" ]; then
  printf '[Unit]\nDescription=STUB regenerated unit (differs from pre-call)\nWatchdogSec=60\n' > "${EZGHA_STUB_UNIT}"
  echo "wrote stub unit to ${EZGHA_STUB_UNIT}" >> "${EZGHA_STUB_LOG}"
  exit 0
fi
exit 0
EOF

chmod +x "${STUB_BIN}"/*
export PATH="${STUB_BIN}:${PATH}"

# ── Seed a fully-installed state ─────────────────────────────────────────
HOME_T="${WORK}/home"
mkdir -p "${HOME_T}/.config/ezgha" \
         "${HOME_T}/.config/systemd/user" \
         "${HOME_T}/.cargo/bin"

printf '# stub config\ntarget = "jleechanorg"\n' > "${HOME_T}/.config/ezgha/config.toml"
# Pre-populate the unit file with content that DIFFERS from what the stub
# install-service writes — this is the production failure mode (the unit
# drift went unnoticed in 2026-07-06).
printf '[Unit]\nDescription=OLD unit (missing WatchdogSec=60)\n' \
  > "${HOME_T}/.config/systemd/user/ezgha.service"
# Place a stub cargo binary where install.sh expects CARGO_BIN/ezgha to land
# so the binary call path is exercised.
cp "${STUB_BIN}/ezgha" "${HOME_T}/.cargo/bin/ezgha"

SYSTEMCTL_LOG="${WORK}/systemctl.log"
EZGHA_STUB_LOG="${WORK}/ezgha.log"
EZGHA_STUB_UNIT="${HOME_T}/.config/systemd/user/ezgha.service"
: > "${SYSTEMCTL_LOG}"
: > "${EZGHA_STUB_LOG}"

# ── Case 1: service is NOT active (this is the production failure mode) ──
# install.sh must hash the unit before install-service, observe the drift
# after, and warn that daemon-reload is required before next start.
SYSTEMCTL_ACTIVE=0 \
HOME="${HOME_T}" \
CARGO_BIN="${HOME_T}/.cargo/bin" \
SYSTEMCTL_LOG="${SYSTEMCTL_LOG}" \
EZGHA_STUB_LOG="${EZGHA_STUB_LOG}" \
EZGHA_STUB_UNIT="${EZGHA_STUB_UNIT}" \
  bash "${TEMP_REPO}/install.sh" --dev > "${WORK}/install.log" 2>&1 || true

# install.sh must have invoked the stub ezgha install-service.
if grep -q "ezgha install-service" "${EZGHA_STUB_LOG}"; then
  echo "PASS: install.sh invoked ezgha install-service"
else
  fail "install.sh did NOT invoke ezgha install-service"
  echo "--- ezgha log ---" >&2; cat "${EZGHA_STUB_LOG}" >&2
fi

# install.sh must have warned about the drift when the service is inactive.
if grep -q "systemd --user unit file changed during install-service" "${WORK}/install.log"; then
  echo "PASS: install.sh warned about unit drift (service inactive)"
else
  fail "install.sh did NOT warn about unit drift despite a real before/after hash change"
  echo "--- install.log ---" >&2; cat "${WORK}/install.log" >&2
fi

# install.sh must have recommended daemon-reload.
if grep -q "systemctl --user daemon-reload" "${WORK}/install.log"; then
  echo "PASS: install.sh recommended daemon-reload"
else
  fail "install.sh did NOT recommend daemon-reload after unit drift"
fi

# install.sh must NOT have recommended restart (service was inactive; only
# restart works on an active service).
if grep -q "systemctl --user restart ezgha.service" "${SYSTEMCTL_LOG}"; then
  fail "install.sh called restart despite service being inactive"
else
  echo "PASS: install.sh skipped restart (service was inactive)"
fi

# ── Case 2: service IS active (the safe path) ───────────────────────────
# install.sh should call systemctl restart (which loads the new unit) and
# should NOT emit the drift warning — restart already covered the change.
: > "${SYSTEMCTL_LOG}"
: > "${EZGHA_STUB_LOG}"
# Reset the unit file to a different pre-call content so the "before" hash
# differs from the stub install-service output again.
printf '[Unit]\nDescription=PRE-restart unit\n' > "${HOME_T}/.config/systemd/user/ezgha.service"

SYSTEMCTL_ACTIVE=1 \
HOME="${HOME_T}" \
CARGO_BIN="${HOME_T}/.cargo/bin" \
SYSTEMCTL_LOG="${SYSTEMCTL_LOG}" \
EZGHA_STUB_LOG="${EZGHA_STUB_LOG}" \
EZGHA_STUB_UNIT="${EZGHA_STUB_UNIT}" \
  bash "${TEMP_REPO}/install.sh" --dev > "${WORK}/install-active.log" 2>&1 || true

if grep -q "systemctl --user restart ezgha.service" "${SYSTEMCTL_LOG}"; then
  echo "PASS: install.sh called restart when service was active"
else
  fail "install.sh did NOT call restart when service was active"
fi

if grep -q "systemd --user unit file changed during install-service" "${WORK}/install-active.log"; then
  fail "install.sh emitted drift warning despite service being active (restart already loads new unit)"
else
  echo "PASS: install.sh correctly DID NOT warn when service was active (restart covers it)"
fi

if [ "${PASS}" = true ]; then
  echo "ALL PASS"
  exit 0
else
  echo "ONE OR MORE ASSERTIONS FAILED" >&2
  echo "--- install.log (inactive) ---" >&2; cat "${WORK}/install.log" >&2
  echo "--- install-active.log ---" >&2; cat "${WORK}/install-active.log" >&2
  exit 1
fi