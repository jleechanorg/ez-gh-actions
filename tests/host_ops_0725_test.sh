#!/usr/bin/env bash
# regression test: static validation of the bead ez-gh-actions-0725
# host-pressure-relief artifacts (agents.slice, psi-oom-watcher.sh/.service/
# .timer, agent-cli-scoped.sh). This test NEVER starts/enables anything
# live -- it only checks syntax and structural wiring, matching the
# constraint this bead's artifacts were built under ("you MAY validate them
# with systemd-analyze verify ... but do not actually start/enable
# anything").
#
# Checks:
#   1. systemd/agents.slice -- valid unit syntax (systemd-analyze verify,
#      falling back to a structural grep if systemd-analyze is unavailable).
#   2. scripts/host/psi-oom-watcher.sh -- valid bash syntax (bash -n), plus
#      a behavioral smoke test proving the qemu/colima exclusion added
#      after live testing on jeff-ubuntu actually holds (regression guard
#      for the "watcher targets the Colima VM and kills the whole runner
#      fleet" near-miss found during development of this bead).
#   3. scripts/host/agent-cli-scoped.sh -- valid bash syntax (bash -n).
#   4. systemd/psi-oom-watcher.service -- valid unit syntax after
#      @SCRIPTS_DIR@/@HOME@ substitution against a stub executable (mirrors
#      install.sh's real substitution step, see install.sh's aux-unit loop).
#   5. systemd/psi-oom-watcher.timer -- valid unit syntax AND its Unit=
#      directive references the correct service file name.
#
# Usage: bash tests/host_ops_0725_test.sh

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
ok() {
  echo "PASS: $1"
}

HAVE_SYSTEMD_ANALYZE=0
command -v systemd-analyze >/dev/null 2>&1 && HAVE_SYSTEMD_ANALYZE=1

# ── 1. agents.slice syntax ──────────────────────────────────────────────────
SLICE="${REPO_ROOT}/systemd/agents.slice"
if [ ! -f "${SLICE}" ]; then
  fail "systemd/agents.slice does not exist"
else
  if [ "${HAVE_SYSTEMD_ANALYZE}" -eq 1 ]; then
    if systemd-analyze verify --user "${SLICE}" >"${WORK}/slice-verify.log" 2>&1; then
      ok "systemd/agents.slice passes systemd-analyze verify --user"
    else
      fail "systemd/agents.slice failed systemd-analyze verify --user: $(cat "${WORK}/slice-verify.log")"
    fi
  else
    if grep -q '^\[Slice\]' "${SLICE}" && grep -q '^MemoryHigh=' "${SLICE}"; then
      ok "systemd/agents.slice structural check (systemd-analyze unavailable): has [Slice] + MemoryHigh="
    else
      fail "systemd/agents.slice missing [Slice] section or MemoryHigh= directive"
    fi
  fi
  if ! grep -q '^MemoryHigh=20G$' "${SLICE}"; then
    fail "systemd/agents.slice MemoryHigh is not the documented 20G value (blast-radius comment would be stale)"
  else
    ok "systemd/agents.slice MemoryHigh=20G matches documented blast-radius value"
  fi
fi

# ── 2. psi-oom-watcher.sh syntax + qemu/colima exclusion regression ────────
WATCHER="${REPO_ROOT}/scripts/host/psi-oom-watcher.sh"
if [ ! -f "${WATCHER}" ]; then
  fail "scripts/host/psi-oom-watcher.sh does not exist"
else
  if bash -n "${WATCHER}" 2>"${WORK}/watcher-syntax.log"; then
    ok "scripts/host/psi-oom-watcher.sh passes bash -n"
  else
    fail "scripts/host/psi-oom-watcher.sh failed bash -n: $(cat "${WORK}/watcher-syntax.log")"
  fi

  if grep -q 'qemu-system-x86' "${WATCHER}" && grep -q 'colima' "${WATCHER}"; then
    ok "scripts/host/psi-oom-watcher.sh exclusion list references qemu/colima (regression guard present)"
  else
    fail "scripts/host/psi-oom-watcher.sh is missing the qemu/colima exclusion -- REGRESSION: this class of bug let a live dry-run target the Colima VM (32GB RSS qemu-system-x86 process) as the SIGTERM candidate, which would kill the entire runner fleet"
  fi

  if grep -q 'warp-terminal' "${WATCHER}" && grep -q 'gnome-terminal' "${WATCHER}"; then
    ok "scripts/host/psi-oom-watcher.sh exclusion list references GUI terminal emulators (warp-terminal etc, regression guard present)"
  else
    fail "scripts/host/psi-oom-watcher.sh is missing the GUI-terminal-emulator exclusion -- REGRESSION: adversarial verification found warp-terminal (~760MB RSS) was the real second-largest-RSS process on jeff-ubuntu after qemu/colima, and would have been SIGTERM'd instead of an agent CLI process"
  fi

  # Behavioral smoke test: fabricate a fake process table via a stub `ps`
  # on PATH shaped exactly like the REAL fixture seen on jeff-ubuntu during
  # adversarial verification: qemu (Colima VM, ~32GB, must be excluded),
  # then warp-terminal (~760MB, the user's GUI terminal, must be excluded),
  # then a legitimate `claude` agent CLI process (the actual intended
  # target class) -- assert the watcher skips BOTH exclusions and lands on
  # the claude process, never qemu or warp-terminal.
  STUB_BIN="${WORK}/bin"
  mkdir -p "${STUB_BIN}"
  cat > "${STUB_BIN}/ps" <<'EOF'
#!/usr/bin/env bash
# Stub ps: ignores its arguments, always returns a fixed fixture table
# shaped like `ps -o pid=,rss=,comm=,args= --sort=-rss` output, matching
# the real top-of-stack seen on jeff-ubuntu 2026-07-10: qemu (Colima VM)
# and warp-terminal (GUI terminal) both must be excluded; the claude
# process is the legitimate target.
cat <<'TABLE'
  24265 33072676 qemu-system-x86 /usr/bin/qemu-system-x86_64 -m 49152 -drive file=/home/jleechan/.lima/colima/diffdisk -name lima-colima
  12439   759760 warp-terminal /usr/bin/warp-terminal
  19195   616432 claude /home/jleechan/.npm-global/bin/claude
TABLE
EOF
  chmod +x "${STUB_BIN}/ps"

  FAKE_PSI="${WORK}/fake_psi_memory"
  printf 'some avg10=50.00 avg60=30.00 avg300=10.00 total=500\nfull avg10=55.00 avg60=25.00 avg300=8.00 total=200\n' > "${FAKE_PSI}"
  STATE_DIR="${WORK}/state"
  mkdir -p "${STATE_DIR}"

  # First poll only advances the consecutive-CRIT streak; second poll
  # crosses CRIT_CONSECUTIVE=2 and evaluates (DRY_RUN=1, so it logs the
  # target instead of signaling it).
  PATH="${STUB_BIN}:${PATH}" PSI_FILE="${FAKE_PSI}" STATE_DIR="${STATE_DIR}" \
    WARN_THRESHOLD=10 CRIT_THRESHOLD=40 CRIT_CONSECUTIVE=2 DRY_RUN=1 \
    bash "${WATCHER}" >>"${STATE_DIR}/run1.log" 2>&1 || true
  PATH="${STUB_BIN}:${PATH}" PSI_FILE="${FAKE_PSI}" STATE_DIR="${STATE_DIR}" \
    WARN_THRESHOLD=10 CRIT_THRESHOLD=40 CRIT_CONSECUTIVE=2 DRY_RUN=1 \
    bash "${WATCHER}" >>"${STATE_DIR}/run2.log" 2>&1 || true

  WATCHER_LOG="${STATE_DIR}/psi-oom-watcher.log"
  if [ -f "${WATCHER_LOG}" ] && grep -q 'would send SIGTERM' "${WATCHER_LOG}"; then
    if grep 'would send SIGTERM' "${WATCHER_LOG}" | grep -q 'pid=24265'; then
      fail "REGRESSION: watcher selected the Colima VM qemu process (pid=24265) as its SIGTERM target -- this would kill the entire runner fleet"
    elif grep 'would send SIGTERM' "${WATCHER_LOG}" | grep -q 'pid=12439'; then
      fail "REGRESSION: watcher selected the user's GUI terminal (warp-terminal, pid=12439) as its SIGTERM target -- this would kill the user's terminal session mid-crisis"
    elif grep 'would send SIGTERM' "${WATCHER_LOG}" | grep -q 'pid=19195'; then
      ok "watcher correctly skipped qemu/colima AND warp-terminal, landing on the legitimate claude agent CLI process (behavioral smoke test)"
    else
      fail "watcher logged a SIGTERM target that matched none of the expected pids -- inspect ${WATCHER_LOG}"
    fi
  else
    fail "watcher never reached the DRY_RUN action line across 2 consecutive CRIT polls -- expected 'would send SIGTERM' in ${WATCHER_LOG}"
  fi
fi

# ── 2b. ezgha.service.d/10-oomd-omit.conf -- exists, correct directive,
#        and parses via systemd-analyze verify when paired with a stub
#        base unit (a bare drop-in fragment can't be verified standalone
#        -- systemd-analyze verify requires a full unit file path). ──────
OOMD_OMIT="${REPO_ROOT}/systemd/ezgha.service.d/10-oomd-omit.conf"
if [ ! -f "${OOMD_OMIT}" ]; then
  fail "systemd/ezgha.service.d/10-oomd-omit.conf does not exist -- REGRESSION: without this per-unit systemd-oomd exemption, tuning system-scope oomd thresholds (docs/host-ops-sudo-block-0725.md Option A) makes the Colima VM (which lives inside ezgha.service's own cgroup) a live SIGKILL candidate"
else
  if grep -q '^ManagedOOMPreference=omit$' "${OOMD_OMIT}"; then
    ok "systemd/ezgha.service.d/10-oomd-omit.conf sets ManagedOOMPreference=omit"
  else
    fail "systemd/ezgha.service.d/10-oomd-omit.conf is missing 'ManagedOOMPreference=omit'"
  fi

  if [ "${HAVE_SYSTEMD_ANALYZE}" -eq 1 ]; then
    PAIR_DIR="${WORK}/oomd-omit-pair"
    mkdir -p "${PAIR_DIR}/ezgha.service.d"
    cat > "${PAIR_DIR}/ezgha.service" <<'EOF'
[Unit]
Description=stub ezgha (test fixture, not the real unit)
[Service]
ExecStart=/bin/true
EOF
    cp "${OOMD_OMIT}" "${PAIR_DIR}/ezgha.service.d/"
    if systemd-analyze verify --user "${PAIR_DIR}/ezgha.service" >"${WORK}/oomd-omit-verify.log" 2>&1; then
      ok "systemd/ezgha.service.d/10-oomd-omit.conf passes systemd-analyze verify --user (paired with stub base unit)"
    else
      fail "systemd/ezgha.service.d/10-oomd-omit.conf failed systemd-analyze verify --user: $(cat "${WORK}/oomd-omit-verify.log")"
    fi
  else
    if grep -q '^\[Service\]' "${OOMD_OMIT}"; then
      ok "systemd/ezgha.service.d/10-oomd-omit.conf structural check (systemd-analyze unavailable): has [Service] section"
    else
      fail "systemd/ezgha.service.d/10-oomd-omit.conf missing [Service] section"
    fi
  fi
fi

# ── 3. agent-cli-scoped.sh syntax ───────────────────────────────────────────
WRAPPER="${REPO_ROOT}/scripts/host/agent-cli-scoped.sh"
if [ ! -f "${WRAPPER}" ]; then
  fail "scripts/host/agent-cli-scoped.sh does not exist"
else
  if bash -n "${WRAPPER}" 2>"${WORK}/wrapper-syntax.log"; then
    ok "scripts/host/agent-cli-scoped.sh passes bash -n"
  else
    fail "scripts/host/agent-cli-scoped.sh failed bash -n: $(cat "${WORK}/wrapper-syntax.log")"
  fi
fi

# ── 4. psi-oom-watcher.service syntax (after placeholder substitution) ─────
SERVICE_SRC="${REPO_ROOT}/systemd/psi-oom-watcher.service"
if [ ! -f "${SERVICE_SRC}" ]; then
  fail "systemd/psi-oom-watcher.service does not exist"
else
  FAKE_SCRIPTS_DIR="${WORK}/libexec"
  mkdir -p "${FAKE_SCRIPTS_DIR}"
  printf '#!/usr/bin/env bash\ntrue\n' > "${FAKE_SCRIPTS_DIR}/psi-oom-watcher.sh"
  chmod +x "${FAKE_SCRIPTS_DIR}/psi-oom-watcher.sh"
  FAKE_HOME="${WORK}/home"
  mkdir -p "${FAKE_HOME}/.local/state/ezgha"

  RENDERED_SERVICE="${WORK}/psi-oom-watcher.service"
  sed -e "s|@SCRIPTS_DIR@|${FAKE_SCRIPTS_DIR}|g" \
      -e "s|@HOME@|${FAKE_HOME}|g" \
      "${SERVICE_SRC}" > "${RENDERED_SERVICE}"

  if grep -q '@[A-Z_]*@' "${RENDERED_SERVICE}"; then
    fail "systemd/psi-oom-watcher.service has an unsubstituted @PLACEHOLDER@ after rendering"
  else
    ok "systemd/psi-oom-watcher.service has no unsubstituted placeholders after rendering"
  fi

  if [ "${HAVE_SYSTEMD_ANALYZE}" -eq 1 ]; then
    if systemd-analyze verify --user "${RENDERED_SERVICE}" >"${WORK}/service-verify.log" 2>&1; then
      ok "systemd/psi-oom-watcher.service passes systemd-analyze verify --user (rendered)"
    else
      fail "systemd/psi-oom-watcher.service failed systemd-analyze verify --user (rendered): $(cat "${WORK}/service-verify.log")"
    fi
  else
    if grep -q '^\[Service\]' "${RENDERED_SERVICE}" && grep -q '^ExecStart=' "${RENDERED_SERVICE}"; then
      ok "systemd/psi-oom-watcher.service structural check (systemd-analyze unavailable): has [Service] + ExecStart="
    else
      fail "systemd/psi-oom-watcher.service missing [Service] section or ExecStart= directive"
    fi
  fi
fi

# ── 5. psi-oom-watcher.timer syntax + Unit= reference correctness ──────────
TIMER="${REPO_ROOT}/systemd/psi-oom-watcher.timer"
if [ ! -f "${TIMER}" ]; then
  fail "systemd/psi-oom-watcher.timer does not exist"
else
  if [ "${HAVE_SYSTEMD_ANALYZE}" -eq 1 ]; then
    if systemd-analyze verify --user "${TIMER}" >"${WORK}/timer-verify.log" 2>&1; then
      ok "systemd/psi-oom-watcher.timer passes systemd-analyze verify --user"
    else
      fail "systemd/psi-oom-watcher.timer failed systemd-analyze verify --user: $(cat "${WORK}/timer-verify.log")"
    fi
  else
    if grep -q '^\[Timer\]' "${TIMER}"; then
      ok "systemd/psi-oom-watcher.timer structural check (systemd-analyze unavailable): has [Timer] section"
    else
      fail "systemd/psi-oom-watcher.timer missing [Timer] section"
    fi
  fi

  if grep -q '^Unit=psi-oom-watcher\.service$' "${TIMER}"; then
    ok "systemd/psi-oom-watcher.timer Unit= correctly references psi-oom-watcher.service"
  else
    fail "systemd/psi-oom-watcher.timer Unit= does not reference psi-oom-watcher.service (wrong service name or missing directive)"
  fi

  # Poll interval must be inside the mandated 10-30s range (bead spec).
  interval_line="$(grep '^OnUnitActiveSec=' "${TIMER}" || true)"
  interval_sec="$(printf '%s' "${interval_line}" | sed -n 's/^OnUnitActiveSec=\([0-9]*\)s$/\1/p')"
  if [ -n "${interval_sec}" ] && [ "${interval_sec}" -ge 10 ] && [ "${interval_sec}" -le 30 ]; then
    ok "systemd/psi-oom-watcher.timer OnUnitActiveSec=${interval_sec}s is within the mandated 10-30s range"
  else
    fail "systemd/psi-oom-watcher.timer OnUnitActiveSec is missing or outside the mandated 10-30s range (found: '${interval_line}')"
  fi
fi

if [ "${PASS}" = true ]; then
  echo "ALL PASS"
  exit 0
else
  echo "ONE OR MORE ASSERTIONS FAILED" >&2
  exit 1
fi
