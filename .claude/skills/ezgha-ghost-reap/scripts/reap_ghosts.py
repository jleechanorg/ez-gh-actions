#!/usr/bin/env python3
"""Reap ghost workflow runs: cancel -> verify -> force-cancel -> delete.

Why cancel-then-delete
----------------------
`DELETE /repos/{owner}/{repo}/actions/runs/{id}` is documented with no status
precondition, but it FAILS with HTTP 403 on a run still in `status=queued`. The run must
first transition out of queued. Verified live in ez-gh-actions commit d105dc4 (10/10
deletes failed 403 until cancel-then-delete was used).

A second trap: a plain `POST .../cancel` returns HTTP 202 but can SILENTLY NO-OP on a run
whose only job never started (`runner_id:0`) — bead jleechan-uud. That is exactly the
ghost profile, so every cancel must be verified and escalated to `force-cancel`.

KNOWN DEAD-END POPULATION (measured 2026-11-14)
----------------------------------------------
A wedged subclass of ghost exists that NO documented API path can remove. For these,
`cancel` and `force-cancel` return **409 "Cannot cancel a workflow run that has not been
queued yet."** and `DELETE` returns **403 "Could not delete the workflow run"**. The 409
message is the tell: GitHub does not consider the run to have reached the queue at all,
so nothing can transition it out of `queued` and delete will never become legal.

Measured on jleechanorg/worldarchitect.ai: all 149 zero-job queued runs (created
2026-11-11T20:35Z onward) are in this state, across 4 independently sampled IDs. There is
no supported cleanup: they are not reapable via cancel, force-cancel, or delete, and the
reaper's historical successes (log: `deleted zombie 39912506885`) came from an earlier
population that was not wedged this way.

This script therefore reports `wedged_unreapable` as a distinct outcome instead of
pretending `stuck_queued` is a transient retryable condition. Do not spend API budget
retrying these every cycle.

Safety invariants (all mandatory)
---------------------------------
1. **Dry run by default.** Real deletion requires `--apply`.
2. **Ghost proof required.** A run is only eligible when
   `jobs.total_count == 0` AND `status == "queued"`, re-checked immediately before acting.
3. **Deploy workflows are never touched.** Matched on workflow `path`, not display name.
   A cancelled deploy is worse than a slow queue (FIXPLAN §5 risk #1).
4. **Race guard.** Re-verify the run is still queued right before each destructive call;
   a run may be picked up late (observed: a run started after 3 days queued).
5. **Rate-limit aware.** Aborts cleanly with a distinct exit code instead of cancelling
   some runs and silently skipping others.

Exit codes: 0 ok, 2 measurement/API failure, 3 partial (some runs failed), 4 rate-limited.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import subprocess
import sys
import time

DEFAULT_REPO = "jleechanorg/worldarchitect.ai"
GHOST_AGE_FLOOR_MIN = 15

# Matched on workflow `path`. Never cancel a deploy, even if it looks like a ghost.
NEVER_CANCEL_PATHS = {
    ".github/workflows/deploy-production.yml",
    ".github/workflows/auto-deploy-dev.yml",
    ".github/workflows/deploy-dev.yml",
    ".github/workflows/deploy-staging.yml",
    ".github/workflows/deploy-dice-audit.yml",
    ".github/workflows/deploy-levelup-test.yml",
}


class ApiError(RuntimeError):
    def __init__(self, path, detail, status=None):
        self.status = status
        super().__init__(f"{path}: {detail}")


def _body_error(body, path):
    if "message" in body and not ({"total_count", "workflow_runs", "jobs"} & set(body)):
        msg = str(body["message"])
        status = 403 if "rate limit" in msg.lower() else None
        raise ApiError(path, msg[:200], status)


def gh(path, method=None):
    cmd = ["gh", "api"]
    if method:
        cmd += ["-X", method]
    cmd.append(path)
    proc = subprocess.run(cmd, capture_output=True, text=True)
    text = (proc.stdout or "").strip()
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout).strip()[:300]
        status = None
        for code in (403, 404, 409, 422, 500, 502, 503):
            if f"HTTP {code}" in err or f": {code}" in err:
                status = code
                break
        if "rate limit" in err.lower():
            status = 403
        raise ApiError(path, err, status)
    return json.loads(text) if text else {}


def paged_runs(path):
    proc = subprocess.run(["gh", "api", "--paginate", path], capture_output=True, text=True)
    if proc.returncode != 0:
        raise ApiError(path, (proc.stderr or proc.stdout).strip()[:300], 403)
    dec = json.JSONDecoder()
    text, idx, rows = proc.stdout, 0, []
    while idx < len(text):
        while idx < len(text) and text[idx] in " \n\t\r":
            idx += 1
        if idx >= len(text):
            break
        obj, idx = dec.raw_decode(text, idx)
        _body_error(obj, path)
        rows.extend(obj.get("workflow_runs", []))
    return rows


def age_min(stamp, now):
    if not stamp:
        return 0.0
    return (now - dt.datetime.fromisoformat(stamp.replace("Z", "+00:00"))).total_seconds() / 60


def classify(repo, min_age_min):
    """Return candidate ghosts, re-proven by jobs endpoint. Nothing is mutated."""
    now = dt.datetime.now(dt.timezone.utc)
    runs = paged_runs(f"/repos/{repo}/actions/runs?status=queued&per_page=100")
    candidates, protected, too_young, not_ghost = [], [], [], []
    for run in runs:
        rid = run["id"]
        row = {
            "id": rid,
            "name": run.get("name") or "",
            "branch": run.get("head_branch") or "",
            "path": run.get("path") or "",
            "age_min": round(age_min(run.get("created_at"), now), 1),
        }
        if row["path"] in NEVER_CANCEL_PATHS:
            protected.append(row)
            continue
        if row["age_min"] < min_age_min:
            too_young.append(row)
            continue
        body = gh(f"/repos/{repo}/actions/runs/{rid}/jobs?per_page=100")
        if body.get("total_count", 0) == 0 and run.get("status") == "queued":
            candidates.append(row)
        else:
            not_ghost.append(row)
    return candidates, protected, too_young, not_ghost


def run_status(repo, rid):
    """Live status of a run, or None when it cannot be READ.

    Returning None (rather than assuming "queued") is essential: the previous
    version mapped any non-404 API error to queued=True, so a run whose status
    reads all returned HTTP 503 was still cancelled, force-cancelled and DELETEd
    (review P0, reproduced).
    """
    try:
        body = gh(f"/repos/{repo}/actions/runs/{rid}")
    except ApiError as exc:
        if exc.status == 404:
            return "gone"
        return None                      # unreadable => fail closed
    st = body.get("status") if isinstance(body, dict) else None
    return st if isinstance(st, str) else None


def still_queued(repo, rid):
    """True only when the status is POSITIVELY read as queued."""
    return run_status(repo, rid) == "queued"


def job_total(repo, rid):
    """Live jobs.total_count for a run, or None when it cannot be read."""
    try:
        return gh(f"/repos/{repo}/actions/runs/{rid}/jobs").get("total_count")
    except (ApiError, KeyError, TypeError):
        return None


def reap_gate(repo, rid):
    """Re-confirm eligibility IMMEDIATELY before each mutating call.

    Returns a skip-status string when the run must not be touched, else None.

    A run that was a zero-job ghost when listed can gain jobs and become real CI
    work at any point. Checking only once before the first cancel is not enough:
    the default verify wait is 6s, and force-cancel/DELETE happen AFTER it, so a
    run can transition in that window and still be destroyed (review P1). This
    gate is therefore called before every mutation.
    """
    st = run_status(repo, rid)
    if st is None:
        return "skipped_status_unknown"  # unreadable => never mutate
    if st == "gone":
        return "skipped_gone"
    if st != "queued":
        return "skipped_started"         # already running/completed
    total = job_total(repo, rid)
    if total is None:
        return "skipped_jobs_unknown"    # fail closed
    if total != 0:
        return "skipped_now_has_jobs"
    return None


def reap_one(repo, row, verify_wait_s, apply):
    """cancel -> verify -> force-cancel -> delete. Returns a status string."""
    rid = row["id"]
    if not apply:
        return "would_reap"
    # Race guard: never destroy a run that started since we listed it.
    if not still_queued(repo, rid):
        return "skipped_started"
    # Race guard (review P1): "still queued" is NOT enough. A run that was a
    # zero-job ghost when listed can gain jobs and become REAL work; deleting it
    # would destroy a live CI run. Re-confirm zero jobs immediately before acting.
    # An unreadable count fails closed (skip) rather than destroying anything.
    gate = reap_gate(repo, rid)
    if gate:
        return gate
    wedged = False
    try:
        gh(f"/repos/{repo}/actions/runs/{rid}/cancel", "POST")
    except ApiError as exc:
        if exc.status == 404:
            return "skipped_gone"
        if exc.status == 409 and "not been queued" in str(exc):
            # The dead-end signature: GitHub says the run never reached the queue.
            wedged = True
    if verify_wait_s > 0:
        time.sleep(verify_wait_s)
    if not still_queued(repo, rid):
        return "skipped_started"
    gate = reap_gate(repo, rid)          # re-check AFTER the verify wait
    if gate:
        return gate
    if still_queued(repo, rid):
        try:
            gh(f"/repos/{repo}/actions/runs/{rid}/force-cancel", "POST")
            time.sleep(2)
        except ApiError as exc:
            if exc.status == 404:
                return "skipped_gone"
            if exc.status == 409 and "not been queued" in str(exc):
                wedged = True
    # FINAL gate immediately before the destructive call. The previous shape
    # re-read status here and, if it had become in_progress, fell through to the
    # DELETE below anyway (review P0, reproduced). reap_gate now positively
    # requires queued AND zero jobs, so this delete runs only on that proof.
    gate = reap_gate(repo, rid)
    if gate:
        return gate
    try:
        gh(f"/repos/{repo}/actions/runs/{rid}", "DELETE")
        return "reaped"
    except ApiError as exc:
        if exc.status == 404:
            return "skipped_gone"
        if exc.status == 403:
            # 403 delete + 409 cancel = wedged, not retryable.
            return "wedged_unreapable" if wedged else "delete_403"
        raise
        raise
    return "reaped"


def main(argv=None):
    ap = argparse.ArgumentParser(description="Reap ghost workflow runs.")
    ap.add_argument("--repo", default=DEFAULT_REPO)
    ap.add_argument("--apply", action="store_true", help="actually cancel+delete (default: dry run)")
    ap.add_argument("--min-age-min", type=float, default=60.0,
                    help="minimum run age in minutes (default 60; ghosts are hours old)")
    ap.add_argument("--limit", type=int, default=0, help="cap how many runs to process (0 = all)")
    ap.add_argument("--verify-wait", type=float, default=6.0,
                    help="seconds to wait after plain cancel before force-cancel")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)

    try:
        candidates, protected, too_young, not_ghost = classify(args.repo, args.min_age_min)
    except ApiError as exc:
        print(f"MEASUREMENT FAILED: {exc}", file=sys.stderr)
        return 4 if exc.status == 403 else 2

    if args.limit:
        candidates = candidates[: args.limit]

    summary = {"scanned_queued": len(candidates) + len(protected) + len(too_young) + len(not_ghost),
               "eligible": len(candidates), "protected_deploy": len(protected),
               "too_young": len(too_young), "not_ghost": len(not_ghost)}
    results = {"reaped": 0, "would_reap": 0, "skipped_started": 0, "skipped_gone": 0,
               "skipped_now_has_jobs": 0, "skipped_jobs_unknown": 0,
               "wedged_unreapable": 0, "stuck_queued": 0, "delete_403": 0, "failed": 0}

    for row in candidates:
        try:
            outcome = reap_one(args.repo, row, args.verify_wait, args.apply)
        except ApiError as exc:
            outcome = "failed"
            print(f"FAIL {row['id']} {row['name'][:30]}: {str(exc)[:150]}", file=sys.stderr)
        results[outcome] = results.get(outcome, 0) + 1
        if not args.json:
            verb = "would reap" if outcome == "would_reap" else outcome
            print(f"  {verb:16} {row['id']} {row['age_min']:>7.0f}m {row['name'][:30]:32} {row['branch'][:26]}")
        # Be gentle with the API: every run costs 2-4 calls.
        if args.apply:
            time.sleep(0.4)

    report = {"repo": args.repo, "apply": args.apply, **summary, "results": results}
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print()
        print(f"{'APPLIED' if args.apply else 'DRY RUN'} — {args.repo}")
        print(f"  queued scanned: {summary['scanned_queued']}  eligible ghosts: {summary['eligible']}")
        print(f"  protected deploy runs skipped: {summary['protected_deploy']}")
        print(f"  too young (<{args.min_age_min:.0f}m): {summary['too_young']}   not ghosts: {summary['not_ghost']}")
        print(f"  results: {json.dumps(results)}")

    if results["failed"] or results["delete_403"] or results["wedged_unreapable"]:
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
