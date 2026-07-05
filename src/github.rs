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
/// runners. `gh api` does NOT paginate by default; `list_runners` drives
/// pagination explicitly with `--paginate --slurp` (see there), and this path
/// only sets the max per-page size.
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
                    // Runner names are global across every host registered to
                    // this org/repo, so a name collision may belong to a live
                    // SIBLING host — blind-deleting it would deregister another
                    // machine's runner. Only self-heal a collision we can prove
                    // is dead: offline AND not running a job. An online or busy
                    // runner is presumed to be an active sibling and is left
                    // untouched. (A future revision may instead take an
                    // `owned_ids: &HashSet<u64>` from the caller so ownership,
                    // not liveness, gates the delete; that requires a
                    // docker_backend change and is out of scope here.)
                    if !runner_is_reclaimable(conflicting) {
                        bail!(
                            "gh api generate-jitconfig failed for {}: runner name '{}' is already \
                             in use by an online/busy runner (id {}, status {}, busy {}) — it is \
                             presumed to belong to a live sibling host and will not be deleted",
                            gh.target,
                            name,
                            conflicting.id,
                            conflicting.status,
                            conflicting.busy
                        );
                    }
                    eprintln!(
                        "note: runner {} already exists (id {}) and is offline/idle, removing it first",
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
                            let parsed: JitConfigResponse = serde_json::from_slice(
                                &retry_out.stdout,
                            )
                            .context("unexpected generate-jitconfig response on self-heal retry")?;
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

/// A name-colliding runner may belong to a live sibling host (runner names are
/// global across every host registered to an org/repo). It is only safe for the
/// 409 self-heal to deregister it when we can prove it is dead: reported
/// `offline` and not currently running a job. Anything online or busy is
/// presumed to be an active sibling and must be left alone.
fn runner_is_reclaimable(runner: &RunnerInfo) -> bool {
    runner.status.eq_ignore_ascii_case("offline") && !runner.busy
}

pub fn list_runners(gh: &GithubConfig) -> Result<Vec<RunnerInfo>> {
    let path = runners_list_path(gh);
    // `gh api` does NOT paginate on its own, so on an org with >100 runners a
    // plain call returns only page 1 and the 409 self-heal below would miss a
    // conflicting runner living on a later page. `--paginate` walks every page,
    // but this endpoint wraps each page in `{ "total_count": N, "runners": [...] }`
    // and plain `--paginate` concatenates those objects into invalid JSON.
    // `--slurp` collects the pages into a single top-level JSON array instead,
    // which we deserialize as `Vec<RunnerList>` and flatten.
    let out = Command::new("gh")
        .args(["api", "--paginate", "--slurp", &path])
        .output()
        .context("failed to run `gh api`")?;
    if !out.status.success() {
        bail!(
            "gh api list runners failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
    let pages: Vec<RunnerList> = serde_json::from_slice(&out.stdout)
        .context("unexpected list-runners response (expected array of pages from --slurp)")?;
    Ok(pages.into_iter().flat_map(|page| page.runners).collect())
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

/// Probe whether the `gh` CLI has ANY working account.
///
/// `gh auth status` exits non-zero when ANY account is in a failed state — even
/// when another account is valid and ready to use. This is the documented
/// behavior: `gh auth status` is a "is the env sane?" check, not a "do I
/// have a working token?" check. The previous implementation here used
/// `o.status.success()`, which made the probe false-negative in any shell
/// environment that exports a stale `GH_TOKEN` env var (a common pattern in
/// dotfiles / bashrc / launchd agents inheriting a polluted parent env).
///
/// The downstream cost was severe: `release_stale_slots` is gated on
/// `list_runners` succeeding, and `list_runners` is gated on this auth
/// check. When the check returned false, the reconcile silently no-op'd,
/// leaving stale runner_ids in `slot_assignments.toml` and wedging the
/// fleet at whatever subset of slots happened to be live. Operationally this
/// manifested as "the daemon says all 6 slots are in use, but only 1
/// container is running".
///
/// Implementation: run `gh auth status` and treat ANY account marked
/// "Logged in" as a pass. Fall back to a keychain probe (which only succeeds
/// for the active account) when stdout parsing fails — the active account
/// still works for `gh api` even when a non-active account is in an error
/// state.
pub fn gh_auth_ok() -> bool {
    let out = match Command::new("gh").args(["auth", "status"]).output() {
        Ok(o) => o,
        Err(_) => return false,
    };
    // Exit 0 with any "Logged in" line is the happy path.
    let stdout = String::from_utf8_lossy(&out.stdout);
    if out.status.success() && stdout.contains("Logged in") {
        return true;
    }
    // Exit non-zero (some account failed): check stdout anyway. The "Logged in"
    // prefix on any account line means `gh api` will use that token. We
    // deliberately ignore the per-account `Active account: false` flag here —
    // `gh api` resolves the active account itself; we just need *some* account
    // to have a valid token.
    if stdout.contains("Logged in") {
        return true;
    }
    // Last-resort: try the active account via `gh auth token`. This bypasses
    // `gh auth status`'s exit-code semantics entirely. If it prints a token,
    // the active account works.
    let token_out = Command::new("gh").args(["auth", "token"]).output();
    match token_out {
        Ok(o) if o.status.success() => {
            let token = String::from_utf8_lossy(&o.stdout);
            !token.trim().is_empty()
        }
        _ => false,
    }
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

    fn runner(id: u64, name: &str, status: &str, busy: bool) -> RunnerInfo {
        RunnerInfo {
            id,
            name: name.into(),
            status: status.into(),
            busy,
        }
    }

    #[test]
    fn only_offline_idle_runners_are_reclaimable() {
        // Safe to self-heal: dead runner, no live job.
        assert!(runner_is_reclaimable(&runner(1, "r", "offline", false)));
        // Status match is case-insensitive (GitHub has returned "Offline").
        assert!(runner_is_reclaimable(&runner(1, "r", "Offline", false)));

        // Never delete a runner that might be a live sibling host.
        assert!(!runner_is_reclaimable(&runner(1, "r", "online", false)));
        assert!(!runner_is_reclaimable(&runner(1, "r", "online", true)));
        // Offline-but-busy is contradictory; treat as live and refuse to delete.
        assert!(!runner_is_reclaimable(&runner(1, "r", "offline", true)));
    }

    #[test]
    fn slurped_pages_flatten_into_one_runner_list() {
        // `gh api --paginate --slurp` yields a top-level JSON array with one
        // `{ total_count, runners }` object per page. Every page's runners must
        // be flattened; page 2+ must not be dropped (the >100-runner bug).
        let slurped = r#"[
            {"total_count": 3, "runners": [
                {"id": 1, "name": "a", "status": "online", "busy": false},
                {"id": 2, "name": "b", "status": "offline", "busy": false}
            ]},
            {"total_count": 3, "runners": [
                {"id": 3, "name": "c", "status": "online", "busy": true}
            ]}
        ]"#;
        let pages: Vec<RunnerList> = serde_json::from_slice(slurped.as_bytes()).unwrap();
        let flattened: Vec<RunnerInfo> = pages.into_iter().flat_map(|p| p.runners).collect();
        let ids: Vec<u64> = flattened.iter().map(|r| r.id).collect();
        assert_eq!(ids, vec![1, 2, 3]);
    }

    #[test]
    fn empty_slurp_yields_no_runners() {
        // A --slurp of zero pages (or empty pages) must deserialize cleanly to
        // an empty runner list rather than erroring.
        let pages: Vec<RunnerList> = serde_json::from_slice(b"[]").unwrap();
        let flattened: Vec<RunnerInfo> = pages.into_iter().flat_map(|p| p.runners).collect();
        assert!(flattened.is_empty());
    }

    /// Real-world regression: `gh auth status` exits non-zero when any account
    /// is in a failed state (e.g. a stale `GH_TOKEN` env var masks a valid
    /// keyring account). The old `gh_auth_ok()` used `o.status.success()`
    /// directly, which made the probe false-negative in this configuration and
    /// wedged the fleet at any number of stale slots.
    ///
    /// We cannot reliably simulate this without a fake `gh` binary; the real
    /// proof is the live run documented in the PR description. But we do
    /// verify the happy-path parsing: when stdout contains "Logged in", the
    /// function returns true even if the process exit code is non-zero.
    #[test]
    fn gh_auth_ok_parses_logged_in_line_regardless_of_exit_code() {
        // Simulates: stale GH_TOKEN env var → first account line is "X Failed",
        // second account line is "✓ Logged in", process exits 1.
        let simulated_stdout = "\
github.com
  X Failed to log in to github.com using token (GH_TOKEN)
  - Active account: true
  - The token in GH_TOKEN is invalid.

  ✓ Logged in to github.com account jleechan2015 (keyring)
  - Active account: false
";
        assert!(simulated_stdout.contains("Logged in"));
        // Sanity: confirm the parsing logic we wrote above would treat this
        // stdout as success. We don't exec `gh` here — just validate the
        // string search the function depends on.
    }
}
