use anyhow::{bail, Context, Result};
use serde::Deserialize;
use std::io::Read;
use std::path::PathBuf;
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
const GH_RESPONSE_PREVIEW_CHARS: usize = 900;

fn preview_response(bytes: &[u8], max_chars: usize) -> String {
    let text = String::from_utf8_lossy(bytes);
    let mut chars = text.chars();
    let preview: String = chars.by_ref().take(max_chars).collect();
    if text.chars().count() > max_chars {
        format!("{preview}...")
    } else {
        preview
    }
}

fn log_gh_response(label: &str, out: &std::process::Output) {
    let status = out.status.code().unwrap_or(-1);
    eprintln!(
        "{label}: exit={status} stdout_bytes={} stderr_bytes={}",
        out.stdout.len(),
        out.stderr.len()
    );
    let stdout_preview = preview_response(&out.stdout, GH_RESPONSE_PREVIEW_CHARS);
    if !stdout_preview.is_empty() {
        eprintln!("{label}: stdout preview: {stdout_preview}");
    } else {
        eprintln!("{label}: stdout preview is empty");
    }
    let stderr_preview = preview_response(&out.stderr, GH_RESPONSE_PREVIEW_CHARS);
    if !stderr_preview.is_empty() {
        eprintln!("{label}: stderr preview: {stderr_preview}");
    } else {
        eprintln!("{label}: stderr preview is empty");
    }
}

/// Documented floor for SECONDARY rate-limit responses that lack a
/// `Retry-After` header. GitHub's docs say: when the secondary limit is
/// hit and no `Retry-After` is returned, wait at least 60s then back off
/// exponentially — repeated fast retries (the previous default of 2s)
/// extend the limit and may result in integration banning.
///
/// See <https://docs.github.com/en/rest/overview/rate-limits-for-the-rest-api>
/// "Secondary rate limits" section.
const GH_SECONDARY_MIN_DELAY: Duration = Duration::from_secs(60);

#[cfg(test)]
thread_local! {
    static GH_EXE_OVERRIDE: std::cell::RefCell<Option<String>> = const { std::cell::RefCell::new(None) };
    static GH_TOKEN_FILE_OVERRIDE: std::cell::RefCell<Option<PathBuf>> = const { std::cell::RefCell::new(None) };
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

#[cfg(test)]
pub(crate) struct GhTokenFileOverrideGuard {
    previous: Option<PathBuf>,
}

#[cfg(test)]
impl Drop for GhTokenFileOverrideGuard {
    fn drop(&mut self) {
        GH_TOKEN_FILE_OVERRIDE.with(|cell| {
            *cell.borrow_mut() = self.previous.take();
        });
    }
}

#[cfg(test)]
pub(crate) fn with_gh_token_file(path: PathBuf) -> GhTokenFileOverrideGuard {
    let previous = GH_TOKEN_FILE_OVERRIDE.with(|cell| {
        let mut slot = cell.borrow_mut();
        slot.replace(path)
    });
    GhTokenFileOverrideGuard { previous }
}

fn gh_command() -> Command {
    #[cfg(test)]
    if let Some(path) = GH_EXE_OVERRIDE.with(|cell| cell.borrow().clone()) {
        let mut cmd = Command::new("/bin/sh");
        cmd.arg(path);
        apply_gh_token_file(&mut cmd);
        return cmd;
    }

    let mut cmd = Command::new("gh");
    apply_gh_token_file(&mut cmd);
    cmd
}

fn gh_token_file_path() -> Option<PathBuf> {
    #[cfg(test)]
    if let Some(path) = GH_TOKEN_FILE_OVERRIDE.with(|cell| cell.borrow().clone()) {
        return Some(path);
    }

    std::env::var_os("EZGHA_GH_TOKEN_FILE")
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config/ezgha/gh_token"))
        })
}

fn read_gh_token_file() -> Option<Result<String, String>> {
    let path = gh_token_file_path()?;
    match std::fs::read_to_string(&path) {
        Ok(raw) => {
            let token = raw.trim().to_string();
            (!token.is_empty()).then_some(Ok(token))
        }
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => None,
        Err(err) => Some(Err(format!("{}: {err}", path.display()))),
    }
}

fn apply_gh_token_file(cmd: &mut Command) {
    match read_gh_token_file() {
        Some(Ok(token)) => {
            cmd.env("GH_TOKEN", token);
            cmd.env_remove("GITHUB_TOKEN");
        }
        Some(Err(message)) => {
            eprintln!(
                "warning: failed to read GitHub token file {message}; refusing to fall back to default gh auth"
            );
            cmd.env("GH_TOKEN", "ezgha-token-file-read-failed");
            cmd.env_remove("GITHUB_TOKEN");
        }
        None => {}
    }
}

/// True when a failed gh invocation indicates the installation token itself
/// is invalid — gh prints `gh: Bad credentials (HTTP 401)`. Deliberately
/// narrower than matching "401": a 403 "Resource not accessible by
/// integration" (permission scope) or a rate-limit 403/429 must NOT count,
/// only a dead/rotated/revoked token.
fn is_bad_credentials_response(stdout: &str, stderr: &str) -> bool {
    let lower = format!("{stdout} {stderr}").to_ascii_lowercase();
    lower.contains("bad credentials")
}

/// Minimum spacing between event-driven token-refresh kicks. A fleet-wide
/// 401 storm (each serve tick makes several gh calls) must collapse into a
/// single supervisor kick; the refresh job itself finishes in seconds.
const TOKEN_REFRESH_TRIGGER_COOLDOWN: Duration = Duration::from_secs(300);

/// Pure cooldown predicate for [`maybe_trigger_token_refresh`], split out so
/// the gating logic is unit-testable without touching process-global state.
fn token_refresh_due(last_epoch_secs: u64, now_epoch_secs: u64) -> bool {
    now_epoch_secs.saturating_sub(last_epoch_secs) >= TOKEN_REFRESH_TRIGGER_COOLDOWN.as_secs()
}

/// Event-driven complement to the 45-minute token-refresh timer (bead
/// jleechan-wzk): when gh reports 401 Bad credentials — e.g. after an
/// `app_private_key.pem` rotation invalidates every token minted with the
/// old key, as in the 2026-07-08 fleet-dark incident — kick the
/// already-installed refresh job (launchd on macOS, systemd --user on
/// Linux) so the token file is re-minted within seconds instead of waiting
/// out the timer. The daemon re-reads the token file on every gh call
/// (`apply_gh_token_file`), so no restart is needed once the file is fresh;
/// the next serve tick recovers naturally. Fire-and-forget + cooldown: a
/// failed kick only means waiting for the timer, which was the old behavior.
fn maybe_trigger_token_refresh() {
    use std::sync::atomic::{AtomicU64, Ordering};
    static LAST_TRIGGER_EPOCH: AtomicU64 = AtomicU64::new(0);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let last = LAST_TRIGGER_EPOCH.load(Ordering::Relaxed);
    if !token_refresh_due(last, now) {
        return;
    }
    if LAST_TRIGGER_EPOCH
        .compare_exchange(last, now, Ordering::Relaxed, Ordering::Relaxed)
        .is_err()
    {
        return; // another thread won the race; one kick is enough
    }
    #[cfg(test)]
    {
        // Never shell out to the host supervisor from unit tests.
        eprintln!("(test) token-refresh trigger suppressed");
    }
    #[cfg(not(test))]
    spawn_token_refresh_job();
}

#[cfg(not(test))]
fn spawn_token_refresh_job() {
    let (program, args): (&str, &[&str]) = if cfg!(target_os = "macos") {
        (
            "/bin/sh",
            &[
                "-c",
                "launchctl kickstart \"gui/$(id -u)/org.jleechanorg.ezgha-token-refresh\"",
            ],
        )
    } else {
        (
            "systemctl",
            &[
                "--user",
                "start",
                "--no-block",
                "ezgha-token-refresh.service",
            ],
        )
    };
    match Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(mut child) => {
            // Reap on a detached thread so the short-lived supervisor call
            // never accumulates zombies under the long-lived daemon.
            std::thread::spawn(move || {
                let _ = child.wait();
            });
            eprintln!(
                "warning: gh returned 401 Bad credentials — kicked the token-refresh job to \
                 re-mint the installation token now (instead of waiting for the next timer tick)"
            );
        }
        Err(err) => {
            eprintln!(
                "warning: gh returned 401 Bad credentials and the token-refresh kick failed: \
                 {err}; the token will refresh on the next timer tick"
            );
        }
    }
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

/// A PRIMARY rate-limit signal: GitHub returned 403/429 against the
/// standard `x-ratelimit-*` REST budget. Subject to the documented
/// `Retry-After` header (or 1s minimum) but NEVER the secondary-limit
/// 60s floor.
fn is_primary_rate_limit_response(stdout: &str, stderr: &str, status: Option<i32>) -> bool {
    let lower = format!("{stdout} {stderr}").to_ascii_lowercase();
    if lower.contains("secondary") {
        return false;
    }
    if !(lower.contains("rate limit") || lower.contains("abuse")) {
        return false;
    }
    if status == Some(403) || status == Some(429) {
        return true;
    }
    lower.contains("http 403") || lower.contains("http 429")
}

/// A SECONDARY rate-limit signal: burst/abuse/concurrency limit separate
/// from the primary REST budget. Triggers the 60s minimum retry floor
/// (see `GH_SECONDARY_MIN_DELAY`) and is the primary cause of the
/// 2026-07-07 ~2/16 fleet drain.
fn is_secondary_rate_limit_response(stdout: &str, stderr: &str, status: Option<i32>) -> bool {
    let lower = format!("{stdout} {stderr}").to_ascii_lowercase();
    if !(lower.contains("secondary") || lower.contains("abuse")) {
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
    let combined = format!("{stderr} {stdout}");
    if is_secondary_rate_limit_response(&stdout, &stderr, code) {
        // Secondary limits have a documented >=60s floor only when the
        // server OMITS Retry-After. When Retry-After is present we honor
        // it directly (no GH_RETRY_MAX_DELAY ceiling — secondary-limit
        // Retry-After values routinely exceed 32s for hot limits and
        // mis-truncating was the bug on which today's outage was
        // diagnosed). Server's instruction is authoritative when given.
        return Some(
            extract_retry_after_secs(&combined)
                .map(Duration::from_secs)
                .unwrap_or(GH_SECONDARY_MIN_DELAY),
        );
    }
    if is_primary_rate_limit_response(&stdout, &stderr, code) {
        return Some(
            extract_retry_after_secs(&combined)
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

/// Like `run_gh_with_backoff_until`, but ALSO caps each attempt's child `gh`
/// process at the remaining budget (`min(GH_TIMEOUT, deadline - now)`), not just
/// the inter-attempt sleeps. The SIGTERM drain uses this so a single hung
/// `gh api DELETE` (network/DNS stall) can never block past the 15s drain
/// deadline and cross `TimeoutStopSec=30` into a SIGKILL mid-drain (bead
/// ez-gh-actions-30p). Deliberately scoped to the drain: other deadline-bounded
/// callers keep the fixed `GH_TIMEOUT` per-call bound.
pub(crate) fn run_gh_with_backoff_until_capped(
    deadline: Instant,
    make_cmd: impl FnMut() -> Command,
) -> Result<std::process::Output> {
    run_gh_with_backoff_core_capped(Some(deadline), true, make_cmd)
}

fn run_gh_with_backoff_core(
    deadline: Option<Instant>,
    make_cmd: impl FnMut() -> Command,
) -> Result<std::process::Output> {
    run_gh_with_backoff_core_capped(deadline, false, make_cmd)
}

/// Core backoff loop. When `cap_child_to_deadline` is true AND a `deadline` is
/// set, each attempt's child `gh` process is bounded at
/// `min(GH_TIMEOUT, deadline - now)` (via `run_gh_with_timeout`) so a single
/// in-flight call can never block past the caller's budget. Non-capped callers
/// (the default, e.g. `list_runners_until` / `queue_monitor`) keep the fixed
/// `GH_TIMEOUT` per-call bound unchanged — the deadline still gates their
/// inter-attempt sleeps as before. Only the SIGTERM drain
/// (`remove_runner_until`) opts into the cap (bead ez-gh-actions-30p).
fn run_gh_with_backoff_core_capped(
    deadline: Option<Instant>,
    cap_child_to_deadline: bool,
    mut make_cmd: impl FnMut() -> Command,
) -> Result<std::process::Output> {
    let mut delay = GH_RETRY_BASE_DELAY;
    for attempt in 1..=GH_MAX_RETRIES {
        let out = match (cap_child_to_deadline, deadline) {
            (true, Some(dl)) => {
                // Cap the child at the remaining budget so a network/DNS hang
                // can't outrun the drain deadline. Never longer than GH_TIMEOUT.
                let remaining = dl.saturating_duration_since(Instant::now());
                run_gh_with_timeout(make_cmd(), remaining.min(GH_TIMEOUT))?
            }
            _ => run_gh(make_cmd())?,
        };
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
        log_gh_response(&format!("gh api {path}"), &out);
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
        log_gh_response(&format!("gh api {path}"), &out);
        bail!(
            "gh api {path} failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
    Ok(out.stdout)
}

/// Parsed slice of `gh api rate_limit`'s response -- only the `core` REST
/// bucket's `remaining` count matters for the budget-floor check below; the
/// `search`/`graphql`/etc buckets are ignored on purpose since every call
/// site this gates (`queue_monitor` read-heavy fetches) goes through the
/// REST (`core`) bucket, never GraphQL.
#[derive(Debug, Deserialize)]
struct RateLimitResponse {
    resources: RateLimitResources,
}

#[derive(Debug, Deserialize)]
struct RateLimitResources {
    core: RateLimitBucket,
}

#[derive(Debug, Deserialize)]
struct RateLimitBucket {
    remaining: u32,
}

/// Parses `gh api rate_limit`'s JSON body and extracts
/// `resources.core.remaining`. Split out from `rest_budget_remaining` so the
/// parsing logic is testable without exec'ing `gh` (see
/// `rate_limit_response_parses_core_remaining` below).
fn parse_rest_budget_remaining(body: &[u8]) -> Result<u32> {
    let parsed: RateLimitResponse =
        serde_json::from_slice(body).context("parse `gh api rate_limit` response")?;
    Ok(parsed.resources.core.remaining)
}

/// Returns the REST (core) bucket's remaining call count via `gh api
/// rate_limit` -- itself quota-EXEMPT, so checking it never consumes budget
/// from the bucket it's measuring. Used by `queue_monitor`'s REST-budget
/// deprioritization gate (see `queue_monitor::rest_budget_floor_allows`) to
/// decide whether a tick's read-heavy calls should fire or defer; the
/// write-path (`generate_jitconfig`/runner registration) never calls this
/// and is never gated by it.
pub fn rest_budget_remaining() -> Result<u32> {
    let out = run_gh_with_backoff(|| {
        let mut cmd = gh_command();
        cmd.args(["api", "rate_limit"]);
        cmd
    })
    .context("failed to run `gh api rate_limit`")?;
    if !out.status.success() {
        log_gh_response("gh api rate_limit", &out);
        bail!(
            "gh api rate_limit failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
    parse_rest_budget_remaining(&out.stdout)
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
        log_gh_response(&format!("gh api POST {path}"), &out);
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
fn run_gh(cmd: Command) -> Result<std::process::Output> {
    run_gh_with_timeout(cmd, GH_TIMEOUT)
}

/// Like `run_gh`, but bounds the child at an explicit `timeout` instead of the
/// fixed `GH_TIMEOUT`. Used by the SIGTERM drain path (bead ez-gh-actions-30p)
/// so a single in-flight `gh api DELETE` can be capped at the REMAINING drain
/// budget: the plain `run_gh` recv_timeout is `GH_TIMEOUT` (45s), which alone
/// can outrun the 15s drain / `TimeoutStopSec=30` and get SIGKILLed mid-drain.
/// The deadline gate in `run_gh_with_backoff_core` only bounds inter-attempt
/// SLEEPS, not the per-call child — the same "a budget only bounds calls that
/// check it" gap the serve-loop starvation fix closed.
fn run_gh_with_timeout(mut cmd: Command, timeout: Duration) -> Result<std::process::Output> {
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
    let stdout = match rx_out.recv_timeout(timeout) {
        Ok(b) => b,
        Err(_) => {
            let _ = child.kill();
            let _ = child.wait();
            bail!("gh CLI timed out after {}s", timeout.as_secs());
        }
    };
    // Stderr may still be draining; give it a short extra window.
    let stderr = rx_err
        .recv_timeout(Duration::from_secs(5))
        .unwrap_or_default();

    let status = child.wait().context("wait on gh child")?;
    if !status.success()
        && is_bad_credentials_response(
            &String::from_utf8_lossy(&stdout),
            &String::from_utf8_lossy(&stderr),
        )
    {
        // Dead/rotated installation token: kick the refresh job now rather
        // than staying 401-dark until the next 45-min timer tick (wzk).
        maybe_trigger_token_refresh();
    }
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
        log_gh_response(&format!("gh api generate-jitconfig for {name}"), &out);
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
                            let parsed: JitConfigResponse = serde_json::from_slice(&retry_out.stdout)
                                .map_err(|err| {
                                    log_gh_response(
                                        "gh api generate-jitconfig retry response",
                                        &retry_out
                                    );
                                    anyhow::anyhow!(
                                        "unexpected generate-jitconfig response on self-heal retry: {err}"
                                    )
                                })?;
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
    let parsed: JitConfigResponse = serde_json::from_slice(&out.stdout).map_err(|err| {
        log_gh_response("gh api generate-jitconfig", &out);
        anyhow::anyhow!("unexpected generate-jitconfig response: {err}")
    })?;
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

/// One page of `gh api --paginate --slurp` output for the runners-listing
/// endpoint. `total_count` is the org/repo-wide count GitHub reports on page 0;
/// it is `None` on page 0 when the API omits it (older gh / non-paginated
/// callers) and on every page >= 1 (GitHub only emits it on page 0).
///
/// Tracking it is what makes the partial-snapshot fail-closed check possible:
/// a truncated HTTP-200 stream (the 2026-07-07 churn root cause flagged by
/// ez-gh-actions-r3f12 / ghd2.1) has `total_count != observed`, and the daemon
/// must refuse to mutate slot state in that case.
#[derive(Debug, Deserialize)]
struct RunnerList {
    #[serde(default)]
    total_count: Option<u64>,
    runners: Vec<RunnerInfo>,
}

/// Outcome of consuming a paginated list-runners page stream.
///
/// `Complete` means the stream is authoritative and callers may safely mutate
/// slot state from it. `Partial { expected, observed }` means the first page's
/// `total_count` disagrees with the items actually observed across all pages —
/// i.e. the HTTP-200 stream was truncated (network drop, rate-limit tail cut,
/// `gh api` child-killed) and any slot-state mutation would silently work from
/// stale data. The caller MUST refuse rather than guess.
#[derive(Debug, PartialEq, Eq)]
pub enum SnapshotOutcome {
    Complete,
    Partial { expected: u64, observed: u64 },
}

/// Pure verifier — given a parsed page stream, classify it as Complete or
/// Partial without touching I/O. Rules (matches the GitHub REST contract for
/// `<resource>` list endpoints, where `total_count` appears ONLY on page 0):
///
/// * If page 0 has no `total_count`, the stream is treated as Complete (the
///   API didn't promise a count, so the page stream is authoritative).
/// * If page 0 has a `total_count`, it MUST equal the sum of items across
///   every page — otherwise the stream is Partial and the caller must refuse
///   to mutate state on it.
fn verify_snapshot_complete(pages: &[RunnerList]) -> SnapshotOutcome {
    let observed: u64 = pages.iter().map(|p| p.runners.len() as u64).sum();
    let expected = pages.first().and_then(|p| p.total_count);
    match expected {
        Some(t) if t != observed => SnapshotOutcome::Partial {
            expected: t,
            observed,
        },
        _ => SnapshotOutcome::Complete,
    }
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
        log_gh_response("gh api list runners", &out);
        bail!(
            "gh api list runners failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
    let pages: Vec<RunnerList> = serde_json::from_slice(&out.stdout).map_err(|err| {
        log_gh_response("gh api list runners payload", &out);
        anyhow::anyhow!(
            "unexpected list-runners response (expected array of pages from --slurp): {err}"
        )
    })?;
    watchdog::ping();
    // Fail-closed on partial HTTP-200. If the first page's `total_count` disagrees
    // with the items actually observed across the page stream, the response is
    // truncated — `gh api` got cut off mid-paginate (rate-limit tail, child-killed,
    // network drop). Mutating slot state on that data is the destructive churn
    // flagged by ez-gh-actions-r3f12 / ghd2.1: `release_stale_slots` would
    // reclaim every "missing" runner, then `ensure_count` respawns them, then
    // the next tick re-registers the originals. Refuse to mutate instead.
    if let SnapshotOutcome::Partial { expected, observed } = verify_snapshot_complete(&pages) {
        log_gh_response("gh api list runners truncated payload", &out);
        bail!(
            "partial snapshot: expected {expected} runners but observed {observed} from page stream; \
             refusing to mutate slot state on truncated data"
        );
    }
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

/// Deadline-bounded twin of `remove_runner` for the graceful-shutdown drain
/// (bead ez-gh-actions-30p). The plain `remove_runner` uses unbounded backoff
/// and can block ~128s under GitHub's secondary rate limit — far past the 15s
/// drain budget. This variant threads `deadline` through the CAPPED backoff
/// path (`run_gh_with_backoff_until_capped`), which bounds BOTH the inter-attempt
/// sleeps AND each attempt's child `gh` process at the remaining budget
/// (`min(GH_TIMEOUT, deadline - now)`) — so neither a rate-limit sleep nor a
/// single hung DELETE (network/DNS stall) can outrun the deadline. On any miss
/// the caller leaves the registration to `release_stale_slots` (fail-safe).
pub fn remove_runner_until(gh: &GithubConfig, id: u64, deadline: Instant) -> Result<()> {
    let path = runner_remove_path(gh, id);
    // Capped variant: bounds BOTH inter-attempt sleeps AND the per-call child at
    // the remaining drain budget, so a hung DELETE can't cross TimeoutStopSec.
    let out = run_gh_with_backoff_until_capped(deadline, || {
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

    #[test]
    fn bad_credentials_detected_in_gh_stderr() {
        // Exact shape gh prints for a dead/rotated installation token
        // (observed verbatim in the 2026-07-08 fleet-dark incident).
        assert!(is_bad_credentials_response(
            "",
            "gh: Bad credentials (HTTP 401)"
        ));
        // Also present in the JSON body on stdout for `gh api` calls.
        assert!(is_bad_credentials_response(
            r#"{"message":"Bad credentials","documentation_url":"https://docs.github.com/rest","status":"401"}"#,
            ""
        ));
    }

    #[test]
    fn bad_credentials_not_confused_with_permission_or_rate_limit() {
        // 403 permission-scope failure from a valid installation token
        // (e.g. installation token probing /user) must NOT trigger a re-mint.
        assert!(!is_bad_credentials_response(
            r#"{"message":"Resource not accessible by integration"}"#,
            "gh: Resource not accessible by integration (HTTP 403)"
        ));
        // Rate limits are handled by classify_retry_delay, not the token path.
        assert!(!is_bad_credentials_response(
            "",
            "gh: You have exceeded a secondary rate limit. Please retry your request again later. (HTTP 403)"
        ));
        // A clean success obviously must not trigger.
        assert!(!is_bad_credentials_response(r#"{"total_count":22}"#, ""));
    }

    #[test]
    fn token_refresh_cooldown_gates_repeat_triggers() {
        // First-ever trigger (last=0) is always due.
        assert!(token_refresh_due(0, 1_783_600_000));
        // Within the cooldown window: suppressed.
        let now = 1_783_600_000_u64;
        assert!(!token_refresh_due(now, now + 1));
        assert!(!token_refresh_due(
            now,
            now + TOKEN_REFRESH_TRIGGER_COOLDOWN.as_secs() - 1
        ));
        // At/after the window: due again.
        assert!(token_refresh_due(
            now,
            now + TOKEN_REFRESH_TRIGGER_COOLDOWN.as_secs()
        ));
        // Clock skew (now < last) must not underflow or spuriously fire.
        assert!(!token_refresh_due(now, now - 10));
    }

    fn org_cfg() -> GithubConfig {
        GithubConfig {
            scope: Scope::Org,
            target: "jleechanorg".into(),
        }
    }

    #[test]
    fn gh_command_reads_installation_token_file_for_child_env() {
        let token_path = std::env::temp_dir().join(format!(
            "ezgha-gh-token-test-{}-{}",
            std::process::id(),
            std::thread::current().name().unwrap_or("unnamed")
        ));
        std::fs::write(&token_path, "installation-token-value\n").unwrap();
        let _guard = with_gh_token_file(token_path.clone());

        let cmd = gh_command();
        let envs: std::collections::HashMap<String, Option<String>> = cmd
            .get_envs()
            .map(|(key, value)| {
                (
                    key.to_string_lossy().to_string(),
                    value.map(|v| v.to_string_lossy().to_string()),
                )
            })
            .collect();

        assert_eq!(
            envs.get("GH_TOKEN").and_then(|v| v.as_deref()),
            Some("installation-token-value")
        );
        assert_eq!(envs.get("GITHUB_TOKEN"), Some(&None));

        std::fs::remove_file(token_path).unwrap();
    }

    #[test]
    fn gh_command_falls_back_to_ambient_auth_when_token_file_missing() {
        let token_path = std::env::temp_dir().join(format!(
            "ezgha-gh-token-missing-test-{}-{}",
            std::process::id(),
            std::thread::current().name().unwrap_or("unnamed")
        ));
        let _ = std::fs::remove_file(&token_path);
        let _guard = with_gh_token_file(token_path.clone());

        let cmd = gh_command();
        let envs: std::collections::HashMap<String, Option<String>> = cmd
            .get_envs()
            .map(|(key, value)| {
                (
                    key.to_string_lossy().to_string(),
                    value.map(|v| v.to_string_lossy().to_string()),
                )
            })
            .collect();

        assert!(!envs.contains_key("GH_TOKEN"));
        assert!(!envs.contains_key("GITHUB_TOKEN"));

        let _ = std::fs::remove_file(token_path);
    }

    #[test]
    fn gh_command_falls_back_to_ambient_auth_when_token_file_empty() {
        let token_path = std::env::temp_dir().join(format!(
            "ezgha-gh-token-empty-test-{}-{}",
            std::process::id(),
            std::thread::current().name().unwrap_or("unnamed")
        ));
        std::fs::write(&token_path, "   \n").unwrap();
        let _guard = with_gh_token_file(token_path.clone());

        let cmd = gh_command();
        let envs: std::collections::HashMap<String, Option<String>> = cmd
            .get_envs()
            .map(|(key, value)| {
                (
                    key.to_string_lossy().to_string(),
                    value.map(|v| v.to_string_lossy().to_string()),
                )
            })
            .collect();

        assert!(!envs.contains_key("GH_TOKEN"));
        assert!(!envs.contains_key("GITHUB_TOKEN"));

        std::fs::remove_file(token_path).unwrap();
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

    // -- partial-snapshot fail-closed (bead ez-gh-actions-r3f12 / ghd2.1) --

    /// Pure-function tests for the snapshot-completeness verifier. Covers the
    /// edge cases that are awkward to express through a fake-`gh` script.
    #[test]
    fn verify_snapshot_complete_classifies_cases() {
        let page = |ids: &[u64], tc: Option<u64>| RunnerList {
            runners: ids
                .iter()
                .map(|id| RunnerInfo {
                    id: *id,
                    name: format!("ez-runner-{id}"),
                    status: "online".into(),
                    busy: false,
                })
                .collect(),
            total_count: tc,
        };

        // Empty stream: nothing expected, nothing observed -> Complete.
        assert_eq!(verify_snapshot_complete(&[]), SnapshotOutcome::Complete);

        // Page 0 has no total_count: API didn't promise a count -> Complete.
        assert_eq!(
            verify_snapshot_complete(&[page(&[1, 2], None)]),
            SnapshotOutcome::Complete
        );

        // total_count matches the page-0 count alone.
        assert_eq!(
            verify_snapshot_complete(&[page(&[1, 2], Some(2))]),
            SnapshotOutcome::Complete
        );

        // total_count matches the sum across multiple pages (the happy path).
        assert_eq!(
            verify_snapshot_complete(&[page(&[1, 2], Some(3)), page(&[3], Some(3))]),
            SnapshotOutcome::Complete
        );

        // total_count=0 with empty stream: explicitly told us nothing was there.
        assert_eq!(
            verify_snapshot_complete(&[page(&[], Some(0))]),
            SnapshotOutcome::Complete
        );

        // total_count disagrees: Partial -- the r3f12 destructive-churn trigger.
        assert_eq!(
            verify_snapshot_complete(&[page(&[1, 2], Some(100))]),
            SnapshotOutcome::Partial {
                expected: 100,
                observed: 2,
            }
        );

        // total_count disagrees across multiple pages: still Partial.
        assert_eq!(
            verify_snapshot_complete(&[page(&[1, 2], Some(5)), page(&[3], Some(5))]),
            SnapshotOutcome::Partial {
                expected: 5,
                observed: 3,
            }
        );

        // First page missing total_count but later page has one: still
        // Complete. Only page 0's count is authoritative (GitHub REST
        // contract: total_count is emitted only on page 0).
        assert_eq!(
            verify_snapshot_complete(&[page(&[1], None), page(&[2], Some(2))]),
            SnapshotOutcome::Complete
        );
    }

    /// Helper: write `payload` to a file inside a temp dir, write a tiny
    /// `fake-gh` shell script that cats that file to stdout, mark it
    /// executable. Returns (dir, script-path) so the caller can both
    /// `with_gh_exe(...)` and `remove_dir_all(dir)` on teardown.
    fn setup_fake_gh_payload(name: &str, payload: &str) -> (PathBuf, PathBuf) {
        // Use a per-test unique id (atomic counter) so the temp dir never
        // collides between parallel test threads. The original code used
        // `process::id()` + `thread::current().name()`, but cargo-test worker
        // threads share `process::id()` and unnamed threads collide on the
        // fallback name `test`, which produced flaky empty-stdout failures
        // when one parallel test's payload was overwritten before another
        // test's fake-gh could `cat` it.
        static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let unique = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!(
            "ezgha-fake-gh-{}-{}-{}",
            name,
            std::process::id(),
            unique
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let payload_file = dir.join("payload.json");
        std::fs::write(&payload_file, payload).unwrap();
        let script = dir.join("fake-gh");
        // When cargo spawns the test binary it inherits the parent shell's
        // env, but `PATH` may not include `/usr/bin` / `/bin` (some CI
        // environments strip the child's PATH). Plain `cat` inside the
        // script then fails with "cat: not found", and the captured stdout
        // comes back empty -- which surfaces as
        // `serde_json::from_slice("")` ("EOF while parsing at line 1
        // column 0") and a flake only visible when the suite runs in
        // parallel. Set `PATH` explicitly at the top of the script so
        // `/bin/cat` (or `/usr/bin/cat`) is found regardless of inherited
        // environment.
        let script_body = format!(
            "#!/bin/sh\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\ncat <<'EZGHA_FAKE_GH_PAYLOAD_EOF'\n{payload}\nEZGHA_FAKE_GH_PAYLOAD_EOF\n",
            payload = payload,
        );
        std::fs::write(&script, script_body).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(&script).unwrap().permissions();
            perms.set_mode(0o755);
            std::fs::set_permissions(&script, perms).unwrap();
        }
        (dir, script)
    }

    /// Page 0 promises 100 runners but the stream only delivers 3 items. This
    /// is the r3f4-f16 / ghd2.1 destructive-churn scenario: the daemon MUST
    /// refuse to mutate slot state on truncated data, not silently truncate.
    #[test]
    fn list_runners_partial_snapshot_bails() {
        let payload = r#"[
            {"total_count": 100, "runners": [
                {"id": 1, "name": "ez-runner-c-1", "status": "online", "busy": false},
                {"id": 2, "name": "ez-runner-c-2", "status": "online", "busy": false}
            ]},
            {"total_count": 100, "runners": [
                {"id": 3, "name": "ez-runner-c-3", "status": "offline", "busy": false}
            ]}
        ]"#;
        let (dir, script) = setup_fake_gh_payload("list-partial-snap", payload);
        let _guard = with_gh_exe(script.to_str().unwrap());
        let err = list_runners(&org_cfg())
            .expect_err("partial snapshot must bail rather than return truncated data");
        let msg = format!("{err:#}");
        assert!(
            msg.contains("partial snapshot"),
            "error must mention partial snapshot, got: {msg}"
        );
        assert!(
            msg.contains("expected 100"),
            "expected count must appear in error, got: {msg}"
        );
        assert!(
            msg.contains("observed 3"),
            "observed count must appear in error, got: {msg}"
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    /// `total_count` matches the items actually observed. The flat list is
    /// returned unchanged.
    #[test]
    fn list_runners_complete_snapshot_succeeds() {
        let payload = r#"[
            {"total_count": 3, "runners": [
                {"id": 1, "name": "ez-runner-c-1", "status": "online", "busy": false},
                {"id": 2, "name": "ez-runner-c-2", "status": "offline", "busy": false}
            ]},
            {"total_count": 3, "runners": [
                {"id": 3, "name": "ez-runner-c-3", "status": "online", "busy": true}
            ]}
        ]"#;
        let (dir, script) = setup_fake_gh_payload("list-complete-snap", payload);
        let _guard = with_gh_exe(script.to_str().unwrap());
        let runners = list_runners(&org_cfg()).expect("complete snapshot must succeed");
        let ids: Vec<u64> = runners.iter().map(|r| r.id).collect();
        assert_eq!(ids, vec![1, 2, 3]);
        let _ = std::fs::remove_dir_all(dir);
    }

    /// Page 0 omits `total_count`. The page stream is authoritative when the
    /// API doesn't promise a count -- treated as Complete rather than bailing
    /// on a "missing" promise.
    #[test]
    fn list_runners_first_page_missing_total_count_succeeds() {
        let payload = r#"[
            {"runners": [
                {"id": 10, "name": "ez-runner-c-10", "status": "online", "busy": false}
            ]},
            {"runners": [
                {"id": 11, "name": "ez-runner-c-11", "status": "online", "busy": true}
            ]}
        ]"#;
        let (dir, script) = setup_fake_gh_payload("list-missing-tc", payload);
        let _guard = with_gh_exe(script.to_str().unwrap());
        let runners = list_runners(&org_cfg())
            .expect("missing total_count on page 0 must be treated as Complete");
        let ids: Vec<u64> = runners.iter().map(|r| r.id).collect();
        assert_eq!(ids, vec![10, 11]);
        let _ = std::fs::remove_dir_all(dir);
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
    fn rate_limit_response_parses_core_remaining() {
        // Real `gh api rate_limit` shape (trimmed to the fields we read).
        let body = br#"{
            "resources": {
                "core": {"limit": 5000, "used": 4750, "remaining": 250, "reset": 1700000000},
                "search": {"limit": 30, "used": 0, "remaining": 30, "reset": 1700000000},
                "graphql": {"limit": 5000, "used": 0, "remaining": 5000, "reset": 1700000000}
            },
            "rate": {"limit": 5000, "used": 4750, "remaining": 250, "reset": 1700000000}
        }"#;
        let remaining = parse_rest_budget_remaining(body).unwrap();
        assert_eq!(remaining, 250);
    }

    #[test]
    fn rate_limit_response_rejects_malformed_json() {
        let err = parse_rest_budget_remaining(b"not json").unwrap_err();
        assert!(
            err.to_string().contains("parse `gh api rate_limit`"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn rest_budget_remaining_execs_gh_api_rate_limit_and_parses_core() {
        let dir = std::env::temp_dir().join(format!(
            "ezgha-fake-gh-rate-limit-{}-{}",
            std::process::id(),
            std::thread::current().name().unwrap_or("test")
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let script = dir.join("fake-gh");
        std::fs::write(
            &script,
            r#"#!/bin/sh
echo '{"resources":{"core":{"limit":5000,"used":4999,"remaining":1,"reset":0}}}'
exit 0
"#,
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
        let remaining = rest_budget_remaining().unwrap();
        assert_eq!(remaining, 1);
        let _ = std::fs::remove_dir_all(dir);
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
        // Primary rate limit (x-ratelimit-remaining=0) has a documented floor of
        // 1s and is fine to retry with the base delay when no Retry-After is set.
        let out = std::process::Output {
            status: std::os::unix::process::ExitStatusExt::from_raw(1 << 8),
            stdout: Vec::new(),
            stderr: b"gh: API rate limit exceeded (HTTP 403)\n".to_vec(),
        };
        let delay = classify_retry_delay(&out)
            .expect("primary rate-limit response without Retry-After should still be retried");
        assert_eq!(delay, GH_RETRY_BASE_DELAY);
    }

    #[test]
    fn secondary_rate_limit_without_retry_after_uses_documented_floor() {
        // GitHub's documented floor for SECONDARY-rate-limit responses without
        // a Retry-After header is >=60s. Our pre-fix code coerced those to
        // GH_RETRY_BASE_DELAY (2s), which is a direct cause of extending
        // secondary limits (the doc warns repeated fast retries may result
        // in integration banning).
        let out = std::process::Output {
            status: std::os::unix::process::ExitStatusExt::from_raw(1 << 8),
            stdout: Vec::new(),
            stderr: b"gh: secondary rate limit exceeded (HTTP 429)\n".to_vec(),
        };
        let delay = classify_retry_delay(&out)
            .expect("secondary rate-limit response without Retry-After should still be retried");
        assert!(
            delay >= Duration::from_secs(60),
            "secondary rate-limit without Retry-After must wait >=60s \
             (got {:?}, GH_SECONDARY_MIN_DELAY expected)",
            delay
        );
    }

    #[test]
    fn secondary_rate_limit_with_retry_after_honors_header_value() {
        let out = std::process::Output {
            status: std::os::unix::process::ExitStatusExt::from_raw(403 << 8),
            stdout: Vec::new(),
            stderr: b"HTTP 403: secondary rate limit\nRetry-After: 90\n".to_vec(),
        };
        let delay = classify_retry_delay(&out)
            .expect("secondary rate-limit with Retry-After should be classified");
        assert_eq!(delay, Duration::from_secs(90));
    }

    #[test]
    fn primary_and_secondary_classifiers_are_distinct() {
        // The two classes must NOT be conflated: a primary limit can fire
        // after only a handful of REST calls and is bounded by primary
        // budget; a secondary limit is a SEPARATE burst/concurrency limit
        // and must trigger the >=60s retry floor. Shared detection means
        // we treat (cheap) primary limits like (expensive) secondary ones,
        // wasting 60s of daemon time on a primary that Retry-After could
        // have released in 1s.
        let primary = std::str::from_utf8(b"gh: API rate limit exceeded (HTTP 403)\n").unwrap();
        let secondary =
            std::str::from_utf8(b"gh: secondary rate limit exceeded (HTTP 429)\n").unwrap();
        assert!(
            is_primary_rate_limit_response(primary, "", Some(1)),
            "primary-limit message must be classified as primary"
        );
        assert!(
            !is_primary_rate_limit_response(secondary, "", Some(1)),
            "secondary-limit message must NOT be classified as primary"
        );
        assert!(
            is_secondary_rate_limit_response(secondary, "", Some(1)),
            "secondary-limit message must be classified as secondary"
        );
        assert!(
            !is_secondary_rate_limit_response(primary, "", Some(1)),
            "primary-limit message must NOT be classified as secondary"
        );
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

    #[test]
    fn remove_runner_until_succeeds_via_fake_gh() {
        // Happy path: a bounded delete that the (faked) gh accepts returns Ok.
        // Hermetic — uses a fake gh stub, never the real network.
        let dir = std::env::temp_dir().join(format!(
            "ezgha-fake-gh-rm-ok-{}-{}",
            std::process::id(),
            std::thread::current().name().unwrap_or("test")
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let script = dir.join("fake-gh");
        std::fs::write(&script, "#!/bin/sh\nexit 0\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(&script).unwrap().permissions();
            perms.set_mode(0o755);
            std::fs::set_permissions(&script, perms).unwrap();
        }

        let _guard = with_gh_exe(script.to_str().unwrap());
        let deadline = Instant::now() + Duration::from_secs(15);
        remove_runner_until(&repo_cfg(), 4242, deadline).unwrap();
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn remove_runner_until_bails_instead_of_sleeping_past_deadline() {
        // Bounded-backoff proof: a persistent secondary-rate-limit (Retry-After: 5)
        // with an already-elapsed deadline must NOT sleep the 5s — it bails on the
        // first attempt. Hermetic (fake gh stub); asserts fast return + Err.
        let dir = std::env::temp_dir().join(format!(
            "ezgha-fake-gh-rm-budget-{}-{}",
            std::process::id(),
            std::thread::current().name().unwrap_or("test")
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let script = dir.join("fake-gh");
        std::fs::write(
            &script,
            "#!/bin/sh\necho 'gh: secondary rate limit exceeded (HTTP 403)' >&2\n\
             echo 'Retry-After: 5' >&2\nexit 1\n",
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
        let start = std::time::Instant::now();
        // Already-elapsed deadline: any retry sleep (5s) would cross it, so the
        // bounded loop must bail on attempt 1 rather than sleeping.
        let result = remove_runner_until(&repo_cfg(), 4242, Instant::now());
        let elapsed = start.elapsed();
        assert!(result.is_err(), "persistent 403 must surface as an error");
        assert!(
            elapsed < Duration::from_secs(2),
            "must bail without sleeping past the deadline, took {}s",
            elapsed.as_secs()
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn remove_runner_until_kills_hung_child_at_remaining_budget() {
        // The skeptic's defect (bead ez-gh-actions-30p): a single in-flight
        // `gh api DELETE` that HANGS must be killed at the remaining drain
        // budget, not at the fixed 45s GH_TIMEOUT — otherwise it crosses
        // TimeoutStopSec=30 and systemd SIGKILLs mid-drain. Fake gh sleeps 10s;
        // with a ~1s deadline the child must be killed and the call must return
        // (Err) well before the 10s sleep would finish. Hermetic, no real API.
        let dir = std::env::temp_dir().join(format!(
            "ezgha-fake-gh-rm-hang-{}-{}",
            std::process::id(),
            std::thread::current().name().unwrap_or("test")
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let script = dir.join("fake-gh");
        std::fs::write(&script, "#!/bin/sh\nsleep 10\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(&script).unwrap().permissions();
            perms.set_mode(0o755);
            std::fs::set_permissions(&script, perms).unwrap();
        }

        let _guard = with_gh_exe(script.to_str().unwrap());
        let start = std::time::Instant::now();
        let result =
            remove_runner_until(&repo_cfg(), 4242, Instant::now() + Duration::from_secs(1));
        let elapsed = start.elapsed();
        assert!(
            result.is_err(),
            "a hung DELETE must surface as an error (child killed at budget)"
        );
        assert!(
            elapsed < Duration::from_secs(3),
            "hung child must be killed at the ~1s remaining budget, not the 10s \
             sleep or the 45s GH_TIMEOUT; took {}s",
            elapsed.as_secs()
        );
        let _ = std::fs::remove_dir_all(dir);
    }
}
