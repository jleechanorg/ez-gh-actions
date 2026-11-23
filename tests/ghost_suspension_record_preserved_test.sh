#!/usr/bin/env bash
# tests/ghost_suspension_record_preserved_test.sh
#
# A ported and expanded version of the reviewer's regression requirement:
#   declared installation -> reinstall WITHOUT the env var -> declaration RETAINED
#
# Why this matters (code-standards / advice review): both installers regenerate the
# queue-agent plists. If a routine ./install.sh (or a fresh-checkout reinstall) ran
# without EZGHA_SUSPENSION_RECORD exported and simply emitted an empty value, it
# would silently revert an acknowledged ghost set to fail-closed and the cleaners
# would go permanently red again. Precedence must be:
#   1. EZGHA_SUSPENSION_RECORD explicitly set (including explicitly empty) -> declare it
#   2. otherwise, carry over the value already present in the installed plist
#   3. otherwise, an explicit empty declaration (fail-closed, safe default)
#
# Usage: bash tests/ghost_suspension_record_preserved_test.sh
set -euo pipefail
unset BASH_ENV || true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILS=$((FAILS+1)); }

PLIST="$WORK/probe.plist"

# Render install.sh's env_xml block against a given plist + env, then read back.
render() { # $1 = plist path ; env: EZGHA_SUSPENSION_RECORD (may be unset)
  local plist="$1"
  # Model install.sh exactly: capture the prior declaration, THEN truncate.
  local prior_record=""
  if [ -f "$plist" ]; then prior_record="$(plist_record_of "$plist")"; fi
  cat > "$plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>probe</string>
P
  ( name="queue-trimmer"; plist="$plist"; prior_record="$prior_record"; \
    DOCKER_HOST_OVERRIDE=""; source "$WORK/helpers.sh"; source "$WORK/block.sh" ) || true
  echo '</dict></plist>' >> "$plist"
}

read_record() { # prints the record, or <ABSENT>
  # PORTABLE: /usr/libexec/PlistBuddy is macOS-only, but this test is wired into
  # `ubuntu-latest` CI. Use python3 plistlib (stdlib, cross-platform) instead.
  python3 - "$1" <<'PYEOF'
import plistlib, sys
try:
    with open(sys.argv[1], 'rb') as fh:
        d = plistlib.load(fh)
except Exception:
    print('<ABSENT>')
    raise SystemExit
env = d.get('EnvironmentVariables') or {}
print(env['EZGHA_SUSPENSION_RECORD'] if 'EZGHA_SUSPENSION_RECORD' in env else '<ABSENT>')
PYEOF
}

# ---- extract the real block + helper from install.sh ----------------------
python3 - "$REPO_ROOT/install.sh" "$WORK/block.sh" "$WORK/helpers.sh" <<'PY'
import sys
src = open(sys.argv[1]).read()
# the env_xml computation + emit
start = src.index('      local env_xml=""')
end   = src.index('\n      fi\n      cat >> "${plist}" <<PLIST\n  <key>StartInterval</key>', start)
block = src[start:end + len('\n      fi')]
open(sys.argv[2], "w").write("\n".join(l[4:] if l.startswith("    ") else l for l in block.splitlines()) + "\n")
# the plist_record_of helper. NOTE: de-indent by 4 ONLY lines that start with
# 4+ spaces; a python heredoc body inside it is indented differently and must be
# preserved verbatim, or the extracted helper is syntactically broken.
# Extract helper functions by BRACE MATCHING, not by "first closing brace".
# A naive `src.index("\n    }\n")` finds the wrong brace because xml_esc() is
# itself a nested function inside the Darwin branch (review-driven fix).
xs = src.index('    xml_esc() {')
def _fn_end(s, open_idx):
    depth = 0
    for i in range(open_idx, len(s)):
        if s[i] == '{':
            depth += 1
        elif s[i] == '}':
            depth -= 1
            if depth == 0:
                return i + 1
    raise AssertionError("unbalanced braces")
xe = _fn_end(src, xs)
xml_esc_src = "\n".join(l[4:] if l.startswith("    ") else l for l in src[xs:xe].splitlines()) + "\n"

hs = src.index('    plist_record_of() {')
he = _fn_end(src, hs)
lines = src[hs:he].splitlines()
out, in_py = [], False
for l in lines:
    if "<<'PYPLIST'" in l:
        in_py = True
    if in_py:
        out.append(l[4:] if l.startswith("    " * 2) else l)
    else:
        out.append(l[4:] if l.startswith("    ") else l)
    if l.strip() == "PYPLIST":
        in_py = False
open(sys.argv[3], "w").write(xml_esc_src + "\n".join(out) + "\n")
PY
# shellcheck disable=SC1090
source "$WORK/helpers.sh"

# ---- 1. fresh install WITH a declaration ---------------------------------
export EZGHA_SUSPENSION_RECORD="bead-alpha"
render "$PLIST"
r="$(read_record "$PLIST")"
[ "$r" = "bead-alpha" ] && pass "1 fresh install declares bead-alpha" \
                        || fail "1 expected bead-alpha, got '$r'"

# ---- 2. reinstall WITHOUT the var: must PRESERVE bead-alpha --------------
unset EZGHA_SUSPENSION_RECORD
render "$PLIST"
r="$(read_record "$PLIST")"
[ "$r" = "bead-alpha" ] && pass "2 reinstall without env var PRESERVES the declaration" \
                        || fail "2 reinstall cleared/overwrote the declaration (got '$r') — this is the P0"

# ---- 3. reinstall with an EXPLICIT empty value clears it -----------------
EZGHA_SUSPENSION_RECORD=""
render "$PLIST"
r="$(read_record "$PLIST")"
[ -z "$r" ] && pass "3 explicit empty clears the declaration (operator intent honoured)" \
            || fail "3 explicit empty did not clear (got '$r')"

# ---- 4. reinstall without var after a clear stays empty (fail-closed) ----
unset EZGHA_SUSPENSION_RECORD
render "$PLIST"
r="$(read_record "$PLIST")"
[ -z "$r" ] && pass "4 stays empty => fail-closed preserved" \
            || fail "4 unexpectedly repopulated (got '$r')"

# ---- 5. fresh install with NO prior plist and NO var => explicit empty ---
rm -f "$PLIST"
render "$PLIST"
r="$(read_record "$PLIST")"
[ -z "$r" ] && pass "5 fresh install without prior state declares empty (not absent)" \
            || fail "5 expected explicit empty, got '$r'"

# ---- 5b. XML-SPECIAL characters must survive round-trip (review P0) ------
# An unescaped & or < produces an INVALID plist; install.sh unloads the prior
# agent before writing, so a bad value can leave a cleaner UNLOADED.
TRICKY='a&b<c>d"e'
export EZGHA_SUSPENSION_RECORD="$TRICKY"
render "$PLIST"
# PORTABLE: plutil is macOS-only. On Linux, validate with python3 plistlib,
# which is what actually detects the unescaped-& failure.
if python3 -c "import plistlib,sys; plistlib.load(open(sys.argv[1],'rb'))" "$PLIST" 2>/dev/null; then
  pass "5b plist with XML-special characters parses cleanly"
else
  fail "5b plist with XML-special characters is INVALID (unescaped record)"
fi
r="$(read_record "$PLIST")"
[ "$r" = "$TRICKY" ] && pass "5b XML-special value round-trips exactly" \
                     || fail "5b round-trip changed the value (got '$r')"

# ---- 5c. ...and preservation of that tricky value across a reinstall -----
unset EZGHA_SUSPENSION_RECORD
render "$PLIST"
r="$(read_record "$PLIST")"
[ "$r" = "$TRICKY" ] && pass "5c XML-special value PRESERVED across reinstall" \
                     || fail "5c preservation mangled the XML-special value (got '$r')"

# ---- 6. the template installer has the same precedence -------------------
T="launchd/install-launchagents.sh"
if grep -q 'GHOST_REC="${EZGHA_SUSPENSION_RECORD-__UNSET__}"' "$T"; then
  pass "6a template installer distinguishes unset from empty"
else
  fail "6a template installer does not distinguish unset from empty"
fi
if grep -q 'EnvironmentVariables:EZGHA_SUSPENSION_RECORD' "$T"; then
  pass "6b template installer reads back the installed declaration"
else
  fail "6b template installer does not preserve an existing declaration"
fi

echo
if [ "$FAILS" -ne 0 ]; then
  echo "FAILED: $FAILS assertion(s)" >&2
  exit 1
fi
echo "ALL TESTS PASSED!"

# ---- 7. the actual launchd installer preserves/clears both queue agents --
# This exercises launchd/install-launchagents.sh itself in an isolated HOME.
# launchctl is a PATH-first fake, so no host service state is read or changed.
FAKE_HOME="$WORK/fake-home"
FAKE_BIN="$WORK/fake-bin"
LAUNCHCTL_LOG="$WORK/fake-launchctl.log"
mkdir -p "$FAKE_HOME/Library/LaunchAgents" "$FAKE_BIN"
cat > "$FAKE_BIN/launchctl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "${LAUNCHCTL_LOG:?}"
exit 0
SH
chmod 0755 "$FAKE_BIN/launchctl"
INSTALL_PATH="$FAKE_BIN:$PATH"
TRIM_LABEL="org.jleechanorg.ezgha-queue-trimmer"
REAPER_LABEL="org.jleechanorg.ezgha-queue-reaper"
INSTALL_SCRIPT="$REPO_ROOT/launchd/install-launchagents.sh"

run_launchagent_install() { # label, mode, value
  local label="$1" mode="$2" value="${3:-}"
  local target="$FAKE_HOME/Library/LaunchAgents/${label}.plist"
  local log="$WORK/install-${label}-${mode}.log"
  local rc
  if [[ "$mode" == "unset" ]]; then
    if env -u BASH_ENV -u EZGHA_SUSPENSION_RECORD HOME="$FAKE_HOME" BASH_ENV=/dev/null \
        PATH="$INSTALL_PATH" LAUNCHCTL_LOG="$LAUNCHCTL_LOG" \
        bash "$INSTALL_SCRIPT" install "$label" > "$log" 2>&1; then
      rc=0
    else
      rc=$?
    fi
  else
    if env -u BASH_ENV HOME="$FAKE_HOME" PATH="$INSTALL_PATH" BASH_ENV=/dev/null \
        LAUNCHCTL_LOG="$LAUNCHCTL_LOG" EZGHA_SUSPENSION_RECORD="$value" \
        bash "$INSTALL_SCRIPT" install "$label" > "$log" 2>&1; then
      rc=0
    else
      rc=$?
    fi
  fi
  if [[ "$rc" -ne 0 ]]; then
    fail "7 installer exited $rc for $label ($mode): $(tail -n 1 "$log")"
    return 1
  fi
  local observed
  observed="$(read_record "$target")"
  if [[ "$mode" == "unset" ]]; then
    [[ "$observed" == "bead-${label##*.ezgha-queue-}" ]] && \
      pass "7 $label reinstall without env var PRESERVES declaration" || \
      fail "7 $label unset reinstall expected preserved record, got '$observed'"
  elif [[ "$mode" == "empty" ]]; then
    [[ -z "$observed" ]] && pass "7 $label explicit empty CLEARS declaration" || \
      fail "7 $label explicit empty left '$observed'"
  else
    [[ "$observed" == "$value" ]] && pass "7 $label install declares record" || \
      fail "7 $label install expected '$value', got '$observed'"
  fi
  if ! grep -qF "$label" "$LAUNCHCTL_LOG"; then
    fail "7 $label did not reach the fake launchctl"
  fi
}

for label in "$TRIM_LABEL" "$REAPER_LABEL"; do
  run_launchagent_install "$label" set "bead-${label##*.ezgha-queue-}"
  run_launchagent_install "$label" unset
  run_launchagent_install "$label" empty ""
done

if [[ -s "$LAUNCHCTL_LOG" ]]; then
  pass "7 both actual installer paths used the fake launchctl"
else
  fail "7 fake launchctl was never invoked"
fi

if [ "$FAILS" -ne 0 ]; then
  echo "FAILED: $FAILS assertion(s)" >&2
  exit 1
fi
echo "ALL TESTS PASSED!"
