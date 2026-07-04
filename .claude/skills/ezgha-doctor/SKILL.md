---
name: ezgha-doctor
description: Diagnose ez-gh-actions (ezgha) fleet health using the repo's doctor.sh and named remediation steps. Use when ezgha.service is misbehaving, the runner fleet is degraded, or "GitHub Actions not running" complaints land on ezgha.
---

# ezgha doctor — diagnose + repair ezgha fleet health

This skill drives the **doctor.sh** script that ships at the repo root, plus the named remediation actions the script recommends. Use it whenever the user reports any of:

- "the runners are not up" / "ezgha is broken" / "GitHub Actions isn't taking tasks"
- service showing `failed (Result 'exit-code')`
- journal full of `ensure_count failed (will retry): … runner with the name already exists`
- worldarchitect.ai fleet page shows fewer than 16 `ez-org-runner-*` runners online

## Step 1 — Establish the baseline

```bash
bash /home/jleechan/projects/ez-gh-actions/doctor.sh
```

Read the verdict. If `fleet healthy`, you're done — stop. If `fleet unhealthy: N critical check(s) failed`, continue.

## Step 2 — Identify the failing checks

The doctor groups failures into 6 sections:

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

## Step 3 — Special cases

### "Missing daemon, runner alive" (slot 3, 5, 7, etc. online at GitHub but no docker container)

This is the most common degraded state. Two safe approaches:

**A. Stop and restart ezgha (preferred):**

```bash
systemctl --user restart ezgha.service
bash /home/jleechan/projects/ez-gh-actions/doctor.sh
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

This is the GOOD state during a CI wave. Wait for worldarchitect's jobs to drain. doctor.sh exit code 1 here is misleading; the real signal is in section 5 (all 16 `ez-org-runner-N` listed as `online`).

## Step 4 — Verify health

Run doctor again. Repeat until it returns 0. If it stays 1 for 10+ minutes despite following the steps above, the issue is upstream (colima VM killed, docker socket lost) and needs an operator's eyes.

## Output format

Always run `bash /home/jleechan/projects/ez-gh-actions/doctor.sh` (no flags) first. The human-readable output is the audit trail. `--json` is available for scripted checks but not enabled by default.

## Important context

- ezgha slots live at `${XDG_CONFIG_HOME:-~/.config}/ezgha/slot_assignments.toml`. The 16-slot capacity is set by `~/.config/ezgha/config.toml` `runner.count`.
- The colima VM (4-cpu/12GB) is the docker daemon host. Restarting it kills all 16 ezgha containers. Only restart if the VM is in `Stopped` state.
- mac ARM64 `org-runner-mac-*` runners persist independently of this Linux host. WARN-level only; deleting them via API does not stop their macOS hosts from re-registering.
- For jobs that show `runner_name: "GitHub Actions NNNNNNNN"` (a 10-digit id), that's GitHub-hosted — not ezgha's problem.