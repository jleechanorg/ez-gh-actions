use anyhow::Result;
use serde::Serialize;

use crate::config::{Config, GithubConfig, Scope};
use crate::github::{self, RunnerInfo, WorkflowJob, WorkflowRun};
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

#[allow(dead_code)]
pub trait ReaperApi {
    fn cancel_workflow_run(&mut self, repo: &str, run_id: u64) -> Result<()>;
    fn force_cancel_workflow_run(&mut self, repo: &str, run_id: u64) -> Result<()>;
    fn list_workflow_jobs(&mut self, repo: &str, run_id: u64) -> Result<Vec<WorkflowJob>>;
    fn remove_runner(&mut self, runner_id: u64) -> Result<()>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
#[allow(dead_code)]
pub enum ReaperExecutionStatus {
    Completed,
    InvalidPollLimit,
    DuplicateRunnerPlan,
    CancelFailed,
    ForceCancelFailed,
    JobLookupFailed,
    JobMissing,
    JobCorrelationChanged,
    PollTimedOut,
    DeleteFailed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
#[allow(dead_code)]
pub enum ReaperStepStatus {
    Succeeded,
    Failed,
    Skipped,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[allow(dead_code)]
pub struct ReaperStepResult {
    pub action: String,
    pub status: ReaperStepStatus,
    pub detail: String,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[allow(dead_code)]
pub struct ReaperExecution {
    pub runner_id: u64,
    pub runner_name: String,
    pub repo: String,
    pub run_id: u64,
    pub job_id: u64,
    pub status: ReaperExecutionStatus,
    pub steps: Vec<ReaperStepResult>,
}

impl ReaperExecution {
    #[allow(dead_code)]
    fn new(plan: &ReaperPlan) -> Self {
        Self {
            runner_id: plan.runner_id,
            runner_name: plan.runner_name.clone(),
            repo: plan.repo.clone(),
            run_id: plan.run_id,
            job_id: plan.job_id,
            status: ReaperExecutionStatus::PollTimedOut,
            steps: Vec::new(),
        }
    }

    #[allow(dead_code)]
    fn push_step(
        &mut self,
        action: impl Into<String>,
        status: ReaperStepStatus,
        detail: impl Into<String>,
    ) {
        self.steps.push(ReaperStepResult {
            action: action.into(),
            status,
            detail: detail.into(),
        });
    }
}

#[allow(dead_code)]
pub fn execute_reaper_plan_with_api(
    api: &mut impl ReaperApi,
    plan: &ReaperPlan,
    poll_attempts: u32,
) -> ReaperExecution {
    let mut execution = ReaperExecution::new(plan);
    if poll_attempts == 0 {
        execution.status = ReaperExecutionStatus::InvalidPollLimit;
        execution.push_step(
            "validate poll attempts",
            ReaperStepStatus::Failed,
            "poll_attempts must be greater than zero",
        );
        return execution;
    }
    let cancel_action = format!(
        "POST repos/{}/actions/runs/{}/cancel",
        plan.repo, plan.run_id
    );
    if let Err(err) = api.cancel_workflow_run(&plan.repo, plan.run_id) {
        execution.status = ReaperExecutionStatus::CancelFailed;
        execution.push_step(cancel_action, ReaperStepStatus::Failed, err.to_string());
        execution.push_step(
            format!("DELETE runner registration {}", plan.runner_id),
            ReaperStepStatus::Skipped,
            "cancel failed",
        );
        return execution;
    }
    execution.push_step(
        cancel_action,
        ReaperStepStatus::Succeeded,
        "cancel accepted",
    );
    let delete_action = format!("DELETE runner registration {}", plan.runner_id);
    match poll_until_job_terminal(api, plan, &mut execution, poll_attempts, "cancel") {
        PollOutcome::Terminal => {}
        PollOutcome::StillInProgress => {
            let force_action = format!(
                "POST repos/{}/actions/runs/{}/force-cancel",
                plan.repo, plan.run_id
            );
            if let Err(err) = api.force_cancel_workflow_run(&plan.repo, plan.run_id) {
                execution.status = ReaperExecutionStatus::ForceCancelFailed;
                execution.push_step(force_action, ReaperStepStatus::Failed, err.to_string());
                execution.push_step(
                    delete_action,
                    ReaperStepStatus::Skipped,
                    "force-cancel failed",
                );
                return execution;
            }
            execution.push_step(
                force_action,
                ReaperStepStatus::Succeeded,
                "force-cancel accepted",
            );
            match poll_until_job_terminal(api, plan, &mut execution, poll_attempts, "force-cancel")
            {
                PollOutcome::Terminal => {}
                PollOutcome::StillInProgress => {
                    execution.status = ReaperExecutionStatus::PollTimedOut;
                    execution.push_step(
                        delete_action,
                        ReaperStepStatus::Skipped,
                        "job still in_progress",
                    );
                    return execution;
                }
                PollOutcome::Failed => {
                    execution.push_step(
                        delete_action,
                        ReaperStepStatus::Skipped,
                        "post-force-cancel polling failed",
                    );
                    return execution;
                }
            }
        }
        PollOutcome::Failed => {
            execution.push_step(
                delete_action,
                ReaperStepStatus::Skipped,
                "post-cancel polling failed",
            );
            return execution;
        }
    }

    if let Err(err) = api.remove_runner(plan.runner_id) {
        execution.status = ReaperExecutionStatus::DeleteFailed;
        execution.push_step(delete_action, ReaperStepStatus::Failed, err.to_string());
        return execution;
    }
    execution.status = ReaperExecutionStatus::Completed;
    execution.push_step(
        delete_action,
        ReaperStepStatus::Succeeded,
        "runner registration removed",
    );
    execution
}

#[allow(dead_code)]
pub fn execute_reaper_plans_with_api(
    api: &mut impl ReaperApi,
    plans: &[ReaperPlan],
    poll_attempts: u32,
) -> Vec<ReaperExecution> {
    let mut seen_runner_ids = std::collections::HashSet::new();
    let mut executions = Vec::new();
    for plan in plans {
        if !seen_runner_ids.insert(plan.runner_id) {
            let mut execution = ReaperExecution::new(plan);
            execution.status = ReaperExecutionStatus::DuplicateRunnerPlan;
            execution.push_step(
                "validate unique runner plan",
                ReaperStepStatus::Failed,
                "runner already has a reaper plan in this batch",
            );
            executions.push(execution);
            continue;
        }
        executions.push(execute_reaper_plan_with_api(api, plan, poll_attempts));
    }
    executions
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(dead_code)]
enum PollOutcome {
    Terminal,
    StillInProgress,
    Failed,
}

#[allow(dead_code)]
fn poll_until_job_terminal(
    api: &mut impl ReaperApi,
    plan: &ReaperPlan,
    execution: &mut ReaperExecution,
    poll_attempts: u32,
    phase: &str,
) -> PollOutcome {
    let poll_action = format!(
        "poll after {phase}: run {} job {} until not in_progress",
        plan.run_id, plan.job_id
    );
    for attempt in 1..=poll_attempts {
        let jobs = match api.list_workflow_jobs(&plan.repo, plan.run_id) {
            Ok(jobs) => jobs,
            Err(err) => {
                execution.status = ReaperExecutionStatus::JobLookupFailed;
                execution.push_step(
                    poll_action.clone(),
                    ReaperStepStatus::Failed,
                    format!("attempt {attempt}: {err}"),
                );
                return PollOutcome::Failed;
            }
        };
        let Some(job) = jobs.iter().find(|job| job.id == plan.job_id) else {
            execution.status = ReaperExecutionStatus::JobMissing;
            execution.push_step(
                poll_action.clone(),
                ReaperStepStatus::Failed,
                format!("attempt {attempt}: correlated job missing"),
            );
            return PollOutcome::Failed;
        };
        if !job_matches_plan(job, plan) {
            execution.status = ReaperExecutionStatus::JobCorrelationChanged;
            execution.push_step(
                poll_action.clone(),
                ReaperStepStatus::Failed,
                format!("attempt {attempt}: correlated job no longer belongs to planned runner"),
            );
            return PollOutcome::Failed;
        }
        if job.status != "in_progress" {
            execution.push_step(
                poll_action,
                ReaperStepStatus::Succeeded,
                format!("attempt {attempt}: job status={}", job.status),
            );
            return PollOutcome::Terminal;
        }
    }
    execution.status = ReaperExecutionStatus::PollTimedOut;
    execution.push_step(
        poll_action,
        ReaperStepStatus::Failed,
        format!("job stayed in_progress for {poll_attempts} poll attempts"),
    );
    PollOutcome::StillInProgress
}

#[allow(dead_code)]
fn job_matches_plan(job: &WorkflowJob, plan: &ReaperPlan) -> bool {
    if job.runner_id == Some(plan.runner_id) {
        return true;
    }
    job.runner_name.as_deref() == Some(plan.runner_name.as_str())
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

/// Fetch in-progress runs (and their jobs) for each repo, in the shape
/// `plan_reaper_actions` expects. Shared by the CLI `reaper-plan` command
/// (`main::run_reaper_plan`) and the docker_backend zombie-slot self-heal
/// path (bead ez-gh-actions-qbl) so both correlate a busy runner to its
/// phantom run/job through the exact same GitHub calls — no divergent
/// duplicate lookups.
///
/// SCOPE NOTE (bead ez-gh-actions-4jv P1 follow-up): `list_workflow_jobs`
/// here is intentionally NOT gated by the REST-budget floor. Both
/// callers of `collect_repo_runs` are event-driven (CLI invocation,
/// zombie-slot self-heal), not serve-loop iterations -- they cannot
/// starve `ensure_count` the way `queue_monitor`'s per-tick reads could.
/// See `canary::run_once` for the parallel exemption rationale.
pub fn collect_repo_runs(repos: &[String]) -> Result<Vec<(String, RepoRunsWithJobs)>> {
    let mut repo_runs = Vec::new();
    for repo in repos {
        let mut runs_with_jobs = Vec::new();
        for run in github::list_repo_in_progress_runs(repo)? {
            let jobs = github::list_workflow_jobs(repo, run.id)?;
            runs_with_jobs.push((run, jobs));
        }
        repo_runs.push((repo.clone(), runs_with_jobs));
    }
    Ok(repo_runs)
}

/// `ReaperApi` implementation that calls real GitHub via `crate::github`.
/// Used to wire `execute_reaper_plan_with_api` into production self-heal
/// paths (see `docker_backend::reclaim_zombie_locked_runner`); tests use
/// `test_support::FakeReaperApi` instead.
pub struct LiveReaperApi<'a> {
    gh: &'a GithubConfig,
}

impl<'a> LiveReaperApi<'a> {
    pub fn new(gh: &'a GithubConfig) -> Self {
        Self { gh }
    }
}

impl ReaperApi for LiveReaperApi<'_> {
    fn cancel_workflow_run(&mut self, repo: &str, run_id: u64) -> Result<()> {
        github::cancel_workflow_run(repo, run_id)
    }

    fn force_cancel_workflow_run(&mut self, repo: &str, run_id: u64) -> Result<()> {
        github::force_cancel_workflow_run(repo, run_id)
    }

    fn list_workflow_jobs(&mut self, repo: &str, run_id: u64) -> Result<Vec<WorkflowJob>> {
        github::list_workflow_jobs(repo, run_id)
    }

    fn remove_runner(&mut self, runner_id: u64) -> Result<()> {
        github::remove_runner(self.gh, runner_id)
    }
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

/// Test-only fixtures and a `ReaperApi` fake shared across `reaper`'s own
/// tests and `docker_backend`'s zombie-slot self-heal tests (bead
/// ez-gh-actions-qbl) so both exercise the cancel-then-delete sequencing
/// through the identical `cancel:{repo}:{run_id}` / `force-cancel:...` /
/// `delete:{runner_id}` call log, rather than two divergent mocks.
#[cfg(test)]
pub(crate) mod test_support {
    use super::*;
    use anyhow::bail;
    use std::collections::VecDeque;

    pub(crate) fn run(id: u64, status: &str) -> WorkflowRun {
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

    pub(crate) fn job(id: u64, runner_id: Option<u64>, runner_name: Option<&str>) -> WorkflowJob {
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

    pub(crate) fn runner(id: u64, name: &str) -> RunnerInfo {
        RunnerInfo {
            id,
            name: name.into(),
            status: "online".into(),
            busy: true,
        }
    }

    #[derive(Default)]
    pub(crate) struct FakeReaperApi {
        pub(crate) calls: Vec<String>,
        pub(crate) cancel_error: Option<String>,
        pub(crate) force_cancel_error: Option<String>,
        pub(crate) job_batches: VecDeque<Result<Vec<WorkflowJob>, String>>,
        pub(crate) delete_error: Option<String>,
    }

    impl ReaperApi for FakeReaperApi {
        fn cancel_workflow_run(&mut self, repo: &str, run_id: u64) -> Result<()> {
            self.calls.push(format!("cancel:{repo}:{run_id}"));
            if let Some(err) = self.cancel_error.take() {
                bail!("{err}");
            }
            Ok(())
        }

        fn force_cancel_workflow_run(&mut self, repo: &str, run_id: u64) -> Result<()> {
            self.calls.push(format!("force-cancel:{repo}:{run_id}"));
            if let Some(err) = self.force_cancel_error.take() {
                bail!("{err}");
            }
            Ok(())
        }

        fn list_workflow_jobs(&mut self, repo: &str, run_id: u64) -> Result<Vec<WorkflowJob>> {
            self.calls.push(format!("jobs:{repo}:{run_id}"));
            match self.job_batches.pop_front() {
                Some(Ok(jobs)) => Ok(jobs),
                Some(Err(err)) => bail!("{err}"),
                None => Ok(vec![job(2, Some(42), Some("ez-runner-c-1"))]),
            }
        }

        fn remove_runner(&mut self, runner_id: u64) -> Result<()> {
            self.calls.push(format!("delete:{runner_id}"));
            if let Some(err) = self.delete_error.take() {
                bail!("{err}");
            }
            Ok(())
        }
    }

    pub(crate) fn completed_job() -> WorkflowJob {
        let mut completed = job(2, Some(42), Some("ez-runner-c-1"));
        completed.status = "completed".into();
        completed.conclusion = Some("cancelled".into());
        completed.completed_at = Some("2026-07-07T09:00:00Z".into());
        completed
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::{completed_job, job, run, runner, FakeReaperApi};
    use super::*;
    use std::collections::VecDeque;

    fn plan() -> ReaperPlan {
        ReaperPlan {
            runner_id: 42,
            runner_name: "ez-runner-c-1".into(),
            repo: "owner/repo".into(),
            run_id: 7,
            run_url: "https://github.example/runs/7".into(),
            job_id: 2,
            job_url: Some("https://github.example/jobs/2".into()),
            age_seconds: 3600,
            sequence: vec![],
        }
    }

    fn completed_unrelated_job() -> WorkflowJob {
        let mut unrelated = completed_job();
        unrelated.id = 99;
        unrelated
    }

    fn reassigned_job() -> WorkflowJob {
        let mut reassigned = completed_job();
        reassigned.runner_id = Some(777);
        reassigned.runner_name = Some("ez-runner-c-777".into());
        reassigned
    }

    #[test]
    fn executor_cancels_polls_then_deletes_after_job_leaves_in_progress() {
        let mut api = FakeReaperApi {
            job_batches: VecDeque::from([
                Ok(vec![job(2, Some(42), Some("ez-runner-c-1"))]),
                Ok(vec![completed_job()]),
            ]),
            ..Default::default()
        };

        let execution = execute_reaper_plan_with_api(&mut api, &plan(), 3);

        assert_eq!(execution.status, ReaperExecutionStatus::Completed);
        assert_eq!(
            api.calls,
            [
                "cancel:owner/repo:7",
                "jobs:owner/repo:7",
                "jobs:owner/repo:7",
                "delete:42",
            ]
        );
        assert_eq!(
            execution.steps.last().expect("delete step recorded").status,
            ReaperStepStatus::Succeeded
        );
    }

    #[test]
    fn executor_refuses_delete_when_cancel_fails() {
        let mut api = FakeReaperApi {
            cancel_error: Some("cancel rejected".into()),
            ..Default::default()
        };

        let execution = execute_reaper_plan_with_api(&mut api, &plan(), 3);

        assert_eq!(execution.status, ReaperExecutionStatus::CancelFailed);
        assert_eq!(api.calls, ["cancel:owner/repo:7"]);
        assert_eq!(
            execution
                .steps
                .last()
                .expect("delete skip step recorded")
                .status,
            ReaperStepStatus::Skipped
        );
    }

    #[test]
    fn executor_refuses_to_mutate_with_zero_poll_limit() {
        let mut api = FakeReaperApi::default();

        let execution = execute_reaper_plan_with_api(&mut api, &plan(), 0);

        assert_eq!(execution.status, ReaperExecutionStatus::InvalidPollLimit);
        assert!(api.calls.is_empty());
    }

    #[test]
    fn executor_refuses_delete_when_poll_fails() {
        let mut api = FakeReaperApi {
            job_batches: VecDeque::from([Err("jobs api failed".into())]),
            ..Default::default()
        };

        let execution = execute_reaper_plan_with_api(&mut api, &plan(), 1);

        assert_eq!(execution.status, ReaperExecutionStatus::JobLookupFailed);
        assert_eq!(api.calls, ["cancel:owner/repo:7", "jobs:owner/repo:7"]);
        assert!(!api.calls.iter().any(|call| call.starts_with("delete:")));
    }

    #[test]
    fn executor_force_cancels_after_poll_budget_then_deletes() {
        let mut api = FakeReaperApi {
            job_batches: VecDeque::from([
                Ok(vec![job(2, Some(42), Some("ez-runner-c-1"))]),
                Ok(vec![completed_job()]),
            ]),
            ..Default::default()
        };

        let execution = execute_reaper_plan_with_api(&mut api, &plan(), 1);

        assert_eq!(execution.status, ReaperExecutionStatus::Completed);
        assert_eq!(
            api.calls,
            [
                "cancel:owner/repo:7",
                "jobs:owner/repo:7",
                "force-cancel:owner/repo:7",
                "jobs:owner/repo:7",
                "delete:42"
            ]
        );
    }

    #[test]
    fn executor_refuses_delete_when_force_cancel_fails() {
        let mut api = FakeReaperApi {
            force_cancel_error: Some("force denied".into()),
            job_batches: VecDeque::from([Ok(vec![job(2, Some(42), Some("ez-runner-c-1"))])]),
            ..Default::default()
        };

        let execution = execute_reaper_plan_with_api(&mut api, &plan(), 1);

        assert_eq!(execution.status, ReaperExecutionStatus::ForceCancelFailed);
        assert_eq!(
            api.calls,
            [
                "cancel:owner/repo:7",
                "jobs:owner/repo:7",
                "force-cancel:owner/repo:7"
            ]
        );
        assert!(!api.calls.iter().any(|call| call.starts_with("delete:")));
    }

    #[test]
    fn executor_refuses_delete_while_job_stays_in_progress_after_force_cancel() {
        let mut api = FakeReaperApi {
            job_batches: VecDeque::from([
                Ok(vec![job(2, Some(42), Some("ez-runner-c-1"))]),
                Ok(vec![job(2, Some(42), Some("ez-runner-c-1"))]),
            ]),
            ..Default::default()
        };

        let execution = execute_reaper_plan_with_api(&mut api, &plan(), 1);

        assert_eq!(execution.status, ReaperExecutionStatus::PollTimedOut);
        assert_eq!(
            api.calls,
            [
                "cancel:owner/repo:7",
                "jobs:owner/repo:7",
                "force-cancel:owner/repo:7",
                "jobs:owner/repo:7"
            ]
        );
        assert!(!api.calls.iter().any(|call| call.starts_with("delete:")));
    }

    #[test]
    fn executor_refuses_delete_when_correlated_job_is_missing() {
        let mut api = FakeReaperApi {
            job_batches: VecDeque::from([Ok(vec![completed_unrelated_job()])]),
            ..Default::default()
        };

        let execution = execute_reaper_plan_with_api(&mut api, &plan(), 1);

        assert_eq!(execution.status, ReaperExecutionStatus::JobMissing);
        assert_eq!(api.calls, ["cancel:owner/repo:7", "jobs:owner/repo:7"]);
        assert!(!api.calls.iter().any(|call| call.starts_with("delete:")));
    }

    #[test]
    fn executor_ignores_unrelated_terminal_job_when_correlated_job_is_still_running() {
        let mut api = FakeReaperApi {
            job_batches: VecDeque::from([Ok(vec![
                completed_unrelated_job(),
                job(2, Some(42), Some("ez-runner-c-1")),
            ])]),
            ..Default::default()
        };

        let execution = execute_reaper_plan_with_api(&mut api, &plan(), 1);

        assert_eq!(execution.status, ReaperExecutionStatus::PollTimedOut);
        assert_eq!(
            api.calls,
            [
                "cancel:owner/repo:7",
                "jobs:owner/repo:7",
                "force-cancel:owner/repo:7",
                "jobs:owner/repo:7"
            ]
        );
        assert!(!api.calls.iter().any(|call| call.starts_with("delete:")));
    }

    #[test]
    fn executor_refuses_delete_when_correlated_job_changes_runner() {
        let mut api = FakeReaperApi {
            job_batches: VecDeque::from([Ok(vec![reassigned_job()])]),
            ..Default::default()
        };

        let execution = execute_reaper_plan_with_api(&mut api, &plan(), 1);

        assert_eq!(
            execution.status,
            ReaperExecutionStatus::JobCorrelationChanged
        );
        assert_eq!(api.calls, ["cancel:owner/repo:7", "jobs:owner/repo:7"]);
        assert!(!api.calls.iter().any(|call| call.starts_with("delete:")));
    }

    #[test]
    fn executor_reports_delete_failure_after_safe_poll() {
        let mut api = FakeReaperApi {
            job_batches: VecDeque::from([Ok(vec![completed_job()])]),
            delete_error: Some("runner locked".into()),
            ..Default::default()
        };

        let execution = execute_reaper_plan_with_api(&mut api, &plan(), 1);

        assert_eq!(execution.status, ReaperExecutionStatus::DeleteFailed);
        assert_eq!(
            api.calls,
            ["cancel:owner/repo:7", "jobs:owner/repo:7", "delete:42"]
        );
    }

    #[test]
    fn executor_rejects_duplicate_runner_plans_without_second_mutation() {
        let mut api = FakeReaperApi {
            job_batches: VecDeque::from([Ok(vec![completed_job()])]),
            ..Default::default()
        };
        let first = plan();
        let mut duplicate = plan();
        duplicate.run_id = 8;

        let executions = execute_reaper_plans_with_api(&mut api, &[first, duplicate], 1);

        assert_eq!(executions[0].status, ReaperExecutionStatus::Completed);
        assert_eq!(
            executions[1].status,
            ReaperExecutionStatus::DuplicateRunnerPlan
        );
        assert_eq!(
            api.calls,
            ["cancel:owner/repo:7", "jobs:owner/repo:7", "delete:42"]
        );
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
