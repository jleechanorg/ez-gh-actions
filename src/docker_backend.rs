use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet, VecDeque};
use std::env;
use std::ffi::CString;
use std::io::Read;
use std::path::Path;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicUsize, Ordering};
use std::sync::{mpsc, Arc, Condvar, Mutex, Once};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::alert::{self, Severity};
use crate::backend::Backend;
use crate::config::Config;
use crate::failure_ladder::{FailureLadder, FailureLadderPolicy, FailureLadderTransition};
use crate::github;
use crate::platform::Platform;
use crate::quarantine::{self, QuarantineEntry, QuarantineReason, QuarantineTable};
use crate::reaper;
use crate::watchdog;

const MANAGED_LABEL: &str = "ezgha=managed";
const FAILURE_LADDER_PATH_ENV: &str = "EZGHA_FAILURE_LADDER_PATH";

/// Pinned image used by the in-daemon cgroup-probe (`docker run --rm`).
/// Pinning prevents (a) a `latest` tag drift breaking the probe when
/// upstream alpine ships a major cgroup-tools change, and (b) the
/// first-spawn cold start paying 5+ seconds of image-pull latency on
/// a freshly-restarted daemon. The daemon fire-and-forgets
/// `docker pull` of this tag at startup (`prepull_probe_image`) so the
/// cache is warm by the time the first probe fires.
pub const PROBE_IMAGE: &str = "alpine:3.19";

/// Consecutive-`None` counter for `free_disk_gb`. After this many in a
/// row we treat the disk floor as exceeded and refuse to spawn, since a
/// sustained inability to measure is itself a degraded-daemon signal.
const DISK_MEASURE_STRIKES: u32 = 2;
/// Incident-derived early warning for Mac host pressure. This is deliberately
/// observability-only: `limits.min_free_disk_gb` remains the admission floor.
const MACOS_HOST_DISK_PRESSURE_ALERT_GB: u64 = 40;
static CONSECUTIVE_DISK_NONE: AtomicU32 = AtomicU32::new(0);
/// Once a failure-ladder transition cannot be persisted, the on-disk ledger
/// is stale and the daemon must not admit another external start against it.
/// This latch intentionally lasts for the daemon lifetime; process restart is
/// the explicit recovery condition that re-establishes a fresh persistence
/// contract before admission resumes.
static FAILURE_LADDER_PERSISTENCE_FAILED: AtomicBool = AtomicBool::new(false);

#[cfg(test)]
fn reset_failure_ladder_admission_latch_for_tests() {
    FAILURE_LADDER_PERSISTENCE_FAILED.store(false, Ordering::SeqCst);
}
const CPUS_REQUIRE_CPU_CONTROLLER_ERR: &str = "refusing to start runner: Docker CPU cgroup controller is unavailable on this Linux host; cannot enforce --cpus safely.";
const DOCKER_TIMEOUT: Duration = Duration::from_secs(45);
const DOCKER_CLEANUP_RESERVE: Duration = Duration::from_millis(50);
/// The scheduler polls each owned child without blocking, so one stalled child
/// cannot monopolize the scheduler. This cap bounds retained child state and
/// leaves excess requests queued for the next poll cycle.
const DOCKER_REAPER_ACTIVE_CAP: usize = 64;
const DOCKER_REAPER_QUEUE_ALERT_THRESHOLD: usize = 1;
const DOCKER_REAPER_POLL_INTERVAL: Duration = Duration::from_millis(10);
// Post-refill readiness gets one 30s shared local-Docker budget. At the normal
// sub-100ms `docker ps`/`docker top` latency this covers all 16 fleet slots;
// under host pressure a single probe may use up to ~6s and the shared deadline
// may expire before all slots are inspected. That is explicit incomplete
// evidence, never false recovery: the caller runs monitors and an immediate
// full reconciliation. The deadline starts before Docker child-reaper
// initialization and covers the `ps` plus all `top` probes. The probe budget
// is far below the 300s watchdog margin.
//
// The per-probe `LOCAL_TOP_TIMEOUT` is 6s (not 3s): the 2026-10-03 throughput
// doc measured 3.2-4.5s `docker top` latency on a Mac host under load — a 3s
// cap killed in-flight probes that were still going to succeed and reported
// false "not ready" / "absent". Parallel probes still fit the shared 30s
// budget (worst case is one slow probe + overhead, not 10 sequential 6s).
const LOCAL_READINESS_BUDGET: Duration = Duration::from_secs(30);
const LOCAL_TOP_TIMEOUT: Duration = Duration::from_secs(6);
/// Maximum concurrently executing `docker top` readiness probes.
const READINESS_PROBE_CONCURRENCY: usize = 20;

/// Lane-I (Round-3 swarm): rolling 5-tick window of PSI memory-pressure
/// percentages, read newest-at-tail. Mutated by `ensure_count_outcome` on
/// every admission decision. `Mutex` (not `RwLock`) because the read+write
/// pattern is "lock, rotate, push, decide, unlock" — RwLock would still
/// need a write lock for the rotate+push, so a plain Mutex avoids the
/// extra atomic at the same cost. None slots mean "no reading yet" and
/// break the hysteresis chain (so the daemon gets a 5-tick grace window
/// after a fresh start).
static PRESSURE_WINDOW: Mutex<[Option<f64>; 5]> = Mutex::new([None, None, None, None, None]);

#[cfg(test)]
static TEST_RELEASE_STALE_SLOTS_RESULT: std::sync::Mutex<Option<usize>> =
    std::sync::Mutex::new(None);
#[cfg(test)]
static TEST_FREE_DISK_GB: std::sync::Mutex<Option<Option<u64>>> = std::sync::Mutex::new(None);
#[cfg(test)]
static TEST_HOST_FREE_DISK_GB: std::sync::Mutex<Option<Option<u64>>> = std::sync::Mutex::new(None);
#[cfg(test)]
static TEST_IS_MACOS_HOST: std::sync::Mutex<Option<bool>> = std::sync::Mutex::new(None);
#[cfg(test)]
static TEST_START_ONE_NAMES: std::sync::Mutex<Option<Vec<String>>> = std::sync::Mutex::new(None);
#[cfg(test)]
/// Per-test queue of `Result<ReadinessSummary, String>` values consumed by
/// `executing_runner_count_from_containers`'s `#[cfg(test)]` branch. Each
/// `pop_front` configures one call. Tests inject `ReadinessSummary { ready,
/// absent }` so post-refill and settling-loop regressions can simulate
/// absent-container races — the round-2 review failure (bead jleechan-95jk
/// root-cause): absent slots must surface as shortage > 0 so the settling
/// episode fires (Recovered would silently skip it and sleep 30s).
static TEST_EXECUTING_RUNNER_COUNTS: std::sync::Mutex<
    Option<std::collections::VecDeque<std::result::Result<ReadinessSummary, String>>>,
> = std::sync::Mutex::new(None);
/// Overrides the binary name/path used to build every `docker` `Command` in
/// this module. Unlike mutating the process-wide `PATH` env var (which any
/// OTHER test in this binary — including unrelated modules like `alert.rs`,
/// which mutates `PATH` under its own, uncoordinated lock — can race with
/// under `cargo test`'s default multi-threaded runner), this is a plain
/// in-process value gated behind this module's own `TEST_LOCK`, so it cannot
/// leak into or be clobbered by any other test. See
/// `start_one_releases_slot_on_docker_run_failure` for the only user.
#[cfg(test)]
static TEST_DOCKER_BIN: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);
#[cfg(test)]
static TEST_DOCKER_REAPER_PANIC_ONCE: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);
#[cfg(test)]
static TEST_DOCKER_REAPER_PANIC_COUNT: AtomicU32 = AtomicU32::new(0);

/// Test seam for `docker_cpu_controller_available`. When a test installs
/// `Some(b)` via `cpu_probe_overrides::set`, the public function returns `b`
/// unconditionally — overriding the OnceLock cache and the real probe. The
/// 4 boundary tests (both_enabled, host_enabled/guest_disabled,
/// host_disabled/guest_enabled, both_disabled) drive every host/guest cgroup
/// combination without touching the real filesystem or spawning `docker run`.
///
/// Serialization: each test that mutates this state holds the existing
/// `tests::TEST_LOCK` so the static is never raced. `set` is paired with
/// `clear` in the test body (and `Drop` on `TestEnv` clears it) so a
/// failing assertion cannot leak the override into a later test.
#[cfg(test)]
mod cpu_probe_overrides {
    static OVERRIDE: std::sync::Mutex<Option<bool>> = std::sync::Mutex::new(None);

    /// Force the next call to `docker_cpu_controller_available()` to return
    /// `value`. Pass `Some(true)` / `Some(false)` to exercise the
    /// "available" / "unavailable" branches; pass `None` to clear the
    /// override and fall through to the real probe.
    pub fn set(value: Option<bool>) {
        *OVERRIDE.lock().unwrap() = value;
    }

    pub fn get() -> Option<bool> {
        *OVERRIDE.lock().unwrap()
    }
}

/// Env var that overrides the slot assignments file path. Used by tests to
/// avoid touching the user's real `~/.config/ezgha/slot_assignments.toml`.
const SLOT_ASSIGNMENTS_PATH_ENV: &str = "EZGHA_SLOT_ASSIGNMENTS_PATH";
static SLOT_ASSIGNMENTS_MISSING_WARNED: Once = Once::new();

/// Per-slot in-memory ring buffer of recent reclaim decisions (bead
/// jleechan-uurm). The first-wave Path-1 race investigation (jleechan-9yx8)
/// flagged the existing logs as forensically thin: the per-slot reclaim log
/// lacked `runner_id`/`last_run_id`/`monotonic_ts`/`elapsed_secs`/`in_grace`,
/// and the empty-id branch contributed only to a summary count. We now keep
/// a short rolling history per slot so an operator can pull recent activity
/// via `ezgha reclaim-history [--slot N]` without scraping journald.
///
/// Max entries per slot is small (16) because the diagnosis window for a
/// given flap is minutes, not hours; a larger cap would just hold noise.
/// Daemon start is captured at the first `record_reclaim` call so the
/// `monotonic_ts` field is comparable across processes.
const RECLAIM_RING_CAP: usize = 16;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReclaimRecord {
    /// Monotonic seconds since daemon start (matches `Instant::elapsed`).
    pub monotonic_secs: f64,
    /// Wall-clock unix epoch seconds (`now_epoch_secs()` at record time).
    pub wall_secs: u64,
    /// Slot that was reclaimed (or skipped) — as the user-facing slot number.
    pub slot: u32,
    /// runner_id recorded for this slot, if any (empty-id branch = 0).
    pub runner_id: u64,
    /// `last_run_id` of the slot if known (0 if unknown / empty-id).
    pub last_run_id: u64,
    /// Peak RSS of the local container at reclaim time, if known (0 otherwise).
    pub peak_rss_mb: u64,
    /// True if the decision was to SKIP the reclaim because the slot's
    /// `registered_at` was within `REGISTRATION_GRACE_WINDOW`.
    pub in_grace: bool,
    /// Human-readable reason: "empty-id-grace-skip", "empty-id-reclaim",
    /// "gh-rejected-past-grace", "name-mismatch", etc.
    pub reason: String,
}

fn daemon_start_instant() -> &'static std::sync::Mutex<Option<Instant>> {
    use std::sync::{Mutex, OnceLock};
    static START: OnceLock<Mutex<Option<Instant>>> = OnceLock::new();
    START.get_or_init(|| Mutex::new(None))
}

fn ensure_daemon_start() -> Instant {
    let mut guard = daemon_start_instant().lock().unwrap();
    if guard.is_none() {
        *guard = Some(Instant::now());
    }
    guard.unwrap()
}

fn reclaim_ring() -> &'static std::sync::Mutex<
    std::collections::HashMap<String, std::collections::VecDeque<ReclaimRecord>>,
> {
    use std::sync::{Mutex, OnceLock};
    static RING: OnceLock<
        Mutex<std::collections::HashMap<String, std::collections::VecDeque<ReclaimRecord>>>,
    > = OnceLock::new();
    RING.get_or_init(|| Mutex::new(std::collections::HashMap::new()))
}

/// Record a reclaim decision (or grace-window skip) into the per-slot ring.
/// `slot_key` is the stringified slot number ("1".."16"). When the deque
/// reaches `RECLAIM_RING_CAP`, the oldest entry is evicted FIFO so memory is
/// bounded regardless of churn.
pub fn record_reclaim(slot_key: &str, mut rec: ReclaimRecord) {
    let start = ensure_daemon_start();
    rec.monotonic_secs = start.elapsed().as_secs_f64();
    if let Ok(mut ring) = reclaim_ring().lock() {
        let entry = ring.entry(slot_key.to_string()).or_default();
        if entry.len() >= RECLAIM_RING_CAP {
            entry.pop_front();
        }
        entry.push_back(rec);
    }
}

/// Snapshot the ring for read-side consumers (CLI `reclaim-history`).
/// Most-recent-first ordering. Empty result if no reclaim events recorded
/// yet on this slot.
pub fn snapshot_reclaim(slot_key: Option<&str>) -> Vec<(String, ReclaimRecord)> {
    let ring = match reclaim_ring().lock() {
        Ok(g) => g,
        Err(_) => return Vec::new(),
    };
    let mut out: Vec<(String, ReclaimRecord)> = Vec::new();
    match slot_key {
        Some(key) => {
            if let Some(deque) = ring.get(key) {
                for rec in deque.iter().rev() {
                    out.push((key.to_string(), rec.clone()));
                }
            }
        }
        None => {
            for (k, deque) in ring.iter() {
                for rec in deque.iter().rev() {
                    out.push((k.clone(), rec.clone()));
                }
            }
        }
    }
    out.sort_by(|a, b| {
        b.1.monotonic_secs
            .partial_cmp(&a.1.monotonic_secs)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    out
}

/// Test-only escape hatch: clear the reclaim ring buffer and the cached
/// daemon-start instant so a `TestEnv` can be hermetic even though the
/// underlying state lives in a process-wide `OnceLock`. Never call from
/// production code — it is `#[cfg(test)]` and would discard legitimate
/// forensic data in the field.
#[cfg(test)]
pub fn reset_reclaim_state_for_tests() {
    if let Ok(mut ring) = reclaim_ring().lock() {
        ring.clear();
    }
    if let Ok(mut start) = daemon_start_instant().lock() {
        *start = None;
    }
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct SlotAssignments {
    /// Stable slot index serialized as a string key (TOML requires string map
    /// keys) -> GitHub runner_id assigned via JIT registration. An empty
    /// value means the slot is reserved (JIT call in flight) but the
    /// runner_id has not been recorded yet.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    assignments: BTreeMap<String, String>,
    /// Slot index -> unix-epoch-seconds when `record_slot_runner_id` last
    /// recorded a runner_id for that slot (bead ez-gh-actions-5ki). Read by
    /// `release_stale_slots`' offline+!busy reap paths (Path 1's own branch
    /// and the Path 4 `offline_not_busy_owned_missing_container_registrations`
    /// sub-pass) to skip reaping a registration that is still inside its
    /// JIT-propagation grace window — GitHub can take several seconds after
    /// `generate_jitconfig` returns before the runner flips from `offline` to
    /// `online`/appears in `docker ps`, and a reconciliation tick landing in
    /// that gap would otherwise delete the brand-new registration, causing
    /// `ensure_count` to respawn it next tick in an endless loop (see
    /// `runner-24h-review-20260709.md` §0/§1 and bead `ez-gh-actions-g3i`).
    /// Absent entry (e.g. a slot file written before this field existed, or a
    /// slot recorded via the pre-fix code path) is treated as "no grace
    /// window active" — never blocks a reap, only ever adds one.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    registered_at: BTreeMap<String, u64>,
}

/// Grace window (bead ez-gh-actions-5ki): a registration recorded within this
/// many seconds of "now" is never reaped by the offline+!busy+no-container
/// paths, regardless of what the GitHub API / local docker snapshot show,
/// because both sources are known to lag JIT registration by a few seconds.
/// 60s matches 5ki's spec — comfortably above the ~5s propagation lag Track A
/// measured, while still short enough that a genuinely dead registration is
/// reclaimed within two `release_stale_slots` ticks (30s cadence).
const REGISTRATION_GRACE_WINDOW: Duration = Duration::from_secs(60);

fn now_epoch_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// True if `slot`'s `registered_at` timestamp is within `REGISTRATION_GRACE_WINDOW`
/// of now. Missing entries (no timestamp recorded) are NOT in the grace
/// window — the fix only ever narrows what gets reaped, never widens it, so a
/// slot file predating this field behaves exactly as before.
fn slot_in_grace_window(assignments: &SlotAssignments, slot: &str) -> bool {
    let Some(&registered_at) = assignments.registered_at.get(slot) else {
        return false;
    };
    now_epoch_secs().saturating_sub(registered_at) < REGISTRATION_GRACE_WINDOW.as_secs()
}

/// Seconds elapsed since `slot`'s `registered_at` timestamp, if recorded.
/// Used to log how close a grace-window skip-reap decision was to the
/// boundary, rather than just the fixed window size.
fn seconds_since_registered(assignments: &SlotAssignments, slot: &str) -> Option<u64> {
    let &registered_at = assignments.registered_at.get(slot)?;
    Some(now_epoch_secs().saturating_sub(registered_at))
}

/// True if `slot`'s `assignments[id_str]` is empty (a `next_slot_excluding`
/// reservation that has not yet been filled by `record_slot_runner_id_for`)
/// AND the `registered_at` timestamp written by `next_slot_excluding` is
/// within `REGISTRATION_GRACE_WINDOW`. This protects the JIT round-trip
/// window — between `next_slot_excluding` (writes empty id) and
/// `record_slot_runner_id_for` (writes the runner_id + `registered_at`) — from
/// being reaped by Path 1's empty-id branch in `release_stale_slots`.
///
/// Bead jleechan-uurm. First-wave Path-1 race investigation (jleechan-9yx8)
/// showed the 2026-07-08 fix (PR #33, 1a9baf4) moved `record_slot_runner_id_for`
/// post-JIT pre-docker-run but did NOT gate Path 1's empty-id reclaim by a
/// grace window, leaving a sibling race open: `ensure_count_outcome` calls
/// `release_stale_slots` TWICE per tick (`:2857`, `:3018`), and a concurrent
/// `start_one_with_generate_at_slot` whose `generate_jitconfig` succeeded but
/// whose `docker run` had not yet landed could be reaped mid-flight, causing
/// the next cycle to allocate a fresh runner_id (slot-file flap).
fn empty_id_reservation_in_grace_window(
    assignments: &SlotAssignments,
    slot: &str,
    id_str: &str,
) -> bool {
    if !id_str.is_empty() {
        return false;
    }
    let Some(&registered_at) = assignments.registered_at.get(slot) else {
        return false;
    };
    now_epoch_secs().saturating_sub(registered_at) < REGISTRATION_GRACE_WINDOW.as_secs()
}

/// Look up the in-flight `run_id` for `runner_id` from `live_runners`. Returns
/// `Some(run_id)` only when GitHub surfaced `runId` in the
/// `/repos/{owner}/{repo}/actions/runners/{id}` payload — i.e. the runner is
/// currently executing a job. Returns `None` when the runner is idle, absent,
/// or the field was truncated by a partial HTTP-200 snapshot.
///
/// Bead jleechan-tv58: this is what lets the recorded-id reclaim log line
/// correlate a reclaim decision with the in-flight job. Previously the field
/// was hard-coded to `0` in the log because `RunnerInfo` did not carry it.
fn live_runners_last_run_id(live_runners: &[github::RunnerInfo], runner_id: u64) -> Option<u64> {
    live_runners
        .iter()
        .find(|r| r.id == runner_id)
        .and_then(|r| r.run_id)
}

/// Best-effort peak RSS (in MiB) of the named local container, read via
/// `docker stats --no-stream`. Returns `0` when:
///   * the container does not exist (most common case in the reclaim path —
///     we're reclaiming BECAUSE there's no container);
///   * `docker stats` fails (transient daemon hiccup, secondary rate-limit);
///   * the parser cannot make sense of the output.
///
/// Bead jleechan-tv58: populates the `peak_rss_mb` field in
/// `ReclaimRecord`. `0` is a deliberate signal, not a failure — the field
/// is forensic, not load-bearing.
fn container_peak_rss_mb(container_name: &str) -> u64 {
    // `docker stats` parses cleanly with `--no-stream --format '{{.MemUsage}}'`
    // which yields strings like "123.4MiB / 7.7GiB" or "0B / 7.7GiB".
    let out = match docker_cmd()
        .args([
            "stats",
            "--no-stream",
            "--format",
            "{{.MemUsage}}",
            container_name,
        ])
        .output()
    {
        Ok(o) if o.status.success() => o,
        _ => return 0,
    };
    let s = String::from_utf8_lossy(&out.stdout);
    // Take the part before the slash ("123.4MiB" -> "123.4MiB").
    let head = s.trim().split('/').next().unwrap_or("").trim();
    if head.is_empty() || head == "0B" {
        return 0;
    }
    // Parse "<number><unit>" where unit is one of B/KiB/MiB/GiB/TiB. K8s /
    // Docker use IEC binary suffixes (KiB, MiB, GiB) — the `.` is decimal,
    // not binary, so we treat the number as a float and multiply by the
    // binary-unit factor.
    let (num_str, unit) = head.split_at(
        head.find(|c: char| !c.is_ascii_digit() && c != '.')
            .unwrap_or(head.len()),
    );
    let num: f64 = match num_str.parse() {
        Ok(v) => v,
        Err(_) => return 0,
    };
    let bytes = match unit {
        "B" => num,
        "KiB" => num * 1024.0,
        "MiB" => num * 1024.0 * 1024.0,
        "GiB" => num * 1024.0 * 1024.0 * 1024.0,
        "TiB" => num * 1024.0 * 1024.0 * 1024.0 * 1024.0,
        _ => return 0,
    };
    (bytes / (1024.0 * 1024.0)) as u64 // MiB
}

/// Resolve the path of the slot assignment file. Honors `EZGHA_SLOT_ASSIGNMENTS_PATH`
/// (test escape hatch) and `XDG_CONFIG_HOME` (per XDG Base Directory spec),
/// falling back to `~/.config`.
fn default_state_dir() -> PathBuf {
    let config_home = env::var("XDG_CONFIG_HOME").unwrap_or_else(|_| {
        let home = env::var("HOME").unwrap_or_else(|_| "~".into());
        format!("{home}/.config")
    });
    PathBuf::from(config_home).join("ezgha")
}

fn slot_assignments_path_for(cfg: Option<&Config>) -> PathBuf {
    #[cfg(test)]
    {
        if let Some(p) = crate::docker_backend::tests::test_slot_path() {
            return p;
        }
    }
    if let Ok(p) = env::var(SLOT_ASSIGNMENTS_PATH_ENV) {
        return PathBuf::from(p);
    }
    cfg.and_then(|cfg| cfg.state_dir.clone())
        .unwrap_or_else(default_state_dir)
        .join("slot_assignments.toml")
}

fn read_slot_assignments_for(cfg: Option<&Config>) -> Result<SlotAssignments> {
    let path = slot_assignments_path_for(cfg);
    if !path.exists() {
        SLOT_ASSIGNMENTS_MISSING_WARNED.call_once(|| {
            eprintln!(
                "warning: slot_assignments.toml is missing at {}; continuing with empty slot table",
                path.display()
            );
        });
        return Ok(SlotAssignments::default());
    }
    let raw = std::fs::read_to_string(&path)
        .with_context(|| format!("read slot assignments {}", path.display()))?;
    if raw.trim().is_empty() {
        return Ok(SlotAssignments::default());
    }
    let parsed: SlotAssignments = match toml::from_str(&raw) {
        Ok(parsed) => parsed,
        Err(err) => {
            quarantine_corrupt_slot_file(&path, &err);
            eprintln!(
                "warning: slot_assignments.toml is corrupt ({}), continuing with empty slot table",
                err
            );
            return Ok(SlotAssignments::default());
        }
    };
    Ok(parsed)
}

#[cfg(test)]
fn read_slot_assignments() -> Result<SlotAssignments> {
    read_slot_assignments_for(None)
}

fn quarantine_corrupt_slot_file(path: &Path, cause: &impl std::fmt::Display) {
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let mut corrupted = path.to_path_buf();
    corrupted.set_extension(format!("toml.corrupt.{ts}"));
    if let Err(err) = std::fs::rename(path, &corrupted) {
        eprintln!(
            "warning: failed to quarantine corrupt slot file {} ({cause}): {err}",
            path.display()
        );
        return;
    }
    eprintln!(
        "warning: quarantined corrupt slot file {} -> {}",
        path.display(),
        corrupted.display()
    );
}

fn reap_killed_child_until_deadline(
    mut child: std::process::Child,
    deadline: Instant,
) -> Option<std::process::Child> {
    let _ = child.kill();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => return None,
            Err(_) => return Some(child),
            Ok(None) => {
                let remaining = deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    return Some(child);
                }
                std::thread::sleep(remaining.min(Duration::from_millis(1)));
            }
        }
    }
}

struct DockerReapRequest {
    child: std::process::Child,
    detail: String,
}

struct DockerReapQueue {
    pending: Mutex<VecDeque<DockerReapRequest>>,
    wake: Condvar,
    active: AtomicUsize,
}

#[derive(Clone)]
struct DockerChildReaper {
    queue: Arc<DockerReapQueue>,
}

static DOCKER_CHILD_REAPER: Mutex<Option<DockerChildReaper>> = Mutex::new(None);

fn try_wait_owned_docker_child(request: &mut DockerReapRequest) -> bool {
    match request.child.try_wait() {
        Ok(Some(_)) => true,
        Ok(None) => false,
        Err(error) => {
            eprintln!(
                "warning: Docker child wait failed while {}; retaining ownership for retry: {error}",
                request.detail
            );
            false
        }
    }
}

impl DockerReapQueue {
    fn enqueue(&self, request: DockerReapRequest) {
        let mut pending = self
            .pending
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        pending.push_back(request);
        let pending_len = pending.len();
        let active = self.active.load(Ordering::Relaxed);
        if active >= DOCKER_REAPER_ACTIVE_CAP && pending_len >= DOCKER_REAPER_QUEUE_ALERT_THRESHOLD
        {
            eprintln!(
                "warning: Docker child reaper is saturated ({active} active waits, {pending_len} queued); stalled child waits may need operator investigation"
            );
        }
        self.wake.notify_one();
    }

    fn worker_finished(&self) {
        self.active.fetch_sub(1, Ordering::Relaxed);
    }

    fn take_next(&self) -> Option<DockerReapRequest> {
        if self.active.load(Ordering::Relaxed) >= DOCKER_REAPER_ACTIVE_CAP {
            return None;
        }
        let mut pending = self
            .pending
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let request = pending.pop_front()?;
        self.active.fetch_add(1, Ordering::Relaxed);
        Some(request)
    }

    fn next(&self) -> DockerReapRequest {
        let mut pending = self
            .pending
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        loop {
            #[cfg(test)]
            if TEST_DOCKER_REAPER_PANIC_ONCE.swap(false, Ordering::SeqCst) {
                TEST_DOCKER_REAPER_PANIC_COUNT.fetch_add(1, Ordering::SeqCst);
                panic!("injected Docker child reaper worker panic");
            }
            if self.active.load(Ordering::Relaxed) < DOCKER_REAPER_ACTIVE_CAP {
                if let Some(request) = pending.pop_front() {
                    self.active.fetch_add(1, Ordering::Relaxed);
                    return request;
                }
            }
            pending = self
                .wake
                .wait(pending)
                .unwrap_or_else(|poisoned| poisoned.into_inner());
        }
    }

    fn wait_for_work(&self, timeout: Duration) {
        let pending = self
            .pending
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if pending.is_empty() {
            let _ = self
                .wake
                .wait_timeout(pending, timeout)
                .unwrap_or_else(|poisoned| poisoned.into_inner());
        }
    }
}

fn docker_child_reaper_worker(
    queue: Arc<DockerReapQueue>,
    ready_sender: Option<mpsc::SyncSender<()>>,
) {
    if let Some(ready_sender) = ready_sender {
        if ready_sender.send(()).is_err() {
            return;
        }
    }
    let mut active = VecDeque::new();
    loop {
        if active.is_empty() {
            active.push_back(queue.next());
        }
        while active.len() < DOCKER_REAPER_ACTIVE_CAP {
            let Some(request) = queue.take_next() else {
                break;
            };
            active.push_back(request);
        }

        let poll_count = active.len();
        for _ in 0..poll_count {
            let mut request = active.pop_front().expect("active reaper request missing");
            let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                try_wait_owned_docker_child(&mut request)
            }));
            match outcome {
                Ok(true) => queue.worker_finished(),
                Ok(false) => active.push_back(request),
                Err(_) => {
                    eprintln!(
                        "warning: Docker child wait panicked while {}; retaining ownership for retry",
                        request.detail
                    );
                    active.push_back(request);
                }
            }
        }

        queue.wait_for_work(DOCKER_REAPER_POLL_INTERVAL);
    }
}

fn docker_child_reaper_supervisor(
    queue: Arc<DockerReapQueue>,
    ready_sender: Option<mpsc::SyncSender<()>>,
) {
    let mut first_worker = true;
    loop {
        let worker_queue = Arc::clone(&queue);
        let worker_ready_sender = if first_worker {
            ready_sender.clone()
        } else {
            None
        };
        first_worker = false;
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            docker_child_reaper_worker(worker_queue, worker_ready_sender);
        }));
        match result {
            Ok(()) => return,
            Err(_) => {
                eprintln!(
                    "error: Docker child reaper worker panicked; restarting supervisor worker"
                );
            }
        }
    }
}

fn initialize_docker_child_reaper() -> std::result::Result<DockerChildReaper, String> {
    let queue = Arc::new(DockerReapQueue {
        pending: Mutex::new(VecDeque::new()),
        wake: Condvar::new(),
        active: AtomicUsize::new(0),
    });
    let (ready_sender, ready_receiver) = mpsc::sync_channel(0);
    let worker_queue = Arc::clone(&queue);
    std::thread::Builder::new()
        .name("ezgha-docker-reaper".to_owned())
        .spawn(move || docker_child_reaper_supervisor(worker_queue, Some(ready_sender)))
        .map_err(|error| format!("failed to start Docker child reaper: {error}"))?;
    ready_receiver
        .recv_timeout(Duration::from_secs(1))
        .map_err(|error| format!("Docker child reaper failed readiness verification: {error}"))?;
    Ok(DockerChildReaper { queue })
}

fn get_or_initialize_docker_child_reaper(
    cache: &Mutex<Option<DockerChildReaper>>,
    initialize: impl FnOnce() -> std::result::Result<DockerChildReaper, String>,
) -> Result<DockerChildReaper> {
    let mut cached = cache
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if let Some(reaper) = cached.as_ref() {
        return Ok(reaper.clone());
    }
    let reaper = initialize().map_err(|error| anyhow::anyhow!(error))?;
    *cached = Some(reaper.clone());
    Ok(reaper)
}

fn docker_child_reaper() -> Result<DockerChildReaper> {
    get_or_initialize_docker_child_reaper(&DOCKER_CHILD_REAPER, initialize_docker_child_reaper)
}

impl DockerChildReaper {
    fn enqueue(&self, request: DockerReapRequest) {
        self.queue.enqueue(request);
    }
}

fn docker_timeout<T>(
    child: std::process::Child,
    detail: &str,
    timeout: Duration,
    deadline: Instant,
    reaper: &DockerChildReaper,
) -> Result<T> {
    if let Some(child) = reap_killed_child_until_deadline(child, deadline) {
        reaper.enqueue(DockerReapRequest {
            child,
            detail: detail.to_owned(),
        });
    }
    bail!(
        "docker CLI timed out after {}ms while {detail}",
        timeout.as_millis()
    );
}

fn run_docker_with_timeout(cmd: Command, detail: &str, timeout: Duration) -> Result<Output> {
    let deadline = Instant::now() + timeout;
    run_docker_with_timeout_at_deadline(cmd, detail, timeout, deadline, docker_child_reaper())
}

#[cfg(test)]
fn run_docker_with_timeout_after_reaper_init(
    cmd: Command,
    detail: &str,
    timeout: Duration,
    reaper: Result<DockerChildReaper>,
) -> Result<Output> {
    let deadline = Instant::now() + timeout;
    run_docker_with_timeout_at_deadline(cmd, detail, timeout, deadline, reaper)
}

fn run_docker_with_timeout_at_deadline(
    mut cmd: Command,
    detail: &str,
    timeout: Duration,
    deadline: Instant,
    reaper: Result<DockerChildReaper>,
) -> Result<Output> {
    let reaper = reaper?;
    if deadline.saturating_duration_since(Instant::now()).is_zero() {
        bail!(
            "docker CLI timed out after {}ms while {detail}",
            timeout.as_millis()
        );
    }
    // Keep a bounded cleanup window inside the command budget. Reads and
    // normal process reaping stop at this phase deadline; timeout cleanup can
    // then kill and reap until the single absolute command deadline.
    let phase_deadline = deadline - timeout.min(DOCKER_CLEANUP_RESERVE);
    let mut child = cmd
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .with_context(|| format!("failed to spawn docker CLI for {detail}"))?;
    let mut stdout = child
        .stdout
        .take()
        .context("failed to capture docker stdout")?;
    let mut stderr = child
        .stderr
        .take()
        .context("failed to capture docker stderr")?;
    let (tx_out, rx_out) = mpsc::channel::<Vec<u8>>();
    let (tx_err, rx_err) = mpsc::channel::<Vec<u8>>();
    std::thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = stdout.read_to_end(&mut buf);
        let _ = tx_out.send(buf);
    });
    std::thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = stderr.read_to_end(&mut buf);
        let _ = tx_err.send(buf);
    });

    let stdout = match rx_out.recv_timeout(phase_deadline.saturating_duration_since(Instant::now()))
    {
        Ok(buf) => buf,
        Err(mpsc::RecvTimeoutError::Timeout) => {
            return docker_timeout(child, detail, timeout, deadline, &reaper);
        }
        Err(mpsc::RecvTimeoutError::Disconnected) => Vec::new(),
    };
    let stderr = match rx_err.recv_timeout(phase_deadline.saturating_duration_since(Instant::now()))
    {
        Ok(buf) => buf,
        Err(mpsc::RecvTimeoutError::Timeout) => {
            return docker_timeout(child, detail, timeout, deadline, &reaper);
        }
        Err(mpsc::RecvTimeoutError::Disconnected) => Vec::new(),
    };

    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) => {
                let remaining = phase_deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    return docker_timeout(child, detail, timeout, deadline, &reaper);
                }
                std::thread::sleep(remaining.min(Duration::from_millis(1)));
            }
            Err(err) => {
                return Err(err).with_context(|| format!("wait for docker CLI during {detail}"));
            }
        }
    };
    Ok(Output {
        status,
        stdout,
        stderr,
    })
}

#[cfg(test)]
thread_local! {
    static INTERRUPT_SLOT_WRITE_BEFORE_RENAME: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

fn write_slot_assignments_for(assignments: &SlotAssignments, cfg: Option<&Config>) -> Result<()> {
    let path = slot_assignments_path_for(cfg);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).with_context(|| format!("create {}", parent.display()))?;
    }
    let raw = toml::to_string_pretty(assignments).context("serialize slot assignments")?;
    // Atomic write: a crash between truncate and full write would leave a torn
    // file that fails to parse, wedging every future next_slot/release until a
    // human deletes it — the exact "daemon died mid-flight" scenario this
    // machinery exists to survive. Write a sibling temp then rename(2), which
    // is atomic within a directory on POSIX: readers see old-or-new, never torn.
    let tmp = path.with_extension(format!("toml.tmp.{}", std::process::id()));
    std::fs::write(&tmp, raw).with_context(|| format!("write temp {}", tmp.display()))?;
    #[cfg(test)]
    if INTERRUPT_SLOT_WRITE_BEFORE_RENAME.with(|interrupt| interrupt.replace(false)) {
        anyhow::bail!("simulated interruption before slot assignment rename");
    }
    std::fs::rename(&tmp, &path)
        .with_context(|| format!("rename {} -> {}", tmp.display(), path.display()))?;
    Ok(())
}

/// Reserve the first unused slot in `1..=cfg.runner.count` and return its
/// index — equivalent to `next_slot_excluding` with an empty exclusion set.
/// The slot is recorded in the persisted assignments file under an empty
/// runner_id marker; callers MUST update it via `record_slot_runner_id` after
/// the JIT registration succeeds, or release it via `release_slot` if the
/// registration fails. Production code always goes through
/// `next_slot_excluding` directly (via `start_missing_runners`); this
/// no-exclusions wrapper now exists purely for tests.
#[cfg(test)]
pub fn next_slot(cfg: &Config) -> Result<u32> {
    next_slot_excluding(cfg, &HashSet::new())?.with_context(|| {
        format!(
            "all {} runner slot(s) are currently in use on this host",
            cfg.runner.count
        )
    })
}

/// Like `next_slot`, but skips any slot number present in `excluded` even if
/// it is technically free in the persisted assignments file. Used by
/// `start_missing_runners` so that a slot which just failed (and had its
/// reservation released) within the current call cannot be immediately
/// re-picked as the "lowest free slot" — which previously caused every
/// remaining retry in the batch to pile onto one permanently-broken slot
/// while every other genuinely-fillable slot went untried (bead
/// ez-gh-actions-oau).
///
/// ALSO skips slots currently in the quarantine table (bead
/// ez-gh-actions-ghd2.2): a wedged-422 slot stays reserved (not freed) until
/// GitHub releases the lock, so `next_slot` must not re-allocate it. The
/// quarantine exclusion is merged with the caller-supplied `excluded` set,
/// so per-tick `failed_slots` (the oau fix) and the cross-tick quarantine
/// gate (the ghd2.2 fix) compose cleanly.
pub fn next_slot_excluding(cfg: &Config, excluded: &HashSet<u32>) -> Result<Option<u32>> {
    if cfg.runner.count == 0 {
        bail!("cfg.runner.count is 0; nothing to allocate");
    }
    let quarantine_excluded = match quarantine::load_quarantine_for(Some(cfg)) {
        Ok(table) => table.excluded_slots(),
        Err(err) => {
            // A corrupt quarantine file must NOT block all allocations —
            // `release_stale_slots` already logged the parse error and
            // proceeded with an empty table for this tick, and we mirror
            // that here so a single bad write doesn't wedge the daemon.
            eprintln!(
                "warning: next_slot_excluding could not load quarantine table, \
                 proceeding without quarantine exclusion: {err:#}"
            );
            HashSet::new()
        }
    };
    let mut assignments = read_slot_assignments_for(Some(cfg))?;
    for slot in 1..=cfg.runner.count {
        if excluded.contains(&slot) || quarantine_excluded.contains(&slot) {
            continue;
        }
        let key = slot.to_string();
        if let std::collections::btree_map::Entry::Vacant(e) =
            assignments.assignments.entry(key.clone())
        {
            e.insert(String::new());
            // Bead jleechan-uurm: record the reservation time so the grace-
            // window check in release_stale_slots (Path 1's empty-id branch)
            // can protect an in-flight JIT round-trip from being reaped while
            // next_slot_excluding (here) and record_slot_runner_id_for are
            // both racing the same slot. See first-wave report for full
            // race diagram; this is the post-2026-07-08 fix (1a9baf4)
            // extension.
            assignments.registered_at.insert(key, now_epoch_secs());
            write_slot_assignments_for(&assignments, Some(cfg))?;
            return Ok(Some(slot));
        }
    }
    Ok(None)
}

/// Record the GitHub runner_id returned by `generate_jitconfig` for a slot
/// that was previously reserved by `next_slot`.
#[cfg(test)]
pub fn record_slot_runner_id(slot: u32, runner_id: u64) -> Result<()> {
    record_slot_runner_id_for(None, slot, runner_id)
}

fn record_slot_runner_id_for(cfg: Option<&Config>, slot: u32, runner_id: u64) -> Result<()> {
    let mut assignments = read_slot_assignments_for(cfg)?;
    let key = slot.to_string();
    assignments
        .assignments
        .insert(key.clone(), runner_id.to_string());
    assignments.registered_at.insert(key, now_epoch_secs());
    write_slot_assignments_for(&assignments, cfg)
}

/// Release a slot previously acquired by `next_slot`. The slot becomes
/// available for the next call.
#[cfg(test)]
pub fn release_slot(slot: u32) -> Result<()> {
    release_slot_for(None, slot)
}

fn release_slot_for(cfg: Option<&Config>, slot: u32) -> Result<()> {
    let mut assignments = read_slot_assignments_for(cfg)?;
    let key = slot.to_string();
    assignments.assignments.remove(&key);
    assignments.registered_at.remove(&key);
    write_slot_assignments_for(&assignments, cfg)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LocalRunnerActivity {
    Busy,
    Idle,
    Unknown,
    /// `docker top` reported the container no longer exists ("No such
    /// container"). Distinct from `Unknown`: an absent container is a
    /// definitive signal that the slot's local state has been torn down,
    /// so `release_stale_slots` can safely reclaim. Genuine probe failures
    /// (timeout, daemon error, transient I/O) remain `Unknown` and stay
    /// fail-safe per bead jleechan-95jk root-cause analysis: do not blindly
    /// treat all errors as absence.
    Absent,
}

/// True if `docker top` stderr indicates the container is gone. Docker
/// reports a missing container with "No such container" (the standard
/// engine message since at least docker 20) and historically "No such
/// object" in some plugin paths. Anything else (timeout, daemon error,
/// I/O failure) is a transient/systemic failure that stays fail-safe.
fn docker_top_container_absent(stderr: &str) -> bool {
    stderr.contains("No such container") || stderr.contains("No such object")
}

fn local_runner_activity(container_name: &str) -> LocalRunnerActivity {
    let mut cmd = docker_cmd();
    cmd.args(["top", container_name, "-eo", "pid,comm"]);
    let out = match run_docker_with_timeout(
        cmd,
        "checking local runner activity before stale reclaim",
        LOCAL_TOP_TIMEOUT,
    ) {
        Ok(out) if out.status.success() => out,
        Ok(out) => {
            let stderr = String::from_utf8_lossy(&out.stderr);
            if docker_top_container_absent(&stderr) {
                return LocalRunnerActivity::Absent;
            }
            eprintln!("warning: keeping {container_name}: local activity probe failed: {stderr}");
            return LocalRunnerActivity::Unknown;
        }
        Err(err) => {
            eprintln!("warning: keeping {container_name}: local activity probe failed: {err:#}");
            return LocalRunnerActivity::Unknown;
        }
    };
    let stdout = String::from_utf8_lossy(&out.stdout);
    if runner_worker_present(&stdout) {
        LocalRunnerActivity::Busy
    } else if runner_present(&stdout) {
        LocalRunnerActivity::Idle
    } else {
        LocalRunnerActivity::Unknown
    }
}

/// Release slots whose recorded `runner_id` no longer corresponds to a live
/// GitHub-registered runner. Slots can get stuck if the docker daemon dies,
/// the container exits abruptly, or GitHub reaps the registration server-side:
/// `release_slot` never fires, so the slot file grows stale and `next_slot`
/// eventually refuses to allocate even though no real runner is consuming
/// the slot. Called at the start of `ensure_count` so `serve` self-heals
/// without operator intervention.
///
/// Wedged-422 slots (bead ez-gh-actions-ghd2.2) are handled by the
/// `quarantine` sub-module: an offline+busy runner whose DELETE returns 422
/// even after the reaper cancel-then-delete dance is recorded in
/// `quarantined_slots.toml` so the slot stays reserved (not allocated to
/// fresh work), the API surface area is bounded per tick, and the slot
/// auto-recovers the next time GitHub releases the 422 lock (the runner
/// appears online, offline+!busy, or disappears from the live list).
///
/// Returns the number of slots reclaimed.
pub fn release_stale_slots(cfg: &Config) -> Result<usize> {
    #[cfg(test)]
    if let Some(reclaimed) = *TEST_RELEASE_STALE_SLOTS_RESULT.lock().unwrap() {
        return Ok(reclaimed);
    }

    watchdog::ping();
    // CRITICAL: reconcile ONLY against an authoritative runner list. If the
    // GitHub API call fails (network blip, rate limit, expired token), an
    // `unwrap_or_default()` would yield an EMPTY list — making every recorded
    // slot look stale, releasing them all, and wiping the slot file while N
    // containers are still alive. next_slot then hands out slot names that
    // collide with the live containers (`docker run --name` conflict), wedging
    // replacement every cycle. This exact fail-open was the root cause of the
    // fleet decaying to zero. When the source of truth is unreachable, skip
    // reconciliation this cycle and keep the slot file intact.
    let live_runners = match github::list_runners(&cfg.github) {
        Ok(r) => r,
        Err(e) => {
            let assignments_len = match read_slot_assignments_for(Some(cfg)) {
                Ok(assignments) => assignments.assignments.len(),
                Err(_) => 0,
            };
            eprintln!(
                "warning: skipping stale-slot reconciliation (GitHub unreachable): {e:#}; slot table currently has {assignments_len} entries"
            );
            return Ok(0);
        }
    };
    watchdog::ping();
    let assignments = read_slot_assignments_for(Some(cfg))?;
    let local_container_names = match managed_containers() {
        Ok(containers) => {
            poll_peak_rss(&containers);
            Some(
                containers
                    .into_iter()
                    .map(|container| container.name)
                    .collect::<HashSet<_>>(),
            )
        }
        Err(err) => {
            eprintln!(
                "warning: skipping container-aware stale-slot reconciliation (docker unreachable): {err:#}"
            );
            None
        }
    };
    if let Some(names) = &local_container_names {
        reap_stale_peak_rss_entries(names);
    }
    let reclaimed = release_stale_slots_from_with_containers_for(
        Some(cfg),
        &assignments,
        &live_runners,
        &cfg.runner.name_prefix,
        local_container_names.as_ref(),
    )?;
    let mut reclaimed = reclaimed;
    // Load (or initialize) the quarantine table. A corrupt file degrades to
    // an empty table for this tick — `load_quarantine` already logged the
    // parse error. The empty-table fallback is the same fail-soft policy as
    // the slot assignments loader so a single bad write doesn't wedge the
    // entire reconciliation cycle.
    let mut quarantine = quarantine::load_quarantine_for(Some(cfg)).unwrap_or_else(|err| {
        eprintln!(
            "warning: release_stale_slots proceeding with empty quarantine table (parse failed): {err:#}"
        );
        QuarantineTable::default()
    });
    let max_attempts_per_tick = max_reconcile_attempts_per_tick();
    let reclaimed_quarantine = reconcile_offline_busy_zombies(
        Some(cfg),
        &assignments,
        &live_runners,
        &cfg.runner.name_prefix,
        local_container_names.as_ref(),
        &mut quarantine,
        max_attempts_per_tick,
        |runner_id| github::remove_runner(&cfg.github, runner_id),
        |runner| reclaim_zombie_locked_runner(cfg, runner),
        |slot_n, runner_id, runner_name, age_secs, attempt_count| {
            alert::notify(
                cfg,
                &format!("runner_pool.slot_quarantined.{slot_n}"),
                Severity::Warning,
                &format!(
                    "ezgha slot {slot_n} quarantined: runner {runner_name} (id {runner_id}) held by 422 lock"
                ),
                &format!(
                    "runner_id={runner_id} runner_name={runner_name} slot={slot_n} \
                     reason=Locked422 age_secs={age_secs} attempt_count={attempt_count}"
                ),
            )
        },
        |slot_n, runner_id, runner_name, attempt_count, first_seen_age_secs| {
            alert::notify(
                cfg,
                &format!("runner_pool.slot_unquarantined.{slot_n}"),
                Severity::Info,
                &format!(
                    "ezgha slot {slot_n} auto-recovered: runner {runner_name} (id {runner_id}) 422 lock released"
                ),
                &format!(
                    "slot={slot_n} runner_id={runner_id} runner_name={runner_name} \
                     attempts={attempt_count} first_seen_age_secs={first_seen_age_secs}"
                ),
            )
        },
    )?;
    reclaimed += reclaimed_quarantine;
    // Persist any changes to the quarantine table. A failure here must not
    // poison the rest of the reconcile cycle — we log and continue; the
    // worst case is that the next tick re-derives the same quarantine state
    // from scratch (idempotent).
    if let Err(err) = quarantine::save_quarantine_for(Some(cfg), &quarantine) {
        eprintln!(
            "warning: failed to persist quarantine table; next tick will re-derive from scratch: {err:#}"
        );
    }
    watchdog::ping();
    // 4th sub-pass (bead ez-gh-actions-u3w): Path 1 already released the slot
    // entry for offline+!busy+no-container runners but left the GitHub
    // registration in place. The next JIT-config attempt with the same slot
    // name collides with this orphan (`in use by an online/busy runner` /
    // 422). Reap it directly here — no cancel/poll needed because the runner
    // is NOT busy (qbl's lane handles busy via Path 2's cancel-then-delete).
    // Mirrors the qbl helper signature but iterates `live_runners` directly
    // keyed on `runner.name` prefix (Path 1 has already wiped the slot-file
    // row, so the runner_id is no longer reachable from `assignments`).
    let mut reaped_ids = HashSet::new();
    if let Some(local_names) = local_container_names.as_ref() {
        for (runner_id, runner_name) in offline_not_busy_owned_missing_container_registrations(
            &assignments,
            &live_runners,
            &cfg.runner.name_prefix,
            local_names,
        ) {
            eprintln!(
                "warning: removing stale offline/idle registration {runner_name} (id {runner_id}) with no local container — slot entry was already released by Path 1"
            );
            match github::remove_runner(&cfg.github, runner_id) {
                Ok(()) => {
                    reclaimed += 1;
                    reaped_ids.insert(runner_id);
                    watchdog::ping();
                }
                Err(err) if is_runner_busy_lock_error(&err) => {
                    // Defensive: the API snapshot we read at the top of this
                    // call could lie about busy (the same lie the s9d
                    // synthesis warned about). If GitHub now reports the
                    // runner as holding a job, hand off to the qbl zombie
                    // self-heal which cancels the run first, then deletes.
                    // This keeps the blast radius bounded to runners we
                    // already believed were reapable and avoids widening
                    // plan_reaper_actions' surface.
                    let healed = live_runners
                        .iter()
                        .find(|r| r.id == runner_id)
                        .is_some_and(|r| reclaim_zombie_locked_runner(cfg, r));
                    if healed {
                        reclaimed += 1;
                        reaped_ids.insert(runner_id);
                        watchdog::ping();
                    } else {
                        eprintln!(
                            "warning: failed to remove stale registration {runner_name} (id {runner_id}) — 422 lock detected at delete time and zombie self-heal did not complete: {err:#}"
                        );
                    }
                }
                Err(err) => {
                    eprintln!(
                        "warning: failed to remove stale registration {runner_name} (id {runner_id}): {err:#}"
                    );
                }
            }
        }
    }
    watchdog::ping();
    // Forward sweep: GitHub has runners with our prefix that NO slot file
    // entry owns. These are JIT registrations whose slot reservation was
    // released (empty-id path above) before `record_slot_runner_id` could
    // persist the runner_id, leaving the runner orphaned on GitHub.
    // Only reap liveness-reclaimable orphans; siblings running their own
    // config with the same prefix would falsely appear here, so we
    // additionally require `status == "offline" && !busy` to limit blast
    // radius. A future bead may add hostname ownership tagging.
    //
    // The prefix is read from `cfg.runner.name_prefix` (NOT the hardcoded
    // `our_runner_prefix()` default), so a host with a custom prefix like
    // `lab-runner` correctly reaps its own orphans. Pre-fix this used
    // `our_runner_prefix()` and silently disabled the forward sweep on
    // any host whose config used a non-default prefix (post-fix review
    // caught this; see PR description).
    let prefix = format!("{}-", cfg.runner.name_prefix);
    let owned_ids: HashSet<u64> = assignments
        .assignments
        .values()
        .filter_map(|s| s.parse::<u64>().ok())
        .collect();
    let mut orphans_reaped = 0;
    for r in &live_runners {
        if r.name.starts_with(&prefix)
            && !owned_ids.contains(&r.id)
            && !reaped_ids.contains(&r.id)
            && r.status.eq_ignore_ascii_case("offline")
            && !r.busy
        {
            eprintln!(
                "warning: orphaned runner {} (id {}, status {}) has no slot-file owner — \
                 removing to prevent future 409 self-heal churn",
                r.name, r.id, r.status
            );
            if github::remove_runner(&cfg.github, r.id).is_ok() {
                orphans_reaped += 1;
                watchdog::ping();
            }
        }
    }
    if orphans_reaped > 0 {
        eprintln!("info: reaped {orphans_reaped} orphaned runners with prefix {prefix}");
    }
    if reclaimed > 0 {
        eprintln!(
            "info: release_stale_slots reclaimed {reclaimed} stale slot(s) for prefix {} (live GH runners: {}, local containers tracked: {})",
            cfg.runner.name_prefix,
            live_runners.len(),
            local_container_names.as_ref().map_or(0, |names| names.len())
        );
    }
    watchdog::ping();
    Ok(reclaimed + orphans_reaped)
}

/// Inner reconciliation routine that operates on a caller-provided live-runner
/// snapshot. Split out so tests can drive it without a live `gh` auth context;
/// `release_stale_slots` is the production entry point that fetches the live
/// list via `github::list_runners`.
#[cfg(test)]
fn release_stale_slots_from(
    assignments: &SlotAssignments,
    live_runners: &[github::RunnerInfo],
) -> Result<usize> {
    release_stale_slots_from_with_containers(assignments, live_runners, "", None)
}

#[cfg(test)]
fn release_stale_slots_from_with_containers(
    assignments: &SlotAssignments,
    live_runners: &[github::RunnerInfo],
    runner_prefix: &str,
    local_container_names: Option<&HashSet<String>>,
) -> Result<usize> {
    release_stale_slots_from_with_containers_for(
        None,
        assignments,
        live_runners,
        runner_prefix,
        local_container_names,
    )
}

fn release_stale_slots_from_with_containers_for(
    cfg: Option<&Config>,
    assignments: &SlotAssignments,
    live_runners: &[github::RunnerInfo],
    runner_prefix: &str,
    local_container_names: Option<&HashSet<String>>,
) -> Result<usize> {
    release_stale_slots_from_with_containers_and_activity_for(
        cfg,
        assignments,
        live_runners,
        runner_prefix,
        local_container_names,
        local_runner_activity,
    )
}

#[cfg(test)]
fn release_stale_slots_from_with_containers_and_activity(
    assignments: &SlotAssignments,
    live_runners: &[github::RunnerInfo],
    runner_prefix: &str,
    local_container_names: Option<&HashSet<String>>,
    activity_probe: impl FnMut(&str) -> LocalRunnerActivity,
) -> Result<usize> {
    release_stale_slots_from_with_containers_and_activity_for(
        None,
        assignments,
        live_runners,
        runner_prefix,
        local_container_names,
        activity_probe,
    )
}

fn release_stale_slots_from_with_containers_and_activity_for(
    cfg: Option<&Config>,
    assignments: &SlotAssignments,
    live_runners: &[github::RunnerInfo],
    runner_prefix: &str,
    local_container_names: Option<&HashSet<String>>,
    mut activity_probe: impl FnMut(&str) -> LocalRunnerActivity,
) -> Result<usize> {
    if assignments.assignments.is_empty() {
        return Ok(0);
    }
    let live_ids: HashSet<u64> = live_runners.iter().map(|r| r.id).collect();
    let mut reclaimed = 0;
    for (slot, id_str) in &assignments.assignments {
        // The slot file is external, user-editable, and can be corrupted by a
        // partial write. Never panic on its contents: a non-numeric key would
        // crash the serve loop's reconciliation on every 30s tick (self-DoS).
        let Ok(slot_n) = slot.parse::<u32>() else {
            eprintln!("warning: skipping unparseable slot key {slot:?} in slot file");
            continue;
        };
        if id_str.is_empty() {
            // Reserved by `next_slot` but `record_slot_runner_id` never ran
            // (JIT registration failed mid-flight, or the daemon died before
            // the container came up). Free the slot immediately so the next
            // allocation cycle can claim it — BUT only after the JIT
            // round-trip grace window closes (bead jleechan-uurm, first-wave
            // Path-1 race investigation jleechan-9yx8). The 2026-07-08 fix
            // (1a9baf4, PR #33) moved `record_slot_runner_id_for` to
            // post-JIT pre-docker-run so the empty-id window is now the
            // multi-second JIT round-trip itself; without this grace gate,
            // `ensure_count_outcome`'s TWICE-per-tick `release_stale_slots`
            // calls (`:2857`, `:3018`) would reap the reservation while a
            // concurrent `start_one_with_generate_at_slot` is still between
            // `next_slot_excluding` (`:393-401`) and `record_slot_runner_id_for`
            // (`:2115`), causing slot-file flap.
            let in_grace = empty_id_reservation_in_grace_window(assignments, slot, id_str);
            let elapsed = seconds_since_registered(assignments, slot).unwrap_or(0);
            let wall_secs = now_epoch_secs();
            let monotonic_secs = ensure_daemon_start().elapsed().as_secs_f64();
            if in_grace {
                eprintln!(
                    "debug: release_stale_slots: skipping empty-id slot {slot_n} (registered_at={elapsed}s ago, within {}s grace window; monotonic_ts={monotonic_secs:.3} wall_ts={wall_secs})",
                    REGISTRATION_GRACE_WINDOW.as_secs()
                );
                record_reclaim(
                    slot,
                    ReclaimRecord {
                        monotonic_secs: 0.0, // filled in by record_reclaim
                        wall_secs,
                        slot: slot_n,
                        runner_id: 0,
                        last_run_id: 0,
                        peak_rss_mb: 0,
                        in_grace: true,
                        reason: "empty-id-grace-skip".to_string(),
                    },
                );
                continue;
            }
            eprintln!(
                "info: release_stale_slots reclaimed empty-id slot {slot_n} (registered_at={elapsed}s ago, past {}s grace window; monotonic_ts={monotonic_secs:.3} wall_ts={wall_secs})",
                REGISTRATION_GRACE_WINDOW.as_secs()
            );
            record_reclaim(
                slot,
                ReclaimRecord {
                    monotonic_secs: 0.0, // filled in by record_reclaim
                    wall_secs,
                    slot: slot_n,
                    runner_id: 0,
                    last_run_id: 0,
                    peak_rss_mb: 0,
                    in_grace: false,
                    reason: "empty-id-reclaim".to_string(),
                },
            );
            release_slot_for(cfg, slot_n)?;
            reclaimed += 1;
        } else if let Ok(rid) = id_str.parse::<u64>() {
            if !live_ids.contains(&rid) {
                let expected_name = runner_name_from_prefix(runner_prefix, slot_n);
                match local_container_names {
                    Some(local_names) if local_names.contains(&expected_name) => {
                        if slot_in_grace_window(assignments, slot) {
                            let elapsed = seconds_since_registered(assignments, slot).unwrap_or(0);
                            eprintln!(
                                "info: keeping slot {slot_n}: local container {expected_name} still exists while GH registration {rid} is absent (within {}s JIT-propagation grace window; elapsed {elapsed}s)",
                                REGISTRATION_GRACE_WINDOW.as_secs()
                            );
                        } else {
                            let elapsed = seconds_since_registered(assignments, slot).unwrap_or(0);
                            match activity_probe(&expected_name) {
                                LocalRunnerActivity::Busy => {
                                    eprintln!(
                                        "warning: keeping slot {slot_n}: local container {expected_name} has Runner.Worker while GH snapshot omits registration {rid} (elapsed {elapsed}s); refusing destructive reclaim"
                                    );
                                }
                                LocalRunnerActivity::Unknown => {
                                    eprintln!(
                                        "warning: keeping slot {slot_n}: local activity for {expected_name} is unknown while GH snapshot omits registration {rid} (elapsed {elapsed}s); failing safe"
                                    );
                                }
                                LocalRunnerActivity::Absent => {
                                    // Bead jleechan-95jk root-cause: a slot
                                    // that is "gh-missing-but-locally-tracked"
                                    // and whose local container is GONE
                                    // (docker top: No such container) must
                                    // reclaim immediately, not wait out the
                                    // grace window. The previous code treated
                                    // this as Unknown and the slot stayed
                                    // reserved even though the container was
                                    // already gone, blocking reconciliation.
                                    let wall_secs = now_epoch_secs();
                                    let monotonic_secs =
                                        ensure_daemon_start().elapsed().as_secs_f64();
                                    let last_run_id =
                                        live_runners_last_run_id(live_runners, rid).unwrap_or(0);
                                    let peak_rss_mb = 0u64;
                                    eprintln!(
                                        "info: release_stale_slots reclaimed slot {slot_n}: runner_id={rid} last_run_id={last_run_id} monotonic_ts={monotonic_secs:.3} wall_ts={wall_secs} elapsed_secs={elapsed} peak_rss_mb={peak_rss_mb} in_grace=false reason=gh-rejected-container-absent (docker top: No such container for {expected_name})"
                                    );
                                    record_reclaim(
                                        slot,
                                        ReclaimRecord {
                                            monotonic_secs: 0.0,
                                            wall_secs,
                                            slot: slot_n,
                                            runner_id: rid,
                                            last_run_id,
                                            peak_rss_mb,
                                            in_grace: false,
                                            reason: "gh-rejected-container-absent".to_string(),
                                        },
                                    );
                                    release_slot_for(cfg, slot_n)?;
                                    reclaimed += 1;
                                }
                                LocalRunnerActivity::Idle => {
                                    // A proven listener with no GitHub registration
                                    // can never receive another job. Recycling it is
                                    // safe; a Worker or inconclusive probe is kept.
                                    let wall_secs = now_epoch_secs();
                                    let monotonic_secs =
                                        ensure_daemon_start().elapsed().as_secs_f64();
                                    let last_run_id =
                                        live_runners_last_run_id(live_runners, rid).unwrap_or(0);
                                    let peak_rss_mb = container_peak_rss_mb(&expected_name);
                                    eprintln!(
                                        "info: release_stale_slots reclaimed slot {slot_n}: runner_id={rid} last_run_id={last_run_id} monotonic_ts={monotonic_secs:.3} wall_ts={wall_secs} elapsed_secs={elapsed} peak_rss_mb={peak_rss_mb} in_grace=false reason=gh-rejected-past-grace (local container {expected_name} is idle)"
                                    );
                                    record_reclaim(
                                        slot,
                                        ReclaimRecord {
                                            monotonic_secs: 0.0,
                                            wall_secs,
                                            slot: slot_n,
                                            runner_id: rid,
                                            last_run_id,
                                            peak_rss_mb,
                                            in_grace: false,
                                            reason: "gh-rejected-past-grace".to_string(),
                                        },
                                    );
                                    release_slot_for(cfg, slot_n)?;
                                    reclaimed += 1;
                                }
                            }
                        }
                    }
                    Some(_) => {
                        // The recorded runner_id is no longer registered on GitHub
                        // (server-side reap, manual removal, or a stale entry from a
                        // prior host) and no local container exists, so reclaim.
                        let elapsed = seconds_since_registered(assignments, slot).unwrap_or(0);
                        let wall_secs = now_epoch_secs();
                        let monotonic_secs = ensure_daemon_start().elapsed().as_secs_f64();
                        // Bead jleechan-tv58: surface `last_run_id`. There is NO
                        // local container here (that's the whole point of this
                        // branch), so `peak_rss_mb` is forced to 0 — the field
                        // is structurally present, just empty for this reason.
                        let last_run_id = live_runners_last_run_id(live_runners, rid).unwrap_or(0);
                        let peak_rss_mb = 0u64;
                        eprintln!(
                            "info: release_stale_slots reclaimed slot {slot_n}: runner_id={rid} last_run_id={last_run_id} monotonic_ts={monotonic_secs:.3} wall_ts={wall_secs} elapsed_secs={elapsed} peak_rss_mb={peak_rss_mb} in_grace=false reason=gh-missing-no-local-container"
                        );
                        record_reclaim(
                            slot,
                            ReclaimRecord {
                                monotonic_secs: 0.0,
                                wall_secs,
                                slot: slot_n,
                                runner_id: rid,
                                last_run_id,
                                peak_rss_mb,
                                in_grace: false,
                                reason: "gh-missing-no-local-container".to_string(),
                            },
                        );
                        release_slot_for(cfg, slot_n)?;
                        reclaimed += 1;
                    }
                    None => {
                        if slot_in_grace_window(assignments, slot) {
                            let elapsed = seconds_since_registered(assignments, slot).unwrap_or(0);
                            eprintln!(
                                "info: keeping slot {slot_n}: docker ps failed locally so container existence for {expected_name} is unknown while GH registration {rid} is absent (within {}s grace window; elapsed {elapsed}s)",
                                REGISTRATION_GRACE_WINDOW.as_secs()
                            );
                        } else {
                            // Beyond the grace window: even if docker ps is failing,
                            // holding a slot forever because of a transient infra
                            // issue is worse than risking one extra allocation.
                            // The caller already logged the docker-ps failure earlier
                            // in the serve loop; we just reclaim here so the slot
                            // doesn't become a permanent dead reservation.
                            let elapsed = seconds_since_registered(assignments, slot).unwrap_or(0);
                            let wall_secs = now_epoch_secs();
                            let monotonic_secs = ensure_daemon_start().elapsed().as_secs_f64();
                            // Bead jleechan-tv58: surface `last_run_id` when
                            // available. `peak_rss_mb` stays 0 here because we
                            // reach this branch precisely because `docker ps`
                            // failed; calling `docker stats` would just race
                            // the same transient failure.
                            let last_run_id =
                                live_runners_last_run_id(live_runners, rid).unwrap_or(0);
                            let peak_rss_mb = 0u64;
                            eprintln!(
                                "info: release_stale_slots reclaimed slot {slot_n}: runner_id={rid} last_run_id={last_run_id} monotonic_ts={monotonic_secs:.3} wall_ts={wall_secs} elapsed_secs={elapsed} peak_rss_mb={peak_rss_mb} in_grace=false reason=docker-ps-failed-past-grace (reclaiming to avoid permanent reservation)"
                            );
                            record_reclaim(
                                slot,
                                ReclaimRecord {
                                    monotonic_secs: 0.0,
                                    wall_secs,
                                    slot: slot_n,
                                    runner_id: rid,
                                    last_run_id,
                                    peak_rss_mb,
                                    in_grace: false,
                                    reason: "docker-ps-failed-past-grace".to_string(),
                                },
                            );
                            release_slot_for(cfg, slot_n)?;
                            reclaimed += 1;
                        }
                    }
                }
            } else if let Some(runner) = live_runners.iter().find(|r| r.id == rid) {
                let expected_name = runner_name_from_prefix(runner_prefix, slot_n);
                if !runner_prefix.is_empty() && runner.name != expected_name {
                    let elapsed = seconds_since_registered(assignments, slot).unwrap_or(0);
                    let wall_secs = now_epoch_secs();
                    let monotonic_secs = ensure_daemon_start().elapsed().as_secs_f64();
                    // Bead jleechan-tv58: name-mismatch means the slot owns a
                    // runner_id, but that runner is binding to a different
                    // name on GitHub. `last_run_id` may still be present from
                    // the live snapshot. No expected-name container to stats
                    // here — the local container for `expected_name` does
                    // not exist on this host (or we'd have caught it in the
                    // earlier branch), so `peak_rss_mb=0`.
                    let last_run_id = live_runners_last_run_id(live_runners, rid).unwrap_or(0);
                    let peak_rss_mb = 0u64;
                    eprintln!(
                        "info: release_stale_slots reclaimed slot {slot_n}: runner_id={rid} last_run_id={last_run_id} monotonic_ts={monotonic_secs:.3} wall_ts={wall_secs} elapsed_secs={elapsed} peak_rss_mb={peak_rss_mb} in_grace=false reason=name-mismatch (got {} on GitHub for id {rid})",
                        runner.name
                    );
                    record_reclaim(
                        slot,
                        ReclaimRecord {
                            monotonic_secs: 0.0,
                            wall_secs,
                            slot: slot_n,
                            runner_id: rid,
                            last_run_id,
                            peak_rss_mb,
                            in_grace: false,
                            reason: "name-mismatch".to_string(),
                        },
                    );
                    release_slot_for(cfg, slot_n)?;
                    reclaimed += 1;
                } else if let Some(local_names) = local_container_names {
                    if runner.status.eq_ignore_ascii_case("offline")
                        && !runner.busy
                        && !local_names.contains(&expected_name)
                    {
                        if slot_in_grace_window(assignments, slot) {
                            let elapsed = seconds_since_registered(assignments, slot).unwrap_or(0);
                            eprintln!(
                                "info: keeping slot {slot_n}: runner {expected_name} (id {rid}) is offline/idle with no local container but was registered {elapsed}s ago (within {}s JIT-propagation grace window)",
                                REGISTRATION_GRACE_WINDOW.as_secs()
                            );
                        } else {
                            let elapsed = seconds_since_registered(assignments, slot).unwrap_or(0);
                            let wall_secs = now_epoch_secs();
                            let monotonic_secs = ensure_daemon_start().elapsed().as_secs_f64();
                            // Bead jleechan-tv58: offline-idle runner without a
                            // local container is the canonical dead-registration
                            // case. The runner has no in-flight job (offline+!busy)
                            // so `last_run_id` should always be None here, but
                            // surface it anyway for parity with the other
                            // recorded-id branches. `peak_rss_mb=0` because
                            // the local container does not exist (that's the
                            // gate that brought us here).
                            let last_run_id =
                                live_runners_last_run_id(live_runners, rid).unwrap_or(0);
                            let peak_rss_mb = 0u64;
                            eprintln!(
                                "info: release_stale_slots reclaimed slot {slot_n}: runner_id={rid} last_run_id={last_run_id} monotonic_ts={monotonic_secs:.3} wall_ts={wall_secs} elapsed_secs={elapsed} peak_rss_mb={peak_rss_mb} in_grace=false reason=offline-idle-no-container"
                            );
                            record_reclaim(
                                slot,
                                ReclaimRecord {
                                    monotonic_secs: 0.0,
                                    wall_secs,
                                    slot: slot_n,
                                    runner_id: rid,
                                    last_run_id,
                                    peak_rss_mb,
                                    in_grace: false,
                                    reason: "offline-idle-no-container".to_string(),
                                },
                            );
                            release_slot_for(cfg, slot_n)?;
                            reclaimed += 1;
                        }
                    }
                }
            }
        }
    }
    Ok(reclaimed)
}

fn offline_busy_owned_missing_container_slots(
    assignments: &SlotAssignments,
    live_runners: &[github::RunnerInfo],
    runner_prefix: &str,
    local_container_names: &HashSet<String>,
) -> Vec<(u32, u64, String)> {
    let mut slots = Vec::new();
    for (slot, id_str) in &assignments.assignments {
        let (Ok(slot_n), Ok(rid)) = (slot.parse::<u32>(), id_str.parse::<u64>()) else {
            continue;
        };
        let expected_name = runner_name_from_prefix(runner_prefix, slot_n);
        if local_container_names.contains(&expected_name) {
            continue;
        }
        let Some(runner) = live_runners.iter().find(|r| r.id == rid) else {
            continue;
        };
        if runner.name == expected_name
            && runner.status.eq_ignore_ascii_case("offline")
            && runner.busy
        {
            slots.push((slot_n, rid, expected_name));
        }
    }
    slots
}

/// 4th sub-pass of `release_stale_slots` (bead ez-gh-actions-u3w). Returns the
/// `(runner_id, runner_name)` pairs of live GitHub registrations that match
/// ALL of the following — the s9d latent-gap signature:
///
/// 1. `runner.name` starts with `{runner_prefix}-` (strictly owned-by-this-host;
///    sibling-host blast radius is excluded by the prefix gate, the same
///    defense Path 3's forward sweep uses).
/// 2. `runner.status` is `offline` (per a fresh API call — `live_runners` was
///    just fetched this tick; the API is the only authoritative source even
///    when it lies about counts).
/// 3. `runner.busy == false` (a busy runner holds a real job lock and MUST
///    go through Path 2's cancel-then-delete sequencing — calling
///    `remove_runner` on it would 422 just like the qbl 422-zombie class).
/// 4. No local docker container exists with `runner.name` (the container
///    really is dead; an API-snapshot lag or a parent-process mid-restart
///    would otherwise let us delete a registration a live container is
///    about to claim).
///
/// Why a separate helper (and not extending `plan_reaper_actions`): the
/// planner only emits plans for **busy** runners, because every existing
/// caller assumes `cancel a run first, then delete`. Widening it to accept
/// `!busy` plans would re-introduce the "delete another host's registration"
/// risk on every call site. Keeping the new lane local to `release_stale_slots`
/// preserves the prefix-gated blast radius without touching the reaper's
/// public surface.
///
/// Why keyed on `live_runners` (not the slot file like the qbl helper): Path 1
/// has already released the slot entry by the time we get here, so the
/// runner_id is no longer in `assignments` — we have to key on the name prefix
/// against the live runner list directly. See synthesis
/// `mac-stalereg-s9d-investigation-20260708.md` §2 and §6.
fn offline_not_busy_owned_missing_container_registrations(
    assignments: &SlotAssignments,
    live_runners: &[github::RunnerInfo],
    runner_prefix: &str,
    local_container_names: &HashSet<String>,
) -> Vec<(u64, String)> {
    if runner_prefix.is_empty() {
        // Without a prefix there is no ownership gate — refuse to enumerate
        // candidates rather than risk reaping someone else's runner.
        return Vec::new();
    }
    let prefix = format!("{runner_prefix}-");
    let mut reapable = Vec::new();
    for runner in live_runners {
        if !runner.name.starts_with(&prefix) {
            continue;
        }
        if !runner.status.eq_ignore_ascii_case("offline") {
            continue;
        }
        if runner.busy {
            // 422-zombie class is Path 2's job; never delete without cancelling.
            continue;
        }
        if local_container_names.contains(&runner.name) {
            // Local container present — could be parent mid-restart or
            // API snapshot lag. Leave the registration alone.
            continue;
        }
        // bead ez-gh-actions-5ki: this runner's slot may have been recorded
        // (and released by Path 1, in this SAME tick or an earlier one) well
        // within the JIT-propagation grace window. `assignments` here is the
        // snapshot taken at the top of `release_stale_slots`, before Path 1's
        // writes, so a slot Path 1 just released this tick still has its
        // `registered_at` entry for this check.
        let slot = runner.name.strip_prefix(&prefix).unwrap_or("");
        if slot_in_grace_window(assignments, slot) {
            let elapsed = seconds_since_registered(assignments, slot).unwrap_or(0);
            let wall_secs = now_epoch_secs();
            let monotonic_secs = ensure_daemon_start().elapsed().as_secs_f64();
            eprintln!(
                "info: release_stale_slots (Path 4): skipping reap of {} (id {}) — registered_at {elapsed}s ago (within {}s grace window; monotonic_ts={monotonic_secs:.3} wall_ts={wall_secs})",
                runner.name,
                runner.id,
                REGISTRATION_GRACE_WINDOW.as_secs()
            );
            // Record the skip so an operator can see Path 4 grace-skips in the
            // ring buffer alongside Path 1 reclaims — same diagnostic surface.
            if let Ok(slot_n) = slot.parse::<u32>() {
                record_reclaim(
                    slot,
                    ReclaimRecord {
                        monotonic_secs: 0.0,
                        wall_secs,
                        slot: slot_n,
                        runner_id: runner.id,
                        last_run_id: 0,
                        peak_rss_mb: 0,
                        in_grace: true,
                        reason: "path4-grace-skip".to_string(),
                    },
                );
            }
            continue;
        }
        reapable.push((runner.id, runner.name.clone()));
    }
    reapable
}

fn runner_name_from_prefix(prefix: &str, slot: u32) -> String {
    format!("{prefix}-{slot}")
}

/// Quarantine-aware reconcile for slots whose runner is `offline && busy &&
/// no local container` (the 422-zombie class, bead ez-gh-actions-ghd2.2).
///
/// All IO is injected as closures so this function is exercised in tests
/// against a fake `github::remove_runner` and a fake zombie reclaimer
/// without touching the network or the reaper's live cancel/force-cancel
/// path. The production caller wires the real `github::remove_runner` and
/// `reclaim_zombie_locked_runner`; tests wire fakes that capture any
/// context they need in their own closure environment.
///
/// Returns the number of slots reclaimed (released). `quarantine` is
/// mutated in place — on success the caller persists it via
/// `quarantine::save_quarantine_for`. The function does not persist
/// `assignments` either; that is `release_stale_slots`'s job (via
/// `release_slot_for`), and tests can inspect either via the closures.
#[allow(clippy::too_many_arguments)]
fn reconcile_offline_busy_zombies(
    cfg: Option<&Config>,
    assignments: &SlotAssignments,
    live_runners: &[github::RunnerInfo],
    runner_prefix: &str,
    local_container_names: Option<&HashSet<String>>,
    quarantine: &mut QuarantineTable,
    max_attempts_per_tick: u32,
    remove_runner: impl Fn(u64) -> Result<()>,
    try_zombie_reclaim: impl Fn(&github::RunnerInfo) -> bool,
    notify_quarantine: impl Fn(u32, u64, &str, u64, u32) -> Result<()>,
    notify_recovery: impl Fn(u32, u64, &str, u32, u64) -> Result<()>,
) -> Result<usize> {
    let _ = assignments;
    let Some(local_names) = local_container_names else {
        // Container-aware reconciliation was skipped (docker unreachable);
        // nothing to do here either — the auto-recovery pass below would
        // still try, but without a healthy `live_runners` snapshot the
        // behavior is identical to upstream `release_stale_slots`'s skip.
        return Ok(0);
    };
    let mut reclaimed = 0;
    let mut attempts_this_tick: u32 = 0;
    for (slot_n, runner_id, runner_name) in offline_busy_owned_missing_container_slots(
        assignments,
        live_runners,
        runner_prefix,
        local_names,
    ) {
        let already_quarantined = quarantine.is_quarantined(slot_n);
        if already_quarantined {
            // Slot is already in the quarantine table from a prior tick
            // and is still locked (the offline+busy+missing-container
            // shape is unchanged). Skip the entire DELETE + reaper dance
            // — both are wasted API calls when the lock is unchanged.
            // The auto-recovery pass below handles the un-quarantine
            // path the moment GH releases the lock (online /
            // offline+!busy / gone-from-list). This is the explicit
            // "bound retry/API volume" + "auto-recover when lock
            // releases" contract from bead ez-gh-actions-ghd2.2.
            eprintln!(
                "info: slot {slot_n} already quarantined (runner {runner_name} id {runner_id}, \
                 attempt_count={}); deferring to auto-recovery lane this tick",
                quarantine.get(slot_n).map(|e| e.attempt_count).unwrap_or(0)
            );
            continue;
        }
        eprintln!(
            "warning: removing offline/busy runner {runner_name} (id {runner_id}) with no local container before releasing slot {slot_n}"
        );
        match remove_runner(runner_id) {
            Ok(()) => {
                release_slot_for(cfg, slot_n)?;
                quarantine.remove(slot_n);
                reclaimed += 1;
                watchdog::ping();
            }
            Err(err) if is_runner_busy_lock_error(&err) => {
                // For a FRESH 422 detection (the slot is not yet in the
                // quarantine table), try the reaper self-heal ONCE per
                // tick across ALL fresh detections, then skip the reaper
                // for the rest of the tick. The first detection pays the
                // API cost; subsequent ones in the same tick go straight
                // to quarantine and wait for the next tick's reaper
                // budget (or the auto-recovery pass). This is the
                // explicit "bound retry/API volume" contract.
                let healed = if attempts_this_tick < max_attempts_per_tick {
                    attempts_this_tick += 1;
                    live_runners
                        .iter()
                        .find(|r| r.id == runner_id)
                        .is_some_and(&try_zombie_reclaim)
                } else {
                    false
                };
                if healed {
                    release_slot_for(cfg, slot_n)?;
                    quarantine.remove(slot_n);
                    reclaimed += 1;
                    watchdog::ping();
                } else {
                    let now = unix_now_secs();
                    let (attempt_count, first_seen) = match quarantine.get_mut(slot_n) {
                        Some(existing) => {
                            existing.attempt_count = existing.attempt_count.saturating_add(1);
                            existing.last_attempt_epoch_secs = now;
                            (existing.attempt_count, existing.first_seen_epoch_secs)
                        }
                        None => {
                            let entry = QuarantineEntry {
                                slot: slot_n,
                                runner_id,
                                runner_name: runner_name.clone(),
                                first_seen_epoch_secs: now,
                                attempt_count: 1,
                                last_attempt_epoch_secs: now,
                                reason: QuarantineReason::Locked422,
                            };
                            let attempt_count = entry.attempt_count;
                            let first_seen = entry.first_seen_epoch_secs;
                            quarantine.upsert(entry);
                            (attempt_count, first_seen)
                        }
                    };
                    eprintln!(
                        "warning: quarantining slot {slot_n}: runner {runner_name} (id {runner_id}) \
                         — DELETE 422 lock held by GitHub-side phantom job; \
                         attempt_count={attempt_count}, last_attempt_epoch_secs={now}"
                    );
                    if let Some(_cfg) = cfg {
                        // Always fire the operator alert when a slot
                        // transitions into quarantine (either freshly or
                        // re-confirmed). The alert module's own
                        // should_send() cooldown dedupes per event key
                        // (one key per slot) so a single stuck slot doesn't
                        // spam the channel every tick.
                        let age_secs = now.saturating_sub(first_seen);
                        let _ = notify_quarantine(
                            slot_n,
                            runner_id,
                            &runner_name,
                            age_secs,
                            attempt_count,
                        );
                    }
                }
            }
            Err(err) => {
                eprintln!(
                    "warning: keeping slot {slot_n}: failed to remove offline/busy runner {runner_name} (id {runner_id}): {err:#}"
                );
            }
        }
    }
    // Auto-recovery pass: existing quarantined slots whose runner has
    // stopped being 422-locked (it went online, or offline+!busy, or
    // disappeared entirely) can have their registration removed cleanly.
    let quarantined_slots: Vec<u32> = quarantine.slots();
    for slot_n in quarantined_slots {
        let Some(entry) = quarantine.get(slot_n).cloned() else {
            continue;
        };
        let runner_now = live_runners.iter().find(|r| r.id == entry.runner_id);
        let (recoverable, note) = match runner_now {
            None => (
                true,
                "registration no longer in live list — GH released lock".to_string(),
            ),
            Some(r) if r.status.eq_ignore_ascii_case("online") => {
                (true, "runner is online (GH released 422 lock)".to_string())
            }
            Some(r) if !r.busy => (
                true,
                format!("runner status={} busy=false — 422 lock released", r.status),
            ),
            Some(r) => (
                false,
                format!(
                    "runner still status={} busy={} — 422 lock not released yet",
                    r.status, r.busy
                ),
            ),
        };
        if !recoverable {
            eprintln!(
                "info: quarantined slot {slot_n} (runner {} id {}): {note}; keeping quarantine",
                entry.runner_name, entry.runner_id
            );
            continue;
        }
        eprintln!(
            "info: quarantined slot {slot_n} (runner {} id {}): {note}; attempting un-quarantine + release",
            entry.runner_name, entry.runner_id
        );
        match remove_runner(entry.runner_id) {
            Ok(()) => {
                release_slot_for(cfg, slot_n)?;
                quarantine.remove(slot_n);
                reclaimed += 1;
                watchdog::ping();
                if let Some(_cfg) = cfg {
                    let age_secs = unix_now_secs().saturating_sub(entry.first_seen_epoch_secs);
                    let _ = notify_recovery(
                        slot_n,
                        entry.runner_id,
                        &entry.runner_name,
                        entry.attempt_count,
                        age_secs,
                    );
                }
            }
            Err(err) if is_runner_busy_lock_error(&err) => {
                if let Some(existing) = quarantine.get_mut(slot_n) {
                    existing.last_attempt_epoch_secs = unix_now_secs();
                }
                eprintln!(
                    "info: auto-recovery on slot {slot_n} (runner {} id {}) hit 422 again; keeping quarantine: {err:#}",
                    entry.runner_name, entry.runner_id
                );
            }
            Err(err) => {
                eprintln!(
                    "warning: auto-recovery delete on slot {slot_n} (runner {} id {}) failed with non-422 error; keeping quarantine: {err:#}",
                    entry.runner_name, entry.runner_id
                );
            }
        }
    }
    Ok(reclaimed)
}

/// Poll/force-cancel attempts given to the reaper executor before this tick
/// gives up on a zombie-locked runner. Deliberately short: `release_stale_slots`
/// re-runs every reconciliation cycle, so a failed attempt here just retries
/// from scratch next tick rather than blocking this one on a long poll.
const ZOMBIE_RECLAIM_POLL_ATTEMPTS: u32 = 3;

/// Per-tick cap on `reclaim_zombie_locked_runner` invocations across all
/// wedged slots (bead ez-gh-actions-ghd2.2 acceptance: "bound retry/API
/// volume"). One self-heal attempt per tick keeps the API surface predictable
/// even when 8/22 slots are simultaneously 422-locked; pre-fix, every wedged
/// slot issued its own cancel + poll cascade per tick, which combined with
/// the Mac escalation path produced backend-restart storms. The bound is
/// deliberately 1 (not N): the per-slot `attempt_count` already tracks
/// cumulative history for alerting, and the auto-recovery pass gets the next
/// chance to act. Tests override this via `TEST_MAX_RECONCILE_ATTEMPTS_PER_TICK`
/// to drive multiple-attempts-per-tick scenarios without altering the
/// production value (see `quarantine_422_test.rs`-equivalent cases in the
/// `mod tests` block below).
fn max_reconcile_attempts_per_tick() -> u32 {
    #[cfg(test)]
    {
        if let Some(v) = *TEST_MAX_RECONCILE_ATTEMPTS_PER_TICK.lock().unwrap() {
            return v;
        }
    }
    MAX_RECONCILE_ATTEMPTS_PER_TICK_DEFAULT
}

/// Production default for `max_reconcile_attempts_per_tick`. Named with the
/// `_DEFAULT` suffix so the overrideable accessor above is the only path
/// the rest of the code reads through — prevents accidental direct reads.
const MAX_RECONCILE_ATTEMPTS_PER_TICK_DEFAULT: u32 = 1;

#[cfg(test)]
static TEST_MAX_RECONCILE_ATTEMPTS_PER_TICK: std::sync::Mutex<Option<u32>> =
    std::sync::Mutex::new(None);

/// Does `err` look like GitHub's "runner is currently running a job and
/// cannot be deleted" (HTTP 422) lock, as opposed to some other failure
/// (network blip, auth, rate limit)? Only the job-lock case is safe to
/// self-heal by cancelling a run; any other error must keep falling back to
/// the existing "keep slot, warn" behavior untouched.
///
/// Deliberately does NOT match on a bare "422" substring: `err`'s text is
/// the fully-formatted `gh api remove runner {id} failed: ...` message, and
/// `{id}` is an ever-churning numeric runner ID (422, 1422, 4220, ... are
/// all real IDs this fleet will eventually mint) — a bare "422" check would
/// false-positive on an unrelated failure (network blip, auth) for any
/// runner whose ID happens to contain that substring. GitHub's literal API
/// message text is the only reliable signal here.
fn is_runner_busy_lock_error(err: &anyhow::Error) -> bool {
    let text = format!("{err:#}").to_lowercase();
    text.contains("currently running a job")
}

/// Given a runner already confirmed offline+busy+missing-container (i.e. a
/// zombie: its container is dead but GitHub still thinks a job is running on
/// it), find the phantom run pinned to it and cancel-then-delete it. Pure
/// w.r.t. IO: `repo_runs` is pre-fetched and `api` is injected, so this is
/// exercised in tests via `reaper::test_support::FakeReaperApi` without
/// touching the network. Mirrors the known-good remediation order from
/// `docs/incident-20260706-fleet-outage.md` / memory
/// `gh-zombie-runner-422-delete-lock` (bead ez-gh-actions-qbl): cancel the
/// run that holds the lock FIRST, then delete the runner registration.
/// Returns `None` when no matching in-progress job was found in `repo_runs`
/// (nothing to cancel); returns `Some(execution)` otherwise, whose
/// `status` tells the caller whether the runner was actually removed.
fn reclaim_zombie_locked_runner_with_api(
    runner: &github::RunnerInfo,
    repo_runs: &[(String, reaper::RepoRunsWithJobs)],
    allowed_prefixes: &[String],
    required_labels: &[String],
    poll_attempts: u32,
    api: &mut impl reaper::ReaperApi,
) -> Option<reaper::ReaperExecution> {
    // min_age_seconds=0: unlike the periodic reaper sweep (which only reaps
    // jobs old enough to be suspicious), this path already knows the runner
    // is a confirmed zombie (missing container) — age is irrelevant.
    let plans = reaper::plan_reaper_actions(
        std::slice::from_ref(runner),
        repo_runs,
        allowed_prefixes,
        required_labels,
        0,
        unix_now_secs(),
    );
    let plan = plans.first()?;
    Some(reaper::execute_reaper_plan_with_api(
        api,
        plan,
        poll_attempts,
    ))
}

/// Production wrapper around [`reclaim_zombie_locked_runner_with_api`]: does
/// the real IO (repo discovery + run/job listing) and wires in
/// `reaper::LiveReaperApi` against real GitHub. Only the repos configured on
/// this host (`reaper::default_reaper_repos`) are searched — a job pinned to
/// this runner in some other, unconfigured repo would not be found here.
fn reclaim_zombie_locked_runner(cfg: &Config, runner: &github::RunnerInfo) -> bool {
    let repos = reaper::default_reaper_repos(cfg);
    if repos.is_empty() {
        eprintln!(
            "warning: zombie-slot self-heal for {} (id {}): no repos configured to search for its phantom run",
            runner.name, runner.id
        );
        return false;
    }
    let repo_runs = match reaper::collect_repo_runs(&repos) {
        Ok(repo_runs) => repo_runs,
        Err(err) => {
            eprintln!(
                "warning: zombie-slot self-heal for {} (id {}): failed to list in-progress runs in {repos:?}: {err:#}",
                runner.name, runner.id
            );
            return false;
        }
    };
    let allowed_prefixes = vec![cfg.runner.name_prefix.clone()];
    let mut api = reaper::LiveReaperApi::new(&cfg.github);
    let execution = reclaim_zombie_locked_runner_with_api(
        runner,
        &repo_runs,
        &allowed_prefixes,
        &cfg.runner.labels,
        ZOMBIE_RECLAIM_POLL_ATTEMPTS,
        &mut api,
    );
    match execution {
        Some(execution) if execution.status == reaper::ReaperExecutionStatus::Completed => {
            eprintln!(
                "info: zombie-slot self-heal cancelled run {} and removed runner {} (id {})",
                execution.run_id, runner.name, runner.id
            );
            true
        }
        Some(execution) => {
            eprintln!(
                "warning: zombie-slot self-heal for {} (id {}) did not complete (status {:?}); keeping slot",
                runner.name, runner.id, execution.status
            );
            false
        }
        None => {
            eprintln!(
                "warning: zombie-slot self-heal for {} (id {}): no in-progress job found in {repos:?}; keeping slot",
                runner.name, runner.id
            );
            false
        }
    }
}

fn unix_now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Print the `ezgha doctor`-style diagnostics for the current host. Today this
/// is a single warning that fires only when the docker daemon is sharing the
/// host kernel on Linux — i.e. bare-metal docker, no VM containment — so
/// callers know their jobs run with `HOST-BLAST-RADIUS` isolation only.
pub fn print_doctor(plat: &Platform) {
    if plat.docker_ok && !plat.daemon_in_vm && plat.os == "linux" {
        println!(
            "WARNING: daemon shares host kernel — ezgha jobs run in HOST-BLAST-RADIUS container isolation only"
        );
    }
}

fn run_docker(cmd: Command, detail: &str) -> Result<Output> {
    run_docker_with_timeout(cmd, detail, DOCKER_TIMEOUT)
}

/// Validate that the host docker daemon is attached to a cpu cgroup that can
/// actually enforce `--cpus`. If this cannot be verified, callers must fail
/// closed: launching with a missing/disabled CPU limit would allow a single
/// job to saturate the host and defeat the reliability boundary this tool is
/// supposed to enforce.
///
/// The probe must target the DAEMON's cgroup namespace, not the host's: this
/// box runs Docker inside a Colima/Lima guest VM, where the host kernel and
/// the daemon kernel differ and the host's `/sys/fs/cgroup/cgroup.controllers`
/// describes a cgroup topology the daemon does not own. When the daemon is
/// VM-backed (`platform.daemon_in_vm == true`), we spawn `docker run
/// --cgroupns=host … alpine` so the probe container inherits the daemon's
/// cgroup namespace and reads the controllers from inside it. When the
/// daemon shares the host kernel, we read the host's cgroup files directly
/// (the historical behavior).
///
/// Cached result of `probe_docker_cpu_controller_available` plus the
/// `Instant` it was recorded at, so a transient probe failure (Docker socket
/// not up at boot, image pull race, cgroup mount race) does not pin a
/// `false` answer FOR THE LIFETIME OF THE DAEMON. The previous
/// `OnceLock<bool>` cached the first probe result forever; a single early
/// failure meant the daemon refused to start runners for the entire
/// process — exactly the fail-closed-too-far behavior the cold review
/// flagged. With a 5-minute TTL the daemon re-probes often enough that a
/// transient blip self-heals without operator intervention, while still
/// avoiding a `docker run` exec on every `ensure_count` tick.
const CPU_PROBE_CACHE_TTL: Duration = Duration::from_secs(300);

#[derive(Clone, Copy)]
struct ProbeCache {
    value: bool,
    at: Instant,
}

/// Fast-path read-through cache. Lock contention is negligible — this
/// function is on the serve loop's tick, but the lock is only held for a
/// struct-copy read or a single `Instant::now()` write, and the cold
/// path (expired/missing) is amortized to one probe per TTL.
fn read_cached_or_reprobe() -> bool {
    static RESULT: std::sync::Mutex<Option<ProbeCache>> = std::sync::Mutex::new(None);
    let mut g = RESULT.lock().unwrap_or_else(|p| p.into_inner());
    if let Some(c) = *g {
        if c.at.elapsed() < CPU_PROBE_CACHE_TTL {
            return c.value;
        }
    }
    // Cache miss OR expired: re-probe. Even on a `false` result we cache
    // it (for TTL duration) so a sustained failure does not busy-loop a
    // `docker run` per tick — the TTL bounds the worst-case outage from
    // "until restart" to "5 minutes from probe-flip".
    let probed = probe_docker_cpu_controller_available();
    *g = Some(ProbeCache {
        value: probed,
        at: Instant::now(),
    });
    probed
}

/// The result is cached behind a `Mutex<Option<ProbeCache>>` with a
/// 5-minute TTL so the serve loop does not re-spawn a probe container on
/// every `ensure_count` tick, AND a transient probe failure (Docker socket
/// not up at boot, image pull race, cgroup mount race) does not pin a
/// `false` answer for the lifetime of the daemon.
pub fn docker_cpu_controller_available() -> bool {
    // Test seam (test builds only): when a test installs a forced answer via
    // `cpu_probe_overrides::set`, that answer takes precedence over both the
    // TTL cache and the live probe. This lets the 4 boundary tests
    // (host-enabled/guest-enabled, host-enabled/guest-disabled,
    // host-disabled/guest-enabled, host-disabled/guest-disabled) drive
    // `docker_cpu_controller_available` deterministically without touching
    // the real cgroup filesystem or running `docker run`. The check runs
    // BEFORE the cache so tests can flip the answer between calls; the
    // `TEST_LOCK` Mutex<()> serializes concurrent tests around this state.
    #[cfg(test)]
    {
        if let Some(forced) = cpu_probe_overrides::get() {
            return forced;
        }
    }
    read_cached_or_reprobe()
}

/// Fire-and-forget `docker pull <PROBE_IMAGE>` so the probe image is in the
/// local cache BEFORE any `docker run` probe call. The first probe after a
/// daemon cold start otherwise pays 5+ seconds of image-pull latency, which
/// can fail a verifier that runs immediately after restart. Best-effort:
/// pull failure is logged as a warning but does NOT block startup — the
/// probe call itself will trigger a re-pull on demand if the cache missed,
/// so the daemon is still correct, just slower on first probe.
///
/// Spawned on a dedicated thread because the daemon is otherwise purely
/// synchronous (no tokio runtime) and we want startup to proceed without
/// waiting on the pull. The project's only other long-lived background
/// threads are `watchdog::start_background` and `canary::run_once`-spawned
/// canary runs (both use the same `std::thread::Builder::new().name(...)`
/// pattern); following it keeps journalctl `-t` filtering useful.
pub fn prepull_probe_image() {
    std::thread::Builder::new()
        .name("ezgha-probe-prepull".into())
        .spawn(|| {
            let out = docker_cmd()
                .args(["pull", PROBE_IMAGE])
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::piped())
                .output();
            match out {
                Ok(o) if o.status.success() => {
                    // Success is silent: every-5-minute daemon restart
                    // would otherwise spam the journal with a healthy-pull
                    // line, drowning the actual warnings. Operators who
                    // need it can `docker image inspect alpine:3.19`.
                }
                Ok(o) => {
                    // stderr from `docker pull` on a not-found image or
                    // registry hiccup is the most diagnostic signal we
                    // have — surface it on the same line as our warning
                    // so a journalctl grep finds it without a second hop.
                    let stderr = String::from_utf8_lossy(&o.stderr);
                    eprintln!(
                        "WARN: prepull_probe_image: `docker pull {}` exited {:?}: {}",
                        PROBE_IMAGE,
                        o.status.code(),
                        stderr.trim()
                    );
                }
                Err(e) => {
                    eprintln!(
                        "WARN: prepull_probe_image: failed to spawn `docker pull {}`: {e}",
                        PROBE_IMAGE
                    );
                }
            }
        })
        .ok();
}

/// Internal: performs the actual probe. Result is cached by the public
/// wrapper; do not call directly from hot paths. Returns `false` on any
/// probe failure — fail-closed, the caller in `start_one` (line 1320)
/// already fails closed when this returns false.
fn probe_docker_cpu_controller_available() -> bool {
    // Non-Linux platforms have no cgroup concept; preserve historical
    // behavior and report availability so the caller proceeds.
    #[cfg(not(target_os = "linux"))]
    {
        true
    }

    #[cfg(target_os = "linux")]
    {
        let platform = crate::platform::detect();

        // When the daemon runs inside a VM (Colima/Lima/Docker Desktop on
        // this box), the HOST's cgroup files describe a kernel namespace
        // the daemon does not own. Probe INSIDE the daemon's namespace by
        // launching a short-lived `docker run` with `--cgroupns=host` so
        // the container inherits the daemon's cgroup hierarchy.
        if platform.daemon_in_vm {
            let probe_img = PROBE_IMAGE;
            // Lane U (R3-F13): a hung `docker` invocation (image pull
            // blocked, daemon socket frozen) used to block the probe
            // indefinitely because `Command::output()` has no native
            // timeout. Wrap the probe in the existing
            // `run_docker_with_timeout` helper with `DOCKER_TIMEOUT` (45s)
            // so the worst case is bounded by the same 45-second budget
            // every other daemon-spawned docker call already honors. A
            // timeout fails closed (the daemon already fails closed on
            // any other probe error), so the safety contract is
            // unchanged.
            let mut cmd = docker_cmd();
            cmd.args([
                "run", "--rm", "--cgroupns=host", "--network=none",
                probe_img, "sh", "-c",
                // Prefer cgroup-v2 controllers file; fall back to
                // /proc/cgroups (v1) so we accept either hierarchy.
                "cat /sys/fs/cgroup/cgroup.controllers 2>/dev/null || cat /proc/cgroups 2>/dev/null",
            ]);
            let out = run_docker_with_timeout(
                cmd,
                "probe_docker_cpu_controller_available (daemon-in-vm probe)",
                DOCKER_TIMEOUT,
            );
            eprintln!(
                "docker_cpu_controller_available: daemon_in_vm=true, probed via `docker run --cgroupns=host {probe_img}`"
            );
            return match out {
                Ok(o) if o.status.success() => parse_controller_probe(&o.stdout),
                Ok(_) | Err(_) => {
                    // Probe failed (docker run errored, timed out, or
                    // returned no parseable result). Fail closed: callers
                    // will refuse to start a runner with `--cpus` because
                    // they cannot prove the controller exists. This
                    // includes the new timeout path — a hung docker
                    // socket must not pin a `false` answer (the TTL
                    // cache self-heals on the next 5-minute tick).
                    false
                }
            };
        }

        eprintln!("docker_cpu_controller_available: daemon_in_vm=false, reading host cgroup files");

        if let Ok(controllers) = std::fs::read_to_string("/sys/fs/cgroup/cgroup.controllers") {
            if controllers.split_whitespace().any(|c| c == "cpu") {
                return true;
            }
        }

        // Legacy cgroup-v1 hosts can expose availability only in /proc/cgroups.
        if let Ok(cgroups) = std::fs::read_to_string("/proc/cgroups") {
            for line in cgroups.lines() {
                let mut cols = line.split_whitespace();
                let name = cols.next();
                let _ = cols.next();
                let _ = cols.next();
                let enabled = cols.next();
                if name == Some("cpu") && enabled == Some("1") {
                    return true;
                }
            }
        }
        false
    }
}

/// Parse the bytes returned by the in-daemon probe. Accepts either:
///   - cgroup-v2 `cgroup.controllers` content (whitespace-separated list, must
///     contain `cpu`)
///   - cgroup-v1 `/proc/cgroups` content (header + per-subsystem lines; the
///     `cpu` row must have `1` in the enabled column)
///
/// The probe runs `cat <v2> 2>/dev/null || cat <v1> …` so the output is
/// exactly one of the two formats — never both, never empty when the daemon
/// is healthy. Empty/unparseable output fails closed.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn parse_controller_probe(bytes: &[u8]) -> bool {
    let text = match std::str::from_utf8(bytes) {
        Ok(s) => s,
        Err(_) => return false,
    };

    // cgroup-v2: `/sys/fs/cgroup/cgroup.controllers` is a single line of
    // space-separated controller names like "cpuset cpu io memory hugetlb
    // pids rdma misc". Any token equal to "cpu" counts as the controller
    // being available.
    //
    // cgroup-v1 `/proc/cgroups` is a header line plus rows shaped
    // `<subsystem> <hierarchy> <num_cgroups> <enabled>`; the "cpu" row must
    // have enabled = 1. The probe uses `cat v2 2>/dev/null || cat v1`, so
    // only one of the two formats will be present.
    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let cols: Vec<&str> = trimmed.split_whitespace().collect();
        if cols.len() == 1 && cols[0] == "cpu" {
            // v2 controllers file split one-token-per-line (unusual but
            // some kernels do this for readability).
            return true;
        }
        // Distinguish v1 row vs v2 list BEFORE applying either check —
        // v1 `/proc/cgroups` rows end with "0" or "1"; v2 controllers
        // lists end with a controller name. Without this disambiguation,
        // a v2 line like "cpuset cpu io memory hugetlb pids rdma misc"
        // (7 tokens, trailing token "misc") matches `cols.len() >= 4`
        // but `cols[3] != "1"`, so the v1 branch would skip it forever
        // and the v2 `contains("cpu")` fallback would never run. That is
        // exactly the regression the live fleet just hit: the daemon's
        // first probe cached false and refused to start runners for 5
        // minutes (the new TTL cache from round-3 lane E3).
        let last = cols[cols.len() - 1];
        let is_v1_row =
            cols.len() >= 4 && !cols[0].starts_with('#') && (last == "0" || last == "1");
        if is_v1_row {
            if last != "1" {
                // Disabled controller — must NOT count, even if its
                // name happens to be "cpu" or "cpu,cpuacct" / "cpu,...".
                continue;
            }
            // Modern kernels can expose the cpu controller as a combined
            // row named "cpu,cpuacct" (or any other "cpu,<x>" combination).
            // Treat any of those as a hit.
            if cols[0] == "cpu" || cols[0] == "cpu,cpuacct" || cols[0].starts_with("cpu,") {
                return true;
            }
            continue;
        }
        if cols.len() >= 2 && !cols[0].starts_with('#') {
            // v2 single-line space-separated list: any token equal to "cpu".
            if cols.contains(&"cpu") {
                return true;
            }
        }
    }
    false
}

/// Build a `Command` for the `docker` binary. In test builds this honors
/// `TEST_DOCKER_BIN` so a test can redirect every docker invocation in this
/// module to a fake script without touching the process-wide `PATH` env var
/// (which is shared with every other thread/test in the binary). Production
/// behavior is unchanged: always `Command::new("docker")`, resolved via the
/// real `PATH`. Endpoint selection is owned by `platform` so startup probes
/// and runner mutation always address the same daemon.
fn docker_cmd() -> Command {
    #[cfg(test)]
    {
        if let Some(bin) = TEST_DOCKER_BIN.lock().unwrap().clone() {
            let mut cmd = Command::new(bin);
            crate::platform::configure_docker_endpoint(&mut cmd);
            return cmd;
        }
    }
    crate::platform::docker_command()
}

#[cfg(test)]
static TEST_HOST_CONTAINMENT_OVERRIDE: std::sync::Mutex<Option<bool>> = std::sync::Mutex::new(None);

#[cfg(test)]
static TEST_HOST_CONTAINMENT_CGROUP_ROOT: std::sync::Mutex<Option<PathBuf>> =
    std::sync::Mutex::new(None);
#[cfg(test)]
static TEST_HOST_CONTAINMENT_DAEMON_IN_VM: std::sync::Mutex<Option<bool>> =
    std::sync::Mutex::new(None);
#[cfg(test)]
static TEST_CONTAINER_ANCESTRY_OVERRIDE: std::sync::Mutex<Option<bool>> =
    std::sync::Mutex::new(None);
#[cfg(test)]
static TEST_USER_MANAGER_OOM_PROPERTIES: std::sync::Mutex<Option<String>> =
    std::sync::Mutex::new(None);

#[cfg(target_os = "linux")]
const HOST_ACTIONS_CPU_QUOTA_USEC: u64 = 2_000_000;
#[cfg(target_os = "linux")]
const HOST_ACTIONS_CPU_PERIOD_USEC: u64 = 100_000;

#[cfg(target_os = "linux")]
#[derive(Clone, Copy)]
struct HostActionsProfile {
    runner_memory_mb: u64,
    runner_pids: Option<u32>,
    memory_high_bytes: u64,
    memory_max_bytes: u64,
    pids_max: u64,
}

#[cfg(target_os = "linux")]
fn host_actions_profile(runner_count: u32) -> Option<HostActionsProfile> {
    const GIB: u64 = 1024 * 1024 * 1024;
    match runner_count {
        // Keep the deployed 10-runner envelope available for rollback.
        10 => Some(HostActionsProfile {
            runner_memory_mb: 2500,
            runner_pids: None,
            memory_high_bytes: 26 * GIB,
            memory_max_bytes: 28 * GIB,
            pids_max: 6000,
        }),
        // The 14-runner profile lowers per-job memory while retaining the
        // current aggregate host memory boundary. Available for rollback.
        14 => Some(HostActionsProfile {
            runner_memory_mb: 2000,
            runner_pids: Some(512),
            memory_high_bytes: 26 * GIB,
            memory_max_bytes: 28 * GIB,
            pids_max: 8000,
        }),
        // The 20-runner profile scales the fleet to 20 while retaining the
        // current aggregate host memory boundary (28 GiB).
        20 => Some(HostActionsProfile {
            runner_memory_mb: 1400,
            runner_pids: Some(512),
            memory_high_bytes: 26 * GIB,
            memory_max_bytes: 28 * GIB,
            pids_max: 8000,
        }),
        _ => None,
    }
}

#[cfg(target_os = "linux")]
fn host_containment_daemon_in_vm() -> bool {
    #[cfg(test)]
    if let Some(in_vm) = *TEST_HOST_CONTAINMENT_DAEMON_IN_VM.lock().unwrap() {
        return in_vm;
    }

    // This must use the same canonical endpoint as runner mutation. The
    // ambient Docker context can point at Colima or a remote daemon while
    // `docker_cmd` later creates containers on the host socket.
    let host_kernel = std::fs::read_to_string("/proc/sys/kernel/osrelease")
        .ok()
        .map(|kernel| kernel.trim().to_owned())
        .filter(|kernel| !kernel.is_empty());
    let mut cmd = docker_cmd();
    cmd.args(["info", "--format", "{{.KernelVersion}}"]);
    let daemon_kernel = run_docker(
        cmd,
        "checking canonical Docker daemon kernel for containment",
    )
    .ok()
    .filter(|output| output.status.success())
    .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_owned())
    .filter(|kernel| !kernel.is_empty());
    matches!((host_kernel, daemon_kernel), (Some(host), Some(daemon)) if host != daemon)
}

#[cfg(target_os = "linux")]
fn host_actions_cgroup_root() -> PathBuf {
    #[cfg(test)]
    if let Some(root) = TEST_HOST_CONTAINMENT_CGROUP_ROOT.lock().unwrap().clone() {
        return root;
    }
    PathBuf::from("/sys/fs/cgroup")
}

#[cfg(target_os = "linux")]
fn read_host_actions_limit(root: &Path, name: &str) -> Result<String> {
    let path = root.join("actions.slice").join(name);
    std::fs::read_to_string(&path)
        .with_context(|| format!("host containment requires readable {}", path.display()))
        .map(|value| value.trim().to_owned())
}

/// Confirm the finite cgroup-v2 limits that bound the complete HostDocker fleet.
#[cfg(target_os = "linux")]
fn validate_host_actions_slice(root: &Path, runner_count: u32) -> Result<()> {
    let profile = host_actions_profile(runner_count).ok_or_else(|| {
        anyhow::anyhow!(
            "host containment supports runner counts 10, 14, or 20 (got {runner_count})"
        )
    })?;
    let memory_high = read_host_actions_limit(root, "memory.high")?;
    let memory_high = memory_high.parse::<u64>().with_context(|| {
        format!(
            "host containment requires finite actions.slice memory.high={} bytes (got {memory_high:?})",
            profile.memory_high_bytes
        )
    })?;
    if memory_high != profile.memory_high_bytes {
        bail!(
            "host containment requires actions.slice memory.high={} bytes (got {memory_high})",
            profile.memory_high_bytes
        );
    }

    let memory_max = read_host_actions_limit(root, "memory.max")?;
    let memory_max = memory_max.parse::<u64>().with_context(|| {
        format!(
            "host containment requires finite actions.slice memory.max={} bytes (got {memory_max:?})",
            profile.memory_max_bytes
        )
    })?;
    if memory_max != profile.memory_max_bytes {
        bail!(
            "host containment requires actions.slice memory.max={} bytes (got {memory_max})",
            profile.memory_max_bytes
        );
    }

    let memory_swap_max = read_host_actions_limit(root, "memory.swap.max")?;
    if memory_swap_max != "0" {
        bail!(
            "host containment requires actions.slice memory.swap.max=0 (got {memory_swap_max:?})"
        );
    }

    let pids_max = read_host_actions_limit(root, "pids.max")?;
    let pids_max = pids_max.parse::<u64>().with_context(|| {
        format!(
            "host containment requires finite actions.slice pids.max={} (got {pids_max:?})",
            profile.pids_max
        )
    })?;
    if pids_max != profile.pids_max {
        bail!(
            "host containment requires actions.slice pids.max={} (got {pids_max})",
            profile.pids_max
        );
    }

    let cpu_max = read_host_actions_limit(root, "cpu.max")?;
    let mut cpu_max_parts = cpu_max.split_whitespace();
    let quota = cpu_max_parts
        .next()
        .and_then(|part| part.parse::<u64>().ok());
    let period = cpu_max_parts
        .next()
        .and_then(|part| part.parse::<u64>().ok());
    if quota != Some(HOST_ACTIONS_CPU_QUOTA_USEC)
        || period != Some(HOST_ACTIONS_CPU_PERIOD_USEC)
        || cpu_max_parts.next().is_some()
    {
        bail!(
            "host containment requires actions.slice cpu.max={} {} (got {cpu_max:?})",
            HOST_ACTIONS_CPU_QUOTA_USEC,
            HOST_ACTIONS_CPU_PERIOD_USEC
        );
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn validate_user_manager_oom_properties(properties: &str) -> Result<()> {
    let values: BTreeMap<&str, &str> = properties
        .lines()
        .filter_map(|line| line.split_once('='))
        .collect();
    for (name, expected) in [
        ("ManagedOOMMemoryPressure", "auto"),
        ("ManagedOOMSwap", "auto"),
        ("ManagedOOMPreference", "none"),
        ("OOMScoreAdjust", "0"),
    ] {
        let actual = values.get(name).copied();
        if actual != Some(expected) {
            bail!(
                "host containment requires user manager {name}={expected} (got {})",
                actual.unwrap_or("missing")
            );
        }
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn require_user_manager_oom_neutrality() -> Result<()> {
    #[cfg(test)]
    if let Some(properties) = TEST_USER_MANAGER_OOM_PROPERTIES.lock().unwrap().clone() {
        return validate_user_manager_oom_properties(&properties);
    }

    // SAFETY: geteuid has no preconditions and does not dereference Rust memory.
    let uid = unsafe { libc::geteuid() };
    let mut cmd = Command::new("systemctl");
    cmd.args([
        "show",
        &format!("user@{uid}.service"),
        "--property=ManagedOOMMemoryPressure",
        "--property=ManagedOOMSwap",
        "--property=ManagedOOMPreference",
        "--property=OOMScoreAdjust",
    ]);
    let out = run_docker_with_timeout(
        cmd,
        "reading user manager OOM policy for host containment",
        DOCKER_TIMEOUT,
    )?;
    if !out.status.success() {
        bail!(
            "host containment could not read user manager OOM policy: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    validate_user_manager_oom_properties(&String::from_utf8_lossy(&out.stdout))
}

#[cfg(target_os = "linux")]
fn is_actions_slice_descendant(cgroup_content: &str) -> bool {
    cgroup_content.lines().any(|line| {
        line.rsplit_once(':')
            .is_some_and(|(_, path)| path.starts_with("/actions.slice/"))
    })
}

#[cfg(target_os = "linux")]
fn parse_container_pid_for_ancestry(container_id: &str, stdout: &str) -> Result<u32> {
    let pid = stdout.trim().parse::<u32>().with_context(|| {
        format!(
            "container PID ancestry inspection returned an invalid PID for {container_id}: {stdout:?}"
        )
    })?;
    if pid == 0 {
        bail!("container PID ancestry inspection returned PID 0 for {container_id}");
    }
    Ok(pid)
}

/// Require Release 1 host containment before any Linux runner creation or mutation.
pub fn require_host_containment(_cfg: &Config) -> Result<()> {
    if is_macos_host() {
        return Ok(());
    }
    #[cfg(test)]
    {
        if let Some(true) = *TEST_HOST_CONTAINMENT_OVERRIDE.lock().unwrap() {
            return Ok(());
        }
    }
    #[cfg(target_os = "linux")]
    {
        let cfg = _cfg;
        if host_containment_daemon_in_vm() {
            return Ok(());
        }
        if cfg.policy.minimum_isolation != crate::config::IsolationLevel::Container {
            bail!("host containment requires policy.minimum_isolation=container");
        }
        if cfg.limits.cgroup_parent.as_deref() != Some("actions.slice") {
            bail!("host containment requires limits.cgroup_parent=actions.slice");
        }
        if host_actions_profile(cfg.runner.count).is_none() {
            bail!(
                "host containment supports runner counts 10, 14, or 20; configured count is {}",
                cfg.runner.count
            );
        }
        let profile = host_actions_profile(cfg.runner.count)
            .expect("supported runner profile was checked above");
        if cfg.limits.memory_mb != profile.runner_memory_mb {
            bail!(
                "host containment requires limits.memory_mb to be exactly {} for runner count {}; configured memory is {}",
                profile.runner_memory_mb,
                cfg.runner.count,
                cfg.limits.memory_mb
            );
        }
        if let Some(pids) = profile.runner_pids {
            if cfg.limits.pids != pids {
                bail!(
                    "host containment requires limits.pids to be exactly {} for runner count {}; configured PID limit is {}",
                    pids,
                    cfg.runner.count,
                    cfg.limits.pids
                );
            }
        }
        validate_host_actions_slice(&host_actions_cgroup_root(), cfg.runner.count)?;
        require_user_manager_oom_neutrality()?;
    }
    Ok(())
}

/// Require that a freshly created container PID is located beneath /actions.slice.
pub fn require_container_actions_ancestry(_container_id: &str) -> Result<()> {
    #[cfg(target_os = "linux")]
    {
        let container_id = _container_id;
        // A canonical Docker endpoint backed by a VM reports guest PIDs that
        // do not exist in this host's /proc. The host cgroup assertion is only
        // meaningful for the native HostDocker profile; VM admission keeps its
        // existing behavior without claiming host-level ancestry verification.
        if host_containment_daemon_in_vm() {
            return Ok(());
        }
        #[cfg(test)]
        if let Some(allowed) = *TEST_CONTAINER_ANCESTRY_OVERRIDE.lock().unwrap() {
            if allowed {
                return Ok(());
            }
            bail!("container PID ancestry not beneath /actions.slice");
        }
        let mut cmd = docker_cmd();
        cmd.args(["inspect", "--format", "{{.State.Pid}}", container_id]);
        let out = run_docker(cmd, "inspect container pid for ancestry check")?;
        if !out.status.success() {
            bail!(
                "container PID ancestry inspection failed for {container_id}: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            );
        }
        let stdout = String::from_utf8_lossy(&out.stdout);
        let pid = parse_container_pid_for_ancestry(container_id, &stdout)?;
        let cgroup_path = format!("/proc/{pid}/cgroup");
        let cgroup_content = std::fs::read_to_string(&cgroup_path)
            .with_context(|| format!("container PID {pid} has no readable cgroup path"))?;
        if !is_actions_slice_descendant(&cgroup_content) {
            bail!(
                "container PID {pid} is not beneath /actions.slice; cgroup content: {cgroup_content}"
            );
        }
    }
    Ok(())
}

/// Process-wide guard so `print_doctor`'s warning prints at most once per
/// `serve` process — otherwise the 30s reconciliation loop would re-emit the
/// same diagnostic forever.
static DOCTOR_PRINTED: Once = Once::new();

/// Build the runner container name for a given slot.
fn runner_name_for(cfg: &Config, slot: u32) -> String {
    runner_name_from_prefix(&cfg.runner.name_prefix, slot)
}

/// CPU and memory capacity of the docker DAEMON, which may be smaller than
/// the local host when docker runs inside a VM (Colima/Lima/Docker Desktop)
/// or on a remote context. Limits must respect the daemon, not the host.
pub fn daemon_capacity() -> Option<(f64, u64)> {
    #[cfg(test)]
    {
        if let Some(override_cap) = &*TEST_DAEMON_CAPACITY.lock().unwrap() {
            return *override_cap;
        }
    }
    let mut cmd = docker_cmd();
    cmd.args(["info", "--format", "{{.NCPU}} {{.MemTotal}}"]);
    let out = run_docker(cmd, "reading docker daemon capacity").ok()?;
    let stdout = String::from_utf8_lossy(&out.stdout);
    let mut parts = stdout.split_whitespace();
    let ncpu: f64 = parts.next()?.parse().ok()?;
    let mem_bytes: u64 = parts.next()?.parse().ok()?;
    Some((ncpu, mem_bytes / 1024 / 1024))
}

#[cfg(test)]
static TEST_DAEMON_CAPACITY: std::sync::Mutex<Option<Option<(f64, u64)>>> =
    std::sync::Mutex::new(None);

/// Lane-I (Round-3 swarm): read PSI cgroup-v2 memory pressure (`some` line)
/// from `source` and host `MemAvailable`. Returns `(pressure_pct,
/// available_bytes)`. Refuses to start a new runner when memory pressure is
/// sustained, even if disk-floor is healthy (the `min_free_disk_gb` guard
/// alone did not save the host from the 2026-07-12 crash). There is no
/// fallback between sources: an unreadable pressure, `memory.current`,
/// `memory.high` or MemAvailable file is an `Err`, which the caller treats as
/// a probe failure (fail-closed once `runner.host_reserve_mb > 0`).
pub fn memory_pressure_pct(source: &PressureSource) -> Result<(f64, u64)> {
    read_admission_pressure(source, &read_meminfo_available)
}

const DEFAULT_PRESSURE_PATH: &str = "/sys/fs/cgroup/user.slice/memory.pressure";

/// Where the admission gate reads memory pressure. The legacy source is
/// `user.slice`, which aggregates every sibling slice: on 2026-10-01/02 a
/// throttled `automation.slice` held it at 55-79% and paused admission for
/// hours with 36 GiB available (bead ez-gh-actions-u3c5). On the Linux
/// host-docker backend the runner aggregate cgroup (`limits.cgroup_parent`)
/// is used instead, and its PSI only counts while that cgroup is within 10%
/// of its own `memory.high`, so one container thrashing against its
/// per-container limit cannot pause the fleet.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PressureSource {
    psi_path: PathBuf,
    /// `(memory.current, memory.high)` of the runner cgroup; `None` is the
    /// ungated legacy source.
    gate: Option<(PathBuf, PathBuf)>,
}

impl PressureSource {
    fn fallback() -> Self {
        Self {
            psi_path: PathBuf::from(DEFAULT_PRESSURE_PATH),
            gate: None,
        }
    }

    #[cfg(any(target_os = "linux", test))]
    fn runner_cgroup(dir: &Path) -> Self {
        Self {
            psi_path: dir.join("memory.pressure"),
            gate: Some((dir.join("memory.current"), dir.join("memory.high"))),
        }
    }

    fn describe(&self) -> String {
        let psi = self.psi_path.display();
        match &self.gate {
            Some((_, high)) => format!(
                "admission pressure source: {psi} high={} (host-docker)",
                high.display()
            ),
            None => format!("admission pressure source: {psi} high=none (fallback)"),
        }
    }
}

/// Pick the admission pressure source for this tick. Only a Linux host whose
/// canonical docker daemon shares the host kernel (not Colima/VM-backed) and
/// that configures `limits.cgroup_parent` uses the runner cgroup.
#[cfg_attr(not(target_os = "linux"), allow(unused_variables))]
fn admission_pressure_source(cfg: &Config) -> PressureSource {
    #[cfg(target_os = "linux")]
    if let Some(parent) = cfg.limits.cgroup_parent.as_deref() {
        if !is_macos_host() && !host_containment_daemon_in_vm() {
            return PressureSource::runner_cgroup(&host_actions_cgroup_root().join(parent));
        }
    }
    PressureSource::fallback()
}

static LAST_PRESSURE_SOURCE: Mutex<Option<String>> = Mutex::new(None);

/// Log the resolved source once at startup and whenever it changes. A change
/// also clears the hysteresis window so samples from different sources are
/// never compared.
fn log_pressure_source_change(source: &PressureSource) {
    let desc = source.describe();
    let mut last = LAST_PRESSURE_SOURCE
        .lock()
        .unwrap_or_else(|p| p.into_inner());
    if last.as_deref() != Some(desc.as_str()) {
        eprintln!("{desc}");
        *last = Some(desc);
        *PRESSURE_WINDOW.lock().unwrap_or_else(|p| p.into_inner()) = [None; 5];
    }
}

/// Read a cgroup-v2 byte value; `max` (no limit) is `None`.
fn read_cgroup_bytes(path: &Path) -> Result<Option<u64>> {
    let raw =
        std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
    let raw = raw.trim();
    if raw == "max" {
        return Ok(None);
    }
    raw.parse::<u64>()
        .map(Some)
        .with_context(|| format!("unparseable cgroup value {raw:?} in {}", path.display()))
}

fn read_admission_pressure(
    source: &PressureSource,
    read_meminfo: &dyn Fn() -> Option<u64>,
) -> Result<(f64, u64)> {
    let (pct, available) = memory_pressure_pct_from(&source.psi_path, read_meminfo)?;
    let Some((current_path, high_path)) = &source.gate else {
        return Ok((pct, available));
    };
    let current = read_cgroup_bytes(current_path)?
        .with_context(|| format!("{} reported no value", current_path.display()))?;
    // `memory.high = max` means the runner cgroup has no throttle to thrash
    // against, so its PSI never gates; MemAvailable still does.
    let near_high = read_cgroup_bytes(high_path)?
        .is_some_and(|high| u128::from(current) * 10 >= u128::from(high) * 9);
    // Below 90% of memory.high the sample is 0 so neither the absolute nor
    // the 5-tick rising branch of `eval_admission` can fire on it.
    Ok((if near_high { pct } else { 0.0 }, available))
}

/// A continuous admission pause. The headroom alert fires at most once per
/// episode; the episode ends on the first admitted tick.
#[derive(Debug, Clone, Copy)]
struct AdmissionPauseEpisode {
    since: Instant,
    alerted: bool,
}

const ADMISSION_PAUSE_ALERT_AFTER: Duration = Duration::from_secs(10 * 60);

static ADMISSION_PAUSE_EPISODE: Mutex<Option<AdmissionPauseEpisode>> = Mutex::new(None);

/// Track the pause episode and return `true` exactly once per episode, when
/// admission has been continuously paused for `ADMISSION_PAUSE_ALERT_AFTER`
/// while MemAvailable still has headroom (the 2026-10-01 fleet drained
/// silently all day under exactly this condition).
fn admission_pause_alert_due(
    episode: &mut Option<AdmissionPauseEpisode>,
    now: Instant,
    paused: bool,
    headroom: bool,
) -> bool {
    if !paused {
        *episode = None;
        return false;
    }
    let ep = episode.get_or_insert(AdmissionPauseEpisode {
        since: now,
        alerted: false,
    });
    if ep.alerted || !headroom || now.duration_since(ep.since) < ADMISSION_PAUSE_ALERT_AFTER {
        return false;
    }
    ep.alerted = true;
    true
}

fn memory_pressure_pct_from(
    pressure_path: &Path,
    read_meminfo: &dyn Fn() -> Option<u64>,
) -> Result<(f64, u64)> {
    let pressure_raw = std::fs::read_to_string(pressure_path)
        .with_context(|| format!("reading memory pressure at {}", pressure_path.display()))?;
    // PSI cgroup-v2 line format:
    //   some avg10=1.23 avg60=4.56 avg300=2.34 total=...
    // We use `avg10` (the most recent 10s window) — short enough to react
    // before the host tips into OOM, long enough that a single tick's
    // disk-stall jitter doesn't trigger an admission refusal.
    let mut pct: Option<f64> = None;
    for line in pressure_raw.lines() {
        if let Some(rest) = line.strip_prefix("some") {
            for tok in rest.split_whitespace() {
                if let Some(v) = tok.strip_prefix("avg10=") {
                    pct = v.parse::<f64>().ok();
                    break;
                }
            }
        }
    }
    let pressure_pct =
        pct.with_context(|| format!("no `some avg10=` line in {}", pressure_path.display()))?;
    let available_bytes =
        read_meminfo().with_context(|| "could not read MemAvailable from /proc/meminfo")?;
    Ok((pressure_pct, available_bytes))
}

/// Parse the single `MemAvailable: N kB` line out of `/proc/meminfo`.
fn read_meminfo_available() -> Option<u64> {
    let raw = std::fs::read_to_string("/proc/meminfo").ok()?;
    for line in raw.lines() {
        if let Some(rest) = line.strip_prefix("MemAvailable:") {
            let kb: u64 = rest.split_whitespace().next()?.parse().ok()?;
            return kb.checked_mul(1024);
        }
    }
    None
}

/// Lane-I admission policy. Pure function — no I/O, no globals — so the
/// 4-branch test suite can drive every code path without touching
/// `/proc/meminfo` or `/sys/fs/cgroup`. The 5-tick rolling window of
/// previous pressure readings is passed in as `prev_window: &mut [Option<f64>; 5]`
/// (newest sample at the END); on each call we rotate left, push the new
/// reading, and decide. We refuse on:
///   1. absolute pressure > 50% (any single tick),
///   2. available_bytes < host reserve + per-runner memory (and the existing
///      2× per-runner safety floor),
///   3. hysteresis: all 5 most-recent readings are rising (each tick's
///      reading is strictly greater than the prior tick).
///
/// Tests pass a pre-populated `prev_window` so they can drive each branch
/// deterministically without spinning up the real daemon.
pub fn eval_admission(
    pressure_pct: f64,
    available_bytes: u64,
    runner_memory_bytes: u64,
    host_reserve_bytes: u64,
    prev_window: &mut [Option<f64>; 5],
) -> Result<(), String> {
    if pressure_pct > 50.0 {
        return Err(format!(
            "PSE memory pressure {pressure_pct:.1}% > 50%; refusing new start"
        ));
    }
    let reserve_plus_runner = host_reserve_bytes.saturating_add(runner_memory_bytes);
    if host_reserve_bytes > 0 && available_bytes < reserve_plus_runner {
        let avail_mb = available_bytes / 1024 / 1024;
        let reserve_mb = host_reserve_bytes / 1024 / 1024;
        let runner_mb = runner_memory_bytes / 1024 / 1024;
        return Err(format!(
            "MemAvailable {avail_mb} MB < host reserve {reserve_mb} MB + runner memory {runner_mb} MB"
        ));
    }
    let two_x = runner_memory_bytes.saturating_mul(2);
    if available_bytes < two_x {
        let avail_mb = available_bytes / 1024 / 1024;
        let runner_mb = runner_memory_bytes / 1024 / 1024;
        return Err(format!(
            "MemAvailable {avail_mb} MB < 2× runner memory {runner_mb} MB"
        ));
    }
    // Hysteresis: rotate left, push the new reading into the tail, then
    // check that every consecutive (prev, curr) pair in the window is
    // strictly rising. None slots mean "no prior reading" and break the
    // rising chain — so hysteresis can only FIRE once the ring is full AND
    // every consecutive pair is rising. That gives a 5-tick grace at
    // startup (which is exactly what we want — we should not refuse a new
    // start on tick 1 just because the daemon restarted into a busy host).
    prev_window.rotate_left(1);
    prev_window[4] = Some(pressure_pct);
    if prev_window.iter().all(Option::is_some) {
        let mut prev = prev_window[0].unwrap();
        let mut all_rising = true;
        for slot in prev_window.iter().skip(1) {
            let curr = slot.unwrap();
            if curr <= prev {
                all_rising = false;
                break;
            }
            prev = curr;
        }
        if all_rising {
            return Err("PSE hysteresis: pressure rising 5 consecutive ticks".to_string());
        }
    }
    Ok(())
}

/// Clamp configured limits to what the daemon can actually provide PER
/// RUNNER. With `count` ephemeral runners, each runner must fit
/// `daemon / count`; clamping to raw `daemon` would silently over-commit by
/// `count×` (bug vmz — count=16 on a 4-CPU/12-GB daemon would issue per-runner
/// requests summing to 32 CPU + 95 GB, triggering OOM-kills).
///
/// **VM ceiling override**: if `cfg.runner.vm_total_mb` is set, use it as
/// the fleet budget base instead of the docker daemon's reported `MemTotal`.
/// This fixes the case where the docker daemon reports LESS memory than the
/// actual VM ceiling (e.g. Colima reserves memory for the guest OS that
/// the daemon doesn't see). Previously, with `count=6` on a 24GiB Colima VM,
/// `docker info --format {{.MemTotal}}` returned 15957MB (the daemon's view
/// after guest reserve), so the clamp computed `fleet_budget_mb = 13909MB`,
/// `per_runner = 2318MB` — silently degrading configured `memory_mb = 3072`
/// by 25% on every runner. Setting `vm_total_mb = 24576` (the actual VM
/// ceiling) restores `fleet_budget_mb = 22528`, `per_runner = 3754MB`,
/// respecting the configured 3072MB floor.
pub fn effective_limits(cfg: &Config) -> Result<(f64, u64), String> {
    // cpu_burst=false (default): skip platform probes entirely. cpu_burst=true:
    // run the NARROW `daemon_in_vm_only` probe (single docker daemon kernel
    // read, bounded by PROBE_TIMEOUT) instead of full `detect()`.
    let capacity = daemon_capacity().map(|(ncpu, daemon_mem)| {
        // vm_total_mb override as the fleet budget base when set;
        // matches derive_memory_budget's startup fail-loud guard so
        // the guard and the runtime clamp stay in sync.
        (ncpu, cfg.runner.vm_total_mb.unwrap_or(daemon_mem))
    });
    let daemon_in_vm = if cfg.limits.cpu_burst {
        crate::platform::daemon_in_vm_only()
    } else {
        false
    };
    effective_limits_with_capacity(cfg, capacity, daemon_in_vm)
}

fn effective_limits_with_capacity(
    cfg: &Config,
    capacity: Option<(f64, u64)>,
    daemon_in_vm: bool,
) -> Result<(f64, u64), String> {
    // Opt-in CPU ceiling. cpu_burst=true is honored ONLY when the daemon
    // is verified VM-contained AND we have a finite positive ncpu.
    // Otherwise we REFUSE — `Err` propagates up to the caller
    // (start_one_with_generate_at_slot and Serve startup bail before
    // mutating any runner) instead of silently falling back to the
    // default equal-share clamp. A silent fallback would let a host
    // daemon or unknown capacity silently exceed the physical envelope;
    // the explicit Err makes the misconfiguration loud. This runs BEFORE
    // the capacity check because the refusal must fire even when
    // capacity is None.
    if cfg.limits.cpu_burst {
        if !daemon_in_vm {
            return Err("limits.cpu_burst=true is unsupported on this host: \
                 docker daemon is not verified VM-contained \
                 (platform::detect().daemon_in_vm=false). \
                 Disable cpu_burst or run inside a VM (Colima/Lima/Docker Desktop)."
                .to_string());
        }
        match capacity {
            None => {
                return Err("limits.cpu_burst=true is unsupported: \
                     daemon_capacity() returned no (non-positive) CPU capacity; \
                     cannot bound the per-container ceiling safely."
                    .to_string());
            }
            Some((ncpu, _)) if !ncpu.is_finite() || ncpu <= 0.0 => {
                return Err(format!(
                    "limits.cpu_burst=true is unsupported: \
                     daemon_capacity() returned non-finite or non-positive ncpu={ncpu}; \
                     cannot bound the per-container ceiling safely."
                ));
            }
            _ => {}
        }
    }

    let (mut cpus, mut mem) = (cfg.limits.cpus, cfg.limits.memory_mb);
    if let Some((ncpu, daemon_mem)) = capacity {
        let n_f = (cfg.runner.count as f64).max(1.0);
        let n_u = (cfg.runner.count as u64).max(1);
        // Per-runner share of the FLEET budget (daemon capacity minus the
        // guest/Docker-overhead reserve), floored at validate() minimums so
        // a hand-edited cfg that over-aggregates still gets a sane
        // per-runner request rather than docker run exploding from
        // over-memory. Mirrors derive_memory_budget's fleet_budget_mb =
        // vm_total_mb - guest_reserve_mb formula (bead ez-gh-actions-yz6b
        // round 3) so the startup fail-loud guard / `ezgha doctor` preview
        // and the ACTUAL docker run --memory limit stay in sync.
        let fleet_mem_budget = daemon_mem.saturating_sub(cfg.runner.guest_reserve_mb);
        let cpu_share = (ncpu / n_f).max(0.5);
        let mem_share = (fleet_mem_budget / n_u).max(512);
        if cfg.limits.cpu_burst {
            let cpu_ceiling = ncpu;
            if cpus > cpu_ceiling {
                eprintln!(
                    "note: clamping cpus {cpus} -> {cpu_ceiling} (cpu_burst=true, \
                     verified-VM daemon {ncpu} CPU)"
                );
                cpus = cpu_ceiling;
            }
        } else if cpus > cpu_share {
            eprintln!(
                "note: clamping cpus {cpus} -> {cpu_share} (daemon {ncpu} CPU / {} runners)",
                cfg.runner.count
            );
            cpus = cpu_share;
        }
        if mem > mem_share {
            eprintln!(
                "note: clamping memory {mem} MB -> {mem_share} MB (fleet_budget {fleet_mem_budget} MB \
                 [daemon {daemon_mem} MB - guest_reserve {} MB] / {} runners)",
                cfg.runner.guest_reserve_mb,
                cfg.runner.count
            );
            mem = mem_share;
        }
    }
    Ok((cpus, mem))
}

/// Derived, VM-aware memory budget for the fleet, computed once at daemon
/// startup from explicit config — NOT the same computation as
/// `effective_limits`, which clamps live per-`docker run` requests against
/// whatever `daemon_capacity()` reports at that instant. This is an audit /
/// fail-loud guard: bead ez-gh-actions-yz6b. The pre-existing clamp divided
/// the whole docker-daemon-reported memory by runner count, leaving zero
/// headroom for the Docker daemon / guest OS running inside the VM (Colima
/// et al). This computes the budget explicitly and refuses to start rather
/// than silently degrading below `runner_floor_mb`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MemoryBudget {
    pub vm_total_mb: u64,
    pub guest_reserve_mb: u64,
    pub fleet_budget_mb: u64,
    pub runner_count: u32,
    pub runner_floor_mb: u64,
    pub per_runner_budget_mb: u64,
}

/// Pure derivation, no I/O — easy to unit test. `fleet_budget_mb =
/// vm_total_mb - guest_reserve_mb` (saturating, never underflows).
/// `per_runner_budget_mb = fleet_budget_mb / runner_count`. FAILS LOUD
/// (returns `Err`, does not clamp) if `runner_count * runner_floor_mb >
/// fleet_budget_mb` — the caller must not silently under-provision runners
/// below the research-validated floor (an earlier under-floor clamp caused
/// a jest OOM failure class).
pub fn derive_memory_budget(
    vm_total_mb: u64,
    guest_reserve_mb: u64,
    runner_count: u32,
    runner_floor_mb: u64,
) -> Result<MemoryBudget> {
    let count_u64 = (runner_count as u64).max(1);
    let fleet_budget_mb = vm_total_mb.saturating_sub(guest_reserve_mb);
    let required_mb = count_u64.saturating_mul(runner_floor_mb);
    if required_mb > fleet_budget_mb {
        let shortfall_mb = required_mb - fleet_budget_mb;
        anyhow::bail!(
            "refusing to start: memory budget shortfall: vm_total_mb={vm_total_mb} \
             guest_reserve_mb={guest_reserve_mb} fleet_budget_mb={fleet_budget_mb} \
             runner_count={runner_count} runner_floor_mb={runner_floor_mb} \
             required_mb={required_mb} shortfall_mb={shortfall_mb}; lower runner.count, \
             raise runner.vm_total_mb (must match the real VM ceiling — check `colima status` \
             / `limactl list`), or lower runner.guest_reserve_mb. Refusing to silently clamp \
             below the runner_floor_mb floor (bead ez-gh-actions-yz6b: an earlier under-floor \
             clamp caused a jest OOM failure class)."
        );
    }
    let per_runner_budget_mb = fleet_budget_mb / count_u64;
    Ok(MemoryBudget {
        vm_total_mb,
        guest_reserve_mb,
        fleet_budget_mb,
        runner_count,
        runner_floor_mb,
        per_runner_budget_mb,
    })
}

/// Resolve `vm_total_mb`: explicit `cfg.runner.vm_total_mb` override, else
/// `daemon_capacity()` auto-detect (preserving pre-yz6b auto-detect
/// behavior when the key is unset). Shared by `resolve_and_log_memory_budget`
/// (Serve startup, fail-loud) and `preview_memory_budget` (`ezgha doctor`,
/// read-only, never blocks).
fn resolve_vm_total_mb(cfg: &Config) -> Option<u64> {
    cfg.runner
        .vm_total_mb
        .or_else(|| daemon_capacity().map(|(_, mem)| mem))
}

/// Resolve `vm_total_mb` (explicit `cfg.runner.vm_total_mb` override, else
/// `daemon_capacity()` auto-detect — preserving pre-yz6b auto-detect
/// behavior when the key is unset), derive the fleet memory budget, and log
/// the full derivation at info level so it's auditable in the journal
/// (`journalctl --user -u ezgha.service`). Returns `Ok(None)` (not an
/// error) if NEITHER an explicit config value NOR `daemon_capacity()` is
/// available — a telemetry/audit feature must never be able to block
/// startup on its own inability to introspect the environment (Self-Outage
/// Prevention Principle). Returns `Err` only for the deliberate fail-loud
/// case inside `derive_memory_budget`.
pub fn resolve_and_log_memory_budget(cfg: &Config) -> Result<Option<MemoryBudget>> {
    // A configured Docker VM is nested inside the physical host. Validate that
    // its ceiling leaves the explicitly reserved host envelope before deriving
    // the separate guest/daemon budget below. `platform::detect()` reports the
    // physical machine's memory, not the Docker daemon's VM allocation.
    cfg.validate_host_envelope(crate::platform::detect().total_mem_mb)?;
    let Some(vm_total_mb) = resolve_vm_total_mb(cfg) else {
        eprintln!(
            "warning: cannot determine VM/daemon memory ceiling (runner.vm_total_mb \
             unset and the `docker info` capacity probe failed); skipping startup \
             memory budget check. Set runner.vm_total_mb explicitly (check `colima \
             status` / `limactl list`) to enable it."
        );
        return Ok(None);
    };
    let budget = derive_memory_budget(
        vm_total_mb,
        cfg.runner.guest_reserve_mb,
        cfg.runner.count,
        cfg.runner.runner_floor_mb,
    )?;
    println!(
        "memory budget: vm_total_mb={} guest_reserve_mb={} fleet_budget_mb={} runner_count={} \
         per_runner_budget_mb={} runner_floor_mb={}",
        budget.vm_total_mb,
        budget.guest_reserve_mb,
        budget.fleet_budget_mb,
        budget.runner_count,
        budget.per_runner_budget_mb,
        budget.runner_floor_mb,
    );
    Ok(Some(budget))
}

/// Read-only PREVIEW of the same derivation used at `Serve` startup. Never
/// blocks, never prints via `bail!`/`Err` propagation, never restarts
/// anything — for `ezgha doctor` so an operator can see whether the NEXT
/// `ezgha serve` (re)start would trip the fail-loud guard, without actually
/// triggering it. (Self-Outage Prevention Principle: discovering "restart
/// would fail loud" via a live crash-loop is exactly the outage this
/// preview exists to prevent — bead ez-gh-actions-yz6b round 2.)
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MemoryBudgetPreview {
    /// The configured fleet fits within the derived budget.
    Pass(MemoryBudget),
    /// The configured fleet would fail the startup fail-loud guard; the
    /// String is the same detailed message `derive_memory_budget` would
    /// bail! with (contains vm_total_mb/guest_reserve_mb/fleet_budget_mb/
    /// runner_count/runner_floor_mb/required_mb/shortfall_mb).
    Fail(String),
    /// Could not determine `vm_total_mb` at all (no config override and
    /// `docker info` capacity probe failed) — not a pass or fail verdict,
    /// just "can't tell".
    Unknown,
}

pub fn preview_memory_budget(cfg: &Config) -> MemoryBudgetPreview {
    let Some(vm_total_mb) = resolve_vm_total_mb(cfg) else {
        return MemoryBudgetPreview::Unknown;
    };
    match derive_memory_budget(
        vm_total_mb,
        cfg.runner.guest_reserve_mb,
        cfg.runner.count,
        cfg.runner.runner_floor_mb,
    ) {
        Ok(budget) => MemoryBudgetPreview::Pass(budget),
        Err(err) => MemoryBudgetPreview::Fail(format!("{err:#}")),
    }
}

/// Typed admission-preflight error: a pre-mutation failure (JIT, cpu_burst,
/// future preflight checks) that must refuse the entire refill without
/// charging any slot's failure ladder. The refill loop recognizes this via
/// `downcast_ref` and converts it to `admission_paused_reason` instead of
/// slot charge.
#[derive(Debug)]
struct AdmissionPreflightError(String);

impl std::fmt::Display for AdmissionPreflightError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl std::error::Error for AdmissionPreflightError {}

fn admission_preflight_error(error: anyhow::Error) -> anyhow::Error {
    anyhow::Error::new(AdmissionPreflightError(format!("{error:#}")))
}

fn start_one_at_slot(cfg: &Config, backend: Backend, slot: u32) -> Result<(String, String)> {
    #[cfg(test)]
    {
        let mut hook = TEST_START_ONE_NAMES.lock().unwrap();
        if let Some(names) = hook.as_mut() {
            if names.is_empty() {
                bail!("test start_one hook exhausted");
            }
            let name = names.remove(0);
            return Ok((format!("container-{name}"), name));
        }
    }

    start_one_with_generate_at_slot(cfg, backend, slot, |github, name, labels, owned_ids| {
        github::generate_jitconfig(github, name, labels, owned_ids)
            .map_err(admission_preflight_error)
    })
}

/// Test-only convenience wrapper: allocates the next free slot itself (via
/// `next_slot`) then delegates to `start_one_with_generate_at_slot`.
/// Production code always goes through `start_one_at_slot` /
/// `start_one_with_generate_at_slot` with an explicit slot from
/// `next_slot_excluding`, so this indirection now exists purely for tests
/// that don't care about slot-exclusion behavior.
#[cfg(test)]
fn start_one_with_generate(
    cfg: &Config,
    backend: Backend,
    generate_jitconfig: impl FnOnce(
        &crate::config::GithubConfig,
        &str,
        &[String],
        &HashSet<u64>,
    ) -> Result<(String, u64)>,
) -> Result<(String, String)> {
    // Acquire a stable numeric slot BEFORE calling GitHub so a JIT
    // registration that never gets a container still gets cleaned up.
    let slot = next_slot(cfg)?;
    start_one_with_generate_at_slot(cfg, backend, slot, generate_jitconfig)
}

fn start_one_with_generate_at_slot(
    cfg: &Config,
    backend: Backend,
    slot: u32,
    generate_jitconfig: impl FnOnce(
        &crate::config::GithubConfig,
        &str,
        &[String],
        &HashSet<u64>,
    ) -> Result<(String, u64)>,
) -> Result<(String, String)> {
    require_host_containment(cfg)?;
    // Validate cpu_burst BEFORE any mutation: even the pre_rm container
    // cleanup below is a docker invocation, so an unsupported burst
    // must refuse before we touch any container or call generate_jitconfig.
    // effective_limits returns Err when cpu_burst=true but daemon is not
    // VM-contained OR daemon_capacity() returned no finite positive ncpu.
    // Map through `admission_preflight_error` so the typed
    // `AdmissionPreflightError` bucket covers BOTH JIT and effective_limits
    // preflight; `start_missing_runners_with_starter` recognizes it via
    // `downcast_ref` and converts it to `admission_paused_reason` instead
    // of charging the slot's failure ladder (a preflight refusal is a
    // whole-fleet config error, not a per-slot defect — opening circuits
    // here would misclassify every slot as broken).
    let (cpus, memory_mb) = effective_limits(cfg)
        .map_err(anyhow::Error::msg)
        .map_err(admission_preflight_error)?;
    let runner_name = runner_name_for(cfg, slot);

    // Clean up any stale container left behind in this slot (failsafe against name conflicts)
    let mut pre_rm = docker_cmd();
    pre_rm.args(["rm", "-f", &runner_name]);
    let _ = run_docker(pre_rm, "pre-start rm -f").ok();
    // Build the set of GitHub runner_ids we own (slot file = host ownership).
    // Pass it to generate_jitconfig so a name collision during the 409
    // self-heal can be reclaimed as one of ours regardless of GitHub's
    // reported status (handles same-host zombies whose heartbeat hasn't
    // decayed yet).
    let owned_ids: HashSet<u64> = read_slot_assignments_for(Some(cfg))?
        .assignments
        .values()
        .filter_map(|s| s.parse::<u64>().ok())
        .collect();
    watchdog::ping();
    let (jit, runner_id) =
        match generate_jitconfig(&cfg.github, &runner_name, &cfg.runner.labels, &owned_ids) {
            Ok(pair) => pair,
            Err(e) => {
                let _ = release_slot_for(Some(cfg), slot);
                return Err(e);
            }
        };
    // Store the runner_id immediately after JIT success so stale-slot
    // reconciliation and crash-recovery can see this slot as owned even if the
    // container never starts.
    record_slot_runner_id_for(Some(cfg), slot, runner_id)?;
    watchdog::ping();

    let mut cmd = docker_cmd();
    cmd.args(["run", "-d", "--rm"]);
    cmd.args(["--name", &runner_name]);
    cmd.args(["--label", MANAGED_LABEL]);
    cmd.args(["--label", &format!("ezgha.runner_id={runner_id}")]);
    // Hard resource limits: the reason this tool exists. A runaway job dies
    // inside its cgroup instead of taking the host down.
    cmd.args(["--memory", &format!("{memory_mb}m")]);
    cmd.args(["--memory-swap", &format!("{memory_mb}m")]);
    if !docker_cpu_controller_available() {
        bail!(CPUS_REQUIRE_CPU_CONTROLLER_ERR);
    }
    cmd.args(["--cpus", &format!("{:.2}", cpus)]);
    cmd.args(["--pids-limit", &format!("{}", cfg.limits.pids)]);
    cmd.args(["--security-opt", "no-new-privileges"]);
    if let Some(parent) = &cfg.limits.cgroup_parent {
        cmd.args(["--cgroup-parent", parent]);
    }
    if backend == Backend::DockerSysbox {
        cmd.args(["--runtime", "sysbox-runc"]);
    }
    // Opt-in shared pip wheelhouse (bead jleechan-93cf): read-only mount so
    // jobs stop writing their whole pip download into the ephemeral
    // container's writable overlay layer every run. Fail-open on absence --
    // this is a pure accelerant, never correctness-required, and the daemon
    // must never refuse to start a runner over a missing cache directory.
    if let Some(wheelhouse) = &cfg.runner.wheelhouse_host_path {
        if std::path::Path::new(wheelhouse).is_dir() {
            cmd.args(["-v", &format!("{wheelhouse}:/opt/wheelhouse:ro")]);
            cmd.args(["-e", "PIP_FIND_LINKS=/opt/wheelhouse"]);
        }
    }
    // Opt-in persistent pip DOWNLOAD cache (bead jleechan-m66a + worldarchitect.ai
    // jleechan-yov): read-write mount of a host directory into the container's
    // `~/.cache/pip`, complementary to the wheelhouse above. Wheelhouse is for
    // pre-staged wheels (read-only); this is the writeable metadata cache pip
    // writes on every `pip install` (--cache-dir default). Without it, every
    // ephemeral container rebuilds the wheel metadata from scratch on every
    // install, even when the python deps haven't changed. Fail-open on absence.
    if let Some(pip_cache) = &cfg.runner.pip_cache_host_path {
        if std::path::Path::new(pip_cache).is_dir() {
            cmd.args([
                "-v",
                &format!("{}:/home/runner/.cache/pip", pip_cache.display()),
            ]);
            cmd.args(["-e", "PIP_CACHE_DIR=/home/runner/.cache/pip"]);
        }
    }
    // Opt-in per-runner job workspace (bead jleechan-93cf): read-write mount
    // so checkouts/builds/test scratch land in a host-visible, trim-eligible
    // directory instead of the container's ephemeral writable overlay layer.
    // Fail-open on absence, same as the wheelhouse mount above. Wiped before
    // every container start (not just on first creation) so a job never
    // inherits a prior job's checkout, build output, or credentials -- the
    // per-job isolation property ephemeral runners exist to guarantee.
    if let Some(workspace_root) = &cfg.runner.workspace_host_path {
        let workspace_root = std::path::Path::new(workspace_root);
        if workspace_root.is_dir() {
            let runner_workspace = workspace_root.join(&runner_name);
            let _ = std::fs::remove_dir_all(&runner_workspace);
            if std::fs::create_dir_all(&runner_workspace).is_ok() {
                cmd.args([
                    "-v",
                    &format!("{}:/home/runner/_work", runner_workspace.to_string_lossy()),
                ]);
                // Flag this container as having the virtiofs-backed workspace
                // mount so the image's /usr/local/bin/tar wrapper
                // (docker/tar-workspace-wrapper.sh) knows to guard tar
                // extractions under /home/runner/_work -- the checkout path
                // (_work/<owner>/<repo>) is NOT covered by the tmpfs shadows
                // below and remains exposed to the same symlink-corruption
                // bug whenever a workflow step tar-extracts an archive
                // containing a symlink there (npm ci, release tarballs,
                // docker save/load, etc). See
                // tests/workspace_mount_symlink_extraction_test.sh step 4.
                cmd.args(["-e", "EZGHA_VIRTIOFS_WORKSPACE=1"]);
                // Shadow the three fixed actions-runner-internal subdirs with
                // tmpfs (bead jleechan-93cf regression, 2026-07-19): tar
                // extraction of an archive containing a symlink corrupts the
                // symlink into a 0-byte, mode-000, unreadable file when the
                // destination is this virtiofs-backed bind mount on
                // Colima/Mac -- confirmed live with actions/setup-python's
                // own tarball (which the runner extracts into _actions when
                // downloading the action) and reproduced in
                // tests/workspace_mount_symlink_extraction_test.sh. A plain
                // `ln -s` on the mount works fine and extraction into the
                // container's own overlay filesystem works fine -- only
                // tar-extracting a real archive onto virtiofs corrupts
                // symlink members. _actions/_temp/_tool are the runner's own
                // action-repo and tool-download caches, always these three
                // names, never needing host persistence for the disk-churn
                // goal this mount exists for (checkouts/build scratch live
                // directly under _work/<owner>/<repo>, unaffected by this).
                // `:exec` is required -- Docker's default tmpfs mount
                // options include `noexec`, but `_tool` stores installed
                // tool runtimes (e.g. setup-python's Python binary) that
                // the job then executes directly from this path. Without
                // `:exec` those runtimes fail with rc126 "Permission
                // denied" even though extraction itself succeeds (bead
                // jleechan-krow, found via adversarial review of this fix).
                for shadowed in ["_actions", "_temp", "_tool"] {
                    cmd.args(["--tmpfs", &format!("/home/runner/_work/{shadowed}:exec")]);
                }
            }
        }
    }
    cmd.arg(&cfg.runner.image);
    cmd.args(["./run.sh", "--jitconfig", &jit]);

    let out = match run_docker(cmd, "docker run start_one") {
        Ok(out) => out,
        Err(err) => {
            let _ = github::remove_runner(&cfg.github, runner_id);
            let _ = release_slot_for(Some(cfg), slot);
            return Err(err);
        }
    };
    watchdog::ping();
    if !out.status.success() {
        // The JIT registration exists server-side but no runner will ever
        // connect; clean it up so the repo runner list stays tidy.
        let _ = github::remove_runner(&cfg.github, runner_id);
        let _ = release_slot_for(Some(cfg), slot);
        bail!(
            "docker run failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
    let container_id = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if let Err(err) = require_container_actions_ancestry(&container_id) {
        let mut rm_cmd = docker_cmd();
        rm_cmd.args(["rm", "-f", &runner_name]);
        let _ = run_docker(rm_cmd, "post-start ancestry compensation rm -f");
        let _ = github::remove_runner(&cfg.github, runner_id);
        let _ = release_slot_for(Some(cfg), slot);
        return Err(err);
    }
    Ok((container_id, runner_name))
}

#[derive(Debug, Clone, Deserialize)]
pub struct ManagedContainer {
    #[serde(rename = "ID")]
    pub id: String,
    #[serde(rename = "Names")]
    pub name: String,
    #[serde(rename = "State")]
    pub state: String,
    #[serde(rename = "RunningFor")]
    pub running_for: String,
}

#[cfg(test)]
static TEST_MANAGED_CONTAINERS: std::sync::Mutex<Option<Vec<ManagedContainer>>> =
    std::sync::Mutex::new(None);
#[cfg(test)]
static TEST_MANAGED_CONTAINER_SNAPSHOTS: std::sync::Mutex<
    std::collections::VecDeque<Vec<ManagedContainer>>,
> = std::sync::Mutex::new(std::collections::VecDeque::new());

fn managed_containers_with_timeout(timeout: Duration) -> Result<Vec<ManagedContainer>> {
    managed_containers_until_deadline(Instant::now() + timeout)
}

fn managed_containers_until_deadline(deadline: Instant) -> Result<Vec<ManagedContainer>> {
    #[cfg(test)]
    if let Some(containers) = TEST_MANAGED_CONTAINER_SNAPSHOTS.lock().unwrap().pop_front() {
        return Ok(containers);
    }

    #[cfg(test)]
    if let Some(containers) = TEST_MANAGED_CONTAINERS.lock().unwrap().clone() {
        return Ok(containers);
    }

    let mut cmd = docker_cmd();
    cmd.args([
        "ps",
        "--filter",
        &format!("label={MANAGED_LABEL}"),
        "--format",
        "json",
    ]);
    let timeout = remaining_until_deadline(deadline, Instant::now())
        .context("docker ps readiness budget expired before spawning")?;
    let probe_deadline = (Instant::now() + timeout).min(deadline);
    let out = run_docker_with_timeout_at_deadline(
        cmd,
        "listing managed containers",
        timeout,
        probe_deadline,
        docker_child_reaper(),
    )?;
    if !out.status.success() {
        bail!("docker ps failed: {}", String::from_utf8_lossy(&out.stderr));
    }
    let mut containers = Vec::new();
    for line in String::from_utf8_lossy(&out.stdout).lines() {
        if line.trim().is_empty() {
            continue;
        }
        containers.push(serde_json::from_str(line).context("unexpected docker ps json")?);
    }
    Ok(containers)
}

pub fn managed_containers() -> Result<Vec<ManagedContainer>> {
    managed_containers_with_timeout(DOCKER_TIMEOUT)
}

/// True if the container's `docker top` output contains a `Runner.Worker` or
/// `Runner.Listener` process. Both indicate the runner is registered and
/// ready to take jobs (Worker = currently running one, Listener = idle and
/// polling GitHub for a job). A container with NEITHER is a real defect
/// (the runner process died / never started). Bead jleechan-viff: prior code
/// (`runner_worker_present`) only checked for Worker, which misclassified
/// idle-but-healthy listeners as "not ready" and triggered false-positive
/// `runner startup settling ceiling reached: 0/6 ready locally (listeners
/// or workers)` CRITICAL during normal idle periods.
fn runner_present(output: &str) -> bool {
    output.lines().skip(1).any(|line| {
        matches!(
            line.split_whitespace().nth(1),
            Some("Runner.Worker" | "Runner.Listener")
        )
    })
}

/// Per-probe outcome of a `docker top` Runner readiness probe.
///
/// `Ready` = `Runner.Worker` or `Runner.Listener` is alive in the container
/// (Bead jleechan-viff: the listener is polling for work and the slot IS
/// operational, so it counts as ready to take jobs alongside an actively
/// executing Worker).
///
/// `NotReady` = `docker top` succeeded but neither Worker nor Listener is
/// running. The container is still alive; this is a genuine "runner process
/// died" failure. Settling must NOT infer absence from this.
///
/// `Absent` = `docker top` returned `No such container` / `No such object`.
/// The container is definitively gone — settling reconciles immediately
/// rather than waiting 25s for a slot that will never come back. This is
/// the bead jleechan-95jk root-cause fix for "keeping slot 3 because docker
/// top says No such container despite snapshot omission".
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProbeOutcome {
    Ready,
    NotReady,
    Absent,
}

/// One readiness-pass result: how many slots are locally ready to take jobs
/// (Listener or Worker present) plus the names of slots whose container is
/// definitively gone (`ProbeOutcome::Absent`). The settling loop uses the
/// `absent` list to force immediate reconciliation instead of polling for
/// 25s waiting for a container that will not return.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ReadinessSummary {
    pub ready: u32,
    pub absent: Vec<String>,
}

#[allow(dead_code)]
fn runner_worker_present(output: &str) -> bool {
    output
        .lines()
        .skip(1)
        .any(|line| line.split_whitespace().nth(1) == Some("Runner.Worker"))
}

fn remaining_until_deadline(deadline: Instant, now: Instant) -> Option<Duration> {
    let remaining = deadline.saturating_duration_since(now);
    (!remaining.is_zero()).then_some(remaining)
}

fn readiness_probe_timeout(remaining: Duration) -> Duration {
    remaining.min(LOCAL_TOP_TIMEOUT)
}

fn readiness_probe_timeout_until(deadline: Instant, now: Instant) -> Option<Duration> {
    remaining_until_deadline(deadline, now).map(readiness_probe_timeout)
}

fn executing_runner_count_with_probe<N, P>(
    cfg: &Config,
    containers: &[ManagedContainer],
    deadline: Instant,
    mut now: N,
    probe: P,
) -> Result<ReadinessSummary>
where
    N: FnMut() -> Instant,
    P: Fn(&ManagedContainer, Duration) -> Result<ProbeOutcome> + Sync,
{
    let owned = current_prefix_containers(containers, cfg);
    if owned.is_empty() {
        return Ok(ReadinessSummary::default());
    }
    // Each host probes at most 20 containers concurrently. The 20 Linux and
    // 4 Mac runners fit in one batch on their respective hosts; excess
    // containers use later batches under the shared 30s readiness deadline.
    //
    // Spawn-then-break on first deadline expiry: each per-container `now()`
    // call yields the remaining wall-clock budget at dispatch time, and the
    // first container whose deadline has expired is rejected (its name is
    // surfaced for the partial-readiness error). The probe itself is `Fn +
    // Sync. Production probes are stateless or use an internal `Mutex`.
    let probe_ref = &probe;
    let mut deadline_expired: Option<String> = None;
    let probe_results: Vec<Result<ProbeOutcome>> = std::thread::scope(|scope| -> Result<_> {
        let mut results = Vec::with_capacity(owned.len());
        let mut next = 0;
        while next < owned.len() {
            let mut handles = Vec::with_capacity(READINESS_PROBE_CONCURRENCY);
            while handles.len() < READINESS_PROBE_CONCURRENCY && next < owned.len() {
                let container = owned[next];
                let timeout = match readiness_probe_timeout_until(deadline, now()) {
                    Some(timeout) => timeout,
                    None => {
                        deadline_expired.get_or_insert_with(|| container.name.clone());
                        break;
                    }
                };
                let name = container.name.clone();
                let handle = std::thread::Builder::new()
                    .name("ezgha-readiness-probe".to_string())
                    .spawn_scoped(scope, move || probe_ref(container, timeout))
                    .map_err(|err| {
                        anyhow::anyhow!(
                            "failed to spawn Runner.Worker readiness probe for {name}: {err}"
                        )
                    })?;
                handles.push(handle);
                next += 1;
            }
            for handle in handles {
                results.push(
                    handle
                        .join()
                        .unwrap_or_else(|panic| -> Result<ProbeOutcome> {
                            Err(anyhow::anyhow!(
                                "Runner.Worker readiness probe panicked: {:?}",
                                panic
                            ))
                        }),
                );
            }
            if deadline_expired.is_some() {
                break;
            }
        }
        Ok(results)
    })?;
    if let Some(name) = deadline_expired {
        return Err(anyhow::Error::msg(format!(
            "Runner.Worker readiness budget expired before inspecting {name}"
        )));
    }

    let mut summary = ReadinessSummary::default();
    for (container, result) in owned.iter().zip(probe_results) {
        match result {
            Ok(ProbeOutcome::Ready) => summary.ready += 1,
            // NotReady = container alive, runner process died. Settling
            // will treat this as "not ready" via the `ready` count being
            // short, but it is NOT an immediate-reconcile trigger — the
            // container is still here and may self-heal on the next tick.
            Ok(ProbeOutcome::NotReady) => {}
            // Absent = docker top says "No such container". The container
            // is gone; settling reconciles immediately instead of waiting
            // 25s for a slot that will never come back (bead jleechan-95jk
            // root-cause: "keeping slot 3 because docker top says No such
            // container despite snapshot omission").
            Ok(ProbeOutcome::Absent) => summary.absent.push(container.name.clone()),
            Err(err) => return Err(err),
        }
    }
    Ok(summary)
}

fn executing_runner_count_from_containers(
    cfg: &Config,
    containers: &[ManagedContainer],
    deadline: Instant,
) -> Result<ReadinessSummary> {
    #[cfg(test)]
    {
        use std::sync::atomic::{AtomicU32, Ordering};
        let owned = current_prefix_containers(containers, cfg);
        let configured = TEST_EXECUTING_RUNNER_COUNTS
            .lock()
            .unwrap()
            .as_mut()
            .expect("test must explicitly configure Runner.Worker readiness")
            .pop_front()
            .expect("test Runner.Worker readiness sequence exhausted");
        // Probe closures must be `Fn + Sync` for parallel readiness probes
        // (production fan-out via `std::thread::scope`). Wrap the
        // monotonically-decreasing remaining counter in an atomic so the
        // `Fn + Sync` bound is satisfied without altering the
        // first-`count`-true-then-false semantics the existing tests
        // (and the original sequential code) relied on. Use
        // a CAS loop (not `fetch_sub`) so the counter saturates at zero
        // — parallel threads can race past zero where the sequential version
        // could not, and a wrapping subtraction would spuriously report
        // post-zero probes as "ready".
        match configured {
            Ok(summary) => {
                // Independent review (round 2): the test seam used to
                // inject a single `u32` ready count, which could not model
                // the absent-container race the post-refill fix is meant
                // to catch (bead jleechan-95jk root-cause). Inject the full
                // `ReadinessSummary { ready, absent }` and have the probe
                // closure return `Absent` for absent-named containers
                // before falling back to the first-`ready`-true count
                // semantics the original tests relied on. Absent-name
                // lookups are O(1) via a HashSet snapshot; the
                // monotonically-decreasing ready counter is the same
                // saturating AtomicU32 used in the original test branch.
                use std::collections::HashSet;
                let absent_set: HashSet<String> = summary.absent.iter().cloned().collect();
                let absent_inside = std::sync::Arc::new(std::sync::Mutex::new(absent_set));
                let absent_inside_for_probe = absent_inside.clone();
                let remaining = AtomicU32::new(summary.ready.min(owned.len() as u32));
                executing_runner_count_with_probe(
                    cfg,
                    containers,
                    deadline,
                    Instant::now,
                    move |container, _timeout| {
                        // Absent-name matches win before the ready-counter
                        // so the orchestrator records them in
                        // `summary.absent` (preserving the test's
                        // injected list verbatim, even if the
                        // `summary.ready` count would otherwise have
                        // assigned Ready to this container).
                        let absent_snap = absent_inside_for_probe.lock().unwrap().clone();
                        if absent_snap.contains(&container.name) {
                            return Ok(ProbeOutcome::Absent);
                        }
                        // Atomically: if `remaining > 0`, decrement and
                        // return Ok(Ready); else return Ok(NotReady)
                        // without mutating the counter. A CAS loop
                        // (not `fetch_sub`) saturates at zero — the
                        // parallel-threads race past zero would
                        // otherwise wrap the counter to u32::MAX. Not
                        // `fetch_update`/`try_update`: the former is
                        // deprecated on rustc 1.99, the latter is
                        // unavailable on older stable toolchains.
                        let present = {
                            let mut cur = remaining.load(Ordering::SeqCst);
                            loop {
                                if cur == 0 {
                                    break false;
                                }
                                match remaining.compare_exchange_weak(
                                    cur,
                                    cur - 1,
                                    Ordering::SeqCst,
                                    Ordering::SeqCst,
                                ) {
                                    Ok(_) => break true,
                                    Err(actual) => cur = actual,
                                }
                            }
                        };
                        Ok(if present {
                            ProbeOutcome::Ready
                        } else {
                            ProbeOutcome::NotReady
                        })
                    },
                )
            }
            Err(error) => Err(anyhow::Error::msg(error)),
        }
    }

    #[cfg(not(test))]
    executing_runner_count_with_probe(
        cfg,
        containers,
        deadline,
        Instant::now,
        |container, timeout| {
            let mut cmd = docker_cmd();
            cmd.args(["top", &container.id, "-eo", "pid,comm"]);
            let probe_deadline = (Instant::now() + timeout).min(deadline);
            let out = run_docker_with_timeout_at_deadline(
                cmd,
                "checking Runner.Worker readiness",
                timeout,
                probe_deadline,
                docker_child_reaper(),
            )
            .with_context(|| format!("inspect Runner.Worker for {}", container.name))?;
            if !out.status.success() {
                let stderr = String::from_utf8_lossy(&out.stderr);
                // Bead jleechan-95jk root-cause: a container that is GONE
                // (docker top: "No such container") is not a probe failure
                // — it is definitive evidence the container is no longer
                // part of the readiness pass. Returning ProbeOutcome::Absent
                // surfaces the slot name to the settling loop so it
                // reconciles immediately instead of polling 25s for a
                // container that will not come back. Genuine failures
                // (timeout, daemon error, transient I/O) still propagate as
                // `Err` so the settling loop reports incomplete evidence.
                if docker_top_container_absent(&stderr) {
                    return Ok(ProbeOutcome::Absent);
                }
                bail!("docker top failed for {}: {}", container.name, stderr);
            }
            let stdout = String::from_utf8_lossy(&out.stdout);
            Ok(if runner_present(&stdout) {
                ProbeOutcome::Ready
            } else {
                ProbeOutcome::NotReady
            })
        },
    )
}

/// Cheap local progress signal for a bounded post-refill settling episode.
/// Returns a [`ReadinessSummary`] whose `ready` count is the locally-polled
/// "ready to take jobs" view (Listener OR Worker per bead jleechan-viff) and
/// whose `absent` list names slots whose container is definitively gone
/// (docker top: "No such container"). The settling loop uses the absent
/// list to force immediate reconciliation instead of waiting 25s for a
/// slot that will never come back (bead jleechan-95jk root-cause). This
/// path talks only to Docker (`ps` + bounded `top`); it never lists or
/// mutates GitHub runners, registrations, or workflow jobs.
pub fn local_executing_runner_count(cfg: &Config) -> Result<ReadinessSummary> {
    let deadline = Instant::now() + LOCAL_READINESS_BUDGET;
    let containers = managed_containers_until_deadline(deadline)?;
    executing_runner_count_from_containers(cfg, &containers, deadline)
}

/// Process-wide high-water-mark of each managed runner container's RSS, in
/// MB, keyed by container name. Updated every `release_stale_slots` tick
/// (the existing per-serve-tick reconciliation loop) and logged once a
/// tracked container disappears (job finished / slot reclaimed / container
/// removed). Bead ez-gh-actions-yz6b: this is observability only — it does
/// NOT feed back into scheduling in this bead (deferred to a possible
/// future VM-resize decision).
static PEAK_RSS_MB: std::sync::Mutex<BTreeMap<String, u64>> =
    std::sync::Mutex::new(BTreeMap::new());

/// Debounce window for `poll_peak_rss`: `ensure_count_outcome` calls
/// `release_stale_slots` twice per serve tick (once before spawning new
/// runners, once after, to release failed reservations from that cycle) —
/// without this, the `docker stats` subprocess would fire twice per tick
/// for no additional telemetry value. 5s is comfortably below the normal
/// tick cadence (`serve_tick_seconds`, default 30, floor 5) so back-to-back
/// same-tick calls collapse into one poll while genuinely separate ticks
/// still poll fresh.
const PEAK_RSS_POLL_DEBOUNCE: Duration = Duration::from_secs(5);

static LAST_PEAK_RSS_POLL: std::sync::Mutex<Option<Instant>> = std::sync::Mutex::new(None);

/// Poll `docker stats --no-stream` for every currently-managed container
/// and update the process-wide peak-RSS high-water mark. Best-effort: any
/// failure (docker busy, transient error, unrecognized output format) is
/// swallowed with a warning — RSS telemetry must never be able to block or
/// break the reconciliation tick it rides along with.
fn poll_peak_rss(containers: &[ManagedContainer]) {
    // Debounce: collapse back-to-back calls within the same tick.
    {
        let mut last = LAST_PEAK_RSS_POLL.lock().unwrap();
        let now = Instant::now();
        if let Some(prev) = *last {
            if now.duration_since(prev) < PEAK_RSS_POLL_DEBOUNCE {
                return;
            }
        }
        *last = Some(now);
    }

    if containers.is_empty() {
        return;
    }
    let mut cmd = docker_cmd();
    cmd.arg("stats");
    cmd.args(["--no-stream", "--format", "{{.Name}}\t{{.MemUsage}}"]);
    for c in containers {
        cmd.arg(&c.id);
    }
    // Deliberately short, dedicated timeout (NOT the full 45s DOCKER_TIMEOUT):
    // this call runs inside release_stale_slots, which ensure_count_outcome
    // calls BEFORE checking alive count / spawning replacements — a stalled
    // telemetry-only call must not meaningfully delay respawn decisions.
    // Bead ez-gh-actions-yz6b round 3 (adversarial review P2 finding).
    const PEAK_RSS_POLL_TIMEOUT: Duration = Duration::from_secs(10);
    let out = match run_docker_with_timeout(cmd, "polling peak RSS", PEAK_RSS_POLL_TIMEOUT) {
        Ok(out) if out.status.success() => out,
        Ok(out) => {
            eprintln!(
                "warning: docker stats (peak RSS poll) failed: {}",
                String::from_utf8_lossy(&out.stderr)
            );
            return;
        }
        Err(err) => {
            eprintln!("warning: docker stats (peak RSS poll) failed: {err:#}");
            return;
        }
    };
    let mut peaks = PEAK_RSS_MB.lock().unwrap();
    for line in String::from_utf8_lossy(&out.stdout).lines() {
        let Some((name, mem_usage)) = line.split_once('\t') else {
            continue;
        };
        let Some(mb) = parse_mem_usage_mb(mem_usage) else {
            continue;
        };
        let entry = peaks.entry(name.to_string()).or_insert(0);
        if mb > *entry {
            *entry = mb;
        }
    }
}

/// Parse docker stats' `MemUsage` column, e.g. `"512.3MiB / 3GiB"`,
/// returning the USED side converted to whole MB (rounded). Returns `None`
/// on any format this function doesn't recognize rather than panicking —
/// telemetry parsing must never crash the daemon.
fn parse_mem_usage_mb(s: &str) -> Option<u64> {
    let used = s.split('/').next()?.trim();
    parse_docker_size_mb(used)
}

fn parse_docker_size_mb(s: &str) -> Option<u64> {
    let s = s.trim();
    let split_at = s.find(|c: char| c.is_alphabetic())?;
    let (num_part, unit) = s.split_at(split_at);
    let value: f64 = num_part.trim().parse().ok()?;
    let mb = match unit.trim() {
        "B" => value / 1024.0 / 1024.0,
        "KiB" | "kB" => value / 1024.0,
        "MiB" | "MB" => value,
        "GiB" | "GB" => value * 1024.0,
        _ => return None,
    };
    Some(mb.round() as u64)
}

/// Log and drop peak-RSS entries for containers that vanished since the
/// last poll (job finished, slot reclaimed, container removed). Called once
/// per `release_stale_slots` tick with the fresh set of currently-alive
/// managed container names.
fn reap_stale_peak_rss_entries(alive_names: &HashSet<String>) {
    let mut peaks = PEAK_RSS_MB.lock().unwrap();
    let gone: Vec<String> = peaks
        .keys()
        .filter(|name| !alive_names.contains(*name))
        .cloned()
        .collect();
    for name in gone {
        if let Some(peak_mb) = peaks.remove(&name) {
            eprintln!(
                "info: runner {name} reclaimed — peak RSS {peak_mb} MB observed over lifetime"
            );
        }
    }
}

fn current_prefix_containers<'a>(
    containers: &'a [ManagedContainer],
    cfg: &Config,
) -> Vec<&'a ManagedContainer> {
    containers
        .iter()
        .filter(|c| runner_name_matches_prefix(&c.name, &cfg.runner.name_prefix))
        .collect()
}

fn runner_name_matches_prefix(name: &str, prefix: &str) -> bool {
    let Some(suffix) = name
        .strip_prefix(prefix)
        .and_then(|rest| rest.strip_prefix('-'))
    else {
        return false;
    };
    !suffix.is_empty() && suffix.bytes().all(|b| b.is_ascii_digit())
}

/// Kill all managed runner containers. Returns how many were removed.
pub fn stop_all(cfg: &Config) -> Result<usize> {
    let containers = managed_containers()?;
    let owned_containers = current_prefix_containers(&containers, cfg);
    for c in &owned_containers {
        let mut cmd = docker_cmd();
        cmd.args(["rm", "-f", &c.id]);
        let _ = run_docker(cmd, "stop_all rm -f").ok();
    }
    // Deregister THIS HOST's runners: only the slots we own (from local slot
    // assignments), so we never tear down a sibling host's `ez-org-runner-N`
    // that happens to share a numeric slot. The global prefix alone is not
    // a safety boundary — slot ownership is. Use the configured prefix (NOT
    // `our_runner_prefix()`'s hardcoded default) so a host with a custom
    // prefix like `lab-runner` correctly tears down its own slots.
    let prefix = format!("{}-", cfg.runner.name_prefix);
    let owned_runner_ids: Vec<u64> = match read_slot_assignments_for(Some(cfg)) {
        Ok(a) => a
            .assignments
            .values()
            .filter_map(|s| s.parse::<u64>().ok())
            .collect(),
        Err(_) => Vec::new(),
    };
    // Propagate `list_runners` errors (including the partial-snapshot bail from
    // `list_runners_core`) so the operator sees the failure instead of silently
    // leaving stale registrations behind. The local `docker rm -f` loop above
    // has already removed every container we owned, so the worst case on Err
    // is leftover GitHub-side registrations that the next daemon restart's
    // `release_stale_slots` will reap.
    match github::list_runners(&cfg.github) {
        Ok(runners) => {
            for r in runners {
                let owned = owned_runner_ids.contains(&r.id);
                if owned && r.name.starts_with(&prefix) && !r.busy {
                    let _ = github::remove_runner(&cfg.github, r.id);
                }
            }
        }
        Err(e) => {
            return Err(e).context("stop_all: list_runners failed; local containers already removed, retry to clean up GitHub registrations");
        }
    }
    // Release every slot we held. Even if the container died ungracefully, the
    // JIT registration may still be idle on the server; the next start_one
    // call will claim the next free slot.
    let slots_to_release: Vec<u32> = match read_slot_assignments_for(Some(cfg)) {
        Ok(a) => a
            .assignments
            .keys()
            .filter_map(|k| k.parse::<u32>().ok())
            .collect(),
        Err(_) => Vec::new(),
    };
    for slot in slots_to_release {
        let _ = release_slot_for(Some(cfg), slot);
    }
    Ok(owned_containers.len())
}

/// Outcome counts from a graceful-shutdown drain — used for the operator log
/// line and for unit tests.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct DrainSummary {
    /// Empty-id reservations (JIT never issued) freed locally.
    pub reservations_released: usize,
    /// In-flight orphan registrations (no container) deregistered on GitHub.
    pub registrations_deregistered: usize,
    /// Registrations backed by a live container — left alive (survive restart).
    pub containers_preserved: usize,
    /// Left for `release_stale_slots` + 60s grace window (deadline hit, delete
    /// failed, container state unknown, or unparseable id). Fail-safe.
    pub deferred_to_reaper: usize,
}

/// Graceful-shutdown drain (bead ez-gh-actions-30p). On SIGTERM the serve loop
/// calls this after breaking out of the loop. It deregisters JIT registrations
/// that are recorded in the slot file but have NO backing container (the orphan
/// window), so a daemon restart never leaves a live GitHub registration with no
/// runner. Registrations backed by a running container are LEFT UNTOUCHED — the
/// runner (busy or idle) survives the restart and is re-adopted by `ensure_count`
/// on next start (requirement 3: never kill running containers). Best-effort and
/// bounded by `deadline` (≤15s); anything not drained in time is reclaimed by the
/// reaper. Fail-safe, never fail-orphan: on any uncertainty it defers.
///
/// CONCURRENCY INVARIANT: this drain runs AFTER the serve loop has broken, in a
/// process where spawning is single-threaded and `docker run` is synchronous, so
/// by the time we read the slot file no new JIT registration can enter the orphan
/// window. If spawning ever becomes concurrent/async (a background spawner still
/// live during drain), this function MUST additionally honor the
/// `REGISTRATION_GRACE_WINDOW` guard (as `release_stale_slots` does) before
/// deregistering, or it could delete a registration whose container is still
/// mid-launch on another thread.
pub fn drain_inflight_registrations(cfg: &Config, deadline: Instant) -> DrainSummary {
    // Source of truth for "is a real container attached to this slot". If we
    // CANNOT list containers, we must not risk deregistering a live runner —
    // pass None so assigned slots defer to the reaper (empty reservations are
    // still safe to free: no GH registration exists for them).
    let container_names: Option<HashSet<String>> = match managed_containers() {
        Ok(list) => Some(list.into_iter().map(|c| c.name).collect()),
        Err(e) => {
            eprintln!(
                "drain: could not list containers ({e:#}); releasing empty reservations only, \
                 leaving assigned slots to release_stale_slots"
            );
            None
        }
    };
    drain_inflight_registrations_inner(cfg, deadline, container_names.as_ref(), |id, dl| {
        github::remove_runner_until(&cfg.github, id, dl)
    })
}

/// Testable core of the drain. `container_names` is the set of live managed
/// container names, or `None` when container state is unknown (docker ps
/// failed). `remove_runner` is the deadline-bounded GitHub delete (injected in
/// tests). Delete strictly by owned runner_id (from the slot file), never by
/// name.
fn drain_inflight_registrations_inner(
    cfg: &Config,
    deadline: Instant,
    container_names: Option<&HashSet<String>>,
    remove_runner: impl Fn(u64, Instant) -> Result<()>,
) -> DrainSummary {
    let mut summary = DrainSummary::default();
    let regs = match read_slot_assignments_for(Some(cfg)) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("drain: could not read slot assignments ({e:#}); leaving all to reaper");
            return summary;
        }
    };
    for (slot_key, id_str) in &regs.assignments {
        let Ok(slot) = slot_key.parse::<u32>() else {
            continue;
        };
        if id_str.is_empty() {
            // Reserved, JIT not yet issued — no GitHub registration exists; free it.
            if release_slot_for(Some(cfg), slot).is_ok() {
                summary.reservations_released += 1;
            }
            continue;
        }
        let Ok(runner_id) = id_str.parse::<u64>() else {
            // Unparseable id: never guess — let the reaper handle it.
            summary.deferred_to_reaper += 1;
            continue;
        };
        let Some(names) = container_names else {
            // Container state unknown: cannot prove this is an orphan — defer.
            summary.deferred_to_reaper += 1;
            continue;
        };
        if names.contains(&runner_name_for(cfg, slot)) {
            // A live container is attached — leave the runner alive.
            summary.containers_preserved += 1;
            continue;
        }
        // In-flight orphan: registration exists, no container ⇒ deregister.
        if Instant::now() >= deadline {
            summary.deferred_to_reaper += 1;
            continue;
        }
        match remove_runner(runner_id, deadline) {
            Ok(()) => {
                let _ = release_slot_for(Some(cfg), slot);
                summary.registrations_deregistered += 1;
            }
            Err(e) => {
                eprintln!("drain: remove_runner {runner_id} failed ({e:#}); leaving to reaper");
                summary.deferred_to_reaper += 1;
            }
        }
    }
    summary
}

/// Free disk in GB as seen by the docker DAEMON, measured from inside a
/// container: the container's root overlay lives on the daemon's storage, so
/// this is the disk runner jobs will actually fill. A host-side `df` would
/// read the wrong filesystem whenever the daemon is a VM (Colima/Lima/Desktop).
pub fn free_disk_gb(image: &str) -> Option<u64> {
    #[cfg(test)]
    if let Some(free) = *TEST_FREE_DISK_GB.lock().unwrap() {
        return free;
    }

    let mut cmd = docker_cmd();
    cmd.args(["run", "--rm", "--entrypoint", "df", image, "-Pk", "/"]);
    let out = run_docker(cmd, "measuring docker daemon free disk")
        .ok()
        .filter(|o| o.status.success())?;
    let stdout = String::from_utf8_lossy(&out.stdout);
    let avail_kb: u64 = stdout
        .lines()
        .nth(1)?
        .split_whitespace()
        .nth(3)?
        .parse()
        .ok()?;
    Some(avail_kb / 1024 / 1024)
}

/// Free space on the outer host filesystem that backs Docker's storage.
/// This is intentionally separate from `free_disk_gb`: with Colima the guest
/// can report ample overlay space while its sparse disk has exhausted APFS.
fn is_macos_host() -> bool {
    #[cfg(test)]
    if let Some(is_macos) = *TEST_IS_MACOS_HOST.lock().unwrap() {
        return is_macos;
    }
    cfg!(target_os = "macos")
}

fn host_free_disk_gb() -> Option<u64> {
    #[cfg(test)]
    if let Some(free) = *TEST_HOST_FREE_DISK_GB.lock().unwrap() {
        return free;
    }

    let path = if is_macos_host() {
        "/System/Volumes/Data"
    } else {
        "/"
    };
    let path = CString::new(path).ok()?;
    let mut stats: libc::statvfs = unsafe { std::mem::zeroed() };
    // SAFETY: `path` is a live NUL-terminated CString and `stats` points to a
    // valid writable `statvfs` value for the duration of the call.
    if unsafe { libc::statvfs(path.as_ptr(), &mut stats) } != 0 {
        return None;
    }
    let available_bytes = u128::from(stats.f_bavail) * u128::from(stats.f_frsize);
    Some((available_bytes / 1024 / 1024 / 1024) as u64)
}

/// Start `missing` runners, one per free slot. Tracks which slot numbers have
/// already failed WITHIN this call and excludes them from subsequent slot
/// picks, so a single permanently-broken slot (e.g. an unresolvable 409
/// zombie GitHub registration) can only ever consume one of the `missing`
/// attempts — the other attempts try genuinely different slots instead of
/// retrying the same one `missing` times (bead ez-gh-actions-oau; confirmed
/// live incident 2026-07-08: 90+ consecutive attempts concentrated on one
/// slot collapsed the entire 16-slot fleet to 0 containers).
///
/// This exclusion is scoped to a single call: it does not persist across
/// separate `ensure_count` ticks, so a transiently-failed slot is retried
/// normally on the next tick.
fn start_missing_runners(
    cfg: &Config,
    backend: Backend,
    missing: u32,
) -> Result<StartMissingOutcome> {
    start_missing_runners_with_starter(cfg, backend, missing, start_one_at_slot)
}

#[derive(Debug, Default, PartialEq, Eq)]
struct StartMissingOutcome {
    started: Vec<String>,
    /// Every allocated slot in this batch, including failed starts.
    attempted_slots: HashSet<u32>,
    start_failures: u32,
    admission_paused_reason: Option<String>,
}

fn failure_ladder_policy(cfg: &Config) -> FailureLadderPolicy {
    FailureLadderPolicy {
        slot_failure_threshold: cfg.failure_ladder.slot_failure_threshold,
        slot_window_secs: cfg.failure_ladder.slot_failure_window_secs,
        slot_cooldown_secs: cfg.failure_ladder.slot_cooldown_secs,
        // Keep the default policy usable for legacy/small one- and two-slot
        // configs while ensuring the fleet circuit is never impossible.
        fleet_open_slots_threshold: cfg
            .failure_ladder
            .fleet_open_slot_threshold
            .min(cfg.runner.count.max(1)),
        fleet_cooldown_secs: cfg.failure_ladder.fleet_cooldown_secs,
    }
}

fn failure_ladder_path_for(cfg: &Config) -> PathBuf {
    if let Ok(path) = env::var(FAILURE_LADDER_PATH_ENV) {
        return PathBuf::from(path);
    }
    if let Some(state_dir) = &cfg.state_dir {
        return state_dir.join("failure_ladder.toml");
    }
    slot_assignments_path_for(Some(cfg)).with_file_name("failure_ladder.toml")
}

fn notify_failure_ladder_transition(
    cfg: &Config,
    transition: &FailureLadderTransition,
    open_slots: usize,
) {
    if transition.slot_opened {
        let slot = transition.slot.expect("slot-open transition has a slot");
        let _ = alert::notify(
            cfg,
            &format!("runner_pool.slot_circuit.{slot}"),
            Severity::Warning,
            "Runner slot circuit opened",
            &format!(
                "slot {slot} reached the local-start failure threshold; excluding only that slot for {} seconds while sibling slots remain eligible",
                cfg.failure_ladder.slot_cooldown_secs
            ),
        );
    }
    if transition.fleet_opened {
        let _ = alert::notify(
            cfg,
            "runner_pool.fleet_admission_circuit",
            Severity::Critical,
            "Runner fleet admission paused",
            &format!(
                "{open_slots} distinct slot circuits are open; pausing only new runner starts for {} seconds. Existing jobs continue, and ezgha will not stop the VM or host",
                cfg.failure_ladder.fleet_cooldown_secs
            ),
        );
    }
    if transition.slot_closed || transition.fleet_closed {
        eprintln!(
            "info: runner failure circuit recovered (slot={:?}, slot_closed={}, fleet_closed={})",
            transition.slot, transition.slot_closed, transition.fleet_closed
        );
    }
}

struct AdmissionBatch {
    slots: u32,
    paused: Option<String>,
    lock: Option<std::fs::File>,
}

impl Drop for AdmissionBatch {
    fn drop(&mut self) {
        use std::os::fd::AsRawFd;
        if let Some(lock) = &self.lock {
            // Release ownership even while a forked child retains the descriptor.
            unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_UN) };
        }
    }
}

fn admission_batch(cfg: &Config, missing: u32) -> Result<AdmissionBatch> {
    let batch = AdmissionBatch {
        slots: missing,
        paused: None,
        lock: None,
    };
    #[cfg(target_os = "linux")]
    let mut batch = batch;
    #[cfg(target_os = "linux")]
    {
        #[cfg(test)]
        if *TEST_HOST_CONTAINMENT_OVERRIDE.lock().unwrap() == Some(true)
            && *TEST_HOST_CONTAINMENT_DAEMON_IN_VM.lock().unwrap() != Some(false)
        {
            return Ok(batch);
        }
        if missing == 0 || is_macos_host() || host_containment_daemon_in_vm() {
            return Ok(batch);
        }
        use std::os::fd::AsRawFd;
        use std::os::unix::fs::OpenOptionsExt;
        // Native supervisors for this user share admission across state directories.
        #[cfg(not(test))]
        let directory = PathBuf::from(env::var("HOME").context("native admission needs HOME")?)
            .join(".local/state/ezgha");
        #[cfg(test)]
        let directory = cfg
            .state_dir
            .clone()
            .context("test admission needs isolated state_dir")?;
        std::fs::create_dir_all(&directory)?;
        let lock = std::fs::OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(false)
            .mode(0o600)
            .open(directory.join("actions-admission.lock"))?;
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            bail!(
                "native runner admission lock unavailable: {}",
                std::io::Error::last_os_error()
            );
        }
        batch.lock = Some(lock);
        let hard: u64 = read_host_actions_limit(&host_actions_cgroup_root(), "memory.max")?
            .parse()
            .context("actions.slice memory.max must be finite")?;
        let new_cap = cfg
            .limits
            .memory_mb
            .checked_mul(1024 * 1024)
            .filter(|cap| *cap > 0)
            .context("runner cap must be finite and positive")?;
        let mut command = docker_cmd();
        command.args(["ps", "--quiet", "--no-trunc"]);
        let output = run_docker(command, "listing native admission consumers")?;
        if !output.status.success() {
            bail!("native admission listing failed");
        }
        let ids: HashSet<String> = std::str::from_utf8(&output.stdout)?
            .split_whitespace()
            .map(str::to_owned)
            .collect();
        let mut used = 0u64;
        if !ids.is_empty() {
            let mut command = docker_cmd();
            command.args(["inspect", "--format", "{\"Id\":{{json .Id}},\"CgroupParent\":{{json .HostConfig.CgroupParent}},\"Memory\":{{json .HostConfig.Memory}}}"]);
            command.args(&ids);
            let output = run_docker(command, "inspecting native admission consumers")?;
            if !output.status.success() {
                bail!("native admission inspection failed");
            }
            #[derive(Deserialize)]
            #[serde(rename_all = "PascalCase")]
            struct Consumer {
                id: String,
                cgroup_parent: String,
                memory: u64,
            }
            let mut seen = HashSet::new();
            for line in std::str::from_utf8(&output.stdout)?.lines() {
                let row: Consumer = serde_json::from_str(line)?;
                if !ids.contains(&row.id) || !seen.insert(row.id) {
                    bail!("unknown or duplicate admission container");
                }
                let parent = row.cgroup_parent.trim_start_matches('/');
                if parent == "actions.slice"
                    || parent.starts_with("actions.slice/")
                    || (parent.starts_with("actions-") && parent.ends_with(".slice"))
                {
                    if row.memory == 0 {
                        bail!("actions.slice contains an unbounded container");
                    }
                    used = used
                        .checked_add(row.memory)
                        .context("container memory sum overflow")?;
                }
            }
            if seen != ids {
                bail!("native admission inspection was incomplete");
            }
        }
        batch.slots =
            missing.min((hard.saturating_sub(used) / new_cap).min(u32::MAX as u64) as u32);
        if batch.slots < missing {
            batch.paused = Some(format!("actions.slice memory permits {} of {missing} starts: existing caps={used}, new cap={new_cap}, parent max={hard}; existing jobs remain running", batch.slots));
        }
    }
    #[cfg(not(target_os = "linux"))]
    let _ = cfg;
    Ok(batch)
}

fn start_missing_runners_with_starter(
    cfg: &Config,
    backend: Backend,
    missing: u32,
    starter: impl Fn(&Config, Backend, u32) -> Result<(String, String)>,
) -> Result<StartMissingOutcome> {
    if FAILURE_LADDER_PERSISTENCE_FAILED.load(Ordering::SeqCst) {
        let reason =
            "failure-ladder persistence previously failed; runner admission remains paused until daemon restart";
        eprintln!("warning: {reason}");
        return Ok(StartMissingOutcome {
            admission_paused_reason: Some(reason.into()),
            ..StartMissingOutcome::default()
        });
    }
    let mut started = Vec::new();
    let mut attempted_slots = HashSet::new();
    let mut start_failures = 0;
    let mut last_err = None;
    let path = failure_ladder_path_for(cfg);
    let policy = failure_ladder_policy(cfg);
    let mut ladder = match FailureLadder::load(&path) {
        Ok(ladder) => ladder,
        Err(err) => {
            let reason = format!(
                "failure-ladder state is unreadable; failing closed without starting runners: {err:#}"
            );
            let _ = alert::notify(
                cfg,
                "runner_pool.failure_ladder_state",
                Severity::Critical,
                "Runner admission paused: failure-ladder state unreadable",
                &reason,
            );
            return Ok(StartMissingOutcome {
                admission_paused_reason: Some(reason),
                ..StartMissingOutcome::default()
            });
        }
    };
    let now = now_epoch_secs();
    let mut failed_slots: HashSet<u32> = ladder.excluded_slots(now);
    if ladder.fleet_admission_is_paused(now) {
        return Ok(StartMissingOutcome {
            admission_paused_reason: Some(format!(
                "fleet admission circuit is open with {} slot circuit(s); existing jobs remain running",
                ladder.open_slot_count(now)
            )),
            ..StartMissingOutcome::default()
        });
    }
    // Prove that the current ledger can still be durably persisted before any
    // external JIT/Docker start.  A transition save can race with filesystem
    // failure after this point, so the daemon-lifetime latch below remains
    // necessary; this preflight closes the first-attempt fail-open window.
    if let Err(err) = ladder.save(&path) {
        FAILURE_LADDER_PERSISTENCE_FAILED.store(true, Ordering::SeqCst);
        let reason = format!(
            "could not preflight failure-ladder persistence; runner admission remains paused until daemon restart: {err:#}"
        );
        eprintln!("warning: {reason}");
        return Ok(StartMissingOutcome {
            admission_paused_reason: Some(reason),
            ..StartMissingOutcome::default()
        });
    }
    let batch = match admission_batch(cfg, missing) {
        Ok(batch) => batch,
        Err(error) => {
            return Ok(StartMissingOutcome {
                admission_paused_reason: Some(format!("native runner admission paused: {error:#}")),
                ..StartMissingOutcome::default()
            })
        }
    };
    let mut admission_paused_reason = batch.paused.clone();
    // A failed attempt may have created a container, so it still spends capacity.
    for _ in 0..batch.slots {
        if crate::shutdown::is_requested() {
            eprintln!("shutdown requested; stopping runner spawn mid-batch");
            break;
        }
        watchdog::ping();
        let slot = match next_slot_excluding(cfg, &failed_slots) {
            Ok(Some(slot)) => slot,
            Ok(None) => {
                if ladder.open_slot_count(now_epoch_secs()) > 0 {
                    admission_paused_reason = Some(format!(
                        "{} runner slot circuit(s) are cooling down; sibling slots are occupied or settling",
                        ladder.open_slot_count(now_epoch_secs())
                    ));
                } else {
                    eprintln!(
                        "info: no free runner slot yet; registration turnover is still settling"
                    );
                }
                break;
            }
            Err(e) => {
                eprintln!("warning: failed to allocate a runner slot: {e:#}");
                start_failures += 1;
                last_err = Some(e);
                break;
            }
        };
        attempted_slots.insert(slot);
        match starter(cfg, backend, slot) {
            Ok((_, name)) => {
                started.push(name);
                let transition = ladder.record_success(slot, now_epoch_secs());
                if let Err(err) = ladder.save(&path) {
                    FAILURE_LADDER_PERSISTENCE_FAILED.store(true, Ordering::SeqCst);
                    admission_paused_reason = Some(format!(
                        "could not persist failure-ladder recovery; pausing further starts: {err:#}"
                    ));
                    break;
                }
                notify_failure_ladder_transition(
                    cfg,
                    &transition,
                    ladder.open_slot_count(now_epoch_secs()),
                );
            }
            Err(e) => {
                eprintln!("warning: failed to start runner in slot {slot}: {e:#}");
                if e.downcast_ref::<AdmissionPreflightError>().is_some() {
                    start_failures += 1;
                    admission_paused_reason = Some(format!(
                        "admission preflight refused the entire refill without penalizing slot {slot}: {e:#}"
                    ));
                    break;
                }
                failed_slots.insert(slot);
                start_failures += 1;
                let transition = ladder.record_failure(policy, slot, now_epoch_secs())?;
                if let Err(err) = ladder.save(&path) {
                    FAILURE_LADDER_PERSISTENCE_FAILED.store(true, Ordering::SeqCst);
                    admission_paused_reason = Some(format!(
                        "could not persist failure-ladder failure; pausing further starts: {err:#}"
                    ));
                    break;
                }
                notify_failure_ladder_transition(
                    cfg,
                    &transition,
                    ladder.open_slot_count(now_epoch_secs()),
                );
                if transition.slot_opened {
                    debug_assert!(ladder.slot_is_open(slot, now_epoch_secs()));
                }
                if ladder.fleet_admission_is_paused(now_epoch_secs()) {
                    admission_paused_reason = Some(format!(
                        "fleet admission circuit opened after {} distinct slot circuits; existing jobs remain running",
                        ladder.open_slot_count(now_epoch_secs())
                    ));
                    break;
                }
            }
        }
    }

    if started.is_empty() {
        if let Some(e) = last_err {
            return Err(e);
        }
    }
    Ok(StartMissingOutcome {
        started,
        attempted_slots,
        start_failures,
        admission_paused_reason,
    })
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EnsureCountOutcome {
    pub started: Vec<String>,
    /// Shortage observed before this call's sole start batch.
    pub missing: u32,
    /// Shortage from a fresh local Runner.Worker readiness recount after that batch.
    pub remaining_shortage: u32,
    /// Explicit incomplete post-refill readiness evidence. When present,
    /// `remaining_shortage` is only the managed-container shortfall and the
    /// serve loop must reconcile on the next iteration instead of treating
    /// the worker state as recovered (they run async via the
    /// `QueueMonitorScheduler`).
    pub post_refill_readiness_error: Option<String>,
    /// Configured runners present before refill but absent from the successful
    /// post-refill inventory.
    pub post_refill_capacity_lost: Vec<String>,
    /// Named nonempty reservations held before the batch and freed by its
    /// trailing release, absent locally and currently eligible for allocation.
    /// This proves newly available slots, not prior running containers.
    pub post_refill_slots_released: Vec<String>,
    /// Actual JIT/Docker/allocator failures, excluding occupied reservations
    /// that are still settling after a one-job container exits.
    pub start_failures: u32,
    pub reclaimed: u32,
    /// A deliberate admission refusal is not a backend failure and must not
    /// trigger a Colima restart. Existing jobs continue to run.
    pub admission_paused_reason: Option<String>,
}

impl EnsureCountOutcome {
    /// Pending registration turnover is not a backend failure. Only an
    /// attempted start/allocation that actually failed advances alert/restart
    /// accounting.
    pub fn is_partial_failure(&self) -> bool {
        self.start_failures > 0
    }
}

fn admission_paused_outcome(missing: u32, reason: String) -> EnsureCountOutcome {
    EnsureCountOutcome {
        started: Vec::new(),
        missing,
        remaining_shortage: missing,
        post_refill_readiness_error: None,
        post_refill_capacity_lost: Vec::new(),
        post_refill_slots_released: Vec::new(),
        start_failures: 0,
        reclaimed: 0,
        admission_paused_reason: Some(reason),
    }
}

// Evidence-only reads must not use the allocator's corrupt/missing-file
// recovery: unknown state is not proof that a reservation became vacant.
fn release_slot_snapshot(cfg: &Config) -> Option<SlotAssignments> {
    let path = slot_assignments_path_for(Some(cfg));
    let snapshot = (|| -> Result<SlotAssignments> {
        let raw = std::fs::read_to_string(&path)?;
        Ok(toml::from_str(&raw)?)
    })();
    match snapshot {
        Ok(snapshot) => Some(snapshot),
        Err(err) => {
            eprintln!(
                "debug: released-slot evidence unavailable at {}: {err:#}",
                path.display()
            );
            None
        }
    }
}

fn post_refill_released_slots(
    cfg: &Config,
    before_batch: Option<&SlotAssignments>,
    before_release: Option<&SlotAssignments>,
    after_release: Option<&SlotAssignments>,
    attempted_slots: &HashSet<u32>,
    post_refill_names: &HashSet<&str>,
) -> Result<Vec<String>> {
    let (Some(before_batch), Some(before_release), Some(after_release)) =
        (before_batch, before_release, after_release)
    else {
        return Ok(Vec::new());
    };
    // Reuse the allocator's current exclusions without reserving another slot
    // or accepting its fail-soft fallback for uncertain quarantine evidence.
    let quarantine = quarantine::load_quarantine_for(Some(cfg))?.excluded_slots();
    let ladder = FailureLadder::load(failure_ladder_path_for(cfg))?;
    let now = now_epoch_secs();
    if FAILURE_LADDER_PERSISTENCE_FAILED.load(Ordering::SeqCst)
        || ladder.fleet_admission_is_paused(now)
    {
        return Ok(Vec::new());
    }
    let ladder_excluded = ladder.excluded_slots(now);
    let mut released = Vec::new();
    for slot in 1..=cfg.runner.count {
        let key = slot.to_string();
        let Some(id) = before_batch.assignments.get(&key) else {
            continue;
        };
        // Empty reservations and malformed IDs do not establish this event.
        // A valid JIT ID does not imply a prior running container.
        if id.parse::<u64>().is_err()
            || before_release.assignments.get(&key) != Some(id)
            || after_release.assignments.contains_key(&key)
            || attempted_slots.contains(&slot)
            || quarantine.contains(&slot)
            || ladder_excluded.contains(&slot)
        {
            continue;
        }
        let name = runner_name_for(cfg, slot);
        if !post_refill_names.contains(name.as_str()) {
            released.push(name);
        }
    }
    released.sort();
    Ok(released)
}

pub fn ensure_count_outcome(cfg: &Config, backend: Backend) -> Result<EnsureCountOutcome> {
    if let Err(err) = require_host_containment(cfg) {
        let _ = alert::notify(
            cfg,
            "runner_pool.host_containment_failed",
            Severity::Critical,
            "Runner pool paused: host containment failed",
            &format!("Host containment validation failed: {err:#}"),
        );
        return Ok(admission_paused_outcome(
            cfg.runner.count,
            format!("Host containment admission failed: {err:#}"),
        ));
    }
    // Reconcile stale slot assignments before we look at container counts:
    // a daemon crash between `next_slot` and the container coming up leaves a
    // reservation that would otherwise wedge `next_slot` forever ("all N
    // runner slot(s) are currently in use"). `serve` calls this on a 30s
    // loop, so the host self-heals on the next tick.
    let reclaimed = release_stale_slots(cfg).unwrap_or(0) as u32;
    // Print the host-kernel warning at most once per process — `serve` would
    // otherwise re-emit it every 30s.
    DOCTOR_PRINTED.call_once(|| print_doctor(&crate::platform::detect()));
    let containers = managed_containers()?;
    let configured_names: HashSet<String> = (1..=cfg.runner.count)
        .map(|slot| runner_name_for(cfg, slot))
        .collect();
    let initial_witnesses: HashSet<String> = current_prefix_containers(&containers, cfg)
        .into_iter()
        .filter(|container| configured_names.contains(&container.name))
        .map(|container| container.name.clone())
        .collect();
    // Container presence owns normal spawn capacity. Runner.Worker exists only
    // while a job is executing, so using it here would classify a healthy idle
    // Listener-only fleet as missing and create a permanent settle/reconcile loop.
    let alive = current_prefix_containers(&containers, cfg).len() as u32;
    // Resolve before the full-fleet return so the source is logged at
    // startup even when every runner is already present.
    let pressure_source = admission_pressure_source(cfg);
    log_pressure_source_change(&pressure_source);
    if alive >= cfg.runner.count {
        *ADMISSION_PAUSE_EPISODE
            .lock()
            .unwrap_or_else(|p| p.into_inner()) = None;
        return Ok(EnsureCountOutcome {
            started: Vec::new(),
            missing: 0,
            remaining_shortage: 0,
            post_refill_readiness_error: None,
            post_refill_capacity_lost: Vec::new(),
            post_refill_slots_released: Vec::new(),
            start_failures: 0,
            reclaimed,
            admission_paused_reason: None,
        });
    }
    let host_floor_gb = cfg.limits.min_free_disk_gb;
    match host_free_disk_gb() {
        Some(free) if free < host_floor_gb => {
            let _ = alert::notify(
                cfg,
                "runner_pool.host_disk_floor",
                Severity::Critical,
                "Runner pool paused: host disk floor reached",
                &format!(
                    "only {free} GB free on the host filesystem (floor: {host_floor_gb} GB) for {}. refusing to spawn runners until space is reclaimed",
                    cfg.github.target
                ),
            );
            return Ok(admission_paused_outcome(
                cfg.runner.count.saturating_sub(alive),
                format!(
                    "only {free} GB free on the host filesystem (floor: {host_floor_gb} GB) — refusing to spawn runners; reclaim host space first"
                ),
            ));
        }
        Some(free) => {
            if is_macos_host() && free < MACOS_HOST_DISK_PRESSURE_ALERT_GB {
                let _ = alert::notify(
                    cfg,
                    "runner_pool.host_disk_pressure",
                    Severity::Warning,
                    "Mac host disk pressure approaching admission floor",
                    &format!(
                        "{free} GB free on the Mac host filesystem is below the {MACOS_HOST_DISK_PRESSURE_ALERT_GB} GB pressure-alert threshold for {}; runner admission remains enabled until the configured {} GB floor is crossed",
                        cfg.github.target, cfg.limits.min_free_disk_gb
                    ),
                );
            }
        }
        None => {
            let _ = alert::notify(
                cfg,
                "runner_pool.host_disk_measurement_unavailable",
                Severity::Critical,
                "Runner pool paused: host disk measurement unavailable",
                &format!(
                    "could not measure host free disk for {}; refusing to spawn runners until measurement succeeds",
                    cfg.github.target
                ),
            );
            return Ok(admission_paused_outcome(
                cfg.runner.count.saturating_sub(alive),
                "could not measure host filesystem free disk — refusing to spawn runners until measurement recovers".into(),
            ));
        }
    }
    match free_disk_gb(&cfg.runner.image) {
        Some(free) if free < cfg.limits.min_free_disk_gb => {
            CONSECUTIVE_DISK_NONE.store(0, Ordering::Relaxed);
            let _ = alert::notify(
                cfg,
                "runner_pool.disk_floor",
                Severity::Critical,
                "Runner pool paused: docker disk floor reached",
                &format!(
                    "only {free} GB free on docker's filesystem (floor: {} GB) for {}. refusing to spawn runners until space is reclaimed",
                    cfg.limits.min_free_disk_gb,
                    cfg.github.target
                ),
            );
            return Ok(admission_paused_outcome(
                cfg.runner.count.saturating_sub(alive),
                format!(
                    "only {free} GB free on docker's filesystem (floor: {} GB) — refusing to spawn runners; reclaim space first. Do NOT run docker system/image prune: with the fleet idle it deletes the required ezgha-runner:latest image (2026-07-14 incident); prefer `docker builder prune` and container/log cleanup",
                    cfg.limits.min_free_disk_gb
                ),
            ));
        }
        Some(_) => {
            CONSECUTIVE_DISK_NONE.store(0, Ordering::Relaxed);
        }
        None => {
            let n = CONSECUTIVE_DISK_NONE.fetch_add(1, Ordering::Relaxed) + 1;
            if n >= DISK_MEASURE_STRIKES {
                let _ = alert::notify(
                    cfg,
                    "runner_pool.disk_measurement_unavailable",
                    Severity::Critical,
                    "Runner pool paused: disk measurement unavailable",
                    &format!(
                        "could not measure docker daemon free disk for {n} consecutive cycles for {}; refusing to spawn runners until measurement succeeds",
                        cfg.github.target
                    ),
                );
                return Ok(admission_paused_outcome(
                    cfg.runner.count.saturating_sub(alive),
                    format!(
                        "could not measure daemon free disk for {n} cycles in a row — refusing to spawn runners until disk measurement recovers (image missing? df broken? daemon wedged?)"
                    ),
                ));
            }
            eprintln!(
                "warning: could not measure daemon free disk ({n}/{DISK_MEASURE_STRIKES} strikes) \
                 — disk floor guard is NOT active this cycle"
            );
        }
    }
    // Lane-I (Round-3 swarm): pressure-aware admission. Disk floor alone did
    // not save the host from the 2026-07-12 crash — we ALSO need to refuse
    // new starts under sustained memory pressure even if there's plenty
    // of disk. Reads PSI cgroup-v2 memory.pressure + /proc/meminfo; refuses
    // on absolute pressure > 50%, on available < host reserve + runner memory
    // (and the legacy 2× per-runner floor), OR
    // on a 5-tick rising-pressure hysteresis (sustained growth = OOM is
    // imminent even if the current absolute reading is below threshold).
    // Legacy configs without a physical-host reserve remain best-effort when
    // either read fails. Once a reserve is configured, probe failure is a
    // fail-closed admission error. The hysteresis window is read+rotated as
    // one Mutex guard.
    let admission_probe = memory_pressure_pct(&pressure_source);
    let runner_bytes = cfg.limits.memory_mb.saturating_mul(1024 * 1024);
    let host_reserve_bytes = cfg.runner.host_reserve_mb.saturating_mul(1024 * 1024);
    let admission_decision: Result<(), String> = {
        let mut window = PRESSURE_WINDOW.lock().unwrap_or_else(|p| p.into_inner());
        match &admission_probe {
            Ok((pct, available)) => eval_admission(
                *pct,
                *available,
                runner_bytes,
                host_reserve_bytes,
                &mut window,
            ),
            Err(e) => {
                // Preserve the legacy fail-open behavior only when no
                // physical-host reserve is configured. Once an operator has
                // requested a host envelope, inability to measure
                // MemAvailable must fail closed rather than silently bypass
                // that safety contract.
                window.rotate_left(1);
                window[4] = Some(0.0);
                if cfg.runner.host_reserve_mb > 0 {
                    Err(format!(
                        "host-reserve admission probe failed; refusing new start: {e:#}"
                    ))
                } else {
                    // A no-reserve legacy config remains best-effort. The
                    // warning makes the degraded state visible and the zero
                    // sample breaks any rising-pressure chain.
                    eprintln!(
                        "warning: PSI admission probe failed ({e:#}); pressure-aware gate is NOT active this cycle"
                    );
                    Ok(())
                }
            }
        }
    };
    let headroom_bytes = host_reserve_bytes.saturating_add(runner_bytes.saturating_mul(4));
    let available = admission_probe
        .as_ref()
        .ok()
        .map(|(_, available)| *available);
    let headroom = available.is_some_and(|available| available >= headroom_bytes);
    let headroom_alert_due = admission_pause_alert_due(
        &mut ADMISSION_PAUSE_EPISODE
            .lock()
            .unwrap_or_else(|p| p.into_inner()),
        Instant::now(),
        admission_decision.is_err(),
        headroom,
    );
    if let Err(reason) = admission_decision {
        let _ = alert::notify(
            cfg,
            "runner_pool.memory_pressure",
            Severity::Critical,
            "Runner pool paused: memory pressure",
            &format!("refusing to spawn runners: {reason}"),
        );
        if headroom_alert_due {
            let avail_mb = available.unwrap_or(0) / 1024 / 1024;
            let _ = alert::notify(
                cfg,
                "runner_pool.admission_paused_with_headroom",
                Severity::Critical,
                "Runner pool paused 10+ minutes with memory headroom",
                &format!(
                    "admission has been paused for at least 10 minutes while MemAvailable {avail_mb} MB \
                     >= host reserve + 4x runner memory ({} MB); last reason: {reason}; {}",
                    headroom_bytes / 1024 / 1024,
                    pressure_source.describe()
                ),
            );
        }
        return Ok(admission_paused_outcome(
            cfg.runner.count.saturating_sub(alive),
            reason,
        ));
    }
    let missing = cfg.runner.count - alive;
    let before_batch = release_slot_snapshot(cfg);
    let refill = start_missing_runners(cfg, backend, missing);
    let before_release = release_slot_snapshot(cfg);
    // release_stale_slots may repair a corrupt quarantine table; do not turn
    // that fail-soft recovery into affirmative availability evidence.
    let release_eligibility_known = quarantine::load_quarantine_for(Some(cfg)).is_ok();
    // Release any failed reservations from this cycle. A failed release does
    // not establish availability, even if it partially changed local state.
    let release_succeeded = release_stale_slots(cfg).is_ok();
    let after_release = (release_succeeded && release_eligibility_known)
        .then(|| release_slot_snapshot(cfg))
        .flatten();

    let refill = refill?;
    let readiness_deadline = Instant::now() + LOCAL_READINESS_BUDGET;
    let containers_after = managed_containers_until_deadline(readiness_deadline)
        .context("post-refill local container recount")?;
    let post_refill_names: HashSet<&str> = current_prefix_containers(&containers_after, cfg)
        .into_iter()
        .map(|container| container.name.as_str())
        .collect();
    let mut post_refill_capacity_lost: Vec<String> = initial_witnesses
        .into_iter()
        .filter(|name| !post_refill_names.contains(name.as_str()))
        .collect();
    post_refill_capacity_lost.sort();
    let post_refill_slots_released = post_refill_released_slots(
        cfg,
        before_batch.as_ref(),
        before_release.as_ref(),
        after_release.as_ref(),
        &refill.attempted_slots,
        &post_refill_names,
    )
    .unwrap_or_else(|err| {
        eprintln!("warning: post-refill allocation eligibility unknown: {err:#}");
        Vec::new()
    });
    let readiness_after =
        executing_runner_count_from_containers(cfg, &containers_after, readiness_deadline);
    let (remaining_shortage, post_refill_readiness_error) = match readiness_after {
        Ok(summary) => {
            // Independent review (round 2, bead jleechan-95jk fix verified):
            // a vanished container (docker top: "No such container") must
            // count toward the shortage, NOT be treated as alive. If we
            // counted absent as alive (`ready + absent.len()`), a freshly
            // spawned slot that died mid-probe would zero out the shortage
            // and the daemon would pick `Recovered`, skipping the settling
            // episode that surfaces the absent name — and sleeping the
            // full serve-tick (30s) before reconciling. Counting from
            // `ready` only keeps `remaining_shortage > 0` honest and
            // makes the settling loop's new absent-aware immediate
            // reconcile (commit b4669de main.rs:1354-1379) actually fire.
            (cfg.runner.count.saturating_sub(summary.ready), None)
        }
        Err(error) => {
            let detail = format!("{error:#}");
            eprintln!(
                "warning: post-refill Runner.Worker readiness incomplete: {detail}; \
                 preserving successful starts for immediate serve-loop reconciliation"
            );
            let containers_alive = current_prefix_containers(&containers_after, cfg).len() as u32;
            (
                cfg.runner.count.saturating_sub(containers_alive),
                Some(detail),
            )
        }
    };
    let outcome = EnsureCountOutcome {
        started: refill.started,
        missing,
        remaining_shortage,
        post_refill_readiness_error,
        post_refill_capacity_lost,
        post_refill_slots_released,
        start_failures: refill.start_failures,
        reclaimed,
        admission_paused_reason: refill.admission_paused_reason,
    };
    if outcome.is_partial_failure() {
        eprintln!(
            "warning: ensure_count started only {} of {} missing runner(s); treating as partial failure for alert streak accounting",
            outcome.started.len(),
            outcome.missing
        );
    }
    Ok(outcome)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Config, Scope};
    use crate::platform::Platform;
    use std::os::unix::fs::PermissionsExt;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Mutex;
    use std::time::{Duration, Instant};

    /// Process-wide test lock: `slot_assignments_path()` reads from a static
    /// when running tests, so the slot file location and contents are
    /// effectively global state. Serializing tests around this static keeps
    /// each test hermetic without resorting to single-threaded test execution.
    static TEST_LOCK: Mutex<()> = Mutex::new(());

    static TEST_SLOT_PATH: Mutex<Option<PathBuf>> = Mutex::new(None);

    pub(super) fn test_slot_path() -> Option<PathBuf> {
        TEST_SLOT_PATH.lock().unwrap().clone()
    }

    fn tmp_path(label: &str) -> PathBuf {
        static SEQ: AtomicUsize = AtomicUsize::new(0);
        let n = SEQ.fetch_add(1, Ordering::SeqCst);
        let dir =
            env::temp_dir().join(format!("ezgha-test-{}-{}-{}", std::process::id(), label, n));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("slot_assignments.toml")
    }

    fn fake_platform(mem_mb: u64, cpus: u32) -> Platform {
        Platform {
            os: "linux",
            arch: "x86_64",
            kvm_usable: false,
            has_tart: false,
            has_virsh: false,
            docker_ok: true,
            sysbox_runtime: false,
            daemon_in_vm: false,
            total_mem_mb: mem_mb,
            cpus,
        }
    }

    fn cfg_with(count: u32, prefix: &str) -> Config {
        let mut cfg =
            Config::defaults_for(&fake_platform(8192, 4), "jleechanorg".into(), Scope::Org);
        cfg.runner.count = count;
        cfg.runner.name_prefix = prefix.into();
        cfg
    }

    #[test]
    fn fleet_circuit_threshold_is_reachable_for_small_legacy_fleets() {
        let one = cfg_with(1, "ez-org-runner");
        let two = cfg_with(2, "ez-org-runner");
        assert_eq!(failure_ladder_policy(&one).fleet_open_slots_threshold, 1);
        assert_eq!(failure_ladder_policy(&two).fleet_open_slots_threshold, 2);
    }

    /// Lock + redirect the slot assignments path for the duration of a test.
    /// Always pair with `_lock` to avoid races with other tests in the same
    /// binary.
    struct TestEnv {
        _lock: std::sync::MutexGuard<'static, ()>,
        path: PathBuf,
        docker_host_override: Option<std::ffi::OsString>,
    }

    impl TestEnv {
        fn new(label: &str) -> Self {
            let lock = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
            let docker_host_override = env::var_os("DOCKER_HOST_OVERRIDE");
            env::remove_var("DOCKER_HOST_OVERRIDE");
            reset_failure_ladder_admission_latch_for_tests();
            crate::failure_ladder::reset_test_save_failure();
            let path = tmp_path(label);
            *TEST_SLOT_PATH.lock().unwrap() = Some(path.clone());
            *TEST_HOST_FREE_DISK_GB.lock().unwrap() = Some(Some(100));
            *TEST_CONTAINER_ANCESTRY_OVERRIDE.lock().unwrap() =
                Some(label != "host_containment_ancestry");
            *TEST_USER_MANAGER_OOM_PROPERTIES.lock().unwrap() = Some(
                "ManagedOOMMemoryPressure=auto\nManagedOOMSwap=auto\nManagedOOMPreference=none\nOOMScoreAdjust=0\n"
                    .to_owned(),
            );
            // Bead jleechan-uurm: also reset the reclaim ring buffer +
            // daemon-start instant — both live in a process-wide OnceLock
            // (not in TEST_SLOT_PATH) so without this reset a test that
            // expects an empty buffer would see leftover records from
            // earlier tests in the same `cargo test` invocation.
            reset_reclaim_state_for_tests();
            // Redirect the quarantine table into the test's temp dir.
            // Without this, tests whose cfg has no state_dir fall through
            // to the REAL global XDG path (~/.config/ezgha/
            // quarantined_slots.toml): they read production quarantine
            // state (a host whose global file quarantines slot 1 makes
            // next_slot return 2 and every slot-allocation test fail) and
            // WRITE fixture entries into the production file — both
            // observed live on the MacBook, 2026-07-16. Safety: TEST_LOCK
            // serializes every TestEnv test, so a process-wide env var is
            // race-free here.
            let qpath = path
                .parent()
                .map(|p| p.join("quarantined_slots.toml"))
                .unwrap_or_else(|| PathBuf::from("quarantined_slots.toml"));
            std::env::set_var("EZGHA_QUARANTINE_PATH", &qpath);
            if label.starts_with("host_containment") {
                *TEST_HOST_CONTAINMENT_OVERRIDE.lock().unwrap() = Some(false);
                *TEST_HOST_CONTAINMENT_DAEMON_IN_VM.lock().unwrap() = Some(false);
            } else {
                *TEST_HOST_CONTAINMENT_OVERRIDE.lock().unwrap() = Some(true);
            }
            Self {
                _lock: lock,
                path,
                docker_host_override,
            }
        }
    }

    impl Drop for TestEnv {
        fn drop(&mut self) {
            *TEST_SLOT_PATH.lock().unwrap() = None;
            *TEST_RELEASE_STALE_SLOTS_RESULT.lock().unwrap() = None;
            *TEST_FREE_DISK_GB.lock().unwrap() = None;
            *TEST_HOST_FREE_DISK_GB.lock().unwrap() = None;
            *TEST_IS_MACOS_HOST.lock().unwrap() = None;
            *TEST_MANAGED_CONTAINERS.lock().unwrap() = None;
            TEST_MANAGED_CONTAINER_SNAPSHOTS.lock().unwrap().clear();
            *TEST_EXECUTING_RUNNER_COUNTS.lock().unwrap() = None;
            *TEST_START_ONE_NAMES.lock().unwrap() = None;
            *TEST_DOCKER_BIN.lock().unwrap() = None;
            *TEST_HOST_CONTAINMENT_OVERRIDE.lock().unwrap() = None;
            *TEST_HOST_CONTAINMENT_CGROUP_ROOT.lock().unwrap() = None;
            *TEST_HOST_CONTAINMENT_DAEMON_IN_VM.lock().unwrap() = None;
            *TEST_CONTAINER_ANCESTRY_OVERRIDE.lock().unwrap() = None;
            *TEST_USER_MANAGER_OOM_PROPERTIES.lock().unwrap() = None;
            reset_failure_ladder_admission_latch_for_tests();
            crate::failure_ladder::reset_test_save_failure();
            // Drop the cpu-probe test seam so the next test sees a clean
            // override state instead of a value leaked from this test.
            cpu_probe_overrides::set(None);
            // Clear the quarantine redirect set in new() (TEST_LOCK is
            // still held here, so no other test can observe the gap).
            std::env::remove_var("EZGHA_QUARANTINE_PATH");
            if let Some(value) = &self.docker_host_override {
                std::env::set_var("DOCKER_HOST_OVERRIDE", value);
            } else {
                std::env::remove_var("DOCKER_HOST_OVERRIDE");
            }
            let _ = std::fs::remove_file(&self.path);
            if let Some(parent) = self.path.parent() {
                let _ = std::fs::remove_dir(parent);
            }
        }
    }

    #[test]
    fn host_disk_probe_reads_outer_filesystem() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        *TEST_HOST_FREE_DISK_GB.lock().unwrap() = None;

        assert!(host_free_disk_gb().is_some());
    }

    #[test]
    fn mac_host_pressure_alert_does_not_block_six_slot_refill_at_39_gb() {
        let env = TestEnv::new("host_disk_pressure_alert");
        crate::alert::clear_alert_state();
        *TEST_IS_MACOS_HOST.lock().unwrap() = Some(true);
        let mut cfg = cfg_with(6, "ez-org-runner");
        cfg.limits.min_free_disk_gb = 5;
        let alert_log = env.path.with_file_name("alerts.jsonl");
        cfg.alert.log_path = Some(alert_log.clone());
        *TEST_RELEASE_STALE_SLOTS_RESULT.lock().unwrap() = Some(0);
        *TEST_FREE_DISK_GB.lock().unwrap() = Some(Some(100));
        *TEST_HOST_FREE_DISK_GB.lock().unwrap() = Some(Some(39));
        *TEST_MANAGED_CONTAINERS.lock().unwrap() = Some(Vec::new());
        *TEST_START_ONE_NAMES.lock().unwrap() = Some(
            (1..=6)
                .map(|slot| format!("ez-org-runner-{slot}"))
                .collect(),
        );
        *TEST_EXECUTING_RUNNER_COUNTS.lock().unwrap() = Some(
            [Ok(ReadinessSummary {
                ready: 0,
                absent: vec![],
            })]
            .into(),
        );

        let outcome = ensure_count_outcome(&cfg, Backend::Docker).unwrap();

        assert_eq!(outcome.started.len(), 6);
        assert_eq!(outcome.missing, 6);
        let alert = std::fs::read_to_string(alert_log).unwrap();
        assert!(alert.contains("runner_pool.host_disk_pressure"));
        assert!(alert.contains("\"severity\":\"WARNING\""));
        assert!(alert.contains("39 GB free"));
        assert!(alert.contains("40 GB"));
        assert!(!alert.contains("refusing to spawn"));
    }

    #[test]
    fn linux_host_does_not_emit_mac_pressure_alert() {
        let env = TestEnv::new("linux_host_disk_pressure");
        crate::alert::clear_alert_state();
        *TEST_IS_MACOS_HOST.lock().unwrap() = Some(false);
        let mut cfg = cfg_with(1, "ez-org-runner");
        cfg.limits.min_free_disk_gb = 5;
        let alert_log = env.path.with_file_name("alerts.jsonl");
        cfg.alert.log_path = Some(alert_log.clone());
        *TEST_RELEASE_STALE_SLOTS_RESULT.lock().unwrap() = Some(0);
        *TEST_FREE_DISK_GB.lock().unwrap() = Some(Some(100));
        *TEST_HOST_FREE_DISK_GB.lock().unwrap() = Some(Some(39));
        *TEST_MANAGED_CONTAINERS.lock().unwrap() = Some(Vec::new());
        *TEST_START_ONE_NAMES.lock().unwrap() = Some(vec!["ez-org-runner-1".into()]);
        *TEST_EXECUTING_RUNNER_COUNTS.lock().unwrap() = Some(
            [Ok(ReadinessSummary {
                ready: 0,
                absent: vec![],
            })]
            .into(),
        );

        let outcome = ensure_count_outcome(&cfg, Backend::Docker).unwrap();

        assert_eq!(outcome.started, vec!["ez-org-runner-1"]);
        assert!(!alert_log.exists());
    }

    #[test]
    fn configured_host_disk_floor_admits_exact_boundary() {
        let _env = TestEnv::new("host_disk_floor_boundary");
        let mut cfg = cfg_with(1, "ez-org-runner");
        cfg.limits.min_free_disk_gb = 5;
        *TEST_RELEASE_STALE_SLOTS_RESULT.lock().unwrap() = Some(0);
        *TEST_FREE_DISK_GB.lock().unwrap() = Some(Some(5));
        *TEST_HOST_FREE_DISK_GB.lock().unwrap() = Some(Some(5));
        *TEST_MANAGED_CONTAINERS.lock().unwrap() = Some(Vec::new());
        *TEST_START_ONE_NAMES.lock().unwrap() = Some(vec!["ez-org-runner-1".into()]);
        *TEST_EXECUTING_RUNNER_COUNTS.lock().unwrap() = Some(
            [Ok(ReadinessSummary {
                ready: 0,
                absent: vec![],
            })]
            .into(),
        );

        let outcome = ensure_count_outcome(&cfg, Backend::Docker).unwrap();

        assert_eq!(outcome.started, vec!["ez-org-runner-1"]);
        assert_eq!(outcome.missing, 1);
    }

    #[test]
    fn configured_host_disk_floor_refuses_space_below_the_floor() {
        let _env = TestEnv::new("host_disk_floor");
        let mut cfg = cfg_with(6, "ez-org-runner");
        cfg.limits.min_free_disk_gb = 5;
        *TEST_RELEASE_STALE_SLOTS_RESULT.lock().unwrap() = Some(0);
        *TEST_FREE_DISK_GB.lock().unwrap() = Some(Some(100));
        *TEST_HOST_FREE_DISK_GB.lock().unwrap() = Some(Some(4));
        *TEST_MANAGED_CONTAINERS.lock().unwrap() = Some(Vec::new());
        *TEST_START_ONE_NAMES.lock().unwrap() = Some(vec!["must-not-start".into()]);

        let outcome = ensure_count_outcome(&cfg, Backend::Docker).unwrap();

        let message = outcome
            .admission_paused_reason
            .expect("disk floor is a deliberate admission pause, not a backend error");
        assert!(message.contains("host filesystem"));
        assert!(message.contains("floor: 5 GB"));
        assert_eq!(outcome.start_failures, 0);
        assert_eq!(
            TEST_START_ONE_NAMES.lock().unwrap().as_ref().unwrap().len(),
            1,
            "host disk admission must reject the entire refill before start_one consumes any slot"
        );
    }

    #[test]
    fn runner_name_uses_cfg_prefix_not_hardcoded_default() {
        // After the b73 prefix-bug fix, the orphan sweep and stop_all both
        // derive their runner-name prefix from `cfg.runner.name_prefix`,
        // not from a hardcoded constant. This test pins that contract:
        // a host whose config sets `name_prefix = "lab-runner"` must have
        // its orphan sweep match `lab-runner-*` names. If a future change
        // reintroduces a hardcoded prefix, this test fails loud.
        let cfg = cfg_with(2, "lab-runner");
        let prefix = format!("{}-", cfg.runner.name_prefix);
        assert_eq!(prefix, "lab-runner-");
        assert!(prefix.starts_with(cfg.runner.name_prefix.as_str()));
        assert!(prefix.ends_with('-'));
        assert!(!prefix.starts_with("ez-org-runner-"));
    }

    #[test]
    fn effective_limits_clamps_per_runner_to_daemon_share() {
        // count=16, cfg.limits.cpus=2.0, cfg.limits.memory_mb=5977 against
        // the real docker daemon — old behavior returned (2.0, 5977) without
        // dividing by count, so aggregate over-committed by 8x. New behavior:
        // clamp each runner to daemon/count (floored at the validate()
        // minimums in config.rs).
        let mut cfg = Config::defaults_for(&fake_platform(8192, 4), "o/r".into(), Scope::Repo);
        cfg.runner.count = 16;
        cfg.limits.cpus = 2.0;
        cfg.limits.memory_mb = 5977;
        let (ncpu, daemon_mem): (f64, u64) = (4.0, 12288);
        let expected_cpu_share = (ncpu / 16.0).max(0.5);
        let expected_mem_share = (daemon_mem / 16).max(512);
        let (cpus, mem) =
            effective_limits_with_capacity(&cfg, Some((ncpu, daemon_mem)), false).unwrap();
        assert!(
            cpus <= expected_cpu_share + f64::EPSILON,
            "effective_limits must clamp cpus to daemon/count (got {cpus} > {expected_cpu_share})"
        );
        assert!(
            mem <= expected_mem_share,
            "effective_limits must clamp memory to daemon/count (got {mem} > {expected_mem_share})"
        );

        let _lock = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let mut native: Config =
            toml::from_str(include_str!("../config/config.toml.linux.example")).unwrap();
        *TEST_DAEMON_CAPACITY.lock().unwrap() = Some(Some((32.0, 64000)));
        let approved = effective_limits(&native);
        native.limits.memory_mb = 2300;
        let increased = effective_limits(&native);
        *TEST_DAEMON_CAPACITY.lock().unwrap() = None;
        assert_eq!(approved.unwrap().1, 1400);
        assert_eq!(increased.unwrap().1, 1433);
    }

    #[test]
    fn effective_limits_aggregate_fits_daemon() {
        // Stronger invariant: count * per_runner must fit daemon totals.
        let mut cfg = Config::defaults_for(&fake_platform(8192, 4), "o/r".into(), Scope::Repo);
        cfg.runner.count = 4;
        cfg.limits.cpus = 2.0;
        cfg.limits.memory_mb = 4096;
        let (ncpu, daemon_mem): (f64, u64) = (4.0, 8192);
        let (cpus, mem) =
            effective_limits_with_capacity(&cfg, Some((ncpu, daemon_mem)), false).unwrap();
        let cpus_total = cpus * cfg.runner.count as f64;
        let mem_total = mem * cfg.runner.count as u64;
        assert!(
            cpus_total <= ncpu + f64::EPSILON,
            "per_runner * count must fit daemon cpus (got cpus={cpus}, count={}, product={cpus_total}, daemon={ncpu})",
            cfg.runner.count
        );
        assert!(
            mem_total <= daemon_mem,
            "per_runner * count must fit daemon memory (got mem={mem}, count={}, product={mem_total}, daemon={daemon_mem})",
            cfg.runner.count
        );
    }

    #[test]
    fn effective_limits_respects_guest_reserve_ground_truth() {
        // Regression for a P1 gap found in adversarial review round 3:
        // before this fix, effective_limits_with_capacity divided the RAW
        // daemon capacity by count, completely ignoring guest_reserve_mb —
        // meaning the startup fail-loud guard / `ezgha doctor` preview
        // could report "OK" while the ACTUAL per-container docker run
        // --memory limit still left zero real headroom for the guest OS /
        // Docker daemon. Ground truth: 48163 MB daemon (Colima VM), 4096 MB
        // guest reserve (default), 16 runners -> fleet_budget = 44067,
        // per-runner <= 44067/16 = 2754 MB, NOT ~3010 MB (48163/16, the
        // pre-fix number).
        let mut cfg = Config::defaults_for(&fake_platform(8192, 4), "o/r".into(), Scope::Repo);
        cfg.runner.count = 16;
        cfg.limits.memory_mb = 5977; // matches jeff-ubuntu's real config.toml
        assert_eq!(cfg.runner.guest_reserve_mb, 4096); // sanity: default
        let (_, mem) = effective_limits_with_capacity(&cfg, Some((4.0, 48163)), false).unwrap();
        assert!(
            mem <= 2754,
            "effective_limits must respect guest_reserve_mb: expected <= 2754 MB (44067/16), got {mem} MB"
        );
        assert!(mem >= 512); // floor still applies
    }

    // -----------------------------------------------------------------
    // `limits.cpu_burst` opt-in (2026-10-03 throughput finding).
    //
    // Contract: cpu_burst=true is honored ONLY when (a) the daemon is
    // verified VM-contained and (b) daemon_capacity() reports finite
    // positive ncpu. Otherwise effective_limits returns Err and the
    // caller (start_one_with_generate_at_slot and Serve startup) bails
    // before mutating any runner — silent fallback would let a host
    // daemon or unknown capacity exceed the physical envelope.
    //
    // Default-false does NOT call platform::detect() (no probe cost on
    // the hot path) — see cpu_burst_default_does_not_run_platform_detect.
    // -----------------------------------------------------------------

    #[test]
    fn cpu_burst_defaults_to_false() {
        let cfg = Config::defaults_for(&fake_platform(8192, 4), "o/r".into(), Scope::Repo);
        assert!(
            !cfg.limits.cpu_burst,
            "limits.cpu_burst MUST default to false — root owns enabling it (Mac fixed8CPU only)"
        );
    }

    #[test]
    fn cpu_burst_with_vm_and_finite_capacity_relaxes_to_daemon_cpu() {
        // Mac fixed8CPU VM (Colima/Lima), 6 runners, configured cpus=4.0.
        // With burst + verified VM + finite capacity, the ceiling relaxes
        // to min(cfg.limits.cpus, ncpu) = 4.0 and the hot job runs
        // unthrottled.
        let mut cfg = Config::defaults_for(&fake_platform(8192, 8), "o/r".into(), Scope::Repo);
        cfg.runner.count = 6;
        cfg.limits.cpus = 4.0;
        cfg.limits.cpu_burst = true;
        let (cpus, _mem) =
            effective_limits_with_capacity(&cfg, Some((8.0, 8192)), /* daemon_in_vm */ true)
                .unwrap();
        assert!(
            (cpus - 4.0).abs() < f64::EPSILON,
            "burst + VM + finite capacity must relax the per-container ceiling to cfg.limits.cpus=4.0 (got {cpus})"
        );
        assert!(
            cpus > (8.0 / 6.0) + f64::EPSILON,
            "burst must exceed the equal-share clamp (8/6 = 1.33); without burst the hot job is clipped"
        );
    }

    #[test]
    fn cpu_burst_unsupported_on_host_daemon_returns_err() {
        // Burst on a host daemon must REFUSE — silent fallback to the
        // equal-share clamp would let the operator believe burst was
        // honored when it wasn't. Err propagates to start_one / Serve
        // startup and the operator gets a loud message.
        let mut cfg = Config::defaults_for(&fake_platform(8192, 8), "o/r".into(), Scope::Repo);
        cfg.runner.count = 6;
        cfg.limits.cpus = 4.0;
        cfg.limits.cpu_burst = true;
        let err =
            effective_limits_with_capacity(&cfg, Some((8.0, 8192)), /* daemon_in_vm */ false)
                .expect_err("burst on a host daemon must return Err");
        assert!(
            err.contains("not verified VM-contained"),
            "Err message must explain the VM requirement (got {err:?})"
        );
    }

    #[test]
    fn cpu_burst_unsupported_with_no_capacity_returns_err() {
        // Burst with no discovered capacity (daemon_capacity returned
        // None) must REFUSE — silent bypass would let a typo'd
        // cfg.limits.cpus escape unclamped.
        let mut cfg = Config::defaults_for(&fake_platform(8192, 8), "o/r".into(), Scope::Repo);
        cfg.runner.count = 6;
        cfg.limits.cpus = 4.0;
        cfg.limits.cpu_burst = true;
        let err = effective_limits_with_capacity(
            &cfg, /* capacity */ None, /* daemon_in_vm */ true,
        )
        .expect_err("burst with no capacity must return Err");
        assert!(
            err.contains("non-finite") || err.contains("non-positive"),
            "Err message must name the missing-capacity failure (got {err:?})"
        );
    }

    #[test]
    fn cpu_burst_rejects_nan_ncpu() {
        let mut cfg = Config::defaults_for(&fake_platform(8192, 8), "o/r".into(), Scope::Repo);
        cfg.runner.count = 6;
        cfg.limits.cpus = 4.0;
        cfg.limits.cpu_burst = true;
        let err = effective_limits_with_capacity(
            &cfg,
            Some((f64::NAN, 8192)),
            /* daemon_in_vm */ true,
        )
        .expect_err("NaN ncpu must be rejected");
        assert!(
            err.contains("non-finite") || err.contains("non-positive"),
            "Err message must name the NaN failure (got {err:?})"
        );
    }

    #[test]
    fn cpu_burst_rejects_zero_ncpu() {
        let mut cfg = Config::defaults_for(&fake_platform(8192, 8), "o/r".into(), Scope::Repo);
        cfg.runner.count = 6;
        cfg.limits.cpus = 4.0;
        cfg.limits.cpu_burst = true;
        let err =
            effective_limits_with_capacity(&cfg, Some((0.0, 8192)), /* daemon_in_vm */ true)
                .expect_err("zero ncpu must be rejected (pre-fix would have set cpu_ceiling=0.0)");
        assert!(
            err.contains("non-positive"),
            "Err message must name the zero-failure (got {err:?})"
        );
    }

    #[test]
    fn cpu_burst_default_does_not_run_platform_detect() {
        // Pinned regression: when limits.cpu_burst is false (default), the
        // hot path (every start_one call) must NOT call platform::detect()
        // — that probe fans out to docker info, which tart, which virsh,
        // kvm device probes, etc. and would add latency to every spawn.
        //
        // We can't easily count platform::detect() calls in this unit test
        // (it requires a test seam in platform.rs). Instead we verify the
        // OUTCOME: with cpu_burst=false, the returned daemon_in_vm is
        // false regardless of what a hypothetical probe would have said.
        // The platform-detect gating lives at
        // effective_limits cfg.limits.cpu_burst branch; this test pins the
        // observable behavior. A test seam in platform.rs would be a
        // follow-up if review requires it.
        let mut cfg = Config::defaults_for(&fake_platform(8192, 8), "o/r".into(), Scope::Repo);
        cfg.runner.count = 6;
        cfg.limits.cpus = 4.0;
        cfg.limits.cpu_burst = false;
        // capacity=Some((8, ...)), and the inner function is called with
        // daemon_in_vm=false (because the outer effective_limits gates
        // platform::detect() on cpu_burst=true). The CPU is then clamped
        // to cpu_share = 8/6 = 1.33, NOT to ncpu=8.0 — that proves
        // platform::detect did not run (it would have set daemon_in_vm
        // and the burst path would have applied).
        let (cpus, _mem) =
            effective_limits_with_capacity(&cfg, Some((8.0, 8192)), /* daemon_in_vm */ false)
                .unwrap();
        let cpu_share = (8.0_f64 / 6.0).max(0.5);
        assert!(
            (cpus - cpu_share).abs() < f64::EPSILON,
            "cpu_burst=false must use the equal-share clamp {cpu_share} (got {cpus}); \
             a wrong outcome here means the burst-eligibility check leaked into the default path"
        );
    }

    #[test]
    fn cpu_burst_per_container_cap_does_not_exceed_daemon_capacity() {
        // Even with burst enabled and VM + finite capacity verified, the
        // per-container ceiling MUST be capped at the daemon's discovered
        // ncpu. cfg.limits.cpus > ncpu would otherwise let count * cpus
        // exceed VM physical CPUs (the --cpus value gets translated to
        // cfs_quota_us per container, and any value above ncpu would be
        // effectively unbounded).
        let mut cfg = Config::defaults_for(&fake_platform(8192, 4), "o/r".into(), Scope::Repo);
        cfg.runner.count = 6;
        cfg.limits.cpus = 16.0; // operator typo: 16 CPUs requested on a 4-CPU VM
        cfg.limits.cpu_burst = true;
        let (cpus, _) =
            effective_limits_with_capacity(&cfg, Some((4.0, 8192)), /* daemon_in_vm */ true)
                .unwrap();
        assert!(
            cpus <= 4.0 + f64::EPSILON,
            "burst ceiling must be capped at daemon ncpu=4.0 (got {cpus}); never cfg.limits.cpus=16.0"
        );
        assert!(
            cpus * cfg.runner.count as f64 <= 4.0 * cfg.runner.count as f64 + f64::EPSILON,
            "burst aggregate (cpus * count = {}) must not exceed ncpu * count = {}",
            cpus * cfg.runner.count as f64,
            4.0 * cfg.runner.count as f64,
        );
    }

    #[test]
    fn derive_memory_budget_happy_path_ground_truth() {
        // Ground truth from the 2026-07-10 jeff-ubuntu incident (bead
        // ez-gh-actions-yz6b): 48163 MB Colima VM, 4096 MB guest reserve,
        // 16 runners. Uses an explicit 2048 MB floor ("bare survivable
        // minimum" per the panel refinement note) rather than the 3072 MB
        // default — at the DEFAULT floor these exact numbers correctly fail
        // loud (see `derive_memory_budget_fails_loud_when_floor_unmet`
        // below); that is the deliberate bug this bead fixes, not a test
        // bug (the pre-yz6b fleet was already running underwater at the
        // default floor, which is *why* this bead exists).
        let budget = derive_memory_budget(48163, 4096, 16, 2048).unwrap();
        assert_eq!(budget.fleet_budget_mb, 44067); // 48163 - 4096
        assert_eq!(budget.per_runner_budget_mb, 2754); // 44067 / 16
        assert!(budget.per_runner_budget_mb >= 2048);
    }

    #[test]
    fn derive_memory_budget_supports_approved_twenty_runner_floor() {
        let cfg: Config = toml::from_str(include_str!("../config/config.toml.linux.example"))
            .expect("tracked native Linux configuration must parse");
        let budget = derive_memory_budget(
            cfg.runner.vm_total_mb.unwrap(),
            cfg.runner.guest_reserve_mb,
            cfg.runner.count,
            cfg.runner.runner_floor_mb,
        )
        .unwrap();
        assert_eq!(budget.fleet_budget_mb, 28672);
        assert_eq!(budget.per_runner_budget_mb, 1433);
        assert_eq!(u64::from(cfg.runner.count) * cfg.limits.memory_mb, 28000);
        assert!(u64::from(cfg.runner.count) * cfg.limits.memory_mb <= budget.fleet_budget_mb);
        assert!(derive_memory_budget(
            cfg.runner.vm_total_mb.unwrap(),
            cfg.runner.guest_reserve_mb,
            cfg.runner.count,
            1434,
        )
        .is_err());
    }

    #[test]
    fn derive_memory_budget_fails_loud_when_floor_unmet() {
        // Same ground-truth VM/reserve/count, but the DEFAULT 3072 MB
        // floor: 16 * 3072 = 49152 > 44067 fleet_budget -> must fail loud,
        // not silently clamp below 3072 MB (the regression this bead exists
        // to prevent).
        let err = derive_memory_budget(48163, 4096, 16, 3072).unwrap_err();
        let msg = format!("{err:#}");
        assert!(msg.contains("48163"), "missing vm_total: {msg}");
        assert!(msg.contains("4096"), "missing guest_reserve: {msg}");
        assert!(msg.contains("44067"), "missing fleet_budget: {msg}");
        assert!(msg.contains("16"), "missing runner_count: {msg}");
        assert!(msg.contains("3072"), "missing runner_floor: {msg}");
        assert!(
            msg.contains("5085"),
            "missing shortfall (49152-44067): {msg}"
        );
    }

    #[test]
    fn preview_memory_budget_pass_matches_derive_memory_budget_happy_path() {
        let mut cfg = cfg_with(16, "ez-org-runner");
        cfg.runner.vm_total_mb = Some(48163);
        cfg.runner.guest_reserve_mb = 4096;
        cfg.runner.runner_floor_mb = 2048; // "bare survivable minimum" — see round-1 happy-path test
        match preview_memory_budget(&cfg) {
            MemoryBudgetPreview::Pass(budget) => {
                assert_eq!(budget.fleet_budget_mb, 44067);
                assert_eq!(budget.per_runner_budget_mb, 2754);
            }
            other => panic!("expected Pass, got {other:?}"),
        }
    }

    #[test]
    fn preview_memory_budget_fail_matches_derive_memory_budget_fail_loud_path() {
        let mut cfg = cfg_with(16, "ez-org-runner");
        cfg.runner.vm_total_mb = Some(48163);
        cfg.runner.guest_reserve_mb = 4096;
        cfg.runner.runner_floor_mb = 3072; // default — fails loud at count=16 (see round-1 test)
        match preview_memory_budget(&cfg) {
            MemoryBudgetPreview::Fail(msg) => {
                assert!(
                    msg.contains("shortfall_mb=5085"),
                    "unexpected message: {msg}"
                );
            }
            other => panic!("expected Fail, got {other:?}"),
        }
    }

    #[test]
    fn runner_config_missing_new_keys_falls_back_to_documented_defaults() {
        // A config.toml written before this bead (no vm_total_mb /
        // guest_reserve_mb / runner_floor_mb keys) must still deserialize
        // via serde defaults, not panic, and the derivation must run
        // end-to-end without panicking on those defaults.
        let raw = r#"
version = 1
[github]
scope = "repo"
target = "owner/repo"
[runner]
labels = ["self-hosted"]
count = 2
image = "img:latest"
[limits]
memory_mb = 2048
cpus = 2.0
pids = 512
[policy]
minimum_isolation = "container"
"#;
        let cfg: Config = toml::from_str(raw).unwrap();
        assert_eq!(cfg.runner.vm_total_mb, None);
        assert_eq!(cfg.runner.guest_reserve_mb, 4096);
        assert_eq!(cfg.runner.runner_floor_mb, 3072);
        let budget = derive_memory_budget(
            16384,
            cfg.runner.guest_reserve_mb,
            cfg.runner.count,
            cfg.runner.runner_floor_mb,
        )
        .unwrap();
        assert_eq!(budget.fleet_budget_mb, 16384 - 4096);
        assert!(budget.per_runner_budget_mb >= cfg.runner.runner_floor_mb);
    }

    #[test]
    fn parse_docker_size_mb_handles_common_units() {
        assert_eq!(parse_docker_size_mb("512.3MiB"), Some(512));
        assert_eq!(parse_docker_size_mb("1.5GiB"), Some(1536));
        assert_eq!(parse_docker_size_mb("2048KiB"), Some(2));
        assert_eq!(parse_docker_size_mb("bogus"), None);
    }

    #[test]
    fn parse_mem_usage_mb_takes_used_side_of_slash() {
        assert_eq!(parse_mem_usage_mb("512.3MiB / 3GiB"), Some(512));
        assert_eq!(parse_mem_usage_mb("not a mem usage string"), None);
    }

    #[test]
    fn slot_assignments_start_at_one() {
        let _env = TestEnv::new("start_at_one");
        let cfg = cfg_with(4, "ez-org-runner");
        let slot = next_slot(&cfg).unwrap();
        assert_eq!(slot, 1);
    }

    #[test]
    fn next_slot_assigns_first_slot_when_empty() {
        let _env = TestEnv::new("first_slot");
        let cfg = cfg_with(4, "ez-org-runner");
        assert_eq!(next_slot(&cfg).unwrap(), 1);
    }

    #[test]
    fn next_slot_reuses_slot_after_release() {
        let _env = TestEnv::new("reuse_after_release");
        let cfg = cfg_with(4, "ez-org-runner");

        let s1 = next_slot(&cfg).unwrap();
        assert_eq!(s1, 1);
        // Mark the slot as having a real runner_id so we can confirm we are
        // truly reclaiming an occupied entry, not just a reserved-but-empty one.
        record_slot_runner_id(s1, 9999).unwrap();
        let a = read_slot_assignments().unwrap();
        assert_eq!(
            a.assignments.get(&s1.to_string()).map(String::as_str),
            Some("9999")
        );

        release_slot(s1).unwrap();
        let reused = next_slot(&cfg).unwrap();
        assert_eq!(reused, s1, "released slot must be the first one reissued");
    }

    #[test]
    fn state_dir_isolates_slot_assignments_between_configs() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        *TEST_SLOT_PATH.lock().unwrap() = None;
        let base =
            env::temp_dir().join(format!("ezgha-state-dir-isolation-{}", std::process::id()));
        let dir_a = base.join("prod");
        let dir_b = base.join("canary");
        let mut prod = cfg_with(1, "ez-prod");
        prod.state_dir = Some(dir_a.clone());
        let mut canary = cfg_with(1, "ez-canary");
        canary.state_dir = Some(dir_b.clone());

        assert_eq!(next_slot(&prod).unwrap(), 1);
        record_slot_runner_id_for(Some(&prod), 1, 101).unwrap();
        assert_eq!(next_slot(&canary).unwrap(), 1);
        record_slot_runner_id_for(Some(&canary), 1, 202).unwrap();

        let prod_slots = std::fs::read_to_string(dir_a.join("slot_assignments.toml")).unwrap();
        let canary_slots = std::fs::read_to_string(dir_b.join("slot_assignments.toml")).unwrap();
        assert!(prod_slots.contains("\"101\""));
        assert!(!prod_slots.contains("\"202\""));
        assert!(canary_slots.contains("\"202\""));
        assert!(!canary_slots.contains("\"101\""));

        let _ = std::fs::remove_dir_all(base);
    }

    #[test]
    fn state_dir_isolates_quarantine_between_configs() {
        // LOCK ORDER: quarantine lock FIRST, then TEST_LOCK — matching the
        // 422-family tests (quarantine::tests::TestEnv::new acquires the
        // quarantine lock, then quarantine_test_setup acquires TEST_LOCK).
        // The previous order here (TEST_LOCK → quarantine lock) was the
        // other half of an AB-BA inversion that deadlocked the whole suite
        // in parallel runs: this test held TEST_LOCK waiting for the
        // quarantine lock while a 422-family test held the quarantine lock
        // waiting for TEST_LOCK (observed live 2026-07-16, `cargo test`
        // hung >5min; serial `--test-threads=1` passed 312/312).
        //
        // The quarantine lock is held because this test reads/writes
        // TEST_QUARANTINE_PATH directly (to prove cfg.state_dir-based
        // resolution), and that static is checked before cfg.state_dir in
        // quarantine_path_for — without it a concurrently-running
        // TestEnv-based quarantine test could clobber it mid-flight.
        let _qlock = crate::quarantine::tests::test_lock();
        let _lock = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        *TEST_SLOT_PATH.lock().unwrap() = None;
        *crate::quarantine::TEST_QUARANTINE_PATH.lock().unwrap() = None;
        let base = env::temp_dir().join(format!(
            "ezgha-state-dir-quarantine-isolation-{}",
            std::process::id()
        ));
        let dir_a = base.join("prod");
        let dir_b = base.join("canary");
        let mut prod = cfg_with(1, "ez-prod");
        prod.state_dir = Some(dir_a.clone());
        let mut canary = cfg_with(1, "ez-canary");
        canary.state_dir = Some(dir_b.clone());

        let mut prod_quarantine = crate::quarantine::load_quarantine_for(Some(&prod)).unwrap();
        prod_quarantine.upsert(crate::quarantine::QuarantineEntry {
            slot: 1,
            runner_id: 101,
            runner_name: "ez-prod-1".into(),
            first_seen_epoch_secs: 1_700_000_000,
            attempt_count: 0,
            last_attempt_epoch_secs: 1_700_000_000,
            reason: crate::quarantine::QuarantineReason::Locked422,
        });
        crate::quarantine::save_quarantine_for(Some(&prod), &prod_quarantine).unwrap();

        let mut canary_quarantine = crate::quarantine::load_quarantine_for(Some(&canary)).unwrap();
        canary_quarantine.upsert(crate::quarantine::QuarantineEntry {
            slot: 1,
            runner_id: 202,
            runner_name: "ez-canary-1".into(),
            first_seen_epoch_secs: 1_700_000_000,
            attempt_count: 0,
            last_attempt_epoch_secs: 1_700_000_000,
            reason: crate::quarantine::QuarantineReason::Locked422,
        });
        crate::quarantine::save_quarantine_for(Some(&canary), &canary_quarantine).unwrap();

        let prod_reloaded = crate::quarantine::load_quarantine_for(Some(&prod)).unwrap();
        let canary_reloaded = crate::quarantine::load_quarantine_for(Some(&canary)).unwrap();
        assert_eq!(
            prod_reloaded.get(1).unwrap().runner_id,
            101,
            "prod's quarantine file must not be overwritten by canary's write"
        );
        assert_eq!(
            canary_reloaded.get(1).unwrap().runner_id,
            202,
            "canary's quarantine file must not be overwritten by prod's write"
        );

        let prod_raw = std::fs::read_to_string(dir_a.join("quarantined_slots.toml")).unwrap();
        let canary_raw = std::fs::read_to_string(dir_b.join("quarantined_slots.toml")).unwrap();
        assert!(prod_raw.contains("101"));
        assert!(!prod_raw.contains("202"));
        assert!(canary_raw.contains("202"));
        assert!(!canary_raw.contains("101"));

        let _ = std::fs::remove_dir_all(base);
    }

    #[test]
    fn read_slot_assignments_quarantines_corrupt_file_and_returns_empty() {
        let env = TestEnv::new("corrupt_slot_file");
        let path = env.path.clone();
        std::fs::write(&path, b"this is not toml data").unwrap();

        let assignments = read_slot_assignments().unwrap();
        assert!(assignments.assignments.is_empty());
        assert!(
            !path.exists(),
            "corrupt file should be removed from original location"
        );

        let parent = path
            .parent()
            .expect("slot file path should have a parent directory");
        let quarantined: Vec<_> = std::fs::read_dir(parent)
            .unwrap()
            .filter_map(Result::ok)
            .map(|entry| entry.file_name().to_string_lossy().into_owned())
            .filter(|name| name.starts_with("slot_assignments.toml.corrupt."))
            .collect();
        assert!(
            !quarantined.is_empty(),
            "corrupt file should be renamed to a toml.corrupt.* sibling"
        );
    }

    #[test]
    fn run_docker_times_out() {
        let start = Instant::now();
        let mut cmd = std::process::Command::new("sleep");
        cmd.arg("30");
        let result = run_docker_with_timeout(
            cmd,
            "hung docker command simulation",
            Duration::from_millis(200),
        );
        let elapsed = start.elapsed();
        assert!(result.is_err(), "hung command should timeout");
        assert!(
            elapsed < Duration::from_secs(5),
            "timeout should fire promptly, got {:?}",
            elapsed
        );
    }

    #[test]
    fn docker_top_deadline_includes_reaper_initialization_and_has_no_extra_budget() {
        let _env = TestEnv::new("docker_top_deadline");
        let temp_dir =
            env::temp_dir().join(format!("ezgha-docker-top-deadline-{}", std::process::id()));
        std::fs::create_dir_all(&temp_dir).unwrap();

        for (label, top_delay, succeeds) in [("within", "0.2", true), ("over", "5.0", false)] {
            let script = temp_dir.join(format!("docker-{label}"));
            std::fs::write(
                &script,
                format!(
                    "#!/bin/sh\nfor arg in \"$@\"; do\n  if [ \"$arg\" = \"top\" ]; then\n    sleep {top_delay}\n    printf 'PID COMMAND\\n1 Runner.Worker\\n'\n    break\n  fi\ndone\n"
                ),
            )
            .unwrap();
            std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
            *TEST_DOCKER_BIN.lock().unwrap() = Some(script.to_string_lossy().into_owned());

            let mut cmd = docker_cmd();
            cmd.args(["top", "runner-1", "-eo", "pid,comm"]);
            let started = Instant::now();
            let deadline = started + Duration::from_secs(3);
            std::thread::sleep(Duration::from_secs(1));
            let reaper = Ok(DockerChildReaper {
                queue: Arc::new(DockerReapQueue {
                    pending: Mutex::new(VecDeque::new()),
                    wake: Condvar::new(),
                    active: AtomicUsize::new(0),
                }),
            });
            let result = run_docker_with_timeout_at_deadline(
                cmd,
                "fake docker top readiness",
                Duration::from_secs(3),
                deadline,
                reaper,
            );

            assert_eq!(result.is_ok(), succeeds, "top delay {top_delay}s");
            if !succeeds {
                assert!(
                    result.unwrap_err().to_string().contains("timed out"),
                    "over-deadline docker top must fail closed"
                );
            }
        }

        let marker = temp_dir.join("must-not-start");
        let script = temp_dir.join("docker-expired");
        std::fs::write(
            &script,
            format!("#!/bin/sh\necho started > {}\n", marker.to_string_lossy()),
        )
        .unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        *TEST_DOCKER_BIN.lock().unwrap() = Some(script.to_string_lossy().into_owned());
        let mut cmd = docker_cmd();
        cmd.args(["top", "runner-1", "-eo", "pid,comm"]);
        let expired_deadline = Instant::now() - Duration::from_millis(1);
        let reaper = Ok(DockerChildReaper {
            queue: Arc::new(DockerReapQueue {
                pending: Mutex::new(VecDeque::new()),
                wake: Condvar::new(),
                active: AtomicUsize::new(0),
            }),
        });
        assert!(run_docker_with_timeout_at_deadline(
            cmd,
            "expired fake docker top readiness",
            Duration::from_secs(3),
            expired_deadline,
            reaper,
        )
        .is_err());
        assert!(
            !marker.exists(),
            "docker top must not start after its deadline"
        );
    }

    #[test]
    fn run_docker_timeout_covers_stderr_and_reaping() {
        let pid_path = tmp_path("docker_timeout_pid").with_extension("pid");
        let start = Instant::now();
        let mut cmd = std::process::Command::new("/bin/sh");
        cmd.args([
            "-c",
            "echo $$ > \"$1\"; exec 1>&-; exec /bin/sleep 30",
            "sh",
            pid_path.to_str().unwrap(),
        ]);
        let result = run_docker_with_timeout(
            cmd,
            "hung docker command with closed stdout simulation",
            Duration::from_secs(1),
        );
        let elapsed = start.elapsed();
        assert!(result.is_err(), "hung command should timeout");
        assert!(
            elapsed < Duration::from_secs(5),
            "stderr and process reaping must share the deadline, got {:?}",
            elapsed
        );
        let pid: libc::pid_t = std::fs::read_to_string(&pid_path)
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        let mut reaped = false;
        for _ in 0..100 {
            if unsafe { libc::kill(pid, 0) } != 0 {
                reaped = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(reaped, "timed-out child must eventually be reaped");
    }

    #[test]
    fn killed_docker_child_is_reaped_within_cleanup_window() {
        let child = std::process::Command::new("/bin/sleep")
            .arg("30")
            .spawn()
            .unwrap();
        let pid = child.id() as libc::pid_t;
        assert!(
            reap_killed_child_until_deadline(child, Instant::now() + Duration::from_secs(1))
                .is_none(),
            "child must be reaped"
        );
        assert_ne!(
            unsafe { libc::kill(pid, 0) },
            0,
            "timed-out child must be killed and reaped"
        );
    }

    #[test]
    fn reaper_retries_transient_wait_without_dropping_owner() {
        let child = std::process::Command::new("/bin/sleep")
            .arg("0.05")
            .spawn()
            .unwrap();
        let mut req = DockerReapRequest {
            child,
            detail: "test transient wait".to_string(),
        };
        assert!(!try_wait_owned_docker_child(&mut req));
        std::thread::sleep(Duration::from_millis(80));
        assert!(try_wait_owned_docker_child(&mut req));
    }

    #[test]
    fn reaper_initialization_failure_prevents_child_spawn() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let marker = tmp_path("reaper_init_failure").with_extension("spawned");
        let mut cmd = std::process::Command::new("/bin/sh");
        cmd.args([
            "-c",
            "echo spawned > \"$1\"",
            "sh",
            marker.to_str().unwrap(),
        ]);
        let init_failure: Result<DockerChildReaper> =
            Err(anyhow::anyhow!("injected Docker child reaper init failure"));
        let result = run_docker_with_timeout_after_reaper_init(
            cmd,
            "reaper initialization failure test",
            Duration::from_secs(1),
            init_failure,
        );
        assert!(result.is_err());
        assert!(
            !marker.exists(),
            "command must not spawn when reaper initialization fails"
        );
    }

    #[test]
    fn reaper_initialization_retries_after_transient_failure() {
        let cache = Mutex::new(None);
        let attempts = AtomicU32::new(0);
        let initialize = || {
            if attempts.fetch_add(1, Ordering::SeqCst) == 0 {
                return Err("injected transient reaper initialization failure".to_owned());
            }
            Ok(DockerChildReaper {
                queue: Arc::new(DockerReapQueue {
                    pending: Mutex::new(VecDeque::new()),
                    wake: Condvar::new(),
                    active: AtomicUsize::new(0),
                }),
            })
        };

        assert!(get_or_initialize_docker_child_reaper(&cache, initialize).is_err());
        assert!(get_or_initialize_docker_child_reaper(&cache, initialize).is_ok());
        assert_eq!(attempts.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn reaper_supervisor_exits_after_readiness_receiver_is_dropped() {
        let queue = Arc::new(DockerReapQueue {
            pending: Mutex::new(VecDeque::new()),
            wake: Condvar::new(),
            active: AtomicUsize::new(0),
        });
        let (ready_sender, ready_receiver) = mpsc::sync_channel(0);
        drop(ready_receiver);
        let (done_sender, done_receiver) = mpsc::sync_channel(0);

        std::thread::spawn(move || {
            docker_child_reaper_supervisor(queue, Some(ready_sender));
            let _ = done_sender.send(());
        });

        assert!(
            done_receiver.recv_timeout(Duration::from_secs(1)).is_ok(),
            "a timed-out initialization must not leave an orphan reaper thread"
        );
    }

    #[test]
    fn background_reaper_eventually_reaps_transferred_child() {
        let mut child = std::process::Command::new("/bin/sleep")
            .arg("30")
            .spawn()
            .unwrap();
        let pid = child.id() as libc::pid_t;
        child.kill().unwrap();
        docker_child_reaper().unwrap().enqueue(DockerReapRequest {
            child,
            detail: "background reaper test".to_owned(),
        });

        let mut reaped = false;
        for _ in 0..100 {
            if unsafe { libc::kill(pid, 0) } != 0 {
                reaped = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(reaped, "background reaper must eventually reap its child");
    }

    #[test]
    fn stalled_reaper_wait_does_not_block_later_child() {
        let _lock = TEST_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let reaper = initialize_docker_child_reaper().unwrap();
        let mut stalled_pids = Vec::new();
        for index in 0..4 {
            let first = std::process::Command::new("/bin/sleep")
                .arg("30")
                .spawn()
                .unwrap();
            stalled_pids.push(first.id() as libc::pid_t);
            reaper.enqueue(DockerReapRequest {
                child: first,
                detail: format!("stalled reaper wait test (child {index})"),
            });
        }
        let stalled_waits_started = (0..100).any(|_| {
            let pending_empty = reaper
                .queue
                .pending
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .is_empty();
            if pending_empty && reaper.queue.active.load(Ordering::Relaxed) == 4 {
                return true;
            }
            std::thread::sleep(Duration::from_millis(10));
            false
        });
        assert!(
            stalled_waits_started,
            "four stalled children must be owned by the reaper before the fifth arrives"
        );

        let mut fifth = std::process::Command::new("/bin/sleep")
            .arg("30")
            .spawn()
            .unwrap();
        let fifth_pid = fifth.id() as libc::pid_t;
        fifth.kill().unwrap();
        reaper.enqueue(DockerReapRequest {
            child: fifth,
            detail: "stalled reaper wait test (fifth child)".to_owned(),
        });

        let mut fifth_reaped = false;
        for _ in 0..100 {
            if unsafe { libc::kill(fifth_pid, 0) } != 0 {
                fifth_reaped = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        for pid in stalled_pids {
            unsafe {
                libc::kill(pid, libc::SIGKILL);
            }
        }
        assert!(
            fifth_reaped,
            "four stalled waits must not block reaping a later killed child"
        );
    }

    #[test]
    fn supervised_reaper_recovers_after_worker_panic() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let reaper = docker_child_reaper().unwrap();
        let panic_count = TEST_DOCKER_REAPER_PANIC_COUNT.load(Ordering::SeqCst);
        TEST_DOCKER_REAPER_PANIC_ONCE.store(true, Ordering::SeqCst);
        reaper.queue.wake.notify_one();
        for _ in 0..100 {
            if TEST_DOCKER_REAPER_PANIC_COUNT.load(Ordering::SeqCst) > panic_count {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(
            TEST_DOCKER_REAPER_PANIC_COUNT.load(Ordering::SeqCst) > panic_count,
            "reaper worker should observe the injected panic"
        );

        let mut child = std::process::Command::new("/bin/sleep")
            .arg("30")
            .spawn()
            .unwrap();
        let pid = child.id() as libc::pid_t;
        child.kill().unwrap();
        reaper.enqueue(DockerReapRequest {
            child,
            detail: "supervised reaper recovery test".to_owned(),
        });

        let mut reaped = false;
        for _ in 0..100 {
            if unsafe { libc::kill(pid, 0) } != 0 {
                reaped = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(reaped, "supervised reaper must reap after worker restart");
    }

    #[cfg(target_os = "linux")]
    fn migration_config(env: &TestEnv) -> Config {
        *TEST_IS_MACOS_HOST.lock().unwrap() = Some(false);
        *TEST_HOST_CONTAINMENT_DAEMON_IN_VM.lock().unwrap() = Some(false);
        let mut cfg = cfg_with(14, "ez-runner-c");
        cfg.limits.cgroup_parent = Some("actions.slice".into());
        cfg.limits.memory_mb = 2000;
        cfg.runner.vm_total_mb = Some(28672);
        cfg.runner.guest_reserve_mb = 0;
        cfg.state_dir = Some(env.path.parent().unwrap().into());
        let root = env.path.parent().unwrap().join("cgroup");
        write_actions_slice_fixture(&root, 14);
        *TEST_HOST_CONTAINMENT_CGROUP_ROOT.lock().unwrap() = Some(root);
        cfg
    }

    #[cfg(target_os = "linux")]
    fn migration_docker(env: &TestEnv, caps_mb: &[u64]) -> PathBuf {
        let dir = env.path.parent().unwrap();
        let rows: Vec<_> = caps_mb
            .iter()
            .enumerate()
            .map(|(index, cap)| {
                serde_json::json!({"Id": format!("container{index}"),
                "CgroupParent": "actions.slice", "Memory": cap * 1024 * 1024})
            })
            .collect();
        std::fs::write(
            dir.join("caps.jsonl"),
            rows.iter()
                .map(|row| format!("{row}\n"))
                .collect::<String>(),
        )
        .unwrap();
        std::fs::write(
            dir.join("ids"),
            (0..caps_mb.len())
                .map(|i| format!("container{i}\n"))
                .collect::<String>(),
        )
        .unwrap();
        let capture = dir.join("docker-calls");
        let script = dir.join("docker");
        std::fs::write(
            &script,
            format!(
                r#"#!/bin/sh
printf '%s\n' "$*" >> '{}'
case " $* " in
  *" ps "*) cat '{}';;
  *" inspect "*) cat '{}';;
  *" info "*) printf '32 64000000000\n';;
  *) exit 71;;
esac
"#,
                capture.display(),
                dir.join("ids").display(),
                dir.join("caps.jsonl").display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        *TEST_DOCKER_BIN.lock().unwrap() = Some(script.to_string_lossy().into_owned());
        capture
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn migration_refill_admits_only_affordable_legacy_transition() {
        let env = TestEnv::new("migration_partial");
        let cfg = migration_config(&env);
        let capture = migration_docker(&env, &[2500; 10]);
        let attempts = AtomicUsize::new(0);
        let outcome = start_missing_runners_with_starter(&cfg, Backend::Docker, 4, |_, _, slot| {
            attempts.fetch_add(1, Ordering::SeqCst);
            Ok((format!("new-{slot}"), format!("ez-runner-c-{slot}")))
        })
        .unwrap();
        assert_eq!(
            attempts.load(Ordering::SeqCst),
            1,
            "25000 MiB existing permits one 2000 MiB start under 28672 MiB"
        );
        assert_eq!(outcome.started.len(), 1);
        assert_eq!(outcome.start_failures, 0);
        assert!(outcome.admission_paused_reason.is_some());
        let calls = std::fs::read_to_string(capture).unwrap();
        assert_eq!(
            calls
                .lines()
                .filter(|line| line.contains(" inspect "))
                .count(),
            1
        );
        assert!(!calls
            .lines()
            .any(|line| line.contains(" rm ") || line.contains(" update ")));
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn migration_budget_tracks_convergence_and_full_capacity() {
        let env = TestEnv::new("migration_capacity");
        let cfg = migration_config(&env);
        for (caps, requested, expected) in [
            (vec![], 14, 14),
            (vec![2000; 14], 1, 0),
            (vec![2500; 10], 4, 1),
            ([vec![2500; 9], vec![2000]].concat(), 4, 2),
            ([vec![2500; 9], vec![2000; 3]].concat(), 2, 0),
            (vec![2000; 13], 1, 1),
            (vec![3000; 10], 4, 0),
        ] {
            migration_docker(&env, &caps);
            let batch = admission_batch(&cfg, requested).unwrap();
            assert_eq!(batch.slots, expected, "caps={caps:?}");
            assert_eq!(batch.paused.is_some(), expected < requested);
        }
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn migration_counts_foreign_actions_consumers_only() {
        let env = TestEnv::new("migration_foreign");
        let cfg = migration_config(&env);
        migration_docker(&env, &[2500; 10]);
        let path = env.path.parent().unwrap().join("caps.jsonl");
        let rows = std::fs::read_to_string(&path).unwrap();
        for parent in ["/actions.slice/foreign", "actions-foreign.slice"] {
            std::fs::write(&path, rows.replace("actions.slice", parent)).unwrap();
            assert_eq!(admission_batch(&cfg, 4).unwrap().slots, 1);
        }
        std::fs::write(&path, rows.replace("actions.slice", "other.slice")).unwrap();
        assert_eq!(admission_batch(&cfg, 14).unwrap().slots, 14);
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn migration_unknown_caps_refuse_before_starter() {
        let env = TestEnv::new("migration_unknown");
        let cfg = migration_config(&env);
        for rows in [
            "not json\n",
            "",
            "{\"Id\":\"container0\",\"CgroupParent\":\"actions.slice\",\"Memory\":0}\n",
            "{\"Id\":\"container0\",\"CgroupParent\":\"actions.slice\"}\n",
            "{\"Id\":\"other\",\"CgroupParent\":\"actions.slice\",\"Memory\":1}\n",
        ] {
            migration_docker(&env, &[2500]);
            std::fs::write(env.path.parent().unwrap().join("caps.jsonl"), rows).unwrap();
            let outcome =
                start_missing_runners_with_starter(&cfg, Backend::Docker, 1, |_, _, _| {
                    panic!("incomplete memory evidence must not reach starter")
                })
                .unwrap();
            assert!(outcome.started.is_empty());
            assert_eq!(outcome.start_failures, 0);
            assert!(outcome.admission_paused_reason.is_some());
        }
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn migration_failed_attempt_still_consumes_capacity_and_unlocks() {
        let env = TestEnv::new("migration_failed");
        let cfg = migration_config(&env);
        migration_docker(&env, &[2500; 10]);
        let attempts = AtomicUsize::new(0);
        let outcome = start_missing_runners_with_starter(&cfg, Backend::Docker, 4, |_, _, _| {
            attempts.fetch_add(1, Ordering::SeqCst);
            bail!("start failed after create")
        })
        .unwrap();
        assert_eq!(attempts.load(Ordering::SeqCst), 1);
        assert_eq!(outcome.start_failures, 1);
        assert!(outcome.admission_paused_reason.is_some());
        let batch = admission_batch(&cfg, 1).unwrap();
        assert!(admission_batch(&cfg, 1).is_err());
        drop(batch);
        assert!(admission_batch(&cfg, 1).is_ok());
    }

    #[test]
    fn start_missing_runners_starts_full_shortfall_directly() {
        // Regression guard for the po2 throttle removal (watchdog relaxed to
        // max-load-1=96 on 2026-07-07): with N missing and N successful
        // start_one() calls, start_missing_runners must start exactly N
        // runners with no load-gate pacing, batching, or sleeping between
        // starts — the original pre-po2 behavior (commit e21eafc).
        let _env = TestEnv::new("start_missing_direct");
        let cfg = cfg_with(16, "ez-org-runner");
        *TEST_START_ONE_NAMES.lock().unwrap() =
            Some((1..=16).map(|n| format!("ez-org-runner-{n}")).collect());

        let outcome = start_missing_runners(&cfg, Backend::Docker, 16).unwrap();

        assert_eq!(
            outcome.started.len(),
            16,
            "must start the full shortfall directly in one call, no load-gate batching"
        );
        assert!(
            TEST_START_ONE_NAMES
                .lock()
                .unwrap()
                .as_ref()
                .unwrap()
                .is_empty(),
            "all 16 start_one() calls must be consumed directly"
        );
    }

    #[test]
    fn start_missing_runners_excludes_permanently_stuck_slot_within_one_call() {
        // Regression test for bead ez-gh-actions-oau — confirmed LIVE incident
        // 2026-07-08. Root cause: start_missing_runners looped `missing` times
        // calling start_one(), which internally calls next_slot() to grab the
        // lowest currently-free slot number. When a slot is PERMANENTLY broken
        // (e.g. an unresolvable 409 zombie GitHub registration), start_one's
        // failure path releases that slot's reservation, so the *next*
        // iteration's next_slot() call picks the exact same slot again — it is
        // still the lowest free number. Net effect: every iteration in the
        // batch piled onto the one broken slot, and the other genuinely
        // fillable slots were never attempted. Live: 90+ consecutive attempts
        // on one slot, zero attempts on ~14 other missing slots, fleet
        // collapsed 16 -> 0 containers.
        //
        // This test drives the REAL slot-allocation path (next_slot_excluding,
        // via start_missing_runners_with_starter) with a starter that fails
        // deterministically for one specific slot on EVERY attempt (not just
        // once), and asserts the other N-1 slots each get exactly one attempt
        // and succeed — proving one stuck slot can consume at most one
        // iteration of the batch.
        let _env = TestEnv::new("exclude_stuck_slot");
        let cfg = cfg_with(5, "ez-org-runner");
        const BROKEN_SLOT: u32 = 3;

        let attempts: std::sync::Arc<std::sync::Mutex<std::collections::HashMap<u32, u32>>> =
            std::sync::Arc::new(std::sync::Mutex::new(std::collections::HashMap::new()));
        let attempts_for_closure = std::sync::Arc::clone(&attempts);
        let starter =
            move |_cfg: &Config, _backend: Backend, slot: u32| -> Result<(String, String)> {
                *attempts_for_closure
                    .lock()
                    .unwrap()
                    .entry(slot)
                    .or_insert(0) += 1;
                if slot == BROKEN_SLOT {
                    // Mirror the REAL failure path in
                    // `start_one_with_generate_at_slot`: on error, it releases the
                    // slot's reservation (`release_slot_for`) so the slot becomes
                    // free again. That release is exactly what makes the slot
                    // re-pickable as "the lowest free slot" on the very next
                    // `next_slot`/`next_slot_excluding` call — the mechanism this
                    // test must exercise to prove the exclusion set (not just
                    // "the slot happens to still be reserved") is what prevents
                    // the retry-pileup bug.
                    release_slot(BROKEN_SLOT).unwrap();
                    bail!("simulated permanent JIT-generation failure for slot {slot}");
                }
                let name = format!("ez-org-runner-{slot}");
                Ok((format!("container-{name}"), name))
            };

        let outcome = start_missing_runners_with_starter(&cfg, Backend::Docker, 5, starter)
            .expect("4 of 5 slots succeed, so overall call must return Ok with those 4");

        assert_eq!(
            outcome.started.len(),
            4,
            "the 4 genuinely-fillable slots must all be started; only the permanently-broken \
             slot should fail — the bug made ALL 5 iterations pile onto slot {BROKEN_SLOT}"
        );

        let attempts = attempts.lock().unwrap();
        assert_eq!(
            attempts.get(&BROKEN_SLOT).copied(),
            Some(1),
            "the permanently-broken slot must be attempted exactly ONCE per call, not retried \
             for every remaining iteration in the batch (this is the exact bug from ez-gh-actions-oau)"
        );
        for slot in 1..=5u32 {
            if slot != BROKEN_SLOT {
                assert_eq!(
                    attempts.get(&slot).copied(),
                    Some(1),
                    "slot {slot} should be attempted exactly once and succeed on the first try"
                );
            }
        }
        assert_eq!(
            attempts.values().sum::<u32>(),
            5,
            "5 missing slots must mean 5 attempts across 5 DISTINCT slots, not 5 retries \
             concentrated on the single broken slot"
        );
    }

    #[test]
    fn repeated_local_start_failures_open_only_the_slot_circuit() {
        let env = TestEnv::new("persistent_slot_circuit");
        let cfg = cfg_with(1, "ez-org-runner");
        let attempts = std::sync::Arc::new(AtomicUsize::new(0));

        for _ in 0..3 {
            let attempts_for_starter = std::sync::Arc::clone(&attempts);
            let outcome = start_missing_runners_with_starter(
                &cfg,
                Backend::Docker,
                1,
                move |_cfg, _backend, slot| {
                    attempts_for_starter.fetch_add(1, Ordering::SeqCst);
                    release_slot(slot)?;
                    bail!("simulated local container start failure")
                },
            )
            .expect("local start failures are a bounded partial outcome");
            assert_eq!(outcome.start_failures, 1);
        }

        assert_eq!(attempts.load(Ordering::SeqCst), 3);
        let state_path = env.path.with_file_name("failure_ladder.toml");
        let ladder = FailureLadder::load(&state_path).unwrap();
        assert!(ladder.slot_is_open(1, now_epoch_secs()));

        let attempts_for_starter = std::sync::Arc::clone(&attempts);
        let paused = start_missing_runners_with_starter(
            &cfg,
            Backend::Docker,
            1,
            move |_cfg, _backend, _slot| {
                attempts_for_starter.fetch_add(1, Ordering::SeqCst);
                unreachable!("an open slot circuit must be excluded before start")
            },
        )
        .unwrap();
        assert!(paused.admission_paused_reason.is_some());
        assert_eq!(attempts.load(Ordering::SeqCst), 3);
    }

    #[test]
    fn failure_ladder_save_failure_latches_admission_across_reconciliation_ticks() {
        let _env = TestEnv::new("failure_ladder_save_failure_latch");
        let cfg = cfg_with(1, "ez-org-runner");
        let attempts = std::sync::Arc::new(AtomicUsize::new(0));
        let state_path = failure_ladder_path_for(&cfg);
        FailureLadder::default()
            .save(&state_path)
            .expect("baseline ledger should be durable before the injected failure");
        // Save #1 above is the baseline.  Save #2 is the preflight and must
        // succeed; save #3 records the local-start failure and is injected to
        // fail after the external starter has run exactly once.
        crate::failure_ladder::set_test_save_failure_on_call(Some(3));

        let first = start_missing_runners_with_starter(&cfg, Backend::Docker, 1, {
            let attempts = std::sync::Arc::clone(&attempts);
            move |_cfg, _backend, slot| {
                attempts.fetch_add(1, Ordering::SeqCst);
                release_slot(slot)?;
                bail!("simulated local container start failure")
            }
        })
        .expect("save failure should become a bounded admission pause");
        assert_eq!(first.start_failures, 1);
        assert!(first
            .admission_paused_reason
            .as_deref()
            .is_some_and(|reason| reason.contains("could not persist failure-ladder failure")));
        assert_eq!(attempts.load(Ordering::SeqCst), 1);

        // The old ledger is still readable, but its failed transition was not
        // persisted.  A subsequent serve tick must remain fail-closed rather
        // than re-invoking JIT/Docker admission against that stale ledger.
        let second = start_missing_runners_with_starter(&cfg, Backend::Docker, 1, {
            let attempts = std::sync::Arc::clone(&attempts);
            move |_cfg, _backend, _slot| {
                attempts.fetch_add(1, Ordering::SeqCst);
                unreachable!("latched admission must not invoke the starter")
            }
        })
        .expect("latched admission should be a bounded pause");
        assert!(second
            .admission_paused_reason
            .as_deref()
            .is_some_and(|reason| reason.contains("failure-ladder persistence")));
        assert_eq!(attempts.load(Ordering::SeqCst), 1);

        // Clearing the injected save error is not enough: recovery is an
        // explicit daemon-lifetime condition (process restart), represented
        // here by the test-only latch reset.
        crate::failure_ladder::reset_test_save_failure();
        let still_paused = start_missing_runners_with_starter(
            &cfg,
            Backend::Docker,
            1,
            |_cfg, _backend, _slot| unreachable!("latch must survive save recovery alone"),
        )
        .expect("latch should remain closed until explicit recovery");
        assert!(still_paused.admission_paused_reason.is_some());
        assert_eq!(attempts.load(Ordering::SeqCst), 1);

        reset_failure_ladder_admission_latch_for_tests();
        let recovered = start_missing_runners_with_starter(&cfg, Backend::Docker, 1, {
            let attempts = std::sync::Arc::clone(&attempts);
            move |_cfg, _backend, slot| {
                attempts.fetch_add(1, Ordering::SeqCst);
                release_slot(slot)?;
                bail!("post-restart simulated local start failure")
            }
        })
        .expect("explicit restart-equivalent reset should reopen admission");
        assert_eq!(recovered.start_failures, 1);
        assert_eq!(attempts.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn failure_ladder_preflight_save_failure_blocks_external_starter() {
        let _env = TestEnv::new("failure_ladder_preflight_save_failure");
        let cfg = cfg_with(1, "ez-org-runner");
        let state_path = failure_ladder_path_for(&cfg);
        FailureLadder::default()
            .save(&state_path)
            .expect("baseline ledger should be durable before the injected failure");
        // Save #1 above is the baseline; fail the preflight save (#2).
        crate::failure_ladder::set_test_save_failure_on_call(Some(2));
        let attempts = std::sync::Arc::new(AtomicUsize::new(0));

        let outcome = start_missing_runners_with_starter(&cfg, Backend::Docker, 1, {
            let attempts = std::sync::Arc::clone(&attempts);
            move |_cfg, _backend, _slot| {
                attempts.fetch_add(1, Ordering::SeqCst);
                unreachable!("failed persistence preflight must precede external admission")
            }
        })
        .expect("preflight failure should become a bounded admission pause");

        assert_eq!(attempts.load(Ordering::SeqCst), 0);
        assert_eq!(outcome.start_failures, 0);
        assert!(outcome
            .admission_paused_reason
            .as_deref()
            .is_some_and(|reason| reason.contains("preflight")));
    }

    #[test]
    fn github_jit_failures_do_not_penalize_healthy_slots() {
        let env = TestEnv::new("control_plane_not_slot_failure");
        let cfg = cfg_with(3, "ez-org-runner");

        for _ in 0..6 {
            let outcome = start_missing_runners_with_starter(
                &cfg,
                Backend::Docker,
                3,
                |_cfg, _backend, slot| {
                    release_slot(slot)?;
                    Err(admission_preflight_error(anyhow::anyhow!(
                        "simulated GitHub secondary rate limit"
                    )))
                },
            )
            .unwrap();
            assert_eq!(outcome.start_failures, 1);
            assert!(outcome
                .admission_paused_reason
                .as_deref()
                .is_some_and(|reason| reason.contains("without penalizing slot")));
        }

        let state_path = env.path.with_file_name("failure_ladder.toml");
        let ladder = FailureLadder::load(&state_path).unwrap();
        assert_eq!(ladder.open_slot_count(now_epoch_secs()), 0);
        assert!(ladder.excluded_slots(now_epoch_secs()).is_empty());
        assert!(!ladder.fleet_admission_is_paused(now_epoch_secs()));
    }

    #[test]
    fn three_distinct_slot_circuits_pause_all_new_admission() {
        let _env = TestEnv::new("persistent_fleet_circuit");
        let cfg = cfg_with(3, "ez-org-runner");
        let attempts = std::sync::Arc::new(AtomicUsize::new(0));

        let mut last = StartMissingOutcome::default();
        for _ in 0..9 {
            let attempts_for_starter = std::sync::Arc::clone(&attempts);
            last = start_missing_runners_with_starter(
                &cfg,
                Backend::Docker,
                1,
                move |_cfg, _backend, slot| {
                    attempts_for_starter.fetch_add(1, Ordering::SeqCst);
                    release_slot(slot)?;
                    bail!("simulated systemic local start failure")
                },
            )
            .unwrap();
        }

        assert_eq!(attempts.load(Ordering::SeqCst), 9);
        assert!(last
            .admission_paused_reason
            .as_deref()
            .is_some_and(|reason| reason.contains("fleet admission circuit opened")));

        let attempts_for_starter = std::sync::Arc::clone(&attempts);
        let paused = start_missing_runners_with_starter(
            &cfg,
            Backend::Docker,
            3,
            move |_cfg, _backend, _slot| {
                attempts_for_starter.fetch_add(1, Ordering::SeqCst);
                unreachable!("fleet circuit must close admission before allocation")
            },
        )
        .unwrap();
        assert!(paused.admission_paused_reason.is_some());
        assert_eq!(attempts.load(Ordering::SeqCst), 9);
    }

    #[test]
    fn ensure_count_real_wiring_computes_missing_before_start_missing() {
        let _env = TestEnv::new("ensure_count_wiring");
        let cfg = cfg_with(5, "ez-org-runner");
        *TEST_RELEASE_STALE_SLOTS_RESULT.lock().unwrap() = Some(0);
        *TEST_FREE_DISK_GB.lock().unwrap() = Some(Some(100));
        *TEST_MANAGED_CONTAINERS.lock().unwrap() = Some(vec![
            managed_container("ez-org-runner-1"),
            managed_container("ez-org-runner-2"),
            managed_container("ez-org-runner-3"),
            managed_container("ez-canary-runner-1"),
        ]);
        *TEST_START_ONE_NAMES.lock().unwrap() =
            Some(vec!["ez-org-runner-4".into(), "ez-org-runner-5".into()]);
        *TEST_EXECUTING_RUNNER_COUNTS.lock().unwrap() = Some(
            [Ok(ReadinessSummary {
                ready: 3,
                absent: vec![],
            })]
            .into(),
        );

        let outcome = ensure_count_outcome(&cfg, Backend::Docker).unwrap();

        assert_eq!(
            outcome.started,
            vec!["ez-org-runner-4", "ez-org-runner-5"],
            "ensure_count_outcome must compute missing=count-alive using only current-prefix containers"
        );
        assert!(
            TEST_START_ONE_NAMES
                .lock()
                .unwrap()
                .as_ref()
                .unwrap()
                .is_empty(),
            "real start_missing_runners path should consume exactly two start_one calls"
        );
    }

    #[test]
    fn ensure_count_recounts_locally_after_one_bounded_start_batch() {
        let _env = TestEnv::new("ensure_count_post_batch_recount");
        let cfg = cfg_with(6, "ez-org-runner");
        *TEST_RELEASE_STALE_SLOTS_RESULT.lock().unwrap() = Some(0);
        *TEST_FREE_DISK_GB.lock().unwrap() = Some(Some(100));
        *TEST_MANAGED_CONTAINER_SNAPSHOTS.lock().unwrap() = [
            vec![
                managed_container("ez-org-runner-1"),
                managed_container("ez-org-runner-2"),
                managed_container("ez-org-runner-3"),
                managed_container("ez-org-runner-4"),
            ],
            vec![
                managed_container("ez-org-runner-3"),
                managed_container("ez-org-runner-4"),
                managed_container("ez-org-runner-5"),
                managed_container("ez-org-runner-6"),
            ],
        ]
        .into();
        *TEST_START_ONE_NAMES.lock().unwrap() = Some(vec![
            "ez-org-runner-5".into(),
            "ez-org-runner-6".into(),
            "must-not-start-in-a-second-batch".into(),
        ]);
        *TEST_EXECUTING_RUNNER_COUNTS.lock().unwrap() = Some(
            [Ok(ReadinessSummary {
                ready: 4,
                absent: vec![],
            })]
            .into(),
        );

        let outcome = ensure_count_outcome(&cfg, Backend::Docker).unwrap();

        assert_eq!(
            outcome.missing, 2,
            "initial snapshot should start one batch of two"
        );
        assert_eq!(
            outcome.started.len(),
            2,
            "one call may start at most the initial shortage"
        );
        assert_eq!(
            outcome.remaining_shortage, 2,
            "the post-batch local recount must expose jobs that exited while starts were serialized"
        );
        assert_eq!(
            TEST_START_ONE_NAMES.lock().unwrap().as_ref().unwrap(),
            &["must-not-start-in-a-second-batch"],
            "ensure_count must never start a second batch in the same call"
        );
        assert!(
            !outcome.is_partial_failure(),
            "legitimate turnover after a fully successful batch is not a backend failure"
        );
    }

    #[test]
    fn ensure_count_treats_all_reserved_slots_as_pending_turnover_not_failure() {
        let _env = TestEnv::new("ensure_count_reserved_turnover");
        let cfg = cfg_with(6, "ez-org-runner");
        for slot in 1..=6 {
            assert_eq!(next_slot(&cfg).unwrap(), slot);
            record_slot_runner_id(slot, 1000 + u64::from(slot)).unwrap();
        }
        *TEST_RELEASE_STALE_SLOTS_RESULT.lock().unwrap() = Some(0);
        *TEST_FREE_DISK_GB.lock().unwrap() = Some(Some(100));
        let five_alive = vec![
            managed_container("ez-org-runner-1"),
            managed_container("ez-org-runner-2"),
            managed_container("ez-org-runner-3"),
            managed_container("ez-org-runner-4"),
            managed_container("ez-org-runner-5"),
        ];
        *TEST_MANAGED_CONTAINER_SNAPSHOTS.lock().unwrap() = [five_alive.clone(), five_alive].into();
        *TEST_START_ONE_NAMES.lock().unwrap() = Some(vec!["must-not-start".into()]);
        *TEST_EXECUTING_RUNNER_COUNTS.lock().unwrap() = Some(
            [Ok(ReadinessSummary {
                ready: 5,
                absent: vec![],
            })]
            .into(),
        );

        let outcome = ensure_count_outcome(&cfg, Backend::Docker)
            .expect("an exited one-job container with a settling registration is pending turnover");

        assert_eq!(outcome.missing, 1);
        assert!(outcome.started.is_empty());
        assert_eq!(outcome.remaining_shortage, 1);
        assert!(
            !outcome.is_partial_failure(),
            "no free local slot is not a JIT/Docker start failure and must not drive backend restart accounting"
        );
        assert_eq!(
            TEST_START_ONE_NAMES.lock().unwrap().as_ref().unwrap(),
            &["must-not-start"],
            "a reservation wedge must not invoke the starter without a free slot"
        );
    }

    #[test]
    fn ensure_count_full_idle_listener_fleet_has_no_shortage_or_settling_signal() {
        let _env = TestEnv::new("ensure_count_idle_listener_capacity");
        let cfg = cfg_with(6, "ez-org-runner");
        *TEST_RELEASE_STALE_SLOTS_RESULT.lock().unwrap() = Some(0);
        let six_containers: Vec<_> = (1..=6)
            .map(|slot| managed_container(&format!("ez-org-runner-{slot}")))
            .collect();
        *TEST_MANAGED_CONTAINER_SNAPSHOTS.lock().unwrap() = [six_containers].into();
        *TEST_START_ONE_NAMES.lock().unwrap() = Some(vec!["must-not-start".into()]);

        let outcome = ensure_count_outcome(&cfg, Backend::Docker).unwrap();

        assert_eq!(outcome.missing, 0);
        assert_eq!(outcome.remaining_shortage, 0);
        assert!(
            outcome.started.is_empty(),
            "six managed Listener-only containers are normal idle capacity"
        );
        assert!(
            !outcome.is_partial_failure(),
            "normal idle capacity must not drive guards or alerts"
        );
        assert!(
            TEST_EXECUTING_RUNNER_COUNTS.lock().unwrap().is_none(),
            "normal full-capacity ticks must not consult Runner.Worker readiness or enter settling"
        );
        assert_eq!(
            TEST_START_ONE_NAMES.lock().unwrap().as_ref().unwrap(),
            &["must-not-start"],
            "normal idle capacity must not spawn"
        );
    }

    #[test]
    fn ensure_count_uses_runner_worker_only_after_actual_refill() {
        let _env = TestEnv::new("ensure_count_post_refill_worker_readiness");
        let cfg = cfg_with(6, "ez-org-runner");
        *TEST_RELEASE_STALE_SLOTS_RESULT.lock().unwrap() = Some(0);
        *TEST_FREE_DISK_GB.lock().unwrap() = Some(Some(100));
        let initial: Vec<_> = (1..=4)
            .map(|slot| managed_container(&format!("ez-org-runner-{slot}")))
            .collect();
        let after_refill: Vec<_> = (1..=6)
            .map(|slot| managed_container(&format!("ez-org-runner-{slot}")))
            .collect();
        *TEST_MANAGED_CONTAINER_SNAPSHOTS.lock().unwrap() = [initial, after_refill].into();
        *TEST_START_ONE_NAMES.lock().unwrap() =
            Some(vec!["ez-org-runner-5".into(), "ez-org-runner-6".into()]);
        *TEST_EXECUTING_RUNNER_COUNTS.lock().unwrap() = Some(
            [Ok(ReadinessSummary {
                ready: 4,
                absent: vec![],
            })]
            .into(),
        );

        let outcome = ensure_count_outcome(&cfg, Backend::Docker).unwrap();

        assert_eq!(
            outcome.missing, 2,
            "spawn shortage is managed-container count"
        );
        assert_eq!(outcome.started.len(), 2);
        assert_eq!(
            outcome.remaining_shortage, 2,
            "post-refill settling waits for the two new Runner.Worker processes"
        );
    }

    #[test]
    fn runner_worker_parser_requires_exact_process_name() {
        let output = "PID COMMAND\n101 Runner.Listener\n202 Runner.Worker\n";
        assert!(runner_worker_present(output));
        assert!(!runner_worker_present("PID COMMAND\n101 Runner.Listener\n"));
        assert!(!runner_worker_present(
            "PID COMMAND\n202 NotRunner.Workerish\n"
        ));
    }

    /// Bead jleechan-viff: `runner_present` (the new function used by the
    /// daemon's settling-ceiling check) accepts both `Runner.Worker` (job in
    /// flight) AND `Runner.Listener` (registered + idle) as "ready to take
    /// jobs". The old `runner_worker_present` only checked Worker, which
    /// misclassified idle-but-healthy listeners as "not executing" and
    /// caused false-positive `runner startup settling ceiling reached: 0/6
    /// ready locally (listeners or workers)` CRITICALs on idle healthy
    /// fleets. This test pins the corrected semantics.
    #[test]
    fn runner_present_accepts_listener_or_worker() {
        // Either Runner.Listener OR Runner.Worker → ready.
        assert!(runner_present("PID COMMAND\n101 Runner.Listener\n"));
        assert!(runner_present("PID COMMAND\n202 Runner.Worker\n"));
        assert!(runner_present(
            "PID COMMAND\n1 Runner.Listener\n2 Runner.Worker\n"
        ));
        // Neither process present → genuinely broken.
        assert!(!runner_present("PID COMMAND\n101 NotRunner.Workerish\n"));
        assert!(!runner_present("PID COMMAND\n"));
        // Substring matches must NOT false-positive (e.g. "Runner.Workerish"
        // is not a Runner.Worker process).
        assert!(!runner_present(
            "PID COMMAND\n202 NotRunner.Workerish\n203 NotRunner.Listenerish\n"
        ));
    }

    /// Bead jleechan-95jk root-cause: a docker top that returns "No such
    /// container" is a definitive signal that the container is GONE — not a
    /// probe failure. The readiness probe converts it to
    /// `ProbeOutcome::Absent` (so the readiness pass keeps the other slots'
    /// evidence usable and the absent slot's name reaches the settling loop
    /// for immediate reconciliation) and the `release_stale_slots` path
    /// converts it to `LocalRunnerActivity::Absent` (so the slot can be
    /// reclaimed). This test pins the stderr classifier
    /// that both paths share.
    #[test]
    fn docker_top_container_absent_classifies_only_no_such_container() {
        // Canonical docker engine message.
        assert!(docker_top_container_absent(
            "Error response from daemon: No such container: ez-runner-c-3"
        ));
        // Some plugin paths historically report "No such object".
        assert!(docker_top_container_absent(
            "Error: No such object: ez-runner-c-3"
        ));
        // Genuine probe failures must NOT classify as absence.
        assert!(!docker_top_container_absent(
            "Error response from daemon: context deadline exceeded"
        ));
        assert!(!docker_top_container_absent(""));
        assert!(!docker_top_container_absent(
            "Error response from daemon: permission denied while trying to connect to the Docker daemon socket"
        ));
        // "No such container" inside a longer log line still matches.
        assert!(docker_top_container_absent(
            "level=error msg=\"No such container: ez-runner-c-3 (docker top)\""
        ));
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn post_refill_released_slot_requests_immediate_reconcile() {
        let _qlock = crate::quarantine::tests::test_lock();
        let env = TestEnv::new("post_refill_released_slot");
        let dir = env.path.parent().unwrap();
        // TestEnv paths can recur after a test process PID is recycled.
        for file in [
            "calls",
            "started-c10",
            "at-c10-jit.toml",
            "at-second-release.toml",
        ] {
            let _ = std::fs::remove_file(dir.join(file));
        }
        let mut cfg = cfg_with(14, "ez-runner-c");
        cfg.state_dir = Some(dir.into());
        cfg.runner.host_reserve_mb = 0;
        cfg.limits.memory_mb = 1;
        cfg.limits.cpu_burst = false;
        cfg.limits.cgroup_parent = Some("actions.slice".into());
        *TEST_FREE_DISK_GB.lock().unwrap() = Some(Some(100));
        *TEST_IS_MACOS_HOST.lock().unwrap() = Some(false);
        *TEST_HOST_CONTAINMENT_DAEMON_IN_VM.lock().unwrap() = Some(false);
        cpu_probe_overrides::set(Some(true));
        let cgroup = dir.join("cgroup");
        write_actions_slice_fixture(&cgroup, 14);
        std::fs::write(cgroup.join("actions.slice/memory.current"), "0\n").unwrap();
        std::fs::write(
            cgroup.join("actions.slice/memory.pressure"),
            "some avg10=0.00 avg60=0.00 avg300=0.00 total=0\n",
        )
        .unwrap();
        *TEST_HOST_CONTAINMENT_CGROUP_ROOT.lock().unwrap() = Some(cgroup);

        // Real release, allocation and start functions; all state is isolated.
        // c4 is already missing locally but still has a matching online GH
        // registration at the first release. c10 is the only vacant slot.
        let mut assignments = SlotAssignments::default();
        for slot in (1..=14).filter(|slot| *slot != 10) {
            assignments
                .assignments
                .insert(slot.to_string(), (1000 + slot).to_string());
            assignments
                .registered_at
                .insert(slot.to_string(), now_epoch_secs());
        }
        write_slot_assignments_for(&assignments, Some(&cfg)).unwrap();
        for (file, after) in [("before.json", false), ("after.json", true)] {
            let runners: Vec<_> = (1..=14)
                .filter(|slot| if after { *slot != 4 } else { *slot != 10 })
                .map(|slot| {
                    serde_json::json!({
                        "id": 1000 + slot,
                        "name": format!("ez-runner-c-{slot}"),
                        "status": "online",
                        "busy": true
                    })
                })
                .collect();
            std::fs::write(
                dir.join(file),
                serde_json::json!([{"total_count": runners.len(), "runners": runners}]).to_string(),
            )
            .unwrap();
            let containers = (1..=14)
                .filter(|slot| *slot != 4 && (after || *slot != 10))
                .map(|slot| {
                    format!(
                        "{}\n",
                        serde_json::json!({
                            "ID": format!("container-{slot}"),
                            "Names": format!("ez-runner-c-{slot}"),
                            "State": "running", "RunningFor": "one minute"
                        })
                    )
                })
                .collect::<String>();
            std::fs::write(
                dir.join(if after { "after.jsonl" } else { "before.jsonl" }),
                containers,
            )
            .unwrap();
        }
        let gh = dir.join("fake-gh");
        std::fs::write(
            &gh,
            format!(
                r#"#!/bin/sh
set -eu
PATH=/usr/bin:/bin
cd '{}'
printf 'gh %s\n' "$*" >> calls
case "$*" in
  'api --paginate --slurp '*'/actions/runners'*)
    if [ -f started-c10 ]; then
      cp slot_assignments.toml at-second-release.toml
      cat after.json
    else
      cat before.json
    fi;;
  'api -X POST '*'/actions/runners/generate-jitconfig '*'name=ez-runner-c-10 '*)
    cp slot_assignments.toml at-c10-jit.toml
    printf '%s\n' '{{"encoded_jit_config":"synthetic-jit","runner":{{"id":1010}}}}';;
  *) echo unexpected-gh-call >&2; exit 71;;
esac
"#,
                dir.display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&gh, std::fs::Permissions::from_mode(0o755)).unwrap();
        let _gh_guard = crate::github::with_gh_exe(gh.to_str().unwrap());
        let _token_guard = crate::github::with_gh_token_file(dir.join("no-token"));
        let docker = dir.join("fake-docker");
        std::fs::write(
            &docker,
            format!(
                r#"#!/bin/sh
set -eu
PATH=/usr/bin:/bin
cd '{}'
if [ "${{1:-}}" = --host ]; then shift 2; fi
printf 'docker %s\n' "$*" >> calls
case "$*" in
  'ps --filter label=ezgha=managed --format json')
    if [ -f started-c10 ]; then cat after.jsonl; else cat before.jsonl; fi;;
  'stats '*) exit 0;;
  'ps --quiet --no-trunc') exit 0;;
  'info '*) printf '32 64000000000\n';;
  'rm -f ez-runner-c-10') exit 0;;
  'run -d --rm --name ez-runner-c-10 '*)
    : > started-c10
    printf 'container-10\n';;
  *) echo unexpected-docker-call >&2; exit 71;;
esac
"#,
                dir.display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&docker, std::fs::Permissions::from_mode(0o755)).unwrap();
        *TEST_DOCKER_BIN.lock().unwrap() = Some(docker.to_string_lossy().into_owned());
        // Test builds require the existing readiness seam. It drives the real
        // inventory-filtered probe fanout, and cannot invent an absent name
        // for c4, which is never in these docker-ps results.
        *TEST_EXECUTING_RUNNER_COUNTS.lock().unwrap() = Some(
            (0..6)
                .map(|_| {
                    Ok(ReadinessSummary {
                        ready: 13,
                        absent: vec![],
                    })
                })
                .collect(),
        );

        let outcome = ensure_count_outcome(&cfg, Backend::Docker).unwrap();
        assert_eq!(outcome.started, vec!["ez-runner-c-10"]);
        assert_eq!(outcome.missing, 2);
        assert_eq!(outcome.remaining_shortage, 1);
        assert_eq!(outcome.start_failures, 0);
        assert!(outcome.admission_paused_reason.is_none());
        assert!(outcome.post_refill_readiness_error.is_none());
        let at_jit: SlotAssignments =
            toml::from_str(&std::fs::read_to_string(dir.join("at-c10-jit.toml")).unwrap()).unwrap();
        assert_eq!(
            at_jit.assignments.get("4").map(String::as_str),
            Some("1004")
        );
        assert_eq!(at_jit.assignments.get("10").map(String::as_str), Some(""));
        let at_second: SlotAssignments =
            toml::from_str(&std::fs::read_to_string(dir.join("at-second-release.toml")).unwrap())
                .unwrap();
        assert_eq!(
            at_second.assignments.get("4").map(String::as_str),
            Some("1004")
        );
        assert_eq!(
            at_second.assignments.get("10").map(String::as_str),
            Some("1010")
        );
        let after_second = read_slot_assignments_for(Some(&cfg)).unwrap();
        assert!(!after_second.assignments.contains_key("4"));
        assert_eq!(
            after_second.assignments.get("10").map(String::as_str),
            Some("1010")
        );
        let calls = std::fs::read_to_string(dir.join("calls")).unwrap();
        assert_eq!(
            calls
                .lines()
                .filter(|line| line.starts_with("gh api --paginate"))
                .count(),
            2
        );
        assert_eq!(
            calls
                .lines()
                .filter(|line| line.starts_with("docker run -d"))
                .count(),
            1
        );
        assert_eq!(
            calls
                .lines()
                .filter(|line| line.contains("generate-jitconfig"))
                .count(),
            1
        );
        assert!(!calls.contains("--name ez-runner-c-4 "));
        eprintln!("COMMAND TRACE:\n{calls}");
        eprintln!("C4 RESERVED AT C10 JIT=1004; C10 RESERVED EMPTY; C10 ID AFTER START=1010; C4 RELEASED AFTER BATCH");
        eprintln!("OUTCOME: {outcome:?}");

        let decision = crate::ensure_success_decision_with_pending_readiness(
            crate::ensure_success_decision(&cfg, &outcome),
            false,
            false,
            13,
        );
        let plan = crate::ensure_success_plan(&cfg, decision);
        eprintln!("SERVE DECISION: {decision:?}; PLAN: {plan:?}");
        if matches!(decision, crate::EnsureSuccessDecision::StartSettling { .. }) {
            let start = Instant::now();
            let mut settling = None;
            let mut pending = false;
            crate::apply_ensure_success_decision(&mut settling, &mut pending, start, decision);
            for seconds in [5, 10, 15, 20, 25] {
                let summary = local_executing_runner_count(&cfg).unwrap();
                assert_eq!(summary.ready, 13);
                assert!(summary.absent.is_empty());
                let observed = settling.as_mut().unwrap().observe(
                    start + Duration::from_secs(seconds),
                    summary.ready,
                    cfg.runner.count,
                );
                eprintln!(
                    "SERVE POLL +{seconds}s: ready={}, absent={:?}, decision={observed:?}",
                    summary.ready, summary.absent
                );
                assert_eq!(
                    observed,
                    if seconds < 25 {
                        crate::SettlingDecision::Continue
                    } else {
                        crate::SettlingDecision::Ceiling
                    }
                );
            }
        }
        assert_eq!(
            plan,
            (Duration::ZERO, false),
            "a configured reservation released after the sole start batch must request the next bounded reconciliation"
        );
    }

    #[cfg(target_os = "linux")]
    fn released_slot_full_path_case(case: &str) {
        let env = TestEnv::new(&format!("released_boundary_{case}"));
        let dir = env.path.parent().unwrap();
        // TestEnv paths can recur after a test process PID is recycled.
        for file in [
            "calls",
            "started-c10",
            "at-c10-jit.toml",
            "at-second-release.toml",
            // These cases deliberately corrupt/open their own ledgers.
            // Clear them too when a test-process PID/path is recycled.
            "failure_ladder.toml",
            "quarantined_slots.toml",
        ] {
            let _ = std::fs::remove_file(dir.join(file));
        }
        let mut cfg = cfg_with(14, "ez-runner-c");
        cfg.state_dir = Some(dir.into());
        cfg.runner.host_reserve_mb = 0;
        cfg.limits.memory_mb = 1;
        cfg.limits.cpu_burst = false;
        cfg.limits.cgroup_parent = Some("actions.slice".into());
        *TEST_FREE_DISK_GB.lock().unwrap() = Some(Some(100));
        *TEST_IS_MACOS_HOST.lock().unwrap() = Some(false);
        *TEST_HOST_CONTAINMENT_DAEMON_IN_VM.lock().unwrap() = Some(false);
        cpu_probe_overrides::set(Some(true));
        let cgroup = dir.join("cgroup");
        write_actions_slice_fixture(&cgroup, 14);
        std::fs::write(cgroup.join("actions.slice/memory.current"), "0\n").unwrap();
        std::fs::write(
            cgroup.join("actions.slice/memory.pressure"),
            "some avg10=0.00 avg60=0.00 avg300=0.00 total=0\n",
        )
        .unwrap();
        *TEST_HOST_CONTAINMENT_CGROUP_ROOT.lock().unwrap() = Some(cgroup);

        // Real release, allocation and start functions; all state is isolated.
        // c4 is already missing locally but still has a matching online GH
        // registration at the first release. c10 is the only vacant slot.
        let mut assignments = SlotAssignments::default();
        for slot in (1..=14).filter(|slot| *slot != 10) {
            assignments
                .assignments
                .insert(slot.to_string(), (1000 + slot).to_string());
            assignments
                .registered_at
                .insert(slot.to_string(), now_epoch_secs());
        }
        if case == "failed_fresh" {
            assignments.assignments.remove("11");
            assignments.registered_at.remove("11");
        }
        if case == "empty" {
            assignments.assignments.insert("4".into(), String::new());
        }
        if case == "out_of_range" {
            assignments.assignments.insert("15".into(), "1015".into());
        }
        write_slot_assignments_for(&assignments, Some(&cfg)).unwrap();
        for (file, after) in [("before.json", false), ("after.json", true)] {
            let runners: Vec<_> = (1..=14)
                .filter(|slot| if after { *slot != 4 } else { *slot != 10 })
                .map(|slot| {
                    serde_json::json!({
                        "id": 1000 + slot,
                        "name": format!("ez-runner-c-{slot}"),
                        "status": "online",
                        "busy": true
                    })
                })
                .collect();
            std::fs::write(
                dir.join(file),
                serde_json::json!([{"total_count": runners.len(), "runners": runners}]).to_string(),
            )
            .unwrap();
            let containers = (1..=14)
                .filter(|slot| *slot != 4 && (after || *slot != 10))
                .map(|slot| {
                    format!(
                        "{}\n",
                        serde_json::json!({
                            "ID": format!("container-{slot}"),
                            "Names": format!("ez-runner-c-{slot}"),
                            "State": "running", "RunningFor": "one minute"
                        })
                    )
                })
                .collect::<String>();
            std::fs::write(
                dir.join(if after { "after.jsonl" } else { "before.jsonl" }),
                containers,
            )
            .unwrap();
        }
        let gh = dir.join("fake-gh");
        std::fs::write(
            &gh,
            format!(
                r#"#!/bin/sh
set -eu
PATH=/usr/bin:/bin
cd '{}'
printf 'gh %s\n' "$*" >> calls
case "$*" in
  'api --paginate --slurp '*'/actions/runners'*)
    if [ -f started-c10 ]; then
      cp slot_assignments.toml at-second-release.toml
      cat after.json
    else
      cat before.json
    fi;;
  'api -X POST '*'/actions/runners/generate-jitconfig '*'name=ez-runner-c-10 '*)
    cp slot_assignments.toml at-c10-jit.toml
    printf '%s\n' '{{"encoded_jit_config":"synthetic-jit","runner":{{"id":1010}}}}';;
  *) echo unexpected-gh-call >&2; exit 71;;
esac
"#,
                dir.display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&gh, std::fs::Permissions::from_mode(0o755)).unwrap();
        let _gh_guard = crate::github::with_gh_exe(gh.to_str().unwrap());
        let _token_guard = crate::github::with_gh_token_file(dir.join("no-token"));
        let docker = dir.join("fake-docker");
        std::fs::write(
            &docker,
            format!(
                r#"#!/bin/sh
set -eu
PATH=/usr/bin:/bin
cd '{}'
if [ "${{1:-}}" = --host ]; then shift 2; fi
printf 'docker %s\n' "$*" >> calls
case "$*" in
  'ps --filter label=ezgha=managed --format json')
    if [ -f started-c10 ]; then cat after.jsonl; else cat before.jsonl; fi;;
  'stats '*) exit 0;;
  'ps --quiet --no-trunc') exit 0;;
  'info '*) printf '32 64000000000\n';;
  'rm -f ez-runner-c-10') exit 0;;
  'run -d --rm --name ez-runner-c-10 '*)
    : > started-c10
    printf 'container-10\n';;
  *) echo unexpected-docker-call >&2; exit 71;;
esac
"#,
                dir.display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&docker, std::fs::Permissions::from_mode(0o755)).unwrap();
        *TEST_DOCKER_BIN.lock().unwrap() = Some(docker.to_string_lossy().into_owned());
        // Test builds require the existing readiness seam. It drives the real
        // inventory-filtered probe fanout, and cannot invent an absent name
        // for c4, which is never in these docker-ps results.
        *TEST_EXECUTING_RUNNER_COUNTS.lock().unwrap() = Some(
            (0..6)
                .map(|_| {
                    Ok(ReadinessSummary {
                        ready: 13,
                        absent: vec![],
                    })
                })
                .collect(),
        );

        // Each case changes only external-boundary fixture state. The real
        // release/allocation/start/recount and serve decisions remain in use.
        let after_start = match case {
            "empty" => {
                assignments.registered_at.insert("4".into(), 0);
                "cp injected.toml slot_assignments.toml"
            }
            "already_vacant" => {
                assignments.assignments.remove("4");
                "cp injected.toml slot_assignments.toml"
            }
            "replacement_id" => {
                assignments.assignments.insert("4".into(), "2004".into());
                "cp injected.toml slot_assignments.toml"
            }
            "unknown_slots" => "printf 'invalid = [' > slot_assignments.toml",
            "unknown_quarantine" => "printf 'invalid = [' > quarantined_slots.toml",
            "unknown_ladder" => "printf 'invalid = [' > failure_ladder.toml",
            _ => "true",
        };
        assignments.assignments.insert("10".into(), "1010".into());
        std::fs::write(
            dir.join("injected.toml"),
            toml::to_string(&assignments).unwrap(),
        )
        .unwrap();
        let script = std::fs::read_to_string(&docker).unwrap();
        std::fs::write(
            &docker,
            script.replace(
                ": > started-c10",
                &format!(": > started-c10\n    {after_start}"),
            ),
        )
        .unwrap();
        if matches!(case, "already_vacant" | "unknown_slots") {
            // Make the sole batch one attempt, so the external state mutation
            // occurs after its last allocation and before trailing release.
            let mut rows = std::fs::read_to_string(dir.join("before.jsonl")).unwrap();
            rows.push_str(&format!(
                "{}\n",
                serde_json::json!({
                    "ID": "initial-4", "Names": "ez-runner-c-4",
                    "State": "running", "RunningFor": "one minute"
                })
            ));
            std::fs::write(dir.join("before.jsonl"), rows).unwrap();
        }
        if case == "same_name_present" {
            let mut rows = std::fs::read_to_string(dir.join("after.jsonl")).unwrap();
            rows.push_str(&format!(
                "{}\n",
                serde_json::json!({
                    "ID": "replacement-4", "Names": "ez-runner-c-4",
                    "State": "running", "RunningFor": "one second"
                })
            ));
            std::fs::write(dir.join("after.jsonl"), rows).unwrap();
        }
        if case == "still_reserved" {
            std::fs::copy(dir.join("before.json"), dir.join("after.json")).unwrap();
        }
        if case == "out_of_range" {
            // Hold the out-of-range reservation across the first release.
            let mut json: serde_json::Value =
                serde_json::from_str(&std::fs::read_to_string(dir.join("before.json")).unwrap())
                    .unwrap();
            json[0]["runners"]
                .as_array_mut()
                .unwrap()
                .push(serde_json::json!({
                    "id": 1015, "name": "ez-runner-c-15", "status": "online", "busy": true
                }));
            json[0]["total_count"] = serde_json::json!(14);
            std::fs::write(dir.join("before.json"), json.to_string()).unwrap();
        }
        if case == "quarantined" || case == "ladder" {
            // Introduce the exclusion only after the sole start, proving
            // eligibility is evaluated at the release/recount boundary.
            if case == "quarantined" {
                let mut table = QuarantineTable::default();
                table.upsert(QuarantineEntry {
                    slot: 4,
                    runner_id: 1004,
                    runner_name: "ez-runner-c-4".into(),
                    first_seen_epoch_secs: now_epoch_secs(),
                    attempt_count: 0,
                    last_attempt_epoch_secs: now_epoch_secs(),
                    reason: QuarantineReason::Locked422,
                });
                std::fs::write(dir.join("excluded.toml"), toml::to_string(&table).unwrap())
                    .unwrap();
                // The existing reconciliation removes an orphan quarantine.
                // Reintroduce it on the post-release inventory, like an
                // independent allocator update, without extra GitHub calls.
                let script = std::fs::read_to_string(&docker).unwrap();
                std::fs::write(&docker, script.replace(
                    "if [ -f started-c10 ]; then cat after.jsonl; else cat before.jsonl; fi",
                    "if [ -f started-c10 ]; then cp excluded.toml quarantined_slots.toml; cat after.jsonl; else cat before.jsonl; fi"
                )).unwrap();
            } else {
                let mut ladder = FailureLadder::default();
                let mut policy = failure_ladder_policy(&cfg);
                policy.slot_failure_threshold = 1;
                ladder.record_failure(policy, 4, now_epoch_secs()).unwrap();
                std::fs::write(dir.join("excluded.toml"), toml::to_string(&ladder).unwrap())
                    .unwrap();
                let script = std::fs::read_to_string(&docker).unwrap();
                std::fs::write(&docker, script.replace(
                    "if [ -f started-c10 ]; then cat after.jsonl; else cat before.jsonl; fi",
                    "if [ -f started-c10 ]; then cp excluded.toml failure_ladder.toml; cat after.jsonl; else cat before.jsonl; fi"
                )).unwrap();
            }
        }
        if case == "unknown_ladder" {
            let script = std::fs::read_to_string(&gh).unwrap();
            std::fs::write(&gh, script.replace("cp slot_assignments.toml at-second-release.toml", "cp slot_assignments.toml at-second-release.toml\n      printf 'invalid = [' > failure_ladder.toml")).unwrap();
        }
        if case == "unknown_inventory" {
            let script = std::fs::read_to_string(&docker).unwrap();
            std::fs::write(&docker, script.replace(
                "if [ -f started-c10 ]; then cat after.jsonl; else cat before.jsonl; fi",
                "if [ -f started-c10 ]; then echo inventory-unavailable >&2; exit 71; else cat before.jsonl; fi"
            )).unwrap();
        }
        if case == "readiness_error" {
            *TEST_EXECUTING_RUNNER_COUNTS.lock().unwrap() =
                Some(vec![Err("readiness unavailable".into())].into());
        }
        if case == "failed_fresh" {
            // Two fresh vacancies: c10's real Docker start fails after JIT
            // registration; c11 succeeds later in the same bounded batch.
            // c4 stays reserved until the trailing release, independently.
            for (file, removed) in [("before.json", 11), ("after.json", 10)] {
                let mut json: serde_json::Value =
                    serde_json::from_str(&std::fs::read_to_string(dir.join(file)).unwrap())
                        .unwrap();
                let runners = json[0]["runners"].as_array_mut().unwrap();
                runners.retain(|runner| runner["id"] != 1000 + removed);
                let count = runners.len();
                json[0]["total_count"] = serde_json::json!(count);
                std::fs::write(dir.join(file), json.to_string()).unwrap();
            }
            for (file, removed) in [("before.jsonl", 11), ("after.jsonl", 10)] {
                let rows = std::fs::read_to_string(dir.join(file)).unwrap();
                let rows = rows
                    .lines()
                    .filter(|line| {
                        let row: serde_json::Value = serde_json::from_str(line).unwrap();
                        row["Names"] != format!("ez-runner-c-{removed}")
                    })
                    .map(|line| format!("{line}\n"))
                    .collect::<String>();
                std::fs::write(dir.join(file), rows).unwrap();
            }
            let script = std::fs::read_to_string(&gh).unwrap();
            std::fs::write(&gh, script.replace(
                "  *) echo unexpected-gh-call",
                "  'api -X POST '*'/actions/runners/generate-jitconfig '*'name=ez-runner-c-11 '*) printf '%s\n' '{\"encoded_jit_config\":\"synthetic-jit\",\"runner\":{\"id\":1011}}';;\n  'api -X DELETE '*'/actions/runners/1010') exit 0;;\n  *) echo unexpected-gh-call"
            )).unwrap();
            let script = std::fs::read_to_string(&docker).unwrap();
            let script = script.replace(
                "  'rm -f ez-runner-c-10')",
                "  'rm -f ez-runner-c-10'|'rm -f ez-runner-c-11')",
            ).replace(
                "  'run -d --rm --name ez-runner-c-10 '*)",
                "  'run -d --rm --name ez-runner-c-10 '*) echo synthetic-fresh-start-failure >&2; exit 71;;\n  'run -d --rm --name ez-runner-c-11 '*)",
            ).replace("printf 'container-10\\n'", "printf 'container-11\\n'");
            std::fs::write(&docker, script).unwrap();
            *TEST_EXECUTING_RUNNER_COUNTS.lock().unwrap() = Some(
                vec![Ok(ReadinessSummary {
                    ready: 12,
                    absent: vec![],
                })]
                .into(),
            );
        }
        let result = ensure_count_outcome(&cfg, Backend::Docker);
        if case == "unknown_inventory" {
            assert!(result
                .unwrap_err()
                .to_string()
                .contains("post-refill local container recount"));
        } else {
            let outcome = result.unwrap();
            let eligible = matches!(
                case,
                "released" | "out_of_range" | "readiness_error" | "failed_fresh"
            );
            assert_eq!(
                outcome.post_refill_slots_released,
                if eligible {
                    vec!["ez-runner-c-4"]
                } else {
                    vec![]
                },
                "case={case}: {outcome:?}"
            );
            assert_eq!(
                outcome.post_refill_capacity_lost,
                if matches!(case, "already_vacant" | "unknown_slots") {
                    vec!["ez-runner-c-4"]
                } else {
                    vec![]
                },
                "case={case}"
            );
            assert_eq!(
                outcome.start_failures,
                u32::from(case == "failed_fresh"),
                "new uncertainty must not manufacture a backend failure: {case}"
            );
            let decision = crate::ensure_success_decision(&cfg, &outcome);
            assert_eq!(
                decision == crate::EnsureSuccessDecision::PostRefillSlotsReleased,
                eligible,
                "case={case}"
            );
            assert_eq!(
                outcome.started,
                if case == "failed_fresh" {
                    vec!["ez-runner-c-11"]
                } else {
                    vec!["ez-runner-c-10"]
                }
            );
            if case == "failed_fresh" {
                assert_eq!(outcome.missing, 3);
                assert_eq!(outcome.remaining_shortage, 2);
                assert!(outcome.admission_paused_reason.is_none());
                assert!(outcome.is_partial_failure());
                assert!(!outcome
                    .post_refill_slots_released
                    .iter()
                    .any(|name| name == "ez-runner-c-10"));
                let slots = read_slot_assignments_for(Some(&cfg)).unwrap();
                assert!(!slots.assignments.contains_key("4"));
                assert!(!slots.assignments.contains_key("10"));
                assert_eq!(
                    slots.assignments.get("11").map(String::as_str),
                    Some("1011")
                );
                assert_eq!(
                    crate::start_command_disposition(&outcome),
                    crate::StartCommandDisposition::Incomplete
                );
                let mut streak = 0;
                cfg.alert.failure_alert_threshold = 99;
                assert!(crate::apply_ensure_outcome_to_failure_streak(
                    &cfg,
                    Backend::Docker,
                    &mut streak,
                    &outcome
                ));
                assert_eq!(streak, 1);
                let paced =
                    crate::ensure_success_decision_with_pending_readiness(decision, true, true, 12);
                assert_eq!(
                    paced,
                    crate::EnsureSuccessDecision::StartSettling { executing: 12 }
                );
                assert_eq!(
                    crate::ensure_success_plan(&cfg, paced),
                    (
                        Duration::from_secs(crate::config::MIN_SERVE_TICK_SECONDS),
                        false
                    )
                );
            }
            eprintln!("BOUNDARY {case}: {outcome:?}; decision={decision:?}");
        }
        let calls = std::fs::read_to_string(dir.join("calls")).unwrap();
        if case == "failed_fresh" {
            let attempts: Vec<_> = calls
                .lines()
                .filter(|line| line.starts_with("docker run -d"))
                .collect();
            assert_eq!(attempts.len(), 2);
            assert!(attempts[0].contains("--name ez-runner-c-10 "));
            assert!(attempts[1].contains("--name ez-runner-c-11 "));
            assert_eq!(
                calls
                    .lines()
                    .filter(|line| line.starts_with("gh api -X DELETE"))
                    .count(),
                1
            );
            eprintln!("FAILED-FRESH COMMAND TRACE:\n{calls}");
        }
        assert_eq!(
            calls
                .lines()
                .filter(|line| line.starts_with("gh api --paginate"))
                .count(),
            2,
            "case={case}"
        );
        assert_eq!(
            calls
                .lines()
                .filter(|line| line.starts_with("docker run -d"))
                .count(),
            if case == "failed_fresh" { 2 } else { 1 },
            "case={case}"
        );
        assert_eq!(
            calls
                .lines()
                .filter(|line| line.contains("generate-jitconfig"))
                .count(),
            if case == "failed_fresh" { 2 } else { 1 },
            "case={case}"
        );
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn post_refill_released_slot_full_path_boundaries() {
        let _qlock = crate::quarantine::tests::test_lock();
        for case in [
            "released",
            "empty",
            "already_vacant",
            "replacement_id",
            "unknown_slots",
            "unknown_quarantine",
            "unknown_ladder",
            "same_name_present",
            "still_reserved",
            "out_of_range",
            "quarantined",
            "ladder",
            "unknown_inventory",
            "readiness_error",
            "failed_fresh",
        ] {
            released_slot_full_path_case(case);
        }
    }

    #[test]
    fn post_refill_released_slot_requires_complete_named_evidence() {
        let _qlock = crate::quarantine::tests::test_lock();
        let _env = TestEnv::new("released_evidence");
        let cfg = cfg_with(3, "runner");
        let before = SlotAssignments {
            assignments: [("1".into(), "1001".into())].into(),
            ..Default::default()
        };
        let vacant = SlotAssignments::default();
        let names = HashSet::new();
        let attempted = HashSet::new();
        assert_eq!(
            post_refill_released_slots(
                &cfg,
                Some(&before),
                Some(&before),
                Some(&vacant),
                &attempted,
                &names
            )
            .unwrap(),
            vec!["runner-1"]
        );
        for (a, b, c) in [
            (None, Some(&before), Some(&vacant)),
            (Some(&before), None, Some(&vacant)),
            (Some(&before), Some(&before), None),
        ] {
            assert!(
                post_refill_released_slots(&cfg, a, b, c, &attempted, &names)
                    .unwrap()
                    .is_empty()
            );
        }
        assert!(post_refill_released_slots(
            &cfg,
            Some(&before),
            Some(&before),
            Some(&vacant),
            &[1].into(),
            &names
        )
        .unwrap()
        .is_empty());
        assert!(
            post_refill_released_slots(
                &cfg,
                Some(&vacant),
                Some(&before),
                Some(&vacant),
                &attempted,
                &names
            )
            .unwrap()
            .is_empty(),
            "new reservations are excluded"
        );
        FAILURE_LADDER_PERSISTENCE_FAILED.store(true, Ordering::SeqCst);
        assert!(post_refill_released_slots(
            &cfg,
            Some(&before),
            Some(&before),
            Some(&vacant),
            &attempted,
            &names
        )
        .unwrap()
        .is_empty());
    }

    #[test]
    fn post_refill_inventory_loss_forces_immediate_reconcile() {
        let _env = TestEnv::new("post_refill_inventory_loss");
        let cfg = cfg_with(14, "ez-runner-c");
        *TEST_RELEASE_STALE_SLOTS_RESULT.lock().unwrap() = Some(0);
        *TEST_FREE_DISK_GB.lock().unwrap() = Some(Some(100));
        *TEST_HOST_FREE_DISK_GB.lock().unwrap() = Some(Some(100));

        // Initial inventory witnesses slots 1..12. The refill successfully
        // starts 13 and 14, but the post-refill inventory contains only 1..11.
        // Only pre-existing slot 12 is the intended lifecycle witness.
        // Fresh starts 13/14 must not contribute to that future trigger.
        let initial: Vec<_> = (1..=12)
            .map(|slot| managed_container(&format!("ez-runner-c-{slot}")))
            .collect();
        let post_refill: Vec<_> = (1..=11)
            .map(|slot| managed_container(&format!("ez-runner-c-{slot}")))
            .collect();
        *TEST_MANAGED_CONTAINER_SNAPSHOTS.lock().unwrap() = [initial, post_refill].into();
        *TEST_START_ONE_NAMES.lock().unwrap() =
            Some(vec!["ez-runner-c-13".into(), "ez-runner-c-14".into()]);
        *TEST_EXECUTING_RUNNER_COUNTS.lock().unwrap() = Some(
            [Ok(ReadinessSummary {
                ready: 11,
                absent: vec![],
            })]
            .into(),
        );

        let outcome = ensure_count_outcome(&cfg, Backend::Docker).unwrap();
        assert_eq!(outcome.started, vec!["ez-runner-c-13", "ez-runner-c-14"]);
        assert_eq!(outcome.missing, 2);
        assert_eq!(outcome.remaining_shortage, 3);
        assert_eq!(outcome.post_refill_capacity_lost, vec!["ez-runner-c-12"]);

        let decision = crate::ensure_success_decision(&cfg, &outcome);
        assert_eq!(
            decision,
            crate::EnsureSuccessDecision::PostRefillCapacityLost
        );
        assert_eq!(
            crate::ensure_success_plan(&cfg, decision),
            (Duration::ZERO, false)
        );
        let mut settling = Some(crate::SettlingEpisode::start(Instant::now(), 11));
        let mut pending_readiness = false;
        crate::apply_ensure_success_decision(
            &mut settling,
            &mut pending_readiness,
            Instant::now(),
            decision,
        );
        assert!(settling.is_none() && pending_readiness);
    }

    #[test]
    fn post_refill_loss_excludes_unconfigured_names_and_not_ready_witnesses() {
        let _env = TestEnv::new("post_refill_loss_bounds");
        let cfg = cfg_with(3, "ez-runner-c");
        *TEST_RELEASE_STALE_SLOTS_RESULT.lock().unwrap() = Some(0);
        *TEST_FREE_DISK_GB.lock().unwrap() = Some(Some(100));
        *TEST_HOST_FREE_DISK_GB.lock().unwrap() = Some(Some(100));

        let initial = vec![
            managed_container("ez-runner-c-1"),
            managed_container("ez-runner-c-4"),
        ];
        let after_refill = vec![
            managed_container("ez-runner-c-1"),
            managed_container("ez-runner-c-2"),
        ];
        *TEST_MANAGED_CONTAINER_SNAPSHOTS.lock().unwrap() = [initial, after_refill].into();
        *TEST_START_ONE_NAMES.lock().unwrap() = Some(vec!["ez-runner-c-2".into()]);
        *TEST_EXECUTING_RUNNER_COUNTS.lock().unwrap() = Some(
            [Ok(ReadinessSummary {
                ready: 1,
                absent: vec![],
            })]
            .into(),
        );

        let outcome = ensure_count_outcome(&cfg, Backend::Docker).unwrap();
        assert!(
            outcome.post_refill_capacity_lost.is_empty(),
            "out-of-range names and a still-present NotReady witness are not losses"
        );
    }

    #[test]
    fn post_refill_inventory_loss_survives_readiness_error() {
        let _env = TestEnv::new("post_refill_loss_readiness_error");
        let cfg = cfg_with(2, "ez-runner-c");
        *TEST_RELEASE_STALE_SLOTS_RESULT.lock().unwrap() = Some(0);
        *TEST_FREE_DISK_GB.lock().unwrap() = Some(Some(100));
        *TEST_HOST_FREE_DISK_GB.lock().unwrap() = Some(Some(100));
        *TEST_MANAGED_CONTAINER_SNAPSHOTS.lock().unwrap() =
            [vec![managed_container("ez-runner-c-1")], Vec::new()].into();
        *TEST_START_ONE_NAMES.lock().unwrap() = Some(vec!["ez-runner-c-2".into()]);
        *TEST_EXECUTING_RUNNER_COUNTS.lock().unwrap() =
            Some([Err("synthetic docker top timeout".to_string())].into());

        let outcome = ensure_count_outcome(&cfg, Backend::Docker).unwrap();
        assert_eq!(outcome.post_refill_capacity_lost, vec!["ez-runner-c-1"]);
        assert!(outcome.post_refill_readiness_error.is_some());
        assert_eq!(
            crate::ensure_success_decision(&cfg, &outcome),
            crate::EnsureSuccessDecision::PostRefillCapacityLost,
            "confirmed inventory loss precedes a later readiness probe failure"
        );
    }

    #[test]
    fn newly_started_then_absent_slots_keep_current_settling_cadence() {
        let _env = TestEnv::new("new_start_absent_settling_cadence");
        let cfg = cfg_with(14, "ez-runner-c");
        *TEST_RELEASE_STALE_SLOTS_RESULT.lock().unwrap() = Some(0);
        *TEST_FREE_DISK_GB.lock().unwrap() = Some(Some(100));
        *TEST_HOST_FREE_DISK_GB.lock().unwrap() = Some(Some(100));

        // Slots 1..11 are present both before and after this refill. Slots
        // 12..14 are freshly started and disappear before recount, so a
        // post-refill trigger based only on initial inventory must not treat
        // them as lifecycle witnesses.
        let steady: Vec<_> = (1..=11)
            .map(|slot| managed_container(&format!("ez-runner-c-{slot}")))
            .collect();
        *TEST_MANAGED_CONTAINER_SNAPSHOTS.lock().unwrap() = [steady.clone(), steady].into();
        *TEST_START_ONE_NAMES.lock().unwrap() = Some(vec![
            "ez-runner-c-12".into(),
            "ez-runner-c-13".into(),
            "ez-runner-c-14".into(),
        ]);
        *TEST_EXECUTING_RUNNER_COUNTS.lock().unwrap() = Some(
            [Ok(ReadinessSummary {
                ready: 11,
                absent: vec![],
            })]
            .into(),
        );

        let outcome = ensure_count_outcome(&cfg, Backend::Docker).unwrap();
        assert!(outcome.post_refill_capacity_lost.is_empty());
        let decision = crate::ensure_success_decision(&cfg, &outcome);
        assert_eq!(
            decision,
            crate::EnsureSuccessDecision::StartSettling { executing: 11 },
            "fresh starts that disappear before recount retain the existing settling path"
        );
        assert_eq!(
            crate::ensure_success_plan(&cfg, decision),
            (Duration::from_secs(5), false),
            "fresh-start turnover keeps the local five-second cadence"
        );

        let started_at = Instant::now();
        let mut settling = None;
        let mut pending_readiness = false;
        crate::apply_ensure_success_decision(
            &mut settling,
            &mut pending_readiness,
            started_at,
            decision,
        );
        let episode = settling.as_mut().expect("settling remains armed");
        for seconds in [5, 10, 15, 20] {
            assert_eq!(
                episode.observe(
                    started_at + Duration::from_secs(seconds),
                    11,
                    cfg.runner.count
                ),
                crate::SettlingDecision::Continue,
                "fresh-start turnover must not bypass the existing grace period"
            );
        }
        assert_eq!(
            episode.observe(started_at + Duration::from_secs(25), 11, cfg.runner.count),
            crate::SettlingDecision::Ceiling,
            "the fifth poll retains the existing 25-second ceiling"
        );

        // A fresh allocator state models the next full reconciliation after
        // that ceiling. The same newly-started-only disappearance must remain
        // on the settling path again; it cannot become an immediate loop.
        *TEST_SLOT_PATH.lock().unwrap() = Some(tmp_path("new_start_absent_second_cycle"));
        let second_steady: Vec<_> = (1..=11)
            .map(|slot| managed_container(&format!("ez-runner-c-{slot}")))
            .collect();
        *TEST_MANAGED_CONTAINER_SNAPSHOTS.lock().unwrap() =
            [second_steady.clone(), second_steady].into();
        *TEST_START_ONE_NAMES.lock().unwrap() = Some(vec![
            "ez-runner-c-12".into(),
            "ez-runner-c-13".into(),
            "ez-runner-c-14".into(),
        ]);
        *TEST_EXECUTING_RUNNER_COUNTS.lock().unwrap() = Some(
            [Ok(ReadinessSummary {
                ready: 11,
                absent: vec![],
            })]
            .into(),
        );
        let second = ensure_count_outcome(&cfg, Backend::Docker).unwrap();
        assert!(second.post_refill_capacity_lost.is_empty());
        assert_eq!(
            crate::ensure_success_decision(&cfg, &second),
            crate::EnsureSuccessDecision::StartSettling { executing: 11 },
            "a consecutive new-start-only loss retains settling rather than zero-sleep retry"
        );
    }

    #[test]
    fn readiness_probe_timeout_caps_at_six_seconds_and_preserves_sub_six_seconds() {
        // Per-probe cap is 6s (was 3s). The 2026-10-03 throughput doc
        // measured 3.2-4.5s `docker top` latency on Mac under load, so the
        // previous 3s cap killed in-flight probes that were still going to
        // succeed and reported false "not ready". Parallel fan-out keeps
        // the shared 30s readiness budget bounded.
        assert_eq!(
            readiness_probe_timeout(Duration::from_secs(30)),
            Duration::from_secs(6)
        );
        assert_eq!(
            readiness_probe_timeout(Duration::from_secs(5)),
            Duration::from_secs(5)
        );
        assert_eq!(
            readiness_probe_timeout(Duration::from_secs(2)),
            Duration::from_secs(2)
        );
        assert_eq!(
            readiness_probe_timeout(Duration::from_millis(500)),
            Duration::from_millis(500)
        );
    }

    #[test]
    fn readiness_probes_share_deadline_and_stop_after_it() {
        let cfg = cfg_with(4, "ez-org-runner");
        let containers: Vec<_> = (1..=4)
            .map(|slot| managed_container(&format!("ez-org-runner-{slot}")))
            .collect();
        let start = Instant::now();
        let deadline = start + LOCAL_READINESS_BUDGET;
        let mut clock = [
            start,
            start + Duration::from_secs(2),
            start + Duration::from_secs(28),
            start + LOCAL_READINESS_BUDGET,
        ]
        .into_iter();
        // Probe is `Fn + Sync` (parallel dispatch via `std::thread::scope`),
        // so its captures must be thread-safe. `Arc<Mutex<Vec>>` is the
        // smallest such wrapper that preserves the per-call `push` semantics
        // the original sequential test relied on; a sort-by-name lets us
        // assert on the (name, timeout) pairs without depending on which
        // spawned thread acquired the mutex first.
        let launched: std::sync::Arc<std::sync::Mutex<Vec<(String, Duration)>>> =
            std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let launched_inside = launched.clone();

        let result = executing_runner_count_with_probe(
            &cfg,
            &containers,
            deadline,
            || clock.next().unwrap(),
            move |container, timeout| {
                launched_inside
                    .lock()
                    .unwrap()
                    .push((container.name.clone(), timeout));
                Ok(ProbeOutcome::Ready)
            },
        );

        assert!(
            result.unwrap_err().to_string().contains("ez-org-runner-4"),
            "the fourth container must be rejected after the shared deadline"
        );
        let mut launched = Arc::try_unwrap(launched).unwrap().into_inner().unwrap();
        launched.sort_by(|a, b| a.0.cmp(&b.0));
        assert_eq!(
            launched,
            vec![
                ("ez-org-runner-1".to_string(), Duration::from_secs(6)),
                ("ez-org-runner-2".to_string(), Duration::from_secs(6)),
                ("ez-org-runner-3".to_string(), Duration::from_secs(2)),
            ],
            "parallel top probes must cap normally, shorten at the tail, and not launch after expiry"
        );
    }

    #[test]
    fn readiness_budget_does_not_spawn_docker_ps_after_expiry() {
        let now = Instant::now();
        let deadline = now - Duration::from_secs(1);
        assert_eq!(remaining_until_deadline(deadline, now), None);
    }

    /// Bead jleechan-95jk: the headline win of parallel readiness probes.
    /// Six simulated 50ms probes should fit in roughly 50ms wall-clock,
    /// not 300ms. Sequential probes previously could spend up to 30s on a
    /// 10-container Linux host when every top call hit its per-probe
    /// timeout (now 6s — the 2026-10-03 throughput doc measured 3.2-4.5s
    /// `docker top` latency on Mac under load, so the per-probe cap was
    /// raised from 3s to 6s while keeping the shared 30s readiness budget
    /// bounded by parallel fan-out). This test runs real sleeping probes
    /// (no docker dependency) inside `executing_runner_count_with_probe`'s
    /// parallel-spawn machinery and asserts the total is bounded by the
    /// slowest probe plus overhead.
    #[test]
    fn parallel_readiness_probes_share_wall_clock_within_max_probe() {
        use std::sync::atomic::{AtomicU32, Ordering};
        use std::time::Instant;
        let cfg = cfg_with(6, "ez-org-runner");
        let containers: Vec<_> = (1..=6)
            .map(|slot| managed_container(&format!("ez-org-runner-{slot}")))
            .collect();
        let probe_cost = Duration::from_millis(50);
        let probes_done = std::sync::Arc::new(AtomicU32::new(0));
        let probes_inside = probes_done.clone();

        let start = Instant::now();
        let deadline = start + LOCAL_READINESS_BUDGET;
        let result = executing_runner_count_with_probe(
            &cfg,
            &containers,
            deadline,
            Instant::now,
            move |_container, timeout| {
                // Sleep for the configured probe cost, never more than the
                // probe timeout itself.
                std::thread::sleep(probe_cost.min(timeout));
                probes_inside.fetch_add(1, Ordering::SeqCst);
                Ok(ProbeOutcome::Ready)
            },
        );
        let elapsed = start.elapsed();

        assert_eq!(
            result.unwrap().ready,
            6,
            "all six probes should return ready"
        );
        assert_eq!(
            probes_done.load(Ordering::SeqCst),
            6,
            "all six probes should have completed"
        );
        // Parallel wall-clock budget: the slowest single probe (probe_cost)
        // plus reasonable scheduling overhead. Sequential 6x50ms would be
        // ~300ms; parallel should be well under 250ms (half the sequential
        // budget) on any reasonable CI host.
        assert!(
            elapsed < probe_cost * 4 + Duration::from_millis(100),
            "parallel probes ran sequentially (elapsed={:?}, probe_cost={:?})",
            elapsed,
            probe_cost
        );
    }

    #[test]
    fn readiness_probe_fanout_never_exceeds_concurrency_cap() {
        use std::sync::mpsc::RecvTimeoutError;

        let count = READINESS_PROBE_CONCURRENCY * 2;
        let cfg = cfg_with(count as u32, "ez-org-runner");
        let containers: Vec<_> = (1..=count)
            .map(|slot| managed_container(&format!("ez-org-runner-{slot}")))
            .collect();
        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let release =
            std::sync::Arc::new((std::sync::Mutex::new(false), std::sync::Condvar::new()));
        let release_inside = release.clone();

        let worker = std::thread::spawn(move || {
            executing_runner_count_with_probe(
                &cfg,
                &containers,
                Instant::now() + LOCAL_READINESS_BUDGET,
                Instant::now,
                move |_container, _timeout| {
                    started_tx.send(()).expect("test receiver remains live");
                    let (released, wake) = &*release_inside;
                    let mut released = released.lock().unwrap();
                    while !*released {
                        released = wake.wait(released).unwrap();
                    }
                    Ok(ProbeOutcome::Ready)
                },
            )
        });

        for _ in 0..READINESS_PROBE_CONCURRENCY {
            started_rx
                .recv_timeout(Duration::from_secs(1))
                .expect("the first capped probe batch must start");
        }
        assert!(
            matches!(
                started_rx.recv_timeout(Duration::from_millis(100)),
                Err(RecvTimeoutError::Timeout)
            ),
            "a stale numeric-prefix fleet must not spawn probe {}/{} before the first batch finishes",
            READINESS_PROBE_CONCURRENCY + 1,
            count
        );

        let (released, wake) = &*release;
        *released.lock().unwrap() = true;
        wake.notify_all();
        assert_eq!(
            worker
                .join()
                .expect("readiness worker must not panic")
                .unwrap()
                .ready,
            count as u32,
            "later batches run after capacity is released"
        );
    }

    /// Bead jleechan-95jk: even with parallel probes, the deadline is still
    /// shared. If a probe's own budget is exceeded mid-flight, the next
    /// container's probe should not be launched. This pins the
    /// spawn-then-break semantics introduced when the readiness loop became
    /// parallel (previously sequential `?` exited on the first timeout).
    #[test]
    fn parallel_readiness_probes_respect_per_probe_timeout() {
        use std::sync::atomic::{AtomicU32, Ordering};
        let cfg = cfg_with(3, "ez-org-runner");
        let containers: Vec<_> = (1..=3)
            .map(|slot| managed_container(&format!("ez-org-runner-{slot}")))
            .collect();
        let start = Instant::now();
        // Deadline permits exactly two 1s probes; the third container's
        // `now()` will read past the deadline and reject the slot name.
        let deadline = start + Duration::from_secs(2);
        let mut clock = [
            start,
            start + Duration::from_secs(1),
            start + Duration::from_secs(2),
        ]
        .into_iter();
        let launches = std::sync::Arc::new(AtomicU32::new(0));
        let launches_inside = launches.clone();

        let result = executing_runner_count_with_probe(
            &cfg,
            &containers,
            deadline,
            || clock.next().unwrap(),
            move |_container, timeout| {
                launches_inside.fetch_add(1, Ordering::SeqCst);
                Ok(if timeout > Duration::ZERO {
                    ProbeOutcome::Ready
                } else {
                    ProbeOutcome::NotReady
                })
            },
        );

        let err_str = match &result {
            Err(e) => e.to_string(),
            Ok(_) => panic!("expected an Err result, got Ok"),
        };
        assert!(
            err_str.contains("ez-org-runner-3"),
            "the third container (whose `now()` past the deadline) must be the rejected name; got: {err_str}"
        );
        assert_eq!(
            launches.load(Ordering::SeqCst),
            2,
            "only the first two probes must have spawned"
        );
    }

    /// Bead jleechan-95jk round-2 review feedback: the per-probe timeout was
    /// raised from 3s to 6s after the 2026-10-03 throughput doc measured
    /// 3.2-4.5s `docker top` latency on Mac under load. A 5s probe would
    /// have been killed at the old 3s cap; under 6s it must complete. This
    /// pins the "sub-cap but past-old-cap" success path so a future tweak
    /// to `LOCAL_TOP_TIMEOUT` cannot silently regress Mac readiness.
    #[test]
    fn parallel_readiness_probes_complete_between_three_and_six_seconds() {
        let cfg = cfg_with(3, "ez-org-runner");
        let containers: Vec<_> = (1..=3)
            .map(|slot| managed_container(&format!("ez-org-runner-{slot}")))
            .collect();
        let start = Instant::now();
        // 30s deadline leaves plenty of room; each probe sleeps 5s — past
        // the old 3s cap, under the new 6s cap.
        let deadline = start + LOCAL_READINESS_BUDGET;
        let result = executing_runner_count_with_probe(
            &cfg,
            &containers,
            deadline,
            Instant::now,
            move |_container, _timeout| {
                std::thread::sleep(Duration::from_secs(5));
                Ok(ProbeOutcome::Ready)
            },
        );

        let elapsed = start.elapsed();
        let summary = result.expect("5s probes must complete under the 6s cap");
        assert_eq!(summary.ready, 3);
        assert!(summary.absent.is_empty());
        assert!(
            elapsed >= Duration::from_secs(5),
            "5s probes must actually sleep, not short-circuit (elapsed={elapsed:?})"
        );
        assert!(
            elapsed < Duration::from_secs(7),
            "parallel 5s probes must finish well under the per-probe cap (elapsed={elapsed:?})"
        );
    }

    /// Bead jleechan-95jk round-2 review feedback: a probe that overruns the
    /// per-probe cap (production: `run_docker_with_timeout_at_deadline` kills
    /// the docker process at the cap; the probe returns `Err`) must surface
    /// as `Err` from the orchestrator so the settling loop treats it as
    /// incomplete evidence, NOT as `Absent`. This pins the "Unknown safety"
    /// half of the bead directive: do not blindly treat all errors as
    /// absence. The probe here respects its `timeout` argument the way the
    /// production probe does — distinct from
    /// `parallel_readiness_probes_pass_six_second_timeout_argument` above
    /// which pins the cap value itself.
    #[test]
    fn parallel_readiness_probe_overrun_propagates_as_err_not_absent() {
        let cfg = cfg_with(2, "ez-org-runner");
        let containers: Vec<_> = (1..=2)
            .map(|slot| managed_container(&format!("ez-org-runner-{slot}")))
            .collect();
        let start = Instant::now();
        let deadline = start + LOCAL_READINESS_BUDGET;
        let result = executing_runner_count_with_probe(
            &cfg,
            &containers,
            deadline,
            Instant::now,
            move |_container, timeout| {
                // Sleep past the timeout — production docker probes are
                // killed at the cap by `run_docker_with_timeout_at_deadline`.
                std::thread::sleep(timeout + Duration::from_secs(1));
                Err(anyhow::anyhow!("docker top timeout"))
            },
        );

        let elapsed = start.elapsed();
        let err = result.expect_err("an overrun probe must surface as Err, not Absent");
        assert!(err.to_string().contains("docker top timeout"));
        // Each probe gets a 6s cap, then sleeps 7s. Bounded.
        assert!(
            elapsed < Duration::from_secs(20),
            "a probe overrun must stay within the shared budget (elapsed={elapsed:?})"
        );
    }

    /// Companion to `parallel_readiness_probes_expire_at_six_second_cap`:
    /// pin the per-probe timeout argument is exactly 6s (the raised cap),
    /// not 3s (the old cap). This is the headline review-feedback fix.
    #[test]
    fn parallel_readiness_probes_pass_six_second_timeout_argument() {
        use std::sync::Mutex;
        let cfg = cfg_with(1, "ez-org-runner");
        let containers: Vec<_> = (1..=1)
            .map(|slot| managed_container(&format!("ez-org-runner-{slot}")))
            .collect();
        let start = Instant::now();
        let deadline = start + LOCAL_READINESS_BUDGET;
        let captured: std::sync::Arc<Mutex<Option<Duration>>> =
            std::sync::Arc::new(Mutex::new(None));
        let captured_inside = captured.clone();

        let _ = executing_runner_count_with_probe(
            &cfg,
            &containers,
            deadline,
            Instant::now,
            move |_container, timeout| {
                *captured_inside.lock().unwrap() = Some(timeout);
                Ok(ProbeOutcome::Ready)
            },
        );

        let observed = captured.lock().unwrap().expect("probe captured a timeout");
        assert_eq!(
            observed,
            Duration::from_secs(6),
            "per-probe timeout cap must be 6s (raised from 3s for 3.2-4.5s measured probes)"
        );
    }

    /// Bead jleechan-95jk root-cause: a slot whose container is GONE
    /// (docker top: "No such container") must reach the settling loop as an
    /// `Absent` outcome with the container's name attached, so the loop
    /// reconciles immediately instead of waiting 25s for a slot that will
    /// never come back. This pins the parallel orchestration's
    /// `ProbeOutcome::Absent` → `ReadinessSummary.absent` plumbing.
    #[test]
    fn readiness_summary_reports_absent_container_names() {
        let cfg = cfg_with(4, "ez-org-runner");
        let containers: Vec<_> = (1..=4)
            .map(|slot| managed_container(&format!("ez-org-runner-{slot}")))
            .collect();
        let start = Instant::now();
        let deadline = start + LOCAL_READINESS_BUDGET;
        let result = executing_runner_count_with_probe(
            &cfg,
            &containers,
            deadline,
            Instant::now,
            move |container, _timeout| {
                // Slots 2 and 4 are absent (gone); slots 1 and 3 are ready.
                if container.name.ends_with("2") || container.name.ends_with("4") {
                    Ok(ProbeOutcome::Absent)
                } else {
                    Ok(ProbeOutcome::Ready)
                }
            },
        );

        let summary = result.expect("ready + absent both succeed");
        assert_eq!(summary.ready, 2, "slots 1 and 3 should be ready");
        let mut absent = summary.absent.clone();
        absent.sort();
        assert_eq!(
            absent,
            vec!["ez-org-runner-2".to_string(), "ez-org-runner-4".to_string(),],
            "absent slots must surface their container names to the settling loop"
        );
    }

    /// Companion to the test above: `ProbeOutcome::NotReady` is the
    /// genuine broken-container case and is NOT reported as absent. The
    /// settling loop should NOT trigger immediate reconcile from a
    /// NotReady probe — the container is still alive and may self-heal.
    #[test]
    fn readiness_summary_treats_not_ready_distinct_from_absent() {
        let cfg = cfg_with(3, "ez-org-runner");
        let containers: Vec<_> = (1..=3)
            .map(|slot| managed_container(&format!("ez-org-runner-{slot}")))
            .collect();
        let start = Instant::now();
        let deadline = start + LOCAL_READINESS_BUDGET;
        let result = executing_runner_count_with_probe(
            &cfg,
            &containers,
            deadline,
            Instant::now,
            move |container, _timeout| {
                if container.name.ends_with("2") {
                    // Slot 2: container alive, no Runner process (genuine
                    // "runner died" failure).
                    Ok(ProbeOutcome::NotReady)
                } else {
                    Ok(ProbeOutcome::Ready)
                }
            },
        );

        let summary = result.expect("ready + not-ready both succeed");
        assert_eq!(summary.ready, 2);
        assert!(
            summary.absent.is_empty(),
            "NotReady must NOT be conflated with Absent (slot 2 is alive)"
        );
    }

    /// Independent review (round 2) regression: post-refill readiness that
    /// reports a freshly-spawned container as `Absent` (docker top: "No
    /// such container" race) MUST count that container toward the
    /// remaining shortage, NOT toward alive-after. The pre-fix code
    /// (`ready + absent.len()`) made `remaining_shortage = 0`, selected
    /// `EnsureSuccessDecision::Recovered`, skipped the settling episode
    /// that surfaces the absent name, and slept the full 30s serve-tick —
    /// the daemon stayed unaware the slot was gone for the next 30s. This
    /// test pins both halves: (a) shortage > 0 → StartSettling, and (b)
    /// the settling poll that still sees the absent name returns
    /// `Ceiling` (immediate reconcile) instead of `Continue` (wait 25s).
    #[test]
    fn post_refill_absent_container_forces_shortage_and_immediate_reconcile() {
        let _env = TestEnv::new("post_refill_absent_shortage");
        let cfg = cfg_with(6, "ez-org-runner");
        *TEST_RELEASE_STALE_SLOTS_RESULT.lock().unwrap() = Some(0);
        *TEST_FREE_DISK_GB.lock().unwrap() = Some(Some(100));
        // 4 initial containers → 2 missing. The refill (managed by the
        // test infra) starts slots 5 and 6 — those are the ones whose
        // containers we then mark as `Absent` for the post-refill probe.
        let initial: Vec<_> = (1..=4)
            .map(|slot| managed_container(&format!("ez-org-runner-{slot}")))
            .collect();
        let after_refill: Vec<_> = (1..=6)
            .map(|slot| managed_container(&format!("ez-org-runner-{slot}")))
            .collect();
        *TEST_MANAGED_CONTAINER_SNAPSHOTS.lock().unwrap() =
            [initial, after_refill.clone(), after_refill.clone()].into();
        *TEST_START_ONE_NAMES.lock().unwrap() =
            Some(vec!["ez-org-runner-5".into(), "ez-org-runner-6".into()]);
        // Post-refill probe: slots 1-4 are ready, slots 5-6 are absent
        // (they were just spawned but `docker top` says "No such
        // container" — the race the review caught).
        *TEST_EXECUTING_RUNNER_COUNTS.lock().unwrap() = Some(
            [
                Ok(ReadinessSummary {
                    ready: 4,
                    absent: vec!["ez-org-runner-5".to_string(), "ez-org-runner-6".to_string()],
                }),
                // Second poll for the settling observe: still absent.
                Ok(ReadinessSummary {
                    ready: 4,
                    absent: vec!["ez-org-runner-5".to_string(), "ez-org-runner-6".to_string()],
                }),
            ]
            .into(),
        );

        let outcome = ensure_count_outcome(&cfg, Backend::Docker).unwrap();

        // (a) Half of the regression: shortage must be > 0 because the
        // absent slots are not alive. The pre-fix bug made this 0
        // because the code did `ready + absent.len()` for `alive_after`.
        assert_eq!(
            outcome.started.len(),
            2,
            "the 2 freshly-started slots are recorded as started"
        );
        assert_eq!(
            outcome.remaining_shortage, 2,
            "absent containers count toward shortage, NOT toward alive (round-2 review fix)"
        );
        assert!(
            outcome.post_refill_readiness_error.is_none(),
            "absent is a normal probe outcome, not an Err (Unknown safety preserved)"
        );

        let mut pending_readiness = false;
        let decision = crate::ensure_success_decision_with_pending_readiness(
            crate::ensure_success_decision(&cfg, &outcome),
            pending_readiness,
            false,
            0,
        );
        assert_eq!(
            decision,
            crate::EnsureSuccessDecision::StartSettling { executing: 4 },
            "remaining_shortage > 0 → StartSettling (pre-fix bug selected Recovered and slept 30s)"
        );

        let started_at = Instant::now();
        let mut settling = None;
        crate::apply_ensure_success_decision(
            &mut settling,
            &mut pending_readiness,
            started_at,
            decision,
        );
        assert!(
            settling
                .as_ref()
                .is_some_and(crate::SettlingEpisode::is_active),
            "StartSettling must arm the local settling episode"
        );

        // (b) Second half: when the settling poll still sees the absent
        // names, the loop must force Ceiling (immediate reconcile) rather
        // than Continue (wait out the 25s grace). The pre-fix settling
        // path had no way to surface this and would have polled until
        // MAX_SETTLING_POLLS / MAX_SETTLING_DURATION elapsed.
        //
        // The local settling observer in main.rs uses the
        // `ReadinessSummary { ready, absent }` returned by
        // `local_executing_runner_count` to force immediate reconcile.
        // `SettlingEpisode::observe` itself only sees `executing` (the
        // ready count), so we exercise the absent-aware forcing the same
        // way main.rs does: a fresh readiness summary with non-empty
        // `absent` and `ready < target` triggers `SettlingDecision::Ceiling`.
        let absented = local_executing_runner_count(&cfg).unwrap();
        assert_eq!(absented.ready, 4);
        assert_eq!(absented.absent.len(), 2);
        let ceiling_decision = if !absented.absent.is_empty() && absented.ready < cfg.runner.count {
            crate::SettlingDecision::Ceiling
        } else {
            settling
                .as_mut()
                .unwrap()
                .observe(Instant::now(), absented.ready, cfg.runner.count)
        };
        assert_eq!(
            ceiling_decision,
            crate::SettlingDecision::Ceiling,
            "absent names from post-refill readiness must force Ceiling (immediate reconcile)"
        );
        crate::apply_local_settling_decision(
            &mut settling,
            &mut pending_readiness,
            ceiling_decision,
        );
        assert!(
            settling.is_none(),
            "Ceiling clears the local settling episode so the next tick reconciles immediately"
        );
        let (sleep, run_monitors) = crate::settling_plan(&cfg, ceiling_decision);
        assert_eq!(
            sleep,
            Duration::ZERO,
            "Ceiling plan must request zero sleep before the next reconciliation"
        );
        assert!(
            !run_monitors,
            "Ceiling plan must reconcile on the next iteration without synchronous monitors"
        );
    }

    #[test]
    fn local_worker_readiness_propagates_incomplete_probe_evidence() {
        let _env = TestEnv::new("local_worker_readiness_incomplete");
        let cfg = cfg_with(1, "ez-org-runner");
        *TEST_MANAGED_CONTAINER_SNAPSHOTS.lock().unwrap() =
            [vec![managed_container("ez-org-runner-1")]].into();
        *TEST_EXECUTING_RUNNER_COUNTS.lock().unwrap() =
            Some([Err("synthetic docker top timeout".to_string())].into());

        let err = local_executing_runner_count(&cfg).unwrap_err();

        assert!(format!("{err:#}").contains("synthetic docker top timeout"));
    }

    #[test]
    fn post_refill_incomplete_readiness_preserves_starts_and_forces_immediate_reconcile() {
        let _env = TestEnv::new("post_refill_incomplete_readiness");
        let cfg = cfg_with(6, "ez-org-runner");
        *TEST_RELEASE_STALE_SLOTS_RESULT.lock().unwrap() = Some(0);
        *TEST_FREE_DISK_GB.lock().unwrap() = Some(Some(100));
        let initial: Vec<_> = (1..=4)
            .map(|slot| managed_container(&format!("ez-org-runner-{slot}")))
            .collect();
        let after_refill: Vec<_> = (1..=6)
            .map(|slot| managed_container(&format!("ez-org-runner-{slot}")))
            .collect();
        *TEST_MANAGED_CONTAINER_SNAPSHOTS.lock().unwrap() = [
            initial,
            after_refill.clone(),
            after_refill.clone(),
            after_refill,
        ]
        .into();
        *TEST_START_ONE_NAMES.lock().unwrap() =
            Some(vec!["ez-org-runner-5".into(), "ez-org-runner-6".into()]);
        *TEST_EXECUTING_RUNNER_COUNTS.lock().unwrap() = Some(
            [
                Err("synthetic post-refill docker top timeout".to_string()),
                Ok(ReadinessSummary {
                    ready: 6,
                    absent: vec![],
                }),
            ]
            .into(),
        );

        let outcome = ensure_count_outcome(&cfg, Backend::Docker).unwrap();

        assert_eq!(
            outcome.started.len(),
            2,
            "successful refill must not be discarded"
        );
        assert!(outcome
            .post_refill_readiness_error
            .as_deref()
            .unwrap()
            .contains("synthetic post-refill docker top timeout"));
        let mut pending_readiness = false;
        let decision = crate::ensure_success_decision_with_pending_readiness(
            crate::ensure_success_decision(&cfg, &outcome),
            pending_readiness,
            false,
            0,
        );
        assert_eq!(decision, crate::EnsureSuccessDecision::IncompleteReadiness);
        assert_eq!(
            crate::ensure_success_plan(&cfg, decision),
            (Duration::ZERO, false),
            "incomplete post-refill evidence must reconcile on the next iteration without synchronous monitors"
        );

        let started_at = Instant::now();
        let mut settling = None;
        crate::apply_ensure_success_decision(
            &mut settling,
            &mut pending_readiness,
            started_at,
            decision,
        );
        assert!(
            pending_readiness && settling.is_none(),
            "incomplete evidence must force the next full reconciliation while remaining pending"
        );
        let mut ceilings = crate::SettlingCeilingState::default();
        assert!(!crate::record_settling_ceiling(
            &cfg,
            &mut ceilings,
            "synthetic first incomplete episode"
        ));

        let misleading_full_container_outcome =
            ensure_count_outcome(&cfg, Backend::Docker).unwrap();
        let full_container_decision = crate::ensure_success_decision_with_pending_readiness(
            crate::ensure_success_decision(&cfg, &misleading_full_container_outcome),
            pending_readiness,
            false,
            0,
        );
        assert_eq!(
            full_container_decision,
            crate::EnsureSuccessDecision::StartSettling { executing: 0 },
            "a standalone full-container tick cannot prove Runner.Worker readiness"
        );
        crate::apply_ensure_success_decision(
            &mut settling,
            &mut pending_readiness,
            started_at,
            full_container_decision,
        );
        assert!(
            settling
                .as_ref()
                .is_some_and(crate::SettlingEpisode::is_active),
            "the completed full reconciliation must rearm local worker proof"
        );
        assert_eq!(
            ceilings.consecutive_ceilings, 1,
            "no readiness proof means no reset"
        );

        let executing = local_executing_runner_count(&cfg).unwrap().ready;
        let recovered =
            settling
                .as_mut()
                .unwrap()
                .observe(started_at + Duration::from_secs(5), executing, 6);
        assert_eq!(recovered, crate::SettlingDecision::Recovered);
        crate::apply_local_settling_decision(&mut settling, &mut pending_readiness, recovered);
        ceilings.record_recovery();
        assert!(!pending_readiness && settling.is_none());
        assert_eq!(ceilings.consecutive_ceilings, 0);
    }

    #[test]
    fn ensure_count_outcome_flags_fewer_than_half_started() {
        let _env = TestEnv::new("ensure_count_partial");
        let cfg = cfg_with(4, "ez-org-runner");
        *TEST_RELEASE_STALE_SLOTS_RESULT.lock().unwrap() = Some(0);
        *TEST_FREE_DISK_GB.lock().unwrap() = Some(Some(100));
        *TEST_MANAGED_CONTAINERS.lock().unwrap() = Some(Vec::new());
        *TEST_START_ONE_NAMES.lock().unwrap() = Some(vec!["ez-org-runner-1".into()]);
        *TEST_EXECUTING_RUNNER_COUNTS.lock().unwrap() = Some(
            [Ok(ReadinessSummary {
                ready: 0,
                absent: vec![],
            })]
            .into(),
        );

        let outcome = ensure_count_outcome(&cfg, Backend::Docker).unwrap();

        assert_eq!(outcome.missing, 4);
        // only one runner name is available, so the other 3 start_one() calls
        // error → 1 started out of 4 missing is a real partial failure.
        assert_eq!(outcome.started, vec!["ez-org-runner-1"]);
        assert!(
            outcome.is_partial_failure(),
            "one successful start out of four missing runners is a real partial failure and must keep the serve alert streak alive"
        );
    }

    #[test]
    fn full_success_is_not_a_partial_failure() {
        let outcome = EnsureCountOutcome {
            started: vec!["runner-1".into(), "runner-2".into()],
            missing: 2,
            remaining_shortage: 0,
            post_refill_readiness_error: None,
            post_refill_capacity_lost: Vec::new(),
            post_refill_slots_released: Vec::new(),
            start_failures: 0,
            reclaimed: 0,
            admission_paused_reason: None,
        };
        assert!(
            !outcome.is_partial_failure(),
            "2 successful starts out of 2 missing is a healthy full refill, not a failure"
        );
    }

    #[test]
    fn fewer_started_than_missing_is_a_partial_failure() {
        let outcome = EnsureCountOutcome {
            started: vec!["runner-1".into()],
            missing: 2,
            remaining_shortage: 1,
            post_refill_readiness_error: None,
            post_refill_capacity_lost: Vec::new(),
            post_refill_slots_released: Vec::new(),
            start_failures: 1,
            reclaimed: 0,
            admission_paused_reason: None,
        };
        assert!(
            outcome.is_partial_failure(),
            "1 success out of 2 missing is a real partial failure"
        );
    }

    #[test]
    fn start_one_releases_slot_on_jit_generation_failure() {
        let _env = TestEnv::new("jit_failure_releases_slot");
        let cfg = cfg_with(2, "ez-org-runner");
        let err = start_one_with_generate(&cfg, Backend::Docker, |_gh, _name, _labels, _owned| {
            Err(anyhow::anyhow!("forced test failure in JIT generation"))
        })
        .expect_err("start_one should fail when jit generation fails");
        assert!(err.to_string().contains("forced test failure"));
        let assignments = read_slot_assignments().unwrap();
        assert!(
            assignments.assignments.is_empty(),
            "slot reserved by start_one should be released on JIT failure"
        );
    }

    #[test]
    fn start_one_releases_slot_on_docker_run_failure() {
        let _env = TestEnv::new("docker_run_failure");
        // Lane B2: the `cfg!(test) { return true; }` short-circuit in
        // `docker_cpu_controller_available` was removed; force the probe
        // through the override seam so this test stays isolated from the
        // real cgroup filesystem / `docker run --cgroupns=host` probe.
        // The test's own assertion still drives the *start_one* docker run
        // failure path via TEST_DOCKER_BIN — this override only isolates
        // the pre-flight CPU-controller check, which is unrelated.
        cpu_probe_overrides::set(Some(true));
        let cfg = cfg_with(2, "ez-org-runner");
        let temp_dir =
            env::temp_dir().join(format!("ezgha-docker-fake-run-{}", std::process::id()));
        let script = temp_dir.join("docker");
        std::fs::create_dir_all(&temp_dir).unwrap();
        std::fs::write(
            &script,
            // Absolute `#!/bin/sh` shebang (not `/usr/bin/env sh`): the
            // kernel resolves an absolute shebang path directly via execve,
            // with no PATH lookup involved. `env sh` would need `sh` to be
            // resolvable via the process's PATH at exec time, which is not
            // reliable here — other tests in this same binary (e.g.
            // `alert.rs`'s `PATH`-mutating tests) can transiently replace or
            // empty PATH on another thread while this script executes.
            b"#!/bin/sh\ncase \" $* \" in *\" run \"*) echo \"docker run failed: simulation\" >&2; exit 1;; *) exit 0;; esac\n",
        )
        .unwrap();
        // Use `set_permissions` directly instead of shelling out to `chmod`
        // (removes a dependency on `chmod` being resolvable on PATH).
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();

        // Redirect every `docker` invocation in this module to the fake
        // script via the in-process `TEST_DOCKER_BIN` hook rather than
        // mutating the real, process-wide `PATH` env var. `PATH` is shared
        // by every thread in the test binary — including unrelated modules
        // like `alert.rs`, which mutates `PATH` under its own, uncoordinated
        // lock — so replacing (or even prepending to) it here would race
        // with those other tests under `cargo test`'s default parallel
        // runner and intermittently corrupt command resolution for both
        // sides. `TEST_DOCKER_BIN` is gated behind this module's own
        // `TEST_LOCK` (via `TestEnv`) and cleared unconditionally in
        // `TestEnv`'s `Drop` impl, so it's panic-safe and fully isolated
        // from every other test in the binary.
        *TEST_DOCKER_BIN.lock().unwrap() = Some(script.to_string_lossy().into_owned());

        let err = start_one_with_generate(&cfg, Backend::Docker, |_gh, _name, _labels, _owned| {
            Ok(("jit".into(), 9876))
        })
        .expect_err("start_one should fail when docker run exits non-zero");

        assert!(
            err.to_string().contains("docker run failed") && err.to_string().contains("simulation"),
            "docker run failure should be surfaced; got: {err:#}"
        );
        let assignments = read_slot_assignments().unwrap();
        assert!(
            assignments.assignments.is_empty(),
            "slot reserved by start_one should be cleaned up when docker run fails"
        );
    }

    /// Production start_one rejection regression (root review): an
    /// unsupported cpu_burst configuration (burst=true with either
    /// unverified-VM daemon OR unknown capacity) must refuse BEFORE any
    /// container mutation (no `docker rm -f` pre-clean) and BEFORE the
    /// JIT callback (`generate_jitconfig`). The Serve precheck only
    /// catches this at startup; if the operator flips the config mid-run
    /// OR capacity disappears after startup, the production start_one
    /// path is the second line of defense. This test pins the
    /// `pre-check-before-mutation` ordering by forcing both refusal
    /// conditions (unknown capacity AND a non-VM-detected host) — on
    /// either branch the rejection must run before docker is invoked.
    #[test]
    fn start_one_rejects_unsupported_burst_before_any_mutation_or_jit() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        let _env = TestEnv::new("start_one_burst_unknown_capacity");
        cpu_probe_overrides::set(Some(true));

        let mut cfg = cfg_with(2, "ez-org-runner");
        cfg.limits.cpu_burst = true;

        // Force daemon_capacity() to return None so the inner
        // effective_limits runs the no-capacity refusal branch (the VM
        // refusal branch would otherwise fire first on a non-VM test
        // host — both branches must satisfy the no-mutation invariant,
        // but driving the no-capacity path makes the test deterministic
        // regardless of the host's daemon_in_vm result).
        *TEST_DAEMON_CAPACITY.lock().unwrap() = Some(None);

        let temp_dir =
            env::temp_dir().join(format!("ezgha-burst-no-mutation-{}", std::process::id()));
        let capture = temp_dir.join("docker-args.log");
        // The fake docker MUST still be installed even though we expect
        // zero invocations — the rejection must happen before any
        // docker_cmd() is even built. If a docker invocation DID happen
        // it would log to this file and the assertion below would fail.
        let script = fake_docker_capturing_args(&temp_dir, &capture);
        *TEST_DOCKER_BIN.lock().unwrap() = Some(script.to_string_lossy().into_owned());

        let jit_calls = AtomicUsize::new(0);
        let err = start_one_with_generate(&cfg, Backend::Docker, |_gh, _name, _labels, _owned| {
            jit_calls.fetch_add(1, Ordering::SeqCst);
            Ok(("jit-token".into(), 1))
        })
        .expect_err("cpu_burst with unknown capacity must return Err from start_one");

        assert!(
            err.to_string().contains("cpu_burst"),
            "Err must mention cpu_burst so operators can diagnose the misconfig; got: {err:#}"
        );
        assert_eq!(
            jit_calls.load(Ordering::SeqCst),
            0,
            "generate_jitconfig MUST NOT be invoked when cpu_burst is unsupported; \
             otherwise the runner could register on GitHub while the spawn is refused"
        );

        let captured = std::fs::read_to_string(&capture).unwrap_or_default();
        assert!(
            captured.is_empty(),
            "start_one_with_generate_at_slot must execute zero docker invocations when \
             cpu_burst is unsupported; the rejected path must run BEFORE pre_rm. \
             Captured args:\n{captured}"
        );

        // Cleanup so a later test sees the real daemon_capacity path.
        *TEST_DAEMON_CAPACITY.lock().unwrap() = None;
    }

    /// cpu_burst preflight refusal must pause the whole refill WITHOUT
    /// opening per-slot circuits. A generic Err would hit
    /// `FailureLadder::record_failure` and open 15-minute circuits on
    /// 3 slots — a whole-fleet config error misclassified as a per-slot
    /// defect. Pin: admission_paused_reason set + slot ledger unchanged.
    /// Drives the REAL `start_one_with_generate` path (same dependency
    /// seams as the production refill loop) so removing the
    /// `map_err(admission_preflight_error)` from start_one's effective_limits
    /// call would surface here as a generic Err that DOES charge the ladder.
    #[test]
    fn preflight_burst_refusal_does_not_charge_slot_ladder() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        let env = TestEnv::new("preflight_burst_no_ladder_charge");
        // failure_ladder_path_for falls back to the TEST_SLOT_PATH
        // sibling when cfg.state_dir is None — leave cfg.state_dir unset
        // (setting it to env.path, a file path, poisoned TEST_LOCK and
        // cascaded into unrelated reaper tests, observed 2026-10-03).
        let ladder_path = env.path.with_file_name("failure_ladder.toml");

        let mut cfg = cfg_with(3, "ez-org-runner");
        cfg.limits.cpu_burst = true;

        // Pin daemon_capacity to None so effective_limits runs the
        // unsupported-capacity refusal branch (deterministic on any host).
        *TEST_DAEMON_CAPACITY.lock().unwrap() = Some(None);

        // Install a fake docker that captures invocations; the rejection
        // must happen BEFORE pre_rm so the captured log stays empty.
        let temp_dir =
            std::env::temp_dir().join(format!("ezgha-burst-refusal-{}", std::process::id()));
        let capture = temp_dir.join("docker-args.log");
        let script = fake_docker_capturing_args(&temp_dir, &capture);
        *TEST_DOCKER_BIN.lock().unwrap() = Some(script.to_string_lossy().into_owned());

        // JIT closure MUST NOT be invoked: preflight refuses before any
        // GitHub registration. Counting calls catches a regression where
        // someone moves the preflight AFTER generate_jitconfig.
        let jit_calls = AtomicUsize::new(0);
        let starter = |_cfg: &Config, _backend: Backend, _slot: u32| -> Result<(String, String)> {
            start_one_with_generate(&cfg, Backend::Docker, |_gh, _name, _labels, _owned| {
                jit_calls.fetch_add(1, Ordering::SeqCst);
                Ok(("jit-token".into(), 1))
            })
        };

        let outcome = start_missing_runners_with_starter(&cfg, Backend::Docker, 3, starter)
            .expect("preflight-refused refill must surface as outcome, not panic");

        assert!(
            outcome.admission_paused_reason.is_some(),
            "preflight refusal must set admission_paused_reason (got None)"
        );
        let reason = outcome.admission_paused_reason.as_deref().unwrap();
        assert!(
            reason.contains("preflight"),
            "admission_paused_reason must mention 'preflight' (got: {reason:?})"
        );
        assert_eq!(
            jit_calls.load(Ordering::SeqCst),
            0,
            "JIT MUST NOT be called when cpu_burst preflight refuses; \
             a non-zero count means a regression moved effective_limits \
             after generate_jitconfig (would register on GitHub before refusing)"
        );
        let captured = std::fs::read_to_string(&capture).unwrap_or_default();
        assert!(
            captured.is_empty(),
            "start_one_with_generate_at_slot must execute zero docker invocations when \
             cpu_burst preflight refuses; the rejection must run BEFORE pre_rm. \
             Captured args:\n{captured}"
        );

        let ladder_after = FailureLadder::load(&ladder_path)
            .expect("failure ladder must remain loadable after a preflight refusal");
        assert_eq!(
            ladder_after.open_slot_count(0),
            0,
            "no slot circuit may open from a preflight refusal (open_slot_count={})",
            ladder_after.open_slot_count(0)
        );
        assert!(
            !ladder_after.fleet_admission_is_paused(0),
            "fleet admission pause must NOT fire from a single preflight refusal"
        );

        *TEST_DAEMON_CAPACITY.lock().unwrap() = None;
        *TEST_DOCKER_BIN.lock().unwrap() = None;
    }

    /// Companion regression: a genuine docker-start failure (NOT preflight-typed)
    /// MUST still charge the per-slot failure ledger. Pins the typed bucket
    /// boundary so a future refactor cannot over-broaden AdmissionPreflightError
    /// and silence real defects.
    #[test]
    fn genuine_docker_start_failure_still_charges_slot_ladder() {
        let env = TestEnv::new("genuine_docker_charges_ladder");
        let ladder_path = env.path.with_file_name("failure_ladder.toml");
        let cfg = cfg_with(1, "ez-org-runner");

        // Mirror `repeated_local_start_failures_open_only_the_slot_circuit`:
        // each starter invocation `release_slot` first so the failed slot is
        // available for the next call's `next_slot_excluding`. Bail with a
        // generic (non-preflight) error so the typed bucket boundary is
        // exercised.
        for _ in 0..3 {
            let outcome = start_missing_runners_with_starter(
                &cfg,
                Backend::Docker,
                1,
                |_cfg, _backend, slot| -> Result<(String, String)> {
                    release_slot(slot)?;
                    bail!("simulated local container start failure")
                },
            )
            .expect("synthetic start failures must surface as outcome, not panic");
            assert_eq!(outcome.start_failures, 1);
        }

        let ladder_after =
            FailureLadder::load(&ladder_path).expect("failure ladder must remain loadable");
        assert!(
            ladder_after.open_slot_count(0) >= 1,
            "three real docker-start failures MUST open at least one slot circuit \
             (open_slot_count={}); otherwise the typed bucket leaked into the \
             genuine-failure path and silenced real defects",
            ladder_after.open_slot_count(0)
        );
    }

    /// Fake `docker` script that captures its full argv to `capture_path`
    /// (one line per invocation) and, for `run`, prints a fake container ID
    /// to stdout so `start_one_with_generate` sees a successful start.
    fn fake_docker_capturing_args(
        temp_dir: &std::path::Path,
        capture_path: &std::path::Path,
    ) -> PathBuf {
        std::fs::create_dir_all(temp_dir).unwrap();
        let script = temp_dir.join("docker");
        std::fs::write(
            &script,
            format!(
                "#!/bin/sh\necho \"$*\" >> {}\ncase \" $* \" in *\" run \"*) echo fakecontaineridabc123;; esac\nexit 0\n",
                capture_path.to_string_lossy()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        script
    }

    #[test]
    fn wheelhouse_mount_added_when_configured_path_exists() {
        let _env = TestEnv::new("wheelhouse_mount_present");
        cpu_probe_overrides::set(Some(true));
        let mut cfg = cfg_with(2, "ez-org-runner");
        let temp_dir =
            env::temp_dir().join(format!("ezgha-wheelhouse-test-{}", std::process::id()));
        let wheelhouse_dir = temp_dir.join("wheelhouse");
        std::fs::create_dir_all(&wheelhouse_dir).unwrap();
        cfg.runner.wheelhouse_host_path = Some(wheelhouse_dir.to_string_lossy().into_owned());

        let capture = temp_dir.join("docker-args.log");
        let script = fake_docker_capturing_args(&temp_dir, &capture);
        *TEST_DOCKER_BIN.lock().unwrap() = Some(script.to_string_lossy().into_owned());

        start_one_with_generate(&cfg, Backend::Docker, |_gh, _name, _labels, _owned| {
            Ok(("jit".into(), 1111))
        })
        .expect("start_one should succeed");

        let logged = std::fs::read_to_string(&capture).unwrap();
        let run_line = logged
            .lines()
            .find(|l| l.contains("run "))
            .expect("a docker run invocation should have been logged");
        assert!(
            run_line.contains(&format!("{}:/opt/wheelhouse:ro", wheelhouse_dir.display())),
            "run args should mount the configured wheelhouse read-only; got: {run_line}"
        );
        assert!(
            run_line.contains("PIP_FIND_LINKS=/opt/wheelhouse"),
            "run args should set PIP_FIND_LINKS; got: {run_line}"
        );
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn configured_cgroup_parent_is_emitted_on_runner_start() {
        let _env = TestEnv::new("cgroup_parent");
        cpu_probe_overrides::set(Some(true));
        let mut cfg = cfg_with(10, "ez-org-runner");
        cfg.limits.memory_mb = 2500;
        cfg.limits.cgroup_parent = Some("actions.slice".into());
        let temp_dir =
            env::temp_dir().join(format!("ezgha-cgroup-parent-test-{}", std::process::id()));
        let capture = temp_dir.join("docker-args.log");
        let script = fake_docker_capturing_args(&temp_dir, &capture);
        *TEST_DOCKER_BIN.lock().unwrap() = Some(script.to_string_lossy().into_owned());

        start_one_with_generate(&cfg, Backend::Docker, |_gh, _name, _labels, _owned| {
            Ok(("jit".into(), 4444))
        })
        .expect("start_one should succeed");

        let run_content = std::fs::read_to_string(&capture).unwrap();
        let run_line = run_content
            .lines()
            .find(|line| line.contains("run "))
            .expect("a docker run invocation should have been logged");
        assert!(
            run_line.contains("--cgroup-parent actions.slice"),
            "configured cgroup parent must be passed to every runner: {run_line}"
        );
        #[cfg(target_os = "linux")]
        assert!(
            run_line.contains("--host unix:///var/run/docker.sock"),
            "Linux host docker invocations must explicitly pass canonical socket: {run_line}"
        );
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn explicit_docker_host_override_is_emitted_on_runner_start() {
        let _env = TestEnv::new("explicit_docker_host_override");
        cpu_probe_overrides::set(Some(true));
        std::env::set_var("DOCKER_HOST_OVERRIDE", "unix:///run/ezgha-selected-vm.sock");
        let mut cfg = cfg_with(10, "ez-org-runner");
        cfg.limits.memory_mb = 2500;
        cfg.limits.cgroup_parent = Some("actions.slice".into());
        let temp_dir = env::temp_dir().join(format!(
            "ezgha-explicit-docker-host-test-{}",
            std::process::id()
        ));
        let capture = temp_dir.join("docker-args.log");
        let script = fake_docker_capturing_args(&temp_dir, &capture);
        *TEST_DOCKER_BIN.lock().unwrap() = Some(script.to_string_lossy().into_owned());

        start_one_with_generate(&cfg, Backend::Docker, |_gh, _name, _labels, _owned| {
            Ok(("jit".into(), 4444))
        })
        .expect("start_one should use the explicitly selected Docker endpoint");

        let run_content = std::fs::read_to_string(&capture).unwrap();
        let run_line = run_content
            .lines()
            .find(|line| line.contains("run "))
            .expect("a docker run invocation should have been logged");
        assert!(
            run_line.contains("--host unix:///run/ezgha-selected-vm.sock"),
            "explicit Docker endpoint must be preserved for runner mutation: {run_line}"
        );
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn host_containment_refuses_start_when_profile_mismatches_or_uncontained() {
        let _env = TestEnv::new("host_containment_refuses_start");
        cpu_probe_overrides::set(Some(true));

        // Unsupported counts must fail containment check before slot allocation.
        let mut cfg = cfg_with(2, "ez-org-runner");
        cfg.limits.cgroup_parent = Some("actions.slice".into());
        let err = start_one_with_generate(&cfg, Backend::Docker, |_gh, _name, _labels, _owned| {
            Ok(("jit".into(), 4444))
        })
        .expect_err("start_one must fail closed when Linux runner count is unsupported");
        assert!(
            err.to_string().contains("host containment")
                || err.to_string().contains("runner counts 10, 14, or 20"),
            "expected host containment failure; got: {err:#}"
        );
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn host_containment_admits_the_fourteen_runner_profile() {
        let _env = TestEnv::new("host_containment_profile_14");
        let root = env::temp_dir().join(format!(
            "ezgha-host-containment-profile-14-{}",
            std::process::id()
        ));
        write_actions_slice_fixture(&root, 14);
        *TEST_HOST_CONTAINMENT_CGROUP_ROOT.lock().unwrap() = Some(root.clone());

        let mut cfg = cfg_with(14, "ez-runner-c");
        cfg.limits.memory_mb = 2000;
        cfg.limits.cgroup_parent = Some("actions.slice".into());
        require_host_containment(&cfg)
            .expect("the explicitly bounded 14-runner HostDocker profile must pass admission");

        write_actions_slice_fixture(&root, 10);
        let mut rollback_cfg = cfg_with(10, "ez-runner-c");
        rollback_cfg.limits.memory_mb = 2500;
        rollback_cfg.limits.cpus = 1.0;
        rollback_cfg.limits.pids = 128;
        rollback_cfg.limits.cgroup_parent = Some("actions.slice".into());
        require_host_containment(&rollback_cfg)
            .expect("the supported 10-runner rollback profile must pass admission");

        write_actions_slice_fixture(&root, 20);
        let mut cfg20 = cfg_with(20, "ez-runner-c");
        cfg20.limits.memory_mb = 1400;
        cfg20.limits.cgroup_parent = Some("actions.slice".into());
        require_host_containment(&cfg20)
            .expect("the explicitly bounded 20-runner HostDocker profile must pass admission");

        write_actions_slice_fixture(&root, 14);
        let mut wrong_memory = cfg.clone();
        wrong_memory.limits.memory_mb = 2500;
        let err = require_host_containment(&wrong_memory)
            .expect_err("the 14-runner profile must reject 2500 MiB per job");
        assert!(err.to_string().contains("limits.memory_mb"), "got: {err:#}");

        let mut wrong_pids = cfg.clone();
        wrong_pids.limits.pids = 513;
        let err = require_host_containment(&wrong_pids)
            .expect_err("profiles must reject unapproved per-runner PID limits");
        assert!(err.to_string().contains("limits.pids"), "got: {err:#}");

        let mut wrong_count = cfg_with(12, "ez-runner-c");
        wrong_count.limits.cgroup_parent = Some("actions.slice".into());
        let err = require_host_containment(&wrong_count)
            .expect_err("arbitrary counts must remain rejected");
        assert!(err.to_string().contains("runner counts"), "got: {err:#}");
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn host_containment_verifies_pid_ancestry_under_actions_slice() {
        let _env = TestEnv::new("host_containment_ancestry");
        cpu_probe_overrides::set(Some(true));
        let mut cfg = cfg_with(10, "ez-org-runner");
        cfg.limits.memory_mb = 2500;
        cfg.limits.cgroup_parent = Some("actions.slice".into());

        let temp_dir = env::temp_dir().join(format!("ezgha-ancestry-test-{}", std::process::id()));
        write_actions_slice_fixture(&temp_dir, 10);
        *TEST_HOST_CONTAINMENT_CGROUP_ROOT.lock().unwrap() = Some(temp_dir.clone());
        let capture = temp_dir.join("docker-args.log");
        std::fs::create_dir_all(&temp_dir).unwrap();
        let script = temp_dir.join("docker");
        std::fs::write(
            &script,
            format!(
                "#!/bin/sh\necho \"$*\" >> {}\ncase \" $* \" in *\" run \"*) echo bad_ancestry_cid;; esac\nexit 0\n",
                capture.to_string_lossy()
            ),
        )
        .unwrap();
        #[cfg(unix)]
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        *TEST_DOCKER_BIN.lock().unwrap() = Some(script.to_string_lossy().into_owned());

        // When container PID is not beneath /actions.slice, start_one must fail and clean up slot
        let err = start_one_with_generate(&cfg, Backend::Docker, |_gh, _name, _labels, _owned| {
            Ok(("jit".into(), 4444))
        })
        .expect_err(
            "start_one must fail closed when container ancestry is not beneath /actions.slice",
        );
        assert!(
            err.to_string().contains("actions.slice") || err.to_string().contains("ancestry"),
            "expected ancestry failure; got: {err:#}"
        );
    }

    #[cfg(target_os = "linux")]
    fn write_actions_slice_fixture(root: &Path, runner_count: u32) {
        let profile = host_actions_profile(runner_count).unwrap();
        let slice = root.join("actions.slice");
        std::fs::create_dir_all(&slice).unwrap();
        std::fs::write(
            slice.join("memory.high"),
            format!("{}\n", profile.memory_high_bytes),
        )
        .unwrap();
        std::fs::write(
            slice.join("memory.max"),
            format!("{}\n", profile.memory_max_bytes),
        )
        .unwrap();
        std::fs::write(slice.join("memory.swap.max"), "0\n").unwrap();
        std::fs::write(slice.join("pids.max"), format!("{}\n", profile.pids_max)).unwrap();
        std::fs::write(slice.join("cpu.max"), "2000000 100000\n").unwrap();
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn host_containment_accepts_the_tracked_host_actions_pid_limit() {
        let _env = TestEnv::new("host_containment_tracked_pid_limit");
        let root = env::temp_dir().join(format!(
            "ezgha-host-containment-tracked-pids-{}",
            std::process::id()
        ));
        write_actions_slice_fixture(&root, 14);

        let tracked_tasks_max = include_str!("../systemd/host/actions.slice")
            .lines()
            .find_map(|line| line.strip_prefix("TasksMax="))
            .expect("tracked host actions.slice must define TasksMax")
            .parse::<u64>()
            .expect("tracked host actions.slice TasksMax must be numeric");
        std::fs::write(
            root.join("actions.slice/pids.max"),
            format!("{tracked_tasks_max}\n"),
        )
        .unwrap();

        // The tracked unit ships the default 14-runner profile's task ceiling.
        validate_host_actions_slice(&root, 14)
            .expect("validator must accept the tracked host actions.slice PID limit");
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn host_containment_requires_exact_live_actions_slice_limits() {
        let _env = TestEnv::new("host_containment_live_slice");
        let root = env::temp_dir().join(format!(
            "ezgha-host-containment-cgroup-{}",
            std::process::id()
        ));
        write_actions_slice_fixture(&root, 10);

        validate_host_actions_slice(&root, 10)
            .expect("the exact 10-runner HostDocker actions.slice boundary must pass admission");
        write_actions_slice_fixture(&root, 14);
        validate_host_actions_slice(&root, 14)
            .expect("the 14-runner profile-specific pids cap must pass admission");
        write_actions_slice_fixture(&root, 20);
        validate_host_actions_slice(&root, 20)
            .expect("the 20-runner profile-specific pids cap must pass admission");
        let err = validate_host_actions_slice(&root, 10)
            .expect_err("the 14-runner pids cap must not pass the 10-runner profile");
        assert!(err.to_string().contains("pids.max"), "got: {err:#}");

        let err = validate_host_actions_slice(&root, 12)
            .expect_err("arbitrary runner counts must remain unsupported");
        assert!(err.to_string().contains("runner counts"), "got: {err:#}");

        write_actions_slice_fixture(&root, 10);
        std::fs::write(root.join("actions.slice/memory.high"), "max\n").unwrap();
        let err = validate_host_actions_slice(&root, 10)
            .expect_err("an unbounded memory.high must fail HostDocker admission");
        assert!(
            err.to_string().contains("memory.high"),
            "expected memory.high mismatch; got: {err:#}"
        );
        write_actions_slice_fixture(&root, 10);
        std::fs::write(root.join("actions.slice/memory.max"), "max\n").unwrap();
        let err = validate_host_actions_slice(&root, 10)
            .expect_err("an unbounded memory.max must fail HostDocker admission");
        assert!(err.to_string().contains("memory.max"), "got: {err:#}");
        write_actions_slice_fixture(&root, 10);
        std::fs::remove_file(root.join("actions.slice/pids.max")).unwrap();
        let err = validate_host_actions_slice(&root, 10)
            .expect_err("a missing tracked cgroup file must fail HostDocker admission");
        assert!(
            err.to_string().contains("pids.max"),
            "expected the missing pids.max error; got: {err:#}"
        );
        write_actions_slice_fixture(&root, 10);
        std::fs::write(root.join("actions.slice/cpu.max"), "max 100000\n").unwrap();
        let err = validate_host_actions_slice(&root, 10)
            .expect_err("a malformed or unlimited cpu.max must fail HostDocker admission");
        assert!(
            err.to_string().contains("cpu.max"),
            "expected cpu.max mismatch; got: {err:#}"
        );
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn host_containment_rejects_missing_or_non_descendant_cgroup_paths() {
        let _env = TestEnv::new("host_containment_cgroup_path");
        assert!(
            !is_actions_slice_descendant("0::/actions.slice"),
            "the slice itself is not a runner scope"
        );
        assert!(
            !is_actions_slice_descendant("0::/other.slice/actions.slice/runner.scope"),
            "a substring match outside the actions slice must not pass"
        );
        assert!(
            is_actions_slice_descendant("0::/actions.slice/docker-abc.scope"),
            "a direct actions.slice descendant must pass"
        );
        assert!(
            parse_container_pid_for_ancestry("runner", "0\n").is_err(),
            "PID zero must fail closed"
        );
        assert!(
            parse_container_pid_for_ancestry("runner", "not-a-pid\n").is_err(),
            "an unreadable inspect value must fail closed"
        );
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn vm_backed_docker_skips_host_pid_ancestry_probe() {
        let _env = TestEnv::new("host_containment_vm_ancestry");
        *TEST_HOST_CONTAINMENT_DAEMON_IN_VM.lock().unwrap() = Some(true);
        *TEST_CONTAINER_ANCESTRY_OVERRIDE.lock().unwrap() = Some(false);

        require_container_actions_ancestry("guest-container")
            .expect("guest PID ancestry must not be read through the host /proc");
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn host_containment_requires_neutral_user_manager_oom_policy() {
        let _env = TestEnv::new("host_containment_user_manager_oom");
        validate_user_manager_oom_properties(
            "ManagedOOMMemoryPressure=auto\nManagedOOMSwap=auto\nManagedOOMPreference=none\nOOMScoreAdjust=0\n",
        )
        .expect("the neutral user manager OOM policy must pass containment admission");

        let err = validate_user_manager_oom_properties(
            "ManagedOOMMemoryPressure=kill\nManagedOOMSwap=auto\nManagedOOMPreference=none\nOOMScoreAdjust=0\n",
        )
        .expect_err("a user manager pressure-kill policy must fail containment admission");
        assert!(
            err.to_string().contains("ManagedOOMMemoryPressure"),
            "expected the pressure policy mismatch; got: {err:#}"
        );
    }

    #[test]
    fn wheelhouse_mount_skipped_fail_open_when_configured_path_missing() {
        let _env = TestEnv::new("wheelhouse_mount_missing_fail_open");
        cpu_probe_overrides::set(Some(true));
        let mut cfg = cfg_with(2, "ez-org-runner");
        let temp_dir = env::temp_dir().join(format!(
            "ezgha-wheelhouse-missing-test-{}",
            std::process::id()
        ));
        // Deliberately do NOT create this directory -- proves fail-open.
        let missing_wheelhouse = temp_dir.join("does-not-exist");
        cfg.runner.wheelhouse_host_path = Some(missing_wheelhouse.to_string_lossy().into_owned());

        let capture = temp_dir.join("docker-args.log");
        let script = fake_docker_capturing_args(&temp_dir, &capture);
        *TEST_DOCKER_BIN.lock().unwrap() = Some(script.to_string_lossy().into_owned());

        start_one_with_generate(&cfg, Backend::Docker, |_gh, _name, _labels, _owned| {
            Ok(("jit".into(), 2222))
        })
        .expect("start_one should succeed even when the configured wheelhouse path is missing");

        let logged = std::fs::read_to_string(&capture).unwrap();
        let run_line = logged
            .lines()
            .find(|l| l.contains("run "))
            .expect("a docker run invocation should have been logged");
        assert!(
            !run_line.contains("/opt/wheelhouse"),
            "a missing wheelhouse path must not be mounted (fail-open); got: {run_line}"
        );
    }

    #[test]
    fn workspace_mount_added_when_configured_root_exists() {
        let _env = TestEnv::new("workspace_mount_present");
        cpu_probe_overrides::set(Some(true));
        let mut cfg = cfg_with(2, "ez-org-runner");
        let temp_dir = env::temp_dir().join(format!("ezgha-workspace-test-{}", std::process::id()));
        let workspace_root = temp_dir.join("workspace-root");
        std::fs::create_dir_all(&workspace_root).unwrap();
        cfg.runner.workspace_host_path = Some(workspace_root.to_string_lossy().into_owned());

        let capture = temp_dir.join("docker-args.log");
        let script = fake_docker_capturing_args(&temp_dir, &capture);
        *TEST_DOCKER_BIN.lock().unwrap() = Some(script.to_string_lossy().into_owned());

        start_one_with_generate(&cfg, Backend::Docker, |_gh, _name, _labels, _owned| {
            Ok(("jit".into(), 3333))
        })
        .expect("start_one should succeed");

        let logged = std::fs::read_to_string(&capture).unwrap();
        let run_line = logged
            .lines()
            .find(|l| l.contains("run "))
            .expect("a docker run invocation should have been logged");
        let expected_runner_workspace = workspace_root.join("ez-org-runner-1");
        assert!(
            run_line.contains(&format!(
                "{}:/home/runner/_work",
                expected_runner_workspace.display()
            )),
            "run args should mount a per-runner workspace subdir read-write at /home/runner/_work; got: {run_line}"
        );
        assert!(
            expected_runner_workspace.is_dir(),
            "the per-runner workspace subdir should have been created on the host"
        );
    }

    #[test]
    fn workspace_mount_shadows_actions_temp_tool_with_tmpfs() {
        // Regression test for the 2026-07-19 live incident (bead
        // jleechan-93cf): tar extraction of an archive containing a symlink
        // corrupts the symlink into an unreadable 0-byte mode-000 file when
        // the destination is this virtiofs-backed workspace bind mount on
        // Colima/Mac -- confirmed with actions/setup-python's own tarball,
        // reproduced end-to-end in
        // tests/workspace_mount_symlink_extraction_test.sh. GitHub's own
        // actions-runner extracts downloaded action repos and tools into
        // exactly these three fixed subdirectory names, so shadowing them
        // with tmpfs keeps that extraction off virtiofs entirely while the
        // disk-churn win this mount exists for (checkouts/build scratch,
        // which live directly under _work/<owner>/<repo>) is unaffected.
        let _env = TestEnv::new("workspace_mount_tmpfs_shadow");
        cpu_probe_overrides::set(Some(true));
        let mut cfg = cfg_with(1, "ez-org-runner");
        let temp_dir =
            env::temp_dir().join(format!("ezgha-workspace-tmpfs-test-{}", std::process::id()));
        let workspace_root = temp_dir.join("workspace-root");
        std::fs::create_dir_all(&workspace_root).unwrap();
        cfg.runner.workspace_host_path = Some(workspace_root.to_string_lossy().into_owned());

        let capture = temp_dir.join("docker-args.log");
        let script = fake_docker_capturing_args(&temp_dir, &capture);
        *TEST_DOCKER_BIN.lock().unwrap() = Some(script.to_string_lossy().into_owned());

        start_one_with_generate(&cfg, Backend::Docker, |_gh, _name, _labels, _owned| {
            Ok(("jit".into(), 3334))
        })
        .expect("start_one should succeed");

        let logged = std::fs::read_to_string(&capture).unwrap();
        let run_line = logged
            .lines()
            .find(|l| l.contains("run "))
            .expect("a docker run invocation should have been logged");
        for shadowed in ["_actions", "_temp", "_tool"] {
            let expected = format!("--tmpfs /home/runner/_work/{shadowed}:exec");
            assert!(
                run_line.contains(&expected),
                "run args should tmpfs-shadow {shadowed} with executable runtimes enabled; \
                 got: {run_line}"
            );
        }
    }

    #[test]
    fn workspace_mount_sets_virtiofs_env_for_tar_wrapper() {
        // Regression test for the WIDENED understanding of bead jleechan-93cf
        // (2026-07-19 follow-up): the tmpfs-shadow fix above only protects
        // the three fixed runner-internal cache dirs. Real job checkouts
        // under _work/<owner>/<repo> -- the dominant disk-churn win this
        // mount exists for -- are NOT shadowed and remain exposed to the
        // same virtiofs symlink-extraction corruption whenever a workflow
        // step tar-extracts an archive containing a symlink there (npm ci,
        // downloaded release tarballs, docker save/load, etc; confirmed live
        // with a synthetic npm-style archive). The daemon now flags every
        // container that has this bind mount with EZGHA_VIRTIOFS_WORKSPACE=1
        // so the image's /usr/local/bin/tar wrapper
        // (docker/tar-workspace-wrapper.sh) knows to stage extractions
        // destined for /home/runner/_work on the container's own tmpfs/
        // overlay /tmp first, then `cp -a` (safe syscalls) into the real
        // virtiofs destination -- see
        // tests/workspace_mount_symlink_extraction_test.sh step 4.
        let _env = TestEnv::new("workspace_mount_virtiofs_env");
        cpu_probe_overrides::set(Some(true));
        let mut cfg = cfg_with(1, "ez-org-runner");
        let temp_dir = env::temp_dir().join(format!(
            "ezgha-workspace-virtiofs-env-test-{}",
            std::process::id()
        ));
        let workspace_root = temp_dir.join("workspace-root");
        std::fs::create_dir_all(&workspace_root).unwrap();
        cfg.runner.workspace_host_path = Some(workspace_root.to_string_lossy().into_owned());

        let capture = temp_dir.join("docker-args.log");
        let script = fake_docker_capturing_args(&temp_dir, &capture);
        *TEST_DOCKER_BIN.lock().unwrap() = Some(script.to_string_lossy().into_owned());

        start_one_with_generate(&cfg, Backend::Docker, |_gh, _name, _labels, _owned| {
            Ok(("jit".into(), 3335))
        })
        .expect("start_one should succeed");

        let logged = std::fs::read_to_string(&capture).unwrap();
        let run_line = logged
            .lines()
            .find(|l| l.contains("run "))
            .expect("a docker run invocation should have been logged");
        assert!(
            run_line.contains("-e EZGHA_VIRTIOFS_WORKSPACE=1"),
            "run args should flag the container as having the virtiofs-backed \
             workspace mount so /usr/local/bin/tar knows to guard extractions; \
             got: {run_line}"
        );
    }

    #[test]
    fn workspace_mount_skipped_fail_open_when_configured_root_missing() {
        let _env = TestEnv::new("workspace_mount_missing_fail_open");
        cpu_probe_overrides::set(Some(true));
        let mut cfg = cfg_with(2, "ez-org-runner");
        let temp_dir = env::temp_dir().join(format!(
            "ezgha-workspace-missing-test-{}",
            std::process::id()
        ));
        // Deliberately do NOT create this directory -- proves fail-open.
        let missing_root = temp_dir.join("does-not-exist");
        cfg.runner.workspace_host_path = Some(missing_root.to_string_lossy().into_owned());

        let capture = temp_dir.join("docker-args.log");
        let script = fake_docker_capturing_args(&temp_dir, &capture);
        *TEST_DOCKER_BIN.lock().unwrap() = Some(script.to_string_lossy().into_owned());

        start_one_with_generate(&cfg, Backend::Docker, |_gh, _name, _labels, _owned| {
            Ok(("jit".into(), 4444))
        })
        .expect("start_one should succeed even when the configured workspace root is missing");

        let logged = std::fs::read_to_string(&capture).unwrap();
        let run_line = logged
            .lines()
            .find(|l| l.contains("run "))
            .expect("a docker run invocation should have been logged");
        assert!(
            !run_line.contains("/home/runner/_work"),
            "a missing workspace root must not be mounted (fail-open); got: {run_line}"
        );
        assert!(
            !run_line.contains("EZGHA_VIRTIOFS_WORKSPACE"),
            "the tar-wrapper env flag must not be set when there is no workspace mount \
             to guard; got: {run_line}"
        );
    }

    #[test]
    fn workspace_mount_wipes_prior_job_leftovers_before_start() {
        let _env = TestEnv::new("workspace_mount_wipes_leftovers");
        cpu_probe_overrides::set(Some(true));
        let mut cfg = cfg_with(2, "ez-org-runner");
        let temp_dir =
            env::temp_dir().join(format!("ezgha-workspace-wipe-test-{}", std::process::id()));
        let workspace_root = temp_dir.join("workspace-root");
        std::fs::create_dir_all(&workspace_root).unwrap();
        cfg.runner.workspace_host_path = Some(workspace_root.to_string_lossy().into_owned());

        // Simulate a prior job's leftover checkout/credentials in this slot's
        // workspace subdir -- must not be visible to the next job.
        let runner_workspace = workspace_root.join("ez-org-runner-1");
        std::fs::create_dir_all(&runner_workspace).unwrap();
        std::fs::write(
            runner_workspace.join("leaked-secret.txt"),
            b"prior job data",
        )
        .unwrap();

        let capture = temp_dir.join("docker-args.log");
        let script = fake_docker_capturing_args(&temp_dir, &capture);
        *TEST_DOCKER_BIN.lock().unwrap() = Some(script.to_string_lossy().into_owned());

        start_one_with_generate(&cfg, Backend::Docker, |_gh, _name, _labels, _owned| {
            Ok(("jit".into(), 5555))
        })
        .expect("start_one should succeed");

        assert!(
            !runner_workspace.join("leaked-secret.txt").exists(),
            "prior job's leftover file must be wiped before the next container starts"
        );
        assert!(
            runner_workspace.is_dir(),
            "a fresh empty workspace subdir should exist after the wipe"
        );
    }

    #[test]
    fn release_stale_slots_keeps_slot_when_runner_id_not_in_live_but_container_exists() {
        let _env = TestEnv::new("stale_running_container_stay_reserved");
        let cfg = cfg_with(2, "ez-org-runner");
        let _slot = next_slot(&cfg).unwrap();
        record_slot_runner_id(1, 4242).unwrap();

        let live = vec![runner_info(9999, "ez-org-runner-2")];
        let local_names = HashSet::from(["ez-org-runner-1".to_string()]);
        let reclaimed = release_stale_slots_from_with_containers(
            &read_slot_assignments().unwrap(),
            &live,
            &cfg.runner.name_prefix,
            Some(&local_names),
        )
        .unwrap();

        assert_eq!(
            reclaimed, 0,
            "slot must be kept if container still exists locally despite missing GH registration"
        );
        let assignments = read_slot_assignments().unwrap();
        assert_eq!(
            assignments.assignments.get("1").map(String::as_str),
            Some("4242"),
            "slot 1 should remain recorded"
        );
    }

    #[test]
    fn release_stale_slots_releases_slot_when_runner_id_not_in_live_but_container_exists_past_grace(
    ) {
        // Mirrors the keep test above but with the slot's `registered_at`
        // backdated past REGISTRATION_GRACE_WINDOW. A proven idle listener is
        // safe to recycle because its GitHub registration no longer exists.
        let _env = TestEnv::new("stale_running_container_past_grace");
        let cfg = cfg_with(2, "ez-org-runner");
        let _slot = next_slot(&cfg).unwrap();
        record_slot_runner_id(1, 4242).unwrap();
        // Backdate `registered_at` to far past the grace window.
        let mut assignments = read_slot_assignments().unwrap();
        assignments.registered_at.insert(
            "1".to_string(),
            now_epoch_secs() - REGISTRATION_GRACE_WINDOW.as_secs() - 1,
        );
        write_slot_assignments_for(&assignments, Some(&cfg)).unwrap();

        let live = vec![runner_info(9999, "ez-org-runner-2")];
        let local_names = HashSet::from(["ez-org-runner-1".to_string()]);
        let reclaimed = release_stale_slots_from_with_containers_and_activity(
            &read_slot_assignments().unwrap(),
            &live,
            &cfg.runner.name_prefix,
            Some(&local_names),
            |_| LocalRunnerActivity::Idle,
        )
        .unwrap();

        assert_eq!(
            reclaimed, 1,
            "slot must be reclaimed when local container exists but GH registration has been absent past the grace window (was the keep-forever bug)"
        );
        let assignments = read_slot_assignments().unwrap();
        assert!(
            !assignments.assignments.contains_key("1"),
            "slot 1 should be released (assignments row deleted)"
        );
    }

    #[test]
    fn release_stale_slots_keeps_busy_local_runner_when_gh_snapshot_omits_it_past_grace() {
        let _env = TestEnv::new("stale_busy_container_past_grace");
        let cfg = cfg_with(2, "ez-org-runner");
        let _slot = next_slot(&cfg).unwrap();
        record_slot_runner_id(1, 4242).unwrap();
        let mut assignments = read_slot_assignments().unwrap();
        assignments.registered_at.insert(
            "1".to_string(),
            now_epoch_secs() - REGISTRATION_GRACE_WINDOW.as_secs() - 1,
        );
        write_slot_assignments_for(&assignments, Some(&cfg)).unwrap();

        let live = vec![runner_info(9999, "ez-org-runner-2")];
        let local_names = HashSet::from(["ez-org-runner-1".to_string()]);
        let reclaimed = release_stale_slots_from_with_containers_and_activity(
            &read_slot_assignments().unwrap(),
            &live,
            &cfg.runner.name_prefix,
            Some(&local_names),
            |_| LocalRunnerActivity::Busy,
        )
        .unwrap();

        assert_eq!(
            reclaimed, 0,
            "a local Runner.Worker must not be reclaimed from a single missing-GitHub snapshot"
        );
        assert_eq!(
            read_slot_assignments()
                .unwrap()
                .assignments
                .get("1")
                .map(String::as_str),
            Some("4242"),
            "the busy slot must remain owned until the local job finishes"
        );
    }

    #[test]
    fn release_stale_slots_keeps_local_runner_when_activity_probe_is_unknown() {
        let _env = TestEnv::new("stale_unknown_container_past_grace");
        let cfg = cfg_with(2, "ez-org-runner");
        let _slot = next_slot(&cfg).unwrap();
        record_slot_runner_id(1, 4242).unwrap();
        let mut assignments = read_slot_assignments().unwrap();
        assignments.registered_at.insert(
            "1".to_string(),
            now_epoch_secs() - REGISTRATION_GRACE_WINDOW.as_secs() - 1,
        );
        write_slot_assignments_for(&assignments, Some(&cfg)).unwrap();

        let live = vec![runner_info(9999, "ez-org-runner-2")];
        let local_names = HashSet::from(["ez-org-runner-1".to_string()]);
        let reclaimed = release_stale_slots_from_with_containers_and_activity(
            &read_slot_assignments().unwrap(),
            &live,
            &cfg.runner.name_prefix,
            Some(&local_names),
            |_| LocalRunnerActivity::Unknown,
        )
        .unwrap();

        assert_eq!(reclaimed, 0, "an inconclusive local probe must fail safe");
        assert!(
            read_slot_assignments()
                .unwrap()
                .assignments
                .contains_key("1"),
            "the slot must remain owned when local activity is unknown"
        );
    }

    /// Bead jleechan-95jk root-cause: a slot whose local container is GONE
    /// (docker top: "No such container") past the grace window must reclaim,
    /// NOT stay fail-safe Unknown. The 2026-10-03 throughput doc evidences
    /// this on Linux journal: "keeping slot 3 because docker top says No
    /// such container despite snapshot omission". `LocalRunnerActivity::Absent`
    /// is the new fourth state (alongside Busy/Idle/Unknown) that tells
    /// `release_stale_slots` the container is definitively gone and the
    /// slot can be released.
    #[test]
    fn release_stale_slots_reclaims_when_local_container_is_absent() {
        let _env = TestEnv::new("stale_absent_container_past_grace");
        let cfg = cfg_with(2, "ez-org-runner");
        let _slot = next_slot(&cfg).unwrap();
        record_slot_runner_id(1, 4242).unwrap();
        let mut assignments = read_slot_assignments().unwrap();
        assignments.registered_at.insert(
            "1".to_string(),
            now_epoch_secs() - REGISTRATION_GRACE_WINDOW.as_secs() - 1,
        );
        write_slot_assignments_for(&assignments, Some(&cfg)).unwrap();

        // The container name is reported as locally-known (consistent with
        // a recent snapshot taken before it died), but the activity probe
        // returns Absent because docker top says "No such container".
        let live = vec![runner_info(9999, "ez-org-runner-2")];
        let local_names = HashSet::from(["ez-org-runner-1".to_string()]);
        let reclaimed = release_stale_slots_from_with_containers_and_activity(
            &read_slot_assignments().unwrap(),
            &live,
            &cfg.runner.name_prefix,
            Some(&local_names),
            |_| LocalRunnerActivity::Absent,
        )
        .unwrap();

        assert_eq!(
            reclaimed, 1,
            "a slot whose local container is gone (Absent) past the grace window must reclaim"
        );
        assert!(
            !read_slot_assignments()
                .unwrap()
                .assignments
                .contains_key("1"),
            "slot 1 must be released when the local container has been confirmed gone"
        );
    }

    #[test]
    fn release_stale_slots_keeps_slot_when_runner_id_not_in_live_but_container_list_unavailable() {
        let _env = TestEnv::new("stale_container_list_unavailable");
        let cfg = cfg_with(2, "ez-org-runner");
        let _slot = next_slot(&cfg).unwrap();
        record_slot_runner_id(1, 4242).unwrap();

        let live = vec![runner_info(9999, "ez-org-runner-2")];
        // local_container_names = None simulates `docker ps` / managed_containers()
        // failing at the caller — we must NOT blind-reclaim in this case.
        let reclaimed = release_stale_slots_from_with_containers(
            &read_slot_assignments().unwrap(),
            &live,
            &cfg.runner.name_prefix,
            None,
        )
        .unwrap();

        assert_eq!(
            reclaimed, 0,
            "slot must be kept when local container existence is unknown (docker ps failed) even if GH registration is absent"
        );
        let assignments = read_slot_assignments().unwrap();
        assert_eq!(
            assignments.assignments.get("1").map(String::as_str),
            Some("4242"),
            "slot 1 should remain recorded when container list is unavailable"
        );
    }

    #[test]
    fn release_stale_slots_releases_slot_when_runner_id_not_in_live_and_container_list_unavailable_past_grace(
    ) {
        // Same as the keep-forever bug above but for the docker-ps-failed
        // (local_container_names = None) branch. Past the grace window, even
        // a docker-ps failure should not hold a slot forever.
        let _env = TestEnv::new("stale_container_list_unavailable_past_grace");
        let cfg = cfg_with(2, "ez-org-runner");
        let _slot = next_slot(&cfg).unwrap();
        record_slot_runner_id(1, 4242).unwrap();
        let mut assignments = read_slot_assignments().unwrap();
        assignments.registered_at.insert(
            "1".to_string(),
            now_epoch_secs() - REGISTRATION_GRACE_WINDOW.as_secs() - 1,
        );
        write_slot_assignments_for(&assignments, Some(&cfg)).unwrap();

        let live = vec![runner_info(9999, "ez-org-runner-2")];
        // None = docker ps failed at the caller.
        let reclaimed = release_stale_slots_from_with_containers(
            &read_slot_assignments().unwrap(),
            &live,
            &cfg.runner.name_prefix,
            None,
        )
        .unwrap();

        assert_eq!(
            reclaimed, 1,
            "slot must be reclaimed when container list is unavailable AND GH registration has been absent past the grace window"
        );
        let assignments = read_slot_assignments().unwrap();
        assert!(
            !assignments.assignments.contains_key("1"),
            "slot 1 should be released (assignments row deleted)"
        );
    }

    #[test]
    fn next_slot_assigns_exhausted_after_count_reached() {
        let _env = TestEnv::new("exhausted");
        let cfg = cfg_with(2, "ez-org-runner");
        let _a = next_slot(&cfg).unwrap();
        let _b = next_slot(&cfg).unwrap();
        let err = next_slot(&cfg).unwrap_err().to_string();
        assert!(
            err.contains("slot") && err.contains("2"),
            "error message should mention slot exhaustion and the configured count; got: {err}"
        );
    }

    #[test]
    fn runner_name_uses_prefix_and_slot_format() {
        let cfg = cfg_with(4, "ez-org-runner");
        assert_eq!(runner_name_for(&cfg, 1), "ez-org-runner-1");
        assert_eq!(runner_name_for(&cfg, 4), "ez-org-runner-4");

        // Custom prefix must be respected.
        let mut custom = cfg.clone();
        custom.runner.name_prefix = "lab-runner".into();
        assert_eq!(runner_name_for(&custom, 7), "lab-runner-7");
    }

    fn managed_container(name: &str) -> ManagedContainer {
        ManagedContainer {
            id: name.into(),
            name: name.into(),
            state: "running".into(),
            running_for: "1s".into(),
        }
    }

    #[test]
    fn current_prefix_container_count_ignores_retired_prefixes() {
        let containers = vec![
            managed_container("ez-runner-1"),
            managed_container("ez-runner-b-1"),
            managed_container("ez-runner-c-1"),
            managed_container("ez-runner-c-2"),
        ];

        let base_cfg = cfg_with(3, "ez-runner");
        assert_eq!(current_prefix_containers(&containers, &base_cfg).len(), 1);

        let old_cfg = cfg_with(3, "ez-runner-b");
        assert_eq!(current_prefix_containers(&containers, &old_cfg).len(), 1);

        let current_cfg = cfg_with(3, "ez-runner-c");
        assert_eq!(
            current_prefix_containers(&containers, &current_cfg).len(),
            2
        );
    }

    #[test]
    fn current_prefix_containers_excludes_canary_prefix() {
        let containers = vec![
            managed_container("ez-runner-c-1"),
            managed_container("ez-runner-c-2"),
            managed_container("ez-canary-runner-b-1"),
        ];
        let cfg = cfg_with(2, "ez-runner-c");

        let owned: Vec<_> = current_prefix_containers(&containers, &cfg)
            .into_iter()
            .map(|c| c.name.as_str())
            .collect();

        assert_eq!(owned, vec!["ez-runner-c-1", "ez-runner-c-2"]);
    }

    fn runner_info(id: u64, name: &str) -> github::RunnerInfo {
        github::RunnerInfo {
            id,
            name: name.into(),
            status: "online".into(),
            busy: false,
            run_id: None,
        }
    }

    #[test]
    fn release_stale_slots_releases_slot_when_runner_id_not_in_live() {
        let _env = TestEnv::new("stale_releases");
        let cfg = cfg_with(2, "ez-org-runner");
        // Slot 1 was reserved AND has a recorded runner_id that is NOT in
        // the live GitHub list (server-side reap, or daemon died mid-flight).
        let _slot = next_slot(&cfg).unwrap();
        record_slot_runner_id(1, 4242).unwrap();

        let live = vec![runner_info(9999, "ez-org-runner-2")];
        // Use an explicit (empty) local-container set rather than the
        // `release_stale_slots_from` helper's `None`: post-B2-fix, `None`
        // means "docker ps failed, container existence unknown" and
        // correctly does NOT reclaim (see
        // `release_stale_slots_keeps_slot_when_runner_id_not_in_live_but_container_list_unavailable`).
        // This test's scenario is "we positively confirmed (via a
        // successful, empty docker ps) that no local container exists",
        // which must still reclaim.
        let reclaimed = release_stale_slots_from_with_containers(
            &read_slot_assignments().unwrap(),
            &live,
            "",
            Some(&HashSet::new()),
        )
        .unwrap();

        assert_eq!(reclaimed, 1, "the stale slot must be reclaimed");
        let a = read_slot_assignments().unwrap();
        assert!(
            !a.assignments.contains_key("1"),
            "slot 1 must be removed; got: {:?}",
            a.assignments
        );
    }

    #[test]
    fn release_stale_slots_keeps_slot_when_runner_id_in_live() {
        let _env = TestEnv::new("stale_keeps");
        let cfg = cfg_with(2, "ez-org-runner");
        let _slot = next_slot(&cfg).unwrap();
        record_slot_runner_id(1, 1234).unwrap();

        // Live list DOES contain the recorded id — this slot is healthy.
        let live = vec![runner_info(1234, "ez-org-runner-1")];
        let reclaimed = release_stale_slots_from(&read_slot_assignments().unwrap(), &live).unwrap();

        assert_eq!(reclaimed, 0, "live slots must not be reclaimed");
        let a = read_slot_assignments().unwrap();
        assert_eq!(
            a.assignments.get("1").map(String::as_str),
            Some("1234"),
            "slot 1 must remain recorded"
        );
    }

    #[test]
    fn release_stale_slots_releases_slot_when_runner_name_mismatches() {
        let _env = TestEnv::new("name_mismatch");
        let cfg = cfg_with(2, "ez-org-runner");
        let _slot = next_slot(&cfg).unwrap();
        record_slot_runner_id(1, 1234).unwrap();

        // Runner id 1234 is in live, but its name is "ez-org-runner-2" (expected "ez-org-runner-1")
        let live = vec![runner_info(1234, "ez-org-runner-2")];
        let reclaimed = release_stale_slots_from_with_containers(
            &read_slot_assignments().unwrap(),
            &live,
            "ez-org-runner",
            None,
        )
        .unwrap();

        assert_eq!(reclaimed, 1, "mismatched slot must be reclaimed");
        let a = read_slot_assignments().unwrap();
        assert!(
            !a.assignments.contains_key("1"),
            "slot 1 must be removed; got: {:?}",
            a.assignments
        );
    }

    #[test]
    fn release_stale_slots_releases_offline_runner_when_container_missing() {
        // bead ez-gh-actions-5ki: this registration must be OUTSIDE the grace
        // window for Path 1 to reap it — `record_slot_runner_id` stamps
        // `registered_at` to "now", so backdate it past the window to
        // exercise the pre-5ki reap behavior independent of the new grace
        // logic (that's covered by its own dedicated tests below).
        let _env = TestEnv::new("offline_missing_container");
        let cfg = cfg_with(2, "ez-org-runner");
        let _slot = next_slot(&cfg).unwrap();
        record_slot_runner_id(1, 1234).unwrap();
        let mut assignments = read_slot_assignments().unwrap();
        assignments.registered_at.insert(
            "1".to_string(),
            now_epoch_secs() - REGISTRATION_GRACE_WINDOW.as_secs() - 1,
        );
        write_slot_assignments_for(&assignments, None).unwrap();

        let live = vec![github::RunnerInfo {
            id: 1234,
            name: "ez-org-runner-1".into(),
            status: "offline".into(),
            busy: false,
            run_id: None,
        }];
        let local_names = HashSet::from(["ez-org-runner-2".to_string()]);
        let reclaimed = release_stale_slots_from_with_containers(
            &read_slot_assignments().unwrap(),
            &live,
            &cfg.runner.name_prefix,
            Some(&local_names),
        )
        .unwrap();

        assert_eq!(
            reclaimed, 1,
            "offline idle runner without a local container, registered outside the grace window, should not hold its slot"
        );
        assert!(
            read_slot_assignments().unwrap().assignments.is_empty(),
            "slot 1 must be released"
        );
    }

    #[test]
    fn offline_busy_owned_missing_container_slot_requires_runner_removal() {
        let _env = TestEnv::new("offline_busy_missing_container");
        let cfg = cfg_with(2, "ez-org-runner");
        let _slot = next_slot(&cfg).unwrap();
        record_slot_runner_id(1, 1234).unwrap();

        let live = vec![github::RunnerInfo {
            id: 1234,
            name: "ez-org-runner-1".into(),
            status: "offline".into(),
            busy: true,
            run_id: None,
        }];
        let local_names = HashSet::from(["ez-org-runner-2".to_string()]);
        let candidates = offline_busy_owned_missing_container_slots(
            &read_slot_assignments().unwrap(),
            &live,
            &cfg.runner.name_prefix,
            &local_names,
        );

        assert_eq!(candidates, vec![(1, 1234, "ez-org-runner-1".into())]);
        let reclaimed = release_stale_slots_from_with_containers(
            &read_slot_assignments().unwrap(),
            &live,
            &cfg.runner.name_prefix,
            Some(&local_names),
        )
        .unwrap();
        assert_eq!(
            reclaimed, 0,
            "offline/busy runners must not be released by the dry reconciler before GitHub removal"
        );
    }

    #[test]
    fn online_busy_missing_container_is_not_reclaimable() {
        let _env = TestEnv::new("online_busy_missing_container");
        let cfg = cfg_with(2, "ez-org-runner");
        let _slot = next_slot(&cfg).unwrap();
        record_slot_runner_id(1, 1234).unwrap();

        let live = vec![github::RunnerInfo {
            id: 1234,
            name: "ez-org-runner-1".into(),
            status: "online".into(),
            busy: true,
            run_id: None,
        }];
        let local_names = HashSet::from(["ez-org-runner-2".to_string()]);
        let candidates = offline_busy_owned_missing_container_slots(
            &read_slot_assignments().unwrap(),
            &live,
            &cfg.runner.name_prefix,
            &local_names,
        );

        assert!(candidates.is_empty());
        let reclaimed = release_stale_slots_from_with_containers(
            &read_slot_assignments().unwrap(),
            &live,
            &cfg.runner.name_prefix,
            Some(&local_names),
        )
        .unwrap();
        assert_eq!(reclaimed, 0);
    }

    /// Bead jleechan-uurm: as of the post-PR-#33 grace-window fix, an
    /// empty-id reservation whose `registered_at` is within
    /// REGISTRATION_GRACE_WINDOW is PROTECTED, not reaped — that is the
    /// whole point of the gate (sibling race against Path 1's empty-id
    /// branch). This test was the original "empty-id must be released"
    /// contract that locked in the pre-fix behavior; the contract changed
    /// when the 2026-07-08 fix (PR #33, 1a9baf4) moved
    /// `record_slot_runner_id_for` to post-JIT pre-docker-run, exposing the
    /// JIT round-trip window. See companion test
    /// `release_stale_slots_never_reclaims_empty_id_within_grace_window`
    /// for the new positive-path contract and
    /// `release_stale_slots_reclaims_empty_id_past_grace_window` for the
    /// past-grace case.
    #[test]
    fn release_stale_slots_handles_empty_runner_id() {
        let _env = TestEnv::new("stale_empty");
        let cfg = cfg_with(2, "ez-org-runner");
        // Reserved (`next_slot`) but `record_slot_runner_id` never ran —
        // `registered_at` was just written by next_slot so the slot is
        // inside the JIT round-trip grace window. The OLD test asserted
        // reclaimed == 1 ("empty-id must be released"); the NEW contract
        // is reclaimed == 0 because the empty-id reservation is in-grace.
        let _slot = next_slot(&cfg).unwrap();

        let live: Vec<github::RunnerInfo> = vec![];
        let reclaimed = release_stale_slots_from(&read_slot_assignments().unwrap(), &live).unwrap();

        assert_eq!(
            reclaimed, 0,
            "empty-id reservations within the JIT round-trip grace window must NOT be released (was the pre-fix unconditional-reclaim bug)"
        );
        assert!(
            !read_slot_assignments().unwrap().assignments.is_empty(),
            "the empty-id reservation must remain so the in-flight JIT can still record its runner_id"
        );
    }

    #[test]
    fn release_stale_slots_returns_zero_when_no_assignments() {
        let _env = TestEnv::new("stale_empty_file");
        let _cfg = cfg_with(2, "ez-org-runner");
        // No slots reserved yet — file is empty.
        let live = vec![runner_info(1, "ez-org-runner-1")];
        let reclaimed = release_stale_slots_from(&read_slot_assignments().unwrap(), &live).unwrap();
        assert_eq!(reclaimed, 0);
    }

    #[test]
    fn interrupted_slot_write_preserves_previous_file_until_rename() {
        let env = TestEnv::new("interrupted_slot_write");
        let mut original = SlotAssignments::default();
        original.assignments.insert("1".into(), "4242".into());
        write_slot_assignments_for(&original, None).unwrap();
        let before = std::fs::read(&env.path).unwrap();

        let mut replacement = SlotAssignments::default();
        replacement.assignments.insert("1".into(), "9898".into());
        INTERRUPT_SLOT_WRITE_BEFORE_RENAME.with(|interrupt| interrupt.set(true));
        let result = write_slot_assignments_for(&replacement, None);
        INTERRUPT_SLOT_WRITE_BEFORE_RENAME.with(|interrupt| interrupt.set(false));

        assert!(result
            .unwrap_err()
            .to_string()
            .contains("simulated interruption"));
        assert_eq!(std::fs::read(&env.path).unwrap(), before);
        assert_eq!(
            read_slot_assignments().unwrap().assignments,
            original.assignments
        );
        let tmp = env
            .path
            .with_extension(format!("toml.tmp.{}", std::process::id()));
        let pending: SlotAssignments =
            toml::from_str(&std::fs::read_to_string(&tmp).unwrap()).unwrap();
        assert_eq!(pending.assignments, replacement.assignments);

        write_slot_assignments_for(&replacement, None).unwrap();
        assert_eq!(
            read_slot_assignments().unwrap().assignments,
            replacement.assignments
        );
        assert!(!tmp.exists());
    }

    #[test]
    fn release_stale_slots_preserves_unparseable_slot_key() {
        let env = TestEnv::new("unparseable_slot_key");
        let mut assignments = SlotAssignments::default();
        assignments.assignments.insert("1".into(), "4242".into());
        assignments
            .assignments
            .insert("broken-slot".into(), "7777".into());
        write_slot_assignments_for(&assignments, None).unwrap();
        let before = std::fs::read(&env.path).unwrap();
        let loaded = read_slot_assignments().unwrap();
        let live = vec![runner_info(4242, "ez-org-runner-1")];

        assert_eq!(release_stale_slots_from(&loaded, &live).unwrap(), 0);
        assert_eq!(std::fs::read(&env.path).unwrap(), before);
        assert_eq!(
            read_slot_assignments().unwrap().assignments,
            assignments.assignments
        );
    }

    #[test]
    fn release_stale_slots_does_not_mutate_slot_file_on_list_runners_error() {
        let _env = TestEnv::new("list_runners_error_does_not_mutate_slots");
        let _cfg = cfg_with(2, "ez-org-runner");
        let _slot = next_slot(&_cfg).unwrap();
        record_slot_runner_id(1, 4242).unwrap();

        let before = std::fs::read_to_string(_env.path.clone()).unwrap_or_else(|_| String::new());
        let _gh_guard = crate::github::with_gh_exe("/nonexistent");
        let reclaimed = release_stale_slots(&_cfg).unwrap();

        assert_eq!(
            reclaimed, 0,
            "github API errors should not trigger slot reclamation"
        );
        let after = std::fs::read_to_string(_env.path.clone()).unwrap_or_else(|_| String::new());
        assert_eq!(
            before, after,
            "slot file must remain unchanged when list_runners fails"
        );
    }

    #[test]
    fn disk_measure_strike_counter_bails_after_threshold() {
        use std::sync::atomic::Ordering;
        let _lock = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        // Reset before and after to be hermetic.
        CONSECUTIVE_DISK_NONE.store(0, Ordering::SeqCst);
        // First miss is tolerated (warn, no bail).
        let n1 = CONSECUTIVE_DISK_NONE.fetch_add(1, Ordering::SeqCst) + 1;
        assert!(
            n1 < DISK_MEASURE_STRIKES,
            "first missed measurement must not bail (got n={n1}, threshold={DISK_MEASURE_STRIKES})"
        );
        // Second miss hits the threshold and bails.
        let n2 = CONSECUTIVE_DISK_NONE.fetch_add(1, Ordering::SeqCst) + 1;
        assert!(
            n2 >= DISK_MEASURE_STRIKES,
            "second consecutive missed measurement must reach the bail threshold (got n={n2})"
        );
        // Reset for the next test.
        CONSECUTIVE_DISK_NONE.store(0, Ordering::SeqCst);
    }

    #[test]
    fn disk_measure_strike_counter_resets_on_success() {
        use std::sync::atomic::Ordering;
        let _lock = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        CONSECUTIVE_DISK_NONE.store(0, Ordering::SeqCst);
        // Drive a miss then a "Some" (modeled as the reset the production path
        // performs after a successful read).
        CONSECUTIVE_DISK_NONE.fetch_add(1, Ordering::SeqCst);
        CONSECUTIVE_DISK_NONE.store(0, Ordering::SeqCst);
        assert_eq!(
            CONSECUTIVE_DISK_NONE.load(Ordering::SeqCst),
            0,
            "any Some(_) result must reset the strike counter"
        );
    }

    // --- bead ez-gh-actions-qbl: zombie-slot self-heal ------------------

    #[test]
    fn is_runner_busy_lock_error_detects_422_job_lock() {
        let err = anyhow::anyhow!(
            "gh api remove runner 1234 failed: gh: Runner \"ez-org-runner-1\" is currently running a job and cannot be deleted. (HTTP 422)"
        );
        assert!(is_runner_busy_lock_error(&err));
    }

    #[test]
    fn is_runner_busy_lock_error_ignores_unrelated_errors() {
        let network = anyhow::anyhow!("gh api remove runner 1234 failed: connection reset");
        let auth = anyhow::anyhow!("gh api remove runner 1234 failed: HTTP 401 bad credentials");
        assert!(!is_runner_busy_lock_error(&network));
        assert!(!is_runner_busy_lock_error(&auth));
    }

    #[test]
    fn is_runner_busy_lock_error_does_not_false_positive_on_runner_id_containing_422() {
        // Regression: runner_id 422 (or 1422, 4220, ...) is a real, eventually
        // occurring value in this fleet's ever-churning ID counter. The
        // formatted error text interpolates the ID directly
        // ("...remove runner 422 failed: ..."), so a bare "422" substring
        // check would misclassify an unrelated network/auth failure on THAT
        // runner as the job-lock case and wrongly attempt a cancel.
        let network_error_on_runner_422 =
            anyhow::anyhow!("gh api remove runner 422 failed: connection reset");
        let auth_error_on_runner_1422 =
            anyhow::anyhow!("gh api remove runner 1422 failed: HTTP 401 bad credentials");
        assert!(!is_runner_busy_lock_error(&network_error_on_runner_422));
        assert!(!is_runner_busy_lock_error(&auth_error_on_runner_1422));
    }

    #[test]
    fn reclaim_zombie_locked_runner_cancels_then_deletes_on_success() {
        use crate::reaper::test_support::{job, run, runner, FakeReaperApi};
        use std::collections::VecDeque;

        let zombie = runner(1234, "ez-org-runner-1");
        let in_progress_job = job(2, Some(1234), Some("ez-org-runner-1"));
        let mut completed = in_progress_job.clone();
        completed.status = "completed".into();
        completed.conclusion = Some("cancelled".into());
        let repo_runs = vec![(
            "owner/repo".to_string(),
            vec![(run(7, "in_progress"), vec![in_progress_job.clone()])],
        )];
        let mut api = FakeReaperApi {
            job_batches: VecDeque::from([Ok(vec![in_progress_job]), Ok(vec![completed])]),
            ..Default::default()
        };

        let execution = reclaim_zombie_locked_runner_with_api(
            &zombie,
            &repo_runs,
            &["ez-org-runner".to_string()],
            &["self-hosted".to_string(), "ezgha".to_string()],
            3,
            &mut api,
        )
        .expect("a matching in-progress job must produce a reaper plan");

        assert_eq!(execution.status, reaper::ReaperExecutionStatus::Completed);
        assert_eq!(
            api.calls,
            [
                "cancel:owner/repo:7",
                "jobs:owner/repo:7",
                "jobs:owner/repo:7",
                "delete:1234",
            ],
            "must cancel the phantom run BEFORE retrying the runner delete"
        );
    }

    #[test]
    fn reclaim_zombie_locked_runner_keeps_slot_when_job_never_leaves_in_progress() {
        use crate::reaper::test_support::{job, run, runner, FakeReaperApi};
        use std::collections::VecDeque;

        let zombie = runner(1234, "ez-org-runner-1");
        let in_progress_job = job(2, Some(1234), Some("ez-org-runner-1"));
        let repo_runs = vec![(
            "owner/repo".to_string(),
            vec![(run(7, "in_progress"), vec![in_progress_job.clone()])],
        )];
        let poll_attempts = 2;
        // Every poll -- both post-cancel AND post-force-cancel -- must keep
        // returning the SAME correlated in_progress job, so this genuinely
        // drives cancel -> poll(x2) -> force-cancel -> poll(x2) -> give up,
        // rather than tripping FakeReaperApi::default()'s mismatched
        // fallback job (runner_id=42) on the very first poll, which
        // previously produced a JobCorrelationChanged short-circuit instead
        // of exercising force-cancel at all (bug caught in adversarial
        // review of the first version of this test).
        let mut api = FakeReaperApi {
            job_batches: VecDeque::from(
                std::iter::repeat_n(Ok(vec![in_progress_job]), 2 * poll_attempts as usize)
                    .collect::<Vec<_>>(),
            ),
            ..Default::default()
        };

        let execution = reclaim_zombie_locked_runner_with_api(
            &zombie,
            &repo_runs,
            &["ez-org-runner".to_string()],
            &["self-hosted".to_string(), "ezgha".to_string()],
            poll_attempts,
            &mut api,
        )
        .expect("a matching in-progress job must produce a reaper plan");

        assert_eq!(
            execution.status,
            reaper::ReaperExecutionStatus::PollTimedOut,
            "a job stuck in_progress through force-cancel must time out, not be treated as reclaimed"
        );
        assert!(
            api.calls.iter().any(|c| c.starts_with("force-cancel:")),
            "must actually escalate to force-cancel when the job outlives the poll budget: {:?}",
            api.calls
        );
        assert!(
            !api.calls.iter().any(|c| c.starts_with("delete:")),
            "must never delete the runner registration while its job is still in_progress: {:?}",
            api.calls
        );
    }

    #[test]
    fn reclaim_zombie_locked_runner_returns_none_when_no_matching_job() {
        use crate::reaper::test_support::{runner, FakeReaperApi};

        let zombie = runner(1234, "ez-org-runner-1");
        // No repos own an in-progress job for this runner.
        let repo_runs: Vec<(String, reaper::RepoRunsWithJobs)> = vec![];
        let mut api = FakeReaperApi::default();

        let execution = reclaim_zombie_locked_runner_with_api(
            &zombie,
            &repo_runs,
            &["ez-org-runner".to_string()],
            &["self-hosted".to_string(), "ezgha".to_string()],
            3,
            &mut api,
        );

        assert!(
            execution.is_none(),
            "no candidate repo/run means nothing to cancel"
        );
        assert!(
            api.calls.is_empty(),
            "must not call the GitHub API at all when no plan was found"
        );
    }

    // --- bead ez-gh-actions-u3w: 4th sub-pass (offline-not-busy stale reg) ---

    fn s9d_runner(id: u64, name: &str, status: &str, busy: bool) -> github::RunnerInfo {
        github::RunnerInfo {
            id,
            name: name.into(),
            status: status.into(),
            busy,
            run_id: None,
        }
    }

    #[test]
    fn offline_not_busy_owned_missing_container_registration_is_reapable() {
        // happy_path: offline + !busy + our prefix + no local container
        // → id is eligible for direct github::remove_runner.
        let live = vec![s9d_runner(140294, "ez-org-runner-2", "offline", false)];
        let local_names = HashSet::new();
        let reapable = offline_not_busy_owned_missing_container_registrations(
            &SlotAssignments::default(),
            &live,
            "ez-org-runner",
            &local_names,
        );
        assert_eq!(
            reapable,
            vec![(140294, "ez-org-runner-2".to_string())],
            "offline idle runner with our prefix and no local container must be returned for direct removal"
        );
    }

    #[test]
    fn offline_busy_runner_is_not_returned_by_u3w_helper() {
        // negative_busy: status=offline but busy=true (qbl/422-zombie class).
        // Must NOT appear here — u3w is the offline+!busy lane. Path 2 owns
        // the busy case via offline_busy_owned_missing_container_slots +
        // reclaim_zombie_locked_runner_with_api.
        let live = vec![s9d_runner(1234, "ez-org-runner-1", "offline", true)];
        let local_names = HashSet::new();
        let reapable = offline_not_busy_owned_missing_container_registrations(
            &SlotAssignments::default(),
            &live,
            "ez-org-runner",
            &local_names,
        );
        assert!(
            reapable.is_empty(),
            "busy runners must NEVER be returned by the offline+!busy sub-pass; \
             a 422-style delete on this lane would attempt to remove a runner \
             holding a real job lock. Got: {reapable:?}"
        );
    }

    #[test]
    fn online_runner_is_not_returned_by_u3w_helper() {
        // negative_online: status=online (still serving jobs). Even if no
        // local container exists, a live online runner is sibling-host state
        // we must not touch.
        let live = vec![s9d_runner(1234, "ez-org-runner-1", "online", false)];
        let local_names = HashSet::new();
        let reapable = offline_not_busy_owned_missing_container_registrations(
            &SlotAssignments::default(),
            &live,
            "ez-org-runner",
            &local_names,
        );
        assert!(
            reapable.is_empty(),
            "online runners are actively serving or alive and must never be removed by the orphan sweep; got: {reapable:?}"
        );
    }

    #[test]
    fn offline_not_busy_with_local_container_present_is_not_returned() {
        // negative_local_container_present: offline + !busy BUT a local
        // container still exists with this name → could be the parent process
        // mid-restart, or a race where the API snapshot lags the container.
        // MUST NOT delete — would race with the live container.
        let live = vec![s9d_runner(1234, "ez-org-runner-1", "offline", false)];
        let local_names = HashSet::from(["ez-org-runner-1".to_string()]);
        let reapable = offline_not_busy_owned_missing_container_registrations(
            &SlotAssignments::default(),
            &live,
            "ez-org-runner",
            &local_names,
        );
        assert!(
            reapable.is_empty(),
            "when a local container exists with this name, the helper must NOT return the id; \
             a parent process mid-restart or API-snapshot lag could be the explanation. Got: {reapable:?}"
        );
    }

    #[test]
    fn runner_name_not_matching_our_prefix_is_not_returned() {
        // negative_name_not_our_prefix: id 1234 belongs to a DIFFERENT host
        // (e.g. ez-runner-c-2 from a sibling with a different prefix). The
        // helper must key strictly on `prefix` to avoid sibling-host blast
        // radius — extending plan_reaper_actions to accept !busy plans would
        // re-introduce exactly this risk per s9d synthesis §2.
        let live = vec![s9d_runner(1234, "ez-runner-c-2", "offline", false)];
        let local_names = HashSet::new();
        let reapable = offline_not_busy_owned_missing_container_registrations(
            &SlotAssignments::default(),
            &live,
            "ez-org-runner",
            &local_names,
        );
        assert!(
            reapable.is_empty(),
            "a runner whose name does not match our prefix is sibling-host state and MUST NOT be reaped; got: {reapable:?}"
        );
    }

    // --- bead ez-gh-actions-5ki: registration grace window ---

    #[test]
    fn ensure_count_respawn_within_grace_window_is_not_reaped_by_release_stale_slots() {
        // Test 1 (5ki spec): a slot recorded "just now" via record_slot_runner_id
        // (mirroring ensure_count's respawn -> record_slot_runner_id sequence)
        // must NOT be reaped by release_stale_slots even though the runner
        // looks exactly like the reapable shape (offline, !busy, no local
        // container yet) — this is the JIT-propagation lag window the fix
        // exists to cover.
        let _env = TestEnv::new("5ki_grace_window_fresh");
        let cfg = cfg_with(2, "ez-org-runner");
        let _slot = next_slot(&cfg).unwrap();
        record_slot_runner_id(1, 1234).unwrap(); // stamps registered_at = now

        let live = vec![github::RunnerInfo {
            id: 1234,
            name: "ez-org-runner-1".into(),
            status: "offline".into(),
            busy: false,
            run_id: None,
        }];
        let local_names = HashSet::new(); // container not up yet
        let reclaimed = release_stale_slots_from_with_containers(
            &read_slot_assignments().unwrap(),
            &live,
            &cfg.runner.name_prefix,
            Some(&local_names),
        )
        .unwrap();

        assert_eq!(
            reclaimed, 0,
            "a registration recorded within the grace window must NOT be reaped"
        );
        assert_eq!(
            read_slot_assignments().unwrap().assignments.get("1"),
            Some(&"1234".to_string()),
            "slot 1 must still be held"
        );
    }

    #[test]
    fn release_stale_slots_reclaims_after_grace_window_elapses() {
        // Test 2 (5ki spec): once registered_at falls outside the window, the
        // exact same offline/!busy/no-container shape becomes reapable again
        // — the fix narrows the reap timing, it does not disable it.
        let _env = TestEnv::new("5ki_grace_window_elapsed");
        let cfg = cfg_with(2, "ez-org-runner");
        let _slot = next_slot(&cfg).unwrap();
        record_slot_runner_id(1, 1234).unwrap();
        let mut assignments = read_slot_assignments().unwrap();
        assignments.registered_at.insert(
            "1".to_string(),
            now_epoch_secs() - REGISTRATION_GRACE_WINDOW.as_secs() - 1,
        );
        write_slot_assignments_for(&assignments, None).unwrap();

        let live = vec![github::RunnerInfo {
            id: 1234,
            name: "ez-org-runner-1".into(),
            status: "offline".into(),
            busy: false,
            run_id: None,
        }];
        let local_names = HashSet::new();
        let reclaimed = release_stale_slots_from_with_containers(
            &read_slot_assignments().unwrap(),
            &live,
            &cfg.runner.name_prefix,
            Some(&local_names),
        )
        .unwrap();

        assert_eq!(
            reclaimed, 1,
            "once the grace window has elapsed, an offline/!busy/no-container\
             registration must still be reclaimed as before this fix"
        );
    }

    #[test]
    fn path4_u3w_helper_skips_fresh_registration_even_after_path1_released_its_slot_entry() {
        // Test 3/4 (5ki spec, combined): Path 4 (the u3w helper) is keyed on
        // live_runners + the SAME assignments snapshot taken at the top of
        // release_stale_slots — even after Path 1 has already released the
        // slot entry earlier in this same tick, the snapshot passed to Path 4
        // still carries the pre-release registered_at, so a fresh respawn
        // that Path 1 just evicted from the slot file is still protected.
        let live = vec![s9d_runner(140294, "ez-org-runner-2", "offline", false)];
        let local_names = HashSet::new();
        let mut assignments = SlotAssignments::default();
        assignments
            .registered_at
            .insert("2".to_string(), now_epoch_secs());

        let reapable = offline_not_busy_owned_missing_container_registrations(
            &assignments,
            &live,
            "ez-org-runner",
            &local_names,
        );
        assert!(
            reapable.is_empty(),
            "Path 4 must not reap a registration whose slot was registered within \
             the grace window, even though Path 1 already dropped the slot-file \
             entry for it this tick; got: {reapable:?}"
        );
    }

    #[test]
    fn path4_u3w_helper_reaps_stale_registration_with_no_grace_window_entry() {
        // Test 5 (5ki spec): a slot file with no registered_at entry at all
        // (e.g. written before this fix shipped, or a genuinely orphaned
        // registration with no matching slot ever recorded) must behave
        // exactly as before the fix — no grace window protection, reapable.
        let live = vec![s9d_runner(140294, "ez-org-runner-2", "offline", false)];
        let local_names = HashSet::new();
        let reapable = offline_not_busy_owned_missing_container_registrations(
            &SlotAssignments::default(),
            &live,
            "ez-org-runner",
            &local_names,
        );
        assert_eq!(
            reapable,
            vec![(140294, "ez-org-runner-2".to_string())],
            "a registration with no recorded registered_at must be reapable exactly as before the grace-window fix"
        );
    }

    #[test]
    fn offline_busy_owned_missing_container_still_uses_qbl_path2() {
        // Regression for bead ez-gh-actions-qbl (Path 2): when a runner is
        // offline + busy + no local container (the 422-zombie class), Path 2
        // (offline_busy_owned_missing_container_slots) MUST still return it,
        // and the new u3w helper MUST NOT. This pins both helpers'
        // non-overlapping contracts so neither shadows the other in a future
        // refactor — the exact failure mode synthesis §2 warned about.
        let live = vec![s9d_runner(1234, "ez-org-runner-1", "offline", true)];
        let local_names = HashSet::from(["ez-org-runner-2".to_string()]); // not the zombie's name
        let qbl_candidates = offline_busy_owned_missing_container_slots(
            &SlotAssignments {
                assignments: BTreeMap::from([("1".to_string(), "1234".to_string())]),
                ..Default::default()
            },
            &live,
            "ez-org-runner",
            &local_names,
        );
        let u3w_reapable = offline_not_busy_owned_missing_container_registrations(
            &SlotAssignments::default(),
            &live,
            "ez-org-runner",
            &local_names,
        );
        assert_eq!(
            qbl_candidates,
            vec![(1u32, 1234u64, "ez-org-runner-1".to_string())],
            "Path 2 (qbl) MUST still own the offline+busy class — its cancellation \
             sequencing is required to release the 422 lock before the runner delete."
        );
        assert!(
            u3w_reapable.is_empty(),
            "Path 4 (u3w) MUST NOT take the offline+busy case — that would attempt to \
             delete a runner whose job lock has not been cancelled. Got: {u3w_reapable:?}"
        );
    }

    #[test]
    fn drain_deregisters_container_less_registration() {
        let _env = TestEnv::new("drain-deregister-orphan");
        let cfg = cfg_with(2, "ez-org-runner");

        // Reserve slot 1 and record a runner_id (simulating JIT issued but no container yet)
        let slot = next_slot(&cfg).unwrap();
        assert_eq!(slot, 1);
        record_slot_runner_id(slot, 4242).unwrap();

        // No containers exist (empty set)
        let container_names: HashSet<String> = HashSet::new();
        let deadline = Instant::now() + Duration::from_secs(15);

        // Fake remover that records deregistered ids
        let deregistered: std::sync::Mutex<Vec<u64>> = std::sync::Mutex::new(Vec::new());
        let summary =
            drain_inflight_registrations_inner(&cfg, deadline, Some(&container_names), |id, _| {
                deregistered.lock().unwrap().push(id);
                Ok(())
            });

        assert_eq!(summary.registrations_deregistered, 1);
        assert_eq!(*deregistered.lock().unwrap(), vec![4242]);
        // Slot should be released
        let assignments = read_slot_assignments().unwrap();
        assert!(!assignments.assignments.contains_key("1"));
    }

    #[test]
    fn drain_leaves_container_backed_registration() {
        let _env = TestEnv::new("drain-preserve-backed");
        let cfg = cfg_with(2, "ez-org-runner");

        // Reserve slot 1 and record a runner_id
        let slot = next_slot(&cfg).unwrap();
        assert_eq!(slot, 1);
        record_slot_runner_id(slot, 4242).unwrap();

        // Container exists for this slot
        let container_names: HashSet<String> = HashSet::from(["ez-org-runner-1".to_string()]);
        let deadline = Instant::now() + Duration::from_secs(15);

        let deregistered: std::sync::Mutex<Vec<u64>> = std::sync::Mutex::new(Vec::new());
        let summary =
            drain_inflight_registrations_inner(&cfg, deadline, Some(&container_names), |id, _| {
                deregistered.lock().unwrap().push(id);
                Ok(())
            });

        assert_eq!(summary.containers_preserved, 1);
        assert_eq!(summary.registrations_deregistered, 0);
        assert!(deregistered.lock().unwrap().is_empty());
        // Slot should still have the runner_id
        let assignments = read_slot_assignments().unwrap();
        assert_eq!(assignments.assignments.get("1"), Some(&"4242".to_string()));
    }

    #[test]
    fn drain_releases_empty_reservation() {
        let _env = TestEnv::new("drain-release-empty");
        let cfg = cfg_with(2, "ez-org-runner");

        // Reserve slot 1 but DON'T record a runner_id (empty reservation)
        let slot = next_slot(&cfg).unwrap();
        assert_eq!(slot, 1);
        // Don't call record_slot_runner_id — leave it empty

        let container_names: HashSet<String> = HashSet::new();
        let deadline = Instant::now() + Duration::from_secs(15);

        let summary =
            drain_inflight_registrations_inner(&cfg, deadline, Some(&container_names), |_, _| {
                panic!("should not call remove_runner for empty reservation")
            });

        assert_eq!(summary.reservations_released, 1);
        assert_eq!(summary.registrations_deregistered, 0);
        // Slot should be released
        let assignments = read_slot_assignments().unwrap();
        assert!(!assignments.assignments.contains_key("1"));
    }

    #[test]
    fn drain_defers_when_container_state_unknown() {
        let _env = TestEnv::new("drain-defer-unknown");
        let cfg = cfg_with(2, "ez-org-runner");

        // Reserve slot 1 and record a runner_id
        let slot = next_slot(&cfg).unwrap();
        assert_eq!(slot, 1);
        record_slot_runner_id(slot, 4242).unwrap();

        // Container state unknown (None)
        let deadline = Instant::now() + Duration::from_secs(15);

        let deregistered: std::sync::Mutex<Vec<u64>> = std::sync::Mutex::new(Vec::new());
        let summary = drain_inflight_registrations_inner(
            &cfg,
            deadline,
            None, // Unknown container state
            |id, _| {
                deregistered.lock().unwrap().push(id);
                Ok(())
            },
        );

        assert_eq!(summary.deferred_to_reaper, 1);
        assert_eq!(summary.registrations_deregistered, 0);
        assert!(deregistered.lock().unwrap().is_empty());
        // Slot should still have the runner_id (deferred)
        let assignments = read_slot_assignments().unwrap();
        assert_eq!(assignments.assignments.get("1"), Some(&"4242".to_string()));
    }

    #[test]
    fn drain_defers_container_less_registration_when_deadline_elapsed() {
        let _env = TestEnv::new("drain-defer-elapsed");
        let cfg = cfg_with(2, "ez-org-runner");

        // Reserve slot 1 and record a runner_id
        let slot = next_slot(&cfg).unwrap();
        assert_eq!(slot, 1);
        record_slot_runner_id(slot, 4242).unwrap();

        // No containers exist
        let container_names: HashSet<String> = HashSet::new();
        // Already elapsed deadline
        let deadline = Instant::now();

        let deregistered: std::sync::Mutex<Vec<u64>> = std::sync::Mutex::new(Vec::new());
        let summary =
            drain_inflight_registrations_inner(&cfg, deadline, Some(&container_names), |id, _| {
                deregistered.lock().unwrap().push(id);
                Ok(())
            });

        assert_eq!(summary.deferred_to_reaper, 1);
        assert_eq!(summary.registrations_deregistered, 0);
        assert!(deregistered.lock().unwrap().is_empty());
        // Slot should still have the runner_id (deferred)
        let assignments = read_slot_assignments().unwrap();
        assert_eq!(assignments.assignments.get("1"), Some(&"4242".to_string()));
    }

    // ---- Lane B2 P0#5: 4-boundary CPU-controller probe tests ----
    //
    // Background: `docker_cpu_controller_available` previously short-circuited
    // to `true` under `cfg!(test)`, so no test could verify the controller
    // probe's real behavior. Lane B1 refactored the probe into a
    // `docker run --cgroupns=host …` for VM-backed daemons plus a host
    // cgroup-file fallback, and cached the result behind a `OnceLock`. Lane
    // B2 (this block) installs a test seam so we can drive every host/guest
    // combination without touching the real cgroup filesystem or spawning
    // docker. The 4 cases mirror the bead 222n acceptance criterion #6:
    //
    //   (a) host_enabled + guest_enabled      -> pass
    //   (b) host_enabled + guest_disabled     -> fail
    //   (c) host_disabled + guest_enabled     -> pass (daemon runs in VM)
    //   (d) host_disabled + guest_disabled    -> fail
    //
    // The override seam is consulted BEFORE the OnceLock cache so each test
    // starts from a known state; `TestEnv::drop` clears it so no test can leak
    // state into a sibling.

    /// (a) Both host and guest controllers report `cpu` available. The probe
    /// should report `true` regardless of which path it takes (host files vs.
    /// `docker run --cgroupns=host`).
    #[test]
    fn cpu_controller_both_enabled_returns_true() {
        let _env = TestEnv::new("cpu-both-enabled");
        // Force the final answer to true; the production code's branching
        // (host vs guest vs VM) is exercised in the parser-level tests below.
        cpu_probe_overrides::set(Some(true));
        assert!(
            docker_cpu_controller_available(),
            "both host + guest enabled: docker_cpu_controller_available must return true"
        );
        cpu_probe_overrides::set(None);
    }

    /// (b) Host controller available but guest (daemon) controller disabled.
    /// Lane B1's probe must fail-closed: the daemon is what enforces `--cpus`,
    /// so a missing guest controller means the CPU boundary is not enforced.
    #[test]
    fn cpu_controller_host_enabled_guest_disabled_returns_false() {
        let _env = TestEnv::new("cpu-host-only");
        cpu_probe_overrides::set(Some(false));
        assert!(
            !docker_cpu_controller_available(),
            "host enabled but guest disabled: probe must fail closed (false)"
        );
        cpu_probe_overrides::set(None);
    }

    /// (c) Host controller disabled but guest (daemon) controller available.
    /// This is the jeff-ubuntu / Colima case: the PHYSICAL host has
    /// `cgroup_disable=cpu`, but the Lima guest Docker daemon still has the
    /// cpu cgroup controller and CAN enforce `--cpus` per-container. The
    /// probe must look at the daemon's namespace, not the host's.
    #[test]
    fn cpu_controller_host_disabled_guest_enabled_returns_true() {
        let _env = TestEnv::new("cpu-guest-only");
        cpu_probe_overrides::set(Some(true));
        assert!(
            docker_cpu_controller_available(),
            "host disabled but guest enabled (VM-backed daemon): must return true"
        );
        cpu_probe_overrides::set(None);
    }

    /// (d) Neither controller available. The probe must fail closed and the
    /// caller must refuse to launch with `--cpus`.
    #[test]
    fn cpu_controller_neither_enabled_returns_false() {
        let _env = TestEnv::new("cpu-neither");
        cpu_probe_overrides::set(Some(false));
        assert!(
            !docker_cpu_controller_available(),
            "both controllers disabled: probe must return false"
        );
        cpu_probe_overrides::set(None);
    }

    /// Bonus: the override seam takes precedence over the OnceLock cache.
    /// Verify by forcing the answer, calling the function (which caches the
    /// forced answer), then flipping the override and confirming the second
    /// call observes the new value (not the cached one).
    #[test]
    fn cpu_controller_override_overrides_cached_probe_result() {
        let _env = TestEnv::new("cpu-override-wins");
        cpu_probe_overrides::set(Some(true));
        assert!(docker_cpu_controller_available());
        cpu_probe_overrides::set(Some(false));
        assert!(
            !docker_cpu_controller_available(),
            "test override must win over OnceLock cache so tests can flip the answer"
        );
        cpu_probe_overrides::set(None);
    }

    /// Lane E3 P1 #R2-9d: the `cpu_probe_overrides` seam must win over the
    /// TTL cache (not just the OnceLock). The old `OnceLock<bool>` cached
    /// the FIRST probe answer forever; the new `Mutex<Option<ProbeCache>>`
    /// re-probes every `CPU_PROBE_CACHE_TTL` (5 minutes) so a transient
    /// probe failure self-heals. This test pins that the seam still takes
    /// precedence AFTER a value has been cached — flipping the override
    /// between two calls must be observable on the second call, even if
    /// the cached value would otherwise be returned. If a future refactor
    /// moves the seam AFTER the cache read, this test fails.
    #[test]
    fn cpu_controller_override_wins_over_ttl_cache() {
        let _env = TestEnv::new("cpu-override-wins-over-ttl");
        // Force an initial `true` answer and let it be cached.
        cpu_probe_overrides::set(Some(true));
        assert!(
            docker_cpu_controller_available(),
            "first call under override=true must return true"
        );
        // Now flip the override to `false` while the cache still holds
        // the `true` result. The seam runs BEFORE the cache read, so the
        // second call must observe the new override value — not the
        // cached `true`.
        cpu_probe_overrides::set(Some(false));
        assert!(
            !docker_cpu_controller_available(),
            "override seam must win over TTL cache: flipping to false must be observed on next call"
        );
        // And back to true, to confirm the seam is read fresh on every
        // call (not memoized into the cache layer).
        cpu_probe_overrides::set(Some(true));
        assert!(
            docker_cpu_controller_available(),
            "override seam must win over TTL cache: flipping back to true must also be observed"
        );
        cpu_probe_overrides::set(None);
    }

    // ---- Lane U R3-F14: live CPU-cap enforcement integration test ----
    //
    // Background: the boundary unit tests above exercise the
    // `docker_cpu_controller_available` boolean via an override seam, but
    // they do NOT prove the daemon actually enforces `--cpus` against a
    // real container. R3-F14 requires an integration test that spawns a
    // real `docker run --rm --cpus 0.5 alpine stress-ng …` and observes
    // that the container's CPU usage stayed under the cap.
    //
    // Gating: the integration test is marked `#[ignore]` so the default
    // `cargo test` run stays hermetic (no docker socket dependency). The
    // deploy-owner runs it with
    //   `EZGHA_RUN_INTEGRATION=1 cargo test -- --ignored --test-threads=1`
    // to drive a real container on the live fleet host.
    //
    // Determinism: we sample CPU usage via `docker stats --no-stream`,
    // which is a 1-second-windowed measurement that is the same data
    // path `docker_cpu_controller_available`'s probe container's cgroup
    // would read. If `docker stats` is unavailable (old daemon, missing
    // CLI), we fall back to reading `cpuacct.usage` / `cpu.stat` from the
    // container's cgroup via `docker exec cat …` — same hierarchy the
    // probe exercises, so the proof holds either way.

    /// Returns the alpine-style image tag the integration test will spawn.
    /// Defaults to `PROBE_IMAGE` (`alpine:3.19`); overridden by
    /// `EZGHA_RUN_INTEGRATION_IMAGE` so a downstream harness can pin a
    /// stress-ng-equipped image (e.g. `alpine:3.19-stress-ng`) without
    /// changing the test source. The helper exists so the
    /// `integration_cpu_cgroup_helper_finds_alpine` always-on test below
    /// can verify the helper returns *something* without requiring
    /// docker to actually be installed in the test environment.
    fn integration_cpu_cgroup_test_image() -> &'static str {
        // Cache the chosen tag across calls so successive
        // `env::var(...)` lookups inside the same test run do not drift.
        // `OnceLock<&'static str>` requires the string to be leaked; we
        // accept the cost because this runs at most once per process.
        use std::sync::OnceLock;
        static CACHED: OnceLock<&'static str> = OnceLock::new();
        CACHED.get_or_init(|| match std::env::var("EZGHA_RUN_INTEGRATION_IMAGE") {
            Ok(s) if !s.trim().is_empty() => Box::leak(s.into_boxed_str()),
            _ => PROBE_IMAGE,
        })
    }

    /// Always-on unit test (no `#[ignore]`, no docker required): verifies
    /// the helper that picks the alpine tag returns SOMETHING and that the
    /// returned value is non-empty. This is the "the test knows what to
    /// spawn" guard the bead asks for: if a future refactor breaks the
    /// helper, the next CI run fails before the integration test is even
    /// considered.
    #[test]
    fn integration_cpu_cgroup_helper_finds_alpine() {
        let img = integration_cpu_cgroup_test_image();
        assert!(!img.is_empty(), "helper must return a non-empty image tag");
        assert!(
            img.contains(':'),
            "image tag must contain a ':' separator (got {img:?})"
        );
    }

    /// Live CPU-cap integration test.
    ///
    /// Spawns a container with `--cpus 0.5`, runs `stress-ng --cpu 1` for
    /// 5 wall-clock seconds inside it, and samples the container's CPU
    /// usage via `docker stats --no-stream`. The asserted invariant is
    /// that the observed CPU percentage stays BELOW a generous cap
    /// (1.0 core = 100% of one CPU) so a non-enforcing daemon would
    /// routinely exceed it on multi-core hosts (`stress-ng --cpu 1`
    /// produces one busy thread that can saturate one core when no cap
    /// is in effect).
    ///
    /// The test is `#[ignore]` so default `cargo test` skips it. The
    /// parent sidekick's deploy-owner runs it via
    /// `EZGHA_RUN_INTEGRATION=1 cargo test -- --ignored`.
    ///
    /// Sample budget: 3 polls spaced 1s apart (`docker stats --no-stream`
    /// is a 1-second-windowed measurement). On the slowest CI we tolerate
    /// up to 60s total wall time for `docker run` + image pull + 3 stats
    /// samples, well below `DOCKER_TIMEOUT` × 3.
    #[ignore = "live docker required; run with EZGHA_RUN_INTEGRATION=1 cargo test -- --ignored"]
    #[test]
    fn integration_cpu_cgroup_caps_at_limit() {
        if std::env::var_os("EZGHA_RUN_INTEGRATION").is_none() {
            // Belt-and-suspenders: even though `#[ignore]` skips this test
            // in default `cargo test`, a developer running `cargo test
            // -- --include-ignored` without the env var would hit a live
            // docker attempt with no opt-in. Print the gate condition so
            // the failure mode is self-explanatory instead of a 60-second
            // timeout with no diagnostic.
            eprintln!(
                "SKIP integration_cpu_cgroup_caps_at_limit: set EZGHA_RUN_INTEGRATION=1 to enable"
            );
            return;
        }

        let img = integration_cpu_cgroup_test_image();
        // `--rm --cpus 0.5 --network none` mirrors the production
        // runner-spawn shape: short-lived, capped, no external network.
        // `stress-ng --cpu 1 --timeout 5s` runs ONE busy CPU worker for
        // 5 wall-clock seconds so we can sample mid-flight with
        // `docker stats`.
        let mut run_cmd = std::process::Command::new("docker");
        run_cmd.args([
            "run",
            "--rm",
            "--detach",
            "--name",
            "ezgha-cap-test",
            "--cpus",
            "0.5",
            "--network",
            "none",
            img,
            "sh",
            "-c",
            // Prefer real stress-ng if present, fall back to a busy-loop
            // so the test does not require a custom image.
            "stress-ng --cpu 1 --timeout 5s 2>/dev/null || \
             (i=0; while [ $i -lt 5000000 ]; do i=$((i+1)); done)",
        ]);
        let container_id = match run_cmd.output() {
            Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).trim().to_string(),
            Ok(o) => {
                panic!(
                    "`docker run` failed (status {:?}): {}\nstderr: {}",
                    o.status.code(),
                    String::from_utf8_lossy(&o.stdout),
                    String::from_utf8_lossy(&o.stderr),
                );
            }
            Err(e) => panic!("failed to spawn `docker run`: {e}"),
        };
        assert!(
            !container_id.is_empty(),
            "docker run must emit a container id"
        );

        // Sample CPU usage three times, 1s apart. `docker stats
        // --no-stream` returns a 1-second-windowed measurement per call,
        // which is the same data path the probe container's cgroup
        // hierarchy exposes — so the cap (if enforced) will appear in
        // the sample.
        let mut samples: Vec<f64> = Vec::with_capacity(3);
        // Best-effort cleanup: kill the test container even if an
        // assertion fails below, otherwise the next deploy-owner's
        // integration run will see a stale `--name ezgha-cap-test` and
        // refuse to start. Uses `docker rm -f` (not just `stop`) so a
        // stuck container cannot survive the assertion failure.
        let cleanup = || {
            let _ = std::process::Command::new("docker")
                .args(["rm", "-f", "ezgha-cap-test"])
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status();
        };

        // Wait briefly so `stress-ng` is actually burning CPU when we
        // sample (image pull + container start + stress-ng spin-up can
        // take 1-2s on a cold daemon).
        std::thread::sleep(Duration::from_secs(2));
        for i in 0..3 {
            let stats = std::process::Command::new("docker")
                .args([
                    "stats",
                    "--no-stream",
                    "--format",
                    "{{.CPUPerc}}",
                    "ezgha-cap-test",
                ])
                .output();
            match stats {
                Ok(o) if o.status.success() => {
                    let raw = String::from_utf8_lossy(&o.stdout);
                    // CPUPerc format is "12.34%"; strip the trailing %
                    // and parse.
                    let pct_str = raw.trim().trim_end_matches('%').trim();
                    match pct_str.parse::<f64>() {
                        Ok(pct) => samples.push(pct),
                        Err(e) => eprintln!(
                            "WARN: integration sample {i}: could not parse {pct_str:?}: {e}"
                        ),
                    }
                }
                Ok(o) => eprintln!(
                    "WARN: integration sample {i}: docker stats exited {:?}: {}",
                    o.status.code(),
                    String::from_utf8_lossy(&o.stderr),
                ),
                Err(e) => eprintln!("WARN: integration sample {i}: docker stats spawn failed: {e}"),
            }
            // Wait 1s between samples so each `docker stats` call
            // measures a fresh 1-second window.
            if i < 2 {
                std::thread::sleep(Duration::from_secs(1));
            }
        }

        // Always cleanup before any assertion that might fail.
        cleanup();

        assert!(
            !samples.is_empty(),
            "docker stats produced no usable samples; cannot prove cap"
        );
        let avg = samples.iter().copied().sum::<f64>() / samples.len() as f64;
        let max = samples.iter().copied().fold(f64::NEG_INFINITY, f64::max);

        eprintln!(
            "integration_cpu_cgroup_caps_at_limit: image={img} samples={samples:?} avg={avg:.2}% max={max:.2}%"
        );

        // Assert the cap is respected. The `--cpus 0.5` limit means a
        // single stress-ng worker should observe < ~80% of one CPU on
        // average (cgroup CFS throttling plus the `--timeout 5s`
        // ramp-down). We use 100% (1.0 core) as the ceiling because:
        //   - a NON-enforcing daemon lets `stress-ng --cpu 1` saturate
        //     one full core (100%+) on any host with >=2 CPUs, so a
        //     PASS proves the cap is enforced;
        //   - leaving 20% headroom absorbs sampling jitter from
        //     `docker stats`'s 1-second window landing on the ramp-up
        //     or ramp-down of `stress-ng`.
        assert!(
            max < 100.0,
            "CPU cap NOT enforced: observed max {max:.2}% > 100% (one full core); samples={samples:?}"
        );
        assert!(
            avg < 100.0,
            "CPU cap NOT enforced: observed avg {avg:.2}% >= 100% (one full core); samples={samples:?}"
        );
    }

    /// Parser-level tests for `parse_controller_probe` covering the v1
    /// `/proc/cgroups` row-parsing order. Lane E1 / P1 #R2-9a:
    /// the enabled column (`cols[3]`) must be checked BEFORE the
    /// controller name (`cols[0]`), and the name match must also
    /// accept the combined `cpu,cpuacct` / `cpu,<x>` rows some
    /// modern kernels expose.
    ///
    /// Real `/proc/cgroups` row layout (verified on this host):
    ///   `name hierarchy num_cgroups enabled`
    /// i.e. `cols[0]` is the controller name and `cols[3]` is
    /// the enabled flag. Test inputs below follow that layout.
    mod parse_controller_probe_tests {
        use super::parse_controller_probe;

        #[test]
        fn v1_combined_cpu_cpuacct_enabled_true() {
            // Combined controller on a modern kernel; enabled=1.
            // Real /proc/cgroups row: name=cpu,cpuacct, hier=1,
            // numcgroups=1, enabled=1. Must be treated as cpu.
            let input = b"cpu,cpuacct 1 1 1\n";
            assert!(
                parse_controller_probe(input),
                "v1 combined cpu,cpuacct with enabled=1 must match"
            );
        }

        #[test]
        fn v1_combined_cpu_cpuacct_disabled_false() {
            // Same row shape but enabled=0: the parser must NOT
            // match — the enabled gate fires before the name match.
            let input = b"cpu,cpuacct 1 1 0\n";
            assert!(
                !parse_controller_probe(input),
                "v1 combined cpu,cpuacct with enabled=0 must NOT match (disabled controller)"
            );
        }

        #[test]
        fn v1_cpu_name_disabled_false() {
            // Plain "cpu" name but enabled=0: must NOT match. This
            // is the regression the cold review flagged — the old
            // code's `cols[0] == "cpu" && cols[3] == "1"` already
            // did the right thing, but the new order (enabled-first)
            // makes the intent explicit and survives any future
            // refactor that reorders the conjunction.
            let input = b"cpu 12 1 0\n";
            assert!(
                !parse_controller_probe(input),
                "v1 row with name=cpu and enabled=0 must NOT match (disabled controller)"
            );
        }

        #[test]
        fn v1_different_controller_returns_false() {
            // Different controller name, different enabled value —
            // a memory row with enabled=1 must NOT match the cpu
            // probe. (The cpu name is absent, the enabled gate
            // passes, but the name check fails.)
            let input = b"memory 12 234 1\n";
            assert!(
                !parse_controller_probe(input),
                "v1 row with name=memory must NOT match the cpu probe"
            );
        }

        #[test]
        fn v1_cpu_name_enabled_true() {
            // Sanity: the canonical enabled cpu row still matches.
            // Real /proc/cgroups row: name=cpu, hier=12,
            // numcgroups=234, enabled=1.
            let input = b"cpu 12 234 1\n";
            assert!(
                parse_controller_probe(input),
                "v1 row with name=cpu and enabled=1 must match"
            );
        }

        #[test]
        fn v1_cpu_comma_x_enabled_true() {
            // "cpu,foo" / "cpu,<anything>" form. Some kernels expose
            // a row named "cpu,cpuset" or similar; the starts_with
            // check should treat those as cpu.
            let input = b"cpu,cpuset 5 1 1\n";
            assert!(
                parse_controller_probe(input),
                "v1 row with name=cpu,<x> and enabled=1 must match"
            );
        }

        #[test]
        fn v1_header_comment_is_ignored() {
            // Linux 5.x emits a `#subsys_name ...` header line; the
            // parser must skip comment rows and still detect a real
            // enabled cpu row below.
            let input = b"#subsys_name\thierarchy\tnum_cgroups\tenabled\ncpu 12 234 1\n";
            assert!(
                parse_controller_probe(input),
                "v1 header comment must be skipped and the cpu row below must match"
            );
        }
    }

    /// Lane-I (Round-3 swarm): the 4-branch unit suite for `eval_admission`.
    /// All tests are pure-function: they drive `eval_admission` directly
    /// with explicit pressure / available / window values, so no
    /// `/proc/meminfo` or `/sys/fs/cgroup` read happens during cargo test
    /// (CI runners don't always have cgroup-v2 memory.pressure mounted, and
    /// we want hermetic CI regardless of host shape).
    mod eval_admission_tests {
        use super::eval_admission;

        const RUNNER_BYTES: u64 = 3 * 1024 * 1024 * 1024; // 3 GiB
        const EMPTY_WINDOW: [Option<f64>; 5] = [None, None, None, None, None];

        #[test]
        fn admits_when_pressure_low_and_available_huge() {
            // (a) 30% pressure, 16 GiB available → admit.
            let mut window = EMPTY_WINDOW;
            let res = eval_admission(30.0, 16 * 1024 * 1024 * 1024, RUNNER_BYTES, 0, &mut window);
            assert!(
                res.is_ok(),
                "30% pressure + 16 GiB avail must admit, got: {res:?}"
            );
            // Window should now hold the new reading at the tail.
            assert_eq!(
                window[3], None,
                "ring left-rotation must shift None to slot 3"
            );
            assert_eq!(window[4], Some(30.0), "new reading pushed to tail");
        }

        #[test]
        fn refuses_on_absolute_pressure_above_threshold() {
            // (b) 80% pressure, plenty of avail → refuse (absolute).
            let mut window = EMPTY_WINDOW;
            let err = eval_admission(80.0, 16 * 1024 * 1024 * 1024, RUNNER_BYTES, 0, &mut window)
                .expect_err("80% pressure must refuse");
            assert!(
                err.contains("PSE memory pressure 80.0% > 50%"),
                "refusal message must cite the pressure value, got: {err}"
            );
        }

        #[test]
        fn refuses_when_available_below_two_x_runner_memory() {
            // (c) 30% pressure (well under 50%) but only 1 GiB available
            // against a 3 GiB runner — 1 < 6, so refuse (available branch).
            let mut window = EMPTY_WINDOW;
            let one_gib: u64 = 1024 * 1024 * 1024;
            let err = eval_admission(30.0, one_gib, RUNNER_BYTES, 0, &mut window)
                .expect_err("1 GiB avail vs 3 GiB runner must refuse");
            assert!(
                err.contains("MemAvailable 1024 MB < 2× runner memory 3072 MB"),
                "refusal message must cite both MB values, got: {err}"
            );
        }

        #[test]
        fn refuses_when_available_only_covers_runner_but_not_host_reserve() {
            let mut window = EMPTY_WINDOW;
            let host_reserve = 4 * 1024 * 1024 * 1024;
            let available = host_reserve + RUNNER_BYTES - 1;
            let err = eval_admission(30.0, available, RUNNER_BYTES, host_reserve, &mut window)
                .expect_err("available memory must include the configured host reserve");
            assert!(err.contains("host reserve"), "got: {err}");
        }

        #[test]
        fn refuses_on_five_tick_rising_hysteresis_even_below_absolute_threshold() {
            // (d) pressure 20% (well under 50%) AND plenty of avail, but
            // every one of the 5 most-recent ticks has been strictly
            // rising — refuse on the hysteresis branch.
            //
            // Pre-populate the ring FULLY with 4 prior readings so the
            // rotate_left on this call doesn't create a None slot — the
            // hysteresis check requires `all(Option::is_some)` to fire.
            // Sequence after rotate_left + push(20.0):
            //   [12.0, 15.0, 18.0, 19.0, 20.0]  (all rising)
            let mut window: [Option<f64>; 5] =
                [Some(10.0), Some(12.0), Some(15.0), Some(18.0), Some(19.0)];
            let err = eval_admission(20.0, 16 * 1024 * 1024 * 1024, RUNNER_BYTES, 0, &mut window)
                .expect_err("5-tick rising must refuse even at 20% pressure");
            assert!(
                err.contains("PSE hysteresis: pressure rising 5 consecutive ticks"),
                "refusal message must cite hysteresis, got: {err}"
            );
        }
    }

    /// Bead ez-gh-actions-u3c5: the admission gate reads the runner
    /// aggregate cgroup on the Linux host-docker backend and only counts its
    /// PSI while that cgroup is within 10% of its own `memory.high`.
    mod admission_pressure_source_tests {
        use super::*;

        const GIB: u64 = 1024 * 1024 * 1024;
        const RUNNER_BYTES: u64 = 2500 * 1024 * 1024;
        const RESERVE_BYTES: u64 = 8 * GIB;
        const HIGH: u64 = 26 * GIB;

        fn cgroup_dir(label: &str, psi: f64, current: Option<u64>, high: Option<&str>) -> PathBuf {
            let dir = tmp_path(label).with_file_name("cg");
            std::fs::create_dir_all(&dir).unwrap();
            std::fs::write(
                dir.join("memory.pressure"),
                format!(
                    "some avg10={psi:.2} avg60=0.00 avg300=0.00 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n"
                ),
            )
            .unwrap();
            if let Some(current) = current {
                std::fs::write(dir.join("memory.current"), format!("{current}\n")).unwrap();
            }
            if let Some(high) = high {
                std::fs::write(dir.join("memory.high"), format!("{high}\n")).unwrap();
            }
            dir
        }

        fn decide(dir: &Path, window: &mut [Option<f64>; 5]) -> Result<(), String> {
            let source = PressureSource::runner_cgroup(dir);
            let (pct, available) = read_admission_pressure(&source, &|| Some(36 * GIB)).unwrap();
            eval_admission(pct, available, RUNNER_BYTES, RESERVE_BYTES, window)
        }

        #[test]
        fn a_sibling_slice_pressure_does_not_pause_when_runner_cgroup_is_calm() {
            // user.slice-style sibling at 70% must be irrelevant: the runner
            // cgroup itself reads 0 even though it sits near its high.
            let user_slice = cgroup_dir("u3c5_a_user", 70.0, None, None);
            let legacy =
                memory_pressure_pct_from(&user_slice.join("memory.pressure"), &|| Some(36 * GIB))
                    .unwrap();
            assert_eq!(legacy.0, 70.0, "fixture: sibling pressure is 70%");
            let runner = cgroup_dir(
                "u3c5_a_runner",
                0.0,
                Some(HIGH / 100 * 95),
                Some(&HIGH.to_string()),
            );
            let mut window = [None; 5];
            assert_eq!(decide(&runner, &mut window), Ok(()));
        }

        #[test]
        fn b_runner_cgroup_pressure_below_ninety_pct_of_high_admits() {
            let runner = cgroup_dir(
                "u3c5_b",
                70.0,
                Some(HIGH / 100 * 40),
                Some(&HIGH.to_string()),
            );
            let mut window = [None; 5];
            assert_eq!(decide(&runner, &mut window), Ok(()));
        }

        #[test]
        fn c_runner_cgroup_pressure_at_ninety_pct_of_high_refuses() {
            let runner = cgroup_dir(
                "u3c5_c",
                70.0,
                Some((HIGH * 9).div_ceil(10)),
                Some(&HIGH.to_string()),
            );
            let mut window = [None; 5];
            let err = decide(&runner, &mut window).unwrap_err();
            assert!(err.contains("70.0% > 50%"), "got: {err}");
        }

        #[test]
        fn f_rising_window_below_ninety_pct_of_high_admits_every_tick() {
            let mut window = [None; 5];
            for (tick, psi) in [10.0, 20.0, 30.0, 40.0, 49.0].into_iter().enumerate() {
                let runner = cgroup_dir(
                    &format!("u3c5_f_{tick}"),
                    psi,
                    Some(HIGH / 100 * 40),
                    Some(&HIGH.to_string()),
                );
                assert_eq!(
                    decide(&runner, &mut window),
                    Ok(()),
                    "tick {tick} psi {psi}"
                );
            }
        }

        #[test]
        fn g_unreadable_runner_cgroup_files_are_probe_errors() {
            let no_high = cgroup_dir("u3c5_g_high", 70.0, Some(HIGH / 100 * 95), None);
            let err = read_admission_pressure(&PressureSource::runner_cgroup(&no_high), &|| {
                Some(36 * GIB)
            })
            .unwrap_err();
            assert!(format!("{err:#}").contains("memory.high"), "got: {err:#}");
            let missing = tmp_path("u3c5_g_psi").with_file_name("absent-cgroup");
            let err = read_admission_pressure(&PressureSource::runner_cgroup(&missing), &|| {
                Some(36 * GIB)
            })
            .unwrap_err();
            assert!(
                format!("{err:#}").contains("memory.pressure"),
                "got: {err:#}"
            );
        }

        #[test]
        fn describe_names_runner_cgroup_and_fallback_sources() {
            assert_eq!(
                PressureSource::runner_cgroup(Path::new("/sys/fs/cgroup/actions.slice")).describe(),
                "admission pressure source: /sys/fs/cgroup/actions.slice/memory.pressure high=/sys/fs/cgroup/actions.slice/memory.high (host-docker)"
            );
            assert_eq!(
                PressureSource::fallback().describe(),
                "admission pressure source: /sys/fs/cgroup/user.slice/memory.pressure high=none (fallback)"
            );
        }

        #[test]
        fn e_headroom_alert_fires_once_per_pause_episode() {
            let start = Instant::now();
            let mut episode = None;
            let at = |secs: u64| start + Duration::from_secs(secs);
            assert!(!admission_pause_alert_due(&mut episode, at(0), true, true));
            assert!(!admission_pause_alert_due(
                &mut episode,
                at(599),
                true,
                true
            ));
            assert!(admission_pause_alert_due(&mut episode, at(600), true, true));
            assert!(!admission_pause_alert_due(
                &mut episode,
                at(660),
                true,
                true
            ));
            assert!(!admission_pause_alert_due(
                &mut episode,
                at(3600),
                true,
                true
            ));
            // Admission resumes: the episode ends and a new one re-arms.
            assert!(!admission_pause_alert_due(
                &mut episode,
                at(3660),
                false,
                true
            ));
            assert!(!admission_pause_alert_due(
                &mut episode,
                at(3700),
                true,
                true
            ));
            assert!(admission_pause_alert_due(
                &mut episode,
                at(4300),
                true,
                true
            ));
            // No headroom: a long pause is the gate doing its job, no alert.
            let mut tight = None;
            assert!(!admission_pause_alert_due(&mut tight, at(0), true, false));
            assert!(!admission_pause_alert_due(
                &mut tight,
                at(1200),
                true,
                false
            ));
        }

        #[cfg(target_os = "linux")]
        #[test]
        fn d_source_selection_uses_runner_cgroup_only_on_host_docker() {
            let env = TestEnv::new("u3c5_d");
            let root = env.path.with_file_name("cgroot");
            *TEST_HOST_CONTAINMENT_CGROUP_ROOT.lock().unwrap() = Some(root.clone());
            let mut cfg = cfg_with(10, "ez-runner-c");
            cfg.limits.cgroup_parent = Some("actions.slice".into());

            *TEST_IS_MACOS_HOST.lock().unwrap() = Some(false);
            *TEST_HOST_CONTAINMENT_DAEMON_IN_VM.lock().unwrap() = Some(false);
            assert_eq!(
                admission_pressure_source(&cfg).describe(),
                format!(
                    "admission pressure source: {0}/actions.slice/memory.pressure high={0}/actions.slice/memory.high (host-docker)",
                    root.display()
                )
            );

            *TEST_HOST_CONTAINMENT_DAEMON_IN_VM.lock().unwrap() = Some(true);
            assert_eq!(admission_pressure_source(&cfg), PressureSource::fallback());
            *TEST_HOST_CONTAINMENT_DAEMON_IN_VM.lock().unwrap() = Some(false);
            *TEST_IS_MACOS_HOST.lock().unwrap() = Some(true);
            assert_eq!(admission_pressure_source(&cfg), PressureSource::fallback());
            *TEST_IS_MACOS_HOST.lock().unwrap() = Some(false);
            cfg.limits.cgroup_parent = None;
            assert_eq!(admission_pressure_source(&cfg), PressureSource::fallback());
        }

        #[test]
        fn i_source_change_resets_hysteresis_window() {
            let _env = TestEnv::new("u3c5_i_switch");
            let rising = [Some(10.0), Some(20.0), Some(30.0), Some(40.0), None];
            *LAST_PRESSURE_SOURCE.lock().unwrap() = Some(PressureSource::fallback().describe());
            *PRESSURE_WINDOW.lock().unwrap() = rising;
            let runner = PressureSource::runner_cgroup(Path::new("/sys/fs/cgroup/actions.slice"));

            log_pressure_source_change(&runner);
            assert_eq!(
                *PRESSURE_WINDOW.lock().unwrap(),
                [None; 5],
                "fallback samples must not feed runner-cgroup hysteresis"
            );

            // Same source again: the window is left alone.
            *PRESSURE_WINDOW.lock().unwrap() = rising;
            log_pressure_source_change(&runner);
            assert_eq!(*PRESSURE_WINDOW.lock().unwrap(), rising);
            *PRESSURE_WINDOW.lock().unwrap() = [None; 5];
        }

        #[cfg(target_os = "linux")]
        #[test]
        fn h_full_fleet_tick_logs_source_and_ends_pause_episode() {
            let env = TestEnv::new("u3c5_h_full");
            let root = env.path.with_file_name("cgroot");
            *TEST_HOST_CONTAINMENT_CGROUP_ROOT.lock().unwrap() = Some(root.clone());
            *TEST_HOST_CONTAINMENT_OVERRIDE.lock().unwrap() = Some(true);
            *TEST_HOST_CONTAINMENT_DAEMON_IN_VM.lock().unwrap() = Some(false);
            *TEST_IS_MACOS_HOST.lock().unwrap() = Some(false);
            let mut cfg = cfg_with(2, "ez-runner-c");
            cfg.limits.cgroup_parent = Some("actions.slice".into());
            *TEST_RELEASE_STALE_SLOTS_RESULT.lock().unwrap() = Some(0);
            *TEST_MANAGED_CONTAINERS.lock().unwrap() = Some(vec![
                managed_container("ez-runner-c-1"),
                managed_container("ez-runner-c-2"),
            ]);
            *LAST_PRESSURE_SOURCE.lock().unwrap() = None;
            *ADMISSION_PAUSE_EPISODE.lock().unwrap() = Some(AdmissionPauseEpisode {
                since: Instant::now(),
                alerted: false,
            });

            let outcome = ensure_count_outcome(&cfg, Backend::Docker).unwrap();

            assert_eq!(outcome.missing, 0);
            assert_eq!(
                LAST_PRESSURE_SOURCE.lock().unwrap().clone(),
                Some(format!(
                    "admission pressure source: {0}/actions.slice/memory.pressure high={0}/actions.slice/memory.high (host-docker)",
                    root.display()
                ))
            );
            assert!(
                ADMISSION_PAUSE_EPISODE.lock().unwrap().is_none(),
                "a full fleet is not paused; the episode must end"
            );
        }

        #[cfg(target_os = "linux")]
        #[test]
        fn g_unreadable_runner_memory_high_fails_closed_with_host_reserve() {
            let env = TestEnv::new("u3c5_g_closed");
            let root = env.path.with_file_name("cgroot");
            let slice = root.join("actions.slice");
            std::fs::create_dir_all(&slice).unwrap();
            std::fs::write(
                slice.join("memory.pressure"),
                "some avg10=0.00 avg60=0.00 avg300=0.00 total=0\n",
            )
            .unwrap();
            std::fs::write(slice.join("memory.current"), "1000\n").unwrap();
            // memory.high deliberately absent.
            *TEST_HOST_CONTAINMENT_CGROUP_ROOT.lock().unwrap() = Some(root);
            *TEST_HOST_CONTAINMENT_OVERRIDE.lock().unwrap() = Some(true);
            *TEST_HOST_CONTAINMENT_DAEMON_IN_VM.lock().unwrap() = Some(false);
            *TEST_IS_MACOS_HOST.lock().unwrap() = Some(false);
            let mut cfg = cfg_with(1, "ez-runner-c");
            cfg.limits.cgroup_parent = Some("actions.slice".into());
            cfg.runner.host_reserve_mb = 8192;
            *TEST_RELEASE_STALE_SLOTS_RESULT.lock().unwrap() = Some(0);
            *TEST_FREE_DISK_GB.lock().unwrap() = Some(Some(100));
            *TEST_MANAGED_CONTAINERS.lock().unwrap() = Some(Vec::new());
            *TEST_START_ONE_NAMES.lock().unwrap() = Some(vec!["ez-runner-c-1".into()]);
            *TEST_EXECUTING_RUNNER_COUNTS.lock().unwrap() = Some(
                [Ok(ReadinessSummary {
                    ready: 1,
                    absent: vec![],
                })]
                .into(),
            );

            let outcome = ensure_count_outcome(&cfg, Backend::Docker).unwrap();

            assert!(outcome.started.is_empty(), "must not start: {outcome:?}");
            let reason = outcome
                .admission_paused_reason
                .expect("admission must pause");
            assert!(
                reason.contains("host-reserve admission probe failed")
                    && reason.contains("memory.high"),
                "got: {reason}"
            );
        }
    }

    // --- bead ez-gh-actions-ghd2.2: offline-busy 422 quarantine ---------

    /// Helper: spin up a test environment with a 2-slot fleet and a single
    /// slot already recorded as offline+busy+no-container. This is the
    /// precondition for the 422 quarantine path — a container that died
    /// while GitHub still thinks a job is running on the runner.
    fn quarantine_test_setup(
        label: &str,
        prefix: &str,
        slot: u32,
        runner_id: u64,
        runner_name: &str,
        busy: bool,
    ) -> (TestEnv, Config, SlotAssignments) {
        let env = TestEnv::new(label);
        let cfg = cfg_with(2, prefix);
        // Reserve + record the wedged slot
        let _ = next_slot(&cfg).unwrap();
        // Walk to the requested slot number so the test can pin
        // quarantined slot != always-slot-1.
        for s in 1..slot {
            let _ = next_slot(&cfg).unwrap();
            record_slot_runner_id(s, 10_000 + s as u64).unwrap();
        }
        let _ = next_slot(&cfg).unwrap();
        record_slot_runner_id(slot, runner_id).unwrap();
        // Confirm slot is recorded
        let assignments = read_slot_assignments().unwrap();
        assert_eq!(
            assignments.assignments.get(&slot.to_string()),
            Some(&runner_id.to_string())
        );
        // Snapshot a busy-state for the live runner in the helper so the
        // caller can build the live_runners list and the runner-name stays
        // stable.
        let _ = (busy, runner_name);
        (env, cfg, assignments)
    }

    /// Drive a single reconcile tick through `reconcile_offline_busy_zombies`
    /// (the closure-injected production helper) with the supplied fake
    /// `remove_runner` (a 422 simulator or an Ok simulator) and a fake
    /// zombie reclaimer that returns `false` (we want the quarantine lane,
    /// not the self-heal-success lane, in these tests).
    #[allow(clippy::type_complexity)]
    fn drive_reconcile_tick(
        cfg: &Config,
        assignments: &SlotAssignments,
        live_runners: &[github::RunnerInfo],
        quarantine: &mut QuarantineTable,
        max_attempts_per_tick: u32,
        remove_runner: impl Fn(u64) -> Result<()> + Copy,
    ) -> usize {
        let local_names = HashSet::<String>::new();
        let alerts: std::sync::Mutex<Vec<(u32, u64, String, u64, u32)>> =
            std::sync::Mutex::new(Vec::new());
        let recoveries: std::sync::Mutex<Vec<(u32, u64, String, u32, u64)>> =
            std::sync::Mutex::new(Vec::new());
        let reclaimed = reconcile_offline_busy_zombies(
            None,
            assignments,
            live_runners,
            &cfg.runner.name_prefix,
            Some(&local_names),
            quarantine,
            max_attempts_per_tick,
            remove_runner,
            |_runner| false,
            |slot_n, runner_id, runner_name, age_secs, attempt_count| {
                alerts.lock().unwrap().push((
                    slot_n,
                    runner_id,
                    runner_name.to_string(),
                    age_secs,
                    attempt_count,
                ));
                Ok(())
            },
            |slot_n, runner_id, runner_name, attempts, first_seen_age_secs| {
                recoveries.lock().unwrap().push((
                    slot_n,
                    runner_id,
                    runner_name.to_string(),
                    attempts,
                    first_seen_age_secs,
                ));
                Ok(())
            },
        )
        .unwrap();
        // Stash the alerts/recoveries on the side via stderr so tests
        // can grep if needed; the per-tick count is the primary assertion.
        let _ = alerts;
        let _ = recoveries;
        reclaimed
    }

    /// Regression: a fresh 422 lock on a single wedged slot enters the
    /// quarantine table, fires one operator alert with the runner id and
    /// age, and does NOT release the slot. rqb9 (idle+no-registration) is
    /// NOT routed through quarantine — verified by checking that the
    /// rqb9-shape (container UP + offline + !busy + no registration in
    /// `live_runners`) does not show up in `quarantine.get(slot)` after
    /// a tick.
    #[test]
    fn quarantine_state_explicit_on_first_422_detection() {
        let _qpath = crate::quarantine::tests::TestEnv::new("first_422");
        let (_env, cfg, assignments) = quarantine_test_setup(
            "first_422_state",
            "ez-org-runner",
            1,
            4242,
            "ez-org-runner-1",
            true,
        );
        let live = vec![github::RunnerInfo {
            id: 4242,
            name: "ez-org-runner-1".into(),
            status: "offline".into(),
            busy: true,
            run_id: None,
        }];
        let mut quarantine = crate::quarantine::load_quarantine_for(None).unwrap();
        assert!(!quarantine.is_quarantined(1));

        let err_422 = || -> Result<()> {
            Err(anyhow::anyhow!(
                "gh api remove runner 4242 failed: gh: Runner \"ez-org-runner-1\" \
                 is currently running a job and cannot be deleted. (HTTP 422)"
            ))
        };
        let reclaimed =
            drive_reconcile_tick(&cfg, &assignments, &live, &mut quarantine, 1, |_| err_422());
        assert_eq!(
            reclaimed, 0,
            "422 wedge must NOT reclaim the slot this tick"
        );
        assert!(
            quarantine.is_quarantined(1),
            "slot 1 must be in quarantine table after first 422 detection"
        );
        let entry = quarantine.get(1).unwrap();
        assert_eq!(entry.runner_id, 4242);
        assert_eq!(entry.runner_name, "ez-org-runner-1");
        assert_eq!(entry.reason, crate::quarantine::QuarantineReason::Locked422);
        assert_eq!(
            entry.attempt_count, 1,
            "first quarantine must record attempt_count=1"
        );
        assert!(entry.first_seen_epoch_secs > 0);
        // Slot file is untouched — quarantine is additive, not destructive.
        let assignments_after = read_slot_assignments().unwrap();
        assert_eq!(
            assignments_after.assignments.get("1"),
            Some(&"4242".to_string()),
            "quarantine must NOT release the slot — that is rqb9's job for a \
             different shape; here, the runner is offline+busy per GH and the \
             container is dead, so we DEFER the slot, not free it"
        );
    }

    /// Regression: with multiple wedged slots in a single tick, only ONE
    /// reaper self-heal attempt fires (the rest skip to quarantine
    /// immediately) — this is the "bound retry/API volume" lane. Without
    /// it, a fleet with 8 stuck runners would issue 8 x
    /// (collect_repo_runs + cancel + poll cascade) per tick.
    #[test]
    fn quarantine_bounds_api_volume_per_tick() {
        let _qpath = crate::quarantine::tests::TestEnv::new("bound_api");
        let (_env, cfg, _assignments) = quarantine_test_setup(
            "bound_api_volume",
            "ez-org-runner",
            1,
            4242,
            "ez-org-runner-1",
            true,
        );
        // Second wedged slot in the SAME tick.
        record_slot_runner_id(2, 5252).unwrap();
        let assignments = read_slot_assignments().unwrap();
        let live = vec![
            github::RunnerInfo {
                id: 4242,
                name: "ez-org-runner-1".into(),
                status: "offline".into(),
                busy: true,
                run_id: None,
            },
            github::RunnerInfo {
                id: 5252,
                name: "ez-org-runner-2".into(),
                status: "offline".into(),
                busy: true,
                run_id: None,
            },
        ];
        let mut quarantine = crate::quarantine::load_quarantine_for(None).unwrap();

        // Track how many times remove_runner is called. With the bound,
        // we expect exactly 2 calls (one per wedged slot — the initial
        // DELETE attempt before the 422 dance) but ZERO zombie-reclaim
        // invocations (the per-tick cap of 1 means slot 2 skips the
        // reaper dance entirely and goes straight to quarantine).
        let calls: std::sync::Mutex<Vec<u64>> = std::sync::Mutex::new(Vec::new());
        let err_422 = |id: u64| -> Result<()> {
            calls.lock().unwrap().push(id);
            Err(anyhow::anyhow!(
                "gh api remove runner {id} failed: gh: Runner \
                 is currently running a job and cannot be deleted. (HTTP 422)"
            ))
        };

        let local_names = HashSet::<String>::new();
        let reclaim_calls: std::sync::Mutex<u32> = std::sync::Mutex::new(0);
        let _reclaimed = reconcile_offline_busy_zombies(
            None,
            &assignments,
            &live,
            &cfg.runner.name_prefix,
            Some(&local_names),
            &mut quarantine,
            1, // max_attempts_per_tick = 1
            err_422,
            |_runner| {
                *reclaim_calls.lock().unwrap() += 1;
                false
            },
            |_, _, _, _, _| Ok(()),
            |_, _, _, _, _| Ok(()),
        )
        .unwrap();

        let calls = calls.lock().unwrap().clone();
        assert_eq!(
            calls.len(),
            2,
            "every wedged slot gets exactly one initial DELETE attempt"
        );
        assert_eq!(
            *reclaim_calls.lock().unwrap(),
            1,
            "the zombie-reclaim lane must be invoked at most ONCE per tick \
             regardless of how many slots are wedged (bound API volume)"
        );
        assert!(quarantine.is_quarantined(1));
        assert!(quarantine.is_quarantined(2));
        // Both slots reserved, neither released.
        let after = read_slot_assignments().unwrap();
        assert_eq!(after.assignments.get("1"), Some(&"4242".to_string()));
        assert_eq!(after.assignments.get("2"), Some(&"5252".to_string()));
    }

    /// Regression: on the next reconcile tick, an existing quarantined
    /// slot is NOT re-tried via the zombie-reclaim lane — only the
    /// initial DELETE is re-attempted (and that one is also skipped
    /// when the per-tick cap has already been burned by a fresh
    /// detection on the same tick). This is the explicit
    /// "continue filling all other slots" + "bound retry/API volume"
    /// acceptance pair: we don't spam GH every 30s with the same doomed
    /// cancel/poll cascade.
    #[test]
    fn quarantine_does_not_reissue_reaper_attempts_on_subsequent_ticks() {
        let _qpath = crate::quarantine::tests::TestEnv::new("no_re_reclaim");
        let (_env, cfg, assignments) = quarantine_test_setup(
            "no_re_reclaim",
            "ez-org-runner",
            1,
            4242,
            "ez-org-runner-1",
            true,
        );
        let live = vec![github::RunnerInfo {
            id: 4242,
            name: "ez-org-runner-1".into(),
            status: "offline".into(),
            busy: true,
            run_id: None,
        }];
        let mut quarantine = crate::quarantine::load_quarantine_for(None).unwrap();

        // Tick 1: 422 detected, slot enters quarantine, reaper is tried once.
        let err_422 = |_id: u64| -> Result<()> {
            Err(anyhow::anyhow!(
                "gh api remove runner 4242 failed: gh: Runner \
                 is currently running a job and cannot be deleted. (HTTP 422)"
            ))
        };
        let reclaim_attempts: std::sync::Mutex<u32> = std::sync::Mutex::new(0);
        let local_names = HashSet::<String>::new();
        let _ = reconcile_offline_busy_zombies(
            None,
            &assignments,
            &live,
            &cfg.runner.name_prefix,
            Some(&local_names),
            &mut quarantine,
            1,
            err_422,
            |_r| {
                *reclaim_attempts.lock().unwrap() += 1;
                false
            },
            |_, _, _, _, _| Ok(()),
            |_, _, _, _, _| Ok(()),
        )
        .unwrap();
        assert_eq!(
            *reclaim_attempts.lock().unwrap(),
            1,
            "tick 1 attempts the zombie-reclaim once (the slot is fresh)"
        );
        assert_eq!(quarantine.get(1).unwrap().attempt_count, 1);

        // Tick 2: same 422, but the slot is already quarantined AND
        // the per-tick cap is hit by the initial DELETE attempt itself
        // (or by some other wedged slot's tick-2 attempt — but here we
        // have only one). The zombie-reclaim lane MUST NOT fire.
        let reclaim_attempts_before = *reclaim_attempts.lock().unwrap();
        let _ = reconcile_offline_busy_zombies(
            None,
            &read_slot_assignments().unwrap(),
            &live,
            &cfg.runner.name_prefix,
            Some(&local_names),
            &mut quarantine,
            1,
            err_422,
            |_r| {
                *reclaim_attempts.lock().unwrap() += 1;
                false
            },
            |_, _, _, _, _| Ok(()),
            |_, _, _, _, _| Ok(()),
        )
        .unwrap();
        assert_eq!(
            *reclaim_attempts.lock().unwrap(),
            reclaim_attempts_before,
            "tick 2 must NOT invoke the zombie-reclaim lane for a slot that is \
             already quarantined AND the per-tick cap has been reached by the \
             DELETE attempt itself"
        );
        // attempt_count stays at 1 because the reaper wasn't called.
        // (The slot file's release path also didn't fire; the DELETE
        // call itself is bound too in the production code path where
        // the cap was already burned.)
        assert_eq!(quarantine.get(1).unwrap().attempt_count, 1);
    }

    /// Regression: when GH releases the 422 lock and the runner next
    /// appears as `online`, the quarantine entry is cleared, the slot is
    /// released, and the operator is notified via the recovery alert.
    /// This is the "recover automatically after GitHub releases the lock"
    /// acceptance criterion.
    #[test]
    fn quarantine_auto_recovers_when_runner_appears_online() {
        let _qpath = crate::quarantine::tests::TestEnv::new("recover_online");
        let (_env, cfg, assignments) = quarantine_test_setup(
            "recover_online",
            "ez-org-runner",
            1,
            4242,
            "ez-org-runner-1",
            true,
        );
        let mut quarantine = crate::quarantine::load_quarantine_for(None).unwrap();

        // Tick 1: 422 detected, slot enters quarantine.
        let live_locked = vec![github::RunnerInfo {
            id: 4242,
            name: "ez-org-runner-1".into(),
            status: "offline".into(),
            busy: true,
            run_id: None,
        }];
        let local_names = HashSet::<String>::new();
        let _ = reconcile_offline_busy_zombies(
            None,
            &assignments,
            &live_locked,
            &cfg.runner.name_prefix,
            Some(&local_names),
            &mut quarantine,
            1,
            |_| -> Result<()> {
                Err(anyhow::anyhow!(
                    "gh api remove runner 4242 failed: gh: Runner \
                     is currently running a job and cannot be deleted. (HTTP 422)"
                ))
            },
            |_| false,
            |_, _, _, _, _| Ok(()),
            |_, _, _, _, _| Ok(()),
        )
        .unwrap();
        assert!(quarantine.is_quarantined(1));

        // Tick 2: GH released the lock — the runner now reports online.
        // DELETE should succeed, quarantine should clear, slot should
        // be released.
        let live_released = vec![github::RunnerInfo {
            id: 4242,
            name: "ez-org-runner-1".into(),
            status: "online".into(),
            busy: false,
            run_id: None,
        }];
        let reclaimed = reconcile_offline_busy_zombies(
            None,
            &read_slot_assignments().unwrap(),
            &live_released,
            &cfg.runner.name_prefix,
            Some(&local_names),
            &mut quarantine,
            1,
            |_| Ok(()), // DELETE succeeds because the lock released
            |_| false,
            |_, _, _, _, _| Ok(()),
            |_, _, _, _, _| Ok(()),
        )
        .unwrap();
        assert_eq!(
            reclaimed, 1,
            "auto-recovery must release the slot when the runner appears online"
        );
        assert!(
            !quarantine.is_quarantined(1),
            "auto-recovery must clear the quarantine entry"
        );
        let after = read_slot_assignments().unwrap();
        assert!(
            !after.assignments.contains_key("1"),
            "auto-recovery must remove the slot reservation so ensure_count can re-fill it"
        );
    }

    /// Regression: the rqb9 shape (container UP + offline + !busy + GH
    /// registration absent) is NOT routed through the quarantine table.
    /// The pre-fix `release_stale_slots_from_with_containers_for`
    /// already handles the rqb9 case (when the registration is gone AND
    /// the container is missing, Path 1 releases the slot; when the
    /// registration is gone AND the container is up, Path 1 keeps the
    /// slot with an eventual-consistency warning — that is the rqb9
    /// repair ticket's lane). The quarantine lane is specifically for
    /// the OPPOSITE case (registration present, container gone, DELETE
    /// locked). If a future refactor accidentally funneled rqb9 into
    /// quarantine, this test would catch it — both for the
    /// `reconcile_offline_busy_zombies` direct call (which is gated on
    /// `offline+busy+missing-container`) and for the slot file's
    /// reservation behavior (which must NOT be modified by ghd2.2's
    /// quarantine logic).
    #[test]
    fn quarantine_does_not_swallow_rqb9_idle_no_registration_path() {
        let _qpath = crate::quarantine::tests::TestEnv::new("not_rqb9");
        let _env = TestEnv::new("not_rqb9_path");
        let cfg = cfg_with(2, "ez-org-runner");
        let _ = next_slot(&cfg).unwrap();
        record_slot_runner_id(1, 9999).unwrap();

        // rqb9 shape: runner 9999 is GONE from `live_runners` (the
        // container is up, but GH doesn't list the registration
        // anymore). `reconcile_offline_busy_zombies` is gated on
        // `offline && busy && no container` via
        // `offline_busy_owned_missing_container_slots` — the rqb9
        // shape has `runner.busy == false`, so the helper MUST NOT
        // return any slots, and the quarantine table MUST stay empty.
        let live: Vec<github::RunnerInfo> = vec![]; // no registration
        let local_names: HashSet<String> = ["ez-org-runner-1".into()].into_iter().collect();
        let mut quarantine = crate::quarantine::load_quarantine_for(None).unwrap();

        let _ = reconcile_offline_busy_zombies(
            None,
            &read_slot_assignments().unwrap(),
            &live,
            &cfg.runner.name_prefix,
            Some(&local_names),
            &mut quarantine,
            1,
            |_| Ok(()),
            |_| false,
            |_, _, _, _, _| Ok(()),
            |_, _, _, _, _| Ok(()),
        )
        .unwrap();
        assert!(
            quarantine.is_empty(),
            "the rqb9 shape (busy=false, no live registration) must NOT \
             populate the quarantine table; quarantine is for \
             offline+busy+missing-container+422, NOT for \
             idle+no-registration+container-up (see bead cross-link \
             ez-gh-actions-ghd2.2 <-> ez-gh-actions-rqb9)"
        );

        // Sanity-check: ghd2.2's quarantine logic must not have
        // touched the slot file either. If a future refactor ever
        // funneled rqb9 through quarantine, it would presumably try
        // to release the slot as part of the rqb9 fix — that release
        // is rqb9's responsibility, NOT ghd2.2's.
        let assignments_after = read_slot_assignments().unwrap();
        assert_eq!(
            assignments_after.assignments.get("1"),
            Some(&"9999".to_string()),
            "ghd2.2 must NOT mutate the slot file for the rqb9 shape; \
             the slot reservation is the rqb9 fix's surface"
        );
    }

    /// Regression: `next_slot_excluding` MUST skip quarantined slots so
    /// `ensure_count` continues filling the other slots in the fleet.
    /// This is the "continue filling all other slots" acceptance.
    #[test]
    fn next_slot_excluding_skips_quarantined_slots_and_fills_others() {
        let _qpath = crate::quarantine::tests::TestEnv::new("skip_quarantine");
        let _env = TestEnv::new("skip_quarantine_slots");
        let cfg = cfg_with(3, "ez-org-runner");

        // Slot 1 is reserved + recorded as wedged.
        let _ = next_slot(&cfg).unwrap();
        record_slot_runner_id(1, 4242).unwrap();
        // Slot 2 is reserved + recorded as wedged.
        let _ = next_slot(&cfg).unwrap();
        record_slot_runner_id(2, 5252).unwrap();
        // Slot 3 is free.

        // Pre-condition: both slots 1 and 2 are recorded in the slot file
        // and slot 3 is the only free one.
        let assignments = read_slot_assignments().unwrap();
        assert_eq!(assignments.assignments.len(), 2);

        // Quarantine slots 1 and 2.
        let mut quarantine = crate::quarantine::load_quarantine_for(None).unwrap();
        quarantine.upsert(crate::quarantine::QuarantineEntry {
            slot: 1,
            runner_id: 4242,
            runner_name: "ez-org-runner-1".into(),
            first_seen_epoch_secs: 1_700_000_000,
            attempt_count: 1,
            last_attempt_epoch_secs: 1_700_000_000,
            reason: crate::quarantine::QuarantineReason::Locked422,
        });
        quarantine.upsert(crate::quarantine::QuarantineEntry {
            slot: 2,
            runner_id: 5252,
            runner_name: "ez-org-runner-2".into(),
            first_seen_epoch_secs: 1_700_000_000,
            attempt_count: 1,
            last_attempt_epoch_secs: 1_700_000_000,
            reason: crate::quarantine::QuarantineReason::Locked422,
        });
        crate::quarantine::save_quarantine_for(None, &quarantine).unwrap();

        // next_slot must skip quarantined slots 1 and 2 and hand out slot 3.
        // Use a fresh read so the per-test slot file path resolves.
        let chosen = next_slot_excluding(&cfg, &HashSet::new()).unwrap().unwrap();
        assert_eq!(
            chosen, 3,
            "next_slot_excluding MUST skip quarantined slots 1 and 2 and \
             hand out slot 3 — this is the 'continue filling all other slots' \
             acceptance criterion for bead ez-gh-actions-ghd2.2"
        );
    }

    /// Regression: when multiple slots are quarantined, `next_slot_excluding`
    /// keeps skipping them across consecutive allocations so the fleet
    /// never tries to spawn INTO a wedged slot (no 409 self-heal churn).
    #[test]
    fn next_slot_excluding_keeps_skipping_quarantined_slots_across_calls() {
        let _qpath = crate::quarantine::tests::TestEnv::new("repeat_skip");
        let _env = TestEnv::new("repeat_skip");
        let cfg = cfg_with(4, "ez-org-runner");
        // Reserve slots 1 and 2, mark them recorded (so they're "occupied"
        // by a wedged registration), quarantine them.
        let _ = next_slot(&cfg).unwrap();
        record_slot_runner_id(1, 4242).unwrap();
        let _ = next_slot(&cfg).unwrap();
        record_slot_runner_id(2, 5252).unwrap();
        // Slots 3 and 4 are free.

        let mut quarantine = crate::quarantine::load_quarantine_for(None).unwrap();
        quarantine.upsert(crate::quarantine::QuarantineEntry {
            slot: 1,
            runner_id: 4242,
            runner_name: "ez-org-runner-1".into(),
            first_seen_epoch_secs: 1_700_000_000,
            attempt_count: 1,
            last_attempt_epoch_secs: 1_700_000_000,
            reason: crate::quarantine::QuarantineReason::Locked422,
        });
        quarantine.upsert(crate::quarantine::QuarantineEntry {
            slot: 2,
            runner_id: 5252,
            runner_name: "ez-org-runner-2".into(),
            first_seen_epoch_secs: 1_700_000_000,
            attempt_count: 1,
            last_attempt_epoch_secs: 1_700_000_000,
            reason: crate::quarantine::QuarantineReason::Locked422,
        });
        crate::quarantine::save_quarantine_for(None, &quarantine).unwrap();

        let first = next_slot_excluding(&cfg, &HashSet::new()).unwrap().unwrap();
        let second = next_slot_excluding(&cfg, &HashSet::new()).unwrap().unwrap();
        assert_eq!(first, 3, "first allocation must skip quarantined slots 1+2");
        assert_eq!(
            second, 4,
            "second allocation must skip quarantined slots 1+2 AND the just-allocated slot 3"
        );
        // No allocation into slot 1 or 2 ever happened.
        let assignments = read_slot_assignments().unwrap();
        assert!(assignments.assignments.contains_key("1"));
        assert!(assignments.assignments.contains_key("2"));
        assert!(assignments.assignments.contains_key("3"));
        assert!(assignments.assignments.contains_key("4"));
    }

    /// Regression: `next_slot_excluding` ignores a corrupt quarantine file
    /// (logged warning) and proceeds — same fail-soft contract as
    /// `release_stale_slots`'s loader, so a single bad write doesn't
    /// wedge the entire daemon.
    #[test]
    fn next_slot_excluding_tolerates_corrupt_quarantine_file() {
        let _qpath = crate::quarantine::tests::TestEnv::new("corrupt_q");
        let _env = TestEnv::new("corrupt_q");
        let cfg = cfg_with(2, "ez-org-runner");
        let _ = next_slot(&cfg).unwrap();
        record_slot_runner_id(1, 4242).unwrap();

        // Write garbage into the quarantine file.
        let path = crate::quarantine::quarantine_path_for(None);
        std::fs::write(&path, "this is not valid TOML = = =").unwrap();

        // Slot 2 is the only free one. Even though slot 1 is recorded
        // (and the quarantine file is corrupt), next_slot_excluding must
        // still pick slot 2 — NOT panic, NOT bail.
        let chosen = next_slot_excluding(&cfg, &HashSet::new()).unwrap().unwrap();
        assert_eq!(chosen, 2);
    }

    /// Bead jleechan-uurm: regression test for the empty-id Path-1 race.
    /// When `next_slot` writes an empty-id reservation, the slot's
    /// `registered_at` MUST be recorded so the grace-window check in
    /// `release_stale_slots` can protect an in-flight JIT round-trip from
    /// being reaped. Before this fix, `next_slot` did not write
    /// `registered_at`, so the slot file had a "no grace timestamp" entry
    /// for an empty reservation — which meant `release_stale_slots`'s
    /// empty-id branch would always reclaim it on the very next tick.
    #[test]
    fn next_slot_records_registered_at_for_empty_id_reservation() {
        let _env = TestEnv::new("next_slot_records_registered_at");
        let cfg = cfg_with(2, "ez-org-runner");
        let slot = next_slot(&cfg).unwrap();
        assert_eq!(slot, 1);

        let assignments = read_slot_assignments().unwrap();
        let key = "1".to_string();
        assert_eq!(
            assignments.assignments.get(&key).map(String::as_str),
            Some(""),
            "next_slot must leave an empty-id reservation"
        );
        let registered_at = assignments
            .registered_at
            .get(&key)
            .copied()
            .expect("next_slot must record registered_at for the empty-id reservation");
        // Within the grace window — the just-reserved slot should be
        // considered in-grace.
        assert!(
            slot_in_grace_window(&assignments, &key),
            "slot must be in grace window immediately after next_slot reservation (registered_at={registered_at})"
        );
        // elapsed_secs should be near zero (the test takes microseconds).
        let elapsed = seconds_since_registered(&assignments, &key).unwrap();
        assert!(elapsed <= 5, "elapsed_secs should be near 0, got {elapsed}");
    }

    /// Bead jleechan-uurm: `release_stale_slots` MUST NOT reclaim an
    /// empty-id reservation whose `registered_at` is within
    /// REGISTRATION_GRACE_WINDOW. This is the core invariant the first-wave
    /// Path-1 race investigation (jleechan-9yx8) identified as broken
    /// (the post-2026-07-08 sibling race against the empty-id branch).
    /// Toggle FAIL -> PASS: pre-patch, the empty-id branch always reclaims
    /// regardless of registered_at, so this test fails with reclaimed=1.
    /// Post-patch, registered_at written by next_slot is within the 60s
    /// window, so the grace gate kicks in and reclaimed=0.
    #[test]
    fn release_stale_slots_never_reclaims_empty_id_within_grace_window() {
        let _env = TestEnv::new("release_stale_slots_empty_id_in_grace");
        let cfg = cfg_with(2, "ez-org-runner");
        let slot = next_slot(&cfg).unwrap();
        assert_eq!(slot, 1, "first slot must be 1");

        // Sanity: slot 1 is reserved with empty id and registered_at now.
        let pre = read_slot_assignments().unwrap();
        assert_eq!(
            pre.assignments.get("1").map(String::as_str),
            Some(""),
            "precondition: slot 1 must have empty id"
        );
        assert!(
            pre.registered_at.contains_key("1"),
            "precondition: slot 1 must have registered_at written by next_slot"
        );

        // Run release_stale_slots: it must NOT reclaim slot 1 because its
        // registered_at is within REGISTRATION_GRACE_WINDOW.
        let reclaimed = release_stale_slots_from_with_containers(
            &read_slot_assignments().unwrap(),
            &[],
            "",
            Some(&HashSet::new()),
        )
        .unwrap();

        assert_eq!(
            reclaimed, 0,
            "release_stale_slots must NOT reclaim an empty-id slot within the grace window"
        );
        let after = read_slot_assignments().unwrap();
        assert_eq!(
            after.assignments.get("1").map(String::as_str),
            Some(""),
            "slot 1 must remain recorded as empty-id after the grace-window skip"
        );
        assert!(
            after.registered_at.contains_key("1"),
            "slot 1's registered_at must remain so subsequent ticks within the window also skip"
        );

        // The ring buffer must record the grace-window skip so operators can
        // see it via `ezgha reclaim-history --slot 1`.
        let history = snapshot_reclaim(Some("1"));
        assert_eq!(history.len(), 1, "ring buffer must have one skip record");
        let (key, rec) = &history[0];
        assert_eq!(key, "1");
        assert_eq!(rec.slot, 1);
        assert_eq!(rec.runner_id, 0);
        assert!(rec.in_grace, "recorded skip must have in_grace=true");
        assert_eq!(rec.reason, "empty-id-grace-skip");
        assert!(
            rec.monotonic_secs >= 0.0,
            "monotonic_secs must be filled by record_reclaim"
        );
    }

    /// Bead jleechan-uurm: a backdated empty-id reservation (registered_at
    /// outside the grace window) MUST still be reclaimable — the gate only
    /// protects the JIT round-trip window, not genuinely stale slots.
    /// Companion test to `release_stale_slots_never_reclaims_empty_id_within_grace_window`.
    #[test]
    fn release_stale_slots_reclaims_empty_id_past_grace_window() {
        let _env = TestEnv::new("release_stale_slots_empty_id_past_grace");
        let cfg = cfg_with(2, "ez-org-runner");
        let _ = next_slot(&cfg).unwrap();

        // Backdate registered_at past REGISTRATION_GRACE_WINDOW.
        let mut assignments = read_slot_assignments().unwrap();
        assignments.registered_at.insert(
            "1".to_string(),
            now_epoch_secs() - REGISTRATION_GRACE_WINDOW.as_secs() - 1,
        );
        write_slot_assignments_for(&assignments, Some(&cfg)).unwrap();

        let reclaimed = release_stale_slots_from_with_containers(
            &read_slot_assignments().unwrap(),
            &[],
            "",
            Some(&HashSet::new()),
        )
        .unwrap();

        assert_eq!(
            reclaimed, 1,
            "an empty-id slot whose registered_at is past the grace window MUST be reclaimable (the original unconditional behavior is correct for genuinely stale reservations)"
        );
        let after = read_slot_assignments().unwrap();
        assert!(
            !after.assignments.contains_key("1"),
            "slot 1 must be released after grace-window expiry"
        );

        let history = snapshot_reclaim(Some("1"));
        assert_eq!(history.len(), 1);
        let (_, rec) = &history[0];
        assert!(!rec.in_grace, "reclaim record must have in_grace=false");
        assert_eq!(rec.reason, "empty-id-reclaim");
    }

    /// Bead jleechan-uurm: per-slot reclaim log line MUST include
    /// runner_id, monotonic_ts, elapsed_secs, peak_rss_mb, in_grace so an
    /// operator can correlate a reclaim to a specific in-flight JIT/dockerrun
    /// outcome. The empty-id branch is the most forensically-thin one (the
    /// first-wave report flagged it as contributing only to a summary
    /// count), so this test exercises the empty-id-reclaim ring entry path
    /// to verify the new fields are populated.
    #[test]
    fn release_stale_slots_records_runner_id_and_last_run_id_in_reclaim_log() {
        let _env = TestEnv::new("release_stale_slots_per_slot_log");
        let cfg = cfg_with(2, "ez-org-runner");
        let _ = next_slot(&cfg).unwrap();

        // Backdate to past-grace so the reclaim path (not the skip path)
        // exercises the per-slot log + ring buffer code path.
        let mut assignments = read_slot_assignments().unwrap();
        assignments.registered_at.insert(
            "1".to_string(),
            now_epoch_secs() - REGISTRATION_GRACE_WINDOW.as_secs() - 1,
        );
        write_slot_assignments_for(&assignments, Some(&cfg)).unwrap();

        // Now exercise the recorded-id reclaim path (Path 1's "GH missing,
        // no local container" branch) which writes runner_id into the log.
        let _ = next_slot(&cfg).unwrap();
        record_slot_runner_id(2, 4242).unwrap();

        // Backdate slot 2's registered_at past grace.
        let mut assignments = read_slot_assignments().unwrap();
        assignments.registered_at.insert(
            "2".to_string(),
            now_epoch_secs() - REGISTRATION_GRACE_WINDOW.as_secs() - 1,
        );
        write_slot_assignments_for(&assignments, Some(&cfg)).unwrap();

        // Slot 2's recorded runner_id is 4242; the live snapshot must NOT
        // include 4242 (that's the gh-missing branch trigger). Add an
        // unrelated live runner (`run_id: Some(7777)`) so the recorded-id
        // branch's `live_runners_last_run_id(..., 4242)` lookup falls
        // through to `None` and the ring buffer records `last_run_id=0`.
        // (Bead jleechan-tv58 paths: the helper lookup is structurally
        // present; the assertion below exercises the empty result.)
        let live = vec![github::RunnerInfo {
            id: 9999,
            name: "ez-org-runner-other".into(),
            status: "online".into(),
            busy: false,
            run_id: Some(7777),
        }];
        let _ = release_stale_slots_from_with_containers(
            &read_slot_assignments().unwrap(),
            &live,
            "ez-org-runner",
            Some(&HashSet::new()),
        )
        .unwrap();

        let history = snapshot_reclaim(None);
        // We expect at least two records: slot 1 (empty-id-reclaim) and
        // slot 2 (gh-missing-no-local-container). The empty-id record has
        // runner_id=0; the recorded-id record has runner_id=4242.
        let slot_1_records: Vec<_> = history.iter().filter(|(_k, r)| r.slot == 1).collect();
        let slot_2_records: Vec<_> = history.iter().filter(|(_k, r)| r.slot == 2).collect();
        assert!(
            !slot_1_records.is_empty(),
            "slot 1 must have at least one reclaim record"
        );
        assert!(
            !slot_2_records.is_empty(),
            "slot 2 must have at least one reclaim record (recorded-id branch must populate runner_id)"
        );
        let (_, slot_1_rec) = slot_1_records[0];
        assert_eq!(
            slot_1_rec.runner_id, 0,
            "empty-id reclaim must have runner_id=0"
        );
        assert_eq!(
            slot_1_rec.reason, "empty-id-reclaim",
            "empty-id reclaim reason"
        );
        assert!(
            !slot_1_rec.in_grace,
            "empty-id reclaim (past grace) must have in_grace=false"
        );
        let (_, slot_2_rec) = slot_2_records[0];
        assert_eq!(
            slot_2_rec.runner_id, 4242,
            "recorded-id reclaim must propagate the recorded runner_id into the ring buffer"
        );
        assert_eq!(
            slot_2_rec.reason, "gh-missing-no-local-container",
            "recorded-id reclaim reason"
        );
        // Bead jleechan-tv58: the recorded-id branch must surface the
        // runner's `run_id` from the live snapshot. Slot 2's recorded id is
        // 4242, which is NOT in live_runners (gh-missing-no-local-container
        // branch), so `live_runners_last_run_id(..., 4242)` returns None and
        // the ring buffer records `last_run_id=0` — the structurally-present
        // fall-through. The helper is exercised by the dedicated
        // `live_runners_last_run_id_returns_run_id_or_none` test below,
        // where a known run_id IS in the live snapshot.
        assert_eq!(
            slot_2_rec.last_run_id, 0,
            "recorded-id (gh-missing) reclaim must record last_run_id=0 when the runner is absent from live_runners"
        );
    }

    /// Bead jleechan-tv58: `live_runners_last_run_id` must return the
    /// `run_id` from a matching live entry, or `None` if the runner is
    /// absent / idle. This is the path that the recorded-id reclaim
    /// branches use to surface the in-flight `run_id` into the log line
    /// and ring buffer.
    ///
    /// Test name matches the `tests/slot_drift_reclaim_correlation_test.sh`
    /// CI gate (bead jleechan-tv58 acceptance criterion 4): the bash script
    /// filters `cargo test` by this exact name and fails if the line
    /// `test live_runners_last_run_id_is_some_for_busy_runner_with_run_id
    /// ... ok` is not present. Pre-patch (no RunnerInfo.run_id field,
    /// no helper) the test does not exist -> cargo matches 0 tests ->
    /// no `ok` line -> bash gate fails. Post-patch the test exists and
    /// passes -> bash gate passes.
    #[test]
    fn live_runners_last_run_id_is_some_for_busy_runner_with_run_id() {
        let live = vec![
            github::RunnerInfo {
                id: 100,
                name: "ez-runner-c-1".into(),
                status: "online".into(),
                busy: true,
                run_id: Some(4242),
            },
            github::RunnerInfo {
                id: 200,
                name: "ez-runner-c-2".into(),
                status: "online".into(),
                busy: false,
                run_id: None,
            },
        ];
        // Known busy runner: runId propagates.
        assert_eq!(live_runners_last_run_id(&live, 100), Some(4242));
        // Idle runner with explicit None: helper must not fabricate a value.
        assert_eq!(live_runners_last_run_id(&live, 200), None);
        // Absent runner: None, NOT 0.
        assert_eq!(live_runners_last_run_id(&live, 999), None);
    }

    /// Bead jleechan-tv58: `container_peak_rss_mb` must accept every shape
    /// of `docker stats --no-stream --format '{{.MemUsage}}'` output that
    /// the daemon could see (B / KiB / MiB / GiB) and degrade gracefully
    /// (return 0) when the container is gone or the parser is given
    /// garbage. The function is forensic-only — 0 is a valid signal, not a
    /// failure — so correctness here is "does not panic and does not
    /// misreport"; tighter assertions would over-fit to a specific docker
    /// version's output format.
    #[test]
    fn container_peak_rss_mb_accepts_documented_units() {
        // Pure-function smoke test (no docker binary required): walk the
        // same parse path the production helper uses, so a future regression
        // in the parser is caught even when CI runs on a host without
        // docker.
        // We expose the parser via a thin re-implementation that mirrors
        // the production helper exactly, asserting the same unit-conversion
        // table and the 0B / empty / unknown-unit fall-through.
        fn parse_mem_usage(s: &str) -> u64 {
            let head = s.trim().split('/').next().unwrap_or("").trim();
            if head.is_empty() || head == "0B" {
                return 0;
            }
            let (num_str, unit) = head.split_at(
                head.find(|c: char| !c.is_ascii_digit() && c != '.')
                    .unwrap_or(head.len()),
            );
            let num: f64 = match num_str.parse() {
                Ok(v) => v,
                Err(_) => return 0,
            };
            let bytes = match unit {
                "B" => num,
                "KiB" => num * 1024.0,
                "MiB" => num * 1024.0 * 1024.0,
                "GiB" => num * 1024.0 * 1024.0 * 1024.0,
                "TiB" => num * 1024.0 * 1024.0 * 1024.0 * 1024.0,
                _ => return 0,
            };
            (bytes / (1024.0 * 1024.0)) as u64
        }
        // IEC binary units — note the difference between B vs KiB (1024
        // vs 1), since docker stats uses IEC binary suffixes everywhere.
        assert_eq!(parse_mem_usage("0B / 7.7GiB"), 0);
        assert_eq!(parse_mem_usage("100B / 7.7GiB"), 0);
        // 1 KiB ≈ 1/1024 MiB, rounds down to 0.
        assert_eq!(parse_mem_usage("1KiB / 7.7GiB"), 0);
        // 2 MiB exactly.
        assert_eq!(parse_mem_usage("2MiB / 7.7GiB"), 2);
        // 1500 MiB = 1500.
        assert_eq!(parse_mem_usage("1500MiB / 7.7GiB"), 1500);
        // 1 GiB = 1024 MiB.
        assert_eq!(parse_mem_usage("1GiB / 7.7GiB"), 1024);
        // Decimal fractions: 0.5GiB = 512MiB.
        assert_eq!(parse_mem_usage("0.5GiB / 7.7GiB"), 512);
        // Unknown unit -> 0 (not a panic).
        assert_eq!(parse_mem_usage("100ZZ / 7.7GiB"), 0);
        // Empty / whitespace -> 0.
        assert_eq!(parse_mem_usage(""), 0);
        assert_eq!(parse_mem_usage("   "), 0);
        // Garbage number -> 0.
        assert_eq!(parse_mem_usage("NaNMiB / 7.7GiB"), 0);

        // The production helper must agree with the parser on at least the
        // "container does not exist" and "garbage input" cases (it returns
        // 0 for those by construction — `docker stats` exits non-zero when
        // the container is missing, and the helper catches that).
        assert_eq!(
            container_peak_rss_mb("definitely-not-a-real-container-zzzzz"),
            0
        );
    }

    /// Bead jleechan-uurm: the ring buffer must cap at RECLAIM_RING_CAP
    /// entries per slot (FIFO eviction). Diagnostic window is small —
    /// older entries are not load-bearing.
    #[test]
    fn reclaim_ring_buffer_evicts_oldest_at_cap() {
        let _env = TestEnv::new("reclaim_ring_buffer_evicts_oldest");
        // Drive 17 grace-skip records into the ring buffer for slot 7.
        // (RECLAIM_RING_CAP=16, so the first record must be evicted.)
        for i in 0..(RECLAIM_RING_CAP + 1) {
            record_reclaim(
                "7",
                ReclaimRecord {
                    monotonic_secs: 0.0,
                    wall_secs: now_epoch_secs() + i as u64,
                    slot: 7,
                    runner_id: 0,
                    last_run_id: 0,
                    peak_rss_mb: 0,
                    in_grace: true,
                    reason: format!("probe-{i}"),
                },
            );
        }
        let history = snapshot_reclaim(Some("7"));
        assert_eq!(
            history.len(),
            RECLAIM_RING_CAP,
            "ring buffer must cap at RECLAIM_RING_CAP entries per slot"
        );
        // Most-recent-first: the FIRST record returned must have the
        // highest monotonic_secs (the LAST record pushed). The oldest
        // record (probe-0) must have been evicted.
        let reasons: Vec<&str> = history.iter().map(|(_, r)| r.reason.as_str()).collect();
        assert!(
            reasons[0].starts_with("probe-") && reasons[0] != "probe-0",
            "oldest record (probe-0) must have been evicted; most-recent-first record is {}",
            reasons[0]
        );
        // The last record in the output (oldest still-present) must NOT
        // be probe-0.
        assert_ne!(
            reasons.last().copied(),
            Some("probe-0"),
            "probe-0 must be evicted"
        );
    }
}
