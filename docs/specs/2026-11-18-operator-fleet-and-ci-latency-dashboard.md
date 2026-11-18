# Operator Fleet, Queue Reconciliation & CI Latency Dashboard

Date: 2026-11-18
Status: Implementation & Verification Specification for PR #239 (`feat/operator-fleet-and-ci-latency-dashboard`)

---

## 1. Outcome

Provide full per-slot fleet observability, active run-vs-slot reconciliation, and CI percentile latency telemetry (`avg / p50 / p90 / p99`) across two complementary surfaces:

1. **Upgraded Public Redacted Status Page (`dashboard/` + `scripts/runner_dashboard_host_probe.sh` + `scripts/build_runner_dashboard_snapshot.py` + `scripts/ci_latency_probe.py` + `scripts/publish_runner_dashboard.sh`)**:
   - Extends `schema_version: 1` backward-compatibly (`sources` retains strictly `mac` and `linux`; top-level `cmux`, `reconciliation`, `latency`, and per-host `slots` arrays are additive).
   - Displays per-slot visual chip grids (`EXECUTING`, `IDLE`, `CYCLING`, `DOWN`, `PARKED`, `OFFLINE`), intentional `PARKED` opt-out (`MAC_RUNNER_DISABLED=1`) distinct from `DOWN`, anonymized `cmux` cloud-VM pool slots (`cloud-vm-1..N` / `cloud-vm-<i>-<j>`), a **"Why Does GitHub Show N Runs In Progress?"** reconciliation banner, and redacted CI latency percentile tables (`avg`, `p50`, `p90`, `p99`) for Queue Wait, Job Execution, and End-to-End Run duration.
   - Guarantees zero leakage of private repository names, branch names, PR titles, commit messages, actor logins, internal hostnames, or tokens on public Pages.

2. **Local Unredacted Operator Live View (`scripts/fleet_live_dashboard.py`)**:
   - Serves an interactive localhost-only (`127.0.0.1` / `localhost` / `::1`) live dashboard (`--serve --port 8790` with 15-second thread-safe TTL cache and `/api/state` polling) and one-shot static HTML snapshots (`--out-html <path>`), consuming either live audit JSON (`--audit-dir`) or bounded live `gh` probes.
   - Surfaces **every runner slot across all hosts** (`jeff-ubuntu` 20 slots, `cmux-*` cloud VMs, `macOS` container + native listener slots) with clickable GitHub Run / Job / PR links, live child-process phase tags (`playwright`, `jest`, `pytest`, `git index-pack`, `npm ci`, etc.), `DOWN` / `DISK-PAUSED` / `IDLE-STARVED` highlighting, host vitals (load, memory, disk free vs admission floor), and sortable `avg / p50 / p90 / p99` workflow breakdown across `Success`, `All Non-Skipped`, `Failure`, and `Cancelled` cohorts.

---

## 2. Non-Goals

- **No changes to Rust runner lifecycle or capacity daemon (`src/*.rs`)**: `ensure_count`, slot allocation, container respawn pacing, and admission floors remain untouched.
- **No automatic mutation of GitHub Actions runs or runner containers**: both dashboards are strictly read-only observability tools; they never cancel runs, restart Docker containers, or trigger deploys.
- **No live deploy from this PR branch**: `cargo install`, `systemctl restart`, `verify-exit-criteria.sh`, and `publish_runner_dashboard.sh --publish` remain owned by the single deploy-owner after review/merge.
- **No unredacted private metadata on GitHub Pages**: private repos, PR URLs, branch refs, and hostnames stay exclusively in local `--out-html` / `--serve` operator output.
- **No multi-machine daemon or cloud database**: relies on existing host probes, `gh` CLI (`~/.config/ezgha/gh_token`), and optional local audit JSON files.

---

## 3. Acceptance Criteria

1. **Backward-Compatible Public Schema & Strict Redaction**:
   - `build_runner_dashboard_snapshot.py` preserves `schema_version: 1`, `sources` containing strictly `{"mac_host", "linux_host"}`, and existing severity rules when optional `cmux` / `latency` inputs are omitted.
   - Public `slots`, `cmux.vms[].slots`, `latency`, `queue`, and `reconciliation` anonymize repository names (`repo-1..N`), workflow names (`workflow-1..N`), slot IDs (`mac-1..N`, `linux-1..N`, `cloud-vm-<i>-<j>`), and VM IDs (`cloud-vm-1..N`), drop raw disk GB values (emitting only coarse `disk.status` / `disk_status`), allowlist `phase_badge` / `workflow_category` / `pause_reason` / `parked_reason`, and never expose branch names, PR titles/URLs, actors, internal hostnames, or tokens on public Pages.
2. **Intentional Parked Opt-Out vs Down**:
   - When `MAC_RUNNER_DISABLED=1` or `EZGHA_DASHBOARD_MAC_DISABLED=1`, `runner_dashboard_host_probe.sh` emits `parked: true`, `parked_slots`, and `PARKED` slot states while keeping unexecuted `service`/`docker`/`process_probe` sources truthful; `build_runner_dashboard_snapshot.py` validates intentional `parked` state via `sources.config.ok` + slot reconciliation and `dashboard.js` renders `PARKED` cleanly instead of false `CRITICAL` / `DOWN`.
3. **Run-vs-Slot Reconciliation Truth**:
   - `queue_probe.py` emits `in_progress_runs` alongside `fresh` / `ghosts` so both the scheduled publisher and local dashboard display `Active Workflow Runs`, `Active Job Slots Occupied`, `Idle Slots`, `Offline / Disk-Paused / Parked Slots`, `Fresh Queued Runs`, and `Inert Ghosts` across verified pools without fabricating counts from unverified hosts.
4. **CI Latency Percentiles (`avg / p50 / p90 / p99`)**:
   - `ci_latency_probe.py` keys workflows by `(repo, workflow)`, computes linear-interpolated `p50`, `p90`, `p99`, `avg`, and `max` across Queue Wait, Job Execution, and End-to-End Run clocks, sets `partial: true` on per-run timeouts, fails closed on rate limits (`timeout=20s` per `gh` call), and parses `ci_latency_percentiles.json` fixtures via shared `iter_audit_repo_blocks()` / `from_audit_data()` across all 4 cohorts.
5. **Operator Local Security & Interactivity**:
   - `fleet_live_dashboard.py` enforces loopback-only server binds AND validates the HTTP `Host` header against loopback (`403` otherwise), escapes embedded JSON (`<`, `>`, `&`, U+2028/U+2029), enforces `http:`/`https:` URL allowlists (`_safe_http_url` in Python and `new URL()` `safeHttpUrl` in browser JS), uses non-blocking single-flight 15s TTL caching, collects real local Docker slots when run without `--audit-dir`, surfaces explicit source timestamps, and supports live host-group filtering, state filtering, text search, cohort switching, and column sorting.
6. **Automated Regression & Live Visual Gates**:
   - All Python, Node (`19/19`), Bash, and Cargo (`fmt`, `clippy -D warnings`, `cargo test`) suites pass cleanly.
   - Headless Playwright renders both `dashboard/index.html` and `scripts/fleet_live_dashboard.py --serve` cleanly on desktop (`1440x900`) and mobile (`375x812`) with zero console/page errors and non-empty grids + percentile rows.

---

## 4. User Stories (Before / After)

### Story 1 — "Why does GitHub show 15 runs while 30+ slots are busy or down?"
- **Before**: The operator only saw `mac: 4/4` and `linux: 20/20` aggregate counters. Multi-shard workflows (fanning 1 run into 6–15 concurrent jobs), `cmux-*` cloud VMs, and disk-paused hosts were invisible, making queue depth and runner health impossible to reconcile.
- **After**: The Reconciliation Banner immediately displays e.g. `17 Active Workflow Runs -> 30 Active Job Slots` alongside `Idle Slots`, `Offline/Paused/Parked Slots`, `Fresh Queued`, and `Inert Ghosts`, while per-host slot chips reveal every active job link, phase (`playwright`, `jest`, `git index-pack`), and pause alert.

### Story 2 — "Is the Mac fleet crashed or intentionally parked?"
- **Before**: Suspending Mac runners (`MAC_RUNNER_DISABLED=1`) caused the public status page to alarm as `DOWN` / `CRITICAL` indefinitely.
- **After**: `EZGHA_DASHBOARD_MAC_DISABLED=1` marks the Mac leg `PARKED` with an optional suspension bead pointer (`EZGHA_SUSPENSION_RECORD`), visually distinct from an unexpected `DOWN` outage.

### Story 3 — "How long do jobs actually wait vs execute at p50/p90/p99?"
- **Before**: No latency telemetry existed on the dashboard; operators had to write ad-hoc scripts to measure queue wait vs execution vs cancellation rate.
- **After**: Both public and local dashboards display `avg / p50 / p90 / p99` for Queue Wait, Job Execution, and End-to-End Runs overall, by runner class, by slow step category, and per top workflow (with interactive cohort/sort controls locally).

---

## 5. Proof Plan

- **Layer 1 (Unit & Contract Tests)**:
  - `tests/runner_dashboard_snapshot_test.py`: schema preservation, strict `sources` keys, public slot/cmux redaction, `PARKED` opt-out, reconciliation totals, and graceful degradation when probes fail.
  - `tests/ci_latency_probe_test.py`: linear percentile math (`avg/p50/p90/p99/max`), skipped/neutral exclusion, rate-limit fail-closed handling, and `from_audit_json` normalization.
  - `tests/fleet_live_dashboard_test.py`: 53-slot audit normalization, XSS/unsafe-URL sanitization, loopback-only guard, and 15s TTL cache under concurrent requests.
  - `tests/runner_dashboard_ui_test.mjs`: 19 UI/state classification, aria-live deduplication, reconciliation, cmux pool, and latency panel rendering assertions.
  - Bash contract tests: `runner_dashboard_host_probe_test.sh`, `runner_dashboard_publisher_test.sh`, `runner_dashboard_launchd_install_test.sh`, `launchd_docker_host_consumers_test.sh`, plus `queue_probe_test.py`.
  - Rust baseline checks: `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, `cargo test`.
- **Layer 2 (Real-Server Browser & Video Proof)**:
  - Serve `origin/main`'s `dashboard/` (BEFORE) and candidate `HEAD`'s `dashboard/` + `scripts/fleet_live_dashboard.py --serve` (AFTER) over local loopback HTTP servers using sanitized non-disclosing audit data (preserving unredacted originals privately in `/Volumes/diskm-scratch/fleet-live-audit-20261118/`).
  - Capture BEFORE vs AFTER desktop (`1440x900`) and mobile (`375x812`) PNG screenshots and a continuous Playwright `.webm` -> `.mp4`/`.gif` video exercising host group filtering, state filtering, text search, cohort switching, workflow sorting, and live `/api/state` refresh.
- **Independent Gates**: `/cs` (4-lane + repo gates), `/visual-verification` (2 independent seats inspecting decoded PNGs & video frames), `/advice` (2 independent full-diff source votes), and closing `/er` adjudication.

---

## 6. Design Mock / Layout Specification

### Public Redacted Pages (`dashboard/index.html`)
```text
+-----------------------------------------------------------------------+
| GitHub Actions Runner Fleet & CI Latency          [AUTO/HEALTHY/PARK] |
| Capacity summary + host freshness timestamps                          |
+-----------------------------------------------------------------------+
| Why Does GitHub Show N Runs In Progress? (Reconciliation Banner)      |
| [Active Runs] [Job Slots Busy] [Idle] [Paused/Down] [Parked] [Ghosts] |
+-----------------------------------------------------------------------+
| Host: Linux X64 Pool        | Host: macOS Pool (PARKED / ACTIVE)      |
| [slot-1 EXEC 12m] [slot-2..] | [mac-1 PARKED] [mac-2 PARKED] ...      |
+-----------------------------------------------------------------------+
| Cloud VM Pool (cloud-vm-1..N anonymized cards + slot chip grids)     |
+-----------------------------------------------------------------------+
| CI Latency Telemetry (Queue Wait / Job Exec / E2E: avg/p50/p90/p99)   |
| + Top Workflows Latency Table (no branches / actors / PR titles)      |
+-----------------------------------------------------------------------+
```

### Local Unredacted Operator Live View (`scripts/fleet_live_dashboard.py`)
```text
+-----------------------------------------------------------------------+
| Fleet + Queue + CI Latency Operator View   [15s Refresh] [Live/Pause] |
| [Filter: All | jeff-ubuntu | cmux | mac] [State: ALL|DOWN|IDLE|EXEC]  |
+-----------------------------------------------------------------------+
| Reconciliation KPI Strip + Queue Fresh/Ghost Counters + Alerts Banner |
+-----------------------------------------------------------------------+
| Host Cards (Load, RAM, Disk Free vs Floor, Pressure Contributors)     |
| -> Slot Table/Chips: Slot | State | Phase | Repo/PR# Link | Run/Job   |
+-----------------------------------------------------------------------+
| CI Latency Panel [Success | All Non-Skipped | Failure | Cancelled]    |
| -> Summary Cards + Runner Class Split + Sortable Per-Workflow Table   |
+-----------------------------------------------------------------------+
```
Responsive target: multi-column grid on desktop (`1440x900`) collapsing cleanly to single-column scrollable cards/tables with horizontal table scroll containment on mobile (`375x812`).

---

## 7. Risk & Blast Radius

- **GitHub API rate-limit / hang risk**: `publish_runner_dashboard.sh` runs under an exclusive lock (`LOCK_DIR`) on the 10-minute launchd cadence so overlapping runs never stack (worst-case probe timeouts: queue `240s` + latency `120s` + optional cmux `60s` + 2x host probe `45s` + publish push; non-overlapping lock prevents cascade). Each `gh` call uses `timeout=20s`. Normal `ci_latency_probe.py` call count per cycle is 2 run-list queries + up to 40 job fetches (42 calls max) plus 2 `in_progress` total-count queries in `queue_probe.py`; on `403`/`429` or timeout, `ci_latency_probe.py` sets `ok: false` or `partial: true` and `publish_runner_dashboard.sh` still publishes host fleet capacity.
- **Public privacy leakage risk**: mitigated by strict allowlist sanitization & deterministic anonymization (`_sanitize_slots`, `_public_host`, `_public_cmux`, `_public_queue`, `_public_latency` in `build_runner_dashboard_snapshot.py`) and regression tests verifying zero private repo/workflow/host/branch/disk-GB fields appear in `status.json`.
- **Local XSS / DNS-rebinding risk**: untrusted GitHub run/workflow titles, branch names, and URLs are escaped in JSON (`_escape_embedded_json`), validated against `http:`/`https:` allowlists in Python and JS, and rendered safely; loopback server rejects non-loopback `Host` headers (`403`).
- **Scope isolation risk**: Rust daemon code (`src/`) and live host services are untouched; deploy/publish commands are never invoked from this branch; `cmux` cloud probing in the scheduled publisher remains opt-in via `EZGHA_DASHBOARD_CMUX_PROBE_CMD`.
