use anyhow::{Context, Result};
use serde::Serialize;
use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

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
    github::dispatch_workflow(repo, &cfg.canary.workflow, &cfg.canary.ref_name, &nonce)?;

    let timeout = Duration::from_secs(timeout_override.unwrap_or(cfg.canary.poll_timeout_seconds));
    let poll_interval = Duration::from_secs(cfg.canary.poll_interval_seconds.max(1));
    let deadline = std::time::Instant::now() + timeout;
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

        if std::time::Instant::now() >= deadline {
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
            .is_some_and(|name| name.starts_with(&format!("{runner_prefix}-")))
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
    let job = correlation.as_ref();
    let time_to_start_seconds =
        job.and_then(|corr| duration_between(&corr.queued_at, corr.started_at.as_deref()));
    let time_to_complete_seconds =
        job.and_then(|corr| duration_between(&corr.queued_at, corr.completed_at.as_deref()));
    let status = if run.status == "completed" {
        "completed".to_string()
    } else if correlation.is_some() {
        "started".to_string()
    } else {
        run.status.clone()
    };
    let conclusion = job
        .and_then(|corr| corr.job_conclusion.clone())
        .or_else(|| run.conclusion.clone());
    let slo_breached = time_to_start_seconds
        .map(|secs| secs > slo_start_seconds as i64)
        .unwrap_or(run.status == "completed");

    CanaryResult {
        nonce: nonce.to_string(),
        repo: repo.to_string(),
        workflow: workflow.to_string(),
        run_id: Some(run.id),
        job_id: job.map(|corr| corr.job_id),
        runner_name: job.and_then(|corr| corr.runner_name.clone()),
        status,
        conclusion,
        queued_at: Some(run.created_at.clone()),
        started_at: job.and_then(|corr| corr.started_at.clone()),
        completed_at: job.and_then(|corr| corr.completed_at.clone()),
        time_to_start_seconds,
        time_to_complete_seconds,
        slo_start_seconds,
        slo_breached,
        url: Some(run.html_url.clone()),
    }
}

pub fn should_alert(result: &CanaryResult) -> bool {
    result.slo_breached || result.conclusion.as_deref().is_some_and(|c| c != "success")
}

fn duration_between(start: &str, end: Option<&str>) -> Option<i64> {
    let start = parse_github_timestamp_secs(start)?;
    let end = parse_github_timestamp_secs(end?)?;
    Some((end - start).max(0))
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
}
