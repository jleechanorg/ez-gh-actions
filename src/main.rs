use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};
use std::time::{Duration, Instant};

mod backend;
mod config;
mod docker_backend;
mod github;
mod platform;
mod service;
mod watchdog;

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
            // the host; size limits to the environment containers run in,
            // divided by count so aggregate reservation does not silently
            // over-commit (bugs gdy + vmz — count=16 on a 4-CPU/12-GB daemon
            // would have reserved 32 CPU + 95 GB).
            if let Some((ncpu, daemon_mem)) = docker_backend::daemon_capacity() {
                let n_f = (*count as f64).max(1.0);
                let n_u = (*count as u64).max(1);
                // Per-runner share of the daemon, floored at the validate()
                // minimums in config.rs (cpus >= 0.5, memory_mb >= 512). If
                // even the floor would over-aggregate (count * 0.5 > ncpu),
                // bail — running would over-commit regardless of cfg.limits.
                let cpu_share = (ncpu / n_f).max(0.5);
                let mem_share = (daemon_mem / n_u).max(512);
                if (*count as f64) * cpu_share > ncpu {
                    bail!(
                        "refusing init: count={count} × per-runner floor cpus=0.5 would over-commit \
                         {ncpu} daemon cpus; lower --count to {} or fewer",
                        (ncpu / 0.5) as u32
                    );
                }
                cfg.limits.cpus = cfg.limits.cpus.min(cpu_share);
                cfg.limits.memory_mb = cfg.limits.memory_mb.min(mem_share);
                println!(
                    "docker daemon capacity: {ncpu} cpus, {daemon_mem} MB; \
                     per-runner ceiling at count={count}: {cpu_share:.2} cpus, {mem_share} MB"
                );
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
            // Single-instance guard (bead 6gw): flock serve.lock so a second
            // `ezgha serve` refuses immediately instead of racing next_slot's
            // read-modify-write. Auto-released on process death; opt-out via
            // EZGHA_SKIP_LOCK=1 for tests.
            let _serve_lock = acquire_serve_lock().context("acquire serve.lock")?;
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
            // systemd notify (bead drg): Tell systemd we're ready so Type=notify
            // stops blocking the start. No-op when NOTIFY_SOCKET is unset (macOS
            // launchd path / interactive `ezgha serve`).
            let _ = sd_notify::notify(true, &[sd_notify::NotifyState::Ready]);
            loop {
                // Ping BEFORE ensure_count: batch JIT+docker spawn can exceed
                // WatchdogSec=300; a post-work-only ping lets systemd SIGABRT mid-spawn.
                watchdog::ping();
                match docker_backend::ensure_count(&cfg, backend) {
                    Ok(started) => {
                        for name in started {
                            println!("respawned ephemeral runner {name}");
                        }
                    }
                    Err(e) => eprintln!("ensure_count failed (will retry): {e:#}"),
                }
                watchdog::ping();
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

/// Acquire an advisory `flock(2)` on `<config_dir>/ezgha/serve.lock` to
/// prevent two `ezgha serve` instances from racing on the slot file. The
/// helper returns a `ServeLock` guard whose `Drop` releases the lock;
/// release also happens automatically when the process dies. Tests opt
/// out with `EZGHA_SKIP_LOCK=1`.
struct ServeLock(Option<std::fs::File>);

impl Drop for ServeLock {
    fn drop(&mut self) {
        if let Some(f) = self.0.take() {
            // Lock release on fd close is automatic; nothing to do here.
            let _ = f;
        }
    }
}

fn acquire_serve_lock() -> Result<ServeLock> {
    if std::env::var_os("EZGHA_SKIP_LOCK").is_some() {
        return Ok(ServeLock(None));
    }
    use std::io::ErrorKind;
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::OpenOptionsExt;
    let home = std::env::var("HOME").unwrap_or_else(|_| "~".into());
    let config_home =
        std::env::var("XDG_CONFIG_HOME").unwrap_or_else(|_| format!("{home}/.config"));
    let path = std::path::PathBuf::from(config_home)
        .join("ezgha")
        .join("serve.lock");
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).with_context(|| format!("create {}", parent.display()))?;
    }
    let f = std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(false)
        .mode(0o644)
        .open(&path)
        .with_context(|| format!("open {}", path.display()))?;
    // flock(LOCK_EX | LOCK_NB): non-blocking exclusive. Refused if another
    // instance holds it. Auto-released on fd close (process death).
    // NOTE: std::fs::File::lock_exclusive() is not yet stable on this
    // toolchain; `libc::flock` is the portable escape hatch and adds zero
    // new transitive crates because libc is already in the dep tree.
    let fd = f.as_raw_fd();
    let op = libc::LOCK_EX | libc::LOCK_NB;
    let rc = unsafe { libc::flock(fd, op) };
    if rc != 0 {
        let e = std::io::Error::last_os_error();
        match e.kind() {
            ErrorKind::WouldBlock => bail!(
                "another ezgha serve is running (lock held at {}); \
                 refusing to start. Set EZGHA_SKIP_LOCK=1 to bypass (tests only).",
                path.display()
            ),
            _ => return Err(e.into()),
        }
    }
    Ok(ServeLock(Some(f)))
}
