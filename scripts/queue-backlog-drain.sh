#!/usr/bin/env bash
# queue-backlog-drain.sh — identify superseded queued workflow runs.
#
# Conservative by default: dry-run only. It never touches in-progress runs and
# only proposes cancelling older queued runs when a newer queued run exists for
# the same workflow name and branch.
#
# Usage:
#   ./scripts/queue-backlog-drain.sh
#   ./scripts/queue-backlog-drain.sh --repo jleechanorg/worldarchitect.ai --min-age-min 30
#   ./scripts/queue-backlog-drain.sh --limit 50
#   ./scripts/queue-backlog-drain.sh --cancel-superseded --yes
set -euo pipefail

QUEUE_REPO="${QUEUE_REPO:-jleechanorg/worldarchitect.ai}"
MIN_AGE_MIN="${MIN_AGE_MIN:-30}"
KEEP_PER_GROUP="${KEEP_PER_GROUP:-1}"
LIMIT="${LIMIT:-20}"
CANCEL=0
YES=0
RUNS_JSON=""

usage() {
  sed -n '2,18p' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      QUEUE_REPO="${2:?missing repo}"
      shift 2
      ;;
    --min-age-min)
      MIN_AGE_MIN="${2:?missing minutes}"
      shift 2
      ;;
    --keep-per-group)
      KEEP_PER_GROUP="${2:?missing count}"
      shift 2
      ;;
    --limit)
      LIMIT="${2:?missing count}"
      shift 2
      ;;
    --cancel-superseded)
      CANCEL=1
      shift
      ;;
    --yes)
      YES=1
      shift
      ;;
    --runs-json)
      RUNS_JSON="${2:?missing path}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! command -v python3 >/dev/null 2>&1; then
  echo "requires python3" >&2
  exit 2
fi
if [[ -z "$RUNS_JSON" ]] && ! command -v gh >/dev/null 2>&1; then
  echo "requires gh unless --runs-json is provided" >&2
  exit 2
fi
if [[ "$CANCEL" -eq 1 && "$YES" -ne 1 ]]; then
  echo "--cancel-superseded requires --yes" >&2
  exit 2
fi

export QUEUE_REPO MIN_AGE_MIN KEEP_PER_GROUP LIMIT CANCEL RUNS_JSON

python3 <<'PY'
import datetime
import json
import os
import subprocess
import sys
import time
from collections import defaultdict

repo = os.environ["QUEUE_REPO"]
min_age_min = float(os.environ["MIN_AGE_MIN"])
keep_per_group = int(os.environ["KEEP_PER_GROUP"])
limit = int(os.environ["LIMIT"])
cancel = os.environ["CANCEL"] == "1"
runs_json = os.environ.get("RUNS_JSON", "")

if keep_per_group < 1:
    print("KEEP_PER_GROUP must be >= 1", file=sys.stderr)
    sys.exit(2)
if limit < 0:
    print("LIMIT must be >= 0", file=sys.stderr)
    sys.exit(2)

def load_runs():
    if runs_json:
        with open(runs_json, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        return data.get("workflow_runs", data if isinstance(data, list) else [])

    runs = []
    page = 1
    while True:
        data = json.loads(subprocess.check_output([
            "gh", "api", f"repos/{repo}/actions/runs?status=queued&per_page=100&page={page}",
        ]))
        batch = data.get("workflow_runs", [])
        if not batch:
            break
        runs.extend(batch)
        if len(batch) < 100:
            break
        page += 1
    return runs

def parse_time(value):
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))

def run_url(run):
    return run.get("html_url") or f"https://github.com/{repo}/actions/runs/{run['id']}"

now = datetime.datetime.now(datetime.timezone.utc)
queued = [r for r in load_runs() if r.get("status") == "queued"]
groups = defaultdict(list)

for run in queued:
    key = (run.get("name") or str(run.get("workflow_id") or "unknown"), run.get("head_branch") or "")
    groups[key].append(run)

superseded = []
tail = []
for key, group in groups.items():
    for run in group:
        created = parse_time(run["created_at"])
        age_min = (now - created).total_seconds() / 60
        if age_min >= min_age_min:
            tail.append({"run": run, "age_min": age_min, "group_key": key})

    if len(group) <= keep_per_group:
        continue
    ordered = sorted(group, key=lambda r: parse_time(r["created_at"]), reverse=True)
    kept = ordered[:keep_per_group]
    kept_ids = {r["id"] for r in kept}
    newest = kept[0]
    for run in ordered[keep_per_group:]:
        created = parse_time(run["created_at"])
        age_min = (now - created).total_seconds() / 60
        if age_min < min_age_min:
            continue
        superseded.append({
            "run": run,
            "age_min": age_min,
            "group_key": key,
            "newest": newest,
            "kept_ids": kept_ids,
        })

print(
    "scan: "
    f"repo={repo} queued={len(queued)} groups={len(groups)} "
    f"tail_older_than_min={len(tail)} superseded_candidates={len(superseded)} "
    f"min_age_min={min_age_min:g} keep_per_group={keep_per_group}"
)

for item in sorted(tail, key=lambda i: i["age_min"], reverse=True)[:limit]:
    run = item["run"]
    workflow, branch = item["group_key"]
    print(
        "tail: "
        f"age={item['age_min']:.1f}m "
        f"run={run['id']} workflow={workflow!r} branch={branch!r} "
        f"url={run_url(run)}"
    )

if len(tail) > limit:
    print(f"tail: omitted={len(tail) - limit} limit={limit}")

for item in sorted(superseded, key=lambda i: i["age_min"], reverse=True):
    run = item["run"]
    newest = item["newest"]
    workflow, branch = item["group_key"]
    print(
        "candidate: "
        f"age={item['age_min']:.1f}m "
        f"run={run['id']} workflow={workflow!r} branch={branch!r} "
        f"newer_run={newest['id']} url={run_url(run)}"
    )

if not cancel:
    print("summary: dry_run=true cancelled=0")
    sys.exit(0)

failed = 0
cancelled = 0
for item in sorted(superseded, key=lambda i: i["age_min"], reverse=True):
    run = item["run"]
    rid = str(run["id"])
    try:
        subprocess.check_output([
            "gh", "api", "-X", "POST", f"repos/{repo}/actions/runs/{rid}/cancel",
        ], stderr=subprocess.STDOUT)
        cancelled += 1
        print(f"cancelled: run={rid} url={run_url(run)}")
    except subprocess.CalledProcessError as exc:
        failed += 1
        output = (exc.output or b"").decode(errors="replace").strip().splitlines()
        detail = output[0][:160] if output else f"exit {exc.returncode}"
        print(f"FAIL cancel: run={rid} detail={detail}")
    time.sleep(0.35)

print(f"summary: dry_run=false cancelled={cancelled} failed={failed}")
sys.exit(1 if failed else 0)
PY
