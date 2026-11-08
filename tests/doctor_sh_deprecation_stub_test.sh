#!/usr/bin/env bash
# tests/doctor_sh_deprecation_stub_test.sh
#
# doctor.sh is legacy (AGENTS.md: "LEGACY/BROKEN on docker 27+"); doctor-runner is
# authoritative. This asserts doctor.sh is a deprecation stub that:
#   1. exits 2 (distinct from 0 healthy / 1 unhealthy, so callers cannot mistake a
#      stub for a verdict),
#   2. names ./doctor-runner so the operator knows where to go,
#   3. runs NO probe — verified by PATH stubs that exit 99 if invoked.
#
# Point 3 is the only mechanical property claimed here. Check equivalence between the
# two scripts is a semantic judgement recorded in
# tests/fixtures/doctor_sh_check_mapping.md with reviewer signoff; six review rounds
# proved a shell pattern gate cannot make that judgement.
set -uo pipefail
unset BASH_ENV || true

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
D="$ROOT/doctor.sh"
W="$(mktemp -d)"
# shellcheck disable=SC2329
cleanup() { rm -rf "${W:?}"; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[ -f "$D" ] || fail "doctor.sh not found"
bash -n "$D" || fail "doctor.sh has a syntax error"

# --- 3a. Baseline fixture integrity -----------------------------------------
F="$ROOT/tests/fixtures/doctor_sh_baseline.sh"
S="$ROOT/tests/fixtures/doctor_sh_baseline.sh.sha256"
[ -f "$F" ] || fail "baseline fixture missing: $F"
[ -f "$S" ] || fail "baseline sha256 missing: $S"
( cd "$ROOT" && shasum -a 256 -c tests/fixtures/doctor_sh_baseline.sh.sha256 >/dev/null 2>&1 ) \
  || fail "baseline fixture does not match its recorded SHA256"
[ "$(wc -l < "$F")" -ge 500 ] \
  || fail "baseline fixture looks truncated ($(wc -l < "$F") lines; expected ~560)"
pass "baseline fixture present, complete and hash-verified"

# --- 1+2+3b. Drive the real script with probing binaries that must not run ---
BIN="$W/bin"; mkdir -p "$BIN"
MARK="$W/probed"
for tool in docker gh ssh systemctl launchctl colima; do
  cat > "$BIN/$tool" <<SH
#!/usr/bin/env bash
echo "$tool" >> "$MARK"
exit 99
SH
  chmod +x "$BIN/$tool"
done

OUT="$W/out"
set +e
env -u BASH_ENV PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" "$D" >"$OUT" 2>&1
RC=$?
set -e

[ "$RC" -eq 2 ] || { sed -n '1,20p' "$OUT" >&2; fail "doctor.sh must exit 2 as a stub (got $RC)"; }
pass "doctor.sh exits 2"

grep -q 'doctor-runner' "$OUT" \
  || { sed -n '1,20p' "$OUT" >&2; fail "stub output must point the operator at ./doctor-runner"; }
pass "stub names ./doctor-runner"

if [ -f "$MARK" ]; then
  echo "probes invoked: $(tr '\n' ' ' < "$MARK")" >&2
  fail "stub must not probe anything (docker/gh/ssh/systemctl/launchctl/colima were called)"
fi
pass "stub runs no probe (docker/gh/ssh/systemctl/launchctl/colima all untouched)"

echo "ALL PASS: doctor.sh is a non-probing deprecation stub pointing at doctor-runner"
