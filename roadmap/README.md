# ez-gh-actions roadmap

Rolling operational notes for the `ezgha` self-hosted runner daemon.

## Recent activity (rolling)

### 2026-07-07 — Fleet doctor session + watchdog root-cause

- Root-caused Linux flapping: `WatchdogSec=60/180` kills `ezgha serve` when `ensure_count` + paginated `gh api` exceeds watchdog window; fix drafted locally (`src/watchdog.rs`, ping before/after + per-runner ping).
- Mac: `minimum_isolation=vm` on container-only Colima caused fail-closed; fixed in `~/.config/ezgha/config.toml` → `container`.
- Added `scripts/queue-health.sh`, `scripts/cleanup-stuck-runs.sh`, doctor section 8 (queue tail >20m), harness trigger on failure.
- Scanned last 20 open PRs: **0 runner failures in completed job logs**; saturation = stuck `queued`, not infra crash.
- [PR #8193](https://github.com/jleechanorg/worldarchitect.ai/pull/8193) (worldarchitect.ai): CodeRabbit APPROVED on `ce269044`; checks pending on saturated fleet.
- **Next:** commit/push local watchdog fix → `cargo install` both hosts → re-enable stable `WatchdogSec=180`.

### 2026-07-06 — Binary at 51a5b35, external fleet-watchdog band-aid

- Fleet functional but AMBER: external `ezgha-fleet-watchdog.sh` restarts every ~120s when count < configured.
- Slot reconciliation fixes landed in `077d07c` / `51a5b35` but supervisor kills and Mac policy gaps still cause 3–6 / 14–16 flapping.
