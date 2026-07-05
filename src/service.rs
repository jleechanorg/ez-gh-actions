use anyhow::{bail, Context, Result};
use std::path::PathBuf;
use std::process::Command;

/// Install a user-level service that runs `ezgha serve` at login and keeps
/// it running: systemd --user on Linux, launchd on macOS.
pub fn install() -> Result<()> {
    let exe = std::env::current_exe().context("cannot resolve ezgha binary path")?;
    if cfg!(target_os = "linux") {
        install_systemd(&exe)
    } else if cfg!(target_os = "macos") {
        install_launchd(&exe)
    } else {
        bail!("service install is only supported on linux (systemd --user) and macos (launchd)")
    }
}

fn home() -> Result<PathBuf> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .context("HOME not set")
}

fn install_systemd(exe: &std::path::Path) -> Result<()> {
    let unit_dir = home()?.join(".config/systemd/user");
    std::fs::create_dir_all(&unit_dir)?;
    let unit_path = unit_dir.join("ezgha.service");
    let path_env = std::env::var("PATH").unwrap_or_else(|_| "/usr/local/bin:/usr/bin:/bin".to_string());
    let home_dir = home()?;
    let unit = format!(
        "[Unit]\n\
         Description=ez-gh-actions ephemeral GitHub Actions runners\n\
         After=network-online.target\n\n\
         [Service]\n\
         ExecStart={} serve\n\
         Restart=on-failure\n\
         RestartSec=10\n\
         Environment=\"PATH={}\"\n\
         Environment=\"HOME={}\"\n\n\
         [Install]\n\
         WantedBy=default.target\n",
        exe.display(),
        path_env,
        home_dir.display()
    );
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

fn install_launchd(exe: &std::path::Path) -> Result<()> {
    let agents = home()?.join("Library/LaunchAgents");
    std::fs::create_dir_all(&agents)?;
    let plist_path = agents.join("org.jleechanorg.ezgha.plist");
    let path_env = std::env::var("PATH").unwrap_or_else(|_| "/usr/local/bin:/usr/bin:/bin".to_string());
    let home_dir = home()?;
    let plist = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>org.jleechanorg.ezgha</string>
    <key>ProgramArguments</key>
    <array><string>{}</string><string>serve</string></array>
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
        exe.display(),
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
