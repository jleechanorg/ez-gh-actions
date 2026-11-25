#!/usr/bin/env python3
"""Bounded, fail-closed GitHub queued-job discovery. No notification writes."""
import datetime as dt
import json
import os
import subprocess
import sys
import time


def discover(env=os.environ, call=None, clock=time.monotonic):
    now = int(env.get('QUEUE_NOW_EPOCH', time.time()))
    deadline = clock() + int(env.get('MAX_RUN_SEC', '240'))
    max_runs = int(env.get('MAX_RUN_CHECKS', '60'))
    max_calls = int(env.get('MAX_API_CALLS', '200'))
    calls = 0
    runs_checked = 0
    excluded = 0
    jobs = {}
    issues = []
    unknown_jobs = 0
    repos = env.get('ALERT_REPOS', 'jleechanorg/worldarchitect.ai jleechanorg/worldai_frontend jleechanorg/ez-gh-actions').split()
    if not repos:
        raise ValueError('empty repository scope')

    repo_calls = {repo: 0 for repo in repos}
    repo_quota = max_calls // len(repos)
    repo_elapsed = {repo: 0.0 for repo in repos}
    repo_seconds = int(env.get('MAX_RUN_SEC', '240')) / len(repos)
    discovery_phase = True

    def api(path):
        nonlocal calls
        repo = path.split('/actions/', 1)[0].removeprefix('repos/')
        limit = max(1, repo_quota // 2) if discovery_phase else repo_quota
        time_left = (repo_seconds / 2 if discovery_phase else repo_seconds) - repo_elapsed[repo]
        if time_left <= 0:
            raise OverflowError('repository fair time budget exhausted')
        if repo_calls[repo] >= limit:
            raise OverflowError('repository fair API budget exhausted')
        if calls >= max_calls or clock() >= deadline:
            raise OverflowError('API budget or cycle deadline exhausted')
        calls += 1
        repo_calls[repo] += 1
        started = clock()
        try:
            if call:
                return call(path)
            timeout = min(float(env.get('GH_CALL_TIMEOUT_SEC', '30')), time_left, max(.01, deadline - clock()))
            result = subprocess.run([env.get('GH_BIN', 'gh'), 'api', path], capture_output=True, text=True, timeout=timeout, check=True)
            return json.loads(result.stdout)
        finally:
            repo_elapsed[repo] += clock() - started

    def pages(path, key):
        page = 1
        seen = set()
        total = None
        while True:
            data = api(f'{path}&per_page=100&page={page}')
            items = data.get(key)
            count = data.get('total_count')
            if not isinstance(items, list) or not isinstance(count, int) or count < 0:
                raise ValueError('missing list or total_count')
            if total is not None and count != total:
                issues.append('pagination count changed during collection')
            total = count
            for item in items:
                ident = item.get('id')
                if not isinstance(ident, int):
                    raise ValueError('missing page identity')
                if ident in seen:
                    issues.append('duplicate identity across mutable pages')
                    continue
                seen.add(ident)
                yield item
            if len(seen) == total:
                return
            if len(seen) > total or not items or len(items) < 100:
                raise ValueError('incomplete pagination')
            page += 1

    def inspect(repo, run):
        nonlocal excluded, unknown_jobs
        # No run-created_at cutoff: reruns may create fresh jobs in old containers.
        for job in pages(f'repos/{repo}/actions/runs/{run["id"]}/jobs?filter=latest', 'jobs'):
            try:
                if job.get('status') != 'queued':
                    continue
                labels = job.get('labels')
                if not isinstance(labels, list) or not labels or not all(isinstance(x, str) for x in labels):
                    raise ValueError('queued job has unknown runner labels')
                labels = [x.lower() for x in labels]
                # Custom labels may omit self-hosted; known fleet labels are affirmative evidence.
                is_self_hosted = any(x in ('self-hosted', 'ezgha', 'self-hosted-linux', 'self-hosted-macos') or x.startswith(('ez-runner-', 'ez-mac-runner-', 'self-hosted-')) for x in labels)
                hosted = any(x.startswith(('ubuntu-', 'windows-', 'macos-')) for x in labels)
                if not is_self_hosted:
                    if hosted:
                        excluded += 1
                        continue
                    raise ValueError('unclassified runner labels')
                mac = any(x in ('self-hosted-macos', 'macos', 'ez-mac-runner') or x.startswith('ez-mac-runner-') for x in labels)
                linux = any(x in ('self-hosted-linux', 'linux', 'ez-runner-c') or x.startswith('ez-runner-c-') for x in labels)
                if (env.get('MAC_RUNNER_DISABLED') == '1' and mac) or (env.get('REMOTE_LINUX_DISABLED') == '1' and linux):
                    excluded += 1
                    continue
                # started_at is often pre-populated by GitHub for queued jobs. Preserve it;
                # status, not that timestamp alone, determines whether the job is waiting.
                created = dt.datetime.fromisoformat(job['created_at'].replace('Z', '+00:00'))
                if created.tzinfo is None:
                    raise ValueError('queued-job timestamp has no timezone')
                age = now - created.timestamp()
                url = job.get('html_url')
                if age < -300 or not isinstance(url, str) or not url.startswith(f'https://github.com/{repo}/actions/runs/'):
                    raise ValueError('invalid queued-job time or URL')
                jobkey = f'{repo}:{job["id"]}'
                if jobkey in jobs:
                    issues.append('job observed more than once'); continue
                jobs[jobkey] = dict(key=jobkey, id=job['id'], repo=repo, run_id=run['id'], run_attempt=run.get('run_attempt'), status='queued', created_at=job['created_at'], started_at=job.get('started_at'), html_url=url, labels=job['labels'], wait_min=max(0, int(age // 60)), observed_at=int(time.time()))
            except (ValueError, KeyError, TypeError) as exc:
                unknown_jobs += 1
                issues.append('job unclassified: ' + str(exc))

    candidates = {repo: {} for repo in repos}
    # Enumerate within half of each repo's equal API share, reserving its other
    # half for job evidence. Run age orders work only; it never excludes a run.
    for repo in repos:
        for status in ('queued', 'in_progress', 'waiting', 'pending', 'requested'):
            try:
                for run in pages(f'repos/{repo}/actions/runs?status={status}', 'workflow_runs'):
                    run['_queue_priority'] = 0 if status == 'queued' else 1
                    previous = candidates[repo].get(run['id'])
                    if previous is None or run['_queue_priority'] < previous['_queue_priority']:
                        candidates[repo][run['id']] = run
            except Exception as exc:
                issues.append(repo + ': ' + type(exc).__name__ + ': ' + str(exc)[:160])
                if isinstance(exc, OverflowError):
                    break
    discovery_phase = False
    ordered = {repo: sorted(runs.values(), key=lambda r: (r['_queue_priority'], r.get('created_at', ''), r['id'])) for repo, runs in candidates.items()}
    # Round robin prevents backend load from consuming frontend's run slots.
    # Queued containers go first, then oldest within status priority.
    while any(ordered.values()):
        if runs_checked >= max_runs or clock() >= deadline:
            issues.append('OverflowError: run inspection cap or cycle deadline exhausted')
            break
        for repo in repos:
            if not ordered[repo]:
                continue
            if runs_checked >= max_runs:
                break
            run = ordered[repo].pop(0)
            runs_checked += 1
            try:
                inspect(repo, run)
            except Exception as exc:
                issues.append(repo + ': ' + type(exc).__name__ + ': ' + str(exc)[:160])
                if isinstance(exc, OverflowError):
                    ordered[repo] = []
    return dict(complete=not issues, reason="; ".join(issues[:10]), unknown_jobs=unknown_jobs, issue_count=len(issues), jobs=sorted(jobs.values(), key=lambda j: (-j['wait_min'], j['key'])), excluded=excluded, runs_checked=runs_checked, api_calls=calls, repo_api_calls=repo_calls, sampled_at=now)


if __name__ == '__main__':
    try:
        print(json.dumps(discover()))
    except Exception as exc:
        print(json.dumps(dict(complete=False, jobs=[], reason=type(exc).__name__ + ': ' + str(exc)[:300])))
        sys.exit(1)
