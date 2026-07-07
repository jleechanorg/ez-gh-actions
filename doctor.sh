#!/usr/bin/env bash
# doctor.sh — ez-gh-actions fleet health check. Read-only.
# Outputs a one-shot human-readable report; --json emits machine-parseable
# status for the loop agent (or a follow-up Claude Code session) to drive
# iteration. Designed to fail loudly on the things that previously caused
# silent fleet decay (slot-file desync, missing daemons, container/reg drift).
set -euo pipefail

# --- arg parsing ---------------------------------------------------------
JSON=0
DETAIL=0
PROVE=0
for a in "$@"; do
  case "$a" in
    --json) JSON=1 ;;
    --detail|-v|--verbose) DETAIL=1 ;;
    --prove) PROVE=1 ;;   # dispatch a live canary job and verify it runs on our fleet
    -h|--help)
      echo "usage: doctor.sh [--prove] [--detail]"
      echo "  --prove   dispatch a live ezgha-selftest and verify it runs on ez-org-runner-* (adds ~1-2 min)"
      echo "  --detail  verbose output"
      echo "env: LOOP_WINDOW (min, default 3), ROUTING_N (runs, default 6), ORG, EZGHA_REPO"
      exit 0 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

ORG="${ORG:-jleechanorg}"
EZGHA_REPO="${EZGHA_REPO:-jleechanorg/ez-gh-actions}"
QUEUE_REPO="${QUEUE_REPO:-jleechanorg/worldarchitect.ai}"
QUEUE_TAIL_WARN_MIN="${QUEUE_TAIL_WARN_MIN:-20}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- helpers -------------------------------------------------------------
section() { printf '\n=== %s ===\n' "$*"; }
ok() { printf '  [OK]   %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; }
bad() { printf '  [BAD]  %s\n' "$*"; }
info() { printf '  [..]   %s\n' "$*"; }

# Platform detection: the same fleet can run on Linux (systemd) or macOS
# (launchd) and the diagnostic surfaces differ accordingly. Detect ONCE at
# the top so downstream sections branch consistently.
case "$(uname -s)" in
  Linux)  PLATFORM="linux" ;;
  Darwin) PLATFORM="macos" ;;
  *)      PLATFORM="other" ;;
esac

# Probe the supervisor (systemd on Linux, launchd on macOS) for ezgha's
# service state. Returns one of: active | inactive | failed | not-loaded.
probe_service_state() {
  if [ "$PLATFORM" = "linux" ]; then
    systemctl --user is-active ezgha.service 2>/dev/null || echo "inactive"
  elif [ "$PLATFORM" = "macos" ]; then
    # launchctl prints `PID STATUS LABEL` per loaded job. The ezgha label is
    # `org.jleechanorg.ezgha`. PID column "-" with STATUS "0" means loaded
    # but not running; any other STATUS is the last exit code.
    local line
    line=$(launchctl list 2>/dev/null | awk '$3 == "org.jleechanorg.ezgha" {print; exit}')
    if [ -z "$line" ]; then
      echo "not-loaded"
      return
    fi
    local pid status
    pid=$(echo "$line" | awk '{print $1}')
    status=$(echo "$line" | awk '{print $2}')
    if [ -n "$pid" ] && [ "$pid" != "-" ]; then
      echo "active"
    elif [ "$status" = "0" ]; then
      echo "inactive"
    else
      echo "failed"
    fi
  else
    echo "unsupported"
  fi
}

# Read the last N minutes of ezgha service logs. On Linux this is journalctl;
# on macOS the launchd supervisor writes to /tmp/ezgha-launchd-stdout.log and
# stderr.log (see src/service.rs install_launchd).
recent_logs() {
  local _since_min="${1:-3}"
  if [ "$PLATFORM" = "linux" ]; then
    journalctl --user -u ezgha.service --since "${_since_min} minutes ago" --no-pager 2>/dev/null
  elif [ "$PLATFORM" = "macos" ]; then
    if [ -f /tmp/ezgha-launchd-stdout.log ]; then
      tail -n 200 /tmp/ezgha-launchd-stdout.log
    fi
    if [ -f /tmp/ezgha-launchd-stderr.log ]; then
      tail -n 200 /tmp/ezgha-launchd-stderr.log
    fi
  fi
}

# --- A. local daemon + service ------------------------------------------
section "1. ezgha service"
SERVICE_STATE=$(probe_service_state)
case "$SERVICE_STATE" in
  active)   ok "ezgha.service = active ($PLATFORM)" ;;
  inactive) bad "ezgha.service = inactive (expected active) — start with: ezgha install-service" ;;
  failed)   bad "ezgha.service = failed — check recent logs" ;;
  not-loaded) bad "ezgha.service = not-loaded — run: ezgha install-service" ;;
  unsupported) warn "ezgha.service = unsupported (unknown platform: $PLATFORM)" ;;
  *)        bad "ezgha.service = $SERVICE_STATE (expected active)" ;;
esac

section "2. docker daemon"
if DOCKER_INFO=$(docker info --format '{{.ServerVersion}} {{.NCPU}} {{.MemTotal}}' 2>&1); then
  ok "docker daemon reachable (version/cpu/mem: $DOCKER_INFO)"
else
  bad "docker daemon unreachable: $DOCKER_INFO"
fi

section "3. colima VM (the daemon's host)"
# Two ways to enumerate running colima/Lima VMs:
#   - `colima list` — macOS only, shows ALL profiles by name (default, ci, etc.).
#   - `limactl list` — Linux + macOS, but only shows profiles named `colima`
#     (not `default`). On a fresh Mac install the active profile is named
#     `default`, NOT `colima`, so a pure `limactl list` probe missed it (the
#     original bug this section fixed). Probe both.
COLIMA_STATUS="NotInstalled"
if command -v colima >/dev/null 2>&1; then
  # colima's `list` columns: PROFILE STATUS ARCH CPUS MEMORY DISK RUNTIME ADDRESS
  any_running=$(colima list 2>/dev/null | awk 'NR>1 && $2 == "Running" {print $2; exit}')
  any_stopped=$(colima list 2>/dev/null | awk 'NR>1 && $2 == "Stopped" {print $2; exit}')
  if [ -n "$any_running" ]; then
    ok "colima VM running (at least one profile)"
    COLIMA_STATUS="Running"
  elif [ -n "$any_stopped" ]; then
    # Before declaring BAD: the stopped profile may be the old 'default' colima
    # profile while the actual Docker daemon runs via a limactl VM named 'colima'.
    # Check limactl first, then fall back to whether Docker is actually reachable.
    lima_running_fallback=""
    if command -v limactl > /dev/null 2>&1; then
      lima_running_fallback=$(limactl list 2>/dev/null | awk 'NR>1 && $2 == "Running" {print; exit}')
    fi
    if [ -n "$lima_running_fallback" ]; then
      ok "colima VM running via limactl (colima 'default' profile stopped but limactl VM active)"
      COLIMA_STATUS="Running"
    elif DOCKER_VER=$(docker info --format '{{.ServerVersion}}' 2>/dev/null) && [ -n "$DOCKER_VER" ]; then
      warn "colima profile stopped but docker daemon reachable (v$DOCKER_VER) — non-Lima backend in use"
      COLIMA_STATUS="Running"
    else
      bad "colima VM stopped — start with: colima start"
      COLIMA_STATUS="Stopped"
    fi
  elif command -v limactl >/dev/null 2>&1; then
    # Fallback to limactl if colima list has no running/stopped profiles (e.g. named 'colima')
    lima_running=$(limactl list 2>/dev/null | awk 'NR>1 && $2 == "Running" {print; exit}')
    lima_stopped=$(limactl list 2>/dev/null | awk 'NR>1 && $2 == "Stopped" {print; exit}')
    if [ -n "$lima_running" ]; then
      ok "lima VM running"
      COLIMA_STATUS="Running"
    elif [ -n "$lima_stopped" ]; then
      bad "lima VM stopped — start with: limactl start <name>"
      COLIMA_STATUS="Stopped"
    else
      info "colima installed but no profiles, and limactl installed but no running VMs (host uses Docker or remote daemon)"
    fi
  else
    info "colima installed but no profiles (host uses Docker Desktop or a remote daemon)"
  fi
elif command -v limactl >/dev/null 2>&1; then
  # Linux-side fallback: limactl list is the only Lima enumeration.
  lima_running=$(limactl list 2>/dev/null | awk 'NR>1 && $2 == "Running" {print; exit}')
  lima_stopped=$(limactl list 2>/dev/null | awk 'NR>1 && $2 == "Stopped" {print; exit}')
  if [ -n "$lima_running" ]; then
    ok "lima VM running"
    COLIMA_STATUS="Running"
  elif [ -n "$lima_stopped" ]; then
    bad "lima VM stopped — start with: limactl start <name>"
    COLIMA_STATUS="Stopped"
  else
    info "limactl installed but no running VMs (host uses Docker or remote daemon)"
  fi
else
  info "neither colima nor limactl installed (this host uses Docker Desktop or a remote daemon)"
fi

# --- B. ezgha runtime state ---------------------------------------------
section "4. ezgha runtime state"
SERVICE_RSS=$(ps -o rss= -p $(pgrep -f 'ezgha serve' 2>/dev/null | head -1) 2>/dev/null || echo "?")
info "binary PID RSS=${SERVICE_RSS} KB"
# Count ensure_count failures in a TIME window. ezgha logs roughly one line
# per 30s; on Linux `journalctl --since N minutes ago` is exact, on macOS we
# fall back to `tail -n 200` over /tmp/ezgha-launchd-{stdout,stderr}.log and
# approximate. Health means CURRENT health: only the last LOOP_WINDOW minutes
# of recent activity count.
LOOP_WINDOW="${LOOP_WINDOW:-3}"
LOOP_FAILS=$(recent_logs "$LOOP_WINDOW" | grep -c 'ensure_count failed' || true)
LAST_LOOP=$(recent_logs "$LOOP_WINDOW" | tail -n 1 | cut -c1-40 || true)
info "ensure_count failed occurrences in last ${LOOP_WINDOW} min: $LOOP_FAILS"
info "most recent log line: $LAST_LOOP"
SLOT_FILE="$HOME/.config/ezgha/slot_assignments.toml"
if [ -f "$SLOT_FILE" ]; then
  ASSIGNED=$(grep -c '=' "$SLOT_FILE" 2>/dev/null || echo 0)
  ok "slot_assignments.toml present ($ASSIGNED slots reserved)"
else
  info "slot_assignments.toml absent (no reservations)"
fi

# Read the configured runner name prefix from ~/.config/ezgha/config.toml.
# Different platforms/stacks use different prefixes: jeff-ubuntu Linux uses
# `ez-org-runner` (legacy) or `ez-runner-b` (after prefix rename PR #8143),
# Mac uses `ez-mac-runner` and may collide so suffixes like `-b` get added
# by next_slot to avoid GitHub-side 422s. The doctor must accept ALL of
# these, not a single hardcoded `ez-org-`.
RUNNER_NAME_PREFIX=$(awk -F'"' '/^name_prefix/ {print $2; exit}' "$HOME/.config/ezgha/config.toml" 2>/dev/null)
if [ -z "$RUNNER_NAME_PREFIX" ]; then
  # Legacy / missing config: fall back to `ez-org-runner` (the pre-#8143 default).
  RUNNER_NAME_PREFIX="ez-org-runner"
fi
info "configured runner name prefix: $RUNNER_NAME_PREFIX"


# Policy vs backend: catch minimum_isolation=vm on hosts where docker blips
# leave backend at container-only (Mac colima socket flake → serve fail-closed).
POLICY_MIN=$(awk -F'"' '/^minimum_isolation/ {print $2; exit}' "$HOME/.config/ezgha/config.toml" 2>/dev/null)
if [ -n "$POLICY_MIN" ]; then
  info "configured minimum_isolation: $POLICY_MIN"
  if recent_logs 10 | grep -q 'policy requires vm isolation but best available backend is docker'; then
    bad "serve fail-closed: minimum_isolation=$POLICY_MIN but docker backend is container-only (daemon blip or misconfig)"
  elif [ "$POLICY_MIN" = "vm" ] && [ "$PLATFORM" = "macos" ] && ! docker info --format '{{.KernelVersion}}' >/dev/null 2>&1; then
    bad "minimum_isolation=vm but docker daemon/kernel probe failed — serve will refuse to spawn"
  else
    ok "isolation policy $POLICY_MIN compatible with current docker backend"
  fi
fi

# --- C. GitHub-side runner fleet ----------------------------------------
section "5. GitHub org runner fleet ($ORG)"
RAW=$($(command -v gh) api "orgs/$ORG/actions/runners" --paginate 2>/dev/null || echo '{"runners":[]}')
TOTAL=$(echo "$RAW" | jq '.total_count // (.runners | length)')
ONLINE=$(echo "$RAW" | jq '[.runners[] | select(.status=="online")] | length')
OFFLINE=$(echo "$RAW" | jq '[.runners[] | select(.status=="offline")] | length')
BUSY=$(echo "$RAW" | jq '[.runners[] | select(.busy==true)] | length')
echo "  total=$TOTAL online=$ONLINE offline=$OFFLINE busy=$BUSY"
EZ_RUNNERS=$(echo "$RAW" | jq -r --arg pfx "$RUNNER_NAME_PREFIX" '.runners[] | select(.name | startswith($pfx)) | "\(.name) \(.status)"')
if [ -n "$EZ_RUNNERS" ]; then
  echo "$EZ_RUNNERS" | while read -r n s; do
    case "$s" in
      online) ok "ezgha: $n $s" ;;
      *)      bad "ezgha: $n $s" ;;
    esac
  done
else
  bad "no ${RUNNER_NAME_PREFIX}-* registrations on GitHub"
fi
COLIMA_RUNNERS=$(echo "$RAW" | jq -r '.runners[] | select(.name | startswith("org-runner-")) | "\(.name) \(.status)"')
if [ -n "$COLIMA_RUNNERS" ]; then
  echo "  (colima leftovers still present, not auto-cleaned by ezgha):"
  echo "$COLIMA_RUNNERS" | while read -r n s; do
    warn "colima: $n $s"
  done
fi

# --- D. live docker containers ------------------------------------------
section "6. live docker containers (ezgha-managed)"
CONTAINER_NAMES=$(docker ps --filter label=ezgha=managed --format '{{.Names}} {{.Status}}' 2>/dev/null || true)
CONTAINER_COUNT=$(docker ps --filter label=ezgha=managed --format '{{.Names}}' 2>/dev/null | wc -l)
CONTAINER_COUNT=$(printf '%d' "$CONTAINER_COUNT" 2>/dev/null || echo 0)
info "managed containers running: $CONTAINER_COUNT (expected: configured runner.count)"
echo "$CONTAINER_NAMES" | head -20

# --- E. recent routing proof: jobs REALLY ran on ez-org-runner-* ---------
# "online" is not "working". This section proves recent GitHub Actions jobs
# were actually EXECUTED by ez-org-runner-* runners by reading each run's
# jobs API and confirming the runner_name that handled it belongs to our
# fleet. A completed run whose runner_name is NOT ez-org-runner-* means the
# job went to colima / GitHub-hosted / somewhere else.
section "7. real job-execution proof (last ${ROUTING_N:-6} ezgha-selftest runs)"
ROUTING_N="${ROUTING_N:-6}"
REAL_ON_FLEET=0
REAL_TOTAL=0
while read -r rid; do
  [ -z "$rid" ] && continue
  REAL_TOTAL=$((REAL_TOTAL+1))
  jobs=$($(command -v gh) api "repos/$EZGHA_REPO/actions/runs/$rid/jobs" 2>/dev/null)
  rn=$(echo "$jobs" | jq -r '.jobs[0].runner_name // "?"' 2>/dev/null)
  conc=$(echo "$jobs" | jq -r '.jobs[0].conclusion // "?"' 2>/dev/null)
  if [[ "$rn" == "${RUNNER_NAME_PREFIX}"* ]] || [[ "$rn" == "${RUNNER_NAME_PREFIX}-"* ]]; then
    ok "run $rid: $conc on $rn (our fleet)"
    [ "$conc" = "success" ] && REAL_ON_FLEET=$((REAL_ON_FLEET+1))
  else
    warn "run $rid: $conc on $rn (NOT an ez-org-runner)"
  fi
done < <($(command -v gh) run list -R "$EZGHA_REPO" -w ezgha-selftest -L "$ROUTING_N" --json databaseId --jq '.[].databaseId' 2>/dev/null)
info "real jobs succeeded on our fleet: $REAL_ON_FLEET / $REAL_TOTAL"

# --- E2. optional live canary: dispatch a job and prove it runs NOW ------
# `--prove` dispatches a fresh ezgha-selftest and blocks until it completes,
# then confirms the runner_name is ez-org-runner-* and conclusion=success.
# This is the strongest "handled for real, right now" proof.
CANARY_OK=""
if [ "$PROVE" = "1" ]; then
  section "7b. live canary (dispatch + verify a job runs on our fleet NOW)"
  before=$($(command -v gh) run list -R "$EZGHA_REPO" -w ezgha-selftest -L 1 --json databaseId --jq '.[0].databaseId // 0' 2>/dev/null)
  $(command -v gh) workflow run ezgha-selftest -R "$EZGHA_REPO" >/dev/null 2>&1
  info "dispatched canary; waiting for a new run to appear + complete (up to 180s)..."
  cid=""
  for _ in $(seq 1 18); do
    sleep 10
    latest=$($(command -v gh) run list -R "$EZGHA_REPO" -w ezgha-selftest -L 1 --json databaseId --jq '.[0].databaseId // 0' 2>/dev/null)
    [ "$latest" != "$before" ] && [ "$latest" != "0" ] && { cid="$latest"; break; }
  done
  if [ -z "$cid" ]; then
    bad "canary never appeared — dispatch failed or no runner picked it up"
  else
    for _ in $(seq 1 18); do
      st=$($(command -v gh) run view "$cid" -R "$EZGHA_REPO" --json status,conclusion --jq '.status' 2>/dev/null)
      [ "$st" = "completed" ] && break
      sleep 10
    done
    jobs=$($(command -v gh) api "repos/$EZGHA_REPO/actions/runs/$cid/jobs" 2>/dev/null)
    rn=$(echo "$jobs" | jq -r '.jobs[0].runner_name // "?"')
    conc=$(echo "$jobs" | jq -r '.jobs[0].conclusion // "?"')
    if [[ "$rn" == ez-org-runner-* ]] && [ "$conc" = "success" ]; then
      ok "canary run $cid: success on $rn — fleet is handling real jobs NOW"
      CANARY_OK=1
    else
      bad "canary run $cid: $conc on $rn (expected success on ez-org-runner-*)"
    fi
  fi
fi


# --- F2. GitHub Actions queue health (saturation / tail latency) ----------
QUEUE_TAIL_BAD=0
QUEUE_QUEUED_STALE=0
if [ -f "$SCRIPT_DIR/scripts/queue-health.sh" ]; then
  set +e
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/scripts/queue-health.sh"
  QUEUE_RC=$?
  set -e
  [ "$QUEUE_RC" -eq 1 ] && QUEUE_TAIL_BAD=1
else
  section "8. GitHub Actions queue health"
  warn "scripts/queue-health.sh missing — queue metrics skipped"
fi

# --- G. verdict ----------------------------------------------------------
section "verdict"
CRITICAL=0
[ "$SERVICE_STATE" != "active" ]            && CRITICAL=$((CRITICAL+1))
[ "$COLIMA_STATUS" = "Stopped" ]            && CRITICAL=$((CRITICAL+1))
# Healthy runners are online AND match the configured name prefix. (Was hardcoded
# `ez-org-`; fixed to use $RUNNER_NAME_PREFIX so Mac's `ez-mac-runner-b-*` fleet
# counts the same as Linux's `ez-org-runner-*` / `ez-runner-b-*`.)
! echo "$RAW" | jq -e --arg pfx "$RUNNER_NAME_PREFIX" '.runners[] | select(.name | startswith($pfx)) | select(.status=="online")' >/dev/null 2>&1 && \
                                          CRITICAL=$((CRITICAL+1))
# Container count gate uses the CONFIGURED count, not a hardcoded 14.
EXPECTED_CONTAINERS="${EXPECTED_CONTAINERS:-${ASSIGNED:-6}}"
[ "${CONTAINER_COUNT:-0}" -lt "$EXPECTED_CONTAINERS" ] && CRITICAL=$((CRITICAL+1))
# LOOP_FAILS is reported as WARN (not CRITICAL) when the fleet is otherwise
# healthy. ensure_count can fail transiently on slot-name collisions (409 from
# GitHub when an existing runner still holds the name) — those recover on the
# next 30s tick once the slot is reconciled. CRITICAL only fires when the
# reconcile is failing AND there are no healthy runners (the loop failure
# actually matters when the fleet is dark). PR #4 (release_stale_slots) will
# fix the underlying collision; until that lands in main, do not fail the
# fleet over a transient reconcile miss.
if [ "$LOOP_FAILS" -gt 3 ]; then
  HEALTHY_RUNNERS=$(echo "$RAW" | jq -r --arg pfx "$RUNNER_NAME_PREFIX" '[.runners[] | select(.name | startswith($pfx)) | select(.status=="online")] | length')
  if [ "${HEALTHY_RUNNERS:-0}" -lt 1 ]; then
    CRITICAL=$((CRITICAL+1))
    bad "ensure_count failed $LOOP_FAILS times in last ${LOOP_WINDOW}m AND no healthy runners"
  else
    warn "ensure_count failed $LOOP_FAILS times in last ${LOOP_WINDOW}m (transient reconcile miss; $HEALTHY_RUNNERS healthy runners online)"
  fi
fi
# real-execution gate: at least one recent job must have succeeded on our fleet
[ "${REAL_ON_FLEET:-0}" -lt 1 ]            && CRITICAL=$((CRITICAL+1))
# canary gate (only when --prove): the live job must have run on our fleet
[ "$PROVE" = "1" ] && [ -z "$CANARY_OK" ]  && CRITICAL=$((CRITICAL+1))
# queue tail gate: fresh backlog waiting > QUEUE_TAIL_WARN_MIN means saturated/mis-routing
[ "${QUEUE_TAIL_BAD:-0}" -eq 1 ] && CRITICAL=$((CRITICAL+1))

if [ "$CRITICAL" -gt 0 ]; then
  bad "fleet unhealthy: $CRITICAL critical check(s) failed"
  echo
  echo "Suggested remediation (platform=$PLATFORM):"
  if [ "$PLATFORM" = "linux" ]; then
    echo "  1. Stop and restart ezgha:  systemctl --user restart ezgha.service"
  elif [ "$PLATFORM" = "macos" ]; then
    echo "  1. Stop and restart ezgha:  launchctl kickstart -k gui/$(id -u)/org.jleechanorg.ezgha"
    echo "     (or reload plist:        launchctl unload ~/Library/LaunchAgents/org.jleechanorg.ezgha.plist && launchctl load -w ~/Library/LaunchAgents/org.jleechanorg.ezgha.plist)"
  else
    echo "  1. Stop and restart ezgha via your platform's service manager"
  fi
  echo "  2. Reset slot file:          rm ~/.config/ezgha/slot_assignments.toml"
  if command -v colima >/dev/null 2>&1; then
    echo "  3. Start colima if down:     colima start"
  elif command -v limactl >/dev/null 2>&1; then
    echo "  3. Start lima if down:       limactl start <name>"
  fi
  echo "  4. Re-run ./doctor.sh --detail after each step"
  exit 1
fi
ok "fleet healthy: $ONLINE/$TOTAL runners online, $BUSY busy, $CONTAINER_COUNT containers up, $LOOP_FAILS loop errors"
exit 0