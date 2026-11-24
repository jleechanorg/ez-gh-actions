#!/usr/bin/env bash
# Hermetic regression for the ephemeral-runner probe race in probe_runner_count().
#
# Measured failure (2026-11-24 on Jeff-Ubuntu): ezgha runners are recreated after
# every job, so a container listed by `docker ps` can be gone by the time
# `docker top` reads it. One such race made the whole probe return unknown and the
# script dispatched status=BLIND cause=blind ("Docker runner inventory or process
# evidence incomplete") at 2026-11-24T03:25:45Z and 03:26:03Z while 18/18 org
# runners were online+busy and 19-20 managed containers were running.
# Same-window counter-evidence: 5 consecutive manual probes returned
# containers=12/14/14/14/14 with top_fail=0 when no recreation happened, and a
# direct loop over one captured id list failed `docker top` with
# "No such container: <id>" plus one container in "removing" state.
#
# The function is exercised directly (extracted from the script) so the assertion
# is about the probe contract, not the whole monitor's dispatch path — that path
# is owned by tests/ezgha_host_health_alert_page_boundary_test.sh.
#
# Contract asserted here:
#   1. One container vanishing between inventory and process read does NOT blind
#      the probe; the remaining inventory still yields a usable count.
#   2. `is not running` is definitive absence too, not a measurement gap.
#   3. Every container gone is NOT reported as live zero capacity; it stays
#      unknown so the fail-closed path owns the outage claim.
#   4. An unreachable docker daemon still blinds the probe.
#   5. A malformed successful table still blinds the probe.
#   6. A generic `docker top` failure (exit 1, no definitive error text) still
#      blinds the probe, preserving the #248 observation-to-page boundary.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$ROOT/scripts/ezgha-host-health-alert.sh"
W="$(mktemp -d)"
trap 'rm -rf "${W:?}"' EXIT
FAILED=0

# Extract the probe verbatim so the test asserts the shipped function.
sed -n '/^probe_runner_count()/,/^}/p' "$S" > "$W/probe_fn.sh"
if [ ! -s "$W/probe_fn.sh" ]; then
  echo "FAIL: could not extract probe_runner_count from $S"
  exit 1
fi

cat > "$W/docker" <<'STUB'
#!/usr/bin/env bash
GOOD_ID=$(printf '%064d' 1)
GONE_ID=$(printf '%064d' 2)
if [ "$1" = top ]; then
  case "$PROBE_FIXTURE" in
    one-gone)
      if [ "$2" = "$GONE_ID" ]; then
        printf 'Error response from daemon: No such container: %s\n' "$2" >&2
        exit 1
      fi
      printf 'PID COMMAND\n1 Runner.Listener\n'
      ;;
    one-not-running)
      if [ "$2" = "$GONE_ID" ]; then
        printf 'Error response from daemon: Container %s is not running\n' "$2" >&2
        exit 1
      fi
      printf 'PID COMMAND\n1 Runner.Worker\n'
      ;;
    all-gone)
      printf 'Error response from daemon: No such container: %s\n' "$2" >&2
      exit 1
      ;;
    malformed)
      printf 'PID COMMAND\nnot-a-pid Runner.Worker\n'
      ;;
    top-generic-failure)
      printf 'PID COMMAND\n1 Runner.Worker\n'
      exit 1
      ;;
    *)
      printf 'PID COMMAND\n1 Runner.Listener\n'
      ;;
  esac
  exit 0
fi
case "$PROBE_FIXTURE" in
  one-gone|one-not-running|all-gone) printf '%s\n%s\n' "$GOOD_ID" "$GONE_ID" ;;
  *) printf '%s\n' "$GOOD_ID" ;;
esac
STUB
chmod +x "$W/docker"

# Daemon unreachable: every docker call fails before any container evidence.
cat > "$W/docker-down" <<'STUB'
#!/usr/bin/env bash
printf 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?\n' >&2
exit 1
STUB
chmod +x "$W/docker-down"

probe() { # fixture
  local fixture="$1" out rc=0
  out=$(PROBE_FIXTURE="$fixture" bash -c "$(cat "$W/probe_fn.sh"); probe_runner_count \"\$1\"" bash "$W/docker" 2>/dev/null) || rc=$?
  echo "$rc|$out"
}

check() { # fixture expected_rc expected_out description
  local fixture="$1" want_rc="$2" want_out="$3" desc="$4" got rc out
  got=$(probe "$fixture")
  rc=${got%%|*}
  out=${got#*|}
  if [ "$rc" = "$want_rc" ] && [ "$out" = "$want_out" ]; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc (rc=$rc want=$want_rc, out='$out' want='$want_out')"
    FAILED=1
  fi
}

check one-gone 0 1 "a container recreated between ps and top does not blind the probe"
check one-not-running 0 1 "'is not running' is definitive absence, not a measurement gap"
check all-gone 1 "" "every container gone is unknown capacity, never a live zero"
check malformed 1 "" "a malformed successful table still blinds the probe"
check top-generic-failure 1 "" "a generic top failure still blinds the probe (fail closed)"
check healthy 0 1 "an unraced healthy inventory is unchanged"

rc=0
out=$(PROBE_FIXTURE=healthy bash -c "$(cat "$W/probe_fn.sh"); probe_runner_count \"\$1\"" bash "$W/docker-down" 2>/dev/null) || rc=$?
if [ "$rc" = 1 ] && [ -z "$out" ]; then
  echo "PASS: an unreachable docker daemon still blinds the probe"
else
  echo "FAIL: an unreachable docker daemon still blinds the probe (rc=$rc out='$out')"
  FAILED=1
fi

exit "$FAILED"
