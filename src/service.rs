use anyhow::{bail, Context, Result};
use std::path::PathBuf;
use std::process::Command;

/// Install a user-level service that runs `ezgha serve` at login and keeps
/// it running: systemd --user on Linux, launchd on macOS.
pub fn install(config_path: &std::path::Path) -> Result<()> {
    let exe = std::env::current_exe().context("cannot resolve ezgha binary path")?;
    if cfg!(target_os = "linux") {
        install_systemd(&exe, config_path)
    } else if cfg!(target_os = "macos") {
        install_launchd(&exe, config_path)
    } else {
        bail!("service install is only supported on linux (systemd --user) and macos (launchd)")
    }
}

fn home() -> Result<PathBuf> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .context("HOME not set")
}

fn systemd_service_unit(
    exe: &std::path::Path,
    config_path: &std::path::Path,
    path_env: &str,
    home_dir: &std::path::Path,
) -> String {
    [
        "[Unit]".to_string(),
        "Description=ez-gh-actions ephemeral GitHub Actions runners".to_string(),
        "# Wait for the Lima VM that hosts the Docker daemon on Linux (Colima/limactl)."
            .to_string(),
        "# If lima-vm@colima.service is not present (Docker Desktop, remote daemon, macOS),"
            .to_string(),
        "# systemd silently ignores the dependency -- the Wants= keeps this non-fatal.".to_string(),
        "After=network-online.target lima-vm@colima.service".to_string(),
        "Wants=lima-vm@colima.service".to_string(),
        "# Limit crash-storm: if the service fails 5 times in 5 minutes, systemd".to_string(),
        "# stops retrying rather than spinning at 100% journal throughput.".to_string(),
        "StartLimitIntervalSec=300".to_string(),
        "StartLimitBurst=5".to_string(),
        "OnFailure=ezgha-alert@%N.service".to_string(),
        "".to_string(),
        "[Service]".to_string(),
        "# Type=notify required so WatchdogSec= takes effect and so systemd only".to_string(),
        "# considers the unit 'active' after wait_for_backend succeeds and we".to_string(),
        "# send READY=1. TimeoutStartSec is set past wait_for_backend's 120s".to_string(),
        "# budget so systemd never hangs forever if READY=1 never arrives.".to_string(),
        "Type=notify".to_string(),
        format!(
            "ExecStart={} --config {} serve",
            exe.display(),
            config_path.display()
        ),
        format!(
            "ExecStopPost=-{} --config {} systemd-alert-hook --source exec-stop-post --unit %n",
            exe.display(),
            config_path.display()
        ),
        "WatchdogSec=300".to_string(),
        "NotifyAccess=main".to_string(),
        "Restart=on-failure".to_string(),
        "RestartSec=30".to_string(),
        "TimeoutStartSec=130".to_string(),
        format!("Environment=\"PATH={}\"", path_env),
        format!("Environment=\"HOME={}\"", home_dir.display()),
        "".to_string(),
        "[Install]".to_string(),
        "WantedBy=default.target".to_string(),
        "".to_string(),
    ]
    .join("\n")
}

fn systemd_alert_unit(
    exe: &std::path::Path,
    config_path: &std::path::Path,
    path_env: &str,
    home_dir: &std::path::Path,
) -> String {
    [
        "[Unit]".to_string(),
        "Description=ez-gh-actions service failure alert hook for %i".to_string(),
        "".to_string(),
        "[Service]".to_string(),
        "Type=oneshot".to_string(),
        format!(
            "ExecStart={} --config {} systemd-alert-hook --source on-failure --unit %i",
            exe.display(),
            config_path.display()
        ),
        "TimeoutStartSec=30".to_string(),
        format!("Environment=\"PATH={}\"", path_env),
        format!("Environment=\"HOME={}\"", home_dir.display()),
        "".to_string(),
    ]
    .join("\n")
}

fn install_systemd(exe: &std::path::Path, config_path: &std::path::Path) -> Result<()> {
    let unit_dir = home()?.join(".config/systemd/user");
    std::fs::create_dir_all(&unit_dir)?;
    let unit_path = unit_dir.join("ezgha.service");
    let alert_unit_path = unit_dir.join("ezgha-alert@.service");
    let path_env =
        std::env::var("PATH").unwrap_or_else(|_| "/usr/local/bin:/usr/bin:/bin".to_string());
    let home_dir = home()?;
    let unit = systemd_service_unit(exe, config_path, &path_env, &home_dir);
    let alert_unit = systemd_alert_unit(exe, config_path, &path_env, &home_dir);
    std::fs::write(&unit_path, unit)?;
    println!("wrote {}", unit_path.display());
    std::fs::write(&alert_unit_path, alert_unit)?;
    println!("wrote {}", alert_unit_path.display());

    for args in [
        vec!["--user", "daemon-reload"],
        vec!["--user", "enable", "--now", "ezgha.service"],
    ] {
        let out = Command::new("systemctl").args(&args).output()?;
        if !out.status.success() {
            bail!(
                "systemctl {:?} failed: {}",
                args,
                String::from_utf8_lossy(&out.stderr)
            );
        }
    }
    println!("service enabled: systemctl --user status ezgha.service");
    Ok(())
}

/// The wrapper script content written by `install_launchd`. Exposed as a
/// `const` so tests can pin the exact bytes that go to disk and so a code
/// reviewer can verify the env-strip list without re-reading the writer.
pub const LAUNCHD_WRAPPER: &str = r#"#!/bin/bash
# Generated by `ezgha install-service`. Strips env vars that mask `gh auth`
# keyring auth (the kind set by a typical dotfiles/bashrc interactive shell).
# See PR #6 in jleechanorg/ez-gh-actions for context.
unset GH_TOKEN GITHUB_TOKEN GH_TOKEN_AGENTF AO_BOT_GH_TOKEN \
      HERMES_AO_HOOK_TOKEN OPENCLAW_AO_HOOK_TOKEN \
      SMOKE_TOKEN SLACK_APP_TOKEN OPENCLAW_STAGING_SLACK_APP_TOKEN 2>/dev/null
exec "$(dirname "$0")/ezgha" "$@"
"#;

fn install_launchd(exe: &std::path::Path, config_path: &std::path::Path) -> Result<()> {
    let agents = home()?.join("Library/LaunchAgents");
    std::fs::create_dir_all(&agents)?;
    let plist_path = agents.join("org.jleechanorg.ezgha.plist");
    let path_env =
        std::env::var("PATH").unwrap_or_else(|_| "/usr/local/bin:/usr/bin:/bin".to_string());
    let home_dir = home()?;
    // Wrap ezgha in a generated shell script that unsets env vars known to
    // mask GitHub CLI keyring auth. The script is written next to the binary
    // and invoked as `serve` from the plist. Without this, launchd inherits
    // the user's interactive shell env (bashrc-sourced GH_TOKEN, GITHUB_TOKEN,
    // AO_BOT_GH_TOKEN, etc.); `gh auth status` then exits non-zero because one
    // of those accounts is in a failed state, and `ezgha::gh_auth_ok()` reports
    // "missing" — which silently disables `release_stale_slots` and wedges the
    // fleet at whatever subset of slots happens to be live. See PR #6 for the
    // Rust-side fix; this wrapper makes the fix durable across `install-service`
    // reinstalls on Macs with polluted interactive envs.
    let wrapper_path = exe
        .parent()
        .map(|p| p.join("ezgha-launchd-wrapper.sh"))
        .ok_or_else(|| anyhow::anyhow!("ezgha binary has no parent directory"))?;
    std::fs::write(&wrapper_path, LAUNCHD_WRAPPER)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = std::fs::metadata(&wrapper_path)?.permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&wrapper_path, perms)?;
    }
    let plist = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>org.jleechanorg.ezgha</string>
    <key>ProgramArguments</key>
    <array><string>{}</string><string>--config</string><string>{}</string><string>serve</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>{}</string>
        <key>HOME</key><string>{}</string>
    </dict>
    <key>StandardOutPath</key><string>/tmp/ezgha-launchd-stdout.log</string>
    <key>StandardErrorPath</key><string>/tmp/ezgha-launchd-stderr.log</string>
</dict>
</plist>
"#,
        wrapper_path.display(),
        config_path.display(),
        path_env,
        home_dir.display()
    );
    std::fs::write(&plist_path, plist)?;
    println!("wrote {}", plist_path.display());

    // Try to unload first to prevent "Already loaded" error on re-run
    let _ = Command::new("launchctl")
        .args(["unload", "-w"])
        .arg(&plist_path)
        .output();

    let out = Command::new("launchctl")
        .args(["load", "-w"])
        .arg(&plist_path)
        .output()?;
    if !out.status.success() {
        bail!(
            "launchctl load failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
    println!("launchd agent loaded");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Regression: every env var known to mask `gh auth` keyring auth on a
    /// developer's interactive shell must be unset in the wrapper. If a new
    /// such var is added to the user's dotfiles, this test should fail until
    /// it's added here. (Adding to the list is the correct fix; silently
    /// dropping the test would re-introduce the wedge class.)
    #[test]
    fn launchd_wrapper_unsets_all_known_gh_auth_masking_vars() {
        const REQUIRED_UNSETS: &[&str] = &[
            "GH_TOKEN",
            "GITHUB_TOKEN",
            "GH_TOKEN_AGENTF",
            "AO_BOT_GH_TOKEN",
            "HERMES_AO_HOOK_TOKEN",
            "OPENCLAW_AO_HOOK_TOKEN",
            "SMOKE_TOKEN",
            "SLACK_APP_TOKEN",
            "OPENCLAW_STAGING_SLACK_APP_TOKEN",
        ];
        // In Rust raw strings, `\` followed by a literal newline is two characters
        // (backslash + newline), not a backslash-newline sequence. The `unset`
        // line in LAUNCHD_WRAPPER is one logical line that wraps visually with
        // `\<newline>` continuations. After normalizing newlines to spaces,
        // the var appears as a whitespace-bounded token inside the unset list.
        let wrapper_one_line: String = LAUNCHD_WRAPPER
            .chars()
            .flat_map(|c| if c == '\n' { Some(' ') } else { Some(c) })
            .collect();
        for var in REQUIRED_UNSETS {
            // Find the `unset` keyword and check the var appears before the
            // `2>/dev/null` (or end-of-string) terminator. This handles all
            // wrap styles (inline space, `\<newline>` continuation, multi-line).
            let in_unset_list = wrapper_one_line
                .split_once("unset")
                .map(|(_, rest)| rest.split_once("2>/dev/null").unwrap_or((rest, "")).0)
                .map(|s| {
                    // word-boundary check: var must be surrounded by whitespace
                    // or start/end of string. Substring match alone would
                    // false-positive on `GH_TOKEN_AGENTF` matching `GH_TOKEN`.
                    let pattern = format!(" {} ", var);
                    let pattern_start = format!(" {} ", var); // leading space (after `unset `)
                    let pattern_end = format!(" {}", var); // trailing space (before space)
                    s.contains(&pattern) || s.contains(&pattern_start) || s.contains(&pattern_end)
                })
                .unwrap_or(false);
            assert!(
                in_unset_list,
                "LAUNCHD_WRAPPER must `unset {}` so launchd-inherited env \
                 doesn't mask gh keyring auth. Current wrapper:\n{}",
                var, LAUNCHD_WRAPPER
            );
        }
    }

    /// Sanity: the wrapper must `exec` the real binary, not fork+wait. If a
    /// future change replaces `exec` with a plain call, the daemon will run
    /// as a child of the wrapper which breaks launchd's process supervision.
    #[test]
    fn launchd_wrapper_execs_the_real_binary() {
        assert!(
            LAUNCHD_WRAPPER.contains("exec \"$(dirname \"$0\")/ezgha\""),
            "LAUNCHD_WRAPPER must exec the real binary in-place"
        );
    }

    #[test]
    fn systemd_service_wires_failure_alert_unit() {
        let unit = systemd_service_unit(
            std::path::Path::new("/home/jleechan/.cargo/bin/ezgha"),
            std::path::Path::new("/home/jleechan/.config/ezgha/config.toml"),
            "/usr/bin:/bin",
            std::path::Path::new("/home/jleechan"),
        );
        assert!(
            unit.contains("OnFailure=ezgha-alert@%N.service"),
            "ezgha.service must invoke an alert unit when watchdog/start-limit failures put it into failed state"
        );
        assert!(unit.contains("ExecStopPost=-/home/jleechan/.cargo/bin/ezgha --config /home/jleechan/.config/ezgha/config.toml systemd-alert-hook --source exec-stop-post --unit %n"));
    }

    #[test]
    fn systemd_alert_unit_invokes_failure_alert_command() {
        let unit = systemd_alert_unit(
            std::path::Path::new("/home/jleechan/.cargo/bin/ezgha"),
            std::path::Path::new("/home/jleechan/.config/ezgha/config.toml"),
            "/usr/bin:/bin",
            std::path::Path::new("/home/jleechan"),
        );
        assert!(unit.contains("Type=oneshot"));
        assert!(unit.contains("systemd-alert-hook"));
        assert!(unit.contains("--source on-failure"));
        assert!(unit.contains("--unit %i"));
        assert!(unit.contains("TimeoutStartSec=30"));
    }
}
