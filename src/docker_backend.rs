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
    std::process::Command::new("hostname")
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "host".into())
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
    let runner_name = format!("ezgha-{}-{}", hostname(), unique_suffix());
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

/// Runner names embed this host's name; only ever deregister our own.
/// Deregistering by bare "ezgha-" prefix would tear down every other host's
/// idle runners on a shared repo/org — a fleet-wide outage button.
pub fn our_runner_prefix() -> String {
    format!("ezgha-{}-", hostname())
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

/// Apply the disk-floor guard given a (possibly-missing) free-disk measurement.
///
/// The disk floor is the flagship safety invariant of this tool: disk
/// exhaustion is the dominant self-hosted runner failure mode and spawning
/// more work onto a full disk makes the incident worse. We therefore fail
/// CLOSED on every uncertain outcome — including a `None` measurement from a
/// failed `docker run --entrypoint df` probe — rather than only when the probe
/// returns a number below the floor. A failed probe could mean the daemon has
/// lost its storage entirely; proceeding would be reckless.
fn check_disk_floor(free: Option<u64>, floor_gb: u64) -> Result<()> {
    match free {
        Some(free) if free < floor_gb => bail!(
            "only {free} GB free on docker's filesystem (floor: {floor_gb} GB) — refusing to spawn runners; \
             reclaim space (e.g. `docker system prune`) first"
        ),
        Some(_) => Ok(()),
        None => bail!(
            "could not measure daemon free disk (probe failed) — refusing to spawn runners \
             because the disk floor ({floor_gb} GB) is the flagship safety invariant and we \
             cannot confirm it; run `ezgha doctor` or verify your docker setup, then retry"
        ),
    }
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
    check_disk_floor(free_disk_gb(&cfg.runner.image), cfg.limits.min_free_disk_gb)?;
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

    #[test]
    fn runner_prefix_is_host_scoped() {
        let prefix = our_runner_prefix();
        assert!(prefix.starts_with("ezgha-"));
        assert!(prefix.ends_with('-'));
        // Must embed a hostname, not just be the bare "ezgha-" prefix that
        // would match every host's runners.
        assert_eq!(prefix, format!("ezgha-{}-", hostname()));
        assert!(prefix.len() > "ezgha--".len());
        assert!(format!("{prefix}abc123").starts_with(&prefix));
    }

    #[test]
    fn disk_floor_fails_closed_when_probe_returns_none() {
        // A `None` from free_disk_gb() simulates a failed probe — e.g. an
        // image that doesn't exist, a docker daemon that can't run the
        // container, or an `df` output we can't parse. The disk floor is the
        // flagship safety invariant, so the guard must REFUSE to spawn rather
        // than silently downgrade to "no measurement, no protection".
        let err = check_disk_floor(None, 10).expect_err("None must fail closed");
        let msg = format!("{err:#}");

        // Error message must explain the failure mode, name the assumed floor,
        // and point the operator at the recovery path.
        assert!(
            msg.contains("could not measure daemon free disk"),
            "error should explain the probe failure, got: {msg}"
        );
        assert!(
            msg.contains("10"),
            "error should name the assumed minimum floor (10 GB), got: {msg}"
        );
        assert!(
            msg.contains("ezgha doctor"),
            "error should point at `ezgha doctor`, got: {msg}"
        );
    }

    #[test]
    fn disk_floor_admits_when_probe_meets_floor() {
        // Sanity check: passing measurement >= floor lets the caller proceed.
        // Guards against the fail-closed patch accidentally closing on the
        // happy path too.
        check_disk_floor(Some(50), 10).expect("ample disk must be admitted");
        check_disk_floor(Some(10), 10).expect("disk exactly at floor must be admitted");
    }

    #[test]
    fn disk_floor_bails_when_probe_below_floor() {
        // Existing fail-closed behavior on measured shortfalls must be
        // preserved — the new None arm is additive, not a replacement.
        let err = check_disk_floor(Some(3), 10).expect_err("3 GB below 10 GB floor must bail");
        let msg = format!("{err:#}");
        assert!(
            msg.contains("3 GB"),
            "error should report measured free, got: {msg}"
        );
        assert!(
            msg.contains("10"),
            "error should name the floor, got: {msg}"
        );
    }
}
