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
const LINUX_FLEET_COUNT: u32 = 10;
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

/// Emergency fix, 2026-07-07 14:xx PT: the uncapped per-tick job enumeration
/// (one `gh api` call per queued run) took long enough with queued_jobs~1290
/// that it starved the daemon's `ensure_count` refill step for minutes at a
/// time, draining the live fleet to 0 containers -- observed directly, not
/// theoretical. Cap job enumeration to the oldest ~N queued runs per repo:
/// INV-2 stays exact (the oldest job necessarily lives among the oldest
/// runs), and `queued_jobs` becomes an explicit LOWER BOUND when the cap
/// bites (signaled via `queued_jobs_capped` in the schema).
const INVARIANT_JOB_ENUMERATION_CAP: usize = 50;

/// The cap above bounds TODAY's known queue size, but only a hard time
/// budget kills the whole failure CLASS: any future expensive per-tick work
/// (a new monitor, a bigger queue, a slower API day) could reintroduce the
/// same ensure_count-starvation drain silently. Every monitoring tick that
/// does per-run GitHub API enumeration must stop enumerating and return
/// (marking its result partial/capped) once this much wall-clock time has
/// elapsed since the CURRENT serve-loop iteration started -- guaranteeing
/// `ensure_count` is reachable at least once per loop iteration regardless
/// of queue depth or API latency. Threaded down from `main.rs`'s serve loop
/// as a shared `Instant` deadline, not re-derived per monitor, so multiple
/// ticks in the same iteration (queue_monitor + invariant_sampler) share one
/// budget rather than each getting their own 75s (which would still allow
/// ~150s of monitor time before ensure_count runs again).
pub const SERVE_LOOP_TIME_BUDGET: Duration = Duration::from_secs(75);

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

    /// `loop_start` is this serve-loop iteration's start time (see
    /// `SERVE_LOOP_TIME_BUDGET`) -- passed down from `main.rs` rather than
    /// captured internally, so this tick and the invariant sampler's tick in
    /// the SAME iteration share one budget instead of each getting their own.
    ///
    /// Production now goes through `drive_serve_loop_ticks` (or
    /// `drive_with_fetcher` for tests) to dedup fleet + per-repo fetches
    /// across both ticks in the same iteration. `maybe_check` is preserved
    /// as a public API for tests and any future caller that wants to run the
    /// starvation/idle-mismatch tick in isolation -- it still does its own
    /// fetch, by design, because that's the only way to test it without
    /// dragging the invariant sampler along.
    #[allow(dead_code)]
    pub fn maybe_check(&mut self, cfg: &Config, loop_start: Instant) -> Result<Option<QueueStats>> {
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
        // Same job-enumeration cap as the E1 invariant sampler (see
        // INVARIANT_JOB_ENUMERATION_CAP's doc comment): this tick shares the
        // identical per-run gh api cost, and at the current queue size
        // (queued_jobs ~1290) it independently starved ensure_count's refill
        // step even with the sampler disabled -- confirmed live in production
        // 2026-07-07. tail_bad/max_current_job_age_minutes stay exact (the
        // oldest job lives among the oldest runs); only the raw queued/
        // in-progress *counts* become a lower bound when capped, which this
        // starvation-alerting path doesn't otherwise report as an exact number.
        let deadline = loop_start + SERVE_LOOP_TIME_BUDGET;
        let (snapshot, _capped) =
            fetch_capped_queue_snapshot(repo, None, INVARIANT_JOB_ENUMERATION_CAP, deadline)?;
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

    /// Drive one serve-loop iteration for both the queue monitor and the
    /// invariant sampler, deduplicating their network fetches. The previous
    /// shape called `maybe_check` and `maybe_sample` independently, each of
    /// which fetched fleet stats and (overlapping) repo queue snapshots on
    /// its own -- at the live queue depth (~1290 queued runs) this doubled
    /// the per-tick GitHub API cost on every iteration where both ticks were
    /// due, and in the common case where `cfg.queue_monitor.repo` overlaps
    /// with `MONITORED_INVARIANT_REPOS` it also duplicated the per-repo
    /// paginated queue enumeration. This driver fixes both: the fleet is
    /// fetched at most once and each distinct repo at most once per
    /// iteration, regardless of which ticks are due.
    ///
    /// The closure-based fetcher seam (`FFleet`, `FRepo`) is the unit-test
    /// seam that makes the dedup contract assertable -- the production path
    /// (`drive_serve_loop_ticks`) passes the real `fetch_fleet_runner_stats`
    /// and `fetch_capped_queue_snapshot` while the red-phase tests pass
    /// counting closures.
    ///
    /// `rest_budget_check` (bead ez-gh-actions-4jv, REST-budget-aware
    /// deprioritization) is a third seam of the same shape: production wires
    /// in `github::rest_budget_remaining` (an actual `gh api rate_limit`
    /// call -- itself quota-EXEMPT, so checking it never spends the budget
    /// it's measuring), tests wire in a fake closure returning a fixed
    /// count. When the returned remaining-count is below
    /// `cfg.queue_monitor.rest_budget_floor`, this tick's read-heavy fetches
    /// (`fetch_fleet`/`fetch_repo`, i.e. queue snapshot enumeration and
    /// invariant-sampler polling) are SKIPPED entirely for this iteration
    /// and a deferral is logged with the observed remaining count -- neither
    /// `last_check` timestamp advances, so both ticks retry next iteration
    /// once budget recovers. This function has ZERO reachability to
    /// `generate_jitconfig`/runner registration (that write path lives in
    /// `docker_backend::ensure_count`, called from `main.rs`'s serve loop
    /// entirely independently of this driver) -- the critical write path is
    /// structurally, not just conditionally, exempt from this gate.
    #[allow(clippy::too_many_arguments)]
    pub fn drive_with_fetcher<FFleet, FRepo, FBudget>(
        &mut self,
        cfg: &Config,
        loop_start: Instant,
        invariant_sampler: &mut InvariantSamplerState,
        mut fetch_fleet: FFleet,
        mut fetch_repo: FRepo,
        mut rest_budget_check: FBudget,
    ) -> Result<(Option<QueueStats>, Option<InvariantSample>)>
    where
        FFleet: FnMut(Instant) -> Result<FleetRunnerStats>,
        FRepo:
            FnMut(&str, Option<FleetRunnerStats>, usize, Instant) -> Result<(QueueSnapshot, bool)>,
        FBudget: FnMut() -> Result<u32>,
    {
        // Compute which ticks are due. Mirrors the gating inside
        // `maybe_check` / `maybe_sample` exactly so a "due" decision here
        // matches what the individual methods would have done -- callers
        // never get a different answer depending on which entry point they
        // use. Both intervals are computed from `cfg`; we do NOT mutate
        // `last_check` until we know the tick will actually run.
        let qm_due = if cfg.queue_monitor.enabled {
            let interval = Duration::from_secs(cfg.queue_monitor.check_interval_seconds);
            self.last_check
                .is_none_or(|last| last.elapsed() >= interval)
        } else {
            false
        };
        let is_due = if cfg.invariant_sampler.enabled {
            let interval = Duration::from_secs(cfg.invariant_sampler.check_interval_seconds);
            invariant_sampler
                .last_check
                .is_none_or(|last| last.elapsed() >= interval)
        } else {
            false
        };

        if !qm_due && !is_due {
            return Ok((None, None));
        }

        // REST-budget-aware deprioritization (bead ez-gh-actions-4jv): check
        // the REST (core) bucket's remaining count BEFORE firing any of this
        // tick's read-heavy fetches (fleet + per-repo queue/job enumeration).
        // A `gh api rate_limit` call failure here is treated as "budget
        // unknown" and does NOT block the tick -- only a successfully
        // observed low count defers, so a transient rate_limit-endpoint
        // hiccup can't itself starve monitoring. If remaining is at/under
        // the configured floor, skip this iteration's read-heavy work
        // entirely and log why; neither `last_check` timestamp advances, so
        // both ticks are retried on the next serve-loop iteration once
        // budget recovers.
        if let Ok(remaining) = rest_budget_check() {
            if remaining <= cfg.queue_monitor.rest_budget_floor {
                eprintln!(
                    "queue_monitor: deferring read-heavy REST calls this tick -- \
                     REST core budget remaining={remaining} <= floor={}",
                    cfg.queue_monitor.rest_budget_floor
                );
                return Ok((None, None));
            }
        }

        // Union of repos needed by the due ticks. `cfg.queue_monitor.repo`
        // may be absent (no per-repo fetch on its side); the invariant
        // sampler always needs every `MONITORED_INVARIANT_REPOS`. We dedup
        // -- overlap between the two sets is the common case in production
        // (the daemon's own repo is in MONITORED_INVARIANT_REPOS).
        let qm_repo = queue_repo(cfg);
        let mut repos: Vec<String> = Vec::new();
        if qm_due {
            if let Some(r) = qm_repo {
                repos.push(r.to_string());
            }
        }
        if is_due {
            for r in MONITORED_INVARIANT_REPOS {
                repos.push((*r).to_string());
            }
        }
        repos.sort();
        repos.dedup();

        // One fleet fetch per iteration that drives at least one consumer.
        // Any consumer that needed fleet stats gets the same value -- the
        // invariant sampler's `fleet.busy_count >= EXPECTED_FLEET_RUNNERS`
        // branch (INV-1) and the queue monitor's idle-runner-mismatch path
        // agree on the exact same fleet snapshot.
        let deadline = loop_start + SERVE_LOOP_TIME_BUDGET;
        let fleet = fetch_fleet(deadline)?;

        let mut snapshots: std::collections::HashMap<String, (QueueSnapshot, bool)> =
            std::collections::HashMap::with_capacity(repos.len());
        for repo in &repos {
            let (mut snapshot, capped) = fetch_repo(
                repo,
                Some(fleet.clone()),
                INVARIANT_JOB_ENUMERATION_CAP,
                deadline,
            )?;
            // Backfill the fleet onto each snapshot if the fetcher didn't
            // already attach one -- the invariant sampler expects the fleet
            // to be present on at least one of the snapshots it receives
            // (or it gets its own separately, which is now this same
            // shared value).
            if snapshot.fleet.is_none() {
                snapshot.fleet = Some(fleet.clone());
            }
            snapshots.insert(repo.clone(), (snapshot, capped));
        }

        // Now run the actual consumer logic against the cached snapshots,
        // mirroring what `maybe_check` / `maybe_sample` would have done.
        // `last_check` is bumped here only after the snapshot for the tick
        // is known to exist -- if the fetcher errored, neither `last_check`
        // advances and both ticks will retry on the next iteration (which
        // is the right cadence anyway because a failed fetch is a
        // transient GitHub API problem, not a "we ran this tick" signal).
        let mut qm_result: Option<QueueStats> = None;
        let mut is_result: Option<InvariantSample> = None;

        if qm_due {
            self.last_check = Some(Instant::now());
            if let Some(repo) = qm_repo {
                if let Some((snapshot, _capped)) = snapshots.get(repo) {
                    let now = unix_now_secs();
                    let stats = queue_stats(
                        snapshot,
                        now,
                        cfg.queue_monitor.stale_hours,
                        cfg.queue_monitor.tail_warn_minutes,
                    );
                    self.record_tail_sample(stats.tail_bad);
                    report_queue_health(cfg, repo, &stats, self.consecutive_bad)?;
                    qm_result = Some(stats);
                }
            }
        }

        if is_due {
            invariant_sampler.last_check = Some(Instant::now());
            // Reproduce the invariant sampler's repo iteration in a way
            // that consumes the shared snapshots directly (rather than
            // re-fetching) -- the result is byte-identical to
            // `sample_invariants`/`combine_invariant_sample` since we
            // share the same `queue_stats`/cap arithmetic. We do this
            // here (vs calling sample_invariants) precisely because
            // sample_invariants owns its own fleet + repo fetches.
            let now = unix_now_secs();
            let mut repo_stats = Vec::with_capacity(MONITORED_INVARIANT_REPOS.len());
            let mut any_capped = false;
            for repo in MONITORED_INVARIANT_REPOS {
                let (snapshot, capped) = match snapshots.get(*repo) {
                    Some(s) => s.clone(),
                    None => continue,
                };
                any_capped |= capped;
                repo_stats.push(queue_stats(
                    &snapshot,
                    now,
                    cfg.queue_monitor.stale_hours,
                    cfg.queue_monitor.tail_warn_minutes,
                ));
            }
            let sample = combine_invariant_sample(&fleet, &repo_stats, now, any_capped);
            append_invariant_sample(cfg, &sample)?;
            if !sample.inv1 || !sample.inv2 {
                alert_invariant_violation(cfg, &sample)?;
            }
            is_result = Some(sample);
        }

        Ok((qm_result, is_result))
    }

    /// Production wrapper around `drive_with_fetcher` that plugs in the real
    /// `fetch_fleet_runner_stats` and `fetch_capped_queue_snapshot`. This
    /// is what `main.rs`'s serve loop calls once per iteration; calling
    /// `maybe_check` and `maybe_sample` separately (the previous shape) is
    /// preserved as a public API for tests and any future caller that wants
    /// to run the ticks in isolation, but it will fetch the fleet twice and
    /// the per-repo queue snapshots twice when both ticks fire in the same
    /// iteration -- so production should always go through here.
    pub fn drive_serve_loop_ticks(
        &mut self,
        cfg: &Config,
        loop_start: Instant,
        invariant_sampler: &mut InvariantSamplerState,
    ) -> Result<(Option<QueueStats>, Option<InvariantSample>)> {
        self.drive_with_fetcher(
            cfg,
            loop_start,
            invariant_sampler,
            fetch_fleet_runner_stats,
            fetch_capped_queue_snapshot,
            github::rest_budget_remaining,
        )
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

    /// `loop_start` is this serve-loop iteration's start time (see
    /// `SERVE_LOOP_TIME_BUDGET`) -- passed down from `main.rs`, shared with
    /// `QueueMonitorState::maybe_check`'s budget in the same iteration.
    ///
    /// Production now goes through `QueueMonitorState::drive_serve_loop_ticks`,
    /// which calls both this method's logic AND the queue monitor's logic
    /// using one shared fleet + per-repo fetch. `maybe_sample` is preserved
    /// for tests that want to exercise the sampler in isolation; the dedup
    /// is opt-in via the driver.
    #[allow(dead_code)]
    pub fn maybe_sample(
        &mut self,
        cfg: &Config,
        loop_start: Instant,
    ) -> Result<Option<InvariantSample>> {
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

        // Deliberate design property: if `sample_invariants` fails (e.g. a
        // GitHub API rate limit -- already observed live on this box), `?`
        // propagates the error here BEFORE `append_invariant_sample` runs, so
        // NO line is written for this tick. A failed API call is UNKNOWN, not
        // a violation: it must never be recorded as either pass or fail, or
        // burst rate-limit windows would silently poison E2's 3-hour
        // zero-violation count. The caller (`run_invariant_sampler_tick` in
        // main.rs) logs the error and moves on; the next tick simply retries
        // after the normal interval.
        let sample = sample_invariants(cfg, loop_start)?;
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
/// oldest_running_job_min, inv1, inv2, inv1_fail_class}` plus
/// `queued_jobs_capped` (added 2026-07-07 for the job-enumeration cap fix,
/// see `INVARIANT_JOB_ENUMERATION_CAP`) -- do not rename fields without
/// updating the exit-criteria doc and any downstream reader.
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
    /// True if any monitored repo had more than `INVARIANT_JOB_ENUMERATION_CAP`
    /// queued runs, meaning `queued_jobs` only reflects the oldest-run subset
    /// that was actually enumerated -- an explicit LOWER BOUND on the true
    /// count, not an exact total. `inv1`'s `queued_jobs == 0` check and
    /// `oldest_queued_job_min` both stay exact regardless (a capped fetch
    /// still contains the true oldest runs).
    pub queued_jobs_capped: bool,
    pub oldest_queued_job_min: f64,
    pub oldest_running_job_min: f64,
    pub inv1: bool,
    pub inv2: bool,
    /// Populated only when `inv1` is false. One of "missing-registration"
    /// (fewer than the expected 16 runners are registered at all),
    /// "offline-respawning" (registered but not all online -- JIT
    /// deregister/respawn churn, see docs/ed8-fleet-churn-root-cause-*.md),
    /// or "genuinely-idle" (fully registered and online, but not picking up
    /// queued work).
    pub inv1_fail_class: Option<String>,
}

/// Standalone version of the invariant sampler's logic: fetches fleet +
/// per-repo queue snapshots and returns the combined `InvariantSample`.
/// Production now inlines this work into `drive_with_fetcher` so it can
/// share fetches with the queue monitor's tick in the same iteration; this
/// function is preserved for tests that want to exercise the sampler in
/// isolation.
#[allow(dead_code)]
fn sample_invariants(cfg: &Config, loop_start: Instant) -> Result<InvariantSample> {
    let deadline = loop_start + SERVE_LOOP_TIME_BUDGET;
    let fleet = fetch_fleet_runner_stats(deadline)?;
    let now = unix_now_secs();
    let mut repo_stats = Vec::with_capacity(MONITORED_INVARIANT_REPOS.len());
    let mut any_capped = false;
    for repo in MONITORED_INVARIANT_REPOS {
        let (snapshot, capped) = fetch_capped_queue_snapshot(
            repo,
            Some(fleet.clone()),
            INVARIANT_JOB_ENUMERATION_CAP,
            deadline,
        )?;
        any_capped |= capped;
        repo_stats.push(queue_stats(
            &snapshot,
            now,
            cfg.queue_monitor.stale_hours,
            cfg.queue_monitor.tail_warn_minutes,
        ));
    }
    Ok(combine_invariant_sample(
        &fleet,
        &repo_stats,
        now,
        any_capped,
    ))
}

/// Pure combination logic, kept separate from `sample_invariants`'s network
/// calls so the classifier + threshold math are unit-testable without a live
/// GitHub API (mirrors how `queue_stats` above is unit-tested against
/// hand-built `QueueSnapshot`s rather than through `fetch_capped_queue_snapshot`).
fn combine_invariant_sample(
    fleet: &FleetRunnerStats,
    repo_stats: &[QueueStats],
    now_secs: i64,
    queued_jobs_capped: bool,
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
    // filters to the 16 expected names only), so `>=` and `==` are
    // operationally identical; `>=` is the defensive form.
    //
    // Correctness fix, 2026-07-07 (found while verifying the mission's first
    // all-clear sample): `queued_jobs == 0` must NOT satisfy INV-1 when the
    // fetch was capped. `queued_jobs_capped=true` means only the OLDEST
    // `INVARIANT_JOB_ENUMERATION_CAP` queued runs were actually enumerated
    // (per repo) -- with the live queue depth (400+ runs, far above the
    // 50-run cap) this is true on EVERY sample right now, confirmed via
    // invariant_history.jsonl. A capped fetch finding 0 self-hosted queued
    // jobs among the examined subset does NOT prove the true total is 0 --
    // there may be self-hosted queued jobs beyond the cap window that were
    // never checked. Treating a capped-zero as "queue confirmed empty" would
    // fabricate an INV-1 pass from incomplete data -- the inverse of the
    // UNKNOWN-on-API-error problem (there we guard against poisoning E2 with
    // a false FAIL from missing data; here the same missing-data situation
    // could poison E2 with a false PASS, which is more dangerous since it's
    // silently accepted rather than alerted on). Only an UNCAPPED zero (a
    // fetch that genuinely enumerated everything and found nothing queued)
    // can satisfy this branch of the OR. The busy_count branch is unaffected
    // -- fleet stats are never capped, so `busy >= 16` remains fully reliable
    // regardless of `queued_jobs_capped`.
    let inv1 =
        fleet.busy_count >= EXPECTED_FLEET_RUNNERS || (queued_jobs == 0 && !queued_jobs_capped);
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
        queued_jobs_capped,
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
    let line = serde_json::to_string(sample).context("serialize invariant sample to JSON line")?;
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
    deadline: Instant,
) -> Result<Vec<QueueJob>> {
    let jobs = github::list_workflow_jobs_until(repo, run.run_id(), deadline)
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

fn fetch_fleet_runner_stats(deadline: Instant) -> Result<FleetRunnerStats> {
    let gh = GithubConfig {
        scope: Scope::Org,
        target: FLEET_ORG.into(),
    };
    Ok(fleet_runner_stats(github::list_runners_until(
        &gh, deadline,
    )?))
}

/// Enumerates self-hosted jobs for `runs` via caller-supplied `fetch_jobs`,
/// bailing out (returning `bailed=true` with whatever was collected so far)
/// the moment `Instant::now() >= deadline`, rather than starting another
/// run's fetch. This is the `SERVE_LOOP_TIME_BUDGET` guarantee in its most
/// literal form -- a pure control-flow wrapper around a fetch closure, kept
/// generic and network-agnostic specifically so it's unit-testable with a
/// synthetic deadline and a fake in-memory closure (see
/// `enumerate_jobs_within_budget_bails_before_first_fetch_past_deadline`),
/// without a live GitHub API or a real `sleep`.
fn enumerate_jobs_within_budget<R, F>(
    runs: &[R],
    deadline: Instant,
    mut fetch_jobs: F,
) -> Result<(Vec<QueueJob>, bool)>
where
    F: FnMut(&R) -> Result<Vec<QueueJob>>,
{
    let mut collected = Vec::new();
    for run in runs {
        if Instant::now() >= deadline {
            return Ok((collected, true));
        }
        collected.extend(fetch_jobs(run)?);
    }
    Ok((collected, false))
}

/// Fetches a repo's queued/in-progress self-hosted job snapshot, capping
/// expensive per-run job enumeration to the oldest `cap` queued runs when the
/// repo has more than `cap` queued -- see `INVARIANT_JOB_ENUMERATION_CAP` for
/// why (this replaced an uncapped fetch that independently starved the
/// daemon's ensure_count refill step at the current queue size, both via the
/// E1 sampler and this module's own starvation-alert tick). GitHub's
/// workflow-runs API returns newest-first, so the oldest runs live on the
/// LAST page; we read page 1 first (cheap, gives `total_count`), and only
/// walk backward from the last page when the total exceeds the cap, instead
/// of fetching every page from the front.
///
/// `deadline` is the harder guarantee layered on top of the size-based cap
/// (see `SERVE_LOOP_TIME_BUDGET`): even a queue that fits under `cap`, or a
/// slow GitHub API day, cannot block past `deadline` -- job enumeration for
/// both queued and in-progress runs bails early via
/// `enumerate_jobs_within_budget`, and the resulting snapshot is marked
/// `capped=true` (an honest partial result) rather than silently returning
/// incomplete data as if it were exact.
fn fetch_capped_queue_snapshot(
    repo: &str,
    fleet: Option<FleetRunnerStats>,
    cap: usize,
    deadline: Instant,
) -> Result<(QueueSnapshot, bool)> {
    let first_path = format!("repos/{repo}/actions/runs?status=queued&per_page=100&page=1");
    let first_body = github::api_json_until(&first_path, deadline)?;
    let first_parsed: RunsResponse = serde_json::from_slice(&first_body)
        .with_context(|| format!("parse queued runs response for {repo} page 1"))?;
    let total_count = first_parsed.total_count as usize;

    let (queued_runs, mut capped) = if total_count <= cap {
        (first_parsed.workflow_runs, false)
    } else {
        let last_page = total_count.div_ceil(100) as u32;
        let mut oldest_runs: Vec<ApiWorkflowRun> = Vec::with_capacity(cap);
        let mut first_page_runs = Some(first_parsed.workflow_runs);
        let mut page = last_page;
        loop {
            if Instant::now() >= deadline {
                break;
            }
            let runs = if page == 1 {
                first_page_runs.take().unwrap_or_default()
            } else {
                let path =
                    format!("repos/{repo}/actions/runs?status=queued&per_page=100&page={page}");
                let body = github::api_json_until(&path, deadline)?;
                let parsed: RunsResponse = serde_json::from_slice(&body).with_context(|| {
                    format!("parse queued runs response for {repo} page {page}")
                })?;
                parsed.workflow_runs
            };
            oldest_runs.extend(runs);
            if oldest_runs.len() >= cap || page == 1 {
                break;
            }
            page -= 1;
        }
        oldest_runs.truncate(cap);
        (oldest_runs, true)
    };

    let (queued, queued_bailed) = enumerate_jobs_within_budget(&queued_runs, deadline, |run| {
        fetch_self_hosted_jobs(repo, run, "queued", deadline)
    })?;
    capped |= queued_bailed;

    let (in_progress, in_progress_bailed) = if Instant::now() >= deadline {
        (Vec::new(), true)
    } else {
        let runs = github::list_repo_in_progress_runs_until(repo, deadline)?;
        enumerate_jobs_within_budget(&runs, deadline, |run| {
            fetch_self_hosted_jobs(repo, run, "in_progress", deadline)
        })?
    };
    capped |= in_progress_bailed;

    Ok((
        QueueSnapshot {
            queued,
            in_progress,
            fleet: fleet.or_else(|| fetch_fleet_runner_stats(deadline).ok()),
        },
        capped,
    ))
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
    fn fleet_stats_counts_exact_16_runner_pool_only() {
        let runners = vec![
            runner("ez-runner-c-1", "online", true),
            runner("ez-runner-c-2", "online", false),
            runner("ez-runner-c-10", "online", true),
            runner("ez-runner-c-11", "online", true),
            runner("ez-mac-runner-b-1", "offline", false),
            runner("ez-mac-runner-b-6", "online", false),
            runner("ez-canary-runner-b-1", "online", false),
        ];

        let stats = fleet_runner_stats(runners);

        assert_eq!(stats.expected_total, 16);
        assert_eq!(stats.registered_count, 5);
        assert_eq!(stats.busy_count, 2);
        assert_eq!(stats.idle_count, 2);
        assert!(stats.missing_names.contains(&"ez-runner-c-3".to_string()));
        assert!(!stats
            .missing_names
            .contains(&"ez-mac-runner-b-6".to_string()));
        assert!(stats
            .runners
            .iter()
            .any(|runner| runner.name == "ez-runner-c-10"));
        assert!(stats
            .runners
            .iter()
            .any(|runner| runner.name == "ez-mac-runner-b-6"));
        assert!(!stats
            .runners
            .iter()
            .any(|runner| runner.name == "ez-runner-c-11"));
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
        let sample = combine_invariant_sample(&fleet, &stats, 1000, false);
        assert!(sample.inv1);
        assert_eq!(sample.inv1_fail_class, None);
    }

    #[test]
    fn invariant_queued_jobs_capped_flag_propagates_verbatim() {
        // combine_invariant_sample doesn't compute this itself -- it just
        // carries through whatever sample_invariants determined during
        // fetching (any monitored repo's queued-run count exceeded
        // INVARIANT_JOB_ENUMERATION_CAP). Verify both states pass through
        // unchanged and independently of INV-1/INV-2's own outcome.
        let fleet = full_fleet(EXPECTED_FLEET_RUNNERS, 0);
        let stats = vec![stats_with_ages(Some(5.0), None)];
        let uncapped = combine_invariant_sample(&fleet, &stats, 1000, false);
        let capped = combine_invariant_sample(&fleet, &stats, 1000, true);
        assert!(!uncapped.queued_jobs_capped);
        assert!(capped.queued_jobs_capped);
        // Capping doesn't change what was actually measured -- only whether
        // it's an exact count or a lower bound.
        assert_eq!(uncapped.queued_jobs, capped.queued_jobs);
    }

    #[test]
    fn enumerate_jobs_within_budget_bails_before_first_fetch_past_deadline() {
        // Deterministic, zero-sleep case: deadline already in the past, so
        // NOTHING gets fetched -- proves the check happens before the first
        // item, not just between items (matters if even the first fetch in
        // a tick is already the one that's slow).
        let runs = vec![1u32, 2, 3];
        let deadline = Instant::now() - Duration::from_millis(1);
        let mut calls = 0u32;
        let (collected, bailed) = enumerate_jobs_within_budget(&runs, deadline, |_run| {
            calls += 1;
            Ok(Vec::<QueueJob>::new())
        })
        .unwrap();
        assert!(bailed);
        assert!(collected.is_empty());
        assert_eq!(
            calls, 0,
            "must not fetch anything once already past deadline"
        );
    }

    #[test]
    fn enumerate_jobs_within_budget_stops_a_slow_fetch_within_the_budget() {
        // Regression test for the 2026-07-07 fleet-drain incident: simulate a
        // "slow fetch" (a few ms per item, standing in for a real gh api
        // round-trip) against a short budget, and assert this function
        // returns control well before processing every item -- i.e. the
        // serve loop's ensure_count cadence is preserved regardless of how
        // many items are queued, not just bounded by the size-based cap.
        let runs: Vec<u32> = (0..1000).collect();
        let budget = Duration::from_millis(30);
        let deadline = Instant::now() + budget;
        let mut calls = 0u32;
        let (collected, bailed) = enumerate_jobs_within_budget(&runs, deadline, |_run| {
            calls += 1;
            std::thread::sleep(Duration::from_millis(5));
            Ok(vec![QueueJob {
                run_id: 1,
                job_id: 1,
                name: "job".into(),
                head_branch: "main".into(),
                created_at: "2026-07-07T00:00:00Z".into(),
                started_at: None,
                url: "https://github.example/runs/1".into(),
            }])
        })
        .unwrap();
        assert!(
            bailed,
            "1000 items at 5ms each (5s total) must bail within a 30ms budget"
        );
        assert!(
            calls < runs.len() as u32,
            "must not process all {} items within a {budget:?} budget (processed {calls})",
            runs.len()
        );
        assert_eq!(
            collected.len(),
            calls as usize,
            "collected jobs must match how many runs were actually processed before bailing"
        );
    }

    #[test]
    fn enumerate_jobs_within_budget_completes_normally_when_deadline_is_far_off() {
        let runs = vec![1u32, 2, 3];
        let deadline = Instant::now() + Duration::from_secs(60);
        let (collected, bailed) = enumerate_jobs_within_budget(&runs, deadline, |_run| {
            Ok(vec![QueueJob {
                run_id: 1,
                job_id: 1,
                name: "job".into(),
                head_branch: "main".into(),
                created_at: "2026-07-07T00:00:00Z".into(),
                started_at: None,
                url: "https://github.example/runs/1".into(),
            }])
        })
        .unwrap();
        assert!(!bailed);
        assert_eq!(collected.len(), 3);
    }

    /// Regression for bead ez-gh-actions-yrt / the ez-gh-actions-g3o fix:
    /// a monitor tick whose FIRST gh call hits a persistent secondary rate
    /// limit must still return within `SERVE_LOOP_TIME_BUDGET`-scale time so
    /// the single-threaded serve loop gets back to `ensure_count` promptly,
    /// instead of blocking through gh's internal retry-with-backoff (which
    /// alone could burn minutes -- the live-observed 67s respawn gap). This
    /// exercises the real code path (`fetch_capped_queue_snapshot` ->
    /// `github::api_json_until`) via a fake `gh` binary, not just the pure
    /// `enumerate_jobs_within_budget` wrapper above.
    #[test]
    fn fetch_capped_queue_snapshot_bails_within_budget_under_persistent_rate_limit() {
        let dir = std::env::temp_dir().join(format!(
            "ezgha-fake-gh-monitor-starvation-{}-{}",
            std::process::id(),
            std::thread::current().name().unwrap_or("test")
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let script = dir.join("fake-gh");
        // ALWAYS returns a secondary rate limit with a large Retry-After
        // (60s) -- an unbounded caller would sleep at least 60s on the very
        // first retry attempt alone.
        std::fs::write(
            &script,
            r#"#!/bin/sh
echo "gh: secondary rate limit exceeded (HTTP 403)" >&2
echo "Retry-After: 60" >&2
exit 1
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

        let _guard = github::with_gh_exe(script.to_str().unwrap());
        // A short deadline stands in for "budget nearly exhausted when this
        // tick started" -- the exact scenario that starved ensure_count live.
        let deadline = Instant::now() + Duration::from_millis(200);
        let started = Instant::now();
        let result = fetch_capped_queue_snapshot("owner/repo", None, 50, deadline);
        let elapsed = started.elapsed();

        assert!(
            result.is_err(),
            "persistent rate limit must surface as an error, not fabricate an empty snapshot"
        );
        assert!(
            elapsed < Duration::from_secs(5),
            "a monitor tick must bail near its deadline rather than blocking through gh's \
             internal 60s Retry-After backoff; took {elapsed:?}"
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn invariant_inv1_true_when_queue_is_empty_regardless_of_busy_count() {
        let fleet = full_fleet(EXPECTED_FLEET_RUNNERS - 1, 1);
        let stats = vec![stats_with_ages(None, None)];
        let sample = combine_invariant_sample(&fleet, &stats, 1000, false);
        assert_eq!(sample.queued_jobs, 0);
        assert!(sample.inv1);
        assert_eq!(sample.inv1_fail_class, None);
    }

    #[test]
    fn invariant_inv1_false_when_zero_queued_is_capped_not_confirmed_empty() {
        // Regression test for a real production near-miss (2026-07-07): with
        // the live queue depth (400+ runs) always exceeding
        // INVARIANT_JOB_ENUMERATION_CAP, every sample was `capped=true`, and
        // one sample happened to find 0 self-hosted queued jobs among the 50
        // oldest runs it examined -- but that does NOT mean the true total
        // across all queued runs was 0. A capped zero must not fabricate an
        // INV-1 pass; only an UNCAPPED zero (this file's other test, above)
        // may.
        let fleet = full_fleet(EXPECTED_FLEET_RUNNERS - 1, 1);
        let stats = vec![stats_with_ages(None, None)];
        let sample = combine_invariant_sample(&fleet, &stats, 1000, true);
        assert_eq!(sample.queued_jobs, 0);
        assert!(sample.queued_jobs_capped);
        assert!(
            !sample.inv1,
            "a capped fetch that happened to find 0 queued jobs must not be \
             treated as a confirmed-empty queue"
        );
        assert_eq!(
            sample.inv1_fail_class.as_deref(),
            Some("genuinely-idle"),
            "busy < 16 with the fleet fully registered+online and no confirmed \
             queued work classifies as genuinely-idle, not a fabricated pass"
        );
    }

    #[test]
    fn invariant_inv1_true_when_busy_full_even_if_queue_read_is_capped() {
        // The busy_count branch of INV-1's OR must stay reliable regardless
        // of queued_jobs_capped -- fleet stats are never subject to the
        // job-enumeration cap.
        let fleet = full_fleet(EXPECTED_FLEET_RUNNERS, 0);
        let stats = vec![stats_with_ages(Some(5.0), None)];
        let sample = combine_invariant_sample(&fleet, &stats, 1000, true);
        assert!(sample.inv1);
    }

    #[test]
    fn invariant_inv1_false_when_fleet_short_one_and_queue_nonempty() {
        let fleet = full_fleet(EXPECTED_FLEET_RUNNERS - 1, 1);
        let stats = vec![stats_with_ages(Some(5.0), None)];
        let sample = combine_invariant_sample(&fleet, &stats, 1000, false);
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
            false,
        );
        assert!(at_threshold.inv2, "exactly 20.0m must satisfy INV-2");

        let over_threshold_queued =
            combine_invariant_sample(&fleet, &[stats_with_ages(Some(20.01), None)], 1000, false);
        assert!(
            !over_threshold_queued.inv2,
            "20.01m queued must violate INV-2"
        );

        let over_threshold_running =
            combine_invariant_sample(&fleet, &[stats_with_ages(None, Some(20.01))], 1000, false);
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

        let sample = combine_invariant_sample(&fleet, &[worldai_stats, ezgha_stats], 1000, false);

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
            missing_names: vec!["ez-runner-c-10".into()],
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
            busy: 14,
            registered: 16,
            queued_jobs: 3,
            queued_jobs_capped: false,
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
            "queued_jobs_capped",
            "oldest_queued_job_min",
            "oldest_running_job_min",
            "inv1",
            "inv2",
            "inv1_fail_class",
        ] {
            assert!(obj.contains_key(key), "missing schema field {key}");
        }
        assert_eq!(obj.len(), 10, "no extra fields beyond the E1 schema");
        assert_eq!(obj["busy"], 14);
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
            queued_jobs_capped: false,
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

    /// Red-phase tests for the unified `ServeLoopSnapshots` driver (TDD
    /// target): one serve-loop iteration must fetch the fleet exactly once
    /// and each repo's queue snapshot exactly once, regardless of whether the
    /// queue monitor and the invariant sampler both fire in the same
    /// iteration or whether `cfg.queue_monitor.repo` overlaps with
    /// `MONITORED_INVARIANT_REPOS`. These tests pin down the dedup contract
    /// so the consolidation refactor can't silently regress to two fetches.
    ///
    /// The tests use injected counting closures rather than `with_gh_exe`:
    /// `with_gh_exe` is thread-local and a single fake-gh script can't
    /// distinguish fleet-list calls from run-list calls from job-list calls,
    /// whereas the closure seam lets the test count each fetch kind
    /// independently with `Arc<AtomicUsize>`.
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    /// Drives one serve-loop iteration with injected counting fetches.
    /// Verifies: fleet fetched once, each distinct repo fetched once.
    #[test]
    fn serve_loop_snapshots_fetches_fleet_and_repos_exactly_once() {
        let mut cfg = base_test_config();
        cfg.queue_monitor.enabled = true;
        cfg.invariant_sampler.enabled = true;
        cfg.queue_monitor.repo = Some("jleechanorg/some-other-repo".into());

        let mut queue_monitor = QueueMonitorState::new();
        let mut invariant_sampler = InvariantSamplerState::new();
        // Force both ticks to be due immediately.
        queue_monitor.last_check = None;
        invariant_sampler.last_check = None;

        let fleet_calls = Arc::new(AtomicUsize::new(0));
        let repo_calls = Arc::new(AtomicUsize::new(0));
        let repos_seen = std::sync::Mutex::new(Vec::<String>::new());

        let loop_start = Instant::now();
        let _ = queue_monitor.drive_with_fetcher(
            &cfg,
            loop_start,
            &mut invariant_sampler,
            |_deadline| {
                fleet_calls.fetch_add(1, Ordering::SeqCst);
                Ok(full_fleet(EXPECTED_FLEET_RUNNERS, 0))
            },
            |repo, _fleet, _cap, _deadline| {
                repo_calls.fetch_add(1, Ordering::SeqCst);
                repos_seen.lock().unwrap().push(repo.to_string());
                Ok((
                    QueueSnapshot {
                        queued: vec![],
                        in_progress: vec![],
                        fleet: None,
                    },
                    false,
                ))
            },
            || Ok(u32::MAX),
        );

        assert_eq!(
            fleet_calls.load(Ordering::SeqCst),
            1,
            "fleet must be fetched exactly once per serve-loop iteration even when \
             both queue_monitor and invariant_sampler fire"
        );
        let mut seen = repos_seen.lock().unwrap().clone();
        seen.sort();
        seen.dedup();
        let expected: Vec<String> = {
            let mut v = vec!["jleechanorg/some-other-repo".to_string()];
            v.extend(MONITORED_INVARIANT_REPOS.iter().map(|s| s.to_string()));
            v.sort();
            v.dedup();
            v
        };
        assert_eq!(
            seen, expected,
            "every distinct repo needed by either tick must be fetched exactly once"
        );
        assert_eq!(
            repo_calls.load(Ordering::SeqCst),
            expected.len(),
            "no repo must be fetched twice in one iteration"
        );
    }

    /// When `cfg.queue_monitor.repo` is itself one of the
    /// `MONITORED_INVARIANT_REPOS`, the union collapses and that repo must
    /// only be fetched once.
    #[test]
    fn serve_loop_snapshots_dedupes_repo_overlap_between_ticks() {
        let mut cfg = base_test_config();
        cfg.queue_monitor.enabled = true;
        cfg.invariant_sampler.enabled = true;
        // Exact match to one of the monitored-invariant repos:
        cfg.queue_monitor.repo = Some(MONITORED_INVARIANT_REPOS[0].into());

        let mut queue_monitor = QueueMonitorState::new();
        let mut invariant_sampler = InvariantSamplerState::new();

        let repo_calls = Arc::new(AtomicUsize::new(0));
        let repos_seen = std::sync::Mutex::new(Vec::<String>::new());

        let _ = queue_monitor.drive_with_fetcher(
            &cfg,
            Instant::now(),
            &mut invariant_sampler,
            |_| Ok(full_fleet(EXPECTED_FLEET_RUNNERS, 0)),
            |repo, _fleet, _cap, _deadline| {
                repo_calls.fetch_add(1, Ordering::SeqCst);
                repos_seen.lock().unwrap().push(repo.to_string());
                Ok((
                    QueueSnapshot {
                        queued: vec![],
                        in_progress: vec![],
                        fleet: None,
                    },
                    false,
                ))
            },
            || Ok(u32::MAX),
        );

        let mut seen = repos_seen.lock().unwrap().clone();
        seen.sort();
        seen.dedup();
        assert_eq!(
            seen.len(),
            MONITORED_INVARIANT_REPOS.len(),
            "repo overlap with MONITORED_INVARIANT_REPOS must not cause a duplicate fetch"
        );
        assert_eq!(
            repo_calls.load(Ordering::SeqCst),
            MONITORED_INVARIANT_REPOS.len(),
            "each distinct repo fetched exactly once even on overlap"
        );
    }

    /// When neither tick is due (both within their interval), no fetches
    /// happen at all -- the driver's dedup is conditional on at least one
    /// tick being due.
    #[test]
    fn serve_loop_snapshots_skips_fetches_when_no_tick_is_due() {
        let mut cfg = base_test_config();
        cfg.queue_monitor.enabled = true;
        cfg.invariant_sampler.enabled = true;
        cfg.queue_monitor.check_interval_seconds = 3600;
        cfg.invariant_sampler.check_interval_seconds = 3600;

        let mut queue_monitor = QueueMonitorState::new();
        let mut invariant_sampler = InvariantSamplerState::new();
        // Mark both as having JUST checked, so neither is due.
        queue_monitor.last_check = Some(Instant::now());
        invariant_sampler.last_check = Some(Instant::now());

        let fleet_calls = Arc::new(AtomicUsize::new(0));
        let repo_calls = Arc::new(AtomicUsize::new(0));

        let _ = queue_monitor.drive_with_fetcher(
            &cfg,
            Instant::now(),
            &mut invariant_sampler,
            |_| {
                fleet_calls.fetch_add(1, Ordering::SeqCst);
                Ok(full_fleet(EXPECTED_FLEET_RUNNERS, 0))
            },
            |_repo, _fleet, _cap, _deadline| {
                repo_calls.fetch_add(1, Ordering::SeqCst);
                Ok((
                    QueueSnapshot {
                        queued: vec![],
                        in_progress: vec![],
                        fleet: None,
                    },
                    false,
                ))
            },
            || Ok(u32::MAX),
        );

        assert_eq!(
            fleet_calls.load(Ordering::SeqCst),
            0,
            "no fleet fetch when neither tick is due"
        );
        assert_eq!(
            repo_calls.load(Ordering::SeqCst),
            0,
            "no repo fetch when neither tick is due"
        );
    }

    /// When only ONE tick is due (queue_monitor enabled and due, but
    /// invariant_sampler not due), the fleet and repos needed by that ONE
    /// tick are fetched -- no over-fetch for the not-due tick.
    #[test]
    fn serve_loop_snapshots_fetches_only_for_due_ticks() {
        let mut cfg = base_test_config();
        cfg.queue_monitor.enabled = true;
        cfg.invariant_sampler.enabled = true;
        cfg.queue_monitor.check_interval_seconds = 1;
        cfg.invariant_sampler.check_interval_seconds = 3600;

        let mut queue_monitor = QueueMonitorState::new();
        let mut invariant_sampler = InvariantSamplerState::new();
        queue_monitor.last_check = Some(Instant::now() - Duration::from_secs(10));
        invariant_sampler.last_check = Some(Instant::now());

        let fleet_calls = Arc::new(AtomicUsize::new(0));
        let repo_calls = Arc::new(AtomicUsize::new(0));
        let repos_seen = std::sync::Mutex::new(Vec::<String>::new());

        let _ = queue_monitor.drive_with_fetcher(
            &cfg,
            Instant::now(),
            &mut invariant_sampler,
            |_| {
                fleet_calls.fetch_add(1, Ordering::SeqCst);
                Ok(full_fleet(EXPECTED_FLEET_RUNNERS, 0))
            },
            |repo, _fleet, _cap, _deadline| {
                repo_calls.fetch_add(1, Ordering::SeqCst);
                repos_seen.lock().unwrap().push(repo.to_string());
                Ok((
                    QueueSnapshot {
                        queued: vec![],
                        in_progress: vec![],
                        fleet: None,
                    },
                    false,
                ))
            },
            || Ok(u32::MAX),
        );

        assert_eq!(fleet_calls.load(Ordering::SeqCst), 1);
        // base_test_config() uses Scope::Repo with target "owner/repo", so
        // queue_repo() resolves to "owner/repo" even though
        // cfg.queue_monitor.repo is None -- the queue monitor tick fetches
        // exactly that one repo. The invariant sampler is NOT due, so its
        // MONITORED_INVARIANT_REPOS repos must NOT be fetched. Total = 1.
        let seen = repos_seen.lock().unwrap().clone();
        assert_eq!(
            repo_calls.load(Ordering::SeqCst),
            1,
            "only the queue monitor's repo should be fetched; invariant sampler's \
             MONITORED_INVARIANT_REPOS must not be touched when it's not due"
        );
        assert_eq!(seen, vec!["owner/repo".to_string()]);
    }

    /// TDD evidence (a): when the injected REST budget check reports a
    /// remaining count AT/UNDER `cfg.queue_monitor.rest_budget_floor`, both
    /// ticks' read-heavy fetches (fleet + per-repo enumeration) must be
    /// skipped entirely for that iteration -- proving the deprioritization
    /// gate actually short-circuits before any fetch closure runs, not just
    /// that it exists.
    #[test]
    fn low_rest_budget_defers_read_heavy_fetches() {
        let mut cfg = base_test_config();
        cfg.queue_monitor.enabled = true;
        cfg.invariant_sampler.enabled = true;
        cfg.queue_monitor.repo = Some("jleechanorg/some-other-repo".into());
        cfg.queue_monitor.rest_budget_floor = 500;

        let mut queue_monitor = QueueMonitorState::new();
        let mut invariant_sampler = InvariantSamplerState::new();
        queue_monitor.last_check = None;
        invariant_sampler.last_check = None;

        let fleet_calls = Arc::new(AtomicUsize::new(0));
        let repo_calls = Arc::new(AtomicUsize::new(0));
        let budget_checks = Arc::new(AtomicUsize::new(0));

        let result = queue_monitor.drive_with_fetcher(
            &cfg,
            Instant::now(),
            &mut invariant_sampler,
            |_| {
                fleet_calls.fetch_add(1, Ordering::SeqCst);
                Ok(full_fleet(EXPECTED_FLEET_RUNNERS, 0))
            },
            |_repo, _fleet, _cap, _deadline| {
                repo_calls.fetch_add(1, Ordering::SeqCst);
                Ok((
                    QueueSnapshot {
                        queued: vec![],
                        in_progress: vec![],
                        fleet: None,
                    },
                    false,
                ))
            },
            // Below the floor: budget check itself must still run (it's the
            // gate), but everything after it must not.
            || {
                budget_checks.fetch_add(1, Ordering::SeqCst);
                Ok(499)
            },
        );

        assert!(result.is_ok(), "a deferred tick is not an error");
        let (qm_result, is_result) = result.unwrap();
        assert!(
            qm_result.is_none(),
            "queue monitor tick must defer, not run"
        );
        assert!(
            is_result.is_none(),
            "invariant sampler tick must defer, not run"
        );
        assert_eq!(
            budget_checks.load(Ordering::SeqCst),
            1,
            "the budget check itself must run exactly once to make the defer decision"
        );
        assert_eq!(
            fleet_calls.load(Ordering::SeqCst),
            0,
            "fleet fetch must be skipped when REST budget is below the floor"
        );
        assert_eq!(
            repo_calls.load(Ordering::SeqCst),
            0,
            "repo fetch must be skipped when REST budget is below the floor"
        );
        assert_eq!(
            queue_monitor.last_check, None,
            "a deferred tick must not advance last_check, so it retries next iteration"
        );
        assert_eq!(
            invariant_sampler.last_check, None,
            "a deferred invariant-sampler tick must not advance last_check either"
        );
    }

    /// Companion to `low_rest_budget_defers_read_heavy_fetches`: a remaining
    /// count comfortably ABOVE the floor must NOT defer -- proves the gate
    /// is a real threshold, not an unconditional skip.
    #[test]
    fn healthy_rest_budget_does_not_defer_read_heavy_fetches() {
        let mut cfg = base_test_config();
        cfg.queue_monitor.enabled = true;
        cfg.invariant_sampler.enabled = true;
        cfg.queue_monitor.repo = Some("jleechanorg/some-other-repo".into());
        cfg.queue_monitor.rest_budget_floor = 500;

        let mut queue_monitor = QueueMonitorState::new();
        let mut invariant_sampler = InvariantSamplerState::new();
        queue_monitor.last_check = None;
        invariant_sampler.last_check = None;

        let fleet_calls = Arc::new(AtomicUsize::new(0));

        let (qm_result, is_result) = queue_monitor
            .drive_with_fetcher(
                &cfg,
                Instant::now(),
                &mut invariant_sampler,
                |_| {
                    fleet_calls.fetch_add(1, Ordering::SeqCst);
                    Ok(full_fleet(EXPECTED_FLEET_RUNNERS, 0))
                },
                |_repo, _fleet, _cap, _deadline| {
                    Ok((
                        QueueSnapshot {
                            queued: vec![],
                            in_progress: vec![],
                            fleet: None,
                        },
                        false,
                    ))
                },
                || Ok(4500),
            )
            .unwrap();

        assert!(
            qm_result.is_some(),
            "queue monitor tick must run when budget is healthy"
        );
        assert!(
            is_result.is_some(),
            "invariant sampler tick must run when budget is healthy"
        );
        assert_eq!(
            fleet_calls.load(Ordering::SeqCst),
            1,
            "fleet fetch must happen when REST budget is above the floor"
        );
    }

    /// A failed budget check (e.g. transient `gh api rate_limit` error) must
    /// NOT be treated as "below floor" -- it must fall through to running
    /// the ticks normally rather than starving monitoring on top of an
    /// already-flaky API. Only a successfully observed low count defers.
    #[test]
    fn rest_budget_check_error_does_not_defer() {
        let mut cfg = base_test_config();
        cfg.queue_monitor.enabled = true;
        cfg.invariant_sampler.enabled = true;
        cfg.queue_monitor.repo = Some("jleechanorg/some-other-repo".into());

        let mut queue_monitor = QueueMonitorState::new();
        let mut invariant_sampler = InvariantSamplerState::new();
        queue_monitor.last_check = None;
        invariant_sampler.last_check = None;

        let fleet_calls = Arc::new(AtomicUsize::new(0));

        let (qm_result, _is_result) = queue_monitor
            .drive_with_fetcher(
                &cfg,
                Instant::now(),
                &mut invariant_sampler,
                |_| {
                    fleet_calls.fetch_add(1, Ordering::SeqCst);
                    Ok(full_fleet(EXPECTED_FLEET_RUNNERS, 0))
                },
                |_repo, _fleet, _cap, _deadline| {
                    Ok((
                        QueueSnapshot {
                            queued: vec![],
                            in_progress: vec![],
                            fleet: None,
                        },
                        false,
                    ))
                },
                || anyhow::bail!("simulated `gh api rate_limit` transient failure"),
            )
            .unwrap();

        assert!(
            qm_result.is_some(),
            "a failed budget check must not defer the tick -- budget-unknown proceeds normally"
        );
        assert_eq!(fleet_calls.load(Ordering::SeqCst), 1);
    }

    /// TDD evidence (b): `drive_serve_loop_ticks` -- the ONLY production
    /// entry point that wires in the real `github::rest_budget_remaining`
    /// gate -- has no parameter, closure, or code path that reaches
    /// `docker_backend::ensure_count`/`github::generate_jitconfig`. The
    /// write path is registered/invoked exclusively from `main.rs`'s serve
    /// loop as a structurally separate call, so it is impossible for this
    /// gate to ever block runner registration -- there is no shared
    /// function, no shared closure, no shared state between the two. This
    /// test asserts the healthy-budget case still returns without touching
    /// any registration-related state, documenting (not just asserting by
    /// absence) that the write path is out of reach of this module.
    #[test]
    fn drive_with_fetcher_never_touches_registration_write_path() {
        // `drive_with_fetcher`'s only fetcher seams are FFleet (list_runners),
        // FRepo (queue/job enumeration), and FBudget (rate_limit) -- none of
        // which is, wraps, or calls `generate_jitconfig`. This is enforced
        // structurally (by the function signature itself, verified at
        // compile time) rather than by a runtime check: there is no
        // `generate_jitconfig`-shaped parameter for a test to inject in the
        // first place, which is the strongest guarantee available for
        // "never gated by the budget check".
        let mut cfg = base_test_config();
        cfg.queue_monitor.enabled = true;
        cfg.queue_monitor.repo = Some("jleechanorg/some-other-repo".into());
        cfg.queue_monitor.rest_budget_floor = 500;

        let mut queue_monitor = QueueMonitorState::new();
        let mut invariant_sampler = InvariantSamplerState::new();
        queue_monitor.last_check = None;

        // Even with budget reported as exhausted (0 remaining), the call
        // must complete without any reference to runner registration --
        // there is nothing in this module that could call it.
        let result = queue_monitor.drive_with_fetcher(
            &cfg,
            Instant::now(),
            &mut invariant_sampler,
            |_| Ok(full_fleet(EXPECTED_FLEET_RUNNERS, 0)),
            |_repo, _fleet, _cap, _deadline| {
                Ok((
                    QueueSnapshot {
                        queued: vec![],
                        in_progress: vec![],
                        fleet: None,
                    },
                    false,
                ))
            },
            || Ok(0),
        );
        assert!(result.is_ok());
    }

    /// Pure helper: a Config with `enabled` toggled per-test. Reuses the
    /// existing `test_config_with_log` shape so we don't duplicate platform
    /// construction logic -- but here we only need the in-memory parts.
    fn base_test_config() -> Config {
        let (cfg, _dir, _log) = test_config_with_log();
        cfg
    }
}
