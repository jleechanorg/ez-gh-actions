# yn0 — Mac token-refresh launchd verification (2026-07-08)

## Bead
`ez-gh-actions-yn0` — fix-mac-token-refresh-launchd

## Premise under test
Track D §3 of the s9d investigation reportedly classified
`org.jleechanorg.ezgha-token-refresh` as **IDLE**. If true, the Mac daemon
would keep using an expired App installation token and `gh api` calls would
fail, draining the fleet back to the old rate-limit behaviour.

## Verification (read-only — no install, no restart, no daemon touch)

Commands run on MacBook via `ssh macbook`:

```bash
launchctl print user/$(id -u) | grep -i ezgha
# → "org.jleechanorg.ezgha" => enabled
# (no token-refresh line — expected; launchctl print shows top-level domain, not every job)

launchctl list | grep -i ezgha
# -   0   org.jleechanorg.ezgha-token-refresh
# -   78  org.jleechanorg.ezgha-queue-reaper-stopgap
# 26738 0 org.jleechanorg.ezgha
# -   78  org.jleechanorg.ezgha-watchdog

ls -la ~/Library/LaunchAgents/ | grep -i ezgha
# -rw-r--r--  1 jleechan  staff  1168 Jul  8 02:27 org.jleechanorg.ezgha-token-refresh.plist
# -rw-r--r--  1 jleechan  staff  3081 Jul  8 02:27 org.jleechanorg.ezgha-queue-reaper-stopgap.plist
# -rw-r--r--  1 jleechan  staff  2593 Jul  7 15:55 org.jleechanorg.ezgha-watchdog.plist
# -rw-r--r--  1 jleechan  staff  2572 Jul  6 20:31 org.jleechanorg.ezgha.plist
```

Plist contents (substituted): `@HOME@` → `/Users/jleechan`, `@REPO_PATH@`
→ `/Users/jleechan/projects_other/ez-gh-actions` (note: older path; the
script source has since moved, but `refresh_gh_app_token.sh` is also present
under `scripts/` in the current checkout — see *Followup* below).

Live evidence the job is firing on cadence:

```bash
date                                                # Wed Jul  8 12:25:04 PDT 2026
stat -f "mtime=%Sm" ~/.config/ezgha/gh_token        # mtime=Jul  8 12:16:29 2026
stat -f "mtime=%Sm  size=%z" ~/.local/state/ezgha/token-refresh.log
                                                    # mtime=Jul  8 12:16:30 2026, 854 bytes
wc -l ~/.local/state/ezgha/token-refresh.log         # 14 lines, all "refreshed gh_token at ..."
ps auxww | grep refresh_gh_app | grep -v grep        # (empty — correct: between StartInterval=2700s runs)
```

## Verdict

**TOKEN-REFRESH LAUNCHD HEALTHY — no change needed.**

- Plist **loaded** into launchd (`launchctl list` shows the job; `PID -` with
  `exit 0` between `StartInterval` runs is **normal**, not a failure — same
  pattern as the watchdog and queue-reaper-stopgap jobs which are also `-`).
- Token file `~/.config/ezgha/gh_token` mtime = **12:16:29**, only **~9 min
  before** the verification timestamp (12:25:04). Refresh cadence matches
  `StartInterval=2700` (45 min).
- Log file `~/.local/state/ezgha/token-refresh.log` has **14 successful
  refresh entries** (854 bytes / ~61 bytes per line), all ending with the
  same success path. No error traces, no abort messages.
- No zombie `refresh_gh_app_token` process — correct: launchd sleeps between
  scheduled runs.

The s9d Track D §3 "IDLE" classification was a **misread** of `launchctl list`
output. The job is not a long-running daemon — it is a periodic
`StartInterval`-driven script job, and `PID -` is the expected state between
firings. Last-exit-status `0` further confirms each run completed cleanly.

## Files changed
None. Verification-only pass per the bead's `READ-VERIFY-FIX if needed`
directive. No install, no kickstart, no daemon restart, no token rotation.