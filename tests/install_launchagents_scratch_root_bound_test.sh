#!/usr/bin/env bash
# Hermetic proof that launchd/install-launchagents.sh BOUNDS its install-time
# `diskm scratch-dir` call (bead jleechan-52fr). `diskm` is a uv-tool python
# program that answers in ~3-4s interactively but has been measured spinning
# indefinitely; with no bound, one hung resolution stalls an entire interactive
# ./install.sh. macOS ships no timeout(1), so the installer bounds the call
# itself and falls through to its existing fail-closed skip path.
#
# Cases (all with a fake diskm on PATH — no real diskm, no real launchctl):
#   (a) answers fast        -> the reaper unit installs with the resolved root
#   (b) hangs past the bound-> killed, install continues WITHOUT the reaper unit
#   (c) exits non-zero      -> same fail-closed path as (b)
#   (d) targeted install with an unresolvable root -> still fails loudly (exit 2)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${REPO_ROOT}/launchd/install-launchagents.sh"
REAPER_LABEL="org.jleechanorg.ezgha-ios-release-cleanup"
COMPANION_LABEL="org.jleechanorg.ezgha-colima-trim"
# Guard on the installer as a whole, deliberately independent of the installer's
# own diskm bound: if the bound regresses, this test FAILS after the deadline
# instead of hanging the suite forever.
INSTALL_DEADLINE_SECONDS=60

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
HOME_T="${WORK}/home"
mkdir -p "${HOME_T}/Library/LaunchAgents"
export LAUNCHCTL_LOG="${WORK}/launchctl.log"
export LAUNCHCTL_STATE="${WORK}/launchctl-loaded.txt"
: > "${LAUNCHCTL_LOG}"
: > "${LAUNCHCTL_STATE}"

REAPER_PLIST="${HOME_T}/Library/LaunchAgents/${REAPER_LABEL}.plist"
COMPANION_PLIST="${HOME_T}/Library/LaunchAgents/${COMPANION_LABEL}.plist"

fail() {
  echo "FAIL: $*" >&2
  echo "--- installer log (${LOG:-none}) ---" >&2
  [[ -z "${LOG:-}" || ! -f "${LOG}" ]] || cat "${LOG}" >&2
  exit 1
}

# launchctl stub in every PATH variant: records invocations and keeps a tiny
# loaded-label state so `print` reports registration truthfully — the installer
# verifies a load registered the label and verifies a stop actually stopped it.
for variant in fast hang fail; do
  mkdir -p "${WORK}/bin-${variant}"
  cat > "${WORK}/bin-${variant}/launchctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${LAUNCHCTL_LOG:?}"
state="${LAUNCHCTL_STATE:?}"
cmd="${1:-}"
shift || true
last=""
for arg in "$@"; do last="${arg}"; done
label="${last##*/}"
label="${label%.plist}"
drop_label() {
  grep -vx "${label}" "${state}" > "${state}.tmp" 2>/dev/null || : > "${state}.tmp"
  mv "${state}.tmp" "${state}"
}
match_label() {
  grep -qx "${label}" "${state}" 2>/dev/null
}
case "${cmd}" in
  load) printf '%s\n' "${label}" >> "${state}"; exit 0 ;;
  unload|bootout) drop_label; exit 0 ;;
  print) match_label && exit 0; exit 1 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "${WORK}/bin-${variant}/launchctl"
done

# (a) answers fast; trailing slash proves the resolved root is normalized.
cat > "${WORK}/bin-fast/diskm" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "scratch-dir" ]] || exit 2
: > "${DISKM_MARKER:?}"
printf '/Volumes/ezgha-test-scratch/\n'
EOF
# (b) never answers: the bound must kill this and move on.
cat > "${WORK}/bin-hang/diskm" <<'EOF'
#!/usr/bin/env bash
: > "${DISKM_MARKER:?}"
exec sleep 3600
EOF
# (c) fails: no root, same fail-closed outcome as (b).
cat > "${WORK}/bin-fail/diskm" <<'EOF'
#!/usr/bin/env bash
: > "${DISKM_MARKER:?}"
echo "diskm: scratch volume not provisioned" >&2
exit 3
EOF
chmod +x "${WORK}"/bin-*/diskm

# Runs the real installer under a temp HOME with one disconnected fake diskm on
# PATH. Sets INSTALL_RC to the installer's exit status; returns non-zero (and
# kills the installer) if it overruns INSTALL_DEADLINE_SECONDS.
run_installer() {
  local variant="$1"
  local label="${2:-}"
  local pid elapsed=0
  LOG="${WORK}/${variant}${label:+-targeted}.log"
  DISKM_MARKER="${WORK}/${variant}${label:+-targeted}.marker"
  rm -f "${DISKM_MARKER}"
  # `env -u BASH_ENV`: a developer shell that exports BASH_ENV would source its
  # own rc file under this PATH and re-prepend the real ~/.local/bin, so the
  # fake diskm would never be reached. The case under test is the installer's
  # bound, nothing else.
  if [[ -n "${label}" ]]; then
    env -u BASH_ENV HOME="${HOME_T}" PATH="${WORK}/bin-${variant}:/usr/bin:/bin" \
      DISKM_MARKER="${DISKM_MARKER}" LAUNCHCTL_LOG="${LAUNCHCTL_LOG}" \
      LAUNCHCTL_STATE="${LAUNCHCTL_STATE}" \
      bash "${INSTALLER}" install "${label}" >"${LOG}" 2>&1 &
  else
    env -u BASH_ENV HOME="${HOME_T}" PATH="${WORK}/bin-${variant}:/usr/bin:/bin" \
      DISKM_MARKER="${DISKM_MARKER}" LAUNCHCTL_LOG="${LAUNCHCTL_LOG}" \
      LAUNCHCTL_STATE="${LAUNCHCTL_STATE}" \
      bash "${INSTALLER}" install >"${LOG}" 2>&1 &
  fi
  pid=$!
  while kill -0 "${pid}" 2>/dev/null; do
    if [[ "${elapsed}" -ge "${INSTALL_DEADLINE_SECONDS}" ]]; then
      kill -KILL "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
      fail "install-launchagents.sh was still running after ${INSTALL_DEADLINE_SECONDS}s — the diskm scratch-dir call is unbounded"
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  INSTALL_RC=0
  wait "${pid}" || INSTALL_RC=$?
  return 0
}

started_at="$(date +%s)"

# ── (a) fast resolver: the reaper unit installs, root substituted ────────────
run_installer fast
[[ "${INSTALL_RC}" -eq 0 ]] || fail "fast diskm: installer exited ${INSTALL_RC}, expected 0"
[[ -f "${DISKM_MARKER}" ]] || fail "the fast-path fake diskm was never invoked"
[[ -f "${REAPER_PLIST}" ]] || fail "resolved Scratch root did not install ${REAPER_LABEL}"
grep -Fq '<string>/Volumes/ezgha-test-scratch</string>' "${REAPER_PLIST}" \
  || fail "reaper plist does not carry the resolved (slash-normalized) Scratch root"
! grep -q '@SCRATCH_ROOT@' "${REAPER_PLIST}" || fail "reaper plist kept an unsubstituted @SCRATCH_ROOT@"
[[ -f "${COMPANION_PLIST}" ]] || fail "bulk install skipped an unrelated unit"

# ── (b) hanging resolver: bounded, install continues without the reaper ──────
# A copy is installed above, so this also proves the fail-closed path still
# stops a unit whose target this host can no longer resolve.
run_installer hang
[[ "${INSTALL_RC}" -eq 0 ]] || fail "hanging diskm: installer exited ${INSTALL_RC}, expected 0 (install must continue)"
[[ -f "${DISKM_MARKER}" ]] || fail "the hanging fake diskm was never invoked — the run did not exercise the bound"
[[ ! -e "${REAPER_PLIST}" ]] || fail "a unit with no resolvable Scratch root was left installed"
[[ -f "${COMPANION_PLIST}" ]] || fail "bulk install did not continue past the hung resolver"
grep -q 'could not resolve this host.s Scratch root' "${LOG}" \
  || fail "hanging diskm did not produce the existing unresolved-root warning"

# ── (c) failing resolver: same fail-closed path, no hang ─────────────────────
run_installer fail
[[ "${INSTALL_RC}" -eq 0 ]] || fail "failing diskm: installer exited ${INSTALL_RC}, expected 0 (install must continue)"
[[ -f "${DISKM_MARKER}" ]] || fail "the failing fake diskm was never invoked"
[[ ! -e "${REAPER_PLIST}" ]] || fail "a unit with an unresolvable Scratch root was installed"
[[ -f "${COMPANION_PLIST}" ]] || fail "bulk install did not continue past the failing resolver"

# ── (d) targeted install of that label still fails loudly ───────────────────
run_installer fail "${REAPER_LABEL}"
[[ "${INSTALL_RC}" -eq 2 ]] || fail "targeted install with no resolvable root exited ${INSTALL_RC}, expected 2"
grep -q 'refusing to install a unit with no target' "${LOG}" \
  || fail "targeted install did not fail loudly on an unresolvable Scratch root"
[[ ! -e "${REAPER_PLIST}" ]] || fail "targeted install wrote a plist anyway"

# Regression bound: the whole suite — hanging stub included — finishes well
# inside a wall-clock budget rather than stalling like the bug did.
suite_elapsed=$(( $(date +%s) - started_at ))
[[ "${suite_elapsed}" -le 300 ]] \
  || fail "suite took ${suite_elapsed}s with the hanging stub; expected a bounded run"

echo "ALL PASS (suite wall clock: ${suite_elapsed}s; installer bound enforced on the hanging stub)"
