use anyhow::{Context, Result};
use directories::ProjectDirs;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

use crate::platform::Platform;

/// The only config schema version this binary understands. Bump when the
/// on-disk format changes incompatibly; `load()` refuses anything else rather
/// than silently mis-reading fields.
const CURRENT_VERSION: u32 = 1;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Config {
    pub version: u32,
    /// Optional directory for mutable daemon state such as serve.lock and
    /// slot_assignments.toml. Defaults to the standard ezgha config dir.
    #[serde(default)]
    pub state_dir: Option<PathBuf>,
    pub github: GithubConfig,
    pub runner: RunnerConfig,
    pub limits: Limits,
    pub policy: Policy,
    #[serde(default)]
    pub alert: AlertConfig,
    #[serde(default)]
    pub queue_monitor: QueueMonitorConfig,
    #[serde(default)]
    pub canary: CanaryConfig,
    #[serde(default)]
    pub invariant_sampler: InvariantSamplerConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct AlertConfig {
    /// How many consecutive `ensure_count` failures should trigger an alert.
    #[serde(default = "default_failure_alert_threshold")]
    pub failure_alert_threshold: u32,
    /// Re-alert cooldown in seconds for the same event class.
    #[serde(default = "default_alert_cooldown_seconds")]
    pub alert_cooldown_secs: u64,
    /// Optional Slack Incoming Webhook URL.
    pub slack_webhook_url: Option<String>,
    /// Optional email destination; requires `sendmail` in PATH.
    pub email_to: Option<String>,
    /// Optional sender address for `sendmail`.
    pub email_from: Option<String>,
    /// Optional durable local JSONL alert log path.
    pub log_path: Option<PathBuf>,
    /// Dead-man's switch: if no alert has been delivered within this many
    /// seconds, the daemon fires a CRITICAL self-test to prove the alert
    /// pipeline is still alive. Set to 0 to disable.
    #[serde(default = "default_deadman_threshold_seconds")]
    pub deadman_threshold_seconds: u64,
}

impl Default for AlertConfig {
    fn default() -> Self {
        Self {
            failure_alert_threshold: default_failure_alert_threshold(),
            alert_cooldown_secs: default_alert_cooldown_seconds(),
            slack_webhook_url: None,
            email_to: None,
            email_from: None,
            log_path: None,
            deadman_threshold_seconds: default_deadman_threshold_seconds(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct QueueMonitorConfig {
    /// Enable daemon-side queued GitHub Actions run monitoring.
    #[serde(default)]
    pub enabled: bool,
    /// Repository to monitor as `owner/repo`. Defaults to `github.target` for repo-scoped configs.
    pub repo: Option<String>,
    /// Alert when the oldest fresh queued run is older than this many minutes.
    #[serde(default = "default_queue_tail_warn_minutes")]
    pub tail_warn_minutes: u64,
    /// Minimum seconds between queue health checks in the serve loop.
    #[serde(default = "default_queue_check_interval_seconds")]
    pub check_interval_seconds: u64,
    /// Treat queued runs older than this many hours as stale GitHub artifacts.
    #[serde(default = "default_queue_stale_hours")]
    pub stale_hours: u64,
    /// Require this many consecutive bad samples before alerting.
    #[serde(default = "default_queue_consecutive_alert_threshold")]
    pub consecutive_alert_threshold: u32,
}

impl Default for QueueMonitorConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            repo: None,
            tail_warn_minutes: default_queue_tail_warn_minutes(),
            check_interval_seconds: default_queue_check_interval_seconds(),
            stale_hours: default_queue_stale_hours(),
            consecutive_alert_threshold: default_queue_consecutive_alert_threshold(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct CanaryConfig {
    /// Enable daemon-side canary scheduling. `canary-once` can still run manually.
    #[serde(default)]
    pub enabled: bool,
    /// Minimum seconds between daemon-scheduled canary dispatches.
    #[serde(default = "default_canary_check_interval_seconds")]
    pub check_interval_seconds: u64,
    /// Repository containing the canary workflow as `owner/repo`. Defaults to `github.target` for repo-scoped configs.
    pub repo: Option<String>,
    /// Workflow file name or workflow id accepted by GitHub's workflow dispatch API.
    #[serde(default = "default_canary_workflow")]
    pub workflow: String,
    /// Git ref used for workflow_dispatch.
    #[serde(default = "default_canary_ref")]
    pub ref_name: String,
    /// Warn/alert when dispatch-to-runner-start exceeds this many seconds.
    #[serde(default = "default_canary_slo_start_seconds")]
    pub slo_start_seconds: u64,
    /// Maximum seconds a one-shot canary check waits for completion.
    #[serde(default = "default_canary_poll_timeout_seconds")]
    pub poll_timeout_seconds: u64,
    /// Seconds between canary run/job polls.
    #[serde(default = "default_canary_poll_interval_seconds")]
    pub poll_interval_seconds: u64,
    /// Optional durable JSONL canary history path.
    pub history_path: Option<PathBuf>,
}

impl Default for CanaryConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            check_interval_seconds: default_canary_check_interval_seconds(),
            repo: None,
            workflow: default_canary_workflow(),
            ref_name: default_canary_ref(),
            slo_start_seconds: default_canary_slo_start_seconds(),
            poll_timeout_seconds: default_canary_poll_timeout_seconds(),
            poll_interval_seconds: default_canary_poll_interval_seconds(),
            history_path: None,
        }
    }
}

/// E1 ironclad exit-criterion sampler (goals/2026-07-07-1920-runner-truly-healthy/
/// 02-exit-criteria-ironclad.md): evaluates INV-1 (fleet utilization) and INV-2
/// (job duration) once per tick across the hardcoded monitored-repo list in
/// `queue_monitor::MONITORED_INVARIANT_REPOS`, and appends one JSON line per
/// sample to `history_path`. This is deliberately separate from
/// `QueueMonitorConfig`, which drives a different, single-repo alerting concern.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct InvariantSamplerConfig {
    /// Enable the invariant sampler in the daemon serve loop. Defaults on
    /// (unlike `queue_monitor.enabled`) because E1 requires this running
    /// automatically without extra config-file surgery.
    #[serde(default = "default_invariant_sampler_enabled")]
    pub enabled: bool,
    /// Minimum seconds between invariant samples. Must stay <= 300 (5 min) to
    /// satisfy E1's sampling-cadence requirement; enforced in `validate()`.
    #[serde(default = "default_invariant_check_interval_seconds")]
    pub check_interval_seconds: u64,
    /// Optional override for the durable JSONL invariant-history path.
    /// Defaults to `$XDG_STATE_HOME/ezgha/invariant_history.jsonl`
    /// (`~/.local/state/ezgha/...` when XDG_STATE_HOME is unset), matching
    /// this repo's existing alerts.jsonl/canary_history.jsonl convention.
    pub history_path: Option<PathBuf>,
}

impl Default for InvariantSamplerConfig {
    fn default() -> Self {
        Self {
            enabled: default_invariant_sampler_enabled(),
            check_interval_seconds: default_invariant_check_interval_seconds(),
            history_path: None,
        }
    }
}

fn default_invariant_sampler_enabled() -> bool {
    true
}

fn default_invariant_check_interval_seconds() -> u64 {
    240
}

fn maximum_invariant_check_interval_seconds() -> u64 {
    300
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct GithubConfig {
    /// "repo" or "org"
    pub scope: Scope,
    /// "owner/repo" for repo scope, "org" for org scope.
    pub target: String,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Scope {
    Repo,
    Org,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct RunnerConfig {
    pub labels: Vec<String>,
    /// How many concurrent ephemeral runners to keep available.
    pub count: u32,
    /// Container image used by the docker backend.
    pub image: String,
    /// Stable prefix for ephemeral runner names. The docker backend appends
    /// `-{slot}` (slot in `1..=count`) so the full name is
    /// `{name_prefix}-{slot}` (e.g. `ez-org-runner-3`). The prefix is global
    /// across hosts; per-host ownership is tracked via the locally persisted
    /// slot assignment file.
    #[serde(default = "default_runner_name_prefix")]
    pub name_prefix: String,
}

fn default_runner_name_prefix() -> String {
    "ez-org-runner".into()
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Limits {
    pub memory_mb: u64,
    pub cpus: f64,
    pub pids: u32,
    /// Refuse to spawn new runners when host free disk drops below this.
    /// Disk exhaustion is the dominant self-hosted runner failure mode.
    #[serde(default = "default_min_free_disk_gb")]
    pub min_free_disk_gb: u64,
}

fn default_min_free_disk_gb() -> u64 {
    10
}

fn default_failure_alert_threshold() -> u32 {
    3
}

fn default_alert_cooldown_seconds() -> u64 {
    900
}

fn default_deadman_threshold_seconds() -> u64 {
    3600
}

fn default_queue_tail_warn_minutes() -> u64 {
    20
}

fn default_queue_check_interval_seconds() -> u64 {
    300
}

fn minimum_queue_check_interval_seconds() -> u64 {
    60
}

fn default_queue_stale_hours() -> u64 {
    8
}

/// Independent of the default so retuning the default (as happened
/// 2026-07-07, 24 -> 8) doesn't silently move the validation ceiling too.
fn maximum_queue_stale_hours() -> u64 {
    8
}

fn default_queue_consecutive_alert_threshold() -> u32 {
    2
}

fn default_canary_workflow() -> String {
    "selftest.yml".into()
}

fn default_canary_ref() -> String {
    "main".into()
}

fn default_canary_slo_start_seconds() -> u64 {
    90
}

fn default_canary_check_interval_seconds() -> u64 {
    600
}

fn minimum_canary_check_interval_seconds() -> u64 {
    60
}

fn default_canary_poll_timeout_seconds() -> u64 {
    600
}

fn default_canary_poll_interval_seconds() -> u64 {
    15
}

fn default_serve_interval_seconds() -> u64 {
    30
}

fn minimum_serve_interval_seconds() -> u64 {
    5
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Policy {
    /// Refuse to start when the best available backend is weaker than this.
    /// "vm" > "container". Fail closed instead of silently degrading.
    pub minimum_isolation: IsolationLevel,
    /// Seconds the serve loop sleeps after a successful `ensure_count` pass
    /// (and after a non-restart ensure failure) before the next tick. Lower
    /// values shrink the window an ephemeral runner slot sits dead between a
    /// job finishing and its replacement spawning (~40% duty-cycle loss at the
    /// 30s default under short-job CI load).
    ///
    /// Clamped to a 5s floor at use-site (`serve_interval()`): sub-5s ticks
    /// would hammer `release_stale_slots`' GitHub `list_runners` call.
    ///
    /// Blast radius: at a 10s tick, `release_stale_slots`' `list_runners`
    /// runs ~360 calls/hr, versus the App-token budget of 9350/hr (normal peak
    /// total <1000/hr) — a safe margin. The queue monitor keeps its own
    /// independent `check_interval_seconds` and is unaffected by this field.
    #[serde(default = "default_serve_interval_seconds")]
    pub serve_interval_seconds: u64,
}

impl Policy {
    /// The serve-loop sleep interval, clamped to the 5s floor. Emits a one-line
    /// clamp note (matching the `note: clamping ...` style used in
    /// docker_backend.rs) when the configured value is below the floor.
    pub fn serve_interval(&self) -> std::time::Duration {
        let min = minimum_serve_interval_seconds();
        let secs = if self.serve_interval_seconds < min {
            eprintln!(
                "note: clamping serve_interval_seconds {} -> {}",
                self.serve_interval_seconds, min
            );
            min
        } else {
            self.serve_interval_seconds
        };
        std::time::Duration::from_secs(secs)
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "lowercase")]
pub enum IsolationLevel {
    Container,
    Vm,
}

impl std::fmt::Display for IsolationLevel {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            IsolationLevel::Container => write!(f, "container"),
            IsolationLevel::Vm => write!(f, "vm"),
        }
    }
}

/// Shared `validate()` guard: an optional path, if configured, must be non-empty.
/// An empty `PathBuf` (e.g. `path = ""` in TOML) is a config typo that would
/// otherwise surface later as a confusing filesystem error.
fn require_non_empty_path(field: &str, path: &Option<PathBuf>) -> Result<()> {
    if let Some(p) = path {
        if p.as_os_str().is_empty() {
            anyhow::bail!("{field} must not be empty when configured");
        }
    }
    Ok(())
}

/// Shared `validate()` guard: an unsigned field must be at least 1.
fn require_at_least_one(field: &str, value: u64) -> Result<()> {
    if value == 0 {
        anyhow::bail!("{field} must be at least 1 (got {value})");
    }
    Ok(())
}

/// Shared `validate()` guard for `queue_monitor.repo` / `canary.repo`: when
/// configured it must be `owner/repo`; when absent, it's only required if the
/// feature is enabled against an org-scoped target (repo scope already
/// implies a single unambiguous repo).
fn require_scoped_repo(
    prefix: &str,
    repo: &Option<String>,
    enabled: bool,
    scope: Scope,
) -> Result<()> {
    if let Some(r) = repo {
        if !is_owner_repo(r) {
            anyhow::bail!(
                "{prefix}.repo must be exactly \"owner/repo\" when configured (got {r:?})"
            );
        }
    } else if enabled && scope != Scope::Repo {
        anyhow::bail!(
            "{prefix}.repo is required when {prefix}.enabled=true and github.scope is org"
        );
    }
    Ok(())
}

impl Config {
    /// Sensible defaults derived from host capacity: half the RAM (bounded to
    /// [2 GiB, 16 GiB]) and half the cores, so a runaway job cannot take the
    /// host down — the failure mode that motivated this tool.
    pub fn defaults_for(plat: &Platform, target: String, scope: Scope) -> Config {
        let mem = (plat.total_mem_mb / 2).clamp(2048, 16384);
        let cpus = ((plat.cpus / 2).max(1)) as f64;
        Config {
            version: 1,
            state_dir: None,
            github: GithubConfig { scope, target },
            runner: RunnerConfig {
                labels: vec!["self-hosted".into(), "ezgha".into()],
                count: 1,
                image: "ghcr.io/actions/actions-runner:latest".into(),
                name_prefix: default_runner_name_prefix(),
            },
            limits: Limits {
                memory_mb: mem,
                cpus,
                pids: 512,
                min_free_disk_gb: default_min_free_disk_gb(),
            },
            policy: Policy {
                minimum_isolation: IsolationLevel::Container,
                serve_interval_seconds: default_serve_interval_seconds(),
            },
            alert: AlertConfig {
                failure_alert_threshold: default_failure_alert_threshold(),
                alert_cooldown_secs: default_alert_cooldown_seconds(),
                slack_webhook_url: None,
                email_to: None,
                email_from: None,
                log_path: None,
                deadman_threshold_seconds: default_deadman_threshold_seconds(),
            },
            queue_monitor: QueueMonitorConfig::default(),
            canary: CanaryConfig::default(),
            invariant_sampler: InvariantSamplerConfig::default(),
        }
    }

    pub fn default_path() -> Result<PathBuf> {
        let dirs = ProjectDirs::from("org", "jleechanorg", "ezgha")
            .context("cannot determine config directory")?;
        Ok(dirs.config_dir().join("config.toml"))
    }

    /// Reject configs that parse syntactically but are semantically unsafe.
    /// The whole point of this tool is bounding runaway jobs, so a `memory_mb`
    /// or `cpus` of 0 (which Docker treats as "unlimited") is a fail-open hole
    /// in the core safety guarantee. We bail rather than clamp: a nonsensical
    /// limit is an operator mistake that should be seen, not silently rewritten.
    pub fn validate(&self) -> Result<()> {
        if self.version != CURRENT_VERSION {
            anyhow::bail!(
                "unsupported config version {} (this binary understands version {}); \
                 re-run `ezgha init` or migrate the config",
                self.version,
                CURRENT_VERSION
            );
        }
        if self.limits.memory_mb < 512 {
            anyhow::bail!(
                "limits.memory_mb must be at least 512 (got {}); 0 means \
                 'unlimited' to Docker and defeats the resource cap",
                self.limits.memory_mb
            );
        }
        if !self.limits.cpus.is_finite() || self.limits.cpus < 0.5 {
            anyhow::bail!(
                "limits.cpus must be a finite value >= 0.5 (got {}); 0 means \
                 'unlimited' to Docker and defeats the resource cap",
                self.limits.cpus
            );
        }
        if self.limits.pids < 1 {
            anyhow::bail!("limits.pids must be at least 1 (got {})", self.limits.pids);
        }
        if self.runner.count < 1 {
            anyhow::bail!(
                "runner.count must be at least 1 (got {})",
                self.runner.count
            );
        }
        if self.github.target.trim().is_empty() {
            anyhow::bail!("github.target must not be empty");
        }
        require_non_empty_path("state_dir", &self.state_dir)?;
        if self.github.scope == Scope::Repo && self.github.target.matches('/').count() != 1 {
            anyhow::bail!(
                "github.target must be exactly \"owner/repo\" for repo scope (got {:?})",
                self.github.target
            );
        }
        require_at_least_one(
            "alert.failure_alert_threshold",
            self.alert.failure_alert_threshold as u64,
        )?;
        require_at_least_one("alert.alert_cooldown_secs", self.alert.alert_cooldown_secs)?;
        require_non_empty_path("alert.log_path", &self.alert.log_path)?;
        require_at_least_one(
            "queue_monitor.tail_warn_minutes",
            self.queue_monitor.tail_warn_minutes,
        )?;
        if self.queue_monitor.check_interval_seconds < minimum_queue_check_interval_seconds() {
            anyhow::bail!(
                "queue_monitor.check_interval_seconds must be at least {} (got {})",
                minimum_queue_check_interval_seconds(),
                self.queue_monitor.check_interval_seconds
            );
        }
        require_at_least_one("queue_monitor.stale_hours", self.queue_monitor.stale_hours)?;
        if self.queue_monitor.stale_hours > maximum_queue_stale_hours() {
            anyhow::bail!(
                "queue_monitor.stale_hours must be at most {} (got {})",
                maximum_queue_stale_hours(),
                self.queue_monitor.stale_hours
            );
        }
        require_at_least_one(
            "queue_monitor.consecutive_alert_threshold",
            self.queue_monitor.consecutive_alert_threshold as u64,
        )?;
        require_scoped_repo(
            "queue_monitor",
            &self.queue_monitor.repo,
            self.queue_monitor.enabled,
            self.github.scope,
        )?;
        require_scoped_repo(
            "canary",
            &self.canary.repo,
            self.canary.enabled,
            self.github.scope,
        )?;
        if self.canary.workflow.trim().is_empty() {
            anyhow::bail!("canary.workflow must not be empty");
        }
        if self.canary.ref_name.trim().is_empty() {
            anyhow::bail!("canary.ref_name must not be empty");
        }
        require_at_least_one("canary.slo_start_seconds", self.canary.slo_start_seconds)?;
        if self.canary.check_interval_seconds < minimum_canary_check_interval_seconds() {
            anyhow::bail!(
                "canary.check_interval_seconds must be at least {} (got {})",
                minimum_canary_check_interval_seconds(),
                self.canary.check_interval_seconds
            );
        }
        require_at_least_one(
            "canary.poll_timeout_seconds",
            self.canary.poll_timeout_seconds,
        )?;
        require_at_least_one(
            "canary.poll_interval_seconds",
            self.canary.poll_interval_seconds,
        )?;
        if self.canary.poll_interval_seconds > self.canary.poll_timeout_seconds {
            anyhow::bail!("canary.poll_interval_seconds must be <= canary.poll_timeout_seconds");
        }
        require_non_empty_path("canary.history_path", &self.canary.history_path)?;
        if self.invariant_sampler.check_interval_seconds == 0
            || self.invariant_sampler.check_interval_seconds
                > maximum_invariant_check_interval_seconds()
        {
            anyhow::bail!(
                "invariant_sampler.check_interval_seconds must be in 1..={} to satisfy \
                 the E1 <=5min sampling-cadence exit criterion (got {})",
                maximum_invariant_check_interval_seconds(),
                self.invariant_sampler.check_interval_seconds
            );
        }
        require_non_empty_path(
            "invariant_sampler.history_path",
            &self.invariant_sampler.history_path,
        )?;
        Ok(())
    }

    pub fn load(path: &PathBuf) -> Result<Config> {
        let raw = std::fs::read_to_string(path)
            .with_context(|| format!("no config at {} — run `ezgha init` first", path.display()))?;
        let cfg: Config = toml::from_str(&raw)
            .with_context(|| format!("invalid config at {}", path.display()))?;
        cfg.validate()
            .with_context(|| format!("invalid config at {}", path.display()))?;
        Ok(cfg)
    }

    pub fn save(&self, path: &PathBuf) -> Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let raw = toml::to_string_pretty(self).context("serialize config")?;
        // Atomic write: a crash between truncate and full write would leave a
        // torn config.toml that fails to parse, wedging all subsequent `ezgha`
        // commands until the operator re-runs `init`. Write a sibling temp file
        // then rename(2), which is atomic within a directory on POSIX.
        let tmp = path.with_extension("toml.tmp");
        std::fs::write(&tmp, raw).with_context(|| format!("write temp {}", tmp.display()))?;
        std::fs::rename(&tmp, path)
            .with_context(|| format!("rename {} -> {}", tmp.display(), path.display()))?;
        Ok(())
    }
}

fn is_owner_repo(value: &str) -> bool {
    if value.trim() != value {
        return false;
    }
    let mut parts = value.split('/');
    let Some(owner) = parts.next() else {
        return false;
    };
    let Some(repo) = parts.next() else {
        return false;
    };
    parts.next().is_none() && !owner.is_empty() && !repo.is_empty()
}

#[cfg(test)]
mod tests {
    use super::*;

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

    #[test]
    fn defaults_are_bounded() {
        let tiny = Config::defaults_for(&fake_platform(1024, 1), "o/r".into(), Scope::Repo);
        assert_eq!(tiny.limits.memory_mb, 2048); // floor
        assert_eq!(tiny.limits.cpus, 1.0);
        assert_eq!(tiny.alert.failure_alert_threshold, 3);
        assert_eq!(tiny.alert.alert_cooldown_secs, 900);
        assert!(!tiny.queue_monitor.enabled);
        assert_eq!(tiny.queue_monitor.tail_warn_minutes, 20);
        assert_eq!(tiny.queue_monitor.check_interval_seconds, 300);
        assert_eq!(tiny.queue_monitor.stale_hours, 8);
        assert_eq!(tiny.queue_monitor.consecutive_alert_threshold, 2);
        assert!(!tiny.canary.enabled);
        assert_eq!(tiny.canary.workflow, "selftest.yml");
        assert_eq!(tiny.canary.ref_name, "main");
        assert_eq!(tiny.canary.slo_start_seconds, 90);
        assert_eq!(tiny.canary.check_interval_seconds, 600);

        let huge = Config::defaults_for(&fake_platform(128 * 1024, 32), "o/r".into(), Scope::Repo);
        assert_eq!(huge.limits.memory_mb, 16384); // ceiling
        assert_eq!(huge.limits.cpus, 16.0);
    }

    #[test]
    fn config_roundtrip() {
        let mut cfg = Config::defaults_for(
            &fake_platform(8192, 8),
            "jleechanorg/ez-gh-actions".into(),
            Scope::Repo,
        );
        cfg.state_dir = Some(std::env::temp_dir().join("ezgha-state-roundtrip"));
        let path = std::env::temp_dir().join(format!("ezgha-test-{}.toml", std::process::id()));
        cfg.save(&path).unwrap();
        let loaded = Config::load(&path).unwrap();
        std::fs::remove_file(&path).ok();
        assert_eq!(cfg, loaded);
    }

    #[test]
    fn isolation_ordering_fail_closed() {
        assert!(IsolationLevel::Vm > IsolationLevel::Container);
    }

    fn valid_config() -> Config {
        Config::defaults_for(&fake_platform(8192, 8), "owner/repo".into(), Scope::Repo)
    }

    /// Write `raw` to a unique temp file and attempt to load it, returning the
    /// result so tests can assert on the (in)validity.
    fn load_from_str(raw: &str, tag: &str) -> Result<Config> {
        let path = std::env::temp_dir().join(format!(
            "ezgha-test-{}-{}-{:?}.toml",
            std::process::id(),
            tag,
            std::thread::current().id()
        ));
        std::fs::write(&path, raw).unwrap();
        let out = Config::load(&path);
        std::fs::remove_file(&path).ok();
        out
    }

    #[test]
    fn valid_config_passes_validation() {
        valid_config().validate().unwrap();
    }

    #[test]
    fn reject_zero_memory() {
        let mut cfg = valid_config();
        cfg.limits.memory_mb = 0;
        assert!(cfg.validate().is_err());
    }

    #[test]
    fn reject_memory_below_floor() {
        let mut cfg = valid_config();
        cfg.limits.memory_mb = 511;
        assert!(cfg.validate().is_err());
        cfg.limits.memory_mb = 512;
        assert!(cfg.validate().is_ok());
    }

    #[test]
    fn reject_zero_cpus() {
        let mut cfg = valid_config();
        cfg.limits.cpus = 0.0;
        assert!(cfg.validate().is_err());
    }

    #[test]
    fn reject_subminimum_cpus() {
        let mut cfg = valid_config();
        cfg.limits.cpus = 0.25;
        assert!(cfg.validate().is_err());
        cfg.limits.cpus = 0.5;
        assert!(cfg.validate().is_ok());
    }

    #[test]
    fn reject_non_finite_cpus() {
        let mut cfg = valid_config();
        cfg.limits.cpus = f64::NAN;
        assert!(cfg.validate().is_err());
        cfg.limits.cpus = f64::INFINITY;
        assert!(cfg.validate().is_err());
    }

    #[test]
    fn reject_zero_pids() {
        let mut cfg = valid_config();
        cfg.limits.pids = 0;
        assert!(cfg.validate().is_err());
    }

    #[test]
    fn reject_zero_count() {
        let mut cfg = valid_config();
        cfg.runner.count = 0;
        assert!(cfg.validate().is_err());
    }

    #[test]
    fn reject_empty_target() {
        let mut cfg = valid_config();
        cfg.github.target = "   ".into();
        assert!(cfg.validate().is_err());
    }

    #[test]
    fn reject_repo_target_without_single_slash() {
        let mut cfg = valid_config();
        cfg.github.scope = Scope::Repo;
        cfg.github.target = "justowner".into();
        assert!(cfg.validate().is_err());
        cfg.github.target = "owner/repo/extra".into();
        assert!(cfg.validate().is_err());
        cfg.github.target = "owner/repo".into();
        assert!(cfg.validate().is_ok());
    }

    #[test]
    fn org_scope_allows_bare_target() {
        let mut cfg = valid_config();
        cfg.github.scope = Scope::Org;
        cfg.github.target = "myorg".into();
        assert!(cfg.validate().is_ok());
    }

    #[test]
    fn queue_monitor_requires_repo_for_org_scope_when_enabled() {
        let mut cfg = valid_config();
        cfg.github.scope = Scope::Org;
        cfg.github.target = "myorg".into();
        cfg.queue_monitor.enabled = true;
        assert!(cfg.validate().is_err());
        cfg.queue_monitor.repo = Some("owner/repo".into());
        assert!(cfg.validate().is_ok());
    }

    #[test]
    fn reject_invalid_queue_monitor_values() {
        let mut cfg = valid_config();
        cfg.queue_monitor.tail_warn_minutes = 0;
        assert!(cfg.validate().is_err());
        cfg.queue_monitor.tail_warn_minutes = 20;
        cfg.queue_monitor.check_interval_seconds = 59;
        assert!(cfg.validate().is_err());
        cfg.queue_monitor.check_interval_seconds = 300;
        cfg.queue_monitor.stale_hours = 0;
        assert!(cfg.validate().is_err());
        cfg.queue_monitor.stale_hours = 9;
        assert!(cfg.validate().is_err());
        cfg.queue_monitor.stale_hours = 8;
        cfg.queue_monitor.consecutive_alert_threshold = 0;
        assert!(cfg.validate().is_err());
        cfg.queue_monitor.consecutive_alert_threshold = 2;
        for repo in [
            "owner-only",
            "owner/",
            "/repo",
            " owner/repo",
            "owner/repo ",
        ] {
            cfg.queue_monitor.repo = Some(repo.into());
            assert!(cfg.validate().is_err(), "{repo:?} should be invalid");
        }
        cfg.queue_monitor.repo = Some("owner/repo".into());
        assert!(cfg.validate().is_ok());
    }

    #[test]
    fn canary_requires_repo_for_org_scope_when_enabled() {
        let mut cfg = valid_config();
        cfg.github.scope = Scope::Org;
        cfg.github.target = "myorg".into();
        cfg.canary.enabled = true;
        assert!(cfg.validate().is_err());
        cfg.canary.repo = Some("owner/repo".into());
        assert!(cfg.validate().is_ok());
    }

    #[test]
    fn reject_invalid_canary_values() {
        let mut cfg = valid_config();
        cfg.canary.repo = Some("owner/".into());
        assert!(cfg.validate().is_err());
        cfg.canary.repo = Some("owner/repo".into());
        cfg.canary.workflow = " ".into();
        assert!(cfg.validate().is_err());
        cfg.canary.workflow = "selftest.yml".into();
        cfg.canary.ref_name = "".into();
        assert!(cfg.validate().is_err());
        cfg.canary.ref_name = "main".into();
        cfg.canary.slo_start_seconds = 0;
        assert!(cfg.validate().is_err());
        cfg.canary.slo_start_seconds = 90;
        cfg.canary.check_interval_seconds = 59;
        assert!(cfg.validate().is_err());
        cfg.canary.check_interval_seconds = 600;
        cfg.canary.poll_timeout_seconds = 0;
        assert!(cfg.validate().is_err());
        cfg.canary.poll_timeout_seconds = 10;
        cfg.canary.poll_interval_seconds = 11;
        assert!(cfg.validate().is_err());
        cfg.canary.poll_interval_seconds = 5;
        assert!(cfg.validate().is_ok());
    }

    #[test]
    fn policy_serve_interval_parses_configured_value() {
        let raw = r#"
version = 1
[github]
scope = "repo"
target = "owner/repo"
[runner]
labels = ["self-hosted"]
count = 1
image = "img:latest"
[limits]
memory_mb = 2048
cpus = 2.0
pids = 512
[policy]
minimum_isolation = "container"
serve_interval_seconds = 10
"#;
        let cfg = load_from_str(raw, "serve-interval-10").unwrap();
        assert_eq!(cfg.policy.serve_interval_seconds, 10);
        assert_eq!(cfg.policy.serve_interval(), std::time::Duration::from_secs(10));
    }

    #[test]
    fn policy_serve_interval_defaults_to_30_when_absent() {
        let raw = r#"
version = 1
[github]
scope = "repo"
target = "owner/repo"
[runner]
labels = ["self-hosted"]
count = 1
image = "img:latest"
[limits]
memory_mb = 2048
cpus = 2.0
pids = 512
[policy]
minimum_isolation = "container"
"#;
        let cfg = load_from_str(raw, "serve-interval-default").unwrap();
        assert_eq!(cfg.policy.serve_interval_seconds, 30);
        assert_eq!(cfg.policy.serve_interval(), std::time::Duration::from_secs(30));
    }

    #[test]
    fn policy_serve_interval_clamps_below_floor_to_5() {
        let mut policy = Policy {
            minimum_isolation: IsolationLevel::Container,
            serve_interval_seconds: 2,
        };
        assert_eq!(policy.serve_interval(), std::time::Duration::from_secs(5));
        // exactly at floor is preserved
        policy.serve_interval_seconds = 5;
        assert_eq!(policy.serve_interval(), std::time::Duration::from_secs(5));
    }

    #[test]
    fn load_legacy_config_without_queue_monitor_defaults_disabled() {
        let raw = r#"
version = 1
[github]
scope = "repo"
target = "owner/repo"
[runner]
labels = ["self-hosted"]
count = 1
image = "img:latest"
[limits]
memory_mb = 2048
cpus = 2.0
pids = 512
[policy]
minimum_isolation = "container"
"#;
        let cfg = load_from_str(raw, "legacy-no-queue-monitor").unwrap();
        assert!(!cfg.queue_monitor.enabled);
        assert_eq!(cfg.queue_monitor.tail_warn_minutes, 20);
        assert_eq!(cfg.queue_monitor.check_interval_seconds, 300);
        assert!(!cfg.canary.enabled);
        assert_eq!(cfg.canary.workflow, "selftest.yml");
        assert_eq!(cfg.canary.check_interval_seconds, 600);
    }

    #[test]
    fn example_configs_load_without_queue_monitor_block() {
        load_from_str(
            include_str!("../config/config.toml.linux.example"),
            "linux-example",
        )
        .unwrap();
        load_from_str(
            include_str!("../config/config.toml.mac.example"),
            "mac-example",
        )
        .unwrap();
    }

    #[test]
    fn reject_wrong_version() {
        let mut cfg = valid_config();
        cfg.version = CURRENT_VERSION + 1;
        assert!(cfg.validate().is_err());
    }

    #[test]
    fn load_rejects_unknown_field() {
        let raw = r#"
version = 1
[github]
scope = "repo"
target = "owner/repo"
[runner]
labels = ["self-hosted"]
count = 1
image = "img:latest"
[limits]
memory_mb = 2048
cpus = 2.0
pids = 512
typo_min_free_disk_gb = 10
[policy]
minimum_isolation = "container"
"#;
        let err = load_from_str(raw, "unknown").unwrap_err();
        assert!(
            format!("{err:#}").contains("typo_min_free_disk_gb")
                || format!("{err:#}").to_lowercase().contains("unknown"),
            "expected unknown-field error, got: {err:#}"
        );
    }

    #[test]
    fn load_rejects_zero_memory_from_disk() {
        let raw = r#"
version = 1
[github]
scope = "repo"
target = "owner/repo"
[runner]
labels = ["self-hosted"]
count = 1
image = "img:latest"
[limits]
memory_mb = 0
cpus = 2.0
pids = 512
[policy]
minimum_isolation = "container"
"#;
        assert!(load_from_str(raw, "zeromem").is_err());
    }

    #[test]
    fn load_rejects_wrong_version_from_disk() {
        let raw = r#"
version = 999
[github]
scope = "repo"
target = "owner/repo"
[runner]
labels = ["self-hosted"]
count = 1
image = "img:latest"
[limits]
memory_mb = 2048
cpus = 2.0
pids = 512
[policy]
minimum_isolation = "container"
"#;
        assert!(load_from_str(raw, "ver").is_err());
    }
}
