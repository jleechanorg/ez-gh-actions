# Collector follow-up verification

Base: `37d33caf7c4314cdd3cefdda9f6538f3dc831de2` (merged #264).

## What changed

- Discovery visits each configured repo's active run statuses, with explicit pages and stable `total_count` checks for runs and latest-attempt jobs. It never filters by workflow creation date.
- Only queued jobs with affirmative self-hosted or established fleet labels count. GitHub-hosted labels are excluded. Unknown labels, invalid dates, missing URLs and incomplete responses mark coverage incomplete rather than becoming a healthy queue; other affirmative positive jobs are retained.
- Retains job ID, URL, run ID/attempt, labels, creation/start times and wait. Waiting age comes from job creation time, not running duration. A queued job's pre-populated `started_at` is retained rather than silently treated as a running job.
- Run/API/time budgets stop the verdict. No partial result clears existing breach observations. Known positive job samples advance their own sustain even when other coverage is incomplete. Complete absent/below-threshold jobs reset their observations.
- Global paging cooldown plus per-job sustain and cooldown retain prior successful delivery time only after the log write succeeds. A new job does not inherit another job's sustain.
- INFO heartbeat uses the existing log, outside the existing ERROR paging filter. A separate atomic local heartbeat records incomplete discovery or failed writes even when the remote path cannot receive it.
- Defaults include backend, frontend and the existing runner repo. Explicit overrides remain supported. No cron, policy or channel change is included.

## Checks

- Existing shell regression suite: 41 passed.
- New hermetic Python discovery/integration suite: 31 passed.
- New suite is wired into the existing CI workflow.
- Shell syntax, Python compile and diff whitespace checks passed.
- No live queue census, GCP write or test notification was run for this patch.

## Limits and review gates

This is code preparation, not an activated monitor. Merge, deployment and removing the existing queue-only suppression are separate decisions. It does not prove SMS delivery.

The default inspection budget is still 60 distinct active runs and 200 API calls per cycle, bounded by 240 seconds. API calls and API time have equal per-repo shares; half is reserved for job inspection. Candidate runs are discovered before inspection, then sorted queued-status-first and oldest-first within status in each repo and inspected round-robin across repos. A fleet with more active runs will report TRUNCATED, not a queue verdict. The activation dry run must establish complete coverage within the approved API/time budget. Increasing the budget is not proof of coverage. There is no cache that guesses old runs are safe to skip.

Heartbeat emission alone does not create an independent missing-heartbeat alert policy. The durable local record and remote INFO record expose the signal for existing monitoring; liveness alert routing needs separate validation.

Unknown custom runner labels intentionally produce BLIND. The current affirmative set is self-hosted, ezgha, self-hosted-linux/macos, self-hosted-* and ez-runner-/ez-mac-runner-* labels. Review must confirm that set against the target workflows before activation.

The discovery list is not a transaction across GitHub. Stable counts detect some pagination movement, but job state can change immediately after any read. Alert evidence preserves the observed status and sample time. Small future timestamps within five minutes are clamped to zero age; larger future timestamps remain unknown. No completed or running job is intentionally included.
