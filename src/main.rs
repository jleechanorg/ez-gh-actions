use anyhow::{bail, Result};
use clap::{Parser, Subcommand};
use std::time::{Duration, Instant};

mod backend;
mod config;
mod docker_backend;
mod github;
mod platform;
mod service;

use backend::Selection;
use config::{Config, Scope};

#[derive(Parser)]
#[command(
    name = "ezgha",
    version = concat!(env!("CARGO_PKG_VERSION"), "-", env!("GIT_SHA")),
    about = "Easy isolated self-hosted GitHub Actions runners (VM-preferred, container fallback with hard limits)"
)]
struct Cli {
    /// Path to config file (default: XDG config dir)
    #[arg(long, global = true)]
    config: Option<std::path::PathBuf>,

    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Detect this machine and write a starter config
    Init {
        /// Target: "owner/repo" (repo scope) or "org" (org scope)
        #[arg(long)]
        target: String,
        /// Scope: repo or org
        #[arg(long, default_value = "repo")]
        scope: String,
        /// How many concurrent ephemeral runners to maintain
        #[arg(long, default_value_t = 1)]
        count: u32,
    },
    /// Check prerequisites and show what backend would be used
    Doctor,
    /// Start ephemeral runner(s) now (one job each, then exit)
    Start {
        /// Override configured runner count
        #[arg(long)]
        count: Option<u32>,
    },
    /// Supervise: keep the configured number of ephemeral runners available
    Serve,
    /// Stop all managed runners and deregister idle ones
    Stop,
    /// Show managed containers and registered runners
    Status,
    /// Install as a user service (systemd --user / launchd)
    InstallService,
}

fn config_path(cli: &Cli) -> Result<std::path::PathBuf> {
    match &cli.config {
        Some(p) => Ok(p.clone()),
        None => Config::default_path(),
    }
}

fn choose_backend(cfg: &config::Config) -> Result<backend::Backend> {
    let plat = platform::detect();
    match backend::select(&plat, cfg.policy.minimum_isolation) {
        Selection::Chosen {
            backend,
            skipped_stronger,
        } => {
            for s in skipped_stronger {
                eprintln!(
                    "note: {} offers stronger isolation but is not driven by ezgha yet; using {}",
                    s.name(),
                    backend.name()
                );
            }
            Ok(backend)
        }
        Selection::PolicyBlocked {
            best_available,
            required,
        } => bail!(
            "policy requires {} isolation but best available backend is {} — refusing to start (fail closed). \
             Lower policy.minimum_isolation or provision a VM backend.",
            required,
            best_available.name()
        ),
        Selection::None => {
            // Improved diagnostic (bead jyy): probe docker directly so the
            // operator gets an actionable error instead of a generic message.
            let docker_reachable = std::process::Command::new("docker")
                .args(["info", "--format", "{{.ServerVersion}}"])
                .output()
                .map(|o| o.status.success())
                .unwrap_or(false);
            if docker_reachable {
                bail!(
                    "no usable backend found — docker is reachable but no suitable backend was selected \
                     (check policy.minimum_isolation in config). Run `ezgha doctor` for details."
                );
            } else {
                bail!(
                    "no usable backend found — docker daemon is not reachable. \
                     If using Lima/Colima, ensure the VM is running: `limactl list` / `colima status`. \
                     Run `ezgha doctor` for the full diagnostic."
                );
            }
        }
    }
}

/// Like `choose_backend`, but retries for up to `timeout` when no backend is
/// found (Selection::None). This handles the boot-time race where the Lima VM
/// is still starting when ezgha.service begins (even with After=lima-vm@colima
/// the socket may not be ready immediately). PolicyBlocked errors are permanent
/// and are returned immediately without retrying.
///
/// Bead: ez-gh-actions-3z5
fn wait_for_backend(cfg: &config::Config, timeout: Duration) -> Result<backend::Backend> {
    let deadline = Instant::now() + timeout;
    let retry_interval = Duration::from_secs(5);
    loop {
        let plat = platform::detect();
        match backend::select(&plat, cfg.policy.minimum_isolation) {
            Selection::Chosen {
                backend,
                skipped_stronger,
            } => {
                for s in skipped_stronger {
                    eprintln!(
                        "note: {} offers stronger isolation but is not driven by ezgha yet; using {}",
                        s.name(),
                        backend.name()
                    );
                }
                return Ok(backend);
            }
            Selection::PolicyBlocked {
                best_available,
                required,
            } => bail!(
                "policy requires {} isolation but best available backend is {} — refusing to start (fail closed). \
                 Lower policy.minimum_isolation or provision a VM backend.",
                required,
                best_available.name()
            ),
            Selection::None => {
                let remaining = deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    // Exhausted budget — surface the same rich diagnostic as choose_backend.
                    return choose_backend(cfg);
                }
                let wait = retry_interval.min(remaining);
                eprintln!(
                    "no usable backend yet — docker daemon not reachable, retrying in {}s \
                     ({}s remaining before giving up)",
                    wait.as_secs(),
                    remaining.as_secs()
                );
                std::thread::sleep(wait);
            }
        }
    }
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let path = config_path(&cli)?;

    match &cli.command {
        Commands::Init {
            target,
            scope,
            count,
        } => {
            let scope = match scope.as_str() {
                "repo" => Scope::Repo,
                "org" => Scope::Org,
                other => bail!("invalid scope '{other}' (expected: repo, org)"),
            };
            if scope == Scope::Repo && !target.contains('/') {
                bail!("repo scope target must be owner/repo, got '{target}'");
            }
            let plat = platform::detect();
            let mut cfg = Config::defaults_for(&plat, target.clone(), scope);
            cfg.runner.count = *count;
            // The docker daemon may be a VM (Colima/Lima/Desktop) smaller than
            // the host; size limits to the environment containers run in.
            if let Some((ncpu, daemon_mem)) = docker_backend::daemon_capacity() {
                cfg.limits.cpus = cfg.limits.cpus.min((ncpu / 2.0).max(1.0));
                cfg.limits.memory_mb = cfg.limits.memory_mb.min((daemon_mem / 2).max(1024));
                println!("docker daemon capacity: {ncpu} cpus, {daemon_mem} MB");
            }
            cfg.save(&path)?;
            println!("wrote {}", path.display());
            println!(
                "host: {} {} | {} MB RAM, {} cpus",
                plat.os, plat.arch, plat.total_mem_mb, plat.cpus
            );
            println!(
                "limits per runner: {} MB RAM, {} cpus, {} pids",
                cfg.limits.memory_mb, cfg.limits.cpus, cfg.limits.pids
            );
            match backend::select(&plat, cfg.policy.minimum_isolation) {
                Selection::Chosen { backend, .. } => println!("backend: {}", backend.name()),
                _ => println!("backend: NONE USABLE — run `ezgha doctor`"),
            }
        }
        Commands::Doctor => {
            let plat = platform::detect();
            println!("os: {} ({})", plat.os, plat.arch);
            println!("ram: {} MB | cpus: {}", plat.total_mem_mb, plat.cpus);
            println!("docker daemon: {}", ok(plat.docker_ok));
            println!(
                "daemon in VM: {} {}",
                ok(plat.daemon_in_vm),
                if plat.daemon_in_vm {
                    "(containers are VM-contained; satisfies minimum_isolation=\"vm\")"
                } else {
                    "(bare-metal daemon; docker backend counts as container isolation)"
                }
            );
            println!("sysbox runtime: {}", ok(plat.sysbox_runtime));
            println!("kvm usable: {}", ok(plat.kvm_usable));
            println!("virsh: {}", ok(plat.has_virsh));
            println!("tart: {}", ok(plat.has_tart));
            println!("gh auth: {}", ok(github::gh_auth_ok()));
            let cands = backend::candidates(&plat);
            if cands.is_empty() {
                println!("backends: none usable");
            } else {
                println!("backends (strongest first):");
                for c in cands {
                    println!(
                        "  - {}{}",
                        c.name(),
                        if c.implemented() {
                            ""
                        } else {
                            "  [detected; not driven by ezgha yet]"
                        }
                    );
                }
            }
            if let Ok(cfg) = Config::load(&path) {
                println!(
                    "config: {} (target {}, count {})",
                    path.display(),
                    cfg.github.target,
                    cfg.runner.count
                );
            } else {
                println!("config: none — run `ezgha init --target owner/repo`");
            }
        }
        Commands::Start { count } => {
            let mut cfg = Config::load(&path)?;
            if let Some(c) = count {
                cfg.runner.count = *c;
            }
            let backend = choose_backend(&cfg)?;
            let started = docker_backend::ensure_count(&cfg, backend)?;
            if started.is_empty() {
                println!("already at capacity ({} runners)", cfg.runner.count);
            }
            for name in started {
                println!("started ephemeral runner {name} [{}]", backend.name());
            }
        }
        Commands::Serve => {
            let cfg = Config::load(&path)?;
            // Use wait_for_backend (bead 3z5): retry up to 120s for the Docker
            // daemon to become reachable. This handles the boot-time race where
            // Lima/Colima is still starting when this service unit fires — even
            // with After=lima-vm@colima.service the Docker socket may not be
            // ready for a few seconds after limactl start exits.
            let backend = wait_for_backend(&cfg, Duration::from_secs(120))?;
            println!(
                "supervising {} ephemeral runner(s) for {} on {}",
                cfg.runner.count,
                cfg.github.target,
                backend.name()
            );
            loop {
                match docker_backend::ensure_count(&cfg, backend) {
                    Ok(started) => {
                        for name in started {
                            println!("respawned ephemeral runner {name}");
                        }
                    }
                    Err(e) => eprintln!("ensure_count failed (will retry): {e:#}"),
                }
                std::thread::sleep(std::time::Duration::from_secs(30));
            }
        }
        Commands::Stop => {
            let cfg = Config::load(&path)?;
            let n = docker_backend::stop_all(&cfg)?;
            println!("removed {n} managed container(s); deregistered idle ezgha runners");
        }
        Commands::Status => {
            let cfg = Config::load(&path)?;
            let containers = docker_backend::managed_containers()?;
            println!("managed containers: {}", containers.len());
            for c in &containers {
                println!("  {} {} ({}, up {})", c.id, c.name, c.state, c.running_for);
            }
            match github::list_runners(&cfg.github) {
                Ok(runners) => {
                    let ours: Vec<_> = runners
                        .iter()
                        .filter(|r| r.name.starts_with(&cfg.runner.name_prefix))
                        .collect();
                    println!(
                        "registered ezgha runners on {}: {}",
                        cfg.github.target,
                        ours.len()
                    );
                    for r in ours {
                        println!("  #{} {} status={} busy={}", r.id, r.name, r.status, r.busy);
                    }
                }
                Err(e) => eprintln!("could not list registered runners: {e:#}"),
            }
        }
        Commands::InstallService => {
            // Validate config exists before installing a service that needs it.
            Config::load(&path)?;
            service::install()?;
        }
    }
    Ok(())
}

fn ok(b: bool) -> &'static str {
    if b {
        "ok"
    } else {
        "missing"
    }
}
