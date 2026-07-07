use std::fs::OpenOptions;
use std::io::Read;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::Duration;

/// Hard ceiling on how long any external capability probe may run. A wedged
/// docker daemon (the common failure mode this tool exists to contain) would
/// otherwise hang `detect()` — and therefore every ezgha command — forever.
/// On expiry we kill the probe and treat the capability as absent.
const PROBE_TIMEOUT: Duration = Duration::from_secs(4);

/// Run `cmd` capturing stdout, but never block longer than `timeout`. Returns
/// `Some((exit_success, stdout_bytes))` if the child finished in time, or
/// `None` if it errored or was killed for exceeding the deadline.
///
/// The child is spawned and its stdout drained on a helper thread; the caller
/// blocks on `recv_timeout`. On expiry we `kill()` the child (which unblocks
/// the reader thread via EOF) and reap it so nothing leaks.
fn capture_with_timeout(mut cmd: Command, timeout: Duration) -> Option<(bool, Vec<u8>)> {
    let mut child = cmd
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let mut stdout = child.stdout.take()?;
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = stdout.read_to_end(&mut buf);
        let _ = tx.send(buf);
    });
    match rx.recv_timeout(timeout) {
        Ok(buf) => {
            let status = child.wait().ok()?;
            Some((status.success(), buf))
        }
        Err(_) => {
            let _ = child.kill();
            let _ = child.wait();
            None
        }
    }
}

/// Convenience wrapper applying the standard [`PROBE_TIMEOUT`].
fn capture(cmd: Command) -> Option<(bool, Vec<u8>)> {
    capture_with_timeout(cmd, PROBE_TIMEOUT)
}

/// What this host can offer, detected at runtime.
#[derive(Debug, Clone)]
pub struct Platform {
    pub os: &'static str,
    pub arch: &'static str,
    /// /dev/kvm exists AND this user can open it read-write.
    pub kvm_usable: bool,
    pub has_tart: bool,
    pub has_virsh: bool,
    /// Docker CLI present and the daemon answered.
    pub docker_ok: bool,
    /// sysbox-runc registered as a Docker runtime.
    pub sysbox_runtime: bool,
    /// The docker daemon runs inside a VM (Colima/Lima/Docker Desktop/remote),
    /// so containers are VM-contained even though the backend is "docker".
    pub daemon_in_vm: bool,
    pub total_mem_mb: u64,
    pub cpus: u32,
}

pub fn detect() -> Platform {
    let os = if cfg!(target_os = "macos") {
        "macos"
    } else if cfg!(target_os = "linux") {
        "linux"
    } else {
        "unsupported"
    };

    let docker_ok = docker_daemon_ok();
    Platform {
        os,
        arch: std::env::consts::ARCH,
        kvm_usable: kvm_usable(),
        has_tart: which::which("tart").is_ok(),
        has_virsh: which::which("virsh").is_ok(),
        docker_ok,
        sysbox_runtime: sysbox_runtime_present(),
        daemon_in_vm: docker_ok && daemon_in_vm(),
        total_mem_mb: total_mem_mb(),
        cpus: std::thread::available_parallelism()
            .map(|n| n.get() as u32)
            .unwrap_or(1),
    }
}

/// A daemon kernel different from the host kernel proves the daemon runs on a
/// different machine — in practice a local VM (Colima/Lima/Docker Desktop) or
/// a remote host. On macOS the daemon is always in a VM (macOS has no native
/// Linux containers), so any Linux daemon kernel counts.
fn daemon_in_vm() -> bool {
    let mut docker_info = Command::new("docker");
    docker_info.args(["info", "--format", "{{.KernelVersion}}"]);
    let daemon_kernel = capture(docker_info)
        .filter(|(ok, _)| *ok)
        .map(|(_, out)| String::from_utf8_lossy(&out).trim().to_string())
        .filter(|s| !s.is_empty());
    let Some(daemon_kernel) = daemon_kernel else {
        return false;
    };
    if cfg!(target_os = "macos") {
        return true;
    }
    let mut uname = Command::new("uname");
    uname.arg("-r");
    let host_kernel = capture(uname)
        .filter(|(ok, _)| *ok)
        .map(|(_, out)| String::from_utf8_lossy(&out).trim().to_string());
    match host_kernel {
        Some(h) => !h.is_empty() && h != daemon_kernel,
        None => false,
    }
}

/// Existence alone is not enough: the user must be in the kvm group (or have
/// an ACL) for the device to be usable, so try to actually open it.
fn kvm_usable() -> bool {
    OpenOptions::new()
        .read(true)
        .write(true)
        .open("/dev/kvm")
        .is_ok()
}

fn docker_daemon_ok() -> bool {
    let mut cmd = Command::new("docker");
    cmd.args(["version", "--format", "{{.Server.Version}}"]);
    capture(cmd).map(|(ok, _)| ok).unwrap_or(false)
}

fn sysbox_runtime_present() -> bool {
    let mut cmd = Command::new("docker");
    cmd.args(["info", "--format", "{{json .Runtimes}}"]);
    capture(cmd)
        .map(|(ok, out)| ok && String::from_utf8_lossy(&out).contains("sysbox-runc"))
        .unwrap_or(false)
}

fn total_mem_mb() -> u64 {
    #[cfg(target_os = "linux")]
    {
        if let Ok(meminfo) = std::fs::read_to_string("/proc/meminfo") {
            for line in meminfo.lines() {
                if let Some(rest) = line.strip_prefix("MemTotal:") {
                    let kb: u64 = rest
                        .trim()
                        .trim_end_matches(" kB")
                        .trim()
                        .parse()
                        .unwrap_or(0);
                    return kb / 1024;
                }
            }
        }
        0
    }
    #[cfg(target_os = "macos")]
    {
        let mut cmd = Command::new("sysctl");
        cmd.args(["-n", "hw.memsize"]);
        capture(cmd)
            .and_then(|(_, out)| String::from_utf8_lossy(&out).trim().parse::<u64>().ok())
            .map(|b| b / 1024 / 1024)
            .unwrap_or(0)
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        0
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    #[test]
    fn capture_returns_output_for_fast_command() {
        let mut cmd = Command::new("/usr/bin/printf");
        cmd.arg("hello");
        let (ok, out) = capture_with_timeout(cmd, Duration::from_secs(4))
            .expect("fast command should complete");
        assert!(ok);
        assert!(!out.is_empty());
    }

    #[test]
    fn capture_reports_nonzero_exit() {
        let cmd = Command::new("/usr/bin/false");
        let (ok, _out) = capture_with_timeout(cmd, Duration::from_secs(4))
            .expect("false should complete quickly");
        assert!(!ok);
    }

    #[test]
    fn capture_kills_wedged_command_and_returns_none() {
        let mut cmd = Command::new("sleep");
        cmd.arg("30");
        let start = Instant::now();
        let result = capture_with_timeout(cmd, Duration::from_millis(300));
        let elapsed = start.elapsed();
        assert!(result.is_none(), "wedged command must time out to None");
        // Must return promptly after the deadline, not wait out the full sleep.
        assert!(
            elapsed < Duration::from_secs(5),
            "timeout should fire near the deadline, took {elapsed:?}"
        );
    }
}
