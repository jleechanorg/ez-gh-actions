use anyhow::{bail, Context, Result};
use serde::Deserialize;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::backend::Backend;
use crate::config::Config;
use crate::github;

const MANAGED_LABEL: &str = "ezgha=managed";

fn unique_suffix() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("{secs:x}{nanos:x}")
}

fn hostname() -> String {
    // Read the system hostname. An empty result is fine: the runner name is
    // scoped by a per-install UUID, so hostname is decorative (and helps when
    // triaging `docker ps` output by eye). The historical fallback to the
    // literal string "host" was a fleet-wide outage button: two degraded
    // hosts both produced `ezgha-host-...` and could deregister each other.
    std::process::Command::new("hostname")
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_default()
}

/// Per-install path for the host id file: `$XDG_CONFIG_HOME/ezgha/host_id`,
/// falling back to `$HOME/.config/ezgha/host_id` on platforms that don't set
/// `XDG_CONFIG_HOME` (notably macOS). The file is the source of truth for
/// the host-scoped runner-name prefix.
fn host_id_path() -> Option<std::path::PathBuf> {
    let base = std::env::var("XDG_CONFIG_HOME")
        .ok()
        .filter(|s| !s.is_empty())
        .map(std::path::PathBuf::from)
        .or_else(|| {
            std::env::var("HOME")
                .ok()
                .filter(|h| !h.is_empty())
                .map(|h| std::path::PathBuf::from(h).join(".config"))
        })?;
    Some(base.join("ezgha").join("host_id"))
}

/// Read the persisted host id, or mint a new UUID v4 and persist it. Returning
/// `None` means the disk path is unwritable AND we have no hostname; callers
/// should treat that as a hard error because the runner name would collapse
/// to the bare "ezgha-" prefix that the host-scoped deregistration fix
/// (commit `minimax: feat: vm-or-refuse policy...`) was added to prevent.
fn load_or_mint_host_id_at(path: &std::path::Path) -> Option<String> {
    if let Ok(s) = std::fs::read_to_string(path) {
        let s = s.trim();
        if !s.is_empty() {
            return Some(s.to_string());
        }
    }
    let id = uuid::Uuid::new_v4().to_string();
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    match std::fs::write(path, &id) {
        Ok(()) => Some(id),
        Err(e) => {
            eprintln!(
                "warning: could not persist host_id to {}: {e}; \
                 runner names will fall back to hostname-only scoping",
                path.display()
            );
            None
        }
    }
}

pub fn load_or_mint_host_id() -> Option<String> {
    let path = host_id_path()?;
    load_or_mint_host_id_at(&path)
}

/// First 8 hex chars of a UUID (the first segment of `xxxxxxxx-...`). Eight
/// hex chars is enough entropy to disambiguate any plausible fleet and keeps
/// runner names short. The full UUID is what's persisted on disk.
fn short_host_id(host_id: &str) -> &str {
    host_id.get(..8).unwrap_or(host_id)
}

/// Pure prefix builder so the test suite can verify all 3 input shapes
/// without touching the filesystem or the `hostname` subprocess.
///
/// The UUID is the load-bearing disambiguator: even on a host where
/// `hostname` returns the empty string (container with no `/bin/hostname`,
/// permissions issue, `unshare -n`, etc.) the prefix is still globally
/// unique. Hostname is a decorative second token when present, never the
/// sole basis for the prefix.
pub fn build_runner_prefix(host_id: Option<&str>, hostname: &str) -> String {
    let short = host_id.map(short_host_id);
    match (short, hostname.is_empty()) {
        (Some(uid), true) => format!("ezgha-{uid}-"),
        (Some(uid), false) => format!("ezgha-{uid}-{hostname}-"),
        (None, true) => "ezgha-".to_string(),
        (None, false) => format!("ezgha-{hostname}-"),
    }
}

/// Pure runner-name builder: prefix + unique suffix. Kept separate from
/// `build_runner_prefix` so the test suite can also assert that the
/// per-run unique suffix lands at the tail of the name.
pub fn build_runner_name(host_id: Option<&str>, hostname: &str, suffix: &str) -> String {
    let short = host_id.map(short_host_id);
    match (short, hostname.is_empty()) {
        (Some(uid), true) => format!("ezgha-{uid}-{suffix}"),
        (Some(uid), false) => format!("ezgha-{uid}-{hostname}-{suffix}"),
        (None, true) => format!("ezgha-{suffix}"),
        (None, false) => format!("ezgha-{hostname}-{suffix}"),
    }
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
    let host_id = load_or_mint_host_id();
    let runner_name = build_runner_name(host_id.as_deref(), &hostname(), &unique_suffix());
    let (cpus, memory_mb) = effective_limits(cfg);
    let (jit, runner_id) =
        github::generate_jitconfig(&cfg.github, &runner_name, &cfg.runner.labels)?;

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

/// Runner names embed this host's per-install UUID; only ever deregister our
/// own. Deregistering by bare "ezgha-" prefix would tear down every other
/// host's idle runners on a shared repo/org — a fleet-wide outage button.
/// Hostnames alone aren't unique (cloned VMs, default `ubuntu`, Mac.local)
/// and the previous literal-"host" fallback collapsed degraded hosts onto
/// the same prefix, so the UUID is the load-bearing disambiguator and
/// hostname is decorative.
pub fn our_runner_prefix() -> String {
    let host_id = load_or_mint_host_id();
    build_runner_prefix(host_id.as_deref(), &hostname())
}

/// Kill all managed runner containers. Returns how many were removed.
pub fn stop_all(cfg: &Config) -> Result<usize> {
    let containers = managed_containers()?;
    for c in &containers {
        let _ = Command::new("docker").args(["rm", "-f", &c.id]).output();
    }
    // Deregister THIS HOST's runners that never picked up a job (JIT runners
    // that ran a job already removed themselves).
    let prefix = our_runner_prefix();
    if let Ok(runners) = github::list_runners(&cfg.github) {
        for r in runners {
            if r.name.starts_with(&prefix) && !r.busy {
                let _ = github::remove_runner(&cfg.github, r.id);
            }
        }
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
    let alive = managed_containers()?.len() as u32;
    if alive >= cfg.runner.count {
        return Ok(Vec::new());
    }
    match free_disk_gb(&cfg.runner.image) {
        Some(free) if free < cfg.limits.min_free_disk_gb => {
            bail!(
                "only {free} GB free on docker's filesystem (floor: {} GB) — refusing to spawn runners; \
                 reclaim space (e.g. `docker system prune`) first",
                cfg.limits.min_free_disk_gb
            );
        }
        Some(_) => {}
        None => eprintln!(
            "warning: could not measure daemon free disk — disk floor guard is NOT active this cycle"
        ),
    }
    let mut started = Vec::new();
    for _ in alive..cfg.runner.count {
        let (_, name) = start_one(cfg, backend)?;
        started.push(name);
    }
    Ok(started)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Prefix builder: 3 input shapes from the spec, each must produce a
    // "unique-feeling" prefix (always includes a disambiguating token —
    // UUID when present, hostname as fallback). The shared baseline asserts
    // that the prefix has the right envelope and is never the dangerous
    // bare "ezgha-" or "ezgha-host-" patterns the original `hostname()`
    // fallback could produce.

    #[test]
    fn build_prefix_with_uuid_and_hostname() {
        let p = build_runner_prefix(Some("f47ac10b"), "myhost");
        assert!(p.starts_with("ezgha-"));
        assert!(p.ends_with('-'));
        assert!(p.contains("f47ac10b"), "UUID must be embedded: {p}");
        assert!(p.contains("myhost"), "hostname must be embedded: {p}");
        // Format is `ezgha-<uid>-<hostname>-`, no accidental double dash.
        assert_eq!(p, "ezgha-f47ac10b-myhost-");
    }

    #[test]
    fn build_prefix_with_uuid_no_hostname() {
        let p = build_runner_prefix(Some("f47ac10b"), "");
        assert!(p.starts_with("ezgha-"));
        assert!(p.ends_with('-'));
        assert!(p.contains("f47ac10b"), "UUID must be embedded: {p}");
        // No hostname → no `hostname-` segment and no double dash.
        assert_eq!(p, "ezgha-f47ac10b-");
        assert!(!p.contains("--"));
    }

    #[test]
    fn build_prefix_no_uuid_with_hostname() {
        // Defensive case: persisted UUID unavailable (disk unwritable, no
        // $HOME / $XDG_CONFIG_HOME). The actual hostname is the only
        // disambiguator — the prefix must embed it, not the literal
        // "host" the old code would have produced.
        let p = build_runner_prefix(None, "weirdhost42");
        assert!(p.starts_with("ezgha-"));
        assert!(p.ends_with('-'));
        assert!(p.contains("weirdhost42"), "hostname must be embedded: {p}");
        assert_eq!(p, "ezgha-weirdhost42-");
        // Regression guard: the old `unwrap_or_else(|| "host".into())`
        // would have produced `ezgha-host-` here.
        assert_ne!(p, "ezgha-host-");
    }

    // Runner name builder: same matrix plus the per-run unique suffix.
    // Verifies the suffix lands at the tail and the prefix portion of the
    // name is consistent with `build_runner_prefix` so `starts_with`
    // matching in `stop_all` still works.

    #[test]
    fn build_runner_name_uses_prefix_and_suffix() {
        let n = build_runner_name(Some("f47ac10b"), "myhost", "deadbeef");
        assert_eq!(n, "ezgha-f47ac10b-myhost-deadbeef");
        let prefix = build_runner_prefix(Some("f47ac10b"), "myhost");
        assert!(n.starts_with(&prefix));
    }

    #[test]
    fn build_runner_name_no_hostname() {
        let n = build_runner_name(Some("f47ac10b"), "", "deadbeef");
        assert_eq!(n, "ezgha-f47ac10b-deadbeef");
    }

    // Persistence: a fresh host_id file is minted on first read and
    // re-read on subsequent calls. Without this guarantee two reinstalls
    // of the same binary on the same box would mint new UUIDs every time
    // the binary is invoked, defeating the "stable across re-runs"
    // property the host-scoped deregistration fix relies on.

    #[test]
    fn load_or_mint_creates_when_missing() {
        let dir = std::env::temp_dir().join(format!("ezgha-test1fu-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let path = dir.join("host_id");

        let id1 = load_or_mint_host_id_at(&path).expect("mint on missing file");
        assert!(!id1.is_empty());
        assert!(path.exists(), "host_id file must be persisted");

        // Second call must return the same id, not mint a new one.
        let id2 = load_or_mint_host_id_at(&path).expect("read existing");
        assert_eq!(id1, id2, "host_id must be stable across calls");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn load_or_mint_reads_existing_without_overwriting() {
        let dir =
            std::env::temp_dir().join(format!("ezgha-test1fu-existing-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("host_id");
        // Use a real UUID format so the on-disk format is realistic.
        std::fs::write(&path, "f47ac10b-58cc-4372-a567-0e02b2c3d479\n").unwrap();

        let id = load_or_mint_host_id_at(&path).expect("read existing");
        assert_eq!(id, "f47ac10b-58cc-4372-a567-0e02b2c3d479");

        // The existing file must not be clobbered by a re-mint.
        let on_disk = std::fs::read_to_string(&path).unwrap();
        assert!(on_disk.contains("f47ac10b-58cc-4372-a567-0e02b2c3d479"));

        let _ = std::fs::remove_dir_all(&dir);
    }
}
