use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand, ValueEnum};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

mod alert;
mod backend;
mod canary;
mod config;
mod docker_backend;
mod github;
mod platform;
mod queue_monitor;
mod reaper;
mod service;
mod watchdog;

use alert::Severity;
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
    /// Send a test alert to the configured alert channel(s)
    TestAlert {
        /// Event key used for cooldown tracking
        #[arg(long, default_value = "operator.test")]
        event_key: String,
    },
    /// Dispatch one nonce-tracked canary workflow and verify the exact run/job/runner.
    CanaryOnce {
        /// Override [canary].poll_timeout_seconds for this one-shot proof
        #[arg(long)]
        timeout_seconds: Option<u64>,
        /// Do not send configured alerts even if the canary breaches SLO
        #[arg(long)]
        no_alert: bool,
        /// Override generated nonce, useful for deterministic manual tests
        #[arg(long)]
        nonce: Option<String>,
    },
    /// Dry-run zombie reaper planning. Prints cancel-then-delete candidates; does not mutate GitHub.
    ReaperPlan {
        /// Repository to inspect as owner/repo. Can be repeated; defaults to configured canary/queue repos.
        #[arg(long = "repo")]
        repos: Vec<String>,
        /// Additional retired runner name prefix allowed for planning.
        #[arg(long = "retired-prefix")]
        retired_prefixes: Vec<String>,
        /// Minimum in-progress job age before a runner can be planned for reaping.
        #[arg(long, default_value_t = 60)]
        min_age_minutes: u64,
    },
    /// Internal systemd failure hook installed by `install-service`
    #[command(hide = true)]
    SystemdAlertHook {
        #[arg(long, value_enum)]
        source: SystemdAlertSource,
        #[arg(long)]
        unit: String,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
enum SystemdAlertSource {
    ExecStopPost,
    OnFailure,
}

struct SystemdAlertEvent {
    event_key: &'static str,
    severity: Severity,
    subject: String,
    body: String,
}

fn config_path(cli: &Cli) -> Result<std::path::PathBuf> {
    match &cli.config {
        Some(p) => Ok(p.clone()),
        None => Config::default_path(),
    }
}

fn mark_service_ready_and_start_watchdog() -> watchdog::Heartbeat {
    let heartbeat = watchdog::start_background();
    // systemd notify (bead drg): Tell systemd we're ready so Type=notify
    // stops blocking the start. No-op when NOTIFY_SOCKET is unset (macOS
    // launchd path / interactive `ezgha serve`).
    let _ = sd_notify::notify(false, &[sd_notify::NotifyState::Ready]);
    heartbeat
}

fn log_skipped_stronger_backends(skipped_stronger: &[backend::Backend], backend: backend::Backend) {
    for s in skipped_stronger {
        eprintln!(
            "note: {} offers stronger isolation but is not driven by ezgha yet; using {}",
            s.name(),
            backend.name()
        );
    }
}

fn docker_reachable() -> bool {
    std::process::Command::new("docker")
        .args(["info", "--format", "{{.ServerVersion}}"])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

fn choose_backend(cfg: &config::Config) -> Result<backend::Backend> {
    let plat = platform::detect();
    match backend::select(&plat, cfg.policy.minimum_isolation) {
        Selection::Chosen {
            backend,
            skipped_stronger,
        } => {
            log_skipped_stronger_backends(&skipped_stronger, backend);
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
            if docker_reachable() {
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
    let mut recovery = BackendRecoveryState::new();
    loop {
        let plat = platform::detect();
        match backend::select(&plat, cfg.policy.minimum_isolation) {
            Selection::Chosen {
                backend,
                skipped_stronger,
            } => {
                log_skipped_stronger_backends(&skipped_stronger, backend);
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
                let docker_reachable = docker_reachable();
                let remaining = deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    // Exhausted budget — surface the same rich diagnostic as choose_backend.
                    return choose_backend(cfg);
                }
                if maybe_restart_backend(cfg, &mut recovery) {
                    eprintln!(
                        "backend restart attempted while waiting for service readiness; retrying quickly"
                    );
                    std::thread::sleep(Duration::from_secs(1));
                    continue;
                }
                let wait = retry_interval.min(remaining);
                eprintln!(
                    "no usable backend yet — docker daemon {}{}, retrying in {}s \
                     ({}s remaining before giving up)",
                    if docker_reachable { "reachable" } else { "not reachable" },
                    if docker_reachable { " but no usable backend was selected" } else { "" },
                    wait.as_secs(),
                    remaining.as_secs()
                );
                std::thread::sleep(wait);
            }
        }
    }
}

const BACKEND_RESTART_COOLDOWN: Duration = Duration::from_secs(60);
const BACKEND_RESTART_WINDOW: Duration = Duration::from_secs(600);
const BACKEND_RESTART_MAX_ATTEMPTS: u32 = 3;
const BACKEND_RESTART_COMMAND_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Debug)]
struct BackendRecoveryState {
    window_started: Instant,
    attempts_in_window: u32,
    last_restart_at: Option<Instant>,
}

impl BackendRecoveryState {
    fn new() -> Self {
        let now = Instant::now();
        Self {
            window_started: now,
            attempts_in_window: 0,
            last_restart_at: None,
        }
    }

    fn allow_restart(&mut self, cfg: &config::Config) -> bool {
        let now = Instant::now();
        if now.duration_since(self.window_started) > BACKEND_RESTART_WINDOW {
            self.window_started = now;
            self.attempts_in_window = 0;
        }

        if let Some(last) = self.last_restart_at {
            if now.duration_since(last) < BACKEND_RESTART_COOLDOWN {
                let subject = "Backend restart suppressed: cooldown window active";
                let body = format!(
                    "saw too-frequent backend restart attempts for {} ({} since last); backing off",
                    cfg.github.target,
                    now.duration_since(last).as_secs()
                );
                if let Err(err) = alert::notify(
                    cfg,
                    "serve.backend.restart.suppressed.cooldown",
                    Severity::Warning,
                    subject,
                    &body,
                ) {
                    eprintln!("WARN: alert send error: {err:#}");
                }
                eprintln!(
                    "backend restart suppressed: cooldown window active ({:?} since last)",
                    now.duration_since(last)
                );
                return false;
            }
        }

        if self.attempts_in_window >= BACKEND_RESTART_MAX_ATTEMPTS {
            let subject = "Backend restart suppressed: rate limit hit";
            let body = format!(
                "saw {} restart attempts in last {:?} for {}; suppressing to avoid start-limit",
                self.attempts_in_window, BACKEND_RESTART_WINDOW, cfg.github.target
            );
            if let Err(err) = alert::notify(
                cfg,
                "serve.backend.restart.suppressed.limit",
                Severity::Critical,
                subject,
                &body,
            ) {
                eprintln!("WARN: alert send error: {err:#}");
            }
            eprintln!(
                "backend restart suppressed: {} attempts in last {:?} reached cap {}",
                self.attempts_in_window, BACKEND_RESTART_WINDOW, BACKEND_RESTART_MAX_ATTEMPTS
            );
            return false;
        }

        self.attempts_in_window += 1;
        self.last_restart_at = Some(now);
        true
    }
}

fn run_restart_command_with_timeout(cmd: &str, args: &[&str], timeout: Duration) -> Result<bool> {
    let mut child = Command::new(cmd)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .with_context(|| format!("failed to execute {cmd}"))?;
    let start = Instant::now();
    loop {
        if let Some(status) = child
            .try_wait()
            .with_context(|| format!("failed to poll {cmd}"))?
        {
            return Ok(status.success());
        }
        if start.elapsed() >= timeout {
            let _ = child.kill();
            let _ = child.wait();
            bail!(
                "{cmd} restart command timed out after {}s",
                timeout.as_secs()
            );
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn run_restart_command(cmd: &str, args: &[&str]) -> Result<bool> {
    run_restart_command_with_timeout(cmd, args, BACKEND_RESTART_COMMAND_TIMEOUT)
}

fn attempt_backend_restart() -> Result<bool> {
    // Keep host bootstrap logic portable: prefer the project-local tooling (`colima`),
    // then the underlying VM launcher (`limactl`), then systemd's native unit.
    let attempts = [
        ("colima", ["start"].as_ref()),
        ("limactl", ["start", "colima"].as_ref()),
        (
            "systemctl",
            ["--user", "start", "lima-vm@colima.service"].as_ref(),
        ),
    ];
    for (cmd, args) in attempts {
        match run_restart_command(cmd, args) {
            Ok(true) => return Ok(true),
            Ok(false) => {
                eprintln!("{cmd} exists but restart returned non-zero ({:?})", args);
            }
            Err(err) => {
                if let Some(io) = err.downcast_ref::<std::io::Error>() {
                    if io.kind() == std::io::ErrorKind::NotFound {
                        continue;
                    }
                }
                eprintln!("{cmd} restart command failed: {err:#}");
            }
        }
    }
    Ok(false)
}

fn backend_restart_can_help(selection: &Selection) -> bool {
    matches!(
        selection,
        Selection::None
            | Selection::Chosen {
                backend: backend::Backend::Docker | backend::Backend::DockerSysbox,
                ..
            }
    )
}

fn maybe_restart_backend(cfg: &config::Config, recovery: &mut BackendRecoveryState) -> bool {
    let selection = backend::select(&platform::detect(), cfg.policy.minimum_isolation);
    if !backend_restart_can_help(&selection) {
        return false;
    }
    if matches!(selection, Selection::None) && docker_reachable() {
        eprintln!(
            "backend selection is NONE but docker is reachable; skipping restart to avoid unnecessary churn"
        );
        return false;
    }
    if !recovery.allow_restart(cfg) {
        return false;
    }
    match attempt_backend_restart() {
        Ok(true) => {
            let subject = "Backend restart attempted";
            let body = format!(
                "attempted backend runtime restart for {} after backend selection/reachability failure",
                cfg.github.target
            );
            if let Err(err) = alert::notify(
                cfg,
                "serve.backend.restart.attempted",
                Severity::Info,
                subject,
                &body,
            ) {
                eprintln!("WARN: alert send error: {err:#}");
            }
            eprintln!("restarted backend runtime and will retry quickly");
            true
        }
        Ok(false) => {
            eprintln!("backend restart command paths were unavailable or returned non-zero");
            false
        }
        Err(err) => {
            eprintln!("backend restart command failed: {err:#}");
            false
        }
    }
}

fn notify_ensure_failure(
    cfg: &config::Config,
    backend: backend::Backend,
    ensure_fail_streak: u32,
    detail: &str,
) {
    if ensure_fail_streak < cfg.alert.failure_alert_threshold {
        return;
    }
    let subject = "Runner pool ensure_count failures";
    let body = format!(
        "ensure_count failed {} consecutive time(s) for target {} on {}. Last detail: {detail}",
        ensure_fail_streak,
        cfg.github.target,
        backend.name()
    );
    let severity = if ensure_fail_streak >= cfg.alert.failure_alert_threshold * 2 {
        Severity::Critical
    } else {
        Severity::Warning
    };
    if let Err(err) = alert::notify(cfg, "serve.ensure_count.failure", severity, subject, &body) {
        eprintln!("WARN: alert send error: {err:#}");
    }
}

fn apply_ensure_outcome_to_failure_streak(
    cfg: &config::Config,
    backend: backend::Backend,
    ensure_fail_streak: &mut u32,
    outcome: &docker_backend::EnsureCountOutcome,
) -> bool {
    let partial_failure = outcome.is_partial_failure();
    if partial_failure {
        *ensure_fail_streak += 1;
        let detail = format!(
            "partial success: started {} of {} missing runner(s)",
            outcome.started.len(),
            outcome.missing
        );
        notify_ensure_failure(cfg, backend, *ensure_fail_streak, &detail);
    } else {
        *ensure_fail_streak = 0;
    }
    partial_failure
}

fn systemd_alert_decision(
    source: SystemdAlertSource,
    unit: &str,
    service_result: Option<&str>,
    exit_code: Option<&str>,
    exit_status: Option<&str>,
) -> Option<SystemdAlertEvent> {
    let result = service_result.unwrap_or("");
    let subject = match source {
        SystemdAlertSource::ExecStopPost if result == "watchdog" => "ezgha service watchdog kill",
        SystemdAlertSource::OnFailure if result == "start-limit-hit" => {
            "ezgha service start-limit hit"
        }
        _ => return None,
    };
    Some(SystemdAlertEvent {
        event_key: match source {
            SystemdAlertSource::ExecStopPost => "service.watchdog_kill",
            SystemdAlertSource::OnFailure => "service.start_limit_hit",
        },
        severity: Severity::Critical,
        subject: subject.to_string(),
        body: format!(
            "systemd reported unit={unit} source={source:?} SERVICE_RESULT={result} EXIT_CODE={} EXIT_STATUS={}",
            exit_code.unwrap_or(""),
            exit_status.unwrap_or("")
        ),
    })
}

fn systemctl_unit_result(unit: &str) -> Option<String> {
    let out = Command::new("systemctl")
        .args(["--user", "show", unit, "-p", "Result", "--value"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let value = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if value.is_empty() {
        None
    } else {
        Some(value)
    }
}

fn run_systemd_alert_hook(
    cfg: &config::Config,
    source: SystemdAlertSource,
    unit: &str,
) -> Result<()> {
    let result = match source {
        SystemdAlertSource::ExecStopPost => std::env::var("SERVICE_RESULT").ok(),
        SystemdAlertSource::OnFailure => std::env::var("MONITOR_SERVICE_RESULT")
            .ok()
            .or_else(|| systemctl_unit_result(unit)),
    };
    let exit_code = match source {
        SystemdAlertSource::ExecStopPost => std::env::var("EXIT_CODE").ok(),
        SystemdAlertSource::OnFailure => std::env::var("MONITOR_EXIT_CODE").ok(),
    };
    let exit_status = match source {
        SystemdAlertSource::ExecStopPost => std::env::var("EXIT_STATUS").ok(),
        SystemdAlertSource::OnFailure => std::env::var("MONITOR_EXIT_STATUS").ok(),
    };

    if let Some(event) = systemd_alert_decision(
        source,
        unit,
        result.as_deref(),
        exit_code.as_deref(),
        exit_status.as_deref(),
    ) {
        alert::notify(
            cfg,
            event.event_key,
            event.severity,
            &event.subject,
            &event.body,
        )?;
        println!("{}", event.subject);
    }
    Ok(())
}

fn run_test_alert(cfg: &config::Config, event_key: &str) -> Result<()> {
    if !alert::configured_channels(&cfg.alert) {
        bail!("no alert channels configured; set alert.log_path, alert.slack_webhook_url, or alert.email_to");
    }
    let delivered = alert::notify_delivery(
        cfg,
        event_key,
        Severity::Info,
        "ezgha test alert",
        "operator-requested test alert delivery proof",
    )?;
    if !delivered {
        bail!(
            "test alert was not delivered; event may be in cooldown or every configured transport failed"
        );
    }
    println!("test alert delivered for event_key={event_key}");
    Ok(())
}

fn run_tick<T>(label: &str, run: impl FnOnce() -> Result<Option<T>>) -> bool {
    match run() {
        Ok(_) => true,
        Err(err) => {
            eprintln!("WARN: {label} failed: {err:#}");
            false
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
                // Record the auto-detected VM/daemon ceiling explicitly so the
                // startup memory-budget guard (bead yz6b) has a known ground truth.
                cfg.runner.vm_total_mb = Some(daemon_mem);
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
                match docker_backend::preview_memory_budget(&cfg) {
                    docker_backend::MemoryBudgetPreview::Pass(b) => println!(
                        "memory budget check (preview): would PASS on next restart — \
                         vm_total_mb={} guest_reserve_mb={} fleet_budget_mb={} runner_count={} \
                         per_runner_budget_mb={} runner_floor_mb={}",
                        b.vm_total_mb,
                        b.guest_reserve_mb,
                        b.fleet_budget_mb,
                        b.runner_count,
                        b.per_runner_budget_mb,
                        b.runner_floor_mb,
                    ),
                    docker_backend::MemoryBudgetPreview::Fail(msg) => println!(
                        "memory budget check (preview): would FAIL on next restart with current \
                         config — {msg}"
                    ),
                    docker_backend::MemoryBudgetPreview::Unknown => println!(
                        "memory budget check (preview): unknown — cannot determine VM/daemon \
                         memory ceiling (set runner.vm_total_mb explicitly; check `colima status` \
                         / `limactl list`)"
                    ),
                }
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
            let _serve_lock = acquire_serve_lock(&cfg).context("acquire serve.lock")?;
            // Use wait_for_backend (bead 3z5): retry up to 120s for the Docker
            // daemon to become reachable. This handles the boot-time race where
            // Lima/Colima is still starting when this service unit fires — even
            // with After=lima-vm@colima.service the Docker socket may not be
            // ready for a few seconds after limactl start exits.
            let backend = wait_for_backend(&cfg, Duration::from_secs(120))?;
            // VM-aware memory budget derivation + fail-loud guard (bead
            // ez-gh-actions-yz6b). See docker_backend::resolve_and_log_memory_budget.
            docker_backend::resolve_and_log_memory_budget(&cfg)
                .context("memory budget check failed at startup")?;
            println!(
                "supervising {} ephemeral runner(s) for {} on {}",
                cfg.runner.count,
                cfg.github.target,
                backend.name()
            );
            let _watchdog_heartbeat = mark_service_ready_and_start_watchdog();
            let mut backend_recovery = BackendRecoveryState::new();
            let mut queue_monitor = queue_monitor::QueueMonitorState::new();
            let mut invariant_sampler = queue_monitor::InvariantSamplerState::new();
            let mut canary_scheduler = canary::CanaryDaemonState::new();
            let mut ensure_fail_streak = 0u32;
            let mut deadman = alert::DeadManState::new(Instant::now());
            loop {
                // Ping BEFORE ensure_count: batch JIT+docker spawn can exceed
                // WatchdogSec=300; a post-work-only ping lets systemd SIGABRT mid-spawn.
                watchdog::ping();
                let (sleep, ensure_succeeded) = match docker_backend::ensure_count_outcome(
                    &cfg, backend,
                ) {
                    Ok(outcome) => {
                        apply_ensure_outcome_to_failure_streak(
                            &cfg,
                            backend,
                            &mut ensure_fail_streak,
                            &outcome,
                        );
                        for name in outcome.started {
                            println!("respawned ephemeral runner {name}");
                        }
                        // A successful ensure_count is itself a "pipeline is
                        // alive" signal — a healthy fleet should not need to
                        // fire alerts to prove liveness. Bump the dead-man
                        // clock so the threshold counts overall daemon
                        // liveness, not just alert throughput.
                        deadman.record_delivery(Instant::now());
                        // Respawn cadence: configurable via [runner]
                        // serve_tick_seconds (default 30, 5s floor) — a
                        // finished short job leaves its slot dead for up to
                        // one tick + container startup, so hosts chasing
                        // duty cycle can lower this (2026-07-09 coordination
                        // with jeff-ubuntu's 60->20 change).
                        (cfg.runner.serve_tick(), true)
                    }
                    Err(e) => {
                        ensure_fail_streak += 1;
                        eprintln!("ensure_count failed (will retry): {e:#}");
                        notify_ensure_failure(&cfg, backend, ensure_fail_streak, &format!("{e:#}"));
                        if maybe_restart_backend(&cfg, &mut backend_recovery) {
                            let subject = "Backend restart attempted after ensure_count failures";
                            let body = format!(
                                "serve loop attempted backend restart after {} failures for {} on {}",
                                ensure_fail_streak,
                                cfg.github.target,
                                backend.name()
                            );
                            if let Err(err) = alert::notify(
                                &cfg,
                                "serve.backend.restart.attempted",
                                Severity::Info,
                                subject,
                                &body,
                            ) {
                                eprintln!("WARN: alert send error: {err:#}");
                            }
                            (Duration::from_secs(8), false)
                        } else {
                            // Failure retry uses the same configured cadence
                            // as success — the existing 8s fast-path above
                            // already covers the post-backend-restart case.
                            (cfg.runner.serve_tick(), false)
                        }
                    }
                };
                if ensure_succeeded {
                    watchdog::ping();
                    // Fresh budget base for monitor ticks: respawn pacing may
                    // legitimately spend minutes before this point, and that
                    // time must not count against SERVE_LOOP_TIME_BUDGET.
                    let monitor_loop_start = Instant::now();
                    // Drive both ticks through the unified fetch dedup path
                    // (see `QueueMonitorState::drive_serve_loop_ticks`):
                    // the queue monitor's starvation/idle-mismatch alerting
                    // and the invariant sampler's INV-1/INV-2 sampling share
                    // one fleet fetch and one fetch per distinct repo per
                    // iteration, instead of doubling both. Calling
                    // `maybe_check` + `maybe_sample` independently (the
                    // previous shape) is preserved as a public API but the
                    // serve loop no longer uses it.
                    let _ = run_tick("queue monitor + invariant sampler drive", || {
                        queue_monitor
                            .drive_serve_loop_ticks(
                                &cfg,
                                monitor_loop_start,
                                &mut invariant_sampler,
                            )
                            .map(|_results| None::<()>)
                    });
                    watchdog::ping();
                    let _ = canary_scheduler.maybe_check(&cfg);
                }
                watchdog::ping();
                // Dead-man's switch: prove the alert pipeline is alive.
                // Runs once per serve-loop tick regardless of ensure success
                // — even a stuck ensure_count loop should still emit alerts.
                let _ = run_tick("deadman alert self-test", || {
                    Ok(Some(deadman.check(&cfg, Instant::now())))
                });
                std::thread::sleep(sleep);
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
            service::install(&path)?;
        }
        Commands::TestAlert { event_key } => {
            let cfg = Config::load(&path)?;
            run_test_alert(&cfg, event_key)?;
        }
        Commands::CanaryOnce {
            timeout_seconds,
            no_alert,
            nonce,
        } => {
            let cfg = Config::load(&path)?;
            let result = canary::run_once(&cfg, *timeout_seconds, nonce.clone(), !no_alert)?;
            println!("{}", serde_json::to_string_pretty(&result)?);
            if result.status != "completed" {
                bail!("canary did not complete: status={}", result.status);
            }
            if result.runner_name.is_none() {
                bail!("canary completed without a matching configured runner prefix");
            }
            if result.conclusion.as_deref() != Some("success") {
                bail!("canary conclusion was not success: {:?}", result.conclusion);
            }
            if result.slo_breached {
                bail!(
                    "canary breached start SLO: time_to_start={:?}s threshold={}s",
                    result.time_to_start_seconds,
                    result.slo_start_seconds
                );
            }
        }
        Commands::ReaperPlan {
            repos,
            retired_prefixes,
            min_age_minutes,
        } => {
            let cfg = Config::load(&path)?;
            let plans = run_reaper_plan(&cfg, repos, retired_prefixes, *min_age_minutes)?;
            println!("{}", serde_json::to_string_pretty(&plans)?);
        }
        Commands::SystemdAlertHook { source, unit } => {
            let cfg = Config::load(&path)?;
            run_systemd_alert_hook(&cfg, *source, unit)?;
        }
    }
    Ok(())
}

fn run_reaper_plan(
    cfg: &Config,
    repos: &[String],
    retired_prefixes: &[String],
    min_age_minutes: u64,
) -> Result<Vec<reaper::ReaperPlan>> {
    let selected_repos = if repos.is_empty() {
        reaper::default_reaper_repos(cfg)
    } else {
        repos.to_vec()
    };
    if selected_repos.is_empty() {
        bail!("no repos configured for reaper planning; pass --repo owner/repo");
    }
    let mut allowed_prefixes = vec![cfg.runner.name_prefix.clone()];
    allowed_prefixes.extend(retired_prefixes.iter().cloned());
    let runners = github::list_runners(&cfg.github)?;
    let repo_runs = reaper::collect_repo_runs(&selected_repos)?;
    Ok(reaper::plan_reaper_actions(
        &runners,
        &repo_runs,
        &allowed_prefixes,
        &cfg.runner.labels,
        min_age_minutes.saturating_mul(60),
        unix_now_secs(),
    ))
}

fn unix_now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
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
/// helper returns a `ServeLock` guard; dropping the `Option<File>` inside
/// closes the fd and releases the flock automatically (also happens when
/// the process dies). Tests opt out with `EZGHA_SKIP_LOCK=1`.
struct ServeLock(#[allow(dead_code)] Option<std::fs::File>);

fn default_state_dir() -> std::path::PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "~".into());
    let config_home =
        std::env::var("XDG_CONFIG_HOME").unwrap_or_else(|_| format!("{home}/.config"));
    std::path::PathBuf::from(config_home).join("ezgha")
}

fn state_dir_for(cfg: &config::Config) -> std::path::PathBuf {
    cfg.state_dir.clone().unwrap_or_else(default_state_dir)
}

fn acquire_serve_lock(cfg: &config::Config) -> Result<ServeLock> {
    if std::env::var_os("EZGHA_SKIP_LOCK").is_some() {
        return Ok(ServeLock(None));
    }
    use std::io::ErrorKind;
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::OpenOptionsExt;
    let path = state_dir_for(cfg).join("serve.lock");
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn test_config() -> config::Config {
        config::Config::defaults_for(
            &platform::Platform {
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
            },
            "jleechanorg".into(),
            Scope::Org,
        )
    }

    #[test]
    fn state_dir_isolates_serve_locks_between_configs() {
        let base =
            std::env::temp_dir().join(format!("ezgha-serve-lock-isolation-{}", std::process::id()));
        let mut prod = test_config();
        prod.state_dir = Some(base.join("prod"));
        let mut canary = test_config();
        canary.state_dir = Some(base.join("canary"));

        let prod_lock = acquire_serve_lock(&prod).expect("prod lock");
        let canary_lock = acquire_serve_lock(&canary).expect("canary lock");

        assert!(base.join("prod").join("serve.lock").exists());
        assert!(base.join("canary").join("serve.lock").exists());

        drop(canary_lock);
        drop(prod_lock);
        let _ = std::fs::remove_dir_all(base);
    }

    fn unique_temp_dir(name: &str) -> std::path::PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!("ezgha-main-{name}-{nanos}"))
    }

    #[test]
    fn serve_match_arm_counts_partial_ensure_success_as_failure_streak() {
        let mut cfg = test_config();
        cfg.alert.failure_alert_threshold = 99;
        let backend = backend::Backend::Docker;
        let mut ensure_fail_streak = 0;

        let partial = docker_backend::EnsureCountOutcome {
            started: vec!["ez-org-runner-1".into()],
            missing: 4,
        };
        let was_partial = apply_ensure_outcome_to_failure_streak(
            &cfg,
            backend,
            &mut ensure_fail_streak,
            &partial,
        );
        assert!(was_partial);
        assert_eq!(
            ensure_fail_streak, 1,
            "serve loop must keep the alert streak alive when ensure_count returns only a partial refill"
        );

        let recovered = docker_backend::EnsureCountOutcome {
            started: vec!["ez-org-runner-2".into(), "ez-org-runner-3".into()],
            missing: 2,
        };
        let was_partial = apply_ensure_outcome_to_failure_streak(
            &cfg,
            backend,
            &mut ensure_fail_streak,
            &recovered,
        );
        assert!(!was_partial);
        assert_eq!(
            ensure_fail_streak, 0,
            "non-partial ensure_count success resets the serve alert streak"
        );
    }

    #[test]
    fn systemd_exec_stop_post_watchdog_emits_critical_event() {
        let event = systemd_alert_decision(
            SystemdAlertSource::ExecStopPost,
            "ezgha.service",
            Some("watchdog"),
            Some("killed"),
            Some("6"),
        )
        .expect("watchdog result should alert");
        assert_eq!(event.event_key, "service.watchdog_kill");
        assert_eq!(event.severity, Severity::Critical);
        assert!(event.body.contains("SERVICE_RESULT=watchdog"));
    }

    #[test]
    fn systemd_exec_stop_post_success_noops() {
        assert!(systemd_alert_decision(
            SystemdAlertSource::ExecStopPost,
            "ezgha.service",
            Some("success"),
            Some("exited"),
            Some("0"),
        )
        .is_none());
    }

    #[test]
    fn systemd_on_failure_start_limit_emits_critical_event() {
        let event = systemd_alert_decision(
            SystemdAlertSource::OnFailure,
            "ezgha.service",
            Some("start-limit-hit"),
            None,
            None,
        )
        .expect("start-limit-hit should alert");
        assert_eq!(event.event_key, "service.start_limit_hit");
        assert_eq!(event.severity, Severity::Critical);
        assert!(event.subject.contains("start-limit"));
    }

    #[test]
    fn systemd_on_failure_exit_code_noops() {
        assert!(systemd_alert_decision(
            SystemdAlertSource::OnFailure,
            "ezgha.service",
            Some("exit-code"),
            Some("exited"),
            Some("1"),
        )
        .is_none());
    }

    #[test]
    fn backend_restart_is_allowed_when_backend_selection_is_none() {
        assert!(backend_restart_can_help(&Selection::None));
    }

    #[test]
    fn backend_restart_is_not_allowed_for_policy_blocked_selection() {
        assert!(!backend_restart_can_help(&Selection::PolicyBlocked {
            best_available: backend::Backend::Docker,
            required: config::IsolationLevel::Vm,
        }));
    }

    #[test]
    fn restart_command_reports_success() {
        assert!(run_restart_command_with_timeout(
            "/bin/sh",
            &["-c", "exit 0"],
            Duration::from_secs(1)
        )
        .unwrap());
    }

    #[test]
    fn restart_command_reports_nonzero() {
        assert!(!run_restart_command_with_timeout(
            "/bin/sh",
            &["-c", "exit 17"],
            Duration::from_secs(1)
        )
        .unwrap());
    }

    #[test]
    fn restart_command_reports_missing_binary() {
        let err = run_restart_command_with_timeout(
            "definitely-not-an-ezgha-command",
            &[],
            Duration::from_secs(1),
        )
        .unwrap_err();
        assert!(err.to_string().contains("failed to execute"));
    }

    #[test]
    fn restart_command_times_out_and_kills_hung_process() {
        let start = Instant::now();
        let err = run_restart_command_with_timeout(
            "/bin/sh",
            &["-c", "/bin/sleep 2"],
            Duration::from_millis(150),
        )
        .unwrap_err();
        assert!(
            err.to_string().contains("timed out"),
            "unexpected error: {err:#}"
        );
        assert!(
            start.elapsed() < Duration::from_secs(1),
            "timeout should fire promptly, took {:?}",
            start.elapsed()
        );
    }

    #[test]
    fn service_ready_helper_returns_background_watchdog_guard() {
        let heartbeat: watchdog::Heartbeat = mark_service_ready_and_start_watchdog();
        drop(heartbeat);
    }

    #[test]
    fn test_alert_requires_configured_channel() {
        let cfg = test_config();
        let err = run_test_alert(&cfg, "unit.no_channel").unwrap_err();
        assert!(err.to_string().contains("no alert channels configured"));
    }

    #[test]
    fn test_alert_writes_configured_log_channel() {
        alert::clear_alert_state();
        let mut cfg = test_config();
        let dir = unique_temp_dir("alert-test");
        let log = dir.join("alerts.jsonl");
        cfg.alert.log_path = Some(log.clone());

        run_test_alert(&cfg, "unit.alert_test").unwrap();

        let raw = std::fs::read_to_string(&log).unwrap();
        assert!(raw.contains("\"event_key\":\"unit.alert_test\""));
        assert!(raw.contains("\"subject\":\"ezgha test alert\""));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn queue_monitor_tick_errors_are_non_fatal() {
        assert!(!run_tick::<queue_monitor::QueueStats>(
            "queue monitor check",
            || { anyhow::bail!("synthetic queue monitor failure") }
        ));
        assert!(run_tick::<queue_monitor::QueueStats>(
            "queue monitor check",
            || Ok(None)
        ));
    }

    #[test]
    fn invariant_sampler_tick_errors_are_non_fatal_and_write_no_sample() {
        // Mirrors queue_monitor_tick_errors_are_non_fatal: a failed API call
        // (e.g. a GitHub rate limit) must not crash the serve loop, and --
        // critically for E1/E2 -- must not be recorded as a pass or a fail.
        // The `Err` case here never reaches `append_invariant_sample`, so
        // this tick simply contributes no line to invariant_history.jsonl.
        assert!(!run_tick::<queue_monitor::InvariantSample>(
            "invariant sampler tick",
            || {
                anyhow::bail!("synthetic invariant sampler failure (e.g. GitHub API rate limit)")
            }
        ));
        assert!(run_tick::<queue_monitor::InvariantSample>(
            "invariant sampler tick",
            || Ok(None)
        ));
    }
}
