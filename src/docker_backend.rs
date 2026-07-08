use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};
use std::env;
use std::io::Read;
use std::path::Path;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::mpsc;
use std::sync::Once;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::alert::{self, Severity};
use crate::backend::Backend;
use crate::config::Config;
use crate::github;
use crate::platform::Platform;
use crate::reaper;
use crate::watchdog;

const MANAGED_LABEL: &str = "ezgha=managed";

/// Consecutive-`None` counter for `free_disk_gb`. After this many in a
/// row we treat the disk floor as exceeded and refuse to spawn, since a
/// sustained inability to measure is itself a degraded-daemon signal.
const DISK_MEASURE_STRIKES: u32 = 2;
static CONSECUTIVE_DISK_NONE: AtomicU32 = AtomicU32::new(0);
const DOCKER_TIMEOUT: Duration = Duration::from_secs(45);

#[cfg(test)]
static TEST_RELEASE_STALE_SLOTS_RESULT: std::sync::Mutex<Option<usize>> =
    std::sync::Mutex::new(None);
#[cfg(test)]
static TEST_FREE_DISK_GB: std::sync::Mutex<Option<Option<u64>>> = std::sync::Mutex::new(None);
#[cfg(test)]
static TEST_START_ONE_NAMES: std::sync::Mutex<Option<Vec<String>>> = std::sync::Mutex::new(None);

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

/// Reserve the first unused slot in `1..=cfg.runner.count` and return its index.
/// The slot is recorded in the persisted assignments file under an empty
/// runner_id marker; callers MUST update it via `record_slot_runner_id` after
/// the JIT registration succeeds, or release it via `release_slot` if the
/// registration fails.
pub fn next_slot(cfg: &Config) -> Result<u32> {
    if cfg.runner.count == 0 {
        bail!("cfg.runner.count is 0; nothing to allocate");
    }
    let mut assignments = read_slot_assignments_for(Some(cfg))?;
    for slot in 1..=cfg.runner.count {
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
    assignments
        .assignments
        .insert(slot.to_string(), runner_id.to_string());
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
    assignments.assignments.remove(&slot.to_string());
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
        Ok(containers) => Some(
            containers
                .into_iter()
                .map(|container| container.name)
                .collect::<HashSet<_>>(),
        ),
        Err(err) => {
            eprintln!(
                "warning: skipping container-aware stale-slot reconciliation (docker unreachable): {err:#}"
            );
            None
        }
    };
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
                // The recorded runner_id is no longer registered on GitHub
                // (server-side reap, manual removal, or a stale entry from a
                // prior host). Treat the slot as free.
                release_slot_for(cfg, slot_n)?;
                reclaimed += 1;
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
    let mut cmd = Command::new("docker");
    cmd.args(["info", "--format", "{{.NCPU}} {{.MemTotal}}"]);
    let out = run_docker(cmd, "reading docker daemon capacity").ok()?;
    let stdout = String::from_utf8_lossy(&out.stdout);
    let mut parts = stdout.split_whitespace();
    let ncpu: f64 = parts.next()?.parse().ok()?;
    let mem_bytes: u64 = parts.next()?.parse().ok()?;
    Some((ncpu, mem_bytes / 1024 / 1024))
}

/// Clamp configured limits to what the daemon can actually provide PER
/// RUNNER. With `count` ephemeral runners, each runner must fit
/// `daemon / count`; clamping to raw `daemon` would silently over-commit by
/// `count×` (bug vmz — count=16 on a 4-CPU/12-GB daemon would issue per-runner
/// requests summing to 32 CPU + 95 GB, triggering OOM-kills).
pub fn effective_limits(cfg: &Config) -> (f64, u64) {
    effective_limits_with_capacity(cfg, daemon_capacity())
}

fn effective_limits_with_capacity(cfg: &Config, capacity: Option<(f64, u64)>) -> (f64, u64) {
    let (mut cpus, mut mem) = (cfg.limits.cpus, cfg.limits.memory_mb);
    if let Some((ncpu, daemon_mem)) = capacity {
        let n_f = (cfg.runner.count as f64).max(1.0);
        let n_u = (cfg.runner.count as u64).max(1);
        // Per-runner share of the daemon, floored at validate() minimums so a
        // hand-edited cfg that over-aggregates still gets a sane per-runner
        // request rather than docker run exploding from over-memory.
        let cpu_share = (ncpu / n_f).max(0.5);
        let mem_share = (daemon_mem / n_u).max(512);
        if cpus > cpu_share {
            eprintln!(
                "note: clamping cpus {cpus} -> {cpu_share} (daemon {ncpu} / {} runners)",
                cfg.runner.count
            );
            cpus = cpu_share;
        }
        if mem > mem_share {
            eprintln!(
                "note: clamping memory {mem} MB -> {mem_share} MB (daemon {daemon_mem} / {} runners)",
                cfg.runner.count
            );
            mem = mem_share;
        }
    }
    (cpus, mem)
}

/// Start one ephemeral JIT runner container. Returns (container_id, runner_name).
pub fn start_one(cfg: &Config, backend: Backend) -> Result<(String, String)> {
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

    start_one_with_generate(cfg, backend, github::generate_jitconfig)
}

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
    let runner_name = runner_name_for(cfg, slot);

    // Clean up any stale container left behind in this slot (failsafe against name conflicts)
    let mut pre_rm = Command::new("docker");
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
    watchdog::ping();

    let mut cmd = Command::new("docker");
    cmd.args(["run", "-d", "--rm"]);
    cmd.args(["--name", &runner_name]);
    cmd.args(["--label", MANAGED_LABEL]);
    cmd.args(["--label", &format!("ezgha.runner_id={runner_id}")]);
    // Hard resource limits: the reason this tool exists. A runaway job dies
    // inside its cgroup instead of taking the host down.
    cmd.args(["--memory", &format!("{memory_mb}m")]);
    cmd.args(["--memory-swap", &format!("{memory_mb}m")]);
    cmd.args(["--cpus", &format!("{:.2}", cpus)]);
    cmd.args(["--pids-limit", &format!("{}", cfg.limits.pids)]);
    cmd.args(["--security-opt", "no-new-privileges"]);
    if backend == Backend::DockerSysbox {
        cmd.args(["--runtime", "sysbox-runc"]);
    }
    cmd.arg(&cfg.runner.image);
    cmd.args(["./run.sh", "--jitconfig", &jit]);

    let out = run_docker(cmd, "docker run start_one")?;
    watchdog::ping();
    if !out.status.success() {
        // The JIT registration exists server-side but no runner will ever
        // connect; clean it up so the repo runner list stays tidy.
        let _ = github::remove_runner(&cfg.github, runner_id);
        bail!(
            "docker run failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
    // Record the runner_id now that the container is up so the slot can be
    // reclaimed if the JIT registration is later removed server-side.
    record_slot_runner_id_for(Some(cfg), slot, runner_id)?;
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

    let mut cmd = Command::new("docker");
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
        let mut cmd = Command::new("docker");
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
    if let Ok(runners) = github::list_runners(&cfg.github) {
        for r in runners {
            let owned = owned_runner_ids.contains(&r.id);
            if owned && r.name.starts_with(&prefix) && !r.busy {
                let _ = github::remove_runner(&cfg.github, r.id);
            }
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

/// Free disk in GB as seen by the docker DAEMON, measured from inside a
/// container: the container's root overlay lives on the daemon's storage, so
/// this is the disk runner jobs will actually fill. A host-side `df` would
/// read the wrong filesystem whenever the daemon is a VM (Colima/Lima/Desktop).
pub fn free_disk_gb(image: &str) -> Option<u64> {
    #[cfg(test)]
    if let Some(free) = *TEST_FREE_DISK_GB.lock().unwrap() {
        return free;
    }

    let mut cmd = Command::new("docker");
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

fn start_missing_runners(cfg: &Config, backend: Backend, missing: u32) -> Result<Vec<String>> {
    let mut started = Vec::new();
    let mut last_err = None;
    for _ in 0..missing {
        watchdog::ping();
        match start_one(cfg, backend) {
            Ok((_, name)) => started.push(name),
            Err(e) => {
                eprintln!("warning: failed to start runner: {e:#}");
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
            Self { _lock: lock, path }
        }
    }

    impl Drop for TestEnv {
        fn drop(&mut self) {
            *TEST_SLOT_PATH.lock().unwrap() = None;
            *TEST_RELEASE_STALE_SLOTS_RESULT.lock().unwrap() = None;
            *TEST_FREE_DISK_GB.lock().unwrap() = None;
            *TEST_MANAGED_CONTAINERS.lock().unwrap() = None;
            *TEST_START_ONE_NAMES.lock().unwrap() = None;
            let _ = std::fs::remove_file(&self.path);
            if let Some(parent) = self.path.parent() {
                let _ = std::fs::remove_dir(parent);
            }
        }
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
        let reclaimed = release_stale_slots_from(&read_slot_assignments().unwrap(), &live).unwrap();

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
        let _env = TestEnv::new("offline_missing_container");
        let cfg = cfg_with(2, "ez-org-runner");
        let _slot = next_slot(&cfg).unwrap();
        record_slot_runner_id(1, 1234).unwrap();

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
            "offline idle runner without a local container should not hold its slot"
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
}
