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

use crate::backend::Backend;
use crate::config::Config;
use crate::github;
use crate::platform::Platform;
use crate::watchdog;

const MANAGED_LABEL: &str = "ezgha=managed";

/// Consecutive-`None` counter for `free_disk_gb`. After this many in a
/// row we treat the disk floor as exceeded and refuse to spawn, since a
/// sustained inability to measure is itself a degraded-daemon signal.
const DISK_MEASURE_STRIKES: u32 = 2;
static CONSECUTIVE_DISK_NONE: AtomicU32 = AtomicU32::new(0);
const DOCKER_TIMEOUT: Duration = Duration::from_secs(45);

/// Env var that overrides the slot assignments file path. Used by tests to
/// avoid touching the user's real `~/.config/ezgha/slot_assignments.toml`.
const SLOT_ASSIGNMENTS_PATH_ENV: &str = "EZGHA_SLOT_ASSIGNMENTS_PATH";

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
fn slot_assignments_path() -> PathBuf {
    #[cfg(test)]
    {
        if let Some(p) = crate::docker_backend::tests::test_slot_path() {
            return p;
        }
    }
    if let Ok(p) = env::var(SLOT_ASSIGNMENTS_PATH_ENV) {
        return PathBuf::from(p);
    }
    let config_home = env::var("XDG_CONFIG_HOME").unwrap_or_else(|_| {
        let home = env::var("HOME").unwrap_or_else(|_| "~".into());
        format!("{home}/.config")
    });
    PathBuf::from(config_home)
        .join("ezgha")
        .join("slot_assignments.toml")
}

fn read_slot_assignments() -> Result<SlotAssignments> {
    let path = slot_assignments_path();
    if !path.exists() {
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

fn write_slot_assignments(assignments: &SlotAssignments) -> Result<()> {
    let path = slot_assignments_path();
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
    let mut assignments = read_slot_assignments()?;
    for slot in 1..=cfg.runner.count {
        let key = slot.to_string();
        if let std::collections::btree_map::Entry::Vacant(e) = assignments.assignments.entry(key) {
            e.insert(String::new());
            write_slot_assignments(&assignments)?;
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
pub fn record_slot_runner_id(slot: u32, runner_id: u64) -> Result<()> {
    let mut assignments = read_slot_assignments()?;
    assignments
        .assignments
        .insert(slot.to_string(), runner_id.to_string());
    write_slot_assignments(&assignments)
}

/// Release a slot previously acquired by `next_slot`. The slot becomes
/// available for the next call.
pub fn release_slot(slot: u32) -> Result<()> {
    let mut assignments = read_slot_assignments()?;
    assignments.assignments.remove(&slot.to_string());
    write_slot_assignments(&assignments)
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
            eprintln!("warning: skipping stale-slot reconciliation (GitHub unreachable): {e:#}");
            return Ok(0);
        }
    };
    watchdog::ping();
    let assignments = read_slot_assignments()?;
    let reclaimed = release_stale_slots_from(&assignments, &live_runners)?;
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
    watchdog::ping();
    Ok(reclaimed + orphans_reaped)
}

/// Inner reconciliation routine that operates on a caller-provided live-runner
/// snapshot. Split out so tests can drive it without a live `gh` auth context;
/// `release_stale_slots` is the production entry point that fetches the live
/// list via `github::list_runners`.
fn release_stale_slots_from(
    assignments: &SlotAssignments,
    live_runners: &[github::RunnerInfo],
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
            release_slot(slot_n)?;
            reclaimed += 1;
        } else if let Ok(rid) = id_str.parse::<u64>() {
            if !live_ids.contains(&rid) {
                // The recorded runner_id is no longer registered on GitHub
                // (server-side reap, manual removal, or a stale entry from a
                // prior host). Treat the slot as free.
                release_slot(slot_n)?;
                reclaimed += 1;
            }
        }
    }
    Ok(reclaimed)
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
    format!("{}-{}", cfg.runner.name_prefix, slot)
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
    let (mut cpus, mut mem) = (cfg.limits.cpus, cfg.limits.memory_mb);
    if let Some((ncpu, daemon_mem)) = daemon_capacity() {
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
    let owned_ids: HashSet<u64> = read_slot_assignments()?
        .assignments
        .values()
        .filter_map(|s| s.parse::<u64>().ok())
        .collect();
    watchdog::ping();
    let (jit, runner_id) =
        match generate_jitconfig(&cfg.github, &runner_name, &cfg.runner.labels, &owned_ids) {
            Ok(pair) => pair,
            Err(e) => {
                let _ = release_slot(slot);
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
    cmd.args(["--cpus", &format!("{cpus}")]);
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
    record_slot_runner_id(slot, runner_id)?;
    let container_id = String::from_utf8_lossy(&out.stdout).trim().to_string();
    Ok((container_id, runner_name))
}

#[derive(Debug, Deserialize)]
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

pub fn managed_containers() -> Result<Vec<ManagedContainer>> {
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

/// Kill all managed runner containers. Returns how many were removed.
pub fn stop_all(cfg: &Config) -> Result<usize> {
    let containers = managed_containers()?;
    for c in &containers {
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
    let owned_runner_ids: Vec<u64> = match read_slot_assignments() {
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
    let slots_to_release: Vec<u32> = match read_slot_assignments() {
        Ok(a) => a
            .assignments
            .keys()
            .filter_map(|k| k.parse::<u32>().ok())
            .collect(),
        Err(_) => Vec::new(),
    };
    for slot in slots_to_release {
        let _ = release_slot(slot);
    }
    Ok(containers.len())
}

/// Free disk in GB as seen by the docker DAEMON, measured from inside a
/// container: the container's root overlay lives on the daemon's storage, so
/// this is the disk runner jobs will actually fill. A host-side `df` would
/// read the wrong filesystem whenever the daemon is a VM (Colima/Lima/Desktop).
pub fn free_disk_gb(image: &str) -> Option<u64> {
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

/// Ensure `count` managed runner containers are alive; start the shortfall.
/// Refuses to spawn when the daemon's disk is below the configured floor —
/// disk exhaustion is the dominant self-hosted runner failure mode, and
/// spawning more work onto a full disk makes the incident worse.
pub fn ensure_count(cfg: &Config, backend: Backend) -> Result<Vec<String>> {
    // Reconcile stale slot assignments before we look at container counts:
    // a daemon crash between `next_slot` and the container coming up leaves a
    // reservation that would otherwise wedge `next_slot` forever ("all N
    // runner slot(s) are currently in use"). `serve` calls this on a 30s
    // loop, so the host self-heals on the next tick.
    let _ = release_stale_slots(cfg);
    // Print the host-kernel warning at most once per process — `serve` would
    // otherwise re-emit it every 30s.
    DOCTOR_PRINTED.call_once(|| print_doctor(&crate::platform::detect()));
    let alive = managed_containers()?.len() as u32;
    if alive >= cfg.runner.count {
        return Ok(Vec::new());
    }
    match free_disk_gb(&cfg.runner.image) {
        Some(free) if free < cfg.limits.min_free_disk_gb => {
            CONSECUTIVE_DISK_NONE.store(0, Ordering::Relaxed);
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
    let mut started = Vec::new();
    let mut last_err = None;
    for _ in alive..cfg.runner.count {
        watchdog::ping();
        match start_one(cfg, backend) {
            Ok((_, name)) => started.push(name),
            Err(e) => {
                eprintln!("warning: failed to start runner: {e:#}");
                last_err = Some(e);
            }
        }
    }
    // Release any failed reservations from this cycle
    let _ = release_stale_slots(cfg);

    if started.is_empty() {
        if let Some(e) = last_err {
            return Err(e);
        }
    }
    Ok(started)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Config, Scope};
    use crate::platform::Platform;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Mutex;
    use std::time::{Duration, Instant};

    struct EnvVarRestore {
        key: &'static str,
        val: Option<std::ffi::OsString>,
    }

    impl EnvVarRestore {
        fn set(key: &'static str, val: &str) -> Self {
            let prev = std::env::var_os(key);
            std::env::set_var(key, val);
            Self { key, val: prev }
        }
    }

    impl Drop for EnvVarRestore {
        fn drop(&mut self) {
            match &self.val {
                Some(v) => std::env::set_var(self.key, v),
                None => std::env::remove_var(self.key),
            }
        }
    }

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
        // effective_limits reads from the LIVE daemon via `docker info`, not
        // from the cfg, so the expected per-runner ceiling must be derived
        // from the same live daemon the function will use.
        let (ncpu, daemon_mem) =
            daemon_capacity().expect("effective_limits test requires a reachable docker daemon");
        let expected_cpu_share = (ncpu / 16.0).max(0.5);
        let expected_mem_share = (daemon_mem / 16).max(512);
        let (cpus, mem) = effective_limits(&cfg);
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
        let (ncpu, daemon_mem) =
            daemon_capacity().expect("effective_limits test requires a reachable docker daemon");
        let (cpus, mem) = effective_limits(&cfg);
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
        let _path_guard = EnvVarRestore::set("PATH", "/nonexistent");
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
}
