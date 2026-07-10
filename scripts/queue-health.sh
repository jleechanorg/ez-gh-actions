#!/usr/bin/env bash
# queue-health.sh — GitHub Actions queue metrics for ezgha fleet diagnosis.
# Read-only. Used by doctor-runner (sourced, section 8) and runnable standalone:
#   ./scripts/queue-health.sh
#   QUEUE_REPO=jleechanorg/worldarchitect.ai QUEUE_TAIL_WARN_MIN=20 ./scripts/queue-health.sh
#
# BAD/critical trigger is JOB-level: the oldest fresh queued JOB's wait
# (job created_at -> now, status=queued), read from doctor-runner's
# section-F1b job map (JOBLEVEL_OLDEST_QUEUED_MIN / JOBLEVEL_QUEUED_COUNT)
# when sourced. Run-level queued ages are reported as INFORMATIONAL only:
# a workflow RUN sits "queued" for 30+ minutes under `concurrency:`
# serialization or staged gate workflows (Green Gate) while every actual
# job gets a runner within seconds — observed 2026-07-10 01:11, run
# 29060462908 was run-level queued 33.4m but its only job was created at
# 01:11:49 and picked up immediately (zero runner wait). Standalone runs
# (no job map in the environment) fall back to the run-level max, labeled
# as such.
set -euo pipefail

# When sourced by doctor.sh, use return — never exit the parent.
_qh_finish() {
  local code="${1:-0}"
  if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    exit "$code"
  fi
  return "$code"
}

QUEUE_REPO="${QUEUE_REPO:-jleechanorg/worldarchitect.ai}"
QUEUE_TAIL_WARN_MIN="${QUEUE_TAIL_WARN_MIN:-20}"
STALE_HOURS="${STALE_HOURS:-8}"

section() { printf '\n=== %s ===\n' "$*"; }
ok() { printf '  [OK]   %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; }
bad() { printf '  [BAD]  %s\n' "$*"; }
info() { printf '  [..]   %s\n' "$*"; }

if ! command -v gh >/dev/null 2>&1; then
  bad "gh CLI not found — cannot measure queue health"
  _qh_finish 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  bad "python3 not found — cannot measure queue health"
  _qh_finish 2
fi

section "8. GitHub Actions queue health ($QUEUE_REPO)"

export QUEUE_REPO QUEUE_TAIL_WARN_MIN STALE_HOURS

eval "$(python3 <<'PY'
import json, os, subprocess, datetime, statistics

repo = os.environ["QUEUE_REPO"]
tail_warn = float(os.environ["QUEUE_TAIL_WARN_MIN"])
stale_h = float(os.environ["STALE_HOURS"])

def api(path):
    return json.loads(subprocess.check_output(["gh", "api", path]))

runs = []
page = 1
while True:
    data = api(f"repos/{repo}/actions/runs?status=queued&per_page=100&page={page}")
    batch = data.get("workflow_runs", [])
    if not batch:
        break
    runs.extend(batch)
    if len(batch) < 100:
        break
    page += 1

in_prog = api(f"repos/{repo}/actions/runs?status=in_progress&per_page=1")
in_prog_total = in_prog.get("total_count", len(in_prog.get("workflow_runs", [])))

now = datetime.datetime.now(datetime.timezone.utc)
stale_cutoff = stale_h * 3600

fresh, stale = [], []
for r in runs:
    c = datetime.datetime.fromisoformat(r["created_at"].replace("Z", "+00:00"))
    age_s = (now - c).total_seconds()
    if age_s >= stale_cutoff:
        stale.append((age_s, r))
    else:
        fresh.append((age_s, r))

fresh_ages_min = sorted(a / 60 for a, _ in fresh)

def pct(vals, p):
    if not vals:
        return 0.0
    idx = min(len(vals) - 1, int(len(vals) * p))
    return vals[idx]

p50 = statistics.median(fresh_ages_min) if fresh_ages_min else 0.0
p90 = pct(fresh_ages_min, 0.9)
mx = max(fresh_ages_min) if fresh_ages_min else 0.0

oldest_fresh = min(fresh, key=lambda x: x[1]["created_at"])[1] if fresh else None
oldest_stale = max(stale, key=lambda x: x[0])[1] if stale else None

print(f'export QUEUE_QUEUED_TOTAL={len(runs)}')
print(f'export QUEUE_QUEUED_FRESH={len(fresh)}')
print(f'export QUEUE_QUEUED_STALE={len(stale)}')
print(f'export QUEUE_IN_PROGRESS={in_prog_total}')
print(f'export QUEUE_P50_MIN={p50:.1f}')
print(f'export QUEUE_P90_MIN={p90:.1f}')
print(f'export QUEUE_MAX_FRESH_MIN={mx:.1f}')
print(f'export QUEUE_TAIL_WARN_MIN={tail_warn:.0f}')

if oldest_fresh:
    c = datetime.datetime.fromisoformat(oldest_fresh["created_at"].replace("Z", "+00:00"))
    age_min = (now - c).total_seconds() / 60
    print(f'export QUEUE_OLDEST_FRESH_ID={oldest_fresh["id"]}')
    print(f'export QUEUE_OLDEST_FRESH_NAME="{oldest_fresh["name"]}"')
    print(f'export QUEUE_OLDEST_FRESH_BRANCH="{oldest_fresh["head_branch"]}"')
    print(f'export QUEUE_OLDEST_FRESH_CREATED="{oldest_fresh["created_at"]}"')
    print(f'export QUEUE_OLDEST_FRESH_AGE_MIN={age_min:.1f}')
else:
    print('export QUEUE_OLDEST_FRESH_ID=0')
    print('export QUEUE_OLDEST_FRESH_AGE_MIN=0')

if oldest_stale:
    c = datetime.datetime.fromisoformat(oldest_stale["created_at"].replace("Z", "+00:00"))
    age_days = (now - c).total_seconds() / 86400
    print(f'export QUEUE_OLDEST_STALE_ID={oldest_stale["id"]}')
    print(f'export QUEUE_OLDEST_STALE_NAME="{oldest_stale["name"]}"')
    print(f'export QUEUE_OLDEST_STALE_BRANCH="{oldest_stale["head_branch"]}"')
    print(f'export QUEUE_OLDEST_STALE_CREATED="{oldest_stale["created_at"]}"')
    print(f'export QUEUE_OLDEST_STALE_AGE_DAYS={age_days:.1f}')
else:
    print('export QUEUE_OLDEST_STALE_ID=0')
    print('export QUEUE_OLDEST_STALE_AGE_DAYS=0')

# Run-level tail exceedance is INFORMATIONAL only (run age includes
# concurrency/staged-gate wait, not runner wait) — the BAD trigger
# (QUEUE_TAIL_BAD) is computed in bash below from JOB-level wait.
runlevel_exceeded = 1 if mx > tail_warn else 0
print(f'export QUEUE_RUNLEVEL_TAIL_EXCEEDED={runlevel_exceeded}')
print(f'export QUEUE_STALE_ZOMBIES={1 if len(stale) > 0 else 0}')
PY
)"

info "workflow runs in_progress: $QUEUE_IN_PROGRESS"
info "workflow runs queued (total): $QUEUE_QUEUED_TOTAL (fresh <${STALE_HOURS}h: $QUEUE_QUEUED_FRESH, stale zombies: $QUEUE_QUEUED_STALE)"

# Run-level stats: INFORMATIONAL context only — never a BAD/critical
# trigger. Run age counts concurrency-serialization and staged-gate (Green
# Gate) wait, which is not runner wait.
if [ "${QUEUE_QUEUED_FRESH:-0}" -gt 0 ]; then
  info "fresh queue wait (RUN-level, informational) — p50=${QUEUE_P50_MIN}m p90=${QUEUE_P90_MIN}m max=${QUEUE_MAX_FRESH_MIN}m"
  info "oldest fresh queued run: id=$QUEUE_OLDEST_FRESH_ID name=$QUEUE_OLDEST_FRESH_NAME branch=$QUEUE_OLDEST_FRESH_BRANCH age=${QUEUE_OLDEST_FRESH_AGE_MIN}m"
  if [ "${QUEUE_RUNLEVEL_TAIL_EXCEEDED:-0}" -eq 1 ]; then
    info "run-level tail ${QUEUE_MAX_FRESH_MIN}m exceeds ${QUEUE_TAIL_WARN_MIN}m — NOT a defect by itself: run age includes concurrency/staged-gate wait (e.g. 2026-07-10 run 29060462908: 33.4m run-queued, job picked up in seconds); job-level verdict below"
  fi
else
  ok "no fresh queued runs (<${STALE_HOURS}h) — queue drained"
fi

# BAD/critical trigger: JOB-level oldest fresh queued-job wait. When sourced
# by doctor-runner, JOBLEVEL_* come from the section-F1b job map (same
# STALE_HOURS freshness rule, single fetch across every repo the fleet
# serves). The job-level branch is taken ONLY when the map is trustworthy:
# any fetch error (JOBLEVEL_FETCH_ERRORS>0, counted by F1b's failure
# ledger), an unparseable age ("?"), or the cross-check contradiction below
# degrades to the run-level fallback — a truncated fan-out yields an empty
# map that looks exactly like a drained queue, and a health gate must fail
# honest, never silent-green (CLAUDE.md API-truncation hazard).
# Standalone invocations have no job map — same run-level fallback, labeled.
QUEUE_JOBMAP_DEGRADED=0
if [ "${JOBLEVEL_FETCH_ERRORS:-0}" -gt 0 ] || [ "${JOBLEVEL_OLDEST_QUEUED_MIN:-}" = "?" ]; then
  QUEUE_JOBMAP_DEGRADED=1
fi
# Cross-check guard: run-level sees fresh queued runs, the job map saw ZERO
# queued jobs, AND the map had fetch errors — the "empty" map is a
# truncation artifact contradicted by run-level data. Degraded, never green.
if [ "${QUEUE_QUEUED_FRESH:-0}" -gt 0 ] && [ "${JOBLEVEL_QUEUED_COUNT:-0}" -eq 0 ] && [ "${JOBLEVEL_FETCH_ERRORS:-0}" -gt 0 ]; then
  QUEUE_JOBMAP_DEGRADED=1
fi
if [ -n "${JOBLEVEL_OLDEST_QUEUED_MIN:-}" ] && [ "$QUEUE_JOBMAP_DEGRADED" -eq 0 ]; then
  QUEUE_TAIL_SOURCE="job-level"
  QUEUE_TAIL_MIN="${JOBLEVEL_OLDEST_QUEUED_MIN}"
  QUEUE_TAIL_N="${JOBLEVEL_QUEUED_COUNT:-0}"
else
  if [ -n "${JOBLEVEL_OLDEST_QUEUED_MIN:-}" ] && [ "$QUEUE_JOBMAP_DEGRADED" -eq 1 ]; then
    warn "job map degraded (${JOBLEVEL_FETCH_ERRORS:-?} fetch errors) — job-level gate unavailable, using run-level"
  fi
  QUEUE_TAIL_SOURCE="run-level FALLBACK (no usable job map; may overcount concurrency wait)"
  QUEUE_TAIL_MIN="${QUEUE_MAX_FRESH_MIN:-0}"
  QUEUE_TAIL_N="${QUEUE_QUEUED_FRESH:-0}"
fi
QUEUE_TAIL_BAD=0
if [ "${QUEUE_TAIL_N:-0}" -gt 0 ] && awk -v m="${QUEUE_TAIL_MIN:-0}" -v t="${QUEUE_TAIL_WARN_MIN}" 'BEGIN{exit !(m > t)}'; then
  QUEUE_TAIL_BAD=1
fi
export QUEUE_TAIL_BAD
if [ "${QUEUE_TAIL_BAD}" -eq 1 ]; then
  bad "queue tail (${QUEUE_TAIL_SOURCE}) ${QUEUE_TAIL_MIN}m exceeds ${QUEUE_TAIL_WARN_MIN}m — ${QUEUE_TAIL_N} queued job(s); runners saturated or mis-routing"
  info "superseded dry-run: QUEUE_REPO=$QUEUE_REPO ./scripts/queue-backlog-drain.sh --min-age-min ${QUEUE_TAIL_WARN_MIN}"
else
  ok "queue tail (${QUEUE_TAIL_SOURCE}) ${QUEUE_TAIL_MIN}m within ${QUEUE_TAIL_WARN_MIN}m threshold (${QUEUE_TAIL_N} queued job(s))"
fi

if [ "${QUEUE_QUEUED_STALE:-0}" -gt 0 ]; then
  warn "stale queued zombies: $QUEUE_QUEUED_STALE runs older than ${STALE_HOURS}h (GitHub artifact — inspect with: ./scripts/cleanup-stuck-runs.sh --zombies)"
  info "cleanup dry-run: ./scripts/cleanup-stuck-runs.sh --zombies"
  info "cleanup apply: ./scripts/cleanup-stuck-runs.sh --zombies --apply  # gh run delete (cancel fails on zombies)"
  info "oldest stale: id=$QUEUE_OLDEST_STALE_ID name=$QUEUE_OLDEST_STALE_NAME branch=$QUEUE_OLDEST_STALE_BRANCH age=${QUEUE_OLDEST_STALE_AGE_DAYS}d created=$QUEUE_OLDEST_STALE_CREATED"
fi

[ "${QUEUE_TAIL_BAD:-0}" -eq 1 ] && _qh_finish 1
_qh_finish 0
