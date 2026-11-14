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
    DOCKER_HOST_OVERRIDE=""; source "$WORK/block.sh" ) || true
  echo '</dict></plist>' >> "$plist"
}

read_record() { # prints the record, or <ABSENT>
  /usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:EZGHA_SUSPENSION_RECORD" "$1" 2>/dev/null \
    || printf '<ABSENT>'
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
# the plist_record_of helper
hs = src.index('    plist_record_of() {')
he = src.index('\n    }\n', hs) + len('\n    }\n')
open(sys.argv[3], "w").write("\n".join(l[4:] if l.startswith("    ") else l for l in src[hs:he].splitlines()) + "\n")
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
