---
name: ezgha-doctor
description: Diagnose ez-gh-actions (ezgha) fleet health using the repo's doctor-runner script and named remediation steps. Use when ezgha.service is misbehaving, the runner fleet is degraded, or "GitHub Actions not running" complaints land on ezgha.
---

# ezgha doctor — diagnose + repair ezgha fleet health

> **Use `doctor-runner`, not `doctor.sh` — the latter is broken on docker 27+ (see bead ez-gh-actions-91r + memory ezgha-doctor-idle-bug).** `doctor.sh` is kept only as a back-reference; the new authoritative file is `doctor-runner` (shipped 2026-07-08, with per-slot explicit-work inventory section 10).

This skill drives the **doctor-runner** script that ships at the repo root, plus the named remediation actions the script recommends. Use it whenever the user reports any of:

- "the runners are not up" / "ezgha is broken" / "GitHub Actions isn't taking tasks"
- service showing `failed (Result 'exit-code')`
- journal full of `ensure_count failed (will retry): … runner with the name already exists`
- worldarchitect.ai fleet page shows fewer than 16 `ez-org-runner-*` runners online

## Step 1 — Establish the baseline

```bash
bash "$(git rev-parse --show-toplevel)/doctor-runner"          # health gate, exit 0 = healthy
bash "$(git rev-parse --show-toplevel)/doctor-runner --prove"  # + live canary: dispatch a real job, verify it runs on ez-org-runner-*
```

Read the verdict AND the exit code. `--prove` is the strongest evidence — it
dispatches a fresh `ezgha-selftest` and confirms `runner_name` is
`configured prefix (e.g. `ez-mac-runner-b-*`, `ez-runner-b-*`) with `conclusion=success`. The gate also checks a
real-execution proof (≥1 of the last 6 runs succeeded on our fleet) and a
time-windowed error count (last 3 min, not last 200 lines — a since-recovered
incident won't keep it red). If `fleet healthy` and exit 0, you're done — stop.
If `fleet unhealthy`, continue. **Never restart-loop the service** — see
`docs/harness-early-victory-5whys.md`. **Before any `systemctl --user restart
ezgha.service`, check `uptime` (1-min load) and `docker ps --filter
label=ezgha=managed | wc -l` (container count) — skip the restart if load_1min
> 12 or containers < 12, since a mass cold respawn has twice tripped this
host's watchdog (`max-load-1 = 24`) into a full reboot on 2026-07-07.**



### Stuck queue cleanup

```bash
./scripts/cleanup-stuck-runs.sh              # zombies (>8h by default, gh run delete) + fresh tail (>45m, cancel)
./scripts/cleanup-stuck-runs.sh --zombies    # delete only ancient queued artifacts
./scripts/cleanup-stuck-runs.sh --tail       # cancel only fresh runs waiting >45m
./scripts/cleanup-stuck-runs.sh --dry-run    # preview
```

Zombies: `gh run cancel` fails with 409 — always use `gh run delete`.
Fresh tail: cancels real PR CI — only run when queue tail > `QUEUE_TAIL_WARN_MIN` and saturation confirmed.

## Step 1b — Queue health metrics (always shown in section 8)

`doctor-runner` sources `scripts/queue-health.sh` on every run. Key metrics:

| Metric | Healthy | Unhealthy |
|--------|---------|-----------|
| Fresh queue max wait | ≤ 20 min | > 20 min → **BAD** (saturation or mis-routing) |
| Fresh queued count | low / draining | growing while all runners `busy=true` |
| Stale queued (>8h default) | 0 ideal | zombies inflate counts — delete with `gh run delete` |
| `in_progress` | matches busy runner count | stuck with 0 progress |

Env overrides: `QUEUE_REPO`, `QUEUE_TAIL_WARN_MIN` (default 20), `STALE_HOURS` (default 8).

Standalone:
```bash
./scripts/queue-health.sh
```

When section 8 is **BAD** or doctor exit ≠ 0, **mandatory**: run `/harness` per `~/.claude/commands/harness.md`.


## Step 2 — Identify the failing checks

The doctor groups failures into 10 sections (9 legacy + section 10 explicit-work inventory added in `doctor-runner` 2026-07-08):

1. **ezgha service** — `ezgha.service` should be `active`. If not: `systemctl --user restart ezgha.service`.
2. **docker daemon** — `docker info` must succeed. If not, the daemon's host is the problem; for Colima: `limactl start colima`.
3. **colima VM** — `limactl list` row 2 column 2 should be `Running`. If `Stopped`: `limactl start colima`.
4. **ezgha runtime state** — `ensure_count failed` in the journal more than 3 times in 200 lines indicates the slot-file desync. Fix:
   ```bash
   systemctl --user stop ezgha.service
   rm -f ~/.config/ezgha/slot_assignments.toml
   systemctl --user start ezgha.service
   ```
   (This is the standard reset; slot-recon PR shipped with v0.1.x makes the loop self-heal.)
5. **GitHub org runner fleet** — `ez-org-runner-N` should all be `online` at GitHub. If only some: see "Missing daemon, runner alive" below.
6. **live docker containers** — at least 14/16 containers should be running locally with `ezgha=managed` label.
9. **per-slot local execution proof** — see "Step 2b" below. This is the ironclad, GitHub-API-independent enforcement of "N/N runners actually executing."

### Step 2b — Per-slot activity truth (section 9, ironclad gate)

Sections 5/6 ("online" at GitHub, container count) can both be **fooled by a
GitHub API rate limit** — "online"/"busy" flags go stale or the query itself
fails, and container *count* alone can't tell idle apart from executing. A
naive `docker logs | grep "Listening for Jobs"` check is worse: it reads a
fully-busy fleet as 0/22 healthy, because an EXECUTING runner doesn't print
that line while it's running a job (observed 2026-07-09: 0/19 "listening"
while 9 jobs were in_progress — the motivating defect for this section).

Section 9 fixes this by proving state from **docker only, never GitHub**:
for every CONFIGURED slot (`${RUNNER_NAME_PREFIX}-1..count`, plus the other
host's fleet over SSH — `jeff-ubuntu` when run on the Mac, `macbook` when run
on Linux — if reachable), it runs `docker inspect` + `docker top <container>
-eo pid,comm | grep Worker` and classifies each slot into exactly one of
four states:

- **DOWN** — no running container at all. Always a defect.
- **IDLE-STARVED** — container up, `Runner.Listener` present, no
  `Runner.Worker`, AND the queue has been non-empty for
  `>= IDLE_STARVED_THRESHOLD_MIN` minutes (default 5; `QUEUE_OLDEST_FRESH_AGE_MIN`
  from section 8, not just instantaneous `QUEUE_QUEUED_FRESH > 0` — a
  single-tick queue blip is not starvation). A defect.
- **IDLE-OK** — idle, and either nothing is queued or the queue has been
  non-empty for less than the threshold. Healthy, not a defect.
- **EXECUTING** — `Runner.Worker` present. This is the actual per-slot proof
  the mission's "22/22 executing" standard requires. Section 10 attributes
  each EXECUTING slot to a real job (name + repo + elapsed + run URL) via
  the GitHub **jobs** API (`runs/{id}/jobs`, matched on `runner_name`) — the
  workflow-run object itself has no `runner_id`/`runner_name` field, so a
  lookup against the runs list alone silently never matches.

It also surfaces the **serve-loop-starvation signal**: the largest gap (in
seconds, Linux-only — journalctl has per-line timestamps, macOS's redirected
launchd logs do not) between `respawned ephemeral runner` bursts in the last
10 minutes, plus how many rate-limit occurrences showed up in the same
window. A gap over `STARVE_GAP_WARN_SECONDS` (default 150s) means
`ensure_count` is being starved by a rate-limited monitor tick again — the
exact ez-gh-actions-yrt/g3o regression (see `src/queue_monitor.rs`'s
`SERVE_LOOP_TIME_BUDGET` and `src/github.rs`'s `run_gh_with_backoff_until`).
If this fires, re-check that both files still thread a `deadline` through
every `gh` call reachable from the monitor/sampler tick — a future change
that adds a new `github::api_json(...)` call in that path (instead of
`api_json_until`) would silently reopen the starvation hole.

Env overrides: `MAC_HOST` (default `macbook`), `MAC_RUNNER_NAME_PREFIX`
(default `ez-mac-runner-b`), `MAC_RUNNER_COUNT` (default `6`),
`STARVE_WINDOW` (minutes, default `10`), `STARVE_GAP_WARN_SECONDS`
(default `150`).

## Step 3 — Special cases

### "Missing daemon, runner alive" (slot 3, 5, 7, etc. online at GitHub but no docker container)

This is the most common degraded state. Two safe approaches:

**A. Stop and restart ezgha (preferred):**

```bash
systemctl --user restart ezgha.service
bash /home/jleechan/projects/ez-gh-actions/doctor-runner
```

After restart, slot-recon calls `release_stale_slots` at the top of `ensure_count`, freeing slots whose runner_id is gone from `github::list_runners`. Then the next call to `next_slot` will mint a fresh slot for each missing daemon.

**B. Force-clean stale registrations:**

```bash
TOKEN=$(gh auth token)
for id in $(/usr/bin/gh api orgs/jleechanorg/actions/runners --paginate 2>/dev/null | jq -r '.runners[] | select(.name|startswith("ez-org-")) | .id'); do
  code=$(curl -sS -o /dev/null -w "%{http_code}" -X DELETE \
    -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/orgs/jleechanorg/actions/runners/$id")
  echo "$code $id"
done
```

Some deletes return 422 ("Runner X is currently running a job and cannot be deleted") — that's fine; try again after the jobs complete. After deletes succeed: `rm -f ~/.config/ezgha/slot_assignments.toml && systemctl --user restart ezgha.service`.

### "Stuck in 409 loop" (slot file says reserved, but GitHub still has the registration)

ezgha v0.1.x: this used to be permanent. With slot-recon merged, the loop self-heals as long as you let ezgha run. The 409 just means "this slot name already exists on GitHub"; once the existing daemon dies or its job completes, the next call to `release_stale_slots` will free the local slot. **Wait 60-120 s; do NOT keep restarting ezgha, that just amplifies the noise.**

### "All 16 are busy and I can't delete them"

This is the GOOD state during a CI wave. Wait for worldarchitect's jobs to drain. doctor-runner exit code 1 here is misleading; the real signal is in section 5 (all 16 `ez-org-runner-N` listed as `online`).

## Step 4 — Verify health

Run doctor again. Repeat until it returns 0. If it stays 1 for 10+ minutes despite following the steps above, the issue is upstream (colima VM killed, docker socket lost) and needs an operator's eyes.

## Output format

Always run `bash /home/jleechan/projects/ez-gh-actions/doctor-runner` (no flags) first. The human-readable output is the audit trail. `--json` is available for scripted checks but not enabled by default.


## Step 5 — Harness diagnosis (mandatory on failure)

When `doctor-runner` exits 1 **or** queue tail > `QUEUE_TAIL_WARN_MIN` (20m):

1. Invoke `/harness` (read `~/.claude/skills/harness-engineering/SKILL.md`)
2. Classify: silent degradation | missing validation | repeated manual fix
3. Check: Is external watchdog masking slot drift? Is systemd unit stale? Are zombie queued runs polluting metrics?
4. Propose durable harness fixes — not just `systemctl restart`

See `docs/harness-early-victory-5whys.md` for why restart-looping is forbidden.

## Safe GitHub payload pattern (PRs, issues, comments)

For Markdown or operator-generated text, never inject body text directly into a
shell word.

Use file/stdin payloads:

```bash
body_file=$(mktemp)
cat > "$body_file" <<'EOF'
Body content with markdown and command-looking text:
`backticks` and $(command substitution) must stay literal.
EOF

repo="jleechanorg/ez-gh-actions"

# PR create path (exact body text in file, no shell interpolation)
gh pr create --title "Safe test" --body-file "$body_file"

# Structured API path for arbitrary payloads
jq -n \
  --rawfile body "$body_file" \
  '{title: "Safe test", body: $body}' \
| gh api repos/"${repo}"/pulls --method POST --input -

# Comment example (same no-interpolation principle)
issue_number=123
jq -n --rawfile body "$body_file" '{body: $body}' \
| gh api repos/"${repo}"/issues/"${issue_number}"/comments --method POST --input -
```

Do not use interpolated `--body "$payload"` for Markdown content.

## Important context

- ezgha slots live at `${XDG_CONFIG_HOME:-~/.config}/ezgha/slot_assignments.toml`. The 16-slot capacity is set by `~/.config/ezgha/config.toml` `runner.count`.
- The colima VM (4-cpu/12GB) is the docker daemon host. Restarting it kills all 16 ezgha containers. Only restart if the VM is in `Stopped` state.
- mac ARM64 `org-runner-mac-*` runners persist independently of this Linux host. WARN-level only; deleting them via API does not stop their macOS hosts from re-registering.
- For jobs that show `runner_name: "GitHub Actions NNNNNNNN"` (a 10-digit id), that's GitHub-hosted — not ezgha's problem.

## Known Failure Modes & Fixes

### Container name-collision loop (stale slot)
**Symptom**: Journal shows repeated `docker run failed: Conflict. The container name "/ez-org-runner-N" is already in use` and Gate 3 fails with `Local managed container count (N) is lower than COUNT-1`.

**Root cause**: A previous container from the same slot exited but was not removed (e.g., due to daemon crash or service restart), leaving a stopped container occupying the name. The daemon's `docker run --name ez-org-runner-N` then fails on every cycle.

**Fix** (manual):
```bash
docker rm -f ez-org-runner-N   # unblock the slot
```

**Permanent fix**: As of commit `c6defc7`, `start_one()` in `docker_backend.rs` runs `docker rm -f <name>` before each `docker run`, so the daemon is self-healing by default.

### Custom runner image missing gh/jq (exit 127)
**Symptom**: Workflow steps that call `gh api` or `jq` fail with `command not found` (exit code 127). The Green Gate workflow shows `Fetch PR details failed (rc=127)` in its annotations.

**Root cause**: The upstream `ghcr.io/actions/actions-runner:latest` image does not include `gh` or `jq`.

**Fix**: Build and use `ezgha-runner:latest`:
```bash
docker build -f Dockerfile.runner -t ezgha-runner:latest .
```
Update `~/.config/ezgha/config.toml` → `image = "ezgha-runner:latest"`, then restart:
```bash
systemctl --user restart ezgha.service
```
