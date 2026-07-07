#!/usr/bin/env bash
# cleanup-stuck-runs.sh — remove GitHub Actions queue artifacts and long-waiting jobs.
#
# Two classes of "stuck" runs on worldarchitect.ai (and QUEUE_REPO):
#   1. Zombies (>STALE_HOURS old, status=queued) — gh run cancel fails; use gh run delete.
#   2. Fresh tail (>FRESH_TAIL_MIN old, still queued) — cancel via API (drops CI for that PR).
#
# Usage:
#   ./scripts/cleanup-stuck-runs.sh              # zombies + fresh tail
#   ./scripts/cleanup-stuck-runs.sh --zombies    # delete only >STALE_HOURS artifacts
#   ./scripts/cleanup-stuck-runs.sh --tail       # cancel only fresh tail >45m
#   ./scripts/cleanup-stuck-runs.sh --dry-run    # report only
set -euo pipefail

QUEUE_REPO="${QUEUE_REPO:-jleechanorg/worldarchitect.ai}"
STALE_HOURS="${STALE_HOURS:-8}"
FRESH_TAIL_MIN="${FRESH_TAIL_MIN:-45}"
DRY_RUN=0
DO_ZOMBIES=1
DO_TAIL=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --zombies) DO_TAIL=0; shift ;;
    --tail) DO_ZOMBIES=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '2,14p' "$0"
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if ! command -v gh >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "requires gh and python3" >&2
  exit 2
fi

export QUEUE_REPO STALE_HOURS FRESH_TAIL_MIN DRY_RUN DO_ZOMBIES DO_TAIL

python3 <<'PY'
import json, os, subprocess, datetime, time, sys

repo = os.environ["QUEUE_REPO"]
stale_h = float(os.environ["STALE_HOURS"])
fresh_tail = float(os.environ["FRESH_TAIL_MIN"])
dry = os.environ.get("DRY_RUN") == "1"
do_zombies = os.environ.get("DO_ZOMBIES") == "1"
do_tail = os.environ.get("DO_TAIL") == "1"

runs = []
page = 1
while True:
    data = json.loads(subprocess.check_output([
        "gh", "api", f"repos/{repo}/actions/runs?status=queued&per_page=100&page={page}"
    ]))
    batch = data.get("workflow_runs", [])
    if not batch:
        break
    runs.extend(batch)
    if len(batch) < 100:
        break
    page += 1

now = datetime.datetime.now(datetime.timezone.utc)
zombies, tail = [], []
for r in runs:
    c = datetime.datetime.fromisoformat(r["created_at"].replace("Z", "+00:00"))
    age_m = (now - c).total_seconds() / 60
    if age_m >= stale_h * 60:
        zombies.append((age_m, r))
    elif age_m > fresh_tail:
        tail.append((age_m, r))

print(f"scan: queued_total={len(runs)} zombies_>{os.environ['STALE_HOURS']}h={len(zombies)} fresh_tail_>{fresh_tail}m={len(tail)}")

def delete_run(rid):
    subprocess.check_output(["gh", "run", "delete", str(rid), "-R", repo], stderr=subprocess.STDOUT)

def cancel_run(rid):
    subprocess.check_output([
        "gh", "api", "-X", "POST", f"repos/{repo}/actions/runs/{rid}/cancel"
    ], stderr=subprocess.STDOUT)

stats = {"zombie_deleted": 0, "zombie_failed": 0, "tail_cancelled": 0, "tail_failed": 0}

if do_zombies:
    for age_m, r in sorted(zombies, key=lambda x: x[0], reverse=True):
        rid, name, branch = r["id"], r["name"][:30], r["head_branch"][:35]
        if dry:
            print(f"[dry-run] would delete zombie {rid} {age_m/60/24:.1f}d {name} ({branch})")
            continue
        try:
            delete_run(rid)
            stats["zombie_deleted"] += 1
            print(f"deleted zombie {rid} {age_m/60/24:.1f}d {name}")
        except subprocess.CalledProcessError as e:
            stats["zombie_failed"] += 1
            print(f"FAIL zombie {rid}: {(e.output or b'').decode()[:80]}")
        time.sleep(0.35)

if do_tail:
    for age_m, r in sorted(tail, key=lambda x: x[0], reverse=True):
        rid, name, branch = r["id"], r["name"][:30], r["head_branch"][:35]
        if dry:
            print(f"[dry-run] would cancel tail {rid} {age_m:.0f}m {name} ({branch})")
            continue
        try:
            cancel_run(rid)
            stats["tail_cancelled"] += 1
            print(f"cancelled tail {rid} {age_m:.0f}m {name}")
        except subprocess.CalledProcessError as e:
            stats["tail_failed"] += 1
            print(f"FAIL tail {rid}: {(e.output or b'').decode()[:80]}")
        time.sleep(0.35)

print("summary:", stats)
if stats["zombie_failed"] or stats["tail_failed"]:
    sys.exit(1)
PY
