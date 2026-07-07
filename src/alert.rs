use crate::config::{AlertConfig, Config};
use anyhow::{Context, Result};
use std::collections::HashMap;
use std::fs::OpenOptions;
use std::io::{Read, Write};
use std::path::Path;
use std::process::{Command, Output, Stdio};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const ALERT_COMMAND_TIMEOUT: Duration = Duration::from_secs(15);
const ALERT_CONNECT_TIMEOUT_SECS: &str = "5";
const ALERT_MAX_TIME_SECS: &str = "15";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Severity {
    Info,
    Warning,
    Critical,
}

impl std::fmt::Display for Severity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Info => write!(f, "INFO"),
            Self::Warning => write!(f, "WARNING"),
            Self::Critical => write!(f, "CRITICAL"),
        }
    }
}

fn alert_state() -> &'static Mutex<HashMap<String, Instant>> {
    static STATE: OnceLock<Mutex<HashMap<String, Instant>>> = OnceLock::new();
    STATE.get_or_init(|| Mutex::new(HashMap::new()))
}

#[cfg(test)]
pub(crate) fn clear_alert_state() {
    alert_state().lock().unwrap().clear();
}

#[cfg(test)]
pub(crate) fn should_send_now_for_test(event: &str, cooldown: Duration) -> bool {
    should_send(event, cooldown)
}

fn should_send(event: &str, cooldown: Duration) -> bool {
    let now = Instant::now();
    let map = alert_state().lock().unwrap();
    if let Some(last) = map.get(event) {
        if now.duration_since(*last) < cooldown {
            return false;
        }
    }
    true
}

fn record_sent(event: &str) {
    alert_state()
        .lock()
        .unwrap()
        .insert(event.to_string(), Instant::now());
}

fn is_dry_run() -> bool {
    std::env::var_os("EZGHA_ALERT_DRY_RUN").is_some()
}

fn slack_payload(subject: &str, body: &str, severity: Severity) -> String {
    format!(
        "{{\"text\":{}}}",
        serde_json::to_string(&format!(
            "[ez-gh-actions:{}] {}\n{}",
            severity, subject, body
        ))
        .unwrap_or_else(|_| format!("[ez-gh-actions:{}] {}\n{}", severity, subject, body))
    )
}

fn slack_curl_args(url: &str, payload: &str) -> Vec<String> {
    [
        "-sS",
        "--fail",
        "--connect-timeout",
        ALERT_CONNECT_TIMEOUT_SECS,
        "--max-time",
        ALERT_MAX_TIME_SECS,
        "-X",
        "POST",
        "-H",
        "Content-Type: application/json",
        "--data",
        payload,
        url,
    ]
    .into_iter()
    .map(str::to_string)
    .collect()
}

fn wait_child_with_timeout(
    mut child: std::process::Child,
    timeout: Duration,
    detail: &str,
) -> Result<Output> {
    let start = Instant::now();
    loop {
        if let Some(status) = child
            .try_wait()
            .with_context(|| format!("poll alert command for {detail}"))?
        {
            let mut stdout = Vec::new();
            let mut stderr = Vec::new();
            if let Some(mut pipe) = child.stdout.take() {
                let _ = pipe.read_to_end(&mut stdout);
            }
            if let Some(mut pipe) = child.stderr.take() {
                let _ = pipe.read_to_end(&mut stderr);
            }
            return Ok(Output {
                status,
                stdout,
                stderr,
            });
        }
        if start.elapsed() >= timeout {
            let _ = child.kill();
            let _ = child.wait();
            anyhow::bail!(
                "alert command timed out after {}s while {detail}",
                timeout.as_secs()
            );
        }
        std::thread::sleep(Duration::from_millis(25));
    }
}

fn run_command_with_timeout(mut cmd: Command, timeout: Duration) -> Result<Output> {
    let child = cmd
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("failed to invoke alert command")?;
    wait_child_with_timeout(child, timeout, "running alert command")
}

fn send_slack(url: &str, subject: &str, body: &str, severity: Severity) -> Result<()> {
    let payload = slack_payload(subject, body, severity);

    if is_dry_run() {
        eprintln!("{}", slack_dry_run_message(url, &payload));
        return Ok(());
    }

    let mut cmd = Command::new("curl");
    cmd.args(slack_curl_args(url, &payload));
    let out = run_command_with_timeout(cmd, ALERT_COMMAND_TIMEOUT)
        .context("failed to invoke curl for slack alert")?;
    if !out.status.success() {
        anyhow::bail!(
            "slack webhook call failed with status {}: {}",
            out.status,
            String::from_utf8_lossy(&out.stderr)
        );
    }
    Ok(())
}

fn slack_dry_run_message(_url: &str, payload: &str) -> String {
    format!("[dry-run] would send slack alert to configured webhook: {payload}")
}

fn email_message(
    from: Option<&str>,
    to: &str,
    subject: &str,
    body: &str,
    severity: Severity,
) -> String {
    let message_from = from.unwrap_or("ezgha@localhost");
    format!(
        "From: {}\nTo: {}\nSubject: [ez-gh-actions:{}] {}\n\n{}\n",
        message_from, to, severity, subject, body
    )
}

fn send_email(
    from: Option<&str>,
    to: &str,
    subject: &str,
    body: &str,
    severity: Severity,
) -> Result<()> {
    let sendmail = which::which("sendmail").context("sendmail not found in PATH")?;
    let message = email_message(from, to, subject, body, severity);

    if is_dry_run() {
        eprintln!("[dry-run] would send email alert to {}", to);
        return Ok(());
    }

    let mut proc = Command::new(sendmail)
        .arg("-t")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("failed to invoke sendmail")?;

    if let Some(mut stdin) = proc.stdin.take() {
        stdin
            .write_all(message.as_bytes())
            .context("failed to write email message body")?;
    }

    let out = wait_child_with_timeout(proc, ALERT_COMMAND_TIMEOUT, "sending email alert")?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        anyhow::bail!("sendmail failed: {err}");
    }
    Ok(())
}

fn send_log(
    path: &Path,
    event_key: &str,
    subject: &str,
    body: &str,
    severity: Severity,
) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("create alert log directory {}", parent.display()))?;
    }

    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let line = serde_json::json!({
        "ts_unix": ts,
        "event_key": event_key,
        "severity": severity.to_string(),
        "subject": subject,
        "body": body,
    });
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .with_context(|| format!("open alert log {}", path.display()))?;
    writeln!(file, "{line}").with_context(|| format!("write alert log {}", path.display()))?;
    Ok(())
}

pub fn configured_channels(cfg: &AlertConfig) -> bool {
    cfg.slack_webhook_url.is_some() || cfg.email_to.is_some() || cfg.log_path.is_some()
}

/// Send an alert and return whether any configured transport delivered it.
/// No-channel and cooldown-suppressed events return `Ok(false)`.
pub fn notify_delivery(
    cfg: &Config,
    event_key: &str,
    severity: Severity,
    subject: &str,
    body: &str,
) -> Result<bool> {
    if !configured_channels(&cfg.alert) {
        return Ok(false);
    }

    let cooldown = Duration::from_secs(cfg.alert.alert_cooldown_secs.max(1));
    if !should_send(event_key, cooldown) {
        return Ok(false);
    }

    let mut delivered = false;

    if let Some(slack_url) = cfg.alert.slack_webhook_url.as_deref() {
        match send_slack(slack_url, subject, body, severity) {
            Ok(()) => delivered = true,
            Err(err) => {
                eprintln!("WARN: slack alert send failed: {err:#}");
            }
        }
    }
    if let Some(email_to) = cfg.alert.email_to.as_deref() {
        match send_email(
            cfg.alert.email_from.as_deref(),
            email_to,
            subject,
            body,
            severity,
        ) {
            Ok(()) => delivered = true,
            Err(err) => {
                eprintln!("WARN: email alert send failed: {err:#}");
            }
        }
    }
    if let Some(log_path) = cfg.alert.log_path.as_deref() {
        match send_log(log_path, event_key, subject, body, severity) {
            Ok(()) => delivered = true,
            Err(err) => {
                eprintln!("WARN: file alert send failed: {err:#}");
            }
        }
    }
    if delivered {
        record_sent(event_key);
    }
    Ok(delivered)
}

/// Send an alert if at least one channel is configured and the event is not
/// within the per-event cooldown window. Returns `Ok(())` even when no channels
/// are configured so alerting is non-fatal for serve loop reliability.
pub fn notify(
    cfg: &Config,
    event_key: &str,
    severity: Severity,
    subject: &str,
    body: &str,
) -> Result<()> {
    notify_delivery(cfg, event_key, severity, subject, body).map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Config, Scope};
    use crate::platform::Platform;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::path::Path;
    use std::sync::{Mutex, OnceLock};
    use std::time::{SystemTime, UNIX_EPOCH};

    fn test_lock() -> std::sync::MutexGuard<'static, ()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(())).lock().unwrap()
    }

    fn platform() -> Platform {
        Platform {
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
        }
    }

    fn unique_temp_dir(name: &str) -> std::path::PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!("ezgha-alert-{name}-{nanos}"))
    }

    fn write_executable(path: &Path, contents: &str) {
        fs::write(path, contents).unwrap();
        let mut perms = fs::metadata(path).unwrap().permissions();
        perms.set_mode(0o755);
        fs::set_permissions(path, perms).unwrap();
    }

    fn with_fake_path<T>(dir: &Path, f: impl FnOnce() -> T) -> T {
        let original_path = std::env::var_os("PATH");
        let original_dry_run = std::env::var_os("EZGHA_ALERT_DRY_RUN");
        std::env::set_var("PATH", dir);
        std::env::remove_var("EZGHA_ALERT_DRY_RUN");
        let result = f();
        match original_path {
            Some(path) => std::env::set_var("PATH", path),
            None => std::env::remove_var("PATH"),
        }
        match original_dry_run {
            Some(value) => std::env::set_var("EZGHA_ALERT_DRY_RUN", value),
            None => std::env::remove_var("EZGHA_ALERT_DRY_RUN"),
        }
        result
    }

    fn logged_invocations(path: &Path) -> usize {
        fs::read_to_string(path).unwrap_or_default().lines().count()
    }

    #[test]
    fn alert_is_noop_without_channels() {
        let _guard = test_lock();
        clear_alert_state();
        let mut cfg = Config::defaults_for(&platform(), "jleechanorg".into(), Scope::Org);
        cfg.alert.slack_webhook_url = None;
        cfg.alert.email_to = None;

        assert!(notify(&cfg, "noop", Severity::Info, "x", "y").is_ok());
    }

    #[test]
    fn cooldown_blocks_repeated_events() {
        let _guard = test_lock();
        clear_alert_state();
        let mut cfg = Config::defaults_for(&platform(), "jleechanorg".into(), Scope::Org);
        cfg.alert.alert_cooldown_secs = 1;
        cfg.alert.slack_webhook_url = Some("http://example.invalid/".into());

        let original_path = std::env::var_os("PATH");
        std::env::set_var("EZGHA_ALERT_DRY_RUN", "1");
        std::env::set_var("PATH", "/nonexistent");
        assert!(notify(&cfg, "same", Severity::Warning, "t", "b").is_ok());
        assert!(notify(&cfg, "same", Severity::Warning, "t", "b").is_ok());

        let state = should_send_now_for_test("same", Duration::from_secs(1));
        assert!(
            !state,
            "event should be in cooldown after back-to-back alerts"
        );

        match original_path {
            Some(path) => std::env::set_var("PATH", path),
            None => std::env::remove_var("PATH"),
        }
    }

    #[test]
    fn failed_delivery_does_not_consume_cooldown() {
        let _guard = test_lock();
        clear_alert_state();
        let mut cfg = Config::defaults_for(&platform(), "jleechanorg".into(), Scope::Org);
        cfg.alert.alert_cooldown_secs = 60;
        cfg.alert.slack_webhook_url = Some("https://hooks.slack.test/T/fail".into());
        cfg.alert.email_to = Some("ops@example.test".into());

        let dir = unique_temp_dir("all-fail");
        fs::create_dir_all(&dir).unwrap();
        let log = dir.join("invocations.log");
        write_executable(
            &dir.join("curl"),
            &format!(
                "#!/bin/sh\nprintf 'curl\\n' >> '{}'\nexit 22\n",
                log.display()
            ),
        );
        write_executable(
            &dir.join("sendmail"),
            &format!(
                "#!/bin/sh\ncat >/dev/null\nprintf 'sendmail\\n' >> '{}'\nexit 1\n",
                log.display()
            ),
        );

        with_fake_path(&dir, || {
            assert!(notify(&cfg, "all-fail", Severity::Critical, "t", "b").is_ok());
            assert!(notify(&cfg, "all-fail", Severity::Critical, "t", "b").is_ok());
        });

        assert_eq!(
            logged_invocations(&log),
            4,
            "both failed transports should be retried on the next event"
        );
        assert!(
            should_send_now_for_test("all-fail", Duration::from_secs(60)),
            "failed delivery must not put the event into cooldown"
        );
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn one_successful_transport_consumes_cooldown() {
        let _guard = test_lock();
        clear_alert_state();
        let mut cfg = Config::defaults_for(&platform(), "jleechanorg".into(), Scope::Org);
        cfg.alert.alert_cooldown_secs = 60;
        cfg.alert.slack_webhook_url = Some("https://hooks.slack.test/T/fail".into());
        cfg.alert.email_to = Some("ops@example.test".into());

        let dir = unique_temp_dir("partial-success");
        fs::create_dir_all(&dir).unwrap();
        let log = dir.join("invocations.log");
        write_executable(
            &dir.join("curl"),
            &format!(
                "#!/bin/sh\nprintf 'curl\\n' >> '{}'\nexit 22\n",
                log.display()
            ),
        );
        write_executable(
            &dir.join("sendmail"),
            &format!(
                "#!/bin/sh\ncat >/dev/null\nprintf 'sendmail\\n' >> '{}'\nexit 0\n",
                log.display()
            ),
        );

        with_fake_path(&dir, || {
            assert!(notify(&cfg, "partial-success", Severity::Critical, "t", "b").is_ok());
            assert!(notify(&cfg, "partial-success", Severity::Critical, "t", "b").is_ok());
        });

        assert_eq!(
            logged_invocations(&log),
            2,
            "a successful transport should put the event into cooldown"
        );
        assert!(
            !should_send_now_for_test("partial-success", Duration::from_secs(60)),
            "one successful transport must record cooldown"
        );
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn file_log_channel_writes_jsonl_and_consumes_cooldown() {
        let _guard = test_lock();
        clear_alert_state();
        let mut cfg = Config::defaults_for(&platform(), "jleechanorg".into(), Scope::Org);
        cfg.alert.alert_cooldown_secs = 60;
        let dir = unique_temp_dir("file-log");
        let log = dir.join("alerts.jsonl");
        cfg.alert.log_path = Some(log.clone());

        let first = notify_delivery(
            &cfg,
            "gate7.test",
            Severity::Critical,
            "test alert",
            "durable body",
        )
        .unwrap();
        let second = notify_delivery(
            &cfg,
            "gate7.test",
            Severity::Critical,
            "test alert",
            "durable body",
        )
        .unwrap();

        assert!(first, "configured file log should count as delivery");
        assert!(!second, "second event should be cooldown-suppressed");
        let raw = fs::read_to_string(&log).unwrap();
        let lines: Vec<_> = raw.lines().collect();
        assert_eq!(lines.len(), 1);
        assert!(lines[0].contains("\"event_key\":\"gate7.test\""));
        assert!(lines[0].contains("\"severity\":\"CRITICAL\""));
        assert!(lines[0].contains("\"subject\":\"test alert\""));
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn payload_includes_context_for_slack() {
        let payload = slack_payload("pool low", "body", Severity::Critical);
        assert!(payload.contains("pool low"));
        assert!(payload.contains("CRITICAL"));
        assert!(payload.contains("body"));
    }

    #[test]
    fn email_message_subject_includes_severity_not_subject_twice() {
        let message = email_message(
            Some("from@example.test"),
            "ops@example.test",
            "pool low",
            "body",
            Severity::Critical,
        );
        assert!(message.contains("Subject: [ez-gh-actions:CRITICAL] pool low"));
        assert!(!message.contains("[ez-gh-actions:pool low] pool low"));
    }

    #[test]
    fn slack_curl_args_include_hard_timeouts() {
        let payload = slack_payload("pool low", "body", Severity::Warning);
        let args = slack_curl_args("https://hooks.slack.test/T/ABC", &payload);
        assert!(args.iter().any(|arg| arg == "--fail"));
        assert!(args.windows(2).any(|w| w == ["--connect-timeout", "5"]));
        assert!(args.windows(2).any(|w| w == ["--max-time", "15"]));
    }

    #[test]
    fn slack_dry_run_message_does_not_include_webhook_url() {
        let secret_url = "https://hooks.slack.test/T/SECRET";
        let payload = slack_payload("pool low", "body", Severity::Warning);
        let message = slack_dry_run_message(secret_url, &payload);

        assert!(
            !message.contains(secret_url),
            "dry-run output must not expose webhook URLs"
        );
        assert!(message.contains("configured webhook"));
        assert!(message.contains("pool low"));
    }

    #[test]
    fn slack_http_error_status_is_delivery_failure() {
        let _guard = test_lock();
        let dir = unique_temp_dir("slack-http-error");
        fs::create_dir_all(&dir).unwrap();
        write_executable(
            &dir.join("curl"),
            "#!/bin/sh\ncase \" $* \" in\n  *' --fail '*) exit 22 ;;\n  *) exit 0 ;;\nesac\n",
        );

        with_fake_path(&dir, || {
            let err = send_slack(
                "https://hooks.slack.test/T/fail",
                "subject",
                "body",
                Severity::Warning,
            )
            .expect_err("curl --fail HTTP errors should fail slack delivery");
            assert!(err.to_string().contains("slack webhook call failed"));
        });
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn command_timeout_kills_hung_process() {
        let start = Instant::now();
        let mut cmd = Command::new("/usr/bin/sleep");
        cmd.arg("30");
        let err = run_command_with_timeout(cmd, Duration::from_millis(200))
            .expect_err("hung alert command should time out");
        assert!(err.to_string().contains("timed out"));
        assert!(
            start.elapsed() < Duration::from_secs(5),
            "timeout helper must return promptly"
        );
    }
}
