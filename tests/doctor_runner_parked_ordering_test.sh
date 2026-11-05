#!/usr/bin/env bash
# Verifies the two ordering defects codex found at ab90d52, using PRODUCTION
# ORDER: the opt-out declaration + prefix default come from the shipped
# doctor-runner (hoisted above section 7), then section 7's classifier and the
# --prove canary run, then section 10's authoritative config lookup.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOC="$REPO/doctor-runner"
[ -f "$DOC" ] || { echo "FAIL: no doctor-runner"; exit 1; }

# --- extract the shipped declaration + prefix default (above section 7) ------
DECL=$(awk '/^# WHO is parked, decided before any consumer/{f=1} f{print} f&&/^export REMOTE_PREFIX$/{exit}' "$DOC")
[ -n "$DECL" ] || { echo "FAIL: could not extract the hoisted opt-out block"; exit 1; }

# --- canonical parked-leg helpers (delimited by sentinels) ------------------
HELPERS=$(awk '/BEGIN parked-leg helpers/{f=1;next} /END parked-leg helpers/{exit} f' "$DOC")
[ -n "$HELPERS" ] || { echo "FAIL: could not extract the parked-leg helpers"; exit 1; }

# --- extract section 7's classifier -----------------------------------------
CLS=$(awk '/^  # Count a success as execution proof only/{f=1} f{print} f&&/^  fi$/ && prev_done{exit} {prev_done=($0 ~ /^  fi$/)}' "$DOC")
# simpler: take through the last "fi" before the read-loop "done < <("
CLS=$(awk '/^  # Count a success as execution proof only/{f=1} f{print} f&&/^done < </{exit}' "$DOC" | sed '$d')

# --- extract the canary parked-leg check ------------------------------------
# The canary block's own closing `fi` is the last one before the `  fi` that
# closes the surrounding `if [ -n "$cid" ]`. Take the 4-space-indented region
# through its final `    fi` (line 774 in the shipped file).
CAN=$(awk '/^    # Apply the SAME parked-leg exclusion as section 7\./{f=1}
           f{print}
           f&&/^    fi$/ && !/^      /{exit}' "$DOC")

run_decl() { # platform env...  -> prints REMOTE_DISABLED and REMOTE_PREFIX
  ( export "$@"=1 2>/dev/null
    bash -c "PLATFORM='$1'; shift 2>/dev/null; $(echo "$DECL" | grep -v '^#')
             printf 'DISABLED=%s PREFIX=%s' \"\$REMOTE_DISABLED\" \"\$REMOTE_PREFIX\"" )
}

ok=1
check() { # label got expect
  if [ "$2" = "$3" ]; then printf '  [%s] %s -- PASS\n' "$1" "$2"
  else printf '  [%s] %s (expect %s) -- FAIL\n' "$1" "$2" "$3"; ok=0; fi
}

echo "--- P0: parked-leg exclusion works in production order ---"
# Linux doctor, MAC_RUNNER_DISABLED=1 -> REMOTE_DISABLED must already be 1 when
# section 7 classifies a Mac run.
got=$(PLATFORM=linux MAC_RUNNER_DISABLED=1 bash -c "$(echo "$DECL" | grep -v '^#')
  REAL_ON_FLEET=0; rid=1; rn=ez-mac-runner-h-1; conc=success
  ok(){ :; }; warn(){ :; }
$HELPERS
$CLS
printf '%s' \"\$REAL_ON_FLEET\"")
check "linux doctor + MAC parked: Mac success REJECTED" "$got" "0"

got=$(PLATFORM=linux MAC_RUNNER_DISABLED=1 bash -c "$(echo "$DECL" | grep -v '^#')
  REAL_ON_FLEET=0; rid=1; rn=ez-runner-c-3; conc=success
  ok(){ :; }; warn(){ :; }
$HELPERS
$CLS
printf '%s' \"\$REAL_ON_FLEET\"")
check "linux doctor + MAC parked: Linux success ACCEPTED" "$got" "1"

# Reverse direction: macOS doctor, REMOTE_LINUX_DISABLED=1
got=$(PLATFORM=macos REMOTE_LINUX_DISABLED=1 bash -c "$(echo "$DECL" | grep -v '^#')
  REAL_ON_FLEET=0; rid=1; rn=ez-runner-c-3; conc=success
  ok(){ :; }; warn(){ :; }
$HELPERS
$CLS
printf '%s' \"\$REAL_ON_FLEET\"")
check "macos doctor + Linux parked: Linux success REJECTED" "$got" "0"

echo "--- P0: canary also rejects a parked leg ---"
if [ -n "$CAN" ]; then
  got=$(PLATFORM=linux MAC_RUNNER_DISABLED=1 bash -c "$(echo "$DECL" | grep -v '^#')
    CANARY_OK=''; cid=1; rn=ez-mac-runner-h-1; conc=success
    ok(){ :; }; bad(){ :; }
$HELPERS
$CAN
printf '%s' \"\${CANARY_OK:-0}\"")
  check "linux doctor + MAC parked: canary on Mac REJECTED" "$got" "0"
else
  echo "  [canary] FAIL: could not extract canary check"; ok=0
fi

echo "--- P1: authoritative config prefix is still read (not short-circuited) ---"
# The hoisted default only fills an EMPTY prefix; section 10 keeps using `||`
# so an explicit override wins and a configured value is still read.
if grep -q '\[ -n "\$REMOTE_PREFIX" \] || REMOTE_PREFIX=\$(_remote_cfg_get' "$DOC"; then
  check "section 10 still reads configured name_prefix" "yes" "yes"
else
  echo "  [config-lookup] FAIL: section 10 no longer reads the configured prefix"; ok=0
fi

if [ "$ok" -eq 1 ]; then echo "REGRESSION_TEST: PASS"; exit 0; else echo "REGRESSION_TEST: FAIL"; exit 1; fi
