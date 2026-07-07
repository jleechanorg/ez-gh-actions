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
    pub github: GithubConfig,
    pub runner: RunnerConfig,
    pub limits: Limits,
    pub policy: Policy,
    #[serde(default)]
    pub alert: AlertConfig,
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
        }
    }
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

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Policy {
    /// Refuse to start when the best available backend is weaker than this.
    /// "vm" > "container". Fail closed instead of silently degrading.
    pub minimum_isolation: IsolationLevel,
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

impl Config {
    /// Sensible defaults derived from host capacity: half the RAM (bounded to
    /// [2 GiB, 16 GiB]) and half the cores, so a runaway job cannot take the
    /// host down — the failure mode that motivated this tool.
    pub fn defaults_for(plat: &Platform, target: String, scope: Scope) -> Config {
        let mem = (plat.total_mem_mb / 2).clamp(2048, 16384);
        let cpus = ((plat.cpus / 2).max(1)) as f64;
        Config {
            version: 1,
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
            },
            alert: AlertConfig {
                failure_alert_threshold: default_failure_alert_threshold(),
                alert_cooldown_secs: default_alert_cooldown_seconds(),
                slack_webhook_url: None,
                email_to: None,
                email_from: None,
                log_path: None,
            },
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
        if self.github.scope == Scope::Repo && self.github.target.matches('/').count() != 1 {
            anyhow::bail!(
                "github.target must be exactly \"owner/repo\" for repo scope (got {:?})",
                self.github.target
            );
        }
        if self.alert.failure_alert_threshold == 0 {
            anyhow::bail!(
                "alert.failure_alert_threshold must be at least 1 (got {})",
                self.alert.failure_alert_threshold
            );
        }
        if self.alert.alert_cooldown_secs == 0 {
            anyhow::bail!(
                "alert.alert_cooldown_secs must be at least 1 second (got {})",
                self.alert.alert_cooldown_secs
            );
        }
        if let Some(path) = &self.alert.log_path {
            if path.as_os_str().is_empty() {
                anyhow::bail!("alert.log_path must not be empty when configured");
            }
        }
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

        let huge = Config::defaults_for(&fake_platform(128 * 1024, 32), "o/r".into(), Scope::Repo);
        assert_eq!(huge.limits.memory_mb, 16384); // ceiling
        assert_eq!(huge.limits.cpus, 16.0);
    }

    #[test]
    fn config_roundtrip() {
        let cfg = Config::defaults_for(
            &fake_platform(8192, 8),
            "jleechanorg/ez-gh-actions".into(),
            Scope::Repo,
        );
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
