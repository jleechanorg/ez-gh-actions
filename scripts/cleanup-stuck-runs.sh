#!/usr/bin/env bash
# cleanup-stuck-runs.sh — report or remove GitHub Actions queue artifacts.
#
# Three classes of "stuck" runs on worldarchitect.ai (and QUEUE_REPO):
#   1. Zombies (>STALE_HOURS old, status=queued) — GitHub rejects DELETE on a
#      queued run (HTTP 403); cancel first (-> completed/cancelled), then delete.
#   2. Superseded queued runs — same branch + workflow, keeping the newest queued run.
#   3. Fresh tail (>FRESH_TAIL_MIN old, still queued) — cancel via API (drops CI for that PR).
#
# Usage:
#   ./scripts/cleanup-stuck-runs.sh                 # dry-run: zombies + superseded queued runs
#   ./scripts/cleanup-stuck-runs.sh --apply          # delete zombies + cancel superseded queued runs
#   ./scripts/cleanup-stuck-runs.sh --zombies        # dry-run: only >STALE_HOURS artifacts
#   ./scripts/cleanup-stuck-runs.sh --superseded     # dry-run: only older queued runs by branch+workflow
#   ./scripts/cleanup-stuck-runs.sh --tail --apply   # cancel fresh tail >45m; intentionally opt-in
set -euo pipefail

QUEUE_REPO="${QUEUE_REPO:-jleechanorg/worldarchitect.ai}"
STALE_HOURS="${STALE_HOURS:-8}"
FRESH_TAIL_MIN="${FRESH_TAIL_MIN:-45}"
DRY_RUN=1
DO_ZOMBIES=1
DO_SUPERSEDED=1
DO_TAIL=0
EXPLICIT_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --zombies)
      if [[ "$EXPLICIT_MODE" -eq 0 ]]; then DO_ZOMBIES=0; DO_SUPERSEDED=0; DO_TAIL=0; fi
      DO_ZOMBIES=1; EXPLICIT_MODE=1; shift ;;
    --superseded)
      if [[ "$EXPLICIT_MODE" -eq 0 ]]; then DO_ZOMBIES=0; DO_SUPERSEDED=0; DO_TAIL=0; fi
      DO_SUPERSEDED=1; EXPLICIT_MODE=1; shift ;;
    --tail)
      if [[ "$EXPLICIT_MODE" -eq 0 ]]; then DO_ZOMBIES=0; DO_SUPERSEDED=0; DO_TAIL=0; fi
      DO_TAIL=1; EXPLICIT_MODE=1; shift ;;
    --apply) DRY_RUN=0; shift ;;
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

export QUEUE_REPO STALE_HOURS FRESH_TAIL_MIN DRY_RUN DO_ZOMBIES DO_SUPERSEDED DO_TAIL

python3 <<'PY'
import json, os, subprocess, datetime, time, sys
from collections import defaultdict

repo = os.environ["QUEUE_REPO"]
stale_h = float(os.environ["STALE_HOURS"])
fresh_tail = float(os.environ["FRESH_TAIL_MIN"])
dry = os.environ.get("DRY_RUN") == "1"
do_zombies = os.environ.get("DO_ZOMBIES") == "1"
do_superseded = os.environ.get("DO_SUPERSEDED") == "1"
do_tail = os.environ.get("DO_TAIL") == "1"

raw_runs = []
page = 1
while True:
    data = json.loads(subprocess.check_output([
        "gh", "api", f"repos/{repo}/actions/runs?status=queued&per_page=100&page={page}"
    ]))
    batch = data.get("workflow_runs", [])
    if not batch:
        break
    raw_runs.extend(batch)
    if len(batch) < 100:
        break
    page += 1

runs = [r for r in raw_runs if r.get("status", "queued") == "queued"]
skipped_non_queued = len(raw_runs) - len(runs)

now = datetime.datetime.now(datetime.timezone.utc)
zombies, tail = [], []
for r in runs:
    c = datetime.datetime.fromisoformat(r["created_at"].replace("Z", "+00:00"))
    age_m = (now - c).total_seconds() / 60
    if age_m >= stale_h * 60:
        zombies.append((age_m, r))
    elif age_m > fresh_tail:
        tail.append((age_m, r))

def run_url(r):
    return r.get("html_url") or f"https://github.com/{repo}/actions/runs/{r['id']}"

def branch(r):
    return r.get("head_branch") or "(unknown-branch)"

def workflow_key(r):
    return str(r.get("workflow_id") or r.get("name") or "(unknown-workflow)")

def workflow_name(r):
    return r.get("name") or f"workflow_id={workflow_key(r)}"

def created_at(r):
    return datetime.datetime.fromisoformat(r["created_at"].replace("Z", "+00:00"))

def run_sort_key(r):
    return (created_at(r), int(r.get("run_number") or 0), int(r["id"]))

groups = defaultdict(list)
for r in runs:
    groups[(branch(r), workflow_key(r))].append(r)

superseded = []
kept_by_group = {}
for key, grouped in groups.items():
    if len(grouped) < 2:
        continue
    newest = max(grouped, key=run_sort_key)
    kept_by_group[key] = newest
    for r in grouped:
        if r["id"] != newest["id"]:
            age_m = (now - created_at(r)).total_seconds() / 60
            superseded.append((key, newest, age_m, r))
superseded_ids = {r["id"] for _, _, _, r in superseded}

print(
    "scan:"
    f" repo={repo}"
    f" queued_total={len(runs)}"
    f" ignored_non_queued={skipped_non_queued}"
    f" zombies_>{os.environ['STALE_HOURS']}h={len(zombies)}"
    f" superseded_by_branch_workflow={len(superseded)}"
    f" fresh_tail_>{fresh_tail}m={len(tail)}"
    f" mode={'dry-run' if dry else 'apply'}"
)
print("safety: only status=queued runs are candidates; in_progress runs are ignored")

def cancel_run(rid):
    subprocess.check_output([
        "gh", "api", "-X", "POST", f"repos/{repo}/actions/runs/{rid}/cancel"
    ], stderr=subprocess.STDOUT)

def delete_run(rid):
    # GitHub rejects DELETE on status=queued runs (HTTP 403) — a queued run must
    # first transition to completed/cancelled via the cancel endpoint before
    # gh run delete succeeds. Ignore cancel failures (e.g. already completed);
    # the delete call below surfaces any real problem.
    try:
        cancel_run(rid)
        time.sleep(1.5)
    except subprocess.CalledProcessError:
        pass
    subprocess.check_output(["gh", "run", "delete", str(rid), "-R", repo], stderr=subprocess.STDOUT)

stats = {"zombie_deleted": 0, "zombie_failed": 0, "tail_cancelled": 0, "tail_failed": 0}
stats.update({"superseded_cancelled": 0, "superseded_failed": 0})

if do_zombies:
    for age_m, r in sorted(zombies, key=lambda x: x[0], reverse=True):
        rid, name, b = r["id"], workflow_name(r), branch(r)
        url = run_url(r)
        if dry:
            print(f"[dry-run] would delete zombie {rid} {age_m/60/24:.1f}d workflow={name!r} branch={b!r} url={url}")
            continue
        try:
            delete_run(rid)
            stats["zombie_deleted"] += 1
            print(f"deleted zombie {rid} {age_m/60/24:.1f}d workflow={name!r} branch={b!r} url={url}")
        except subprocess.CalledProcessError as e:
            stats["zombie_failed"] += 1
            print(f"FAIL zombie {rid} url={url}: {(e.output or b'').decode()[:160]}")
        time.sleep(0.35)

if do_superseded:
    for key in sorted(kept_by_group):
        grouped = [(age_m, r) for k, newest, age_m, r in superseded if k == key]
        if not grouped:
            continue
        kept = kept_by_group[key]
        print(
            "keep newest queued"
            f" branch={key[0]!r}"
            f" workflow={workflow_name(kept)!r}"
            f" id={kept['id']}"
            f" created={kept['created_at']}"
            f" url={run_url(kept)}"
        )
        for age_m, r in sorted(grouped, key=lambda x: run_sort_key(x[1])):
            rid, name, b = r["id"], workflow_name(r), branch(r)
            url = run_url(r)
            if dry:
                print(f"[dry-run] would cancel superseded queued {rid} {age_m:.0f}m workflow={name!r} branch={b!r} url={url}")
                continue
            try:
                cancel_run(rid)
                stats["superseded_cancelled"] += 1
                print(f"cancelled superseded queued {rid} {age_m:.0f}m workflow={name!r} branch={b!r} url={url}")
            except subprocess.CalledProcessError as e:
                stats["superseded_failed"] += 1
                print(f"FAIL superseded {rid} url={url}: {(e.output or b'').decode()[:160]}")
            time.sleep(0.35)

if do_tail:
    for age_m, r in sorted(tail, key=lambda x: x[0], reverse=True):
        if do_superseded and r["id"] in superseded_ids:
            continue
        rid, name, b = r["id"], workflow_name(r), branch(r)
        url = run_url(r)
        if dry:
            print(f"[dry-run] would cancel tail {rid} {age_m:.0f}m workflow={name!r} branch={b!r} url={url}")
            continue
        try:
            cancel_run(rid)
            stats["tail_cancelled"] += 1
            print(f"cancelled tail {rid} {age_m:.0f}m workflow={name!r} branch={b!r} url={url}")
        except subprocess.CalledProcessError as e:
            stats["tail_failed"] += 1
            print(f"FAIL tail {rid} url={url}: {(e.output or b'').decode()[:160]}")
        time.sleep(0.35)

print("summary:", stats)
if stats["zombie_failed"] or stats["superseded_failed"] or stats["tail_failed"]:
    sys.exit(1)
PY
