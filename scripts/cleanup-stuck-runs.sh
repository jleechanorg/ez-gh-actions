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

# Rate-limit resilience (bead jleechan-me9): GitHub applies a SECONDARY
# throttle to the /actions/* REST family that is invisible in the primary
# rate_limit numbers (core can read ~4000 remaining while /actions/runs
# 403s). An unhandled 403 here crash-loops the reaper tick and leaves the
# queue unswept — observed live 2026-07-08 02:41-03:42Z while >20m runs
# accumulated. On a rate-limit 403: back off once (60s), retry, and if
# still throttled skip the tick GRACEFULLY (exit 0 with a log line) so
# launchd cadence resumes next interval instead of logging a crash.
def list_queued_page(page):
    return json.loads(subprocess.check_output([
        "gh", "api", f"repos/{repo}/actions/runs?status=queued&per_page=100&page={page}"
    ], stderr=subprocess.STDOUT))

def is_rate_limited(err):
    return b"rate limit" in (err.output or b"").lower() or b"403" in (err.output or b"")

raw_runs = []
page = 1
while True:
    try:
        data = list_queued_page(page)
    except subprocess.CalledProcessError as e:
        if not is_rate_limited(e):
            raise
        print("rate-limited on /actions/runs listing; backing off 60s and retrying once")
        time.sleep(60)
        try:
            data = list_queued_page(page)
        except subprocess.CalledProcessError as e2:
            if not is_rate_limited(e2):
                raise
            print("SKIP TICK: /actions/runs still rate-limited after backoff — "
                  "leaving queue for next scheduled tick (graceful, not a failure)")
            sys.exit(0)
    batch = data.get("workflow_runs", [])
    if not batch:
        break
    raw_runs.extend(batch)
    if len(batch) < 100:
        break
    page += 1

# Deploy workflows are NEVER candidates for any cancel lever (zombie/superseded/
# tail), even if queued past every threshold below. A cancelled deploy
# mid-flight is worse than a slow queue -- FIXPLAN §5 risk #1
# (docs/FIXPLAN-gh-actions-systemic-20260707.md). Match on workflow `path`
# (exact, unambiguous) rather than display `name` (can be renamed/localized).
NEVER_CANCEL_PATHS = {
    ".github/workflows/deploy-production.yml",
    ".github/workflows/auto-deploy-dev.yml",
}

all_queued = [r for r in raw_runs if r.get("status", "queued") == "queued"]
runs = [r for r in all_queued if r.get("path") not in NEVER_CANCEL_PATHS]
protected_deploy_count = len(all_queued) - len(runs)
skipped_non_queued = len(raw_runs) - len(all_queued)

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
print(f"safety: deploy workflows excluded from all cancel levers; protected_deploy_queued={protected_deploy_count}")

def run_status(rid):
    out = subprocess.check_output([
        "gh", "api", f"repos/{repo}/actions/runs/{rid}", "--jq", ".status"
    ], stderr=subprocess.STDOUT)
    return out.decode().strip()

def force_cancel_run(rid):
    subprocess.check_output([
        "gh", "api", "-X", "POST", f"repos/{repo}/actions/runs/{rid}/force-cancel"
    ], stderr=subprocess.STDOUT)

# Plain cancel only. POST .../cancel returns 202 but queued runs frequently
# STAY queued (observed live 2026-07-07 on runs 28884233335 / 28892581952);
# the force-cancel endpoint is what actually transitions them. Rather than
# poll status per run (1-2 extra API calls x N cancels — a real contributor
# to the secondary throttle, bead jleechan-me9), callers batch-verify: the
# tail pass re-lists queued runs ONCE after all cancels and force-cancels
# only the ids that survived. The rare zombie-delete path keeps its own
# per-run poll (delete requires the transition to have completed).
def cancel_run(rid):
    subprocess.check_output([
        "gh", "api", "-X", "POST", f"repos/{repo}/actions/runs/{rid}/cancel"
    ], stderr=subprocess.STDOUT)

def delete_run(rid):
    # GitHub rejects DELETE on status=queued runs (HTTP 403) — a queued run must
    # first transition to completed/cancelled via the cancel endpoint before
    # gh run delete succeeds. Ignore cancel failures (e.g. already completed);
    # the delete call below surfaces any real problem. Zombies are rare, so a
    # per-run poll + force-cancel here is cheap and keeps delete reliable.
    try:
        cancel_run(rid)
        time.sleep(2)
        if run_status(rid) == "queued":
            force_cancel_run(rid)
            time.sleep(2)
    except subprocess.CalledProcessError:
        pass
    subprocess.check_output(["gh", "run", "delete", str(rid), "-R", repo], stderr=subprocess.STDOUT)

stats = {"zombie_deleted": 0, "zombie_failed": 0, "tail_cancelled": 0, "tail_failed": 0}
stats.update({"superseded_cancelled": 0, "superseded_failed": 0, "tail_force_cancelled": 0})

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
    tail_cancelled_ids = []
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
            tail_cancelled_ids.append(rid)
            stats["tail_cancelled"] += 1
            print(f"cancelled tail {rid} {age_m:.0f}m workflow={name!r} branch={b!r} url={url}")
        except subprocess.CalledProcessError as e:
            stats["tail_failed"] += 1
            print(f"FAIL tail {rid} url={url}: {(e.output or b'').decode()[:160]}")
        time.sleep(0.35)

    # Batched force-cancel verification: ONE re-listing instead of a status
    # poll per cancelled run. Any cancelled id still present as queued did
    # not transition (the 202-but-still-queued behavior) — force-cancel it.
    if tail_cancelled_ids:
        time.sleep(8)
        still_queued = set()
        try:
            page = 1
            while True:
                data = list_queued_page(page)
                batch = data.get("workflow_runs", [])
                still_queued.update(r["id"] for r in batch)
                if len(batch) < 100:
                    break
                page += 1
        except subprocess.CalledProcessError:
            still_queued = None  # verification listing throttled; skip quietly
        if still_queued is None:
            print("force-cancel verification skipped: re-listing rate-limited")
        else:
            stuck = [rid for rid in tail_cancelled_ids if rid in still_queued]
            for rid in stuck:
                try:
                    force_cancel_run(rid)
                    stats["tail_force_cancelled"] += 1
                    print(f"force-cancelled stuck tail {rid} (survived plain cancel)")
                except subprocess.CalledProcessError as e:
                    stats["tail_failed"] += 1
                    print(f"FAIL force-cancel {rid}: {(e.output or b'').decode()[:120]}")
                time.sleep(0.35)

print("summary:", stats)
if stats["zombie_failed"] or stats["superseded_failed"] or stats["tail_failed"]:
    sys.exit(1)
PY
