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
    seen_runs = set()
    repos = env.get('ALERT_REPOS', 'jleechanorg/worldarchitect.ai jleechanorg/worldai_frontend jleechanorg/ez-gh-actions').split()
    if not repos:
        raise ValueError('empty repository scope')

    def api(path):
        nonlocal calls
        if calls >= max_calls or clock() >= deadline:
            raise OverflowError('API budget or cycle deadline exhausted')
        calls += 1
        if call:
            return call(path)
        timeout = min(float(env.get('GH_CALL_TIMEOUT_SEC', '30')), max(.01, deadline - clock()))
        result = subprocess.run([env.get('GH_BIN', 'gh'), 'api', path], capture_output=True, text=True, timeout=timeout, check=True)
        return json.loads(result.stdout)

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
                raise ValueError('pagination changed during collection')
            total = count
            for item in items:
                ident = item.get('id')
                if not isinstance(ident, int) or ident in seen:
                    raise ValueError('missing or repeated page identity')
                seen.add(ident)
                yield item
            if len(seen) == total:
                return
            if len(seen) > total or not items or len(items) < 100:
                raise ValueError('incomplete pagination')
            page += 1

    for repo in repos:
        for status in ('queued', 'in_progress', 'waiting', 'pending', 'requested'):
            for run in pages(f'repos/{repo}/actions/runs?status={status}', 'workflow_runs'):
                key = (repo, run['id'])
                if key in seen_runs:
                    continue
                seen_runs.add(key)
                if runs_checked >= max_runs:
                    raise OverflowError('run inspection cap exhausted')
                runs_checked += 1
                # No run-created_at cutoff: reruns can have fresh jobs in old containers.
                for job in pages(f'repos/{repo}/actions/runs/{run["id"]}/jobs?filter=latest', 'jobs'):
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
                    if age < 0 or not isinstance(url, str) or not url.startswith(f'https://github.com/{repo}/actions/runs/'):
                        raise ValueError('invalid queued-job time or URL')
                    jobkey = f'{repo}:{job["id"]}'
                    if jobkey in jobs:
                        raise ValueError('duplicate job identity')
                    jobs[jobkey] = dict(key=jobkey, id=job['id'], repo=repo, run_id=run['id'], run_attempt=run.get('run_attempt'), status='queued', created_at=job['created_at'], started_at=job.get('started_at'), html_url=url, labels=job['labels'], wait_min=int(age // 60))
    return dict(complete=True, jobs=sorted(jobs.values(), key=lambda j: (-j['wait_min'], j['key'])), excluded=excluded, runs_checked=runs_checked, api_calls=calls, sampled_at=now)


if __name__ == '__main__':
    try:
        print(json.dumps(discover()))
    except Exception as exc:
        print(json.dumps(dict(complete=False, jobs=[], reason=type(exc).__name__ + ': ' + str(exc)[:300])))
        sys.exit(1)
