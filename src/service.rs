use anyhow::{bail, Context, Result};
use std::path::{Path, PathBuf};
use std::process::Command;

/// Fallback PATH used when the current process has no PATH set. Covers the
/// common Docker/gh install locations on macOS/Linux plus the POSIX minimum.
pub(crate) const FALLBACK_PATH: &str = "/usr/local/bin:/usr/bin:/bin";

/// Install a user-level service that runs `ezgha serve` at login and keeps
/// it running: systemd --user on Linux, launchd on macOS.
pub fn install() -> Result<()> {
    let exe = std::env::current_exe().context("cannot resolve ezgha binary path")?;
    let path = detect_user_path();
    if cfg!(target_os = "linux") {
        install_systemd(&exe, &path)
    } else if cfg!(target_os = "macos") {
        install_launchd(&exe, &path)
    } else {
        bail!("service install is only supported on linux (systemd --user) and macos (launchd)")
    }
}

fn home() -> Result<PathBuf> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .context("HOME not set")
}

/// Return the PATH the user expects their shell to have. We capture it once
/// from the current process environment (the canonical single source of
/// truth — equivalent to `sh -c 'echo $PATH'` since the subprocess would
/// inherit the same env) and pass it to both the systemd unit and the
/// launchd plist so the launched `serve` process can find docker/gh/etc.
/// Falls back to a POSIX minimum if PATH is unset or empty.
fn detect_user_path() -> String {
    match std::env::var("PATH") {
        Ok(p) if !p.trim().is_empty() => p,
        _ => FALLBACK_PATH.to_string(),
    }
}

fn install_systemd(exe: &Path, path: &str) -> Result<()> {
    let unit_dir = home()?.join(".config/systemd/user");
    std::fs::create_dir_all(&unit_dir)?;
    let unit_path = unit_dir.join("ezgha.service");
    let unit = render_systemd_unit(exe, path);
    std::fs::write(&unit_path, unit)?;
    println!("wrote {}", unit_path.display());

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

fn install_launchd(exe: &Path, path: &str) -> Result<()> {
    let agents = home()?.join("Library/LaunchAgents");
    std::fs::create_dir_all(&agents)?;
    let plist_path = agents.join("org.jleechanorg.ezgha.plist");
    let plist = render_launchd_plist(exe, path);
    std::fs::write(&plist_path, plist)?;
    println!("wrote {}", plist_path.display());

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

/// Render the systemd --user unit body. Kept as a pure function so tests can
/// assert the exact template without touching the filesystem or systemctl.
///
/// Note: `After=docker.service` is intentionally omitted. It is a system
/// unit (managed by root) and referencing it from a `--user` unit is a
/// documented no-op; the user's daemon-in-VM detection means docker may not
/// even be running on the host. PATH is set explicitly because the user
/// manager does not inherit a useful PATH by default, so `serve` would
/// otherwise be unable to find docker/gh.
pub(crate) fn render_systemd_unit(exe: &Path, path: &str) -> String {
    format!(
        "[Unit]\n\
         Description=ez-gh-actions ephemeral GitHub Actions runners\n\
         After=network-online.target\n\n\
         [Service]\n\
         ExecStart={} serve\n\
         Environment=PATH={}\n\
         Restart=on-failure\n\
         RestartSec=10\n\n\
         [Install]\n\
         WantedBy=default.target\n",
        exe.display(),
        path
    )
}

/// Render the launchd plist body. Kept as a pure function so tests can
/// assert the exact template without touching the filesystem or launchctl.
///
/// We pass `PATH` via EnvironmentVariables because launchd's default PATH
/// does not include /usr/local/bin etc., so without this `serve` could not
/// find docker/gh.
pub(crate) fn render_launchd_plist(exe: &Path, path: &str) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>org.jleechanorg.ezgha</string>
    <key>ProgramArguments</key>
    <array><string>{}</string><string>serve</string></array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>{}</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
</dict>
</plist>
"#,
        exe.display(),
        path
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn exe() -> &'static Path {
        Path::new("/usr/local/bin/ezgha")
    }

    #[test]
    fn systemd_unit_sets_exec_and_path_and_keeps_network_after() {
        let unit = render_systemd_unit(exe(), "/opt/bin:/usr/bin");
        assert!(unit.contains("ExecStart=/usr/local/bin/ezgha serve"));
        assert!(unit.contains("Environment=PATH=/opt/bin:/usr/bin"));
        assert!(unit.contains("After=network-online.target"));
        assert!(!unit.contains("After=docker.service"));
        assert!(unit.contains("Restart=on-failure"));
        assert!(unit.contains("WantedBy=default.target"));
    }

    #[test]
    fn systemd_unit_does_not_reference_docker_service() {
        // `docker.service` is a system unit; referring to it from a user
        // unit is a no-op and was the root cause of bead xh4.
        let unit = render_systemd_unit(exe(), FALLBACK_PATH);
        assert!(
            !unit.contains("docker.service"),
            "user unit must not order itself against a system unit"
        );
    }

    #[test]
    fn launchd_plist_writes_environmentvariables_path() {
        let plist = render_launchd_plist(exe(), "/opt/homebrew/bin:/usr/bin");
        assert!(plist.contains("<key>EnvironmentVariables</key>"));
        assert!(plist.contains("<key>PATH</key><string>/opt/homebrew/bin:/usr/bin</string>"));
        assert!(plist.contains("<string>/usr/local/bin/ezgha</string>"));
        assert!(plist.contains("<string>serve</string>"));
        assert!(plist.contains("RunAtLoad"));
        assert!(plist.contains("KeepAlive"));
    }

    #[test]
    fn fallback_path_covers_docker_gh_minimum() {
        assert!(!FALLBACK_PATH.is_empty());
        assert!(FALLBACK_PATH.contains("/usr/bin"));
        assert!(FALLBACK_PATH.contains("/bin"));
    }

    #[test]
    fn detect_user_path_returns_current_path_when_set() {
        // Save and restore so this test is isolated from the rest of the
        // suite and from the host environment.
        let saved = std::env::var("PATH").ok();
        unsafe {
            std::env::set_var("PATH", "/custom/bin:/usr/bin");
        }
        let got = detect_user_path();
        unsafe {
            match saved {
                Some(v) => std::env::set_var("PATH", v),
                None => std::env::remove_var("PATH"),
            }
        }
        assert_eq!(got, "/custom/bin:/usr/bin");
    }
}
