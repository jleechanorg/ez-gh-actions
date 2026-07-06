use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};
use std::env;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Once;

use crate::backend::Backend;
use crate::config::Config;
use crate::github;
use crate::platform::Platform;

const MANAGED_LABEL: &str = "ezgha=managed";

/// Consecutive-`None` counter for `free_disk_gb`. After this many in a
/// row we treat the disk floor as exceeded and refuse to spawn, since a
/// sustained inability to measure is itself a degraded-daemon signal.
const DISK_MEASURE_STRIKES: u32 = 2;
static CONSECUTIVE_DISK_NONE: AtomicU32 = AtomicU32::new(0);

/// Env var that overrides the slot assignments file path. Used by tests to
/// avoid touching the user's real `~/.config/ezgha/slot_assignments.toml`.
const SLOT_ASSIGNMENTS_PATH_ENV: &str = "EZGHA_SLOT_ASSIGNMENTS_PATH";

/// Default prefix used when callers don't have a Config in hand (matches the
/// `default_runner_name_prefix` value in `config::RunnerConfig`).
const DEFAULT_RUNNER_NAME_PREFIX: &str = "ez-org-runner";

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
    let parsed: SlotAssignments = toml::from_str(&raw)
        .with_context(|| format!("parse slot assignments {}", path.display()))?;
    Ok(parsed)
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
    release_stale_slots_from(&read_slot_assignments()?, &live_runners)
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
    let out = Command::new("docker")
        .args(["info", "--format", "{{.NCPU}} {{.MemTotal}}"])
        .output()
        .ok()
        .filter(|o| o.status.success())?;
    let stdout = String::from_utf8_lossy(&out.stdout);
    let mut parts = stdout.split_whitespace();
    let ncpu: f64 = parts.next()?.parse().ok()?;
    let mem_bytes: u64 = parts.next()?.parse().ok()?;
    Some((ncpu, mem_bytes / 1024 / 1024))
}

/// Clamp configured limits to what the daemon can actually provide.
pub fn effective_limits(cfg: &Config) -> (f64, u64) {
    let (mut cpus, mut mem) = (cfg.limits.cpus, cfg.limits.memory_mb);
    if let Some((ncpu, daemon_mem)) = daemon_capacity() {
        if cpus > ncpu {
            eprintln!("note: clamping cpus {cpus} -> {ncpu} (docker daemon capacity)");
            cpus = ncpu;
        }
        if mem > daemon_mem {
            eprintln!("note: clamping memory {mem} MB -> {daemon_mem} MB (docker daemon capacity)");
            mem = daemon_mem;
        }
    }
    (cpus, mem)
}

/// Start one ephemeral JIT runner container. Returns (container_id, runner_name).
pub fn start_one(cfg: &Config, backend: Backend) -> Result<(String, String)> {
    // Acquire a stable numeric slot BEFORE calling GitHub so a JIT
    // registration that never gets a container still gets cleaned up.
    let slot = next_slot(cfg)?;
    let runner_name = runner_name_for(cfg, slot);

    // Clean up any stale container left behind in this slot (failsafe against name conflicts)
    let _ = std::process::Command::new("docker")
        .args(["rm", "-f", &runner_name])
        .output();

    let (cpus, memory_mb) = effective_limits(cfg);
    let (jit, runner_id) =
        match github::generate_jitconfig(&cfg.github, &runner_name, &cfg.runner.labels) {
            Ok(pair) => pair,
            Err(e) => {
                return Err(e);
            }
        };

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

    let out = cmd.output().context("failed to run docker")?;
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
    let out = Command::new("docker")
        .args([
            "ps",
            "--filter",
            &format!("label={MANAGED_LABEL}"),
            "--format",
            "json",
        ])
        .output()
        .context("failed to run docker ps")?;
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

/// Prefix shared by every runner this tool creates. Names are now
/// `{name_prefix}-{slot}` (default `ez-org-runner-1..=count`); the prefix is
/// global across hosts by design, so host-scoped ownership is tracked in the
/// slot assignment file rather than embedded in the name.
pub fn our_runner_prefix() -> String {
    format!("{DEFAULT_RUNNER_NAME_PREFIX}-")
}

/// Kill all managed runner containers. Returns how many were removed.
pub fn stop_all(cfg: &Config) -> Result<usize> {
    let containers = managed_containers()?;
    for c in &containers {
        let _ = Command::new("docker").args(["rm", "-f", &c.id]).output();
    }
    // Deregister THIS HOST's runners: only the slots we own (from local slot
    // assignments), so we never tear down a sibling host's `ez-org-runner-N`
    // that happens to share a numeric slot. The global prefix alone is not
    // a safety boundary — slot ownership is.
    let prefix = our_runner_prefix();
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
    let out = Command::new("docker")
        .args(["run", "--rm", "--entrypoint", "df", image, "-Pk", "/"])
        .output()
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

    fn fake_platform() -> Platform {
        Platform {
            os: "linux",
            arch: "x86_64",
            kvm_usable: false,
            has_tart: false,
            has_virsh: false,
            docker_ok: true,
            sysbox_runtime: false,
            daemon_in_vm: false,
            total_mem_mb: 8192,
            cpus: 4,
        }
    }

    fn cfg_with(count: u32, prefix: &str) -> Config {
        let mut cfg = Config::defaults_for(&fake_platform(), "jleechanorg".into(), Scope::Org);
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
    fn our_runner_prefix_is_host_scoped() {
        // The shared prefix is global (single, deterministic name space);
        // per-host ownership lives in the slot assignment file, not in the
        // prefix, so this just pins the deterministic `ez-org-runner-` form.
        let prefix = our_runner_prefix();
        assert_eq!(prefix, format!("{DEFAULT_RUNNER_NAME_PREFIX}-"));
        assert!(prefix.starts_with("ez-org-runner-"));
        assert!(prefix.ends_with('-'));
        assert!(format!("{prefix}1").starts_with(&prefix));
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
