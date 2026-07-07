use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::io::Write;
use std::path::PathBuf;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::alert::{self, Severity};
use crate::config::{Config, GithubConfig, Scope};
use crate::github;

const FLEET_ORG: &str = "jleechanorg";
const LINUX_FLEET_PREFIX: &str = "ez-runner-c-";
const MAC_FLEET_PREFIX: &str = "ez-mac-runner-b-";
const LINUX_FLEET_COUNT: u32 = 16;
const MAC_FLEET_COUNT: u32 = 6;
const EXPECTED_FLEET_RUNNERS: usize = (LINUX_FLEET_COUNT + MAC_FLEET_COUNT) as usize;

/// Repos the E1 ironclad exit criterion requires watching for INV-1/INV-2,
/// independent of whatever single repo `cfg.github.target`/`queue_monitor.repo`
/// point at. Hardcoded (like `FLEET_ORG` above) rather than config-driven: this
/// is a fixed mission requirement (goals/2026-07-07-1920-runner-truly-healthy/
/// 02-exit-criteria-ironclad.md), not a per-deployment setting.
pub const MONITORED_INVARIANT_REPOS: &[&str] =
    &["jleechanorg/worldarchitect.ai", "jleechanorg/ez-gh-actions"];

/// INV-2's "no job queued or in_progress > 20 min" boundary. A job at exactly
/// 20.0 minutes satisfies the invariant (`<=`, not `<`); only strictly over 20
/// minutes counts as a violation, matching this file's existing `tail_bad`
/// convention (`max_current > tail_warn_minutes as f64`).
const INVARIANT_DURATION_THRESHOLD_MINUTES: f64 = 20.0;

#[derive(Debug, Default)]
pub struct QueueMonitorState {
    last_check: Option<Instant>,
    consecutive_bad: u32,
}

impl QueueMonitorState {
    pub fn new() -> Self {
        Self {
            last_check: None,
            consecutive_bad: 0,
        }
    }

    pub fn maybe_check(&mut self, cfg: &Config) -> Result<Option<QueueStats>> {
        if !cfg.queue_monitor.enabled {
            return Ok(None);
        }
        let interval = Duration::from_secs(cfg.queue_monitor.check_interval_seconds);
        if self
            .last_check
            .is_some_and(|last| last.elapsed() < interval)
        {
            return Ok(None);
        }
        self.last_check = Some(Instant::now());

        let Some(repo) = queue_repo(cfg) else {
            return Ok(None);
        };
        let snapshot = fetch_queue_snapshot(repo)?;
        let now = unix_now_secs();
        let stats = queue_stats(
            &snapshot,
            now,
            cfg.queue_monitor.stale_hours,
            cfg.queue_monitor.tail_warn_minutes,
        );
        self.record_tail_sample(stats.tail_bad);
        report_queue_health(cfg, repo, &stats, self.consecutive_bad)?;
        Ok(Some(stats))
    }

    fn record_tail_sample(&mut self, tail_bad: bool) -> u32 {
        if tail_bad {
            self.consecutive_bad = self.consecutive_bad.saturating_add(1);
        } else {
            self.consecutive_bad = 0;
        }
        self.consecutive_bad
    }
}

/// E1 ironclad exit-criterion sampler. Deliberately separate from
/// `QueueMonitorState` above: that state drives a single-repo starvation/
/// idle-mismatch alerting concern tied to `cfg.queue_monitor`/`queue_repo(cfg)`,
/// while this one evaluates INV-1/INV-2 across the fixed
/// `MONITORED_INVARIANT_REPOS` list + whole fleet and is durably logged for
/// E2's 3-hour zero-violation window, regardless of what `cfg.github.target`
/// or `queue_monitor.repo` happen to point at.
#[derive(Debug, Default)]
pub struct InvariantSamplerState {
    last_check: Option<Instant>,
}

impl InvariantSamplerState {
    pub fn new() -> Self {
        Self { last_check: None }
    }

    pub fn maybe_sample(&mut self, cfg: &Config) -> Result<Option<InvariantSample>> {
        if !cfg.invariant_sampler.enabled {
            return Ok(None);
        }
        let interval = Duration::from_secs(cfg.invariant_sampler.check_interval_seconds);
        if self
            .last_check
            .is_some_and(|last| last.elapsed() < interval)
        {
            return Ok(None);
        }
        self.last_check = Some(Instant::now());

        let sample = sample_invariants(cfg)?;
        append_invariant_sample(cfg, &sample)?;
        if !sample.inv1 || !sample.inv2 {
            alert_invariant_violation(cfg, &sample)?;
        }
        Ok(Some(sample))
    }
}

/// One INV-1/INV-2 sample, appended verbatim (via `serde_json::to_string`) as
/// one JSON line to the invariant-history JSONL file. Field names and set are
/// exactly the E1 exit-criterion schema
/// `{ts, busy, registered, queued_jobs, oldest_queued_job_min,
/// oldest_running_job_min, inv1, inv2, inv1_fail_class}` -- do not rename
/// fields without updating the exit-criteria doc and any downstream reader.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct InvariantSample {
    /// Unix epoch seconds, matching this codebase's existing `ts_unix`
    /// convention in alerts.jsonl (renamed to the exit-criterion's literal
    /// field name `ts`; value format is still an integer, not RFC3339 --
    /// this repo has no date-formatting dependency and every other JSONL
    /// history file here already uses unix seconds).
    pub ts: i64,
    pub busy: usize,
    pub registered: usize,
    pub queued_jobs: usize,
    pub oldest_queued_job_min: f64,
    pub oldest_running_job_min: f64,
    pub inv1: bool,
    pub inv2: bool,
    /// Populated only when `inv1` is false. One of "missing-registration"
    /// (fewer than the expected 22 runners are registered at all),
    /// "offline-respawning" (registered but not all online -- JIT
    /// deregister/respawn churn, see docs/ed8-fleet-churn-root-cause-*.md),
    /// or "genuinely-idle" (fully registered and online, but not picking up
    /// queued work).
    pub inv1_fail_class: Option<String>,
}

fn sample_invariants(cfg: &Config) -> Result<InvariantSample> {
    let fleet = fetch_fleet_runner_stats()?;
    let now = unix_now_secs();
    let mut repo_stats = Vec::with_capacity(MONITORED_INVARIANT_REPOS.len());
    for repo in MONITORED_INVARIANT_REPOS {
        let snapshot = fetch_queue_snapshot_with_fleet(repo, Some(fleet.clone()))?;
        repo_stats.push(queue_stats(
            &snapshot,
            now,
            cfg.queue_monitor.stale_hours,
            cfg.queue_monitor.tail_warn_minutes,
        ));
    }
    Ok(combine_invariant_sample(&fleet, &repo_stats, now))
}

/// Pure combination logic, kept separate from `sample_invariants`'s network
/// calls so the classifier + threshold math are unit-testable without a live
/// GitHub API (mirrors how `queue_stats` above is unit-tested against
/// hand-built `QueueSnapshot`s rather than through `fetch_queue_snapshot`).
fn combine_invariant_sample(
    fleet: &FleetRunnerStats,
    repo_stats: &[QueueStats],
    now_secs: i64,
) -> InvariantSample {
    let queued_jobs: usize = repo_stats.iter().map(|s| s.queued_total).sum();

    // A stale (>8h) queued job is still "queued > 20 min" for INV-2's purposes
    // even though `queue_stats` excludes it from `max_current_job_age_minutes`
    // (that field backs a different, zombie-aware alerting concern). E1's
    // ironclad duration invariant makes no such exception, so combine both
    // `oldest_fresh` and `oldest_stale` here.
    let oldest_queued_job_min = repo_stats
        .iter()
        .flat_map(|s| {
            s.oldest_fresh
                .as_ref()
                .map(|j| j.age_minutes)
                .into_iter()
                .chain(s.oldest_stale.as_ref().map(|j| j.age_minutes))
        })
        .fold(0.0_f64, f64::max);
    let oldest_running_job_min = repo_stats
        .iter()
        .map(|s| s.max_in_progress_age_minutes)
        .fold(0.0_f64, f64::max);

    // busy_count can never exceed EXPECTED_FLEET_RUNNERS (fleet_runner_stats
    // filters to the 22 expected names only), so `>=` and `==` are
    // operationally identical; `>=` is the defensive form.
    let inv1 = fleet.busy_count >= EXPECTED_FLEET_RUNNERS || queued_jobs == 0;
    let inv2 = oldest_queued_job_min <= INVARIANT_DURATION_THRESHOLD_MINUTES
        && oldest_running_job_min <= INVARIANT_DURATION_THRESHOLD_MINUTES;
    let inv1_fail_class = if inv1 {
        None
    } else {
        Some(classify_inv1_failure(fleet).to_string())
    };

    InvariantSample {
        ts: now_secs,
        busy: fleet.busy_count,
        registered: fleet.registered_count,
        queued_jobs,
        oldest_queued_job_min,
        oldest_running_job_min,
        inv1,
        inv2,
        inv1_fail_class,
    }
}

/// Classify why INV-1 failed, in priority order from most to least severe:
/// a runner that never registered at all is a bigger problem than one that
/// registered but is offline, which is a bigger problem than one that is
/// online but simply idle.
fn classify_inv1_failure(fleet: &FleetRunnerStats) -> &'static str {
    if !fleet.missing_names.is_empty() {
        "missing-registration"
    } else if fleet.runners.iter().any(|r| r.status != "online") {
        "offline-respawning"
    } else {
        "genuinely-idle"
    }
}

fn alert_invariant_violation(cfg: &Config, sample: &InvariantSample) -> Result<()> {
    let mut reasons = Vec::new();
    if !sample.inv1 {
        reasons.push(format!(
            "INV-1 utilization violated: busy={}/{} registered={} queued_jobs={} fail_class={}",
            sample.busy,
            EXPECTED_FLEET_RUNNERS,
            sample.registered,
            sample.queued_jobs,
            sample.inv1_fail_class.as_deref().unwrap_or("unknown"),
        ));
    }
    if !sample.inv2 {
        reasons.push(format!(
            "INV-2 duration violated: oldest_queued={:.1}m oldest_running={:.1}m threshold={:.0}m",
            sample.oldest_queued_job_min,
            sample.oldest_running_job_min,
            INVARIANT_DURATION_THRESHOLD_MINUTES,
        ));
    }
    let body = reasons.join("; ");
    alert::notify(
        cfg,
        "invariant.violation",
        Severity::Critical,
        "ezgha fleet invariant violation (E1)",
        &body,
    )?;
    eprintln!("warning: {body}");
    Ok(())
}

fn append_invariant_sample(cfg: &Config, sample: &InvariantSample) -> Result<()> {
    let path = invariant_history_path(cfg);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("create invariant history dir {}", parent.display()))?;
    }
    let line =
        serde_json::to_string(sample).context("serialize invariant sample to JSON line")?;
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .with_context(|| format!("open invariant history file {}", path.display()))?;
    writeln!(file, "{line}")
        .with_context(|| format!("append invariant history file {}", path.display()))?;
    Ok(())
}

fn invariant_history_path(cfg: &Config) -> PathBuf {
    cfg.invariant_sampler
        .history_path
        .clone()
        .unwrap_or_else(default_invariant_history_path)
}

/// `$XDG_STATE_HOME/ezgha/invariant_history.jsonl`, falling back to
/// `~/.local/state` per the XDG Base Directory spec -- mirrors
/// `docker_backend.rs`'s `default_state_dir()` pattern (env-var driven, no
/// `directories` crate) but targets the *state* dir, not the *config* dir,
/// matching where this repo's alerts.jsonl/canary_history.jsonl actually live
/// on disk today (`~/.local/state/ezgha/...`, set explicitly in
/// `~/.config/ezgha/config.toml`'s `alert.log_path`/`canary.history_path`).
fn default_invariant_history_path() -> PathBuf {
    let state_home = std::env::var("XDG_STATE_HOME").unwrap_or_else(|_| {
        let home = std::env::var("HOME").unwrap_or_else(|_| "~".into());
        format!("{home}/.local/state")
    });
    PathBuf::from(state_home)
        .join("ezgha")
        .join("invariant_history.jsonl")
}

fn queue_repo(cfg: &Config) -> Option<&str> {
    cfg.queue_monitor.repo.as_deref().or_else(|| {
        if cfg.github.scope == Scope::Repo {
            Some(cfg.github.target.as_str())
        } else {
            None
        }
    })
}

fn fetch_self_hosted_jobs(
    repo: &str,
    run: &impl RunLike,
    expected_status: &str,
) -> Result<Vec<QueueJob>> {
    let jobs = github::list_workflow_jobs(repo, run.run_id())
        .with_context(|| format!("list jobs for queued monitor run {}", run.run_id()))?;
    Ok(jobs
        .into_iter()
        .filter(|job| job.status == expected_status)
        .filter(|job| is_self_hosted_job(&job.labels))
        .map(|job| QueueJob {
            run_id: run.run_id(),
            job_id: job.id,
            name: job.name,
            head_branch: run.head_branch().unwrap_or_default(),
            created_at: job.created_at,
            started_at: job.started_at,
            url: job
                .html_url
                .unwrap_or_else(|| run.html_url().unwrap_or_default()),
        })
        .collect())
}

trait RunLike {
    fn run_id(&self) -> u64;
    fn head_branch(&self) -> Option<String>;
    fn html_url(&self) -> Option<String>;
}

impl RunLike for ApiWorkflowRun {
    fn run_id(&self) -> u64 {
        self.id
    }

    fn head_branch(&self) -> Option<String> {
        self.head_branch.clone()
    }

    fn html_url(&self) -> Option<String> {
        self.html_url.clone()
    }
}

impl RunLike for github::WorkflowRun {
    fn run_id(&self) -> u64 {
        self.id
    }

    fn head_branch(&self) -> Option<String> {
        self.head_branch.clone()
    }

    fn html_url(&self) -> Option<String> {
        Some(self.html_url.clone())
    }
}

fn is_self_hosted_job(labels: &[String]) -> bool {
    labels
        .iter()
        .any(|label| label.eq_ignore_ascii_case("self-hosted"))
}

fn fetch_fleet_runner_stats() -> Result<FleetRunnerStats> {
    let gh = GithubConfig {
        scope: Scope::Org,
        target: FLEET_ORG.into(),
    };
    Ok(fleet_runner_stats(github::list_runners(&gh)?))
}

fn fetch_queue_snapshot(repo: &str) -> Result<QueueSnapshot> {
    fetch_queue_snapshot_with_fleet(repo, None)
}

/// Same as `fetch_queue_snapshot`, but accepts an already-fetched
/// `FleetRunnerStats` to avoid an extra `list_runners` API call when the
/// caller is sampling multiple repos against the same org fleet in one tick
/// (see `sample_invariants` below) -- API-rate-limit hygiene given how many
/// concurrent agents hit this org's GitHub API.
fn fetch_queue_snapshot_with_fleet(
    repo: &str,
    fleet: Option<FleetRunnerStats>,
) -> Result<QueueSnapshot> {
    let mut queued = Vec::new();
    let mut page = 1u32;
    loop {
        let path = format!("repos/{repo}/actions/runs?status=queued&per_page=100&page={page}");
        let body = github::api_json(&path)?;
        let parsed: RunsResponse = serde_json::from_slice(&body)
            .with_context(|| format!("parse queued runs response for {repo} page {page}"))?;
        let len = parsed.workflow_runs.len();
        for run in parsed.workflow_runs {
            queued.extend(fetch_self_hosted_jobs(repo, &run, "queued")?);
        }
        if len < 100 {
            break;
        }
        page = page.saturating_add(1);
    }

    let mut in_progress = Vec::new();
    for run in github::list_repo_in_progress_runs(repo)? {
        in_progress.extend(fetch_self_hosted_jobs(repo, &run, "in_progress")?);
    }

    Ok(QueueSnapshot {
        queued,
        in_progress,
        fleet: fleet.or_else(|| fetch_fleet_runner_stats().ok()),
    })
}

fn report_queue_health(
    cfg: &Config,
    repo: &str,
    stats: &QueueStats,
    consecutive_bad: u32,
) -> Result<()> {
    report_stale_queue(cfg, repo, stats)?;
    report_idle_runner_mismatch(cfg, repo, stats)?;
    if !stats.tail_bad {
        println!(
            "queue monitor: {repo} queued_jobs={} fresh={} stale={} in_progress_jobs={} max_job_age={:.1}m threshold={}m",
            stats.queued_total,
            stats.fresh_queued,
            stats.stale_queued,
            stats.in_progress_total,
            stats.max_current_job_age_minutes,
            stats.tail_warn_minutes
        );
        return Ok(());
    }

    let Some(severity) = queue_alert_severity(
        consecutive_bad,
        cfg.queue_monitor.consecutive_alert_threshold,
    ) else {
        eprintln!(
            "warning: queue monitor saw bad sample {}/{} for {repo}: max_fresh_wait={:.1}m threshold={}m",
            consecutive_bad,
            cfg.queue_monitor.consecutive_alert_threshold,
            stats.max_current_job_age_minutes,
            stats.tail_warn_minutes
        );
        return Ok(());
    };

    let subject = "GitHub Actions queue starvation";
    let event_key = match severity {
        Severity::Critical => "queue.starvation.tail.critical",
        _ => "queue.starvation.tail",
    };
    let oldest = stats
        .oldest_fresh
        .as_ref()
        .map(|job| {
            format!(
                "oldest fresh queued job: run_id={} job_id={} name={} branch={} age={:.1}m url={}",
                job.run_id, job.job_id, job.name, job.head_branch, job.age_minutes, job.url
            )
        })
        .or_else(|| {
            stats.oldest_in_progress.as_ref().map(|job| {
                format!(
                    "oldest in-progress job: run_id={} job_id={} name={} branch={} age={:.1}m url={}",
                    job.run_id,
                    job.job_id,
                    job.name,
                    job.head_branch,
                    job.age_minutes,
                    job.url
                )
            })
        })
        .unwrap_or_else(|| "oldest current job: none".to_string());
    let body = format!(
        "{repo} has {} queued self-hosted jobs (fresh={}, stale={}), {} in-progress self-hosted jobs; current job age p50={:.1}m p90={:.1}m max={:.1}m exceeds threshold {}m. {oldest}",
        stats.queued_total,
        stats.fresh_queued,
        stats.stale_queued,
        stats.in_progress_total,
        stats.p50_wait_minutes,
        stats.p90_wait_minutes,
        stats.max_current_job_age_minutes,
        stats.tail_warn_minutes,
    );
    alert::notify(cfg, event_key, severity, subject, &body)?;
    eprintln!("warning: {body}");
    Ok(())
}

fn report_idle_runner_mismatch(cfg: &Config, repo: &str, stats: &QueueStats) -> Result<()> {
    if stats.fresh_queued == 0 {
        return Ok(());
    }
    let Some(fleet) = stats.fleet.as_ref() else {
        return Ok(());
    };
    if fleet.idle_count == 0 {
        return Ok(());
    }
    let table = fleet.runner_table();
    let missing = if fleet.missing_names.is_empty() {
        "missing expected runners: none".to_string()
    } else {
        format!(
            "missing expected runners: {}",
            fleet.missing_names.join(", ")
        )
    };
    let body = format!(
        "{repo} has {} fresh queued self-hosted job(s) while {} of {} expected fleet runners are registered busy and {} are online idle/not-busy. This indicates queued work is not being picked up despite idle capacity.\n{missing}\n{table}",
        stats.fresh_queued,
        fleet.busy_count,
        fleet.expected_total,
        fleet.idle_count,
    );
    alert::notify(
        cfg,
        "queue.idle_runner_mismatch",
        Severity::Critical,
        "GitHub Actions queued jobs with idle runners",
        &body,
    )?;
    eprintln!("warning: {body}");
    Ok(())
}

fn report_stale_queue(cfg: &Config, repo: &str, stats: &QueueStats) -> Result<()> {
    if stats.stale_queued == 0 {
        return Ok(());
    }
    let oldest = stats
        .oldest_stale
        .as_ref()
        .map(|job| {
            format!(
                "oldest stale queued job: run_id={} job_id={} name={} branch={} age={:.1}d url={}",
                job.run_id,
                job.job_id,
                job.name,
                job.head_branch,
                job.age_minutes / 1440.0,
                job.url
            )
        })
        .unwrap_or_else(|| "oldest stale queued job: none".to_string());
    let body = format!(
        "{repo} has {} stale queued self-hosted job(s) older than the {}h cutoff; {oldest}",
        stats.stale_queued, stats.stale_cutoff_hours,
    );
    alert::notify(
        cfg,
        "queue.stale.zombies",
        Severity::Warning,
        "GitHub Actions stale queued runs",
        &body,
    )?;
    eprintln!("warning: {body}");
    Ok(())
}

fn queue_alert_severity(consecutive_bad: u32, threshold: u32) -> Option<Severity> {
    if consecutive_bad < threshold {
        return None;
    }
    if consecutive_bad >= threshold.saturating_mul(2) {
        Some(Severity::Critical)
    } else {
        Some(Severity::Warning)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct QueueSnapshot {
    pub queued: Vec<QueueJob>,
    pub in_progress: Vec<QueueJob>,
    pub fleet: Option<FleetRunnerStats>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct QueueJob {
    pub run_id: u64,
    pub job_id: u64,
    pub name: String,
    pub head_branch: String,
    pub created_at: String,
    pub started_at: Option<String>,
    pub url: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct FleetRunnerStats {
    pub expected_total: usize,
    pub registered_count: usize,
    pub busy_count: usize,
    pub idle_count: usize,
    pub missing_names: Vec<String>,
    pub runners: Vec<FleetRunner>,
}

impl FleetRunnerStats {
    fn runner_table(&self) -> String {
        let mut lines = vec!["runner status busy".to_string()];
        lines.extend(
            self.runners
                .iter()
                .map(|runner| format!("{} {} {}", runner.name, runner.status, runner.busy)),
        );
        lines.join("\n")
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct FleetRunner {
    pub name: String,
    pub status: String,
    pub busy: bool,
}

fn fleet_runner_stats(runners: Vec<github::RunnerInfo>) -> FleetRunnerStats {
    let expected = expected_fleet_runner_names();
    let mut fleet: Vec<FleetRunner> = runners
        .into_iter()
        .filter(|runner| expected.iter().any(|name| name == &runner.name))
        .map(|runner| FleetRunner {
            name: runner.name,
            status: runner.status,
            busy: runner.busy,
        })
        .collect();
    fleet.sort_by(|a, b| natural_runner_name_cmp(&a.name, &b.name));

    let registered_names: std::collections::HashSet<&str> =
        fleet.iter().map(|runner| runner.name.as_str()).collect();
    let missing_names = expected
        .into_iter()
        .filter(|name| !registered_names.contains(name.as_str()))
        .collect::<Vec<_>>();
    let busy_count = fleet.iter().filter(|runner| runner.busy).count();
    let idle_count = fleet
        .iter()
        .filter(|runner| runner.status == "online" && !runner.busy)
        .count();

    FleetRunnerStats {
        expected_total: EXPECTED_FLEET_RUNNERS,
        registered_count: fleet.len(),
        busy_count,
        idle_count,
        missing_names,
        runners: fleet,
    }
}

fn expected_fleet_runner_names() -> Vec<String> {
    let mut names = Vec::with_capacity(EXPECTED_FLEET_RUNNERS);
    names.extend((1..=LINUX_FLEET_COUNT).map(|idx| format!("{LINUX_FLEET_PREFIX}{idx}")));
    names.extend((1..=MAC_FLEET_COUNT).map(|idx| format!("{MAC_FLEET_PREFIX}{idx}")));
    names
}

fn natural_runner_name_cmp(left: &str, right: &str) -> std::cmp::Ordering {
    runner_sort_key(left).cmp(&runner_sort_key(right))
}

fn runner_sort_key(name: &str) -> (u8, u32, String) {
    if let Some(raw) = name.strip_prefix(LINUX_FLEET_PREFIX) {
        return (0, raw.parse().unwrap_or(u32::MAX), name.to_string());
    }
    if let Some(raw) = name.strip_prefix(MAC_FLEET_PREFIX) {
        return (1, raw.parse().unwrap_or(u32::MAX), name.to_string());
    }
    (2, u32::MAX, name.to_string())
}

#[derive(Debug, Clone, PartialEq)]
pub struct QueueStats {
    pub queued_total: usize,
    pub fresh_queued: usize,
    pub stale_queued: usize,
    pub in_progress_total: usize,
    pub p50_wait_minutes: f64,
    pub p90_wait_minutes: f64,
    pub max_fresh_wait_minutes: f64,
    pub max_in_progress_age_minutes: f64,
    pub max_current_job_age_minutes: f64,
    pub tail_warn_minutes: u64,
    pub stale_cutoff_hours: u64,
    pub tail_bad: bool,
    pub oldest_fresh: Option<AgedQueueJob>,
    pub oldest_stale: Option<AgedQueueJob>,
    pub oldest_in_progress: Option<AgedQueueJob>,
    pub fleet: Option<FleetRunnerStats>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct AgedQueueJob {
    pub run_id: u64,
    pub job_id: u64,
    pub name: String,
    pub head_branch: String,
    pub url: String,
    pub age_minutes: f64,
}

fn queue_stats(
    snapshot: &QueueSnapshot,
    now_secs: i64,
    stale_hours: u64,
    tail_warn_minutes: u64,
) -> QueueStats {
    let stale_secs = (stale_hours * 3600) as i64;
    let mut fresh_ages = Vec::new();
    let mut current_job_ages = Vec::new();
    let mut stale_queued = 0usize;
    let mut oldest_fresh: Option<AgedQueueJob> = None;
    let mut oldest_stale: Option<AgedQueueJob> = None;
    let mut oldest_in_progress: Option<AgedQueueJob> = None;

    for job in &snapshot.queued {
        let Some(created) = parse_github_timestamp_secs(&job.created_at) else {
            continue;
        };
        let age_secs = (now_secs - created).max(0);
        let age_minutes = age_secs as f64 / 60.0;
        if age_secs >= stale_secs {
            stale_queued += 1;
            if oldest_stale
                .as_ref()
                .is_none_or(|old| age_minutes > old.age_minutes)
            {
                oldest_stale = Some(AgedQueueJob {
                    run_id: job.run_id,
                    job_id: job.job_id,
                    name: job.name.clone(),
                    head_branch: job.head_branch.clone(),
                    url: job.url.clone(),
                    age_minutes,
                });
            }
            continue;
        }
        current_job_ages.push(age_minutes);
        fresh_ages.push(age_minutes);
        if oldest_fresh
            .as_ref()
            .is_none_or(|old| age_minutes > old.age_minutes)
        {
            oldest_fresh = Some(AgedQueueJob {
                run_id: job.run_id,
                job_id: job.job_id,
                name: job.name.clone(),
                head_branch: job.head_branch.clone(),
                url: job.url.clone(),
                age_minutes,
            });
        }
    }

    let mut in_progress_ages = Vec::new();
    for job in &snapshot.in_progress {
        let age_from = job.started_at.as_deref().unwrap_or(&job.created_at);
        let Some(started) = parse_github_timestamp_secs(age_from) else {
            continue;
        };
        let age_minutes = (now_secs - started).max(0) as f64 / 60.0;
        in_progress_ages.push(age_minutes);
        current_job_ages.push(age_minutes);
        if oldest_in_progress
            .as_ref()
            .is_none_or(|old| age_minutes > old.age_minutes)
        {
            oldest_in_progress = Some(AgedQueueJob {
                run_id: job.run_id,
                job_id: job.job_id,
                name: job.name.clone(),
                head_branch: job.head_branch.clone(),
                url: job.url.clone(),
                age_minutes,
            });
        }
    }

    fresh_ages.sort_by(|a, b| a.total_cmp(b));
    in_progress_ages.sort_by(|a, b| a.total_cmp(b));
    current_job_ages.sort_by(|a, b| a.total_cmp(b));
    let max_fresh = fresh_ages.last().copied().unwrap_or(0.0);
    let max_in_progress = in_progress_ages.last().copied().unwrap_or(0.0);
    let max_current = current_job_ages.last().copied().unwrap_or(0.0);

    QueueStats {
        queued_total: snapshot.queued.len(),
        fresh_queued: fresh_ages.len(),
        stale_queued,
        in_progress_total: snapshot.in_progress.len(),
        p50_wait_minutes: median(&current_job_ages),
        p90_wait_minutes: percentile(&current_job_ages, 0.9),
        max_fresh_wait_minutes: max_fresh,
        max_in_progress_age_minutes: max_in_progress,
        max_current_job_age_minutes: max_current,
        tail_warn_minutes,
        stale_cutoff_hours: stale_hours,
        tail_bad: max_current > tail_warn_minutes as f64,
        oldest_fresh,
        oldest_stale,
        oldest_in_progress,
        fleet: snapshot.fleet.clone(),
    }
}

fn median(values: &[f64]) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    let mid = values.len() / 2;
    if values.len().is_multiple_of(2) {
        (values[mid - 1] + values[mid]) / 2.0
    } else {
        values[mid]
    }
}

fn percentile(values: &[f64], p: f64) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    let idx = (values.len() as f64 * p) as usize;
    values[idx.min(values.len() - 1)]
}

fn unix_now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

pub(crate) fn parse_github_timestamp_secs(raw: &str) -> Option<i64> {
    if raw.len() != 20 || !raw.ends_with('Z') {
        return None;
    }
    let year = raw.get(0..4)?.parse::<i32>().ok()?;
    let month = raw.get(5..7)?.parse::<u32>().ok()?;
    let day = raw.get(8..10)?.parse::<u32>().ok()?;
    let hour = raw.get(11..13)?.parse::<u32>().ok()?;
    let minute = raw.get(14..16)?.parse::<u32>().ok()?;
    let second = raw.get(17..19)?.parse::<u32>().ok()?;
    if raw.as_bytes().get(4) != Some(&b'-')
        || raw.as_bytes().get(7) != Some(&b'-')
        || raw.as_bytes().get(10) != Some(&b'T')
        || raw.as_bytes().get(13) != Some(&b':')
        || raw.as_bytes().get(16) != Some(&b':')
        || !(1..=12).contains(&month)
        || !(1..=31).contains(&day)
        || hour > 23
        || minute > 59
        || second > 59
    {
        return None;
    }
    let days = days_from_civil(year, month, day)?;
    Some(days * 86_400 + hour as i64 * 3600 + minute as i64 * 60 + second as i64)
}

fn days_from_civil(year: i32, month: u32, day: u32) -> Option<i64> {
    let max_day = match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if is_leap_year(year) => 29,
        2 => 28,
        _ => return None,
    };
    if day == 0 || day > max_day {
        return None;
    }

    let mut y = year as i64;
    let m = month as i64;
    let d = day as i64;
    y -= (m <= 2) as i64;
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let doy = (153 * (m + if m > 2 { -3 } else { 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    Some(era * 146_097 + doe - 719_468)
}

fn is_leap_year(year: i32) -> bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

#[derive(Debug, Deserialize)]
struct RunsResponse {
    #[allow(dead_code)]
    total_count: u64,
    workflow_runs: Vec<ApiWorkflowRun>,
}

#[derive(Debug, Deserialize)]
struct ApiWorkflowRun {
    id: u64,
    #[serde(default)]
    head_branch: Option<String>,
    #[serde(default)]
    html_url: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn parses_github_timestamp() {
        assert_eq!(parse_github_timestamp_secs("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(
            parse_github_timestamp_secs("1970-01-01T00:01:00Z"),
            Some(60)
        );
        assert!(parse_github_timestamp_secs("2024-02-29T12:34:56Z").is_some());
        assert!(parse_github_timestamp_secs("2026-02-30T00:00:00Z").is_none());
        assert!(parse_github_timestamp_secs("2026-01-01T00:00:00+00:00").is_none());
    }

    #[test]
    fn queue_stats_flags_fresh_tail_breach_and_ignores_stale_runs() {
        let now = parse_github_timestamp_secs("2026-07-07T08:30:00Z").unwrap();
        let snapshot = QueueSnapshot {
            queued: vec![
                job(1, "Green Gate", "main", "2026-07-07T08:25:00Z"),
                job(2, "Presubmit", "feature", "2026-07-07T07:45:00Z"),
                job(3, "Zombie", "old", "2026-07-06T07:00:00Z"),
            ],
            in_progress: vec![started_job(
                4,
                "Long Test",
                "feature",
                "2026-07-07T08:00:00Z",
            )],
            fleet: None,
        };

        let stats = queue_stats(&snapshot, now, 8, 20);

        assert_eq!(stats.queued_total, 3);
        assert_eq!(stats.fresh_queued, 2);
        assert_eq!(stats.stale_queued, 1);
        assert_eq!(stats.in_progress_total, 1);
        assert!(stats.tail_bad);
        assert_eq!(stats.max_fresh_wait_minutes, 45.0);
        assert_eq!(stats.max_in_progress_age_minutes, 30.0);
        assert_eq!(stats.max_current_job_age_minutes, 45.0);
        assert_eq!(stats.oldest_fresh.as_ref().map(|r| r.job_id), Some(2));
        assert_eq!(stats.oldest_stale.as_ref().map(|r| r.job_id), Some(3));
        assert_eq!(stats.oldest_in_progress.as_ref().map(|r| r.job_id), Some(4));
    }

    #[test]
    fn queue_stats_passes_when_tail_is_within_threshold() {
        let now = parse_github_timestamp_secs("2026-07-07T08:30:00Z").unwrap();
        let snapshot = QueueSnapshot {
            queued: vec![job(1, "Quick", "main", "2026-07-07T08:20:00Z")],
            in_progress: vec![],
            fleet: None,
        };

        let stats = queue_stats(&snapshot, now, 8, 20);

        assert!(!stats.tail_bad);
        assert_eq!(stats.p50_wait_minutes, 10.0);
        assert_eq!(stats.p90_wait_minutes, 10.0);
    }

    #[test]
    fn queue_stats_handles_boundaries_and_ignored_timestamps() {
        let now = parse_github_timestamp_secs("2026-07-07T08:30:00Z").unwrap();
        let snapshot = QueueSnapshot {
            queued: vec![
                job(1, "Exact threshold", "main", "2026-07-07T08:10:00Z"),
                job(2, "Future", "main", "2026-07-07T08:35:00Z"),
                job(3, "Exact stale cutoff", "main", "2026-07-07T00:30:00Z"),
                job(4, "Invalid", "main", "not-a-timestamp"),
            ],
            in_progress: vec![],
            fleet: None,
        };

        let stats = queue_stats(&snapshot, now, 8, 20);

        assert_eq!(stats.queued_total, 4);
        assert_eq!(stats.fresh_queued, 2);
        assert_eq!(stats.stale_queued, 1);
        assert!(!stats.tail_bad);
        assert_eq!(stats.max_fresh_wait_minutes, 20.0);
        assert_eq!(stats.p50_wait_minutes, 10.0);
        assert_eq!(stats.p90_wait_minutes, 20.0);
        assert_eq!(stats.oldest_stale.as_ref().map(|r| r.job_id), Some(3));
    }

    #[test]
    fn queue_stats_flags_long_in_progress_job_at_job_level() {
        let now = parse_github_timestamp_secs("2026-07-07T08:30:00Z").unwrap();
        let snapshot = QueueSnapshot {
            queued: vec![],
            in_progress: vec![started_job(
                99,
                "Stuck Integration",
                "main",
                "2026-07-07T07:59:00Z",
            )],
            fleet: None,
        };

        let stats = queue_stats(&snapshot, now, 8, 20);

        assert!(stats.tail_bad);
        assert_eq!(stats.queued_total, 0);
        assert_eq!(stats.in_progress_total, 1);
        assert_eq!(stats.max_current_job_age_minutes, 31.0);
        assert_eq!(
            stats.oldest_in_progress.as_ref().map(|job| job.job_id),
            Some(99)
        );
    }

    #[test]
    fn queue_alert_waits_for_consecutive_bad_samples() {
        assert_eq!(queue_alert_severity(1, 2), None);
        assert_eq!(queue_alert_severity(2, 2), Some(Severity::Warning));
        assert_eq!(queue_alert_severity(4, 2), Some(Severity::Critical));
    }

    #[test]
    fn bad_sample_counter_resets_after_clean_sample() {
        let mut state = QueueMonitorState::new();
        assert_eq!(state.record_tail_sample(true), 1);
        assert_eq!(state.record_tail_sample(true), 2);
        assert_eq!(state.record_tail_sample(false), 0);
        assert_eq!(state.record_tail_sample(true), 1);
    }

    #[test]
    fn queue_alert_uses_log_channel_after_consecutive_bad_samples() {
        alert::clear_alert_state();
        let (mut cfg, dir, log) = test_config_with_log();
        cfg.queue_monitor.consecutive_alert_threshold = 2;
        let stats = bad_stats();

        report_queue_health(&cfg, "owner/repo", &stats, 1).unwrap();
        assert!(!log.exists());

        report_queue_health(&cfg, "owner/repo", &stats, 2).unwrap();
        let raw = fs::read_to_string(&log).unwrap();
        assert!(raw.contains("\"event_key\":\"queue.starvation.tail\""));
        assert!(raw.contains("\"severity\":\"WARNING\""));

        report_queue_health(&cfg, "owner/repo", &stats, 4).unwrap();
        let raw = fs::read_to_string(&log).unwrap();
        assert!(raw.contains("\"event_key\":\"queue.starvation.tail.critical\""));
        assert!(raw.contains("\"severity\":\"CRITICAL\""));
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn stale_queue_warning_is_independent_of_tail_breach() {
        alert::clear_alert_state();
        let (cfg, dir, log) = test_config_with_log();
        let stats = QueueStats {
            queued_total: 1,
            fresh_queued: 0,
            stale_queued: 1,
            in_progress_total: 0,
            p50_wait_minutes: 0.0,
            p90_wait_minutes: 0.0,
            max_fresh_wait_minutes: 0.0,
            max_in_progress_age_minutes: 0.0,
            max_current_job_age_minutes: 0.0,
            tail_warn_minutes: 20,
            stale_cutoff_hours: 8,
            tail_bad: false,
            oldest_fresh: None,
            oldest_stale: Some(AgedQueueJob {
                run_id: 90,
                job_id: 9,
                name: "Zombie".into(),
                head_branch: "main".into(),
                url: "https://github.example/runs/9".into(),
                age_minutes: 1441.0,
            }),
            oldest_in_progress: None,
            fleet: None,
        };

        report_queue_health(&cfg, "owner/repo", &stats, 0).unwrap();

        let raw = fs::read_to_string(&log).unwrap();
        assert!(raw.contains("\"event_key\":\"queue.stale.zombies\""));
        assert!(raw.contains("stale queued self-hosted job"));
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn idle_runner_mismatch_alert_includes_runner_table_and_missing_names() {
        alert::clear_alert_state();
        let (cfg, dir, log) = test_config_with_log();
        let mut stats = bad_stats();
        stats.tail_bad = false;
        stats.max_current_job_age_minutes = 5.0;
        stats.fleet = Some(FleetRunnerStats {
            expected_total: EXPECTED_FLEET_RUNNERS,
            registered_count: 2,
            busy_count: 1,
            idle_count: 1,
            missing_names: vec!["ez-runner-c-2".into()],
            runners: vec![
                FleetRunner {
                    name: "ez-runner-c-1".into(),
                    status: "online".into(),
                    busy: true,
                },
                FleetRunner {
                    name: "ez-mac-runner-b-1".into(),
                    status: "online".into(),
                    busy: false,
                },
            ],
        });

        report_queue_health(&cfg, "owner/repo", &stats, 0).unwrap();

        let raw = fs::read_to_string(&log).unwrap();
        assert!(raw.contains("\"event_key\":\"queue.idle_runner_mismatch\""));
        assert!(raw.contains("\"severity\":\"CRITICAL\""));
        assert!(raw.contains("ez-mac-runner-b-1 online false"));
        assert!(raw.contains("missing expected runners: ez-runner-c-2"));
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn fleet_stats_counts_exact_22_runner_pool_only() {
        let runners = vec![
            runner("ez-runner-c-1", "online", true),
            runner("ez-runner-c-2", "online", false),
            runner("ez-mac-runner-b-1", "offline", false),
            runner("ez-canary-runner-b-1", "online", false),
        ];

        let stats = fleet_runner_stats(runners);

        assert_eq!(stats.expected_total, 22);
        assert_eq!(stats.registered_count, 3);
        assert_eq!(stats.busy_count, 1);
        assert_eq!(stats.idle_count, 1);
        assert!(stats.missing_names.contains(&"ez-runner-c-3".to_string()));
        assert!(stats
            .missing_names
            .contains(&"ez-mac-runner-b-6".to_string()));
        assert!(!stats
            .runners
            .iter()
            .any(|runner| runner.name == "ez-canary-runner-b-1"));
    }

    fn fleet_runner(name: &str, status: &str, busy: bool) -> FleetRunner {
        FleetRunner {
            name: name.into(),
            status: status.into(),
            busy,
        }
    }

    fn full_fleet(busy_count: usize, idle_count: usize) -> FleetRunnerStats {
        FleetRunnerStats {
            expected_total: EXPECTED_FLEET_RUNNERS,
            registered_count: EXPECTED_FLEET_RUNNERS,
            busy_count,
            idle_count,
            missing_names: vec![],
            runners: vec![],
        }
    }

    fn stats_with_ages(oldest_queued: Option<f64>, oldest_in_progress: Option<f64>) -> QueueStats {
        QueueStats {
            queued_total: usize::from(oldest_queued.is_some()),
            fresh_queued: usize::from(oldest_queued.is_some()),
            stale_queued: 0,
            in_progress_total: usize::from(oldest_in_progress.is_some()),
            p50_wait_minutes: 0.0,
            p90_wait_minutes: 0.0,
            max_fresh_wait_minutes: oldest_queued.unwrap_or(0.0),
            max_in_progress_age_minutes: oldest_in_progress.unwrap_or(0.0),
            max_current_job_age_minutes: oldest_queued
                .unwrap_or(0.0)
                .max(oldest_in_progress.unwrap_or(0.0)),
            tail_warn_minutes: 20,
            stale_cutoff_hours: 8,
            tail_bad: false,
            oldest_fresh: oldest_queued.map(|age_minutes| AgedQueueJob {
                run_id: 1,
                job_id: 1,
                name: "job".into(),
                head_branch: "main".into(),
                url: "https://github.example/runs/1".into(),
                age_minutes,
            }),
            oldest_stale: None,
            oldest_in_progress: oldest_in_progress.map(|age_minutes| AgedQueueJob {
                run_id: 2,
                job_id: 2,
                name: "job".into(),
                head_branch: "main".into(),
                url: "https://github.example/runs/2".into(),
                age_minutes,
            }),
            fleet: None,
        }
    }

    #[test]
    fn invariant_inv1_true_when_fleet_fully_busy_regardless_of_queue() {
        let fleet = full_fleet(EXPECTED_FLEET_RUNNERS, 0);
        let stats = vec![stats_with_ages(Some(5.0), None)];
        let sample = combine_invariant_sample(&fleet, &stats, 1000);
        assert!(sample.inv1);
        assert_eq!(sample.inv1_fail_class, None);
    }

    #[test]
    fn invariant_inv1_true_when_queue_is_empty_regardless_of_busy_count() {
        let fleet = full_fleet(EXPECTED_FLEET_RUNNERS - 1, 1);
        let stats = vec![stats_with_ages(None, None)];
        let sample = combine_invariant_sample(&fleet, &stats, 1000);
        assert_eq!(sample.queued_jobs, 0);
        assert!(sample.inv1);
        assert_eq!(sample.inv1_fail_class, None);
    }

    #[test]
    fn invariant_inv1_false_when_fleet_short_one_and_queue_nonempty() {
        let fleet = full_fleet(EXPECTED_FLEET_RUNNERS - 1, 1);
        let stats = vec![stats_with_ages(Some(5.0), None)];
        let sample = combine_invariant_sample(&fleet, &stats, 1000);
        assert_eq!(sample.queued_jobs, 1);
        assert!(!sample.inv1);
        assert_eq!(sample.inv1_fail_class.as_deref(), Some("genuinely-idle"));
    }

    #[test]
    fn invariant_inv2_boundary_is_inclusive_of_exactly_20_minutes() {
        let fleet = full_fleet(EXPECTED_FLEET_RUNNERS, 0);
        let at_threshold = combine_invariant_sample(
            &fleet,
            &[stats_with_ages(Some(20.0), Some(20.0))],
            1000,
        );
        assert!(at_threshold.inv2, "exactly 20.0m must satisfy INV-2");

        let over_threshold_queued = combine_invariant_sample(
            &fleet,
            &[stats_with_ages(Some(20.01), None)],
            1000,
        );
        assert!(!over_threshold_queued.inv2, "20.01m queued must violate INV-2");

        let over_threshold_running = combine_invariant_sample(
            &fleet,
            &[stats_with_ages(None, Some(20.01))],
            1000,
        );
        assert!(
            !over_threshold_running.inv2,
            "20.01m in-progress must violate INV-2"
        );
    }

    #[test]
    fn invariant_oldest_ages_combine_stale_and_fresh_across_repos_via_max() {
        let fleet = full_fleet(EXPECTED_FLEET_RUNNERS, 0);
        let mut worldai_stats = stats_with_ages(Some(5.0), None);
        // A stale (>8h) zombie is still "queued > 20min" for E1's ironclad
        // duration invariant even though queue_stats() excludes it from
        // max_current_job_age_minutes for the unrelated starvation-alert path.
        worldai_stats.oldest_stale = Some(AgedQueueJob {
            run_id: 9,
            job_id: 9,
            name: "zombie".into(),
            head_branch: "main".into(),
            url: "https://github.example/runs/9".into(),
            age_minutes: 500.0,
        });
        let ezgha_stats = stats_with_ages(Some(3.0), Some(45.0));

        let sample = combine_invariant_sample(&fleet, &[worldai_stats, ezgha_stats], 1000);

        assert_eq!(sample.oldest_queued_job_min, 500.0);
        assert_eq!(sample.oldest_running_job_min, 45.0);
        assert!(!sample.inv2);
    }

    #[test]
    fn classify_inv1_failure_prioritizes_missing_registration() {
        let fleet = FleetRunnerStats {
            expected_total: EXPECTED_FLEET_RUNNERS,
            registered_count: EXPECTED_FLEET_RUNNERS - 1,
            busy_count: EXPECTED_FLEET_RUNNERS - 1,
            idle_count: 0,
            missing_names: vec!["ez-runner-c-16".into()],
            runners: vec![fleet_runner("ez-mac-runner-b-1", "offline", false)],
        };
        assert_eq!(classify_inv1_failure(&fleet), "missing-registration");
    }

    #[test]
    fn classify_inv1_failure_detects_offline_respawning_when_fully_registered() {
        let fleet = FleetRunnerStats {
            expected_total: EXPECTED_FLEET_RUNNERS,
            registered_count: EXPECTED_FLEET_RUNNERS,
            busy_count: EXPECTED_FLEET_RUNNERS - 1,
            idle_count: 0,
            missing_names: vec![],
            runners: vec![
                fleet_runner("ez-runner-c-1", "online", true),
                fleet_runner("ez-runner-c-2", "offline", false),
            ],
        };
        assert_eq!(classify_inv1_failure(&fleet), "offline-respawning");
    }

    #[test]
    fn classify_inv1_failure_falls_back_to_genuinely_idle() {
        let fleet = FleetRunnerStats {
            expected_total: EXPECTED_FLEET_RUNNERS,
            registered_count: EXPECTED_FLEET_RUNNERS,
            busy_count: EXPECTED_FLEET_RUNNERS - 1,
            idle_count: 1,
            missing_names: vec![],
            runners: vec![
                fleet_runner("ez-runner-c-1", "online", true),
                fleet_runner("ez-runner-c-2", "online", false),
            ],
        };
        assert_eq!(classify_inv1_failure(&fleet), "genuinely-idle");
    }

    #[test]
    fn append_invariant_sample_writes_exact_schema_fields() {
        let (mut cfg, dir, _log) = test_config_with_log();
        let history = dir.join("invariant_history.jsonl");
        cfg.invariant_sampler.history_path = Some(history.clone());
        let sample = InvariantSample {
            ts: 1_700_000_000,
            busy: 20,
            registered: 22,
            queued_jobs: 3,
            oldest_queued_job_min: 12.5,
            oldest_running_job_min: 4.0,
            inv1: false,
            inv2: true,
            inv1_fail_class: Some("genuinely-idle".into()),
        };

        append_invariant_sample(&cfg, &sample).unwrap();
        append_invariant_sample(&cfg, &sample).unwrap();

        let raw = fs::read_to_string(&history).unwrap();
        let lines: Vec<&str> = raw.lines().collect();
        assert_eq!(lines.len(), 2, "one JSON line appended per sample");
        let parsed: serde_json::Value = serde_json::from_str(lines[0]).unwrap();
        let obj = parsed.as_object().unwrap();
        for key in [
            "ts",
            "busy",
            "registered",
            "queued_jobs",
            "oldest_queued_job_min",
            "oldest_running_job_min",
            "inv1",
            "inv2",
            "inv1_fail_class",
        ] {
            assert!(obj.contains_key(key), "missing schema field {key}");
        }
        assert_eq!(obj.len(), 9, "no extra fields beyond the E1 schema");
        assert_eq!(obj["busy"], 20);
        assert_eq!(obj["inv1"], false);
        assert_eq!(obj["inv1_fail_class"], "genuinely-idle");
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn invariant_history_path_honors_config_override() {
        let (mut cfg, dir, _log) = test_config_with_log();
        let custom = dir.join("custom-invariant-history.jsonl");
        cfg.invariant_sampler.history_path = Some(custom.clone());
        assert_eq!(invariant_history_path(&cfg), custom);
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn alert_invariant_violation_reports_both_invariants_when_both_fail() {
        alert::clear_alert_state();
        let (cfg, dir, log) = test_config_with_log();
        let sample = InvariantSample {
            ts: 1_700_000_000,
            busy: 18,
            registered: 20,
            queued_jobs: 5,
            oldest_queued_job_min: 45.0,
            oldest_running_job_min: 25.0,
            inv1: false,
            inv2: false,
            inv1_fail_class: Some("missing-registration".into()),
        };

        alert_invariant_violation(&cfg, &sample).unwrap();

        let raw = fs::read_to_string(&log).unwrap();
        assert!(raw.contains("\"event_key\":\"invariant.violation\""));
        assert!(raw.contains("\"severity\":\"CRITICAL\""));
        assert!(raw.contains("INV-1 utilization violated"));
        assert!(raw.contains("INV-2 duration violated"));
        assert!(raw.contains("fail_class=missing-registration"));
        let _ = fs::remove_dir_all(dir);
    }

    fn bad_stats() -> QueueStats {
        QueueStats {
            queued_total: 1,
            fresh_queued: 1,
            stale_queued: 0,
            in_progress_total: 0,
            p50_wait_minutes: 45.0,
            p90_wait_minutes: 45.0,
            max_fresh_wait_minutes: 45.0,
            max_in_progress_age_minutes: 0.0,
            max_current_job_age_minutes: 45.0,
            tail_warn_minutes: 20,
            stale_cutoff_hours: 8,
            tail_bad: true,
            oldest_fresh: Some(AgedQueueJob {
                run_id: 20,
                job_id: 2,
                name: "Presubmit".into(),
                head_branch: "feature".into(),
                url: "https://github.example/runs/2".into(),
                age_minutes: 45.0,
            }),
            oldest_stale: None,
            oldest_in_progress: None,
            fleet: None,
        }
    }

    fn test_config_with_log() -> (Config, std::path::PathBuf, std::path::PathBuf) {
        let mut cfg = Config::defaults_for(
            &crate::platform::Platform {
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
            "owner/repo".into(),
            Scope::Repo,
        );
        cfg.alert.alert_cooldown_secs = 900;
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("ezgha-queue-monitor-test-{nanos}"));
        let log = dir.join("alerts.jsonl");
        cfg.alert.log_path = Some(log.clone());
        (cfg, dir, log)
    }

    fn job(id: u64, name: &str, branch: &str, created_at: &str) -> QueueJob {
        QueueJob {
            run_id: id * 10,
            job_id: id,
            name: name.into(),
            head_branch: branch.into(),
            created_at: created_at.into(),
            started_at: None,
            url: format!("https://github.example/runs/{id}"),
        }
    }

    fn started_job(id: u64, name: &str, branch: &str, started_at: &str) -> QueueJob {
        QueueJob {
            started_at: Some(started_at.into()),
            ..job(id, name, branch, "2026-07-07T07:00:00Z")
        }
    }

    fn runner(name: &str, status: &str, busy: bool) -> github::RunnerInfo {
        github::RunnerInfo {
            id: 1,
            name: name.into(),
            status: status.into(),
            busy,
        }
    }
}
