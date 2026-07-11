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

# Portability fix (fourth adversarial re-verification pass, 2026-07-10):
# the original version of this test only fell back to a structural
# (grep-based) check when systemd-analyze was ENTIRELY MISSING from PATH.
# But `systemd-analyze verify --user` can also fail for purely
# environmental reasons -- e.g. no live user D-Bus/systemd session, common
# in containers/CI -- with errors like "Failed to connect to bus" or
# "Failed to lookup RuntimeDirectory path", which is NOT a unit-file
# defect. The original test treated that the same as a genuine syntax
# error and hard-failed, even though a structural fallback path already
# existed for the "binary missing" case. looks_like_infra_failure()
# distinguishes the two so this test stays portable without papering over
# real syntax errors.
looks_like_infra_failure() {
  grep -qiE 'failed to (connect to bus|lookup .*runtimedirectory|create bus connection|get (d-)?bus connection)|no such file or directory.*(bus|runtime)|system has not been booted with systemd|failed to create.*d-bus|could not connect to bus' "$1"
}

# verify_unit LABEL UNIT_PATH FALLBACK_FN
# Tries `systemd-analyze verify --user` first (if the binary exists). On a
# genuine failure it hard-fails via fail(). On an infra/environment
# failure, OR when systemd-analyze isn't installed at all, it calls
# FALLBACK_FN (a shell function name) to run a structural grep-based check
# instead.
verify_unit() {
  local label="$1" unit_path="$2" fallback_fn="$3"
  local logfile="${WORK}/verify-log-${RANDOM}-${RANDOM}"
  if [ "${HAVE_SYSTEMD_ANALYZE}" -eq 1 ]; then
    if systemd-analyze verify --user "${unit_path}" >"${logfile}" 2>&1; then
      ok "${label} passes systemd-analyze verify --user"
      return 0
    fi
    if looks_like_infra_failure "${logfile}"; then
      echo "INFO: ${label}: systemd-analyze verify --user failed due to environment (no live user systemd session -- expected in containers/CI), falling back to structural check" >&2
    else
      fail "${label} failed systemd-analyze verify --user: $(cat "${logfile}")"
      return 1
    fi
  fi
  "${fallback_fn}"
}

# ── 1. agents.slice syntax ──────────────────────────────────────────────────
SLICE="${REPO_ROOT}/systemd/agents.slice"
if [ ! -f "${SLICE}" ]; then
  fail "systemd/agents.slice does not exist"
else
  slice_structural_check() {
    if grep -q '^\[Slice\]' "${SLICE}" && grep -q '^MemoryHigh=' "${SLICE}"; then
      ok "systemd/agents.slice structural check: has [Slice] + MemoryHigh="
    else
      fail "systemd/agents.slice missing [Slice] section or MemoryHigh= directive"
    fi
  }
  verify_unit "systemd/agents.slice" "${SLICE}" slice_structural_check
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

  # DRY_RUN state-poisoning regression guard (third adversarial
  # re-verification pass, 2026-07-10): a DRY_RUN rehearsal must NEVER write
  # the cooldown marker -- doing so would silently disable REAL protection
  # for the full 10-minute cooldown window right when a human is most
  # likely to be running a rehearsal (during an actual incident). The two
  # DRY_RUN polls above already crossed CRIT_CONSECUTIVE and hit the
  # action-log line, so if the bug were present, COOLDOWN_MARKER would
  # exist by now.
  COOLDOWN_MARKER_PATH="${STATE_DIR}/psi-oom-watcher.last-action"
  if [ -f "${COOLDOWN_MARKER_PATH}" ]; then
    fail "REGRESSION: DRY_RUN wrote the cooldown marker (${COOLDOWN_MARKER_PATH}) -- a rehearsal during a real incident would silently suppress the watcher's real SIGTERM protection for the full cooldown window"
  else
    ok "DRY_RUN correctly did not write the cooldown marker -- real protection stays fully armed after a rehearsal"
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

  if grep -q '^OOMScoreAdjust=-1000$' "${OOMD_OMIT}"; then
    ok "systemd/ezgha.service.d/10-oomd-omit.conf sets OOMScoreAdjust=-1000 (kernel-level protection, covers the swap-path gap ManagedOOMPreference=omit cannot)"
  else
    fail "systemd/ezgha.service.d/10-oomd-omit.conf is missing 'OOMScoreAdjust=-1000' -- REGRESSION: this is the mechanism that protects Colima from earlyoom's default victim selection and the raw kernel OOM killer, verified via man systemd.exec ('-1000: to disable OOM killing of processes of this unit')"
  fi

  PAIR_DIR="${WORK}/oomd-omit-pair"
  mkdir -p "${PAIR_DIR}/ezgha.service.d"
  cat > "${PAIR_DIR}/ezgha.service" <<'EOF'
[Unit]
Description=stub ezgha (test fixture, not the real unit)
[Service]
ExecStart=/bin/true
EOF
  cp "${OOMD_OMIT}" "${PAIR_DIR}/ezgha.service.d/"
  oomd_omit_structural_check() {
    if grep -q '^\[Service\]' "${OOMD_OMIT}"; then
      ok "systemd/ezgha.service.d/10-oomd-omit.conf structural check: has [Service] section"
    else
      fail "systemd/ezgha.service.d/10-oomd-omit.conf missing [Service] section"
    fi
  }
  verify_unit "systemd/ezgha.service.d/10-oomd-omit.conf (paired with stub base unit)" "${PAIR_DIR}/ezgha.service" oomd_omit_structural_check

  # Swap-path scope-boundary regression guard (second adversarial
  # re-verification pass, 2026-07-10): per `man systemd.resource-control`,
  # ManagedOOMPreference=omit is honored on the memory-PRESSURE kill path
  # for a same-owner unit like ezgha.service, but NOT on the swap-usage
  # kill path (root-owned-only, no same-owner exception). This drop-in
  # therefore must NEVER set ManagedOOMSwap or SwapUsedLimit -- doing so
  # would claim/imply swap-path protection this mechanism cannot actually
  # provide. This assertion exists so a future edit can't silently
  # reintroduce that false-protection claim.
  if grep -qE '^(ManagedOOMSwap|SwapUsedLimit)=' "${OOMD_OMIT}"; then
    fail "systemd/ezgha.service.d/10-oomd-omit.conf sets ManagedOOMSwap or SwapUsedLimit -- REGRESSION: the omit exemption does NOT cover the swap-usage kill path (root-owned-only per man systemd.resource-control, no same-owner exception), so this would silently imply swap-path protection that doesn't exist"
  else
    ok "systemd/ezgha.service.d/10-oomd-omit.conf correctly does not set ManagedOOMSwap/SwapUsedLimit (swap-path scope boundary respected)"
  fi
fi

# ── 2c. docs/host-ops-sudo-block-0725.md -- Option A's actual command
#        blocks must not tighten the swap-usage kill path (same
#        scope-boundary regression guard, applied to the doc's code
#        fences specifically, not just prose that explains the boundary
#        -- prose legitimately mentions SwapUsedLimit/ManagedOOMSwap to
#        explain why they're absent, so this check targets the heredoc
#        bodies between `<<'EOF'` and `EOF` inside the Option A section
#        only). ──────────────────────────────────────────────────────────
SUDO_DOC="${REPO_ROOT}/docs/host-ops-sudo-block-0725.md"
if [ ! -f "${SUDO_DOC}" ]; then
  fail "docs/host-ops-sudo-block-0725.md does not exist"
else
  # Extract lines between "### Option A" and the next "### " heading, then
  # within that, only the heredoc BODY lines (between <<'EOF' and EOF) --
  # i.e. what would actually be written to disk if the operator copy-pastes
  # the block, not the surrounding explanatory comments.
  awk '/^### Option A/{flag=1} /^### Option B/{flag=0} flag' "${SUDO_DOC}" \
    | awk '/<<.EOF./{heredoc=1; next} /^EOF$/{heredoc=0; next} heredoc' \
    > "${WORK}/option-a-heredoc-bodies.txt"
  if grep -qE '^(ManagedOOMSwap|SwapUsedLimit)=' "${WORK}/option-a-heredoc-bodies.txt"; then
    fail "docs/host-ops-sudo-block-0725.md Option A's actual command block (heredoc body, not prose) sets ManagedOOMSwap or SwapUsedLimit -- REGRESSION: this reintroduces the swap-path exposure this doc was corrected to remove (see 'swap-path scope boundary' finding in the same doc)"
  else
    ok "docs/host-ops-sudo-block-0725.md Option A's command block does not set ManagedOOMSwap/SwapUsedLimit (swap-path scope boundary respected in the actual copy-pasteable commands)"
  fi

  # ── 2d. earlyoom (Option B) regression guards, third adversarial
  #        re-verification pass, 2026-07-10 ──────────────────────────────
  # Extract Option B's EARLYOOM_ARGS heredoc body specifically (same
  # technique as Option A above): between "### Option B" and the next
  # "### " heading (or EOF-of-doc), only the <<'EOF' ... EOF heredoc body.
  awk '/^### Option B/{flag=1} /^---/{flag=0} flag' "${SUDO_DOC}" \
    | awk '/<<.EOF./{heredoc=1; next} /^EOF$/{heredoc=0; next} heredoc' \
    > "${WORK}/option-b-heredoc-bodies.txt"

  # (a) Truncation bug: earlyoom matches against the kernel's comm field,
  # which truncates at 15 bytes -- "qemu-system-x86_64" (18 bytes) can
  # never appear in a live comm value, only the truncated "qemu-system-x86"
  # (15 bytes) can. Check the ACTUAL EARLYOOM_ARGS= directive line
  # specifically (not the whole heredoc body, which also legitimately
  # contains explanatory '#' comment lines that mention the untruncated
  # form for documentation purposes -- those are fine, only the live
  # directive matters for whether the regex actually works).
  earlyoom_args_line="$(grep '^EARLYOOM_ARGS=' "${WORK}/option-b-heredoc-bodies.txt" || true)"
  if [ -z "${earlyoom_args_line}" ]; then
    fail "docs/host-ops-sudo-block-0725.md Option B's heredoc body has no EARLYOOM_ARGS= line -- expected the earlyoom config directive to be present"
  elif printf '%s' "${earlyoom_args_line}" | grep -qF 'qemu-system-x86_64'; then
    fail "docs/host-ops-sudo-block-0725.md Option B's EARLYOOM_ARGS= directive still contains the untruncated 'qemu-system-x86_64' -- REGRESSION: earlyoom matches against the kernel comm field (15-byte truncated), so this pattern can never match the live qemu process and provides zero protection. Line: ${earlyoom_args_line}"
  elif printf '%s' "${earlyoom_args_line}" | grep -qF 'qemu-system-x86'; then
    ok "docs/host-ops-sudo-block-0725.md Option B's EARLYOOM_ARGS= directive uses the correctly-truncated 'qemu-system-x86' (not the untruncated _64 form)"
  else
    fail "docs/host-ops-sudo-block-0725.md Option B's EARLYOOM_ARGS= directive does not reference qemu-system-x86 at all -- expected the truncated pattern to be present. Line: ${earlyoom_args_line}"
  fi

  # (b) Semantics: --avoid must not be described as a hard/guaranteed
  # exclusion anywhere in the doc (verified against the real earlyoom
  # 1.7-2 man page: it's a soft -300 oom_score adjustment, and there is no
  # --ignore hard-exclusion flag in that version at all).
  if grep -qi 'NEVER kill' "${SUDO_DOC}"; then
    fail "docs/host-ops-sudo-block-0725.md still describes --avoid (or similar) as a mechanism that will 'NEVER kill' a process -- REGRESSION: verified against the real earlyoom 1.7-2 man page, --avoid is a soft -300 oom_score preference, not a guarantee; this phrasing overclaims protection that doesn't exist"
  else
    ok "docs/host-ops-sudo-block-0725.md does not overclaim --avoid as a hard exclusion ('NEVER kill' phrasing absent)"
  fi
  if grep -q 'subtracts 300 from oom_score\|SOFT preference' "${SUDO_DOC}"; then
    ok "docs/host-ops-sudo-block-0725.md accurately describes --avoid as a soft oom_score preference"
  else
    fail "docs/host-ops-sudo-block-0725.md is missing the accurate soft-preference description of --avoid (subtracts 300 from oom_score, per the real earlyoom 1.7-2 man page)"
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

  service_structural_check() {
    if grep -q '^\[Service\]' "${RENDERED_SERVICE}" && grep -q '^ExecStart=' "${RENDERED_SERVICE}"; then
      ok "systemd/psi-oom-watcher.service structural check: has [Service] + ExecStart="
    else
      fail "systemd/psi-oom-watcher.service missing [Service] section or ExecStart= directive"
    fi
  }
  verify_unit "systemd/psi-oom-watcher.service (rendered)" "${RENDERED_SERVICE}" service_structural_check
fi

# ── 5. psi-oom-watcher.timer syntax + Unit= reference correctness ──────────
TIMER="${REPO_ROOT}/systemd/psi-oom-watcher.timer"
if [ ! -f "${TIMER}" ]; then
  fail "systemd/psi-oom-watcher.timer does not exist"
else
  timer_structural_check() {
    if grep -q '^\[Timer\]' "${TIMER}"; then
      ok "systemd/psi-oom-watcher.timer structural check: has [Timer] section"
    else
      fail "systemd/psi-oom-watcher.timer missing [Timer] section"
    fi
  }
  verify_unit "systemd/psi-oom-watcher.timer" "${TIMER}" timer_structural_check

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
