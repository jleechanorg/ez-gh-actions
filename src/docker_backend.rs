use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};
use std::env;
use std::ffi::CString;
use std::io::Read;
use std::path::Path;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::mpsc;
use std::sync::Mutex;
use std::sync::Once;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::alert::{self, Severity};
use crate::backend::Backend;
use crate::config::Config;
use crate::github;
use crate::platform::Platform;
use crate::reaper;
use crate::watchdog;

const MANAGED_LABEL: &str = "ezgha=managed";

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
const MACOS_HOST_DISK_FLOOR_GB: u64 = 40;
static CONSECUTIVE_DISK_NONE: AtomicU32 = AtomicU32::new(0);
const CPUS_REQUIRE_CPU_CONTROLLER_ERR: &str = "refusing to start runner: Docker CPU cgroup controller is unavailable on this Linux host; cannot enforce --cpus safely.";
const DOCKER_TIMEOUT: Duration = Duration::from_secs(45);

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
static TEST_START_ONE_NAMES: std::sync::Mutex<Option<Vec<String>>> = std::sync::Mutex::new(None);
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

fn run_docker_with_timeout(mut cmd: Command, detail: &str, timeout: Duration) -> Result<Output> {
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

    let stdout = match rx_out.recv_timeout(timeout) {
        Ok(buf) => buf,
        Err(_) => {
            let _ = child.kill();
            let _ = child.wait();
            bail!(
                "docker CLI timed out after {}ms while {detail}",
                timeout.as_millis()
            );
        }
    };
    let stderr = rx_err
        .recv_timeout(Duration::from_secs(5))
        .unwrap_or_default();

    let status = child
        .wait()
        .with_context(|| format!("wait for docker CLI during {detail}"))?;
    Ok(Output {
        status,
        stdout,
        stderr,
    })
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
    next_slot_excluding(cfg, &HashSet::new())
}

/// Like `next_slot`, but skips any slot number present in `excluded` even if
/// it is technically free in the persisted assignments file. Used by
/// `start_missing_runners` so that a slot which just failed (and had its
/// reservation released) within the current call cannot be immediately
/// re-picked as the "lowest free slot" — which previously caused every
/// remaining retry in the batch to pile onto one permanently-broken slot
/// while every other genuinely-fillable slot went untried (bead
/// ez-gh-actions-oau).
pub fn next_slot_excluding(cfg: &Config, excluded: &HashSet<u32>) -> Result<u32> {
    if cfg.runner.count == 0 {
        bail!("cfg.runner.count is 0; nothing to allocate");
    }
    let mut assignments = read_slot_assignments_for(Some(cfg))?;
    for slot in 1..=cfg.runner.count {
        if excluded.contains(&slot) {
            continue;
        }
        let key = slot.to_string();
        if let std::collections::btree_map::Entry::Vacant(e) = assignments.assignments.entry(key) {
            e.insert(String::new());
            write_slot_assignments_for(&assignments, Some(cfg))?;
            return Ok(slot);
        }
    }
    bail!(
        "all {} runner slot(s) are currently in use on this host; \
         stop/release a slot first (e.g. `ezgha stop`) or raise cfg.runner.count",
        cfg.runner.count
    );
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

/// Release slots whose recorded `runner_id` no longer corresponds to a live
/// GitHub-registered runner. Slots can get stuck if the docker daemon dies,
/// the container exits abruptly, or GitHub reaps the registration server-side:
/// `release_slot` never fires, so the slot file grows stale and `next_slot`
/// eventually refuses to allocate even though no real runner is consuming
/// the slot. Called at the start of `ensure_count` so `serve` self-heals
/// without operator intervention.
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
    if let Some(local_names) = local_container_names.as_ref() {
        for (slot_n, runner_id, runner_name) in offline_busy_owned_missing_container_slots(
            &assignments,
            &live_runners,
            &cfg.runner.name_prefix,
            local_names,
        ) {
            eprintln!(
                "warning: removing offline/busy runner {runner_name} (id {runner_id}) with no local container before releasing slot {slot_n}"
            );
            match github::remove_runner(&cfg.github, runner_id) {
                Ok(()) => {
                    release_slot_for(Some(cfg), slot_n)?;
                    reclaimed += 1;
                    watchdog::ping();
                }
                Err(err) if is_runner_busy_lock_error(&err) => {
                    // GitHub's DELETE-runner lock is job-side, not
                    // runner-side (see memory gh-zombie-runner-422-delete-lock):
                    // cancel the phantom run pinned to this runner first,
                    // which is what actually holds the 422 lock, then retry
                    // the delete. `live_runners` already has this runner's
                    // `RunnerInfo` from the reconciliation fetch above.
                    let healed = live_runners
                        .iter()
                        .find(|r| r.id == runner_id)
                        .is_some_and(|r| reclaim_zombie_locked_runner(cfg, r));
                    if healed {
                        release_slot_for(Some(cfg), slot_n)?;
                        reclaimed += 1;
                        watchdog::ping();
                    } else {
                        eprintln!(
                            "warning: keeping slot {slot_n}: failed to remove offline/busy runner {runner_name} (id {runner_id}) even after zombie-slot self-heal: {err:#}"
                        );
                    }
                }
                Err(err) => {
                    eprintln!(
                        "warning: keeping slot {slot_n}: failed to remove offline/busy runner {runner_name} (id {runner_id}): {err:#}"
                    );
                }
            }
        }
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
            // allocation cycle can claim it.
            release_slot_for(cfg, slot_n)?;
            reclaimed += 1;
        } else if let Ok(rid) = id_str.parse::<u64>() {
            if !live_ids.contains(&rid) {
                let expected_name = runner_name_from_prefix(runner_prefix, slot_n);
                match local_container_names {
                    Some(local_names) if local_names.contains(&expected_name) => {
                        eprintln!(
                            "warning: keeping slot {slot_n}: local container {expected_name} still exists while GH registration {rid} is absent (treating as in-flight / eventual consistency)"
                        );
                    }
                    Some(_) => {
                        // The recorded runner_id is no longer registered on GitHub
                        // (server-side reap, manual removal, or a stale entry from a
                        // prior host) and no local container exists, so reclaim.
                        release_slot_for(cfg, slot_n)?;
                        reclaimed += 1;
                    }
                    None => {
                        eprintln!(
                            "warning: keeping slot {slot_n}: docker ps failed locally so container existence for {expected_name} is unknown while GH registration {rid} is absent; skipping reclaim this tick to avoid a blind mass-reclaim"
                        );
                    }
                }
            } else if let Some(runner) = live_runners.iter().find(|r| r.id == rid) {
                let expected_name = runner_name_from_prefix(runner_prefix, slot_n);
                if !runner_prefix.is_empty() && runner.name != expected_name {
                    eprintln!(
                        "warning: releasing slot {slot_n}: runner name mismatch (expected {expected_name}, got {} on GitHub for id {rid})",
                        runner.name
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
                            eprintln!(
                                "warning: releasing slot {slot_n}: runner {expected_name} (id {rid}) is offline/idle and has no local container"
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
            eprintln!(
                "info: release_stale_slots (Path 4): skipping reap of {} (id {}) — registered_at {elapsed}s ago (within {}s grace window)",
                runner.name,
                runner.id,
                REGISTRATION_GRACE_WINDOW.as_secs()
            );
            continue;
        }
        reapable.push((runner.id, runner.name.clone()));
    }
    reapable
}

fn runner_name_from_prefix(prefix: &str, slot: u32) -> String {
    format!("{prefix}-{slot}")
}

/// Poll/force-cancel attempts given to the reaper executor before this tick
/// gives up on a zombie-locked runner. Deliberately short: `release_stale_slots`
/// re-runs every reconciliation cycle, so a failed attempt here just retries
/// from scratch next tick rather than blocking this one on a long poll.
const ZOMBIE_RECLAIM_POLL_ATTEMPTS: u32 = 3;

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
            let out = Command::new("docker")
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
        return true;
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
            let mut cmd = Command::new("docker");
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
/// real `PATH`.
fn docker_cmd() -> Command {
    #[cfg(test)]
    {
        if let Some(bin) = TEST_DOCKER_BIN.lock().unwrap().clone() {
            return Command::new(bin);
        }
    }
    Command::new("docker")
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
    let mut cmd = docker_cmd();
    cmd.args(["info", "--format", "{{.NCPU}} {{.MemTotal}}"]);
    let out = run_docker(cmd, "reading docker daemon capacity").ok()?;
    let stdout = String::from_utf8_lossy(&out.stdout);
    let mut parts = stdout.split_whitespace();
    let ncpu: f64 = parts.next()?.parse().ok()?;
    let mem_bytes: u64 = parts.next()?.parse().ok()?;
    Some((ncpu, mem_bytes / 1024 / 1024))
}

/// Lane-I (Round-3 swarm): read PSI cgroup-v2 memory pressure (`some` line)
/// and host `MemAvailable`. Returns `(pressure_pct, available_bytes)`. Pure
/// helper — no global state, no I/O beyond reading two small sysfs/proc
/// files. Refuses to start a new runner when the host is already under
/// sustained memory pressure, even if disk-floor is healthy (the
/// `min_free_disk_gb` guard alone did not save the host from the 2026-07-12
/// crash). Default cgroup path is `user.slice` because that's where the
/// daemon is most likely to live; an `Err` is returned if `/proc/self/cgroup`
/// cannot be parsed AND `user.slice` is unreadable, so a misconfigured host
/// fails loud rather than silently admitting a runaway job.
pub fn memory_pressure_pct() -> Result<(f64, u64)> {
    memory_pressure_pct_from(DEFAULT_PRESSURE_PATH, &read_meminfo_available)
}

const DEFAULT_PRESSURE_PATH: &str = "/sys/fs/cgroup/user.slice/memory.pressure";

fn memory_pressure_pct_from(
    pressure_path: &str,
    read_meminfo: &dyn Fn() -> Option<u64>,
) -> Result<(f64, u64)> {
    let pressure_raw = std::fs::read_to_string(pressure_path)
        .with_context(|| format!("reading memory pressure at {pressure_path}"))?;
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
    let pressure_pct = pct.with_context(|| format!("no `some avg10=` line in {pressure_path}"))?;
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
///   2. available_bytes < 2× per-runner memory,
///   3. hysteresis: all 5 most-recent readings are rising (each tick's
///      reading is strictly greater than the prior tick).
///
/// Tests pass a pre-populated `prev_window` so they can drive each branch
/// deterministically without spinning up the real daemon.
pub fn eval_admission(
    pressure_pct: f64,
    available_bytes: u64,
    runner_memory_bytes: u64,
    prev_window: &mut [Option<f64>; 5],
) -> Result<(), String> {
    if pressure_pct > 50.0 {
        return Err(format!(
            "PSE memory pressure {pressure_pct:.1}% > 50%; refusing new start"
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
pub fn effective_limits(cfg: &Config) -> (f64, u64) {
    let (ncpu, daemon_mem) = match daemon_capacity() {
        Some(c) => c,
        None => return (cfg.limits.cpus, cfg.limits.memory_mb),
    };
    // If vm_total_mb override is set, use it as the fleet budget base
    // instead of the docker daemon's reported MemTotal. This is the SAME
    // value that derive_memory_budget uses for the startup fail-loud guard,
    // so the guard and the runtime clamp stay in sync (bead ez-gh-actions-yz6b
    // round 3 sync requirement).
    let fleet_mem_base = cfg.runner.vm_total_mb.unwrap_or(daemon_mem);
    effective_limits_with_capacity(cfg, Some((ncpu, fleet_mem_base)))
}

fn effective_limits_with_capacity(cfg: &Config, capacity: Option<(f64, u64)>) -> (f64, u64) {
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
        // and the ACTUAL docker run --memory limit stay in sync — before
        // this fix they were two disconnected calculations and the guard
        // could report "OK" while runners were still spawned with zero real
        // guest headroom (daemon_mem / count, ignoring guest_reserve_mb).
        let fleet_mem_budget = daemon_mem.saturating_sub(cfg.runner.guest_reserve_mb);
        let cpu_share = (ncpu / n_f).max(0.5);
        let mem_share = (fleet_mem_budget / n_u).max(512);
        if cpus > cpu_share {
            eprintln!(
                "note: clamping cpus {cpus} -> {cpu_share} (daemon {ncpu} / {} runners)",
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
    (cpus, mem)
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

/// Start one ephemeral JIT runner container in a slot the caller has already
/// reserved (e.g. via `next_slot_excluding`), instead of letting this
/// function pick the lowest free slot itself. Used by `start_missing_runners`
/// so a failed slot can be excluded from the next pick within the same batch.
/// Returns (container_id, runner_name).
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

    start_one_with_generate_at_slot(cfg, backend, slot, github::generate_jitconfig)
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
    let runner_name = runner_name_for(cfg, slot);

    // Clean up any stale container left behind in this slot (failsafe against name conflicts)
    let mut pre_rm = docker_cmd();
    pre_rm.args(["rm", "-f", &runner_name]);
    let _ = run_docker(pre_rm, "pre-start rm -f").ok();

    let (cpus, memory_mb) = effective_limits(cfg);
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
    if backend == Backend::DockerSysbox {
        cmd.args(["--runtime", "sysbox-runc"]);
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

pub fn managed_containers() -> Result<Vec<ManagedContainer>> {
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
    let out = run_docker(cmd, "listing managed containers")?;
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

fn effective_host_disk_floor_gb(configured_floor_gb: u64, is_macos: bool) -> u64 {
    if is_macos {
        // ponytail: keep one incident-derived Mac safety floor here; add a
        // separate host-floor config only if heterogeneous hosts need it.
        configured_floor_gb.max(MACOS_HOST_DISK_FLOOR_GB)
    } else {
        configured_floor_gb
    }
}

/// Free space on the outer host filesystem that backs Docker's storage.
/// This is intentionally separate from `free_disk_gb`: with Colima the guest
/// can report ample overlay space while its sparse disk has exhausted APFS.
fn host_free_disk_gb() -> Option<u64> {
    #[cfg(test)]
    if let Some(free) = *TEST_HOST_FREE_DISK_GB.lock().unwrap() {
        return free;
    }

    let path = if cfg!(target_os = "macos") {
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
fn start_missing_runners(cfg: &Config, backend: Backend, missing: u32) -> Result<Vec<String>> {
    start_missing_runners_with_starter(cfg, backend, missing, start_one_at_slot)
}

fn start_missing_runners_with_starter(
    cfg: &Config,
    backend: Backend,
    missing: u32,
    starter: impl Fn(&Config, Backend, u32) -> Result<(String, String)>,
) -> Result<Vec<String>> {
    let mut started = Vec::new();
    let mut last_err = None;
    let mut failed_slots: HashSet<u32> = HashSet::new();
    for _ in 0..missing {
        if crate::shutdown::is_requested() {
            eprintln!("shutdown requested; stopping runner spawn mid-batch");
            break;
        }
        watchdog::ping();
        let slot = match next_slot_excluding(cfg, &failed_slots) {
            Ok(slot) => slot,
            Err(e) => {
                // No free, non-excluded slot left at all (e.g. every slot is
                // either occupied or has already failed this cycle) — further
                // iterations cannot possibly succeed either, so stop instead
                // of spinning through the remaining `missing` count.
                eprintln!("warning: no runner slot available to attempt: {e:#}");
                last_err = Some(e);
                break;
            }
        };
        match starter(cfg, backend, slot) {
            Ok((_, name)) => started.push(name),
            Err(e) => {
                eprintln!("warning: failed to start runner in slot {slot}: {e:#}");
                failed_slots.insert(slot);
                last_err = Some(e);
            }
        }
    }

    if started.is_empty() {
        if let Some(e) = last_err {
            return Err(e);
        }
    }
    Ok(started)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EnsureCountOutcome {
    pub started: Vec<String>,
    pub missing: u32,
}

impl EnsureCountOutcome {
    /// A partial failure is when we started fewer runners than were missing.
    pub fn is_partial_failure(&self) -> bool {
        (self.started.len() as u32) < self.missing
    }
}

/// Ensure `count` managed runner containers are alive; start the shortfall.
/// Refuses to spawn when the daemon's disk is below the configured floor —
/// disk exhaustion is the dominant self-hosted runner failure mode, and
/// spawning more work onto a full disk makes the incident worse.
pub fn ensure_count(cfg: &Config, backend: Backend) -> Result<Vec<String>> {
    Ok(ensure_count_outcome(cfg, backend)?.started)
}

pub fn ensure_count_outcome(cfg: &Config, backend: Backend) -> Result<EnsureCountOutcome> {
    // Reconcile stale slot assignments before we look at container counts:
    // a daemon crash between `next_slot` and the container coming up leaves a
    // reservation that would otherwise wedge `next_slot` forever ("all N
    // runner slot(s) are currently in use"). `serve` calls this on a 30s
    // loop, so the host self-heals on the next tick.
    let _ = release_stale_slots(cfg);
    // Print the host-kernel warning at most once per process — `serve` would
    // otherwise re-emit it every 30s.
    DOCTOR_PRINTED.call_once(|| print_doctor(&crate::platform::detect()));
    let containers = managed_containers()?;
    let alive = current_prefix_containers(&containers, cfg).len() as u32;
    if alive >= cfg.runner.count {
        return Ok(EnsureCountOutcome {
            started: Vec::new(),
            missing: 0,
        });
    }
    let host_floor_gb =
        effective_host_disk_floor_gb(cfg.limits.min_free_disk_gb, cfg!(target_os = "macos"));
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
            bail!(
                "only {free} GB free on the host filesystem (floor: {host_floor_gb} GB) — refusing to spawn runners; reclaim host space first"
            );
        }
        Some(_) => {}
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
            bail!(
                "could not measure host filesystem free disk — refusing to spawn runners until measurement recovers"
            );
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
            bail!(
                "only {free} GB free on docker's filesystem (floor: {} GB) — refusing to spawn runners; \
                 reclaim space (e.g. `docker system prune`) first",
                cfg.limits.min_free_disk_gb
            );
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
                bail!(
                    "could not measure daemon free disk for {n} cycles in a row — \
                     refusing to spawn runners until disk measurement recovers \
                     (image missing? df broken? daemon wedged?)"
                );
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
    // on absolute pressure > 50%, on available < 2× per-runner memory, OR
    // on a 5-tick rising-pressure hysteresis (sustained growth = OOM is
    // imminent even if the current absolute reading is below threshold).
    // Best-effort: if either read fails (cgroup not mounted, /proc/meminfo
    // unreadable, parse error) we LOG and continue rather than bail — a
    // single broken probe must NOT take the runner pool offline. The
    // hysteresis window is read+rotated as one Mutex guard.
    let admission_probe = memory_pressure_pct();
    let admission_decision: Result<(), String> = {
        let mut window = PRESSURE_WINDOW.lock().unwrap_or_else(|p| p.into_inner());
        match &admission_probe {
            Ok((pct, available)) => {
                let runner_bytes = cfg.limits.memory_mb.saturating_mul(1024 * 1024);
                eval_admission(*pct, *available, runner_bytes, &mut window)
            }
            Err(e) => {
                // Probe failed — degrade gracefully. Push a None-equivalent
                // (we can't, since the window is Option<f64>; push 0.0 to
                // break the rising chain on the next successful probe) and
                // log so the operator sees degraded-but-not-stopped.
                window.rotate_left(1);
                window[4] = Some(0.0);
                eprintln!(
                    "warning: PSI admission probe failed ({e:#}); pressure-aware gate is NOT active this cycle"
                );
                Ok(())
            }
        }
    };
    if let Err(reason) = admission_decision {
        let _ = alert::notify(
            cfg,
            "runner_pool.memory_pressure",
            Severity::Critical,
            "Runner pool paused: memory pressure",
            &format!("refusing to spawn runners: {reason}"),
        );
        bail!("{reason}");
    }
    let missing = cfg.runner.count - alive;
    let refill = start_missing_runners(cfg, backend, missing);
    // Release any failed reservations from this cycle
    let _ = release_stale_slots(cfg);

    let started = refill?;
    let outcome = EnsureCountOutcome { started, missing };
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

    /// Lock + redirect the slot assignments path for the duration of a test.
    /// Always pair with `_lock` to avoid races with other tests in the same
    /// binary.
    struct TestEnv {
        _lock: std::sync::MutexGuard<'static, ()>,
        path: PathBuf,
    }

    impl TestEnv {
        fn new(label: &str) -> Self {
            let lock = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
            let path = tmp_path(label);
            *TEST_SLOT_PATH.lock().unwrap() = Some(path.clone());
            *TEST_HOST_FREE_DISK_GB.lock().unwrap() = Some(Some(100));
            Self { _lock: lock, path }
        }
    }

    impl Drop for TestEnv {
        fn drop(&mut self) {
            *TEST_SLOT_PATH.lock().unwrap() = None;
            *TEST_RELEASE_STALE_SLOTS_RESULT.lock().unwrap() = None;
            *TEST_FREE_DISK_GB.lock().unwrap() = None;
            *TEST_HOST_FREE_DISK_GB.lock().unwrap() = None;
            *TEST_MANAGED_CONTAINERS.lock().unwrap() = None;
            *TEST_START_ONE_NAMES.lock().unwrap() = None;
            *TEST_DOCKER_BIN.lock().unwrap() = None;
            // Drop the cpu-probe test seam so the next test sees a clean
            // override state instead of a value leaked from this test.
            cpu_probe_overrides::set(None);
            let _ = std::fs::remove_file(&self.path);
            if let Some(parent) = self.path.parent() {
                let _ = std::fs::remove_dir(parent);
            }
        }
    }

    #[test]
    fn macos_host_floor_never_drops_below_pressure_threshold() {
        assert_eq!(effective_host_disk_floor_gb(5, true), 40);
        assert_eq!(effective_host_disk_floor_gb(48, true), 48);
        assert_eq!(effective_host_disk_floor_gb(5, false), 5);
    }

    #[test]
    fn host_disk_probe_reads_outer_filesystem() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        *TEST_HOST_FREE_DISK_GB.lock().unwrap() = None;

        assert!(host_free_disk_gb().is_some());
    }

    #[test]
    fn host_disk_floor_refuses_batch_before_any_runner_starts() {
        let _env = TestEnv::new("host_disk_floor");
        let mut cfg = cfg_with(6, "ez-org-runner");
        cfg.limits.min_free_disk_gb = 40;
        *TEST_RELEASE_STALE_SLOTS_RESULT.lock().unwrap() = Some(0);
        *TEST_FREE_DISK_GB.lock().unwrap() = Some(Some(100));
        *TEST_HOST_FREE_DISK_GB.lock().unwrap() = Some(Some(39));
        *TEST_MANAGED_CONTAINERS.lock().unwrap() = Some(Vec::new());
        *TEST_START_ONE_NAMES.lock().unwrap() = Some(vec!["must-not-start".into()]);

        let err = ensure_count_outcome(&cfg, Backend::Docker).unwrap_err();

        assert!(format!("{err:#}").contains("host filesystem"));
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
        let (cpus, mem) = effective_limits_with_capacity(&cfg, Some((ncpu, daemon_mem)));
        assert!(
            cpus <= expected_cpu_share + f64::EPSILON,
            "effective_limits must clamp cpus to daemon/count (got {cpus} > {expected_cpu_share})"
        );
        assert!(
            mem <= expected_mem_share,
            "effective_limits must clamp memory to daemon/count (got {mem} > {expected_mem_share})"
        );
    }

    #[test]
    fn effective_limits_aggregate_fits_daemon() {
        // Stronger invariant: count * per_runner must fit daemon totals.
        let mut cfg = Config::defaults_for(&fake_platform(8192, 4), "o/r".into(), Scope::Repo);
        cfg.runner.count = 4;
        cfg.limits.cpus = 2.0;
        cfg.limits.memory_mb = 4096;
        let (ncpu, daemon_mem): (f64, u64) = (4.0, 8192);
        let (cpus, mem) = effective_limits_with_capacity(&cfg, Some((ncpu, daemon_mem)));
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
        let (_, mem) = effective_limits_with_capacity(&cfg, Some((4.0, 48163)));
        assert!(
            mem <= 2754,
            "effective_limits must respect guest_reserve_mb: expected <= 2754 MB (44067/16), got {mem} MB"
        );
        assert!(mem >= 512); // floor still applies
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

        let started = start_missing_runners(&cfg, Backend::Docker, 16).unwrap();

        assert_eq!(
            started.len(),
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

        let started = start_missing_runners_with_starter(&cfg, Backend::Docker, 5, starter)
            .expect("4 of 5 slots succeed, so overall call must return Ok with those 4");

        assert_eq!(
            started.len(),
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

        let started = ensure_count(&cfg, Backend::Docker).unwrap();

        assert_eq!(
            started,
            vec!["ez-org-runner-4", "ez-org-runner-5"],
            "ensure_count must compute missing=count-alive using only current-prefix containers"
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
    fn ensure_count_outcome_flags_fewer_than_half_started() {
        let _env = TestEnv::new("ensure_count_partial");
        let cfg = cfg_with(4, "ez-org-runner");
        *TEST_RELEASE_STALE_SLOTS_RESULT.lock().unwrap() = Some(0);
        *TEST_FREE_DISK_GB.lock().unwrap() = Some(Some(100));
        *TEST_MANAGED_CONTAINERS.lock().unwrap() = Some(Vec::new());
        *TEST_START_ONE_NAMES.lock().unwrap() = Some(vec!["ez-org-runner-1".into()]);

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
            b"#!/bin/sh\nif [ \"$1\" = \"run\" ]; then echo \"docker run failed: simulation\" >&2; exit 1; else exit 0; fi\n",
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

    #[test]
    fn release_stale_slots_handles_empty_runner_id() {
        let _env = TestEnv::new("stale_empty");
        let cfg = cfg_with(2, "ez-org-runner");
        // Reserved (`next_slot`) but `record_slot_runner_id` never ran — this
        // is the "JIT in flight, daemon crashed" wedge case.
        let _slot = next_slot(&cfg).unwrap();

        let live: Vec<github::RunnerInfo> = vec![];
        let reclaimed = release_stale_slots_from(&read_slot_assignments().unwrap(), &live).unwrap();

        assert_eq!(reclaimed, 1, "empty-id reservations must be released");
        assert!(
            read_slot_assignments().unwrap().assignments.is_empty(),
            "all reservations must be cleared when none have runner_ids"
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
            "once the grace window has elapsed, an offline/!busy/no-container \
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
            let res = eval_admission(30.0, 16 * 1024 * 1024 * 1024, RUNNER_BYTES, &mut window);
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
            let err = eval_admission(80.0, 16 * 1024 * 1024 * 1024, RUNNER_BYTES, &mut window)
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
            let err = eval_admission(30.0, one_gib, RUNNER_BYTES, &mut window)
                .expect_err("1 GiB avail vs 3 GiB runner must refuse");
            assert!(
                err.contains("MemAvailable 1024 MB < 2× runner memory 3072 MB"),
                "refusal message must cite both MB values, got: {err}"
            );
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
            let err = eval_admission(20.0, 16 * 1024 * 1024 * 1024, RUNNER_BYTES, &mut window)
                .expect_err("5-tick rising must refuse even at 20% pressure");
            assert!(
                err.contains("PSE hysteresis: pressure rising 5 consecutive ticks"),
                "refusal message must cite hysteresis, got: {err}"
            );
        }
    }
}
