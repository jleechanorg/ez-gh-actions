use anyhow::{Context, Result};
use serde::Serialize;
use std::path::Path;
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::alert::{self, Severity};
use crate::config::{Config, Scope};
use crate::github::{self, WorkflowJob, WorkflowRun};
use crate::queue_monitor::parse_github_timestamp_secs;

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct CanaryResult {
    pub nonce: String,
    pub repo: String,
    pub workflow: String,
    pub run_id: Option<u64>,
    pub job_id: Option<u64>,
    pub runner_name: Option<String>,
    pub status: String,
    pub conclusion: Option<String>,
    pub queued_at: Option<String>,
    pub started_at: Option<String>,
    pub completed_at: Option<String>,
    pub time_to_start_seconds: Option<i64>,
    pub time_to_complete_seconds: Option<i64>,
    pub slo_start_seconds: u64,
    pub slo_breached: bool,
    pub url: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct RunJobRunnerCorrelation {
    pub run_id: u64,
    pub job_id: u64,
    pub runner_name: Option<String>,
    pub runner_id: Option<u64>,
    pub run_status: String,
    pub job_status: String,
    pub job_conclusion: Option<String>,
    pub queued_at: String,
    pub started_at: Option<String>,
    pub completed_at: Option<String>,
    pub run_url: String,
    pub job_url: Option<String>,
}

#[derive(Debug)]
pub struct CanaryDaemonState {
    last_started_at: Option<Instant>,
    in_flight: Option<JoinHandle<Result<CanaryResult>>>,
}

impl CanaryDaemonState {
    pub fn new() -> Self {
        Self {
            last_started_at: Some(Instant::now()),
            in_flight: None,
        }
    }

    pub fn maybe_check(&mut self, cfg: &Config) -> bool {
        self.maybe_check_with(cfg, Instant::now(), |cfg| {
            thread::spawn(move || run_once(&cfg, None, None, true))
        })
    }

    fn maybe_check_with<F>(&mut self, cfg: &Config, now: Instant, spawn: F) -> bool
    where
        F: FnOnce(Config) -> JoinHandle<Result<CanaryResult>>,
    {
        self.collect_finished();
        if !cfg.canary.enabled || self.in_flight.is_some() {
            return false;
        }
        let interval = Duration::from_secs(cfg.canary.check_interval_seconds);
        if self
            .last_started_at
            .is_some_and(|last| now.saturating_duration_since(last) < interval)
        {
            return false;
        }

        self.last_started_at = Some(now);
        self.in_flight = Some(spawn(cfg.clone()));
        println!(
            "canary scheduler: dispatched background canary for workflow {}",
            cfg.canary.workflow
        );
        true
    }

    fn collect_finished(&mut self) -> bool {
        let Some(handle) = self.in_flight.as_ref() else {
            return false;
        };
        if !handle.is_finished() {
            return false;
        }
        let handle = self.in_flight.take().expect("checked in-flight canary");
        match handle.join() {
            Ok(Ok(result)) => {
                println!(
                    "canary scheduler: nonce={} status={} conclusion={:?} runner={:?} time_to_start={:?}s",
                    result.nonce,
                    result.status,
                    result.conclusion,
                    result.runner_name,
                    result.time_to_start_seconds
                );
                true
            }
            Ok(Err(err)) => {
                eprintln!("WARN: canary scheduler check failed: {err:#}");
                false
            }
            Err(_) => {
                eprintln!("WARN: canary scheduler worker panicked");
                false
            }
        }
    }
}

impl Default for CanaryDaemonState {
    fn default() -> Self {
        Self::new()
    }
}

pub fn canary_repo(cfg: &Config) -> Option<&str> {
    cfg.canary.repo.as_deref().or_else(|| {
        if cfg.github.scope == Scope::Repo {
            Some(cfg.github.target.as_str())
        } else {
            None
        }
    })
}

pub fn make_nonce() -> String {
    let now = unix_now_secs();
    format!("ezgha-canary-{now}-{}", std::process::id())
}

pub fn run_once(
    cfg: &Config,
    timeout_override: Option<u64>,
    nonce_override: Option<String>,
    send_alert: bool,
) -> Result<CanaryResult> {
    let repo = canary_repo(cfg)
        .context("canary.repo is required for org-scoped configs; set [canary].repo")?;
    let nonce = nonce_override.unwrap_or_else(make_nonce);
    github::dispatch_workflow(
        repo,
        &cfg.canary.workflow,
        &cfg.canary.ref_name,
        &nonce,
        &cfg.runner.labels,
    )?;

    let timeout = Duration::from_secs(timeout_override.unwrap_or(cfg.canary.poll_timeout_seconds));
    let poll_interval = Duration::from_secs(cfg.canary.poll_interval_seconds.max(1));
    let now = std::time::Instant::now();
    let deadline = now + timeout;
    let started_wait_deadline = now + Duration::from_secs(cfg.canary.slo_start_seconds);
    let mut last_result = CanaryResult {
        nonce: nonce.clone(),
        repo: repo.to_string(),
        workflow: cfg.canary.workflow.clone(),
        run_id: None,
        job_id: None,
        runner_name: None,
        status: "dispatched".into(),
        conclusion: None,
        queued_at: None,
        started_at: None,
        completed_at: None,
        time_to_start_seconds: None,
        time_to_complete_seconds: None,
        slo_start_seconds: cfg.canary.slo_start_seconds,
        slo_breached: false,
        url: None,
    };

    // canary `list_workflow_runs` / `list_workflow_jobs` are intentionally
    // NOT gated by the REST-budget floor (bead ez-gh-actions-4jv P1 scope
    // follow-up): canary runs in a deadline-bounded poll loop with its own
    // timeout (`cfg.canary.poll_timeout_seconds`), triggered by the
    // scheduler independently of the serve-loop hot path. Adding the gate
    // here would either (a) silently break canary observability on a
    // low-budget day, or (b) require threading `RestBudgetProbe` through
    // this hot loop -- the canary is a one-shot dispatch per scheduled
    // tick (default 600s), not a per-iteration serve-loop reader, so the
    // rate pressure is `2 * 1/600` calls/s = negligible vs. the serve
    // loop's `~1 call/30s` queue/invariant fetches. The same exemption
    // applies to `reaper::collect_repo_runs` (`list_repo_in_progress_runs`
    // + `list_workflow_jobs` on reaper.rs:336) which is invoked from
    // `main::run_reaper_plan` (CLI) and `docker_backend::reclaim_zombie_locked_runner`
    // (qbl self-heal) -- both are event-driven, not serve-loop reads.
    loop {
        let runs = github::list_workflow_runs(repo, &cfg.canary.workflow, 20)?;
        if let Some(run) = find_run_by_nonce(&runs, &nonce) {
            let jobs = github::list_workflow_jobs(repo, run.id)?;
            last_result = result_from_run_jobs(
                repo,
                &cfg.canary.workflow,
                &nonce,
                run,
                &jobs,
                &cfg.runner.name_prefix,
                cfg.canary.slo_start_seconds,
            );
            if last_result.status == "completed" {
                break;
            }
        }

        let now = std::time::Instant::now();
        if last_result.time_to_start_seconds.is_none() && now >= started_wait_deadline {
            last_result.status = if last_result.run_id.is_some() {
                "slo_timeout_waiting_for_start".into()
            } else {
                "slo_timeout_waiting_for_run".into()
            };
            last_result.slo_breached = true;
            break;
        }
        if now >= deadline {
            last_result.status = if last_result.run_id.is_some() {
                "timeout_after_run_seen".into()
            } else {
                "timeout_waiting_for_run".into()
            };
            last_result.slo_breached = true;
            break;
        }
        std::thread::sleep(
            poll_interval.min(deadline.saturating_duration_since(std::time::Instant::now())),
        );
    }

    if let Some(path) = cfg.canary.history_path.as_deref() {
        append_history(path, &last_result)?;
    }
    if send_alert && should_alert(&last_result) {
        alert_canary(cfg, &last_result)?;
    }
    Ok(last_result)
}

pub fn find_run_by_nonce<'a>(runs: &'a [WorkflowRun], nonce: &str) -> Option<&'a WorkflowRun> {
    runs.iter()
        .filter(|run| run.event == "workflow_dispatch")
        .find(|run| run.display_title.contains(nonce))
}

pub fn correlate_run_job(
    run: &WorkflowRun,
    jobs: &[WorkflowJob],
    runner_prefix: &str,
) -> Option<RunJobRunnerCorrelation> {
    let job = jobs.iter().find(|job| {
        job.runner_name
            .as_deref()
            .is_some_and(|name| runner_matches_prefix(name, runner_prefix))
    })?;
    Some(RunJobRunnerCorrelation {
        run_id: run.id,
        job_id: job.id,
        runner_name: job.runner_name.clone(),
        runner_id: job.runner_id,
        run_status: run.status.clone(),
        job_status: job.status.clone(),
        job_conclusion: job.conclusion.clone(),
        queued_at: run.created_at.clone(),
        started_at: job.started_at.clone(),
        completed_at: job.completed_at.clone(),
        run_url: run.html_url.clone(),
        job_url: job.html_url.clone(),
    })
}

pub fn result_from_run_jobs(
    repo: &str,
    workflow: &str,
    nonce: &str,
    run: &WorkflowRun,
    jobs: &[WorkflowJob],
    runner_prefix: &str,
    slo_start_seconds: u64,
) -> CanaryResult {
    let correlation = correlate_run_job(run, jobs, runner_prefix);
    let correlated_job = correlation.as_ref();
    let fallback_job = jobs.first();
    let fallback_runner_name = fallback_job
        .and_then(|job| job.runner_name.as_deref())
        .filter(|name| runner_matches_prefix(name, runner_prefix));
    let queued_at = run.created_at.clone();
    let started_at = correlated_job.and_then(|corr| corr.started_at.clone());
    let completed_at = correlated_job.and_then(|corr| corr.completed_at.clone());
    let time_to_start_seconds = duration_between(&queued_at, started_at.as_deref());
    let time_to_complete_seconds = duration_between(&queued_at, completed_at.as_deref());
    let status = if run.status == "completed" {
        "completed".to_string()
    } else if correlation.is_some() {
        "started".to_string()
    } else if let Some(job) = fallback_job {
        job.status.clone()
    } else {
        run.status.clone()
    };
    let conclusion = correlated_job
        .and_then(|corr| corr.job_conclusion.clone())
        .or_else(|| fallback_job.and_then(|job| job.conclusion.clone()))
        .or_else(|| run.conclusion.clone());
    let slo_breached = time_to_start_seconds
        .map(|secs| secs > slo_start_seconds as i64)
        .unwrap_or(run.status == "completed");

    CanaryResult {
        nonce: nonce.to_string(),
        repo: repo.to_string(),
        workflow: workflow.to_string(),
        run_id: Some(run.id),
        job_id: correlated_job
            .map(|corr| corr.job_id)
            .or_else(|| fallback_job.map(|job| job.id)),
        runner_name: correlated_job
            .and_then(|corr| corr.runner_name.clone())
            .or_else(|| fallback_runner_name.map(str::to_string)),
        status,
        conclusion,
        queued_at: Some(queued_at),
        started_at,
        completed_at,
        time_to_start_seconds,
        time_to_complete_seconds,
        slo_start_seconds,
        slo_breached,
        url: Some(run.html_url.clone()),
    }
}

pub fn should_alert(result: &CanaryResult) -> bool {
    result.slo_breached
        || result.conclusion.as_deref().is_some_and(|c| c != "success")
        || (result.status == "completed" && result.runner_name.is_none())
}

fn duration_between(start: &str, end: Option<&str>) -> Option<i64> {
    let start = parse_github_timestamp_secs(start)?;
    let end = parse_github_timestamp_secs(end?)?;
    Some((end - start).max(0))
}

fn runner_matches_prefix(runner_name: &str, runner_prefix: &str) -> bool {
    runner_name.starts_with(&format!("{runner_prefix}-"))
}

fn append_history(path: &Path, result: &CanaryResult) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("create canary history directory {}", parent.display()))?;
    }
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .with_context(|| format!("open canary history {}", path.display()))?;
    use std::io::Write;
    writeln!(file, "{}", serde_json::to_string(result)?)
        .with_context(|| format!("write canary history {}", path.display()))?;
    Ok(())
}

fn alert_canary(cfg: &Config, result: &CanaryResult) -> Result<()> {
    let body = format!(
        "{} {} nonce={} status={} conclusion={:?} runner={:?} time_to_start={:?}s slo={}s url={:?}",
        result.repo,
        result.workflow,
        result.nonce,
        result.status,
        result.conclusion,
        result.runner_name,
        result.time_to_start_seconds,
        result.slo_start_seconds,
        result.url
    );
    alert::notify(
        cfg,
        "canary.slo",
        Severity::Warning,
        "ezgha canary SLO breach",
        &body,
    )
}

fn unix_now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::platform::Platform;

    #[test]
    fn finds_workflow_run_by_nonce_in_display_title() {
        let runs = vec![
            run(1, "ezgha-selftest old", "workflow_dispatch", "completed"),
            run(
                2,
                "ezgha-selftest ezgha-canary-123",
                "workflow_dispatch",
                "queued",
            ),
            run(3, "ezgha-selftest ezgha-canary-123", "push", "queued"),
        ];

        let found = find_run_by_nonce(&runs, "ezgha-canary-123").unwrap();

        assert_eq!(found.id, 2);
    }

    #[test]
    fn correlates_run_to_prefix_matching_job() {
        let run = run(7, "ezgha-selftest nonce", "workflow_dispatch", "completed");
        let jobs = vec![
            job(1, Some("other-runner-1"), "completed", Some("success")),
            job(2, Some("ez-runner-c-9"), "completed", Some("success")),
        ];

        let corr = correlate_run_job(&run, &jobs, "ez-runner-c").unwrap();

        assert_eq!(corr.run_id, 7);
        assert_eq!(corr.job_id, 2);
        assert_eq!(corr.runner_name.as_deref(), Some("ez-runner-c-9"));
    }

    #[test]
    fn result_computes_slo_and_completion_times() {
        let run = WorkflowRun {
            created_at: "2026-07-07T08:00:00Z".into(),
            ..run(7, "ezgha-selftest nonce", "workflow_dispatch", "completed")
        };
        let jobs = vec![WorkflowJob {
            started_at: Some("2026-07-07T08:03:00Z".into()),
            completed_at: Some("2026-07-07T08:04:00Z".into()),
            ..job(2, Some("ez-runner-c-9"), "completed", Some("success"))
        }];

        let result = result_from_run_jobs(
            "owner/repo",
            "selftest.yml",
            "nonce",
            &run,
            &jobs,
            "ez-runner-c",
            90,
        );

        assert_eq!(result.time_to_start_seconds, Some(180));
        assert_eq!(result.time_to_complete_seconds, Some(240));
        assert!(result.slo_breached);
        assert!(should_alert(&result));
    }

    #[test]
    fn result_preserves_queued_job_before_runner_assignment() {
        let run = run(7, "ezgha-selftest nonce", "workflow_dispatch", "queued");
        let jobs = vec![job(2, None, "queued", None)];

        let result = result_from_run_jobs(
            "owner/repo",
            "selftest.yml",
            "nonce",
            &run,
            &jobs,
            "ez-runner-c",
            90,
        );

        assert_eq!(result.run_id, Some(7));
        assert_eq!(result.job_id, Some(2));
        assert_eq!(result.runner_name, None);
        assert_eq!(result.status, "queued");
        assert_eq!(result.time_to_start_seconds, None);
    }

    #[test]
    fn result_does_not_accept_wrong_runner_prefix_from_fallback_job() {
        let run = run(7, "ezgha-selftest nonce", "workflow_dispatch", "completed");
        let jobs = vec![job(2, Some("other-runner-1"), "completed", Some("success"))];

        let result = result_from_run_jobs(
            "owner/repo",
            "selftest.yml",
            "nonce",
            &run,
            &jobs,
            "ez-runner-c",
            90,
        );

        assert_eq!(result.run_id, Some(7));
        assert_eq!(result.job_id, Some(2));
        assert_eq!(result.runner_name, None);
        assert_eq!(result.status, "completed");
        assert_eq!(result.conclusion.as_deref(), Some("success"));
        assert_eq!(result.time_to_start_seconds, None);
        assert!(should_alert(&result));
    }

    #[test]
    fn history_writes_jsonl() {
        let result = CanaryResult {
            nonce: "nonce".into(),
            repo: "owner/repo".into(),
            workflow: "selftest.yml".into(),
            run_id: Some(1),
            job_id: Some(2),
            runner_name: Some("ez-runner-c-1".into()),
            status: "completed".into(),
            conclusion: Some("success".into()),
            queued_at: Some("2026-07-07T08:00:00Z".into()),
            started_at: Some("2026-07-07T08:00:10Z".into()),
            completed_at: Some("2026-07-07T08:00:20Z".into()),
            time_to_start_seconds: Some(10),
            time_to_complete_seconds: Some(20),
            slo_start_seconds: 90,
            slo_breached: false,
            url: Some("https://github.example/runs/1".into()),
        };
        let path = std::env::temp_dir().join(format!(
            "ezgha-canary-history-{}-{}.jsonl",
            std::process::id(),
            unix_now_secs()
        ));

        append_history(&path, &result).unwrap();

        let raw = std::fs::read_to_string(&path).unwrap();
        assert!(raw.contains("\"nonce\":\"nonce\""));
        assert!(raw.contains("\"runner_name\":\"ez-runner-c-1\""));
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn daemon_scheduler_waits_initial_interval_after_startup() {
        let mut cfg = test_config();
        cfg.canary.enabled = true;
        cfg.canary.check_interval_seconds = 600;
        let mut state = CanaryDaemonState::new();
        let now = Instant::now();

        let started = state.maybe_check_with(&cfg, now, |cfg| {
            thread::spawn(move || Ok(result(&cfg, "too-early")))
        });

        assert!(!started);
        assert!(state.in_flight.is_none());
    }

    #[test]
    fn daemon_scheduler_starts_when_interval_is_due() {
        let mut cfg = test_config();
        cfg.canary.enabled = true;
        cfg.canary.check_interval_seconds = 600;
        let mut state = ready_state();
        let now = Instant::now();

        let started = state.maybe_check_with(&cfg, now, |cfg| {
            thread::spawn(move || Ok(result(&cfg, "first")))
        });

        assert!(started);
        assert!(state.in_flight.is_some());
        std::thread::sleep(Duration::from_millis(10));
        assert!(state.collect_finished());
    }

    #[test]
    fn daemon_scheduler_respects_interval_and_in_flight_worker() {
        let mut cfg = test_config();
        cfg.canary.enabled = true;
        cfg.canary.check_interval_seconds = 600;
        let mut state = ready_state();
        let now = Instant::now();

        assert!(state.maybe_check_with(&cfg, now, |cfg| {
            thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(100));
                Ok(result(&cfg, "first"))
            })
        }));
        assert!(
            !state.maybe_check_with(&cfg, now + Duration::from_secs(600), |cfg| {
                thread::spawn(move || Ok(result(&cfg, "overlap")))
            })
        );
        std::thread::sleep(Duration::from_millis(150));
        assert!(state.collect_finished());
        assert!(
            !state.maybe_check_with(&cfg, now + Duration::from_secs(599), |cfg| {
                thread::spawn(move || Ok(result(&cfg, "too-soon")))
            })
        );
        assert!(
            state.maybe_check_with(&cfg, now + Duration::from_secs(600), |cfg| {
                thread::spawn(move || Ok(result(&cfg, "second")))
            })
        );
    }

    #[test]
    fn daemon_scheduler_disabled_does_not_dispatch() {
        let cfg = test_config();
        let mut state = CanaryDaemonState::new();

        let started = state.maybe_check_with(&cfg, Instant::now(), |cfg| {
            thread::spawn(move || Ok(result(&cfg, "disabled")))
        });

        assert!(!started);
        assert!(state.in_flight.is_none());
    }

    fn run(id: u64, display_title: &str, event: &str, status: &str) -> WorkflowRun {
        WorkflowRun {
            id,
            name: "ezgha-selftest".into(),
            display_title: display_title.into(),
            event: event.into(),
            status: status.into(),
            conclusion: None,
            created_at: "2026-07-07T08:00:00Z".into(),
            run_started_at: None,
            updated_at: "2026-07-07T08:00:00Z".into(),
            html_url: format!("https://github.example/runs/{id}"),
            head_branch: Some("main".into()),
            head_sha: "abc123".into(),
        }
    }

    fn job(
        id: u64,
        runner_name: Option<&str>,
        status: &str,
        conclusion: Option<&str>,
    ) -> WorkflowJob {
        WorkflowJob {
            id,
            name: "selftest".into(),
            status: status.into(),
            conclusion: conclusion.map(str::to_string),
            created_at: "2026-07-07T08:00:00Z".into(),
            started_at: None,
            completed_at: None,
            runner_id: Some(99),
            runner_name: runner_name.map(str::to_string),
            runner_group_id: Some(1),
            runner_group_name: Some("Default".into()),
            labels: vec!["self-hosted".into(), "ezgha".into()],
            html_url: Some(format!("https://github.example/jobs/{id}")),
        }
    }

    fn test_config() -> Config {
        let platform = Platform {
            os: "linux",
            arch: "x86_64",
            kvm_usable: false,
            has_tart: false,
            has_virsh: false,
            docker_ok: true,
            sysbox_runtime: false,
            daemon_in_vm: false,
            total_mem_mb: 8192,
            cpus: 8,
        };
        Config::defaults_for(&platform, "owner/repo".into(), Scope::Repo)
    }

    fn ready_state() -> CanaryDaemonState {
        CanaryDaemonState {
            last_started_at: None,
            in_flight: None,
        }
    }

    fn result(cfg: &Config, nonce: &str) -> CanaryResult {
        CanaryResult {
            nonce: nonce.into(),
            repo: "owner/repo".into(),
            workflow: cfg.canary.workflow.clone(),
            run_id: Some(1),
            job_id: Some(2),
            runner_name: Some("ez-runner-c-1".into()),
            status: "completed".into(),
            conclusion: Some("success".into()),
            queued_at: Some("2026-07-07T08:00:00Z".into()),
            started_at: Some("2026-07-07T08:00:10Z".into()),
            completed_at: Some("2026-07-07T08:00:20Z".into()),
            time_to_start_seconds: Some(10),
            time_to_complete_seconds: Some(20),
            slo_start_seconds: cfg.canary.slo_start_seconds,
            slo_breached: false,
            url: Some("https://github.example/runs/1".into()),
        }
    }
}
