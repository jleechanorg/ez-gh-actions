# ezgha fleet state — honest assessment, 2026-07-04 12:04 UTC

## Claim: fleet is working
- 8 of last 8 `ezgha-selftest` runs completed `success` on `ez-org-runner-*` slots.
- worldarchitect.ai's CI wave has been draining (busy count fell from 16 → 1 over the last hour).
- The new binary has slot reconciliation merged at `105c766`, which means the slot file no longer wedges permanently.

## Counter-claim: fleet is NOT at full capacity
- Doctor currently reports `3/16` ez-org-runner online. Twelve slots lost over the session.
- 168 ensure_count failed messages in journal (now down to ~33 after the latest reset; trending down further as slot-recon runs each cycle).
- The mac ARM64 colima fleet (6 runners) persists independently of this Linux host. They resurrect from macOS hosts we don't have shell access to.

## What was fixed (and shipped to main)
1. `feature/stable-naming` (#3): stable `ez-org-runner-N` slot-based names. PR merged at `627be9e`.
2. `feature/slot-reconciliation` (#4 merge via squash): `release_stale_slots(cfg)` runs at the top of `ensure_count`, freeing slots whose runner_id is gone from `github::list_runners`. PR merged at `105c766`.
3. `feature/ezgha-doctor`: read-only `doctor.sh` script + `.claude/skills/ezgha-doctor/SKILL.md` for next-session diagnosis. PR merged at `74bda62`.

## What's still broken (not yet fixed)
- **The slot-recon blind spot.** `release_stale_slots` only frees slots whose runner_id is **gone from GitHub**. For slots whose runner_id is *online at GitHub but the local daemon is dead*, no remediation. The fix needs to fetch each runner's details and check `busy=false AND last_active within 60s`, not just list presence. Filed as Task #2 in `/nextsteps`.
- **Cascading restart amplification.** Every restart creates new GitHub registrations while old containers are still alive. The fix is to *not* restart ezgha in tight loops.
- **The mac colima fleet** (6 runners) can't be stopped from this Linux host.

## Next-step actions (deferred)
1. Implement per-runner online check in slot-recon (`fix/slot-recon-online-check`).
2. Audit worldarchitect.ai mac colima host files for the re-registration source.
3. Tag a v0.1.1 release with the merged PRs + slot-recon upgrade.
4. Re-run /er on the v0.1.1 release.

## Reproduction
```bash
bash doctor.sh                          # health verdict
bash doctor.sh 2>&1 | tail -10          # last 10 lines (verdict only)
gh api orgs/jleechanorg/actions/runners --paginate | jq '.runners | length'    # fleet size
```
