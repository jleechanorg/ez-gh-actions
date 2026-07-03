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

/// Per-runner caps derived from daemon capacity divided by runner count.
///
/// Without division, N runners each sized to the full daemon memory would
/// over-commit the daemon VM (common on Colima/Lima/Desktop where the daemon
/// is smaller than the host) and trigger OOM the moment every job lands.
///
/// Floors: cpus ≥ 0.5, memory ≥ 1024 MB so a runaway job can't starve its
/// siblings below a workable minimum. `count == 0` is treated as 1
/// defensively — neither the CLI (`Init` defaults to 1) nor `Config::defaults_for`
/// can produce 0 today, but we don't want a future bug here to silently divide
/// by zero.
///
/// Returns `None` when daemon capacity is unknown (e.g. `docker info` fails);
/// callers should leave the configured limits untouched in that case.
pub fn per_runner_caps(count: u32, daemon: Option<(f64, u64)>) -> Option<(f64, u64)> {
    let (ncpu, daemon_mem) = daemon?;
    let divisor = if count == 0 { 1.0 } else { count as f64 };
    let cpus = (ncpu / divisor).max(0.5);
    let mem = ((daemon_mem as f64) / divisor) as u64;
    let mem_mb = mem.max(1024);
    Some((cpus, mem_mb))
}

/// Clamp configured limits to what each runner can actually consume when
/// `cfg.runner.count` runners share one daemon.
pub fn effective_limits(cfg: &Config) -> (f64, u64) {
    effective_limits_with(cfg, daemon_capacity())
}

/// Same as `effective_limits` but with the daemon capacity injected — keeps
/// the clamping logic unit-testable without shelling out to `docker info`.
pub fn effective_limits_with(cfg: &Config, daemon: Option<(f64, u64)>) -> (f64, u64) {
    let (mut cpus, mut mem) = (cfg.limits.cpus, cfg.limits.memory_mb);
    if let Some((per_cpu, per_mem)) = per_runner_caps(cfg.runner.count, daemon) {
        if cpus > per_cpu {
            eprintln!(
                "note: clamping cpus {cpus} -> {per_cpu} (docker daemon capacity / count={})",
                cfg.runner.count
            );
            cpus = per_cpu;
        }
        if mem > per_mem {
            eprintln!(
                "note: clamping memory {mem} MB -> {per_mem} MB (docker daemon capacity / count={})",
                cfg.runner.count
            );
            mem = per_mem;
        }
    }
    (cpus, mem)
}

/// Apply per-runner caps to a config in place — the host-side `init` path
/// writes the resulting `cfg.limits` to disk, so we must mutate rather than
/// return a tuple. Returns the per-runner caps actually applied (or `None`
/// when daemon capacity is unknown, in which case the config is untouched).
pub fn apply_per_runner_caps(cfg: &mut Config, daemon: Option<(f64, u64)>) -> Option<(f64, u64)> {
    let (per_cpu, per_mem) = per_runner_caps(cfg.runner.count, daemon)?;
    cfg.limits.cpus = cfg.limits.cpus.min(per_cpu);
    cfg.limits.memory_mb = cfg.limits.memory_mb.min(per_mem);
    Some((per_cpu, per_mem))
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
    use crate::config::{
        Config, GithubConfig, IsolationLevel, Limits, Policy, RunnerConfig, Scope,
    };

    fn cfg_with_count(count: u32, cpus: f64, memory_mb: u64) -> Config {
        Config {
            version: 1,
            github: GithubConfig {
                scope: Scope::Repo,
                target: "o/r".into(),
            },
            runner: RunnerConfig {
                labels: vec!["self-hosted".into(), "ezgha".into()],
                count,
                image: "ghcr.io/actions/actions-runner:latest".into(),
            },
            limits: Limits {
                memory_mb,
                cpus,
                pids: 512,
                min_free_disk_gb: 10,
            },
            policy: Policy {
                minimum_isolation: IsolationLevel::Container,
            },
        }
    }

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

    // ----- per_runner_caps: the divide-by-count math the rest of the file
    //       (and the host-side init path) all funnel through. These tests
    //       pin the contract so future refactors don't regress OOM safety.

    #[test]
    fn per_runner_caps_count_one_unchanged() {
        // Single runner: no division, caps equal daemon capacity.
        let (cpus, mem) = per_runner_caps(1, Some((4.0, 8 * 1024))).unwrap();
        assert_eq!(cpus, 4.0);
        assert_eq!(mem, 8 * 1024);
    }

    #[test]
    fn per_runner_caps_count_four_in_four_cpu_vm() {
        // 4-cpu VM, 4 runners → each ≤ 1 cpu. Memory also divided: 16 GB / 4 = 4 GB.
        let (cpus, mem) = per_runner_caps(4, Some((4.0, 16 * 1024))).unwrap();
        assert_eq!(cpus, 1.0);
        assert_eq!(mem, 4 * 1024);
    }

    #[test]
    fn per_runner_caps_count_two_with_twelve_gb_memory() {
        // 12 GB daemon memory, 2 runners → each ≤ 6 GB.
        let (cpus, mem) = per_runner_caps(2, Some((8.0, 12 * 1024))).unwrap();
        assert_eq!(cpus, 4.0);
        assert_eq!(mem, 6 * 1024);
    }

    #[test]
    fn per_runner_caps_floors_cpus_at_half() {
        // 1 cpu / 4 runners = 0.25 → floor to 0.5 so a job still has a workable share.
        let (cpus, _) = per_runner_caps(4, Some((1.0, 16 * 1024))).unwrap();
        assert_eq!(cpus, 0.5);
    }

    #[test]
    fn per_runner_caps_floors_memory_at_one_gib() {
        // 4096 MB / 8 = 512 → floor to 1024 MB.
        let (_, mem) = per_runner_caps(8, Some((16.0, 4096))).unwrap();
        assert_eq!(mem, 1024);
    }

    #[test]
    fn per_runner_caps_zero_count_is_defensive_noop() {
        // count == 0 should not happen (CLI default 1, defaults_for gives 1),
        // but defensive: treat as 1 so we never divide by zero or silently
        // return zero-capacity caps.
        let (cpus, mem) = per_runner_caps(0, Some((4.0, 8 * 1024))).unwrap();
        assert_eq!(cpus, 4.0);
        assert_eq!(mem, 8 * 1024);
    }

    #[test]
    fn per_runner_caps_none_when_daemon_unknown() {
        // `docker info` failure propagates as None; callers leave limits alone.
        assert!(per_runner_caps(4, None).is_none());
    }

    // ----- effective_limits: must clamp user-configured limits to the
    //       per-runner caps, not the raw daemon capacity. Uses the
    //       daemon-injection seam so we don't shell out to `docker info`.

    #[test]
    fn effective_limits_count_one_preserves_user_config() {
        // With a single runner, effective_limits should not shrink a user
        // configuration that already fits inside the daemon.
        let cfg = cfg_with_count(1, 2.0, 4 * 1024);
        let (cpus, mem) = effective_limits_with(&cfg, Some((4.0, 8 * 1024)));
        assert_eq!(cpus, 2.0);
        assert_eq!(mem, 4 * 1024);
    }

    #[test]
    fn effective_limits_count_four_clamps_to_per_runner_caps() {
        // User asked for 4 cpus / 8 GB but daemon has 4 cpus / 8 GB and we run
        // 4 runners: each runner must end up ≤ 1 cpu / 2 GB, not the full 4/8.
        let cfg = cfg_with_count(4, 4.0, 8 * 1024);
        let (cpus, mem) = effective_limits_with(&cfg, Some((4.0, 8 * 1024)));
        assert_eq!(cpus, 1.0);
        assert_eq!(mem, 2 * 1024);
    }

    #[test]
    fn effective_limits_preserves_below_cap_user_config() {
        // User asked for less than the per-runner cap → keep as-is.
        let cfg = cfg_with_count(4, 0.5, 1024);
        let (cpus, mem) = effective_limits_with(&cfg, Some((4.0, 8 * 1024)));
        assert_eq!(cpus, 0.5);
        assert_eq!(mem, 1024);
    }

    #[test]
    fn effective_limits_no_clamp_when_daemon_unknown() {
        // Without daemon capacity we can't be sure the config fits, so we
        // pass it through untouched (caller is responsible for sensible defaults).
        let cfg = cfg_with_count(4, 4.0, 8 * 1024);
        let (cpus, mem) = effective_limits_with(&cfg, None);
        assert_eq!(cpus, 4.0);
        assert_eq!(mem, 8 * 1024);
    }

    // ----- apply_per_runner_caps: the host-side init path. Same math as
    //       effective_limits_with, but mutates the config that gets written
    //       to disk. Pinning it here guarantees the init story and the
    //       runtime story agree.

    #[test]
    fn apply_per_runner_caps_init_writes_divided_limits() {
        // Host-side init: write cfg.limits as min(user-default, per-runner cap).
        // count=4, daemon 4 cpus / 8 GB → each runner ≤ 1 cpu / 2 GB. User
        // default 4 cpus / 8 GB shrinks to those per-runner caps.
        let mut cfg = cfg_with_count(4, 4.0, 8 * 1024);
        let applied = apply_per_runner_caps(&mut cfg, Some((4.0, 8 * 1024))).unwrap();
        assert_eq!(applied, (1.0, 2 * 1024));
        assert_eq!(cfg.limits.cpus, 1.0);
        assert_eq!(cfg.limits.memory_mb, 2 * 1024);
    }

    #[test]
    fn apply_per_runner_caps_init_count_one_unchanged() {
        // count=1: no division; user default survives the clamp.
        let mut cfg = cfg_with_count(1, 4.0, 8 * 1024);
        let applied = apply_per_runner_caps(&mut cfg, Some((4.0, 8 * 1024))).unwrap();
        assert_eq!(applied, (4.0, 8 * 1024));
        assert_eq!(cfg.limits.cpus, 4.0);
        assert_eq!(cfg.limits.memory_mb, 8 * 1024);
    }

    #[test]
    fn apply_per_runner_caps_init_count_two_with_twelve_gb() {
        // The exact scenario from the bead: 12 GB daemon, count=2 → 6 GB each.
        let mut cfg = cfg_with_count(2, 8.0, 12 * 1024);
        let applied = apply_per_runner_caps(&mut cfg, Some((8.0, 12 * 1024))).unwrap();
        assert_eq!(applied, (4.0, 6 * 1024));
        assert_eq!(cfg.limits.memory_mb, 6 * 1024);
    }

    #[test]
    fn apply_per_runner_caps_init_preserves_user_sub_cap_config() {
        // If the user already configured below the per-runner cap, do not
        // raise it — `min` semantics preserve user intent. The 1024 MB /
        // 0.5 cpu floors in `per_runner_caps` apply to the cap (the upper
        // bound), not to the user config; the init path should not silently
        // rewrite a user's explicit choice.
        let mut cfg = cfg_with_count(4, 0.5, 512);
        let applied = apply_per_runner_caps(&mut cfg, Some((4.0, 8 * 1024))).unwrap();
        // Cap was 1.0 cpus / 2048 MB (4 cpus / 8 GB over 4 runners, no floors hit).
        assert_eq!(applied, (1.0, 2 * 1024));
        // User config (below the cap) survives untouched.
        assert_eq!(cfg.limits.cpus, 0.5);
        assert_eq!(cfg.limits.memory_mb, 512);
    }

    #[test]
    fn apply_per_runner_caps_init_no_op_when_daemon_unknown() {
        // Without daemon capacity, leave the config alone and report None.
        let mut cfg = cfg_with_count(4, 4.0, 8 * 1024);
        assert!(apply_per_runner_caps(&mut cfg, None).is_none());
        assert_eq!(cfg.limits.cpus, 4.0);
        assert_eq!(cfg.limits.memory_mb, 8 * 1024);
    }
}
