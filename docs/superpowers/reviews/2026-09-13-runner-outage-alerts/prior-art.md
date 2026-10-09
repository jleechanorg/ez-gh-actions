# ezgha Mac + Linux outage alerts — prior-art search

Date: 2026-09-13.  Read-only `/history` sparse search and `/ms` memory search.
No secret values or webhook/email addresses are recorded here.

## Confirmed historical prior art

1. **A deterministic cross-platform fleet alerter already existed in history.**
   Git commits dated 2026-08-01 are `5ddc5f7` (alert + hysteresis), `3ac2f4a`
   (systemd timer/service), and `ae61e27` (launchd plist).  The later 2026-08-06
   GH#106 series is `4b9c150`, `a0697fd`, `3728ca1`, `e5817fe`.
   The commit file inventory names `scripts/ezgha-fleet-alert.sh`,
   `src/alert.rs`, `systemd/ezgha-fleet-alert.service`,
   `systemd/ezgha-fleet-alert.timer`,
   `launchd/org.jleechanorg.ezgha-fleet-alert.plist.template`,
   `launchd/README-ezgha-fleet-alert.md`, and alert tests.

2. **The recorded design is deterministic, not an AI polling loop.**
   `/Users/jleechan/roadmap/nextsteps-2026-08-01-ezgha-mac-fleet-recovery-and-3-post-merge-defects.md`
   calls for a five-minute poll of doctor verdict, daemon CRITICAL stderr, and
   container count, with five-minute AND one-hour hysteresis; it names a Slack
   webhook as a stretch goal and `/var/log/ezgha-alerts.log` as default output.

3. **Mac outage precedent shows that a deployed agent can silently point to stale
   code.**
   `/Users/jleechan/.claude/projects/-Users-jleechan-projects-other-ez-gh-actions/memory/feedback_2026-07-29_plist_fix_landed_not_deployed.md:11-21`
   records that the live launchd plist was not regenerated, leaving a watchdog
   to restart-loop for roughly five hours.  It requires regenerating the unit
   and verifying its running ProgramArguments.

4. **A later Mac incident generated silent errors that the historical alerter did
   not observe.**
   `/Users/jleechan/.claude/projects/-Users-jleechan-projects-other-ez-gh-actions/memory/feedback_2026-08-25_harness_fix_presence_vs_behavioral.md:11-20`
   says the 2026-08-20 outage followed 311+ silent rebuild failures over 19
   days, and explicitly says `ezgha-fleet-alert.sh` only watched daemon-stderr
   reclaim patterns.  It recommends wiring new sentinel/error paths to
   `alerts.jsonl` or Slack and exercising them behaviorally.

5. **The existing alerter also had documented signal gaps.**
   `/Users/jleechan/.claude/projects/-Users-jleechan-projects-other-ez-gh-actions/memory/feedback_2026-08-01_advice_synthesis_post_closure.md:21-32`
   lists missed classes: configured-count refill rate, orphan Listener/Worker,
   image-missing warning string, and job-outcome rate.  It identifies the first
   real degraded event as the alerter's first true live test.

6. **Healthy-idle and failed are distinct states.**
   `/Users/jleechan/roadmap/nextsteps-2026-08-01-ezgha-mac-fleet-recovery-and-3-post-merge-defects.md:54-69`
   defines Listener-only as healthy idle, Worker as busy, and sustained absence
   of both as real CRITICAL.  This avoids alerting simply because no job is
   running.

7. **Hermes history contains dated evidence that launchd fleet-alert artifacts
   were present during the 2026-08-05 Mac troubleshooting.**
   `~/.hermes/state.db` FTS result, 2026-08-05 22:43:49 local time, session
   "Debugging stalled PR queue", includes
   `org.jleechanorg.ezgha-fleet-alert.plist`; the nearby 22:43:58 result reports
   respawns of Mac slots b-3 through b-6.

## Candidate existing handoff/design sources

- `/Users/jleechan/roadmap/nextsteps-2026-08-01-ezgha-mac-fleet-recovery-and-3-post-merge-defects.md`
- `/Users/jleechan/roadmap/nextsteps-2026-07-10-ezgha-fleet-hardening.md`
- `/Users/jleechan/roadmap/nextsteps-2026-07-04-ezgha-fleet-handoff.md`
- `launchd/README-ezgha-fleet-alert.md` (historically changed artifact)
- `evidence/deadman-alert-pipeline-20260708/README.md` (historically changed artifact)

## Search coverage and gaps

- `/history`: ran bounded five-source helper for `ezgha` and `fleet alert`
  (Claude, Codex, Hermes, agy, Cursor).  The `fleet alert` match was found in
  Claude history dated 2026-08-21 and Hermes historic Slack transcripts dated
  2026-08-05.  The helper returned no useful agy or Cursor matches.  Codex had
  no directly relevant bounded match.
- `/ms`: searched roadmap, repo-scoped Claude memories, Hermes FTS (read-only),
  Hermes index/briefings, OpenClaw index, and wiki paths.  Strong matches were
  roadmap and repo-scoped Claude memories.  No direct matching OpenClaw index,
  Hermes briefing/index, or wiki result was established in this bounded pass.
- Slack connector search was unavailable in this agent session; therefore this
  report does not claim a live Slack search.  Hermes's stored Slack transcripts
  are historical evidence only.
- This is prior-art discovery, not a live assertion that any launchd/systemd
  unit, Slack endpoint, or email delivery currently works.

## Parent live Slack fallback (2026-09-13)

The message-search method is absent, but the Slack connector is available: channel listing and history reads succeeded. Parent sampled the latest 20 messages each in #mcp-mail, #worldai-alerts, #jleechanclaw, #agent-digest, and Jeffrey's DM. No relevant alert-delivery proof appeared. One #agent-digest excerpt references prior Mac/Linux runner repository work, without new notification evidence. This corrects the earlier lane-level connector-unavailable statement. This bounded five-channel sample is not an exhaustive workspace search and does not prove no message was ever sent. No Slack messages were posted or marked read.
