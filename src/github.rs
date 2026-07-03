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

/// Page size used when listing runners. The GitHub REST API caps
/// `per_page` at 100, so anything larger must come from subsequent pages.
const RUNNERS_PER_PAGE: usize = 100;

/// Defensive cap on pages fetched before we refuse to keep going. 100 pages
/// at 100 runners/page = 10_000 runners — well above any realistic org and
/// small enough to fail loudly on a misbehaving server.
const RUNNERS_MAX_PAGES: u32 = 100;

/// Parse one page of the runners API response into a `Vec<RunnerInfo>`.
///
/// Public-in-crate so unit tests can verify pagination concatenation with
/// canned JSON without invoking the `gh` CLI.
pub(crate) fn parse_runners_page(stdout: &[u8]) -> Result<Vec<RunnerInfo>> {
    let parsed: RunnerList =
        serde_json::from_slice(stdout).context("unexpected runners list response from gh api")?;
    Ok(parsed.runners)
}

/// Fetch a single page of runners. Page numbering starts at 1.
fn fetch_runners_page(gh: &GithubConfig, page: u32) -> Result<Vec<RunnerInfo>> {
    let path = format!(
        "{}/actions/runners?per_page={}&page={}",
        api_base(gh),
        RUNNERS_PER_PAGE,
        page
    );
    let out = Command::new("gh")
        .args(["api", &path])
        .output()
        .context("failed to run `gh api`")?;
    if !out.status.success() {
        bail!(
            "gh api list runners failed on page {page}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
    parse_runners_page(&out.stdout)
}

/// Inner pagination loop. Generic over the page-fetch closure so tests can
/// drive it with canned responses and a smaller `per_page` (matching their
/// fixture page sizes) without invoking the `gh` CLI.
///
/// Stops on the first empty page, the first short page, or after
/// `RUNNERS_MAX_PAGES` fetches — whichever comes first.
fn paginate<F>(mut fetch: F, per_page: usize) -> Result<Vec<RunnerInfo>>
where
    F: FnMut(u32) -> Result<Vec<RunnerInfo>>,
{
    let mut all = Vec::new();
    let mut page: u32 = 1;
    loop {
        let runners = fetch(page)?;
        if runners.is_empty() {
            break;
        }
        let fetched = runners.len();
        all.extend(runners);
        // Last page is signaled by a short page; requesting another would
        // either return [] or 422 (per_page*page > total). Stop early.
        if fetched < per_page {
            break;
        }
        page += 1;
        if page > RUNNERS_MAX_PAGES {
            bail!(
                "runners pagination exceeded {} pages — refusing to fetch more",
                RUNNERS_MAX_PAGES
            );
        }
    }
    Ok(all)
}

/// Fetch every registered runner for the configured scope.
///
/// GitHub returns at most 100 runners per page. Without pagination, an org
/// with > 100 runners would have its list silently truncated and any
/// subsequent `stop_all` would miss idle runners past page 1.
pub fn list_runners(gh: &GithubConfig) -> Result<Vec<RunnerInfo>> {
    paginate(|page| fetch_runners_page(gh, page), RUNNERS_PER_PAGE)
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

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a JSON page body of `count` runners with predictable ids/names.
    fn page_body(count: u32, prefix: &str) -> String {
        let mut s = String::from("{\"runners\":[");
        for i in 0..count {
            if i > 0 {
                s.push(',');
            }
            s.push_str(&format!(
                "{{\"id\":{},\"name\":\"{prefix}{i}\",\"status\":\"online\",\"busy\":false}}",
                i + 1
            ));
        }
        s.push_str("]}");
        s
    }

    #[test]
    fn parse_runners_page_deserializes_full_page() {
        let body = page_body(100, "r-");
        let runners = parse_runners_page(body.as_bytes()).expect("parse");
        assert_eq!(runners.len(), 100);
        assert_eq!(runners[0].id, 1);
        assert_eq!(runners[0].name, "r-0");
        assert_eq!(runners[99].id, 100);
        assert_eq!(runners[99].name, "r-99");
        assert!(!runners[0].busy);
    }

    #[test]
    fn parse_runners_page_handles_empty_array() {
        // GitHub returns {"runners":[]} once we ask past the last page.
        let body = "{\"runners\":[]}";
        let runners = parse_runners_page(body.as_bytes()).expect("parse");
        assert!(runners.is_empty());
    }

    #[test]
    fn parse_runners_page_rejects_malformed_json() {
        // Garbage input must surface as an error, not panic.
        let bad = b"{not json";
        assert!(parse_runners_page(bad).is_err());
    }

    /// Simulate the pagination loop in `list_runners` by feeding three
    /// canned pages (10 + 10 + 2) through `paginate` with a closure that
    /// returns the fixture body for each requested page. Verifies the
    /// totals concat correctly and the loop terminates on the short final
    /// page. We use `per_page = 10` here so the fixture's page sizes match
    /// the loop's short-page detector — the real call uses 100.
    #[test]
    fn list_runners_concatenates_pages_until_short_page() {
        let pages: Vec<Vec<u8>> = vec![
            page_body(10, "p1-").into_bytes(),
            page_body(10, "p2-").into_bytes(),
            page_body(2, "p3-").into_bytes(),
        ];
        let per_page: usize = 10;

        let mut call_idx: u32 = 0;
        let all = paginate(
            |_page| {
                let body = &pages[call_idx as usize];
                call_idx += 1;
                parse_runners_page(body)
            },
            per_page,
        )
        .expect("paginate");

        assert_eq!(
            call_idx, 3,
            "should have fetched exactly the 3 fixture pages"
        );
        assert_eq!(all.len(), 22);
        // Names embed the page prefix, so the concatenation order is
        // observable through `name` even though `id` resets per page in
        // the fixture (each page is its own independent API response).
        assert_eq!(all.first().unwrap().name, "p1-0");
        assert_eq!(all.first().unwrap().id, 1);
        assert_eq!(all.get(9).unwrap().name, "p1-9");
        assert_eq!(all.get(10).unwrap().name, "p2-0");
        assert_eq!(all.get(10).unwrap().id, 1);
        assert_eq!(all.get(20).unwrap().name, "p3-0");
        assert_eq!(all.get(20).unwrap().id, 1);
        assert_eq!(all.last().unwrap().name, "p3-1");
        assert_eq!(all.last().unwrap().id, 2);
    }

    /// Three full pages should keep the loop going past them all and only
    /// terminate when the server finally returns an empty page (the real
    /// GitHub API behavior once page * per_page > total).
    #[test]
    fn list_runners_terminates_on_empty_page_after_full_pages() {
        let pages: Vec<Vec<u8>> = vec![
            page_body(100, "f1-").into_bytes(),
            page_body(100, "f2-").into_bytes(),
            page_body(100, "f3-").into_bytes(),
            b"{\"runners\":[]}".to_vec(),
        ];

        let mut call_idx: u32 = 0;
        let all = paginate(
            |_page| {
                let body = &pages[call_idx as usize];
                call_idx += 1;
                parse_runners_page(body)
            },
            RUNNERS_PER_PAGE,
        )
        .expect("paginate");

        assert_eq!(
            call_idx, 4,
            "should fetch the 3 full pages plus the empty terminator"
        );
        assert_eq!(all.len(), 300);
        assert_eq!(all.first().unwrap().name, "f1-0");
        assert_eq!(all.last().unwrap().name, "f3-99");
    }

    /// Defensive cap test: a misbehaving server returning a full page
    /// forever should be refused, not looped indefinitely.
    #[test]
    fn paginate_refuses_to_loop_forever_on_infinite_full_pages() {
        // 200 full pages of 100 runners each = 20_000 runners, exceeding the
        // RUNNERS_MAX_PAGES cap. The cap should fire and bail.
        let mut call_idx: u32 = 0;
        let result = paginate(
            |_page| {
                call_idx += 1;
                parse_runners_page(page_body(RUNNERS_PER_PAGE as u32, "x-").as_bytes())
            },
            RUNNERS_PER_PAGE,
        );
        assert!(
            result.is_err(),
            "infinite pagination must surface as an error"
        );
        let err = format!("{}", result.unwrap_err());
        assert!(
            err.contains("pagination exceeded"),
            "error must mention pagination cap, got: {err}"
        );
        assert!(call_idx <= RUNNERS_MAX_PAGES + 1);
    }
}
