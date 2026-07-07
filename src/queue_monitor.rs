use anyhow::{Context, Result};
use serde::Deserialize;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::alert::{self, Severity};
use crate::config::{Config, Scope};
use crate::github;

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

fn queue_repo(cfg: &Config) -> Option<&str> {
    cfg.queue_monitor.repo.as_deref().or_else(|| {
        if cfg.github.scope == Scope::Repo {
            Some(cfg.github.target.as_str())
        } else {
            None
        }
    })
}

fn fetch_queue_snapshot(repo: &str) -> Result<QueueSnapshot> {
    let mut queued = Vec::new();
    let mut page = 1u32;
    loop {
        let path = format!("repos/{repo}/actions/runs?status=queued&per_page=100&page={page}");
        let body = github::api_json(&path)?;
        let parsed: RunsResponse = serde_json::from_slice(&body)
            .with_context(|| format!("parse queued runs response for {repo} page {page}"))?;
        let len = parsed.workflow_runs.len();
        queued.extend(parsed.workflow_runs.into_iter().map(QueueRun::from));
        if len < 100 {
            break;
        }
        page = page.saturating_add(1);
    }

    let in_progress_path = format!("repos/{repo}/actions/runs?status=in_progress&per_page=1");
    let in_progress_body = github::api_json(&in_progress_path)?;
    let in_progress: RunsResponse = serde_json::from_slice(&in_progress_body)
        .with_context(|| format!("parse in-progress runs response for {repo}"))?;

    Ok(QueueSnapshot {
        queued,
        in_progress_total: in_progress.total_count,
    })
}

fn report_queue_health(
    cfg: &Config,
    repo: &str,
    stats: &QueueStats,
    consecutive_bad: u32,
) -> Result<()> {
    report_stale_queue(cfg, repo, stats)?;
    if !stats.tail_bad {
        println!(
            "queue monitor: {repo} queued={} fresh={} stale={} max_fresh_wait={:.1}m threshold={}m",
            stats.queued_total,
            stats.fresh_queued,
            stats.stale_queued,
            stats.max_fresh_wait_minutes,
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
            stats.max_fresh_wait_minutes,
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
        .map(|run| {
            format!(
                "oldest fresh queued run: id={} name={} branch={} age={:.1}m url={}",
                run.id, run.name, run.head_branch, run.age_minutes, run.url
            )
        })
        .unwrap_or_else(|| "oldest fresh queued run: none".to_string());
    let body = format!(
        "{repo} has {} queued runs (fresh={}, stale={}), {} in progress; fresh queue wait p50={:.1}m p90={:.1}m max={:.1}m exceeds threshold {}m. {oldest}",
        stats.queued_total,
        stats.fresh_queued,
        stats.stale_queued,
        stats.in_progress_total,
        stats.p50_wait_minutes,
        stats.p90_wait_minutes,
        stats.max_fresh_wait_minutes,
        stats.tail_warn_minutes,
    );
    alert::notify(cfg, event_key, severity, subject, &body)?;
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
        .map(|run| {
            format!(
                "oldest stale queued run: id={} name={} branch={} age={:.1}d url={}",
                run.id,
                run.name,
                run.head_branch,
                run.age_minutes / 1440.0,
                run.url
            )
        })
        .unwrap_or_else(|| "oldest stale queued run: none".to_string());
    let body = format!(
        "{repo} has {} stale queued run(s) older than the {}h cutoff; {oldest}",
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
    pub queued: Vec<QueueRun>,
    pub in_progress_total: u64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct QueueRun {
    pub id: u64,
    pub name: String,
    pub head_branch: String,
    pub created_at: String,
    pub url: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct QueueStats {
    pub queued_total: usize,
    pub fresh_queued: usize,
    pub stale_queued: usize,
    pub in_progress_total: u64,
    pub p50_wait_minutes: f64,
    pub p90_wait_minutes: f64,
    pub max_fresh_wait_minutes: f64,
    pub tail_warn_minutes: u64,
    pub stale_cutoff_hours: u64,
    pub tail_bad: bool,
    pub oldest_fresh: Option<AgedQueueRun>,
    pub oldest_stale: Option<AgedQueueRun>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct AgedQueueRun {
    pub id: u64,
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
    let mut stale_queued = 0usize;
    let mut oldest_fresh: Option<AgedQueueRun> = None;
    let mut oldest_stale: Option<AgedQueueRun> = None;

    for run in &snapshot.queued {
        let Some(created) = parse_github_timestamp_secs(&run.created_at) else {
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
                oldest_stale = Some(AgedQueueRun {
                    id: run.id,
                    name: run.name.clone(),
                    head_branch: run.head_branch.clone(),
                    url: run.url.clone(),
                    age_minutes,
                });
            }
            continue;
        }
        fresh_ages.push(age_minutes);
        if oldest_fresh
            .as_ref()
            .is_none_or(|old| age_minutes > old.age_minutes)
        {
            oldest_fresh = Some(AgedQueueRun {
                id: run.id,
                name: run.name.clone(),
                head_branch: run.head_branch.clone(),
                url: run.url.clone(),
                age_minutes,
            });
        }
    }

    fresh_ages.sort_by(|a, b| a.total_cmp(b));
    let max_fresh = fresh_ages.last().copied().unwrap_or(0.0);

    QueueStats {
        queued_total: snapshot.queued.len(),
        fresh_queued: fresh_ages.len(),
        stale_queued,
        in_progress_total: snapshot.in_progress_total,
        p50_wait_minutes: median(&fresh_ages),
        p90_wait_minutes: percentile(&fresh_ages, 0.9),
        max_fresh_wait_minutes: max_fresh,
        tail_warn_minutes,
        stale_cutoff_hours: stale_hours,
        tail_bad: max_fresh > tail_warn_minutes as f64,
        oldest_fresh,
        oldest_stale,
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
    total_count: u64,
    workflow_runs: Vec<ApiWorkflowRun>,
}

#[derive(Debug, Deserialize)]
struct ApiWorkflowRun {
    id: u64,
    name: String,
    #[serde(default)]
    head_branch: Option<String>,
    created_at: String,
    #[serde(default)]
    html_url: Option<String>,
}

impl From<ApiWorkflowRun> for QueueRun {
    fn from(run: ApiWorkflowRun) -> Self {
        Self {
            id: run.id,
            name: run.name,
            head_branch: run.head_branch.unwrap_or_default(),
            created_at: run.created_at,
            url: run.html_url.unwrap_or_default(),
        }
    }
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
            in_progress_total: 7,
            queued: vec![
                run(1, "Green Gate", "main", "2026-07-07T08:25:00Z"),
                run(2, "Presubmit", "feature", "2026-07-07T07:45:00Z"),
                run(3, "Zombie", "old", "2026-07-06T07:00:00Z"),
            ],
        };

        let stats = queue_stats(&snapshot, now, 8, 20);

        assert_eq!(stats.queued_total, 3);
        assert_eq!(stats.fresh_queued, 2);
        assert_eq!(stats.stale_queued, 1);
        assert_eq!(stats.in_progress_total, 7);
        assert!(stats.tail_bad);
        assert_eq!(stats.max_fresh_wait_minutes, 45.0);
        assert_eq!(stats.oldest_fresh.as_ref().map(|r| r.id), Some(2));
        assert_eq!(stats.oldest_stale.as_ref().map(|r| r.id), Some(3));
    }

    #[test]
    fn queue_stats_passes_when_tail_is_within_threshold() {
        let now = parse_github_timestamp_secs("2026-07-07T08:30:00Z").unwrap();
        let snapshot = QueueSnapshot {
            in_progress_total: 1,
            queued: vec![run(1, "Quick", "main", "2026-07-07T08:20:00Z")],
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
            in_progress_total: 0,
            queued: vec![
                run(1, "Exact threshold", "main", "2026-07-07T08:10:00Z"),
                run(2, "Future", "main", "2026-07-07T08:35:00Z"),
                run(3, "Exact stale cutoff", "main", "2026-07-07T00:30:00Z"),
                run(4, "Invalid", "main", "not-a-timestamp"),
            ],
        };

        let stats = queue_stats(&snapshot, now, 8, 20);

        assert_eq!(stats.queued_total, 4);
        assert_eq!(stats.fresh_queued, 2);
        assert_eq!(stats.stale_queued, 1);
        assert!(!stats.tail_bad);
        assert_eq!(stats.max_fresh_wait_minutes, 20.0);
        assert_eq!(stats.p50_wait_minutes, 10.0);
        assert_eq!(stats.p90_wait_minutes, 20.0);
        assert_eq!(stats.oldest_stale.as_ref().map(|r| r.id), Some(3));
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
            tail_warn_minutes: 20,
            stale_cutoff_hours: 8,
            tail_bad: false,
            oldest_fresh: None,
            oldest_stale: Some(AgedQueueRun {
                id: 9,
                name: "Zombie".into(),
                head_branch: "main".into(),
                url: "https://github.example/runs/9".into(),
                age_minutes: 1441.0,
            }),
        };

        report_queue_health(&cfg, "owner/repo", &stats, 0).unwrap();

        let raw = fs::read_to_string(&log).unwrap();
        assert!(raw.contains("\"event_key\":\"queue.stale.zombies\""));
        assert!(raw.contains("stale queued run"));
        let _ = fs::remove_dir_all(dir);
    }

    fn bad_stats() -> QueueStats {
        QueueStats {
            queued_total: 1,
            fresh_queued: 1,
            stale_queued: 0,
            in_progress_total: 7,
            p50_wait_minutes: 45.0,
            p90_wait_minutes: 45.0,
            max_fresh_wait_minutes: 45.0,
            tail_warn_minutes: 20,
            stale_cutoff_hours: 8,
            tail_bad: true,
            oldest_fresh: Some(AgedQueueRun {
                id: 2,
                name: "Presubmit".into(),
                head_branch: "feature".into(),
                url: "https://github.example/runs/2".into(),
                age_minutes: 45.0,
            }),
            oldest_stale: None,
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

    fn run(id: u64, name: &str, branch: &str, created_at: &str) -> QueueRun {
        QueueRun {
            id,
            name: name.into(),
            head_branch: branch.into(),
            created_at: created_at.into(),
            url: format!("https://github.example/runs/{id}"),
        }
    }
}
