import datetime
import json
import os
import subprocess
import sys
import time

repo = os.environ["QUEUE_REPO"]
min_pr_age_hours = float(os.environ["MIN_PR_AGE_HOURS"])
trim_drafts = os.environ.get("TRIM_DRAFTS", "1") == "1"
trim_superseded = os.environ.get("TRIM_SUPERSEDED", "1") == "1"
dry = os.environ.get("DRY_RUN") == "1"
verify_wait_s = float(os.environ.get("CANCEL_VERIFY_WAIT_S", "10"))

NEVER_CANCEL_PATHS = {
    ".github/workflows/deploy-production.yml",
    ".github/workflows/auto-deploy-dev.yml",
}

def gh_cmd(args):
    cmd = ["gh"] + args
    return subprocess.check_output(cmd, stderr=subprocess.STDOUT)

def gh_json(args):
    raw = gh_cmd(args)
    return json.loads(raw) if raw.strip() else None

def is_rate_limited(err):
    out = (err.output or b"").lower()
    return b"rate limit" in out or b"secondary rate limit" in out or b"403" in out

def list_queued_runs():
    runs = []
    page = 1
    while page <= 3:
        try:
            data = gh_json([
                "api", f"repos/{repo}/actions/runs?status=queued&per_page=100&page={page}"
            ])
        except subprocess.CalledProcessError as e:
            if is_rate_limited(e):
                print("rate-limited listing /actions/runs; backing off 60s and retrying once")
                time.sleep(60)
                try:
                    data = gh_json([
                        "api", f"repos/{repo}/actions/runs?status=queued&per_page=100&page={page}"
                    ])
                except subprocess.CalledProcessError as e2:
                    if is_rate_limited(e2):
                        print("SKIP: /actions/runs rate-limited after backoff — skipping repo tick")
                        return []
                    raise
            else:
                raise
        batch = data.get("workflow_runs", []) if data else []
        if not batch:
            break
        runs.extend(batch)
        if len(batch) < 100:
            break
        page += 1
    return runs

def get_remote_head(branch):
    try:
        out = subprocess.check_output([
            "git", "ls-remote", f"https://github.com/{repo}.git", f"refs/heads/{branch}"
        ], stderr=subprocess.DEVNULL, text=True).strip()
        if out:
            return out.split()[0]
    except Exception:
        pass
    return None

def get_commit_date(sha):
    try:
        out = gh_cmd(["api", f"repos/{repo}/commits/{sha}", "--jq", ".commit.committer.date"]).decode().strip()
        if out:
            return datetime.datetime.fromisoformat(out.replace("Z", "+00:00"))
    except Exception:
        pass
    return None

def run_status(rid):
    out = gh_cmd(["api", f"repos/{repo}/actions/runs/{rid}", "--jq", ".status"]).decode().strip()
    return out

def cancel_run(rid):
    gh_cmd(["api", "-X", "POST", f"repos/{repo}/actions/runs/{rid}/cancel"])

def force_cancel_run(rid):
    gh_cmd(["api", "-X", "POST", f"repos/{repo}/actions/runs/{rid}/force-cancel"])

def verify_and_force_cancel(rid):
    if verify_wait_s > 0:
        time.sleep(verify_wait_s)
    try:
        status = run_status(rid)
    except subprocess.CalledProcessError:
        return False
    if status == "queued":
        force_cancel_run(rid)
        return True
    return False

now = datetime.datetime.now(datetime.timezone.utc)
all_queued = list_queued_runs()
eligible_runs = [r for r in all_queued if r.get("path") not in NEVER_CANCEL_PATHS]

print(f"scan: repo={repo} queued_total={len(all_queued)} eligible={len(eligible_runs)} mode={'dry-run' if dry else 'apply'}")

if not eligible_runs:
    sys.exit(0)

# Pre-fetch PR and remote HEAD info per branch to minimize API calls
branches = sorted(list(set(r.get("head_branch") for r in eligible_runs if r.get("head_branch"))))
branch_info = {}
commit_dates = {}

for b in branches:
    remote_head = get_remote_head(b)
    pr_data = None
    if b not in ("main", "master"):
        try:
            prs = gh_json(["pr", "list", "--repo", repo, "--head", b, "--state", "open", "--json", "number,title,isDraft,updatedAt,headRefOid"])
            if prs:
                pr_data = prs[0]
        except Exception:
            pass
    branch_info[b] = {
        "remote_head": remote_head,
        "pr": pr_data,
    }

# Find newest queued ios-testflight run on main/master to avoid cancelling the current candidate
newest_testflight_main_id = {}
for r in eligible_runs:
    if (r.get("path") == ".github/workflows/ios-testflight.yml" and
            r.get("head_branch") in ("main", "master") and
            r.get("event", "push") == "push"):
        hb = r.get("head_branch")
        cur_max = newest_testflight_main_id.get(hb, -1)
        if r.get("id", 0) > cur_max:
            newest_testflight_main_id[hb] = r.get("id", 0)

candidates = []

for r in eligible_runs:
    b = r.get("head_branch")
    if not b:
        continue
    info = branch_info.get(b)
    if not info:
        continue

    run_sha = r.get("head_sha")
    remote_head = info["remote_head"]
    pr = info["pr"]

    # Special case: iOS TestFlight runs on main/master
    if r.get("path") == ".github/workflows/ios-testflight.yml" and b in ("main", "master"):
        if trim_superseded and r.get("event", "push") == "push":
            max_id = newest_testflight_main_id.get(b)
            is_superseded_sha = bool(remote_head and run_sha and run_sha != remote_head)
            is_superseded_queue = bool(max_id and r.get("id", 0) < max_id)
            if is_superseded_sha or is_superseded_queue:
                reasons = []
                if is_superseded_sha:
                    reasons.append(f"run_sha={run_sha[:8]} != remote_head={remote_head[:8]}")
                if is_superseded_queue:
                    reasons.append(f"newer_queued_id={max_id}")
                candidates.append((r, f"superseded_main_build ({', '.join(reasons)})"))
        continue

    if b in ("main", "master"):
        continue

    # Reason 1: Superseded commit on branch
    if trim_superseded and remote_head and run_sha and run_sha != remote_head:
        candidates.append((r, f"superseded_commit (run_sha={run_sha[:8]} != branch_head={remote_head[:8]})"))
        continue

    if not pr:
        continue

    # Reason 2: Draft PR
    if trim_drafts and pr.get("isDraft"):
        candidates.append((r, f"draft_pr (PR #{pr['number']} is draft)"))
        continue

    # Reason 3: PR not modified in last MIN_PR_AGE_HOURS
    pr_updated_str = pr.get("updatedAt", "")
    pr_updated_dt = datetime.datetime.fromisoformat(pr_updated_str.replace("Z", "+00:00")) if pr_updated_str else None
    
    # Check commit committer date
    if run_sha not in commit_dates:
        commit_dates[run_sha] = get_commit_date(run_sha)
    commit_dt = commit_dates.get(run_sha)

    # Consider unmodified if commit date is >= min_pr_age_hours old
    ref_dt = commit_dt or pr_updated_dt
    if ref_dt:
        age_hours = (now - ref_dt).total_seconds() / 3600.0
        if age_hours >= min_pr_age_hours:
            candidates.append((r, f"unmodified_pr (PR #{pr['number']} last code/update was {age_hours:.1f}h ago >= {min_pr_age_hours:g}h)"))
            continue

print(f"candidates_identified: {len(candidates)}")

cancelled = 0
failed = 0
skipped_non_queued = 0

for r, reason in candidates:
    rid = r["id"]
    name = r.get("name") or f"id={rid}"
    b = r.get("head_branch")
    url = r.get("html_url") or f"https://github.com/{repo}/actions/runs/{rid}"

    if dry:
        print(f"[dry-run] would cancel {rid} ({name}) on branch '{b}': {reason} — {url}")
        continue

    # Recheck status to guard against race with worker pickup
    try:
        cur_status = run_status(rid)
        if cur_status != "queued":
            skipped_non_queued += 1
            print(f"skipped {rid}: no longer queued (now {cur_status})")
            continue
    except subprocess.CalledProcessError:
        pass

    try:
        cancel_run(rid)
        cancelled += 1
        print(f"cancelled {rid} ({name}) on branch '{b}': {reason} — {url}")
        try:
            if verify_and_force_cancel(rid):
                print(f"force-cancelled {rid}: survived plain cancel")
        except Exception as e:
            print(f"verify/force-cancel notice for {rid}: {e}")
    except subprocess.CalledProcessError as e:
        failed += 1
        print(f"FAIL cancel {rid}: {(e.output or b'').decode()[:120]}")
    time.sleep(0.35)

print(f"summary: candidates={len(candidates)} cancelled={cancelled} failed={failed} skipped_non_queued={skipped_non_queued} dry_run={dry}")
if failed:
    sys.exit(1)
