#!/usr/bin/env bash
# Focused Gate-3 burst preflight regression for the 2026-10-03
# production-guard wiring. Exercises `gate3_burst_preflight` (extracted
# from docs/verify-exit-criteria.sh) across the cases the bash verifier
# must handle. Drives the SAME production `daemon_in_vm` kernel proof
# via stubbed `uname` and `docker` on PATH — we deliberately do NOT
# redefine daemon_in_vm itself, because that would mask the prior
# Darwin OS-only shortcut regression (the one where `daemon_in_vm`
# returned true on macOS without probing the docker daemon). By
# sourcing the production function and pointing it at fakes we cover
# that path end-to-end.
#
# Cases (default-false is covered by case 1 only — production default
# MUST stay unchanged):
#   1. cpu_burst=false                            → pass-through, equal-share
#   2. cpu_burst=true + daemon_kernel_probe fails → refuse (non-VM)
#   3. cpu_burst=true + VM + NCPU=0               → refuse (non-positive)
#   4. cpu_burst=true + VM + NCPU=abc             → refuse (not uint)
#   5. cpu_burst=true + VM + NCPU empty           → refuse (missing)
#   6. cpu_burst=true + VM + NCPU=8               → accept, echo 8
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY="$ROOT/docs/verify-exit-criteria.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
HELPER="$TMP/helper.sh"
{
    awk '
        /^is_uint\(\) \{$/ { capturing=1 }
        capturing { print; if (/^}$/) { capturing=0; exit } }
    ' "$VERIFY"
    awk '
        /^daemon_in_vm\(\) \{$/ { capturing=1 }
        capturing { print; if (/^}$/) { capturing=0; exit } }
    ' "$VERIFY"
    awk '
        /^gate3_burst_preflight\(\) \{$/ { capturing=1 }
        capturing { print; if (/^}$/) { capturing=0; exit } }
    ' "$VERIFY"
} > "$HELPER"
grep -q 'gate3_burst_preflight() {' "$HELPER" \
  || fail "could not extract gate3_burst_preflight helper"
grep -q 'daemon_in_vm() {' "$HELPER" \
  || fail "could not extract daemon_in_vm helper"
grep -q 'is_uint() {' "$HELPER" \
  || fail "could not extract is_uint helper"
# shellcheck disable=SC1090
source "$HELPER"

# Sanity: the helper must depend on daemon_in_vm + is_uint (no new
# semantics invented).
grep -q 'daemon_in_vm' "$HELPER" \
  || fail "gate3_burst_preflight must depend on the daemon_in_vm kernel proof"
grep -q 'is_uint' "$HELPER" \
  || fail "gate3_burst_preflight must validate NCPU via is_uint"

# Build a stubbed PATH containing fake `uname` and `docker`. These fakes
# let us drive the REAL production daemon_in_vm and is_uint without
# touching the host's actual binaries. uname -s is set to Linux so the
# kernel-diff branch runs (we are testing the kernel proof itself).
FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/uname" <<'EOF'
#!/usr/bin/env bash
# Print a fixed host kernel. daemon_in_vm's kernel-diff branch compares
# this against the fake `docker info KernelVersion` we set up per case.
case "${FAKE_UNAME_S:-Linux}${1:+_$1}" in
    Linux_s)   echo "Linux" ;;
    Linux_r)   echo "6.17.0-host" ;;
    Linux)     echo "Linux" ;;
    *)         echo "Linux" ;;
esac
EOF
chmod +x "$FAKE_BIN/uname"

# Run one preflight case. Args: <label> <fake_docker_script_body> <expected_rc>
# <expected_stderr_substr_or_empty> <expected_stdout>. Sets up the fake
# docker, runs the sourced helper under a subshell with the fake PATH,
# and asserts the four invariants.
run_case() {
    local label="$1" docker_body="$2" exp_rc="$3" exp_stderr_substr="$4" exp_stdout="$5"
    cat > "$FAKE_BIN/docker" <<EOF
#!/usr/bin/env bash
$docker_body
EOF
    chmod +x "$FAKE_BIN/docker"
    set +e
    out=$(LIMIT_CPU_BURST=true PATH="$FAKE_BIN:$PATH" gate3_burst_preflight 2>/tmp/case_err)
    rc=$?
    set -e
    [ "$rc" = "$exp_rc" ] \
      || fail "$label: exit code $rc, expected $exp_rc (stderr: $(cat /tmp/case_err), stdout: '$out')"
    if [ -n "$exp_stderr_substr" ]; then
        grep -q "$exp_stderr_substr" /tmp/case_err \
          || fail "$label: stderr missing '$exp_stderr_substr' (got: $(cat /tmp/case_err))"
    fi
    [ "$out" = "$exp_stdout" ] \
      || fail "$label: stdout '$out' != expected '$exp_stdout'"
}

# --- Case 1: cpu_burst=false → unconditional pass ----------------------------
LIMIT_CPU_BURST=false out=$(PATH="$FAKE_BIN:$PATH" gate3_burst_preflight) \
  || fail "case1 default must exit 0"
[ -z "$out" ] || fail "case1 default must not echo anything (got '$out')"

# --- Case 2: cpu_burst=true + Darwin + daemon_kernel_probe FAILS (non-VM) ----
# Stub uname -s=Darwin (which on the OLD code would have short-circuited
# to return 0 unconditionally), AND make docker info KernelVersion emit
# empty output so the kernel probe fails. The post-fix daemon_in_vm MUST
# return false in this scenario — that's the regression the prior
# Darwin-OS-only shortcut missed. Pin: preflight refuses with
# 'not verified VM-contained', not the NCPU rejection downstream.
run_case_uname() {
    local label="$1" fake_uname_s="$2" docker_body="$3" exp_rc="$4" exp_stderr_substr="$5" exp_stdout="$6"
    cat > "$FAKE_BIN/uname" <<EOF
#!/usr/bin/env bash
case "\$1" in
    -s) echo "$fake_uname_s" ;;
    -r) echo "6.17.0-host" ;;
    *)  echo "$fake_uname_s" ;;
esac
EOF
    chmod +x "$FAKE_BIN/uname"
    cat > "$FAKE_BIN/docker" <<EOF
#!/usr/bin/env bash
$docker_body
EOF
    chmod +x "$FAKE_BIN/docker"
    set +e
    out=$(LIMIT_CPU_BURST=true PATH="$FAKE_BIN:$PATH" gate3_burst_preflight 2>/tmp/case_err)
    rc=$?
    set -e
    [ "$rc" = "$exp_rc" ] \
      || fail "$label: exit code $rc, expected $exp_rc (stderr: $(cat /tmp/case_err), stdout: '$out')"
    if [ -n "$exp_stderr_substr" ]; then
        grep -q "$exp_stderr_substr" /tmp/case_err \
          || fail "$label: stderr missing '$exp_stderr_substr' (got: $(cat /tmp/case_err))"
    fi
    [ "$out" = "$exp_stdout" ] \
      || fail "$label: stdout '$out' != expected '$exp_stdout'"
}
run_case_uname "case2 (Darwin + failed kernel probe)" \
  "Darwin" \
  "# Fail the kernel probe: empty output, non-zero exit
   exit 1" \
  "1" "not verified VM-contained" ""

# --- Case 3: VM proved + NCPU=0 → non-positive -----------------------------------
run_case "case3 (zero NCPU)" \
  "if [ \"\$1\" = \"info\" ] && [ \"\$3\" = \"{{.KernelVersion}}\" ]; then echo 6.17.0-vm; exit 0; fi
   if [ \"\$1\" = \"info\" ] && [ \"\$3\" = \"{{.NCPU}}\" ]; then echo 0; exit 0; fi
   echo 'unexpected docker call: \$*' >&2; exit 99" \
  "1" "not a finite positive integer" ""

# --- Case 4: VM proved + NCPU=abc → not uint ----------------------------------
run_case "case4 (non-numeric NCPU)" \
  "if [ \"\$1\" = \"info\" ] && [ \"\$3\" = \"{{.KernelVersion}}\" ]; then echo 6.17.0-vm; exit 0; fi
   if [ \"\$1\" = \"info\" ] && [ \"\$3\" = \"{{.NCPU}}\" ]; then echo abc; exit 0; fi
   echo 'unexpected docker call: \$*' >&2; exit 99" \
  "1" "not a finite positive integer" ""

# --- Case 5: VM proved + NCPU empty → missing ---------------------------------
run_case "case5 (empty NCPU)" \
  "if [ \"\$1\" = \"info\" ] && [ \"\$3\" = \"{{.KernelVersion}}\" ]; then echo 6.17.0-vm; exit 0; fi
   if [ \"\$1\" = \"info\" ] && [ \"\$3\" = \"{{.NCPU}}\" ]; then echo; exit 0; fi
   echo 'unexpected docker call: \$*' >&2; exit 99" \
  "1" "not a finite positive integer" ""

# --- Case 6: VM proved + NCPU=8 → accept, echo 8 ------------------------------
run_case "case6 (accept)" \
  "if [ \"\$1\" = \"info\" ] && [ \"\$3\" = \"{{.KernelVersion}}\" ]; then echo 6.17.0-vm; exit 0; fi
   if [ \"\$1\" = \"info\" ] && [ \"\$3\" = \"{{.NCPU}}\" ]; then echo 8; exit 0; fi
   echo 'unexpected docker call: \$*' >&2; exit 99" \
  "0" "" "8"

# --- Case 3: VM proved + NCPU=0 → non-positive -----------------------------------
run_case "case3 (zero NCPU)" \
  "if [ \"\$1\" = \"info\" ] && [ \"\$3\" = \"{{.KernelVersion}}\" ]; then echo 6.17.0-vm; exit 0; fi
   if [ \"\$1\" = \"info\" ] && [ \"\$3\" = \"{{.NCPU}}\" ]; then echo 0; exit 0; fi
   echo 'unexpected docker call: \$*' >&2; exit 99" \
  "1" "not a finite positive integer" ""

# --- Case 4: VM proved + NCPU=abc → not uint ----------------------------------
run_case "case4 (non-numeric NCPU)" \
  "if [ \"\$1\" = \"info\" ] && [ \"\$3\" = \"{{.KernelVersion}}\" ]; then echo 6.17.0-vm; exit 0; fi
   if [ \"\$1\" = \"info\" ] && [ \"\$3\" = \"{{.NCPU}}\" ]; then echo abc; exit 0; fi
   echo 'unexpected docker call: \$*' >&2; exit 99" \
  "1" "not a finite positive integer" ""

# --- Case 5: VM proved + NCPU empty → missing ---------------------------------
run_case "case5 (empty NCPU)" \
  "if [ \"\$1\" = \"info\" ] && [ \"\$3\" = \"{{.KernelVersion}}\" ]; then echo 6.17.0-vm; exit 0; fi
   if [ \"\$1\" = \"info\" ] && [ \"\$3\" = \"{{.NCPU}}\" ]; then echo; exit 0; fi
   echo 'unexpected docker call: \$*' >&2; exit 99" \
  "1" "not a finite positive integer" ""

# --- Case 6: VM proved + NCPU=8 → accept, echo 8 ------------------------------
run_case "case6 (accept)" \
  "if [ \"\$1\" = \"info\" ] && [ \"\$3\" = \"{{.KernelVersion}}\" ]; then echo 6.17.0-vm; exit 0; fi
   if [ \"\$1\" = \"info\" ] && [ \"\$3\" = \"{{.NCPU}}\" ]; then echo 8; exit 0; fi
   echo 'unexpected docker call: \$*' >&2; exit 99" \
  "0" "" "8"

# --- Case 7: KernelVersion probe exits nonzero with nonempty stdout --------
# Regression for the prior `|| true` swallowing: a half-failed probe that
# printed something (e.g. a docker daemon warning on stderr that leaked
# into stdout) would have been accepted by the OLD code; the new code
# MUST require exit 0 first. Pin: daemon_in_vm returns false → preflight
# refuses with the VM-containment message, NOT a downstream NCPU error.
run_case_uname "case7 (KernelVersion nonzero+nonempty)" \
  "Linux" \
  "if [ \"\$1\" = \"info\" ] && [ \"\$3\" = \"{{.KernelVersion}}\" ]; then echo 6.17.0-fake; exit 1; fi
   echo 'unexpected docker call: \$*' >&2; exit 99" \
  "1" "not verified VM-contained" ""

# --- Case 8: NCPU probe exits nonzero with nonempty stdout ------------------
# VM proof succeeds (kernel probe OK), then NCPU probe returns nonzero
# with a stale value. The OLD `|| true` would have leaked the value into
# is_uint; the new code MUST require exit 0 first and surface the
# probe-failure message (not a misleading "not finite positive integer").
run_case_uname "case8 (NCPU nonzero+nonempty)" \
  "Linux" \
  "if [ \"\$1\" = \"info\" ] && [ \"\$3\" = \"{{.KernelVersion}}\" ]; then echo 6.17.0-vm; exit 0; fi
   if [ \"\$1\" = \"info\" ] && [ \"\$3\" = \"{{.NCPU}}\" ]; then echo 4; exit 1; fi
   echo 'unexpected docker call: \$*' >&2; exit 99" \
  "1" "exited non-zero" ""

# Verify Gate 3 actually invokes the helper at the production call site —
# anchor on the GATE3_PROVEN_NCPU assignment (which only happens when the
# helper is invoked AND its stdout captured). A bare reference to the
# helper definition would pass this grep but is not what Gate 3 needs;
# the seam is the assignment, not the declaration.
grep -nq 'GATE3_PROVEN_NCPU=$(gate3_burst_preflight)' "$VERIFY" \
  || fail "Gate 3 must capture gate3_burst_preflight output via GATE3_PROVEN_NCPU=\$(gate3_burst_preflight) — declaration references alone are not sufficient (found no assignment)"

echo "VERIFY_EXIT_GATE3_BURST_PREFLIGHT_TEST: PASS"