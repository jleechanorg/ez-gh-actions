use anyhow::{Context, Result};
use directories::ProjectDirs;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

use crate::platform::Platform;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Config {
    pub version: u32,
    pub github: GithubConfig,
    pub runner: RunnerConfig,
    pub limits: Limits,
    pub policy: Policy,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
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
pub struct RunnerConfig {
    pub labels: Vec<String>,
    /// How many concurrent ephemeral runners to keep available.
    pub count: u32,
    /// Container image used by the docker backend.
    pub image: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
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

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
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
        }
    }

    pub fn default_path() -> Result<PathBuf> {
        let dirs = ProjectDirs::from("org", "jleechanorg", "ezgha")
            .context("cannot determine config directory")?;
        Ok(dirs.config_dir().join("config.toml"))
    }

    pub fn load(path: &PathBuf) -> Result<Config> {
        let raw = std::fs::read_to_string(path)
            .with_context(|| format!("no config at {} — run `ezgha init` first", path.display()))?;
        let cfg: Config = toml::from_str(&raw)
            .with_context(|| format!("invalid config at {}", path.display()))?;
        Ok(cfg)
    }

    pub fn save(&self, path: &PathBuf) -> Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(path, toml::to_string_pretty(self)?)?;
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
}
