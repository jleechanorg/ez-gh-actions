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

/// Kill all managed runner containers. Returns how many were removed.
pub fn stop_all(cfg: &Config) -> Result<usize> {
    let containers = managed_containers()?;
    for c in &containers {
        let _ = Command::new("docker").args(["rm", "-f", &c.id]).output();
    }
    // Deregister runners that never picked up a job (JIT runners that ran a
    // job already removed themselves).
    if let Ok(runners) = github::list_runners(&cfg.github) {
        for r in runners {
            if r.name.starts_with("ezgha-") && !r.busy {
                let _ = github::remove_runner(&cfg.github, r.id);
            }
        }
    }
    Ok(containers.len())
}

/// Free disk in GB on the filesystem holding docker's data (falls back to /).
pub fn free_disk_gb() -> Option<u64> {
    let path = Command::new("docker")
        .args(["info", "--format", "{{.DockerRootDir}}"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "/".into());
    let out = Command::new("df").args(["-Pk", &path]).output().ok()?;
    if !out.status.success() {
        return None;
    }
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
/// Refuses to spawn when host disk is below the configured floor — disk
/// exhaustion is the dominant self-hosted runner failure mode, and spawning
/// more work onto a full disk makes the incident worse.
pub fn ensure_count(cfg: &Config, backend: Backend) -> Result<Vec<String>> {
    let alive = managed_containers()?.len() as u32;
    if alive >= cfg.runner.count {
        return Ok(Vec::new());
    }
    if let Some(free) = free_disk_gb() {
        if free < cfg.limits.min_free_disk_gb {
            bail!(
                "only {free} GB free on docker's filesystem (floor: {} GB) — refusing to spawn runners; \
                 reclaim space (e.g. `docker system prune`) first",
                cfg.limits.min_free_disk_gb
            );
        }
    }
    let mut started = Vec::new();
    for _ in alive..cfg.runner.count {
        let (_, name) = start_one(cfg, backend)?;
        started.push(name);
    }
    Ok(started)
}
