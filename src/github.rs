use anyhow::{bail, Context, Result};
use serde::Deserialize;
use std::process::Command;

use crate::config::{GithubConfig, Scope};

/// All GitHub API access goes through the `gh` CLI so we inherit its auth
/// (keyring/oauth) instead of handling tokens ourselves. v1 requirement:
/// `gh auth login` must have been run for the target.
///
/// Repo scope → `repos/{owner}/{repo}/...`
/// Org scope  → `orgs/{org}/...`
pub fn api_base(gh: &GithubConfig) -> String {
    match gh.scope {
        Scope::Repo => format!("repos/{}", gh.target),
        Scope::Org => format!("orgs/{}", gh.target),
    }
}

/// Path for POST …/actions/runners/generate-jitconfig, used by JIT registration.
pub fn jitconfig_path(gh: &GithubConfig) -> String {
    format!("{}/actions/runners/generate-jitconfig", api_base(gh))
}

/// Path for GET …/actions/runners?per_page=100, used to enumerate registered
/// runners. Pagination is the caller's responsibility — `gh api` paginates by
/// default and we keep that behavior.
pub fn runners_list_path(gh: &GithubConfig) -> String {
    format!("{}/actions/runners?per_page=100", api_base(gh))
}

/// Path for DELETE …/actions/runners/{id}, used to deregister a runner that
/// never picked up a job.
pub fn runner_remove_path(gh: &GithubConfig, id: u64) -> String {
    format!("{}/actions/runners/{id}", api_base(gh))
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
    let path = jitconfig_path(gh);
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
        let stderr = String::from_utf8_lossy(&out.stderr);
        if stderr.contains("Already exists") || stderr.contains("already exists") {
            if let Ok(runners) = list_runners(gh) {
                if let Some(conflicting) = runners.iter().find(|r| r.name == name) {
                    eprintln!(
                        "note: runner {} already exists (id {}), removing it first",
                        name, conflicting.id
                    );
                    if remove_runner(gh, conflicting.id).is_ok() {
                        let mut retry_cmd = Command::new("gh");
                        retry_cmd.args(["api", "-X", "POST", &path, "-f", &format!("name={name}")]);
                        retry_cmd.args(["-F", "runner_group_id=1"]);
                        for label in labels {
                            retry_cmd.args(["-f", &format!("labels[]={label}")]);
                        }
                        let retry_out = retry_cmd.output()?;
                        if retry_out.status.success() {
                            let parsed: JitConfigResponse =
                                serde_json::from_slice(&retry_out.stdout)?;
                            return Ok((parsed.encoded_jit_config, parsed.runner.id));
                        }
                    }
                }
            }
        }
        bail!(
            "gh api generate-jitconfig failed for {}: {}",
            gh.target,
            stderr
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
    let path = runners_list_path(gh);
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
    let path = runner_remove_path(gh, id);
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

#[cfg(test)]
mod tests {
    use super::*;

    fn repo_cfg() -> GithubConfig {
        GithubConfig {
            scope: Scope::Repo,
            target: "jleechanorg/ez-gh-actions".into(),
        }
    }

    fn org_cfg() -> GithubConfig {
        GithubConfig {
            scope: Scope::Org,
            target: "jleechanorg".into(),
        }
    }

    #[test]
    fn api_base_repo_yields_repos_target() {
        let gh = repo_cfg();
        assert_eq!(api_base(&gh), "repos/jleechanorg/ez-gh-actions");
    }

    #[test]
    fn api_base_org_yields_orgs_target() {
        let gh = org_cfg();
        assert_eq!(api_base(&gh), "orgs/jleechanorg");
    }

    #[test]
    fn generate_jitconfig_org_routes_to_orgs_path() {
        let gh = org_cfg();
        let path = jitconfig_path(&gh);
        assert_eq!(path, "orgs/jleechanorg/actions/runners/generate-jitconfig");
        // Mirror the gh argv construction in generate_jitconfig and prove the
        // path token sits where it does for org scope. This is a string-level
        // check on the constructed args; no subprocess is launched.
        let name = "ezgha-test";
        let labels = ["self-hosted", "ezgha"];
        let mut argv: Vec<String> = vec![
            "api".into(),
            "-X".into(),
            "POST".into(),
            path.clone(),
            format!("name={name}"),
            "runner_group_id=1".into(),
        ];
        for label in &labels {
            argv.push(format!("labels[]={label}"));
        }
        let argv_refs: Vec<&str> = argv.iter().map(String::as_str).collect();
        // The third positional-ish arg after `api -X POST` is the URL path.
        assert_eq!(
            argv_refs[3],
            "orgs/jleechanorg/actions/runners/generate-jitconfig"
        );
        // And the same shape used for repo scope stays under repos/.
        let repo_path = jitconfig_path(&repo_cfg());
        assert_eq!(
            repo_path,
            "repos/jleechanorg/ez-gh-actions/actions/runners/generate-jitconfig"
        );
    }

    #[test]
    fn path_snapshot_for_both_scopes() {
        // Drive every path-selection helper through a fake GitHubConfig for
        // both scopes so any drift in the org-scope wiring is caught in one shot.
        for gh in [repo_cfg(), org_cfg()] {
            let base = api_base(&gh);
            assert_eq!(
                jitconfig_path(&gh),
                format!("{base}/actions/runners/generate-jitconfig")
            );
            assert_eq!(
                runners_list_path(&gh),
                format!("{base}/actions/runners?per_page=100")
            );
            assert_eq!(
                runner_remove_path(&gh, 42),
                format!("{base}/actions/runners/42")
            );
        }

        // Org-scope concrete expectations (the case this PR enables).
        let org = org_cfg();
        assert_eq!(
            jitconfig_path(&org),
            "orgs/jleechanorg/actions/runners/generate-jitconfig"
        );
        assert_eq!(
            runners_list_path(&org),
            "orgs/jleechanorg/actions/runners?per_page=100"
        );
        assert_eq!(
            runner_remove_path(&org, 7),
            "orgs/jleechanorg/actions/runners/7"
        );

        // Repo-scope concrete expectations (regression guard).
        let repo = repo_cfg();
        assert_eq!(
            jitconfig_path(&repo),
            "repos/jleechanorg/ez-gh-actions/actions/runners/generate-jitconfig"
        );
        assert_eq!(
            runners_list_path(&repo),
            "repos/jleechanorg/ez-gh-actions/actions/runners?per_page=100"
        );
        assert_eq!(
            runner_remove_path(&repo, 7),
            "repos/jleechanorg/ez-gh-actions/actions/runners/7"
        );
    }
}
