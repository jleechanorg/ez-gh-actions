#!/bin/bash
# GitHub's hook dispatcher supports shell scripts, not Python scripts. Keep
# the hook outside the runner installation, use the image's trusted Python,
# and bound this synchronous cleanup so it cannot indefinitely delay a job.
cd / || exit 0
if ! /usr/bin/timeout --kill-after=5s 60s /usr/bin/python3 -I /usr/local/libexec/ezgha/runner-post-job-workspace-prune.py; then
    printf '%s\n' 'ezgha post-job cleanup: partial (cleanup failed or exceeded its time budget)'
fi
# Cleanup failure must not change the result of the workflow that just ran.
exit 0
