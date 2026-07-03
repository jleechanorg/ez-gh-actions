use anyhow::{bail, Context, Result};
use serde::Deserialize;
use std::process::Command;

use crate::config::{GithubConfig, Scope};

/// All GitHub API access goes through the `gh` CLI so we inherit its auth
/// (keyring/oauth) instead of handling tokens ourselves. v1 requirement:
/// `gh auth login` must have been run for the target.
fn api_base(gh: &GithubConfig) -> String {
    match gh.scope {
        Scope::Repo => format!("repos/{}", gh.target),
        Scope::Org => format!("orgs/{}", gh.target),
    }
}

#[derive(Debug, Deserialize)]
struct JitConfigResponse {
    encoded_jit_config: String,
    runner: JitRunner,
}

#[derive(Debug, Deserialize)]
struct JitRunner {
    id: u64,
    name: String,
}

/// Ask GitHub for a just-in-time runner registration. A JIT runner accepts
/// exactly one job and then deregisters itself — ephemeral by construction,
/// no registration token to store or clean up.
pub fn generate_jitconfig(
    gh: &GithubConfig,
    name: &str,
    labels: &[String],
) -> Result<(String, u64)> {
    let path = format!("{}/actions/runners/generate-jitconfig", api_base(gh));
    let mut cmd = Command::new("gh");
    cmd.args(["api", "-X", "POST", &path, "-f", &format!("name={name}")]);
    cmd.args(["-F", "runner_group_id=1"]);
    for label in labels {
        cmd.args(["-f", &format!("labels[]={label}")]);
    }
    let out = cmd
        .output()
        .context("failed to run `gh api` — is the gh CLI installed?")?;
    if !out.status.success() {
        bail!(
            "gh api generate-jitconfig failed for {}: {}",
            gh.target,
            String::from_utf8_lossy(&out.stderr)
        );
    }
    let parsed: JitConfigResponse =
        serde_json::from_slice(&out.stdout).context("unexpected generate-jitconfig response")?;
    let _ = parsed.runner.name;
    Ok((parsed.encoded_jit_config, parsed.runner.id))
}

#[derive(Debug, Deserialize)]
pub struct RunnerInfo {
    pub id: u64,
    pub name: String,
    pub status: String,
    pub busy: bool,
}

#[derive(Debug, Deserialize)]
struct RunnerList {
    runners: Vec<RunnerInfo>,
}

pub fn list_runners(gh: &GithubConfig) -> Result<Vec<RunnerInfo>> {
    let path = format!("{}/actions/runners?per_page=100", api_base(gh));
    let out = Command::new("gh")
        .args(["api", &path])
        .output()
        .context("failed to run `gh api`")?;
    if !out.status.success() {
        bail!(
            "gh api list runners failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
    let parsed: RunnerList = serde_json::from_slice(&out.stdout)?;
    Ok(parsed.runners)
}

/// Best-effort removal of a registered runner (used when we kill a runner
/// container before it ever picked up a job).
pub fn remove_runner(gh: &GithubConfig, id: u64) -> Result<()> {
    let path = format!("{}/actions/runners/{id}", api_base(gh));
    let out = Command::new("gh")
        .args(["api", "-X", "DELETE", &path])
        .output()
        .context("failed to run `gh api`")?;
    if !out.status.success() {
        bail!(
            "gh api remove runner {id} failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
    Ok(())
}

pub fn gh_auth_ok() -> bool {
    Command::new("gh")
        .args(["auth", "status"])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}
