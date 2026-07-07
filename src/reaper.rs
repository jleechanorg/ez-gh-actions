use serde::Serialize;

use crate::config::{Config, Scope};
use crate::github::{RunnerInfo, WorkflowJob, WorkflowRun};
use crate::queue_monitor::parse_github_timestamp_secs;

pub type RepoRunsWithJobs = Vec<(WorkflowRun, Vec<WorkflowJob>)>;

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ReaperPlan {
    pub runner_id: u64,
    pub runner_name: String,
    pub repo: String,
    pub run_id: u64,
    pub run_url: String,
    pub job_id: u64,
    pub job_url: Option<String>,
    pub age_seconds: u64,
    pub sequence: Vec<String>,
}

pub fn default_reaper_repos(cfg: &Config) -> Vec<String> {
    let mut repos = Vec::new();
    if cfg.github.scope == Scope::Repo {
        repos.push(cfg.github.target.clone());
    }
    if let Some(repo) = cfg.queue_monitor.repo.as_ref() {
        push_unique(&mut repos, repo);
    }
    if let Some(repo) = cfg.canary.repo.as_ref() {
        push_unique(&mut repos, repo);
    }
    repos
}

pub fn plan_reaper_actions(
    runners: &[RunnerInfo],
    repo_runs: &[(String, RepoRunsWithJobs)],
    allowed_prefixes: &[String],
    required_labels: &[String],
    min_age_seconds: u64,
    now_unix: u64,
) -> Vec<ReaperPlan> {
    let mut plans = Vec::new();
    for runner in runners {
        if !runner.busy || !runner_name_allowed(&runner.name, allowed_prefixes) {
            continue;
        }
        for (repo, runs) in repo_runs {
            for (run, jobs) in runs {
                if run.status != "in_progress" {
                    continue;
                }
                let Some(job) = jobs.iter().find(|job| job_matches_runner(job, runner)) else {
                    continue;
                };
                if job.status != "in_progress" || !has_required_labels(job, required_labels) {
                    continue;
                }
                let Some(started_at) = job.started_at.as_deref().or(run.run_started_at.as_deref())
                else {
                    continue;
                };
                let Some(started_unix) = parse_github_timestamp_secs(started_at) else {
                    continue;
                };
                if started_unix < 0 {
                    continue;
                }
                let age_seconds = now_unix.saturating_sub(started_unix as u64);
                if age_seconds < min_age_seconds {
                    continue;
                }
                plans.push(ReaperPlan {
                    runner_id: runner.id,
                    runner_name: runner.name.clone(),
                    repo: repo.clone(),
                    run_id: run.id,
                    run_url: run.html_url.clone(),
                    job_id: job.id,
                    job_url: job.html_url.clone(),
                    age_seconds,
                    sequence: vec![
                        format!("POST repos/{repo}/actions/runs/{}/cancel", run.id),
                        "poll correlated job until it is no longer in_progress".to_string(),
                        format!("DELETE runner registration {}", runner.id),
                    ],
                });
            }
        }
    }
    plans
}

fn push_unique(repos: &mut Vec<String>, repo: &str) {
    if !repos.iter().any(|existing| existing == repo) {
        repos.push(repo.to_string());
    }
}

fn runner_name_allowed(name: &str, allowed_prefixes: &[String]) -> bool {
    allowed_prefixes.iter().any(|prefix| {
        name.strip_prefix(prefix)
            .is_some_and(|rest| rest.starts_with('-'))
    })
}

fn job_matches_runner(job: &WorkflowJob, runner: &RunnerInfo) -> bool {
    if job.runner_id == Some(runner.id) {
        return true;
    }
    job.runner_name.as_deref() == Some(runner.name.as_str())
}

fn has_required_labels(job: &WorkflowJob, required_labels: &[String]) -> bool {
    required_labels
        .iter()
        .all(|required| job.labels.iter().any(|label| label == required))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(id: u64, status: &str) -> WorkflowRun {
        WorkflowRun {
            id,
            name: "CI".into(),
            display_title: "CI".into(),
            event: "push".into(),
            status: status.into(),
            conclusion: None,
            created_at: "2026-07-07T08:00:00Z".into(),
            run_started_at: Some("2026-07-07T08:00:00Z".into()),
            updated_at: "2026-07-07T08:10:00Z".into(),
            html_url: format!("https://github.example/runs/{id}"),
            head_branch: Some("main".into()),
            head_sha: "abc".into(),
        }
    }

    fn job(id: u64, runner_id: Option<u64>, runner_name: Option<&str>) -> WorkflowJob {
        WorkflowJob {
            id,
            name: "test".into(),
            status: "in_progress".into(),
            conclusion: None,
            created_at: "2026-07-07T08:00:00Z".into(),
            started_at: Some("2026-07-07T08:00:00Z".into()),
            completed_at: None,
            runner_id,
            runner_name: runner_name.map(str::to_string),
            runner_group_id: Some(1),
            runner_group_name: Some("Default".into()),
            labels: vec!["self-hosted".into(), "ezgha".into()],
            html_url: Some(format!("https://github.example/jobs/{id}")),
        }
    }

    fn runner(id: u64, name: &str) -> RunnerInfo {
        RunnerInfo {
            id,
            name: name.into(),
            status: "online".into(),
            busy: true,
        }
    }

    #[test]
    fn planner_matches_busy_runner_by_runner_id() {
        let plans = plan_reaper_actions(
            &[runner(42, "ez-runner-c-1")],
            &[(
                "owner/repo".into(),
                vec![(run(7, "in_progress"), vec![job(2, Some(42), None)])],
            )],
            &["ez-runner-c".into()],
            &["self-hosted".into(), "ezgha".into()],
            60,
            1_783_411_400,
        );

        assert_eq!(plans.len(), 1);
        assert_eq!(plans[0].runner_id, 42);
        assert_eq!(plans[0].run_id, 7);
        assert!(plans[0].sequence[0].contains("/cancel"));
    }

    #[test]
    fn planner_refuses_wrong_prefix_and_missing_labels() {
        let repo_runs = vec![(
            "owner/repo".into(),
            vec![(
                run(7, "in_progress"),
                vec![job(2, Some(42), Some("other-1"))],
            )],
        )];
        let wrong_prefix = plan_reaper_actions(
            &[runner(42, "other-1")],
            &repo_runs,
            &["ez-runner-c".into()],
            &["self-hosted".into(), "ezgha".into()],
            60,
            1_783_411_400,
        );
        assert!(wrong_prefix.is_empty());

        let missing_label = plan_reaper_actions(
            &[runner(42, "ez-runner-c-1")],
            &repo_runs,
            &["ez-runner-c".into()],
            &["self-hosted".into(), "missing".into()],
            60,
            1_783_411_400,
        );
        assert!(missing_label.is_empty());
    }

    #[test]
    fn planner_refuses_too_young_or_unmatched_jobs() {
        let too_young = plan_reaper_actions(
            &[runner(42, "ez-runner-c-1")],
            &[(
                "owner/repo".into(),
                vec![(run(7, "in_progress"), vec![job(2, Some(42), None)])],
            )],
            &["ez-runner-c".into()],
            &["self-hosted".into(), "ezgha".into()],
            3600,
            1_783_411_210,
        );
        assert!(too_young.is_empty());

        let unmatched = plan_reaper_actions(
            &[runner(42, "ez-runner-c-1")],
            &[(
                "owner/repo".into(),
                vec![(run(7, "in_progress"), vec![job(2, Some(99), None)])],
            )],
            &["ez-runner-c".into()],
            &["self-hosted".into(), "ezgha".into()],
            60,
            1_783_411_400,
        );
        assert!(unmatched.is_empty());
    }

    #[test]
    fn planner_handles_retired_prefix_when_explicitly_allowed() {
        let plans = plan_reaper_actions(
            &[runner(42, "ez-runner-b-11")],
            &[(
                "owner/repo".into(),
                vec![(
                    run(7, "in_progress"),
                    vec![job(2, Some(42), Some("ez-runner-b-11"))],
                )],
            )],
            &["ez-runner-c".into(), "ez-runner-b".into()],
            &["self-hosted".into(), "ezgha".into()],
            60,
            1_783_411_400,
        );
        assert_eq!(plans.len(), 1);
    }
}
