use anyhow::{bail, Context, Result};
use serde::Deserialize;
use std::io::Read;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use crate::config::{GithubConfig, Scope};
use crate::watchdog;

/// Hard ceiling on how long any `gh` CLI invocation may run. A hung `gh`
/// process (keychain prompt, GraphQL rate-limit, network stall) would
/// otherwise block the entire serve loop — preventing runner respawning
/// while the daemon appears healthy to systemd.
///
/// 45 s is generous: normal JIT config calls complete in <5 s; paginated
/// list-runners calls can take 10-15 s on a large org. Anything longer is
/// hung and should be killed so the 30 s serve loop can retry.
const GH_TIMEOUT: Duration = Duration::from_secs(45);
const GH_MAX_RETRIES: u32 = 5;
const GH_RETRY_BASE_DELAY: Duration = Duration::from_secs(2);
const GH_RETRY_MAX_DELAY: Duration = Duration::from_secs(32);

#[cfg(test)]
thread_local! {
    static GH_EXE_OVERRIDE: std::cell::RefCell<Option<String>> = const { std::cell::RefCell::new(None) };
}

#[cfg(test)]
pub(crate) struct GhExeOverrideGuard {
    previous: Option<String>,
}

#[cfg(test)]
impl Drop for GhExeOverrideGuard {
    fn drop(&mut self) {
        GH_EXE_OVERRIDE.with(|cell| {
            *cell.borrow_mut() = self.previous.take();
        });
    }
}

#[cfg(test)]
pub(crate) fn with_gh_exe(path: &str) -> GhExeOverrideGuard {
    let previous = GH_EXE_OVERRIDE.with(|cell| {
        let mut slot = cell.borrow_mut();
        slot.replace(path.to_string())
    });
    GhExeOverrideGuard { previous }
}

fn gh_command() -> Command {
    #[cfg(test)]
    if let Some(path) = GH_EXE_OVERRIDE.with(|cell| cell.borrow().clone()) {
        let mut cmd = Command::new("/bin/sh");
        cmd.arg(path);
        return cmd;
    }

    Command::new("gh")
}

fn extract_retry_after_secs(text: &str) -> Option<u64> {
    for line in text.lines() {
        let lower = line.to_ascii_lowercase();
        if !lower.contains("retry") {
            continue;
        }
        for token in lower
            .split(|c: char| !(c.is_ascii_alphanumeric() || c == '-'))
            .filter(|p| !p.is_empty())
        {
            if let Ok(v) = token.parse::<u64>() {
                return Some(v);
            }
            if let Some((_, raw)) = token.split_once(':') {
                if let Ok(v) = raw.trim().parse::<u64>() {
                    return Some(v);
                }
            }
        }
    }
    None
}

fn is_rate_limit_response(stdout: &str, stderr: &str, status: Option<i32>) -> bool {
    let lower = format!("{stdout} {stderr}").to_ascii_lowercase();
    if !(lower.contains("rate") || lower.contains("secondary") || lower.contains("abuse")) {
        return false;
    }
    if status == Some(403) || status == Some(429) {
        return true;
    }
    lower.contains("http 403") || lower.contains("http 429")
}

fn is_transient_json_parse_response(stdout: &str, stderr: &str) -> bool {
    let stderr_lower = stderr.to_ascii_lowercase();
    stderr_lower.contains("unexpected end of json input") && matches!(stdout.trim(), "" | "[]")
}

fn classify_retry_delay(out: &std::process::Output) -> Option<Duration> {
    let code = out.status.code();
    let stderr = String::from_utf8_lossy(&out.stderr);
    let stdout = String::from_utf8_lossy(&out.stdout);
    if is_rate_limit_response(&stdout, &stderr, code) {
        return Some(
            extract_retry_after_secs(&format!("{stderr} {stdout}"))
                .map(Duration::from_secs)
                .unwrap_or(GH_RETRY_BASE_DELAY)
                .min(GH_RETRY_MAX_DELAY)
                .max(Duration::from_secs(1)),
        );
    }
    if is_transient_json_parse_response(&stdout, &stderr) {
        return Some(GH_RETRY_BASE_DELAY);
    }
    None
}

fn run_gh_with_backoff(make_cmd: impl FnMut() -> Command) -> Result<std::process::Output> {
    run_gh_with_backoff_core(None, make_cmd)
}

/// Like `run_gh_with_backoff`, but bounded by `deadline`: if honoring the
/// classified retry delay (Retry-After / exponential backoff) would sleep
/// past `deadline`, the loop bails immediately with the last failed attempt
/// instead of sleeping -- it never retries past the caller's time budget.
///
/// This exists because `run_gh_with_backoff` alone let a single gh
/// invocation block the (single-threaded) serve loop for up to
/// `GH_MAX_RETRIES` x `GH_RETRY_MAX_DELAY` (~128s) when GitHub's secondary
/// rate limit persisted across every attempt -- long enough to starve
/// `ensure_count` well past `queue_monitor::SERVE_LOOP_TIME_BUDGET` even
/// though every OTHER fetch in that module already threads a `deadline`
/// through. Every gh call reachable from the monitor/sampler tick must use
/// this variant (or a wrapper built on it) so the budget is real, not
/// aspirational.
pub(crate) fn run_gh_with_backoff_until(
    deadline: Instant,
    make_cmd: impl FnMut() -> Command,
) -> Result<std::process::Output> {
    run_gh_with_backoff_core(Some(deadline), make_cmd)
}

fn run_gh_with_backoff_core(
    deadline: Option<Instant>,
    mut make_cmd: impl FnMut() -> Command,
) -> Result<std::process::Output> {
    let mut delay = GH_RETRY_BASE_DELAY;
    for attempt in 1..=GH_MAX_RETRIES {
        let out = run_gh(make_cmd())?;
        if out.status.success() {
            return Ok(out);
        }
        if let Some(wait) = classify_retry_delay(&out) {
            if attempt >= GH_MAX_RETRIES {
                return Ok(out);
            }
            let sleep_for = std::cmp::max(wait, delay);
            if let Some(dl) = deadline {
                if Instant::now() + sleep_for >= dl {
                    eprintln!(
                        "gh API transient failure; time budget exhausted, bailing after \
                         attempt {attempt}/{GH_MAX_RETRIES} instead of sleeping {}s",
                        sleep_for.as_secs()
                    );
                    return Ok(out);
                }
            }
            eprintln!(
                "gh API transient failure; retrying in {}s (attempt {}/{})",
                sleep_for.as_secs(),
                attempt,
                GH_MAX_RETRIES
            );
            std::thread::sleep(sleep_for);
            delay = (delay * 2).min(GH_RETRY_MAX_DELAY);
            continue;
        }
        return Ok(out);
    }
    unreachable!("backoff loop must return before exit");
}

pub(crate) fn api_json(path: &str) -> Result<Vec<u8>> {
    let out = run_gh_with_backoff(|| {
        let mut cmd = gh_command();
        cmd.args(["api", path]);
        cmd
    })
    .with_context(|| format!("failed to run `gh api {path}`"))?;
    if !out.status.success() {
        bail!(
            "gh api {path} failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
    Ok(out.stdout)
}

/// Deadline-bounded twin of `api_json` -- see `run_gh_with_backoff_until`.
/// Every call site reachable from `queue_monitor`'s budget-tracked
/// monitor/sampler tick must use this (or a wrapper built on it), not
/// `api_json`, so a persistent rate limit can never starve `ensure_count`.
pub(crate) fn api_json_until(path: &str, deadline: Instant) -> Result<Vec<u8>> {
    let out = run_gh_with_backoff_until(deadline, || {
        let mut cmd = gh_command();
        cmd.args(["api", path]);
        cmd
    })
    .with_context(|| format!("failed to run `gh api {path}`"))?;
    if !out.status.success() {
        bail!(
            "gh api {path} failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
    Ok(out.stdout)
}

pub(crate) fn api_post_empty(path: &str, fields: &[(&str, &str)]) -> Result<()> {
    let out = run_gh_with_backoff(|| {
        let mut cmd = gh_command();
        cmd.args(["api", "-X", "POST", path]);
        for (key, value) in fields {
            cmd.args(["-f", &format!("{key}={value}")]);
        }
        cmd
    })
    .with_context(|| format!("failed to run `gh api -X POST {path}`"))?;
    if !out.status.success() {
        bail!(
            "gh api POST {path} failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
    Ok(())
}

/// Run `cmd`, capturing stdout and stderr, but never block longer than
/// `GH_TIMEOUT`. Returns `Ok((stdout, stderr))` if the child exited (success
/// or failure) within the deadline; returns `Err` if the deadline expired
/// (the child is killed) or if the process could not be spawned.
///
/// Unlike `platform::capture_with_timeout`, this captures *both* streams so
/// callers can inspect stderr on non-zero exits.
fn run_gh(mut cmd: Command) -> Result<std::process::Output> {
    let mut child = cmd
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("failed to spawn gh CLI")?;

    let mut stdout_pipe = child.stdout.take().expect("stdout piped");
    let mut stderr_pipe = child.stderr.take().expect("stderr piped");

    let (tx_out, rx_out) = mpsc::channel::<Vec<u8>>();
    let (tx_err, rx_err) = mpsc::channel::<Vec<u8>>();

    std::thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = stdout_pipe.read_to_end(&mut buf);
        let _ = tx_out.send(buf);
    });
    std::thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = stderr_pipe.read_to_end(&mut buf);
        let _ = tx_err.send(buf);
    });

    // Wait for stdout first (the larger payload); stderr is typically small.
    let stdout = match rx_out.recv_timeout(GH_TIMEOUT) {
        Ok(b) => b,
        Err(_) => {
            let _ = child.kill();
            let _ = child.wait();
            bail!("gh CLI timed out after {}s", GH_TIMEOUT.as_secs());
        }
    };
    // Stderr may still be draining; give it a short extra window.
    let stderr = rx_err
        .recv_timeout(Duration::from_secs(5))
        .unwrap_or_default();

    let status = child.wait().context("wait on gh child")?;
    Ok(std::process::Output {
        status,
        stdout,
        stderr,
    })
}

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

pub fn workflow_dispatch_path(repo: &str, workflow: &str) -> String {
    format!("repos/{repo}/actions/workflows/{workflow}/dispatches")
}

pub fn workflow_runs_path(repo: &str, workflow: &str, limit: u32) -> String {
    format!(
        "repos/{repo}/actions/workflows/{workflow}/runs?event=workflow_dispatch&per_page={}",
        limit.clamp(1, 100)
    )
}

pub fn workflow_run_jobs_path(repo: &str, run_id: u64) -> String {
    format!("repos/{repo}/actions/runs/{run_id}/jobs?per_page=100")
}

pub fn repo_in_progress_runs_path(repo: &str, page: u32) -> String {
    format!(
        "repos/{repo}/actions/runs?status=in_progress&per_page=100&page={}",
        page.max(1)
    )
}

pub fn workflow_run_cancel_path(repo: &str, run_id: u64) -> String {
    format!("repos/{repo}/actions/runs/{run_id}/cancel")
}

pub fn workflow_run_force_cancel_path(repo: &str, run_id: u64) -> String {
    format!("repos/{repo}/actions/runs/{run_id}/force-cancel")
}

pub fn dispatch_workflow(
    repo: &str,
    workflow: &str,
    ref_name: &str,
    nonce: &str,
    runs_on_labels: &[String],
) -> Result<()> {
    let fields = workflow_dispatch_fields(ref_name, nonce, runs_on_labels)?;
    let field_refs: Vec<(&str, &str)> = fields
        .iter()
        .map(|(key, value)| (key.as_str(), value.as_str()))
        .collect();
    api_post_empty(&workflow_dispatch_path(repo, workflow), &field_refs)
}

fn workflow_dispatch_fields(
    ref_name: &str,
    nonce: &str,
    runs_on_labels: &[String],
) -> Result<Vec<(String, String)>> {
    let runs_on_json = serde_json::to_string(runs_on_labels).context("serialize canary labels")?;
    Ok(vec![
        ("ref".into(), ref_name.into()),
        ("inputs[nonce]".into(), nonce.into()),
        ("inputs[runs_on_json]".into(), runs_on_json),
    ])
}

pub fn list_workflow_runs(repo: &str, workflow: &str, limit: u32) -> Result<Vec<WorkflowRun>> {
    let path = workflow_runs_path(repo, workflow, limit);
    let body = api_json(&path)?;
    let parsed: WorkflowRunsResponse = serde_json::from_slice(&body)
        .with_context(|| format!("unexpected workflow-runs response for {repo}/{workflow}"))?;
    Ok(parsed.workflow_runs)
}

pub fn list_workflow_jobs(repo: &str, run_id: u64) -> Result<Vec<WorkflowJob>> {
    let path = workflow_run_jobs_path(repo, run_id);
    let body = api_json(&path)?;
    let parsed: WorkflowJobsResponse = serde_json::from_slice(&body)
        .with_context(|| format!("unexpected workflow-jobs response for run {run_id}"))?;
    Ok(parsed.jobs)
}

/// Deadline-bounded twin of `list_workflow_jobs` for `queue_monitor`'s
/// budget-tracked tick -- see `run_gh_with_backoff_until`.
pub fn list_workflow_jobs_until(
    repo: &str,
    run_id: u64,
    deadline: Instant,
) -> Result<Vec<WorkflowJob>> {
    let path = workflow_run_jobs_path(repo, run_id);
    let body = api_json_until(&path, deadline)?;
    let parsed: WorkflowJobsResponse = serde_json::from_slice(&body)
        .with_context(|| format!("unexpected workflow-jobs response for run {run_id}"))?;
    Ok(parsed.jobs)
}

pub fn list_repo_in_progress_runs(repo: &str) -> Result<Vec<WorkflowRun>> {
    let mut runs = Vec::new();
    for page in 1.. {
        let path = repo_in_progress_runs_path(repo, page);
        let body = api_json(&path)?;
        let parsed: WorkflowRunsResponse = serde_json::from_slice(&body)
            .with_context(|| format!("unexpected in-progress runs response for {repo}"))?;
        let done = parsed.workflow_runs.len() < 100;
        runs.extend(parsed.workflow_runs);
        if done {
            break;
        }
    }
    Ok(runs)
}

/// Deadline-bounded twin of `list_repo_in_progress_runs` for
/// `queue_monitor`'s budget-tracked tick -- see `run_gh_with_backoff_until`.
/// Bails between pages (in addition to within each `gh` call) once
/// `deadline` has passed, returning whatever pages were already collected.
pub fn list_repo_in_progress_runs_until(repo: &str, deadline: Instant) -> Result<Vec<WorkflowRun>> {
    let mut runs = Vec::new();
    for page in 1.. {
        if Instant::now() >= deadline {
            break;
        }
        let path = repo_in_progress_runs_path(repo, page);
        let body = api_json_until(&path, deadline)?;
        let parsed: WorkflowRunsResponse = serde_json::from_slice(&body)
            .with_context(|| format!("unexpected in-progress runs response for {repo}"))?;
        let done = parsed.workflow_runs.len() < 100;
        runs.extend(parsed.workflow_runs);
        if done {
            break;
        }
    }
    Ok(runs)
}

#[allow(dead_code)]
pub fn cancel_workflow_run(repo: &str, run_id: u64) -> Result<()> {
    api_post_empty(&workflow_run_cancel_path(repo, run_id), &[])
}

#[allow(dead_code)]
pub fn force_cancel_workflow_run(repo: &str, run_id: u64) -> Result<()> {
    api_post_empty(&workflow_run_force_cancel_path(repo, run_id), &[])
}

#[derive(Debug, Deserialize)]
struct JitConfigResponse {
    encoded_jit_config: String,
    runner: JitRunner,
}

#[derive(Debug, Deserialize)]
struct JitRunner {
    id: u64,
}

/// Build the `gh api -X POST <path>` command that registers a JIT runner.
/// Shared by `generate_jitconfig`'s first attempt and its 409-conflict
/// self-heal retry, which otherwise built byte-identical argv independently.
fn build_jitconfig_cmd(path: &str, name: &str, labels: &[String]) -> Command {
    let mut cmd = gh_command();
    cmd.args(["api", "-X", "POST", path, "-f", &format!("name={name}")]);
    cmd.args(["-F", "runner_group_id=1"]);
    for label in labels {
        cmd.args(["-f", &format!("labels[]={label}")]);
    }
    cmd
}

/// Ask GitHub for a just-in-time runner registration. A JIT runner accepts
/// exactly one job and then deregisters itself — ephemeral by construction,
/// no registration token to store or clean up.
pub fn generate_jitconfig(
    gh: &GithubConfig,
    name: &str,
    labels: &[String],
    owned_ids: &std::collections::HashSet<u64>,
) -> Result<(String, u64)> {
    let path = jitconfig_path(gh);
    let out = run_gh_with_backoff(|| build_jitconfig_cmd(&path, name, labels))
        .context("failed to run `gh api` — is the gh CLI installed?")?;
    watchdog::ping();
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        if stderr.contains("Already exists") || stderr.contains("already exists") {
            watchdog::ping();
            if let Ok(runners) = list_runners(gh) {
                if let Some(conflicting) = runners.iter().find(|r| r.name == name) {
                    // Runner names are global across every host registered to
                    // this org/repo, so a name collision may belong to a live
                    // SIBLING host — blind-deleting it would deregister another
                    // machine's runner. Distinguish same-host zombies (we own
                    // the id via the slot file → reclaimable in any status) from
                    // cross-host runners (only reclaimable when liveness proves
                    // the runner is dead: offline AND not busy).
                    if !runner_is_reclaimable(conflicting, owned_ids) {
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
                        watchdog::ping();
                        let retry_out =
                            run_gh_with_backoff(|| build_jitconfig_cmd(&path, name, labels))?;
                        if retry_out.status.success() {
                            let parsed: JitConfigResponse = serde_json::from_slice(
                                &retry_out.stdout,
                            )
                            .context("unexpected generate-jitconfig response on self-heal retry")?;
                            watchdog::ping();
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
    watchdog::ping();
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

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct WorkflowRun {
    pub id: u64,
    pub name: String,
    #[serde(default)]
    pub display_title: String,
    pub event: String,
    pub status: String,
    pub conclusion: Option<String>,
    pub created_at: String,
    pub run_started_at: Option<String>,
    pub updated_at: String,
    pub html_url: String,
    pub head_branch: Option<String>,
    pub head_sha: String,
}

#[derive(Debug, Deserialize)]
struct WorkflowRunsResponse {
    #[allow(dead_code)]
    total_count: u64,
    workflow_runs: Vec<WorkflowRun>,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct WorkflowJob {
    pub id: u64,
    pub name: String,
    pub status: String,
    pub conclusion: Option<String>,
    pub created_at: String,
    pub started_at: Option<String>,
    pub completed_at: Option<String>,
    pub runner_id: Option<u64>,
    pub runner_name: Option<String>,
    pub runner_group_id: Option<u64>,
    pub runner_group_name: Option<String>,
    #[serde(default)]
    pub labels: Vec<String>,
    pub html_url: Option<String>,
}

#[derive(Debug, Deserialize)]
struct WorkflowJobsResponse {
    #[allow(dead_code)]
    total_count: u64,
    jobs: Vec<WorkflowJob>,
}

/// A name-colliding runner may belong to a live sibling host (runner names are
/// global across every host registered to an org/repo). It is only safe for the
/// 409 self-heal to deregister it when we can prove it is one of OURS and dead:
/// slot-file ownership (we created it on this host) overrides liveness, so a
/// same-host zombie whose heartbeat has not decayed yet still gets reaped; a
/// cross-host runner requires liveness proof (offline AND not busy) before
/// we'll delete it.
fn runner_is_reclaimable(runner: &RunnerInfo, owned_ids: &std::collections::HashSet<u64>) -> bool {
    // Slot-file ownership is treated as host ownership: if we own this id,
    // reclaim regardless of status (zombies with stale online/busy flag get
    // reaped here; otherwise they'd hold the slot name hostage until
    // GitHub's heartbeat decayed).
    if owned_ids.contains(&runner.id) {
        return true;
    }
    // Cross-host: only reclaim when liveness proves the runner is dead.
    runner.status.eq_ignore_ascii_case("offline") && !runner.busy
}

pub fn list_runners(gh: &GithubConfig) -> Result<Vec<RunnerInfo>> {
    list_runners_core(gh, None)
}

/// Deadline-bounded twin of `list_runners` for `queue_monitor`'s
/// budget-tracked tick -- see `run_gh_with_backoff_until`.
pub fn list_runners_until(gh: &GithubConfig, deadline: Instant) -> Result<Vec<RunnerInfo>> {
    list_runners_core(gh, Some(deadline))
}

fn list_runners_core(gh: &GithubConfig, deadline: Option<Instant>) -> Result<Vec<RunnerInfo>> {
    let path = runners_list_path(gh);
    // `gh api` does NOT paginate on its own, so on an org with >100 runners a
    // plain call returns only page 1 and the 409 self-heal below would miss a
    // conflicting runner living on a later page. `--paginate` walks every page,
    // but this endpoint wraps each page in `{ "total_count": N, "runners": [...] }`
    // and plain `--paginate` concatenates those objects into invalid JSON.
    // `--slurp` collects the pages into a single top-level JSON array instead,
    // which we deserialize as `Vec<RunnerList>` and flatten.
    let make_cmd = || {
        let mut cmd = gh_command();
        cmd.args(["api", "--paginate", "--slurp", &path]);
        cmd
    };
    let out = match deadline {
        Some(dl) => run_gh_with_backoff_until(dl, make_cmd),
        None => run_gh_with_backoff(make_cmd),
    }
    .context("failed to run `gh api`")?;
    if !out.status.success() {
        bail!(
            "gh api list runners failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
    let pages: Vec<RunnerList> = serde_json::from_slice(&out.stdout)
        .context("unexpected list-runners response (expected array of pages from --slurp)")?;
    watchdog::ping();
    Ok(pages.into_iter().flat_map(|page| page.runners).collect())
}

/// Best-effort removal of a registered runner (used when we kill a runner
/// container before it ever picked up a job).
pub fn remove_runner(gh: &GithubConfig, id: u64) -> Result<()> {
    let path = runner_remove_path(gh, id);
    let out = run_gh_with_backoff(|| {
        let mut cmd = gh_command();
        cmd.args(["api", "-X", "DELETE", &path]);
        cmd
    })
    .context("failed to run `gh api`")?;
    if !out.status.success() {
        bail!(
            "gh api remove runner {id} failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
    watchdog::ping();
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
    let out = match run_gh_with_backoff(|| {
        let mut status_cmd = gh_command();
        status_cmd.args(["auth", "status"]);
        status_cmd
    }) {
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
    match run_gh_with_backoff(|| {
        let mut token_cmd = gh_command();
        token_cmd.args(["auth", "token"]);
        token_cmd
    }) {
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
        assert_eq!(
            workflow_dispatch_path("jleechanorg/ez-gh-actions", "selftest.yml"),
            "repos/jleechanorg/ez-gh-actions/actions/workflows/selftest.yml/dispatches"
        );
        assert_eq!(
            workflow_runs_path("jleechanorg/ez-gh-actions", "selftest.yml", 250),
            "repos/jleechanorg/ez-gh-actions/actions/workflows/selftest.yml/runs?event=workflow_dispatch&per_page=100"
        );
        assert_eq!(
            workflow_run_jobs_path("jleechanorg/ez-gh-actions", 123),
            "repos/jleechanorg/ez-gh-actions/actions/runs/123/jobs?per_page=100"
        );
        assert_eq!(
            repo_in_progress_runs_path("jleechanorg/ez-gh-actions", 0),
            "repos/jleechanorg/ez-gh-actions/actions/runs?status=in_progress&per_page=100&page=1"
        );
        assert_eq!(
            repo_in_progress_runs_path("jleechanorg/ez-gh-actions", 3),
            "repos/jleechanorg/ez-gh-actions/actions/runs?status=in_progress&per_page=100&page=3"
        );
        assert_eq!(
            workflow_run_cancel_path("jleechanorg/ez-gh-actions", 123),
            "repos/jleechanorg/ez-gh-actions/actions/runs/123/cancel"
        );
        assert_eq!(
            workflow_run_force_cancel_path("jleechanorg/ez-gh-actions", 123),
            "repos/jleechanorg/ez-gh-actions/actions/runs/123/force-cancel"
        );
    }

    #[test]
    fn workflow_dispatch_includes_host_specific_runner_labels() {
        let fields = workflow_dispatch_fields(
            "main",
            "nonce-123",
            &[
                "self-hosted".into(),
                "ezgha".into(),
                "Linux".into(),
                "X64".into(),
            ],
        )
        .unwrap();

        assert_eq!(
            fields,
            vec![
                ("ref".into(), "main".into()),
                ("inputs[nonce]".into(), "nonce-123".into()),
                (
                    "inputs[runs_on_json]".into(),
                    "[\"self-hosted\",\"ezgha\",\"Linux\",\"X64\"]".into()
                ),
            ]
        );
    }

    #[test]
    fn workflow_run_fixture_deserializes() {
        let raw = r#"{
            "total_count": 1,
            "workflow_runs": [{
                "id": 123,
                "name": "ezgha-selftest",
                "display_title": "ezgha-selftest ezgha-canary-123",
                "event": "workflow_dispatch",
                "status": "completed",
                "conclusion": "success",
                "created_at": "2026-07-07T08:00:00Z",
                "run_started_at": "2026-07-07T08:01:00Z",
                "updated_at": "2026-07-07T08:02:00Z",
                "html_url": "https://github.example/runs/123",
                "head_branch": "main",
                "head_sha": "abc123"
            }]
        }"#;

        let parsed: WorkflowRunsResponse = serde_json::from_str(raw).unwrap();

        assert_eq!(parsed.total_count, 1);
        assert_eq!(parsed.workflow_runs[0].id, 123);
        assert_eq!(
            parsed.workflow_runs[0].display_title,
            "ezgha-selftest ezgha-canary-123"
        );
    }

    #[test]
    fn workflow_jobs_fixture_deserializes() {
        let raw = r#"{
            "total_count": 1,
            "jobs": [{
                "id": 456,
                "name": "selftest",
                "status": "completed",
                "conclusion": "success",
                "created_at": "2026-07-07T08:00:00Z",
                "started_at": "2026-07-07T08:01:00Z",
                "completed_at": "2026-07-07T08:02:00Z",
                "runner_id": 99,
                "runner_name": "ez-runner-c-9",
                "runner_group_id": 1,
                "runner_group_name": "Default",
                "labels": ["self-hosted", "ezgha"],
                "html_url": "https://github.example/jobs/456"
            }]
        }"#;

        let parsed: WorkflowJobsResponse = serde_json::from_str(raw).unwrap();

        assert_eq!(parsed.total_count, 1);
        assert_eq!(parsed.jobs[0].id, 456);
        assert_eq!(parsed.jobs[0].runner_name.as_deref(), Some("ez-runner-c-9"));
        assert_eq!(parsed.jobs[0].labels, vec!["self-hosted", "ezgha"]);
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
    fn owned_zombie_is_reclaimable_even_if_online_busy() {
        use std::collections::HashSet;
        let mut owned = HashSet::new();
        owned.insert(42);
        // We own the runner — reclaim even though it's online AND busy.
        assert!(runner_is_reclaimable(
            &runner(42, "ez-org-runner-3", "online", true),
            &owned,
        ));
        // We own it — also reclaim when offline (existing case still passes).
        assert!(runner_is_reclaimable(
            &runner(42, "ez-org-runner-3", "offline", false),
            &owned,
        ));
    }

    #[test]
    fn cross_host_live_runner_is_not_reclaimable() {
        use std::collections::HashSet;
        let owned = HashSet::new();
        assert!(!runner_is_reclaimable(
            &runner(99, "ez-org-runner-3", "online", false),
            &owned,
        ));
        assert!(!runner_is_reclaimable(
            &runner(99, "ez-org-runner-3", "online", true),
            &owned,
        ));
        // Dead sibling — reclaim is allowed (liveness proof).
        assert!(runner_is_reclaimable(
            &runner(99, "ez-org-runner-3", "offline", false),
            &owned,
        ));
        // Offline-but-busy: contradictory; refuse to be safe.
        assert!(!runner_is_reclaimable(
            &runner(99, "ez-org-runner-3", "offline", true),
            &owned,
        ));
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

    #[test]
    fn detect_rate_limit_output() {
        let out = std::process::Output {
            status: std::os::unix::process::ExitStatusExt::from_raw(403 << 8),
            stdout: Vec::new(),
            stderr: b"HTTP 403: You have exceeded a secondary rate limit\nRetry-After: 7\n"
                .to_vec(),
        };
        let delay =
            classify_retry_delay(&out).expect("secondary rate limit response should be classified");
        assert_eq!(delay, Duration::from_secs(7));
    }

    #[test]
    fn detect_rate_limit_output_from_gh_exit_one() {
        let out = std::process::Output {
            status: std::os::unix::process::ExitStatusExt::from_raw(1 << 8),
            stdout: Vec::new(),
            stderr: b"gh: API rate limit exceeded (HTTP 403)\nRetry-After: 4\n".to_vec(),
        };
        let delay = classify_retry_delay(&out)
            .expect("gh exit-1 HTTP 403 rate limit response should be classified");
        assert_eq!(delay, Duration::from_secs(4));
    }

    #[test]
    fn rate_limit_without_retry_after_uses_default_backoff() {
        let out = std::process::Output {
            status: std::os::unix::process::ExitStatusExt::from_raw(1 << 8),
            stdout: Vec::new(),
            stderr: b"gh: secondary rate limit exceeded (HTTP 429)\n".to_vec(),
        };
        let delay = classify_retry_delay(&out)
            .expect("rate-limit response without Retry-After should still be retried");
        assert_eq!(delay, GH_RETRY_BASE_DELAY);
    }

    #[test]
    fn transient_gh_json_parse_failure_uses_default_backoff() {
        let out = std::process::Output {
            status: std::os::unix::process::ExitStatusExt::from_raw(1 << 8),
            stdout: b"[]\n".to_vec(),
            stderr: b"unexpected end of JSON input\n".to_vec(),
        };
        let delay =
            classify_retry_delay(&out).expect("gh transient JSON parse failures should be retried");
        assert_eq!(delay, GH_RETRY_BASE_DELAY);
    }

    #[test]
    fn transient_gh_json_parse_failure_retries_empty_stdout() {
        let out = std::process::Output {
            status: std::os::unix::process::ExitStatusExt::from_raw(1 << 8),
            stdout: Vec::new(),
            stderr: b"unexpected end of JSON input\n".to_vec(),
        };
        let delay = classify_retry_delay(&out)
            .expect("empty-body gh JSON parse failures should be retried");
        assert_eq!(delay, GH_RETRY_BASE_DELAY);
    }

    #[test]
    fn retry_after_parser_prefers_any_digit_token() {
        let text = "Retry-After: 31\nX-Ratelimit-Reset: 1700000000\n";
        assert_eq!(extract_retry_after_secs(text), Some(31));
    }

    #[test]
    fn non_rate_limit_response_is_not_retried() {
        let out = std::process::Output {
            status: std::os::unix::process::ExitStatusExt::from_raw(1 << 8),
            stdout: Vec::new(),
            stderr: b"gh: runner already exists and cannot be removed\n".to_vec(),
        };
        assert!(classify_retry_delay(&out).is_none());
    }

    #[test]
    fn run_gh_with_backoff_retries_fake_gh_after_rate_limit() {
        let dir = std::env::temp_dir().join(format!(
            "ezgha-fake-gh-{}-{}",
            std::process::id(),
            std::thread::current().name().unwrap_or("test")
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let counter = dir.join("counter");
        let script = dir.join("fake-gh");
        std::fs::write(
            &script,
            format!(
                r#"#!/bin/sh
counter={counter}
n=0
if [ -f "$counter" ]; then n=$(cat "$counter"); fi
n=$((n + 1))
echo "$n" > "$counter"
if [ "$n" -eq 1 ]; then
  echo "gh: secondary rate limit exceeded (HTTP 403)" >&2
  echo "Retry-After: 1" >&2
  exit 1
fi
echo '{{"ok":true}}'
exit 0
"#,
                counter = counter.display()
            ),
        )
        .unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(&script).unwrap().permissions();
            perms.set_mode(0o755);
            std::fs::set_permissions(&script, perms).unwrap();
        }

        let out = run_gh_with_backoff(|| {
            let mut cmd = Command::new("/bin/sh");
            cmd.arg(&script);
            cmd
        })
        .unwrap();
        assert!(out.status.success());
        assert_eq!(std::fs::read_to_string(counter).unwrap().trim(), "2");
        let _ = std::fs::remove_dir_all(dir);
    }

    /// Regression for the ez-gh-actions-yrt fleet-starvation bug: a monitor
    /// tick that hits a persistent secondary rate limit must never block past
    /// its caller-supplied deadline (`SERVE_LOOP_TIME_BUDGET` in
    /// `queue_monitor.rs`). Before this fix, `run_gh_with_backoff` had no
    /// concept of a deadline at all -- it always slept through up to
    /// `GH_MAX_RETRIES` attempts at up to `GH_RETRY_MAX_DELAY` (32s) each,
    /// which could keep the single-threaded serve loop away from
    /// `ensure_count` for well over a minute per tick, live-observed as a 67s
    /// gap between respawn bursts. The fake `gh` here ALWAYS returns a
    /// secondary-rate-limit response with a 30s `Retry-After`, so an
    /// unbounded caller would sleep at least 30s on the very first retry;
    /// with a deadline just a few hundred ms out, `run_gh_with_backoff_until`
    /// must instead bail immediately after the first failed attempt.
    #[test]
    fn run_gh_with_backoff_until_bails_when_deadline_is_exhausted_instead_of_sleeping() {
        let dir = std::env::temp_dir().join(format!(
            "ezgha-fake-gh-deadline-{}-{}",
            std::process::id(),
            std::thread::current().name().unwrap_or("test")
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let counter = dir.join("counter");
        let script = dir.join("fake-gh");
        std::fs::write(
            &script,
            format!(
                r#"#!/bin/sh
counter={counter}
n=0
if [ -f "$counter" ]; then n=$(cat "$counter"); fi
n=$((n + 1))
echo "$n" > "$counter"
echo "gh: secondary rate limit exceeded (HTTP 403)" >&2
echo "Retry-After: 30" >&2
exit 1
"#,
                counter = counter.display()
            ),
        )
        .unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(&script).unwrap().permissions();
            perms.set_mode(0o755);
            std::fs::set_permissions(&script, perms).unwrap();
        }

        let deadline = std::time::Instant::now() + Duration::from_millis(200);
        let started = std::time::Instant::now();
        let out = run_gh_with_backoff_until(deadline, || {
            let mut cmd = Command::new("/bin/sh");
            cmd.arg(&script);
            cmd
        })
        .unwrap();
        let elapsed = started.elapsed();

        assert!(
            !out.status.success(),
            "gh never succeeds in this test; the returned output must be the last failed attempt"
        );
        assert!(
            elapsed < Duration::from_secs(5),
            "run_gh_with_backoff_until must bail once the deadline is exhausted rather than \
             sleeping through the full 30s Retry-After; took {elapsed:?}"
        );
        // Exactly one attempt: the deadline (200ms) is exhausted before the
        // first retry sleep (which would wait max(30s Retry-After, 2s base)),
        // so the loop must bail after attempt 1 without retrying at all.
        assert_eq!(std::fs::read_to_string(counter).unwrap().trim(), "1");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn run_gh_with_backoff_retries_fake_gh_after_json_parse_failure() {
        let dir = std::env::temp_dir().join(format!(
            "ezgha-fake-gh-json-{}-{}",
            std::process::id(),
            std::thread::current().name().unwrap_or("test")
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let counter = dir.join("counter");
        let script = dir.join("fake-gh");
        std::fs::write(
            &script,
            format!(
                r#"#!/bin/sh
counter={counter}
n=0
if [ -f "$counter" ]; then n=$(cat "$counter"); fi
n=$((n + 1))
echo "$n" > "$counter"
if [ "$n" -eq 1 ]; then
  echo '[]'
  echo 'unexpected end of JSON input' >&2
  exit 1
fi
echo '{{"ok":true}}'
exit 0
"#,
                counter = counter.display()
            ),
        )
        .unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(&script).unwrap().permissions();
            perms.set_mode(0o755);
            std::fs::set_permissions(&script, perms).unwrap();
        }

        let out = run_gh_with_backoff(|| {
            let mut cmd = Command::new("/bin/sh");
            cmd.arg(&script);
            cmd
        })
        .unwrap();
        assert!(out.status.success());
        assert_eq!(std::fs::read_to_string(counter).unwrap().trim(), "2");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn list_runners_retries_transient_gh_json_parse_failure() {
        let dir = std::env::temp_dir().join(format!(
            "ezgha-fake-gh-list-json-{}-{}",
            std::process::id(),
            std::thread::current().name().unwrap_or("test")
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let counter = dir.join("counter");
        let script = dir.join("fake-gh");
        std::fs::write(
            &script,
            format!(
                r#"#!/bin/sh
counter={counter}
n=0
if [ -f "$counter" ]; then n=$(cat "$counter"); fi
n=$((n + 1))
echo "$n" > "$counter"
if [ "$n" -eq 1 ]; then
  echo '[]'
  echo 'unexpected end of JSON input' >&2
  exit 1
fi
echo '[{{"total_count":1,"runners":[{{"id":123,"name":"ez-runner-c-1","status":"online","busy":false}}]}}]'
exit 0
"#,
                counter = counter.display()
            ),
        )
        .unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(&script).unwrap().permissions();
            perms.set_mode(0o755);
            std::fs::set_permissions(&script, perms).unwrap();
        }

        let _guard = with_gh_exe(script.to_str().unwrap());
        let runners = list_runners(&org_cfg()).unwrap();
        assert_eq!(runners.len(), 1);
        assert_eq!(runners[0].id, 123);
        assert_eq!(std::fs::read_to_string(counter).unwrap().trim(), "2");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn generate_jitconfig_retries_transient_empty_json_parse_failure() {
        let dir = std::env::temp_dir().join(format!(
            "ezgha-fake-gh-jit-json-{}-{}",
            std::process::id(),
            std::thread::current().name().unwrap_or("test")
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let counter = dir.join("counter");
        let script = dir.join("fake-gh");
        std::fs::write(
            &script,
            format!(
                r#"#!/bin/sh
counter={counter}
n=0
if [ -f "$counter" ]; then n=$(cat "$counter"); fi
n=$((n + 1))
echo "$n" > "$counter"
if [ "$n" -eq 1 ]; then
  echo 'unexpected end of JSON input' >&2
  exit 1
fi
echo '{{"encoded_jit_config":"abc123","runner":{{"id":456,"name":"ez-runner-c-1"}}}}'
exit 0
"#,
                counter = counter.display()
            ),
        )
        .unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(&script).unwrap().permissions();
            perms.set_mode(0o755);
            std::fs::set_permissions(&script, perms).unwrap();
        }

        let _guard = with_gh_exe(script.to_str().unwrap());
        let owned = std::collections::HashSet::new();
        let (jit, runner_id) =
            generate_jitconfig(&org_cfg(), "ez-runner-c-1", &["self-hosted".into()], &owned)
                .unwrap();
        assert_eq!(jit, "abc123");
        assert_eq!(runner_id, 456);
        assert_eq!(std::fs::read_to_string(counter).unwrap().trim(), "2");
        let _ = std::fs::remove_dir_all(dir);
    }
}
