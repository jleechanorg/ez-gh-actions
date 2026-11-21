#!/usr/bin/env bash
# tests/launchd_templates_parse_test.sh
#
# Every launchd template must render to a plist that REAL XML parsers accept,
# and the queue-agent templates must carry the ghost declaration through.
#
# Why (review finding): the reaper template contained '--' inside an XML comment
# (Runs … --apply, and "failed -- unless"). `plutil` on macOS tolerates that, but
# Python's plistlib (expat) rejects the whole document. Both installer read-back
# helpers use plistlib and swallow the exception, so preservation silently
# returned empty and a reinstall would have cleared an acknowledged ghost set.
# A parser-level check is the only thing that catches this class.
#
# Usage: bash tests/launchd_templates_parse_test.sh
set -uo pipefail
unset BASH_ENV || true

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILS=$((FAILS+1)); }

python3 - "$ROOT/launchd" <<'PY'
import glob, os, re, sys
import plistlib

d = sys.argv[1]
bad = 0
checked = 0
queue_missing = []
for f in sorted(glob.glob(os.path.join(d, "*.plist.template"))):
    raw = open(f).read()
    rendered = (raw.replace("@HOME@", "/tmp/home")
                   .replace("@SCRIPTS_DIR@", "/tmp/scripts")
                   .replace("@SCRATCH_ROOT@", "/tmp/scratch")
                   .replace("@GHOST_SUSPENSION_RECORD@", "bead-probe"))
    rendered = re.sub(r"@[A-Z_]+@", "x", rendered)   # any remaining placeholder
    checked += 1
    try:
        doc = plistlib.loads(rendered.encode())
    except Exception as e:
        bad += 1
        print(f"FAIL {os.path.basename(f)}: rejected by plistlib -> {type(e).__name__}: {e}")
        continue
    print(f"PASS {os.path.basename(f)}: parses")
    # Only the two agents this PR actually manages. The older
    # -queue-reaper-stopgap agent is a different script (queue-reaper-stopgap.sh)
    # and intentionally has no ghost declaration.
    if os.path.basename(f) in (
            "org.jleechanorg.ezgha-queue-reaper.plist.template",
            "org.jleechanorg.ezgha-queue-trimmer.plist.template"):
        env = doc.get("EnvironmentVariables") or {}
        if env.get("EZGHA_SUSPENSION_RECORD") != "bead-probe":
            queue_missing.append(os.path.basename(f))

if queue_missing:
    bad += 1
    print("FAIL queue-agent template(s) did not carry the declaration: " + ", ".join(queue_missing))
else:
    print("PASS every queue-agent template carries EZGHA_SUSPENSION_RECORD")

print(f"TEMPLATES_CHECKED={checked}")
sys.exit(1 if bad else 0)
PY
rc=$?
[ "$rc" -eq 0 ] && pass "all launchd templates render to parseable plists" \
                || fail "at least one launchd template is unparseable (see above)"

echo
if [ "$FAILS" -ne 0 ]; then
  echo "FAILED: $FAILS assertion(s)" >&2
  exit 1
fi
echo "ALL TESTS PASSED!"
