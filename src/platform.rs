use std::fs::OpenOptions;
use std::io::Read;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::Duration;

/// Hard ceiling on how long any external capability probe may run. A wedged
/// docker daemon (the common failure mode this tool exists to contain) would
/// otherwise hang `detect()` — and therefore every ezgha command — forever.
/// On expiry we kill the probe and treat the capability as absent.
///
/// Raised 2026-10-03 from 4s → 8s after a real Colima VM measured
/// `docker version` 4.99s and `docker info KernelVersion` 5.15s while
/// within its own deadline (Mac, docker daemon reattaching after a
/// transient). A 4s ceiling misclassified those legitimate answers as
/// "unsupported VM" and tripped the cpu_burst Err path in
/// `effective_limits`, opening per-slot start circuits while the daemon
/// itself was healthy. 8s leaves room for the observed 5.15s case while
/// still bounding a truly wedged daemon — the `unknown => reject`
/// semantics in `effective_limits` are preserved.
const PROBE_TIMEOUT: Duration = Duration::from_secs(8);

/// Build a Docker command for the endpoint selected during installation.
/// Services persist that endpoint in `DOCKER_HOST_OVERRIDE`; interactive
/// `DOCKER_HOST` and `DOCKER_CONTEXT` are never trusted for daemon control.
/// Linux falls back to its native socket when no endpoint was selected.
pub fn docker_command() -> Command {
    let mut cmd = Command::new("docker");
    configure_docker_endpoint(&mut cmd);
    cmd
}

pub fn configure_docker_endpoint(cmd: &mut Command) {
    cmd.env_remove("DOCKER_HOST").env_remove("DOCKER_CONTEXT");
    if let Some(host) = std::env::var("DOCKER_HOST_OVERRIDE")
        .ok()
        .filter(|host| !host.trim().is_empty())
    {
        cmd.arg("--host").arg(host);
    } else if cfg!(target_os = "linux") {
        cmd.arg("--host").arg("unix:///var/run/docker.sock");
    }
}

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

/// VM-containment proof via the docker daemon's own kernel string.
/// Returns `true` only when a real `docker info --format {{.KernelVersion}}`
/// succeeds AND, on Linux, the daemon kernel differs from the host kernel
/// (`uname -r`). On macOS the daemon is always in a VM (no native Linux
/// containers) so any non-empty daemon kernel counts — but the daemon
/// kernel probe must STILL succeed first; an unreachable daemon returns
/// `false` rather than a stale "Darwin implies VM" true (regression
/// 2026-10-03 review: the old `cfg!(target_os = "macos")` short-circuit
/// silently admitted burst on a host whose docker daemon was unreachable,
/// which `effective_limits`'s burst path would then have passed through).
fn daemon_in_vm() -> bool {
    let mut docker_info = docker_command();
    docker_info.args(["info", "--format", "{{.KernelVersion}}"]);
    let Some(daemon_kernel) = capture(docker_info)
        .filter(|(ok, _)| *ok)
        .map(|(_, out)| String::from_utf8_lossy(&out).trim().to_string())
        .filter(|s| !s.is_empty())
    else {
        return false;
    };
    if cfg!(target_os = "macos") {
        return true;
    }
    let mut uname = Command::new("uname");
    uname.arg("-r");
    let Some(host_kernel) = capture(uname)
        .filter(|(ok, _)| *ok)
        .map(|(_, out)| String::from_utf8_lossy(&out).trim().to_string())
        .filter(|s| !s.is_empty())
    else {
        return false;
    };
    host_kernel != daemon_kernel
}

/// Public, narrow VM-containment probe used by `effective_limits` for
/// the cpu_burst admission guard. Same semantics as `daemon_in_vm`;
/// exposed `pub` so the production guard test can exercise the actual
/// probe path.
pub fn daemon_in_vm_only() -> bool {
    daemon_in_vm()
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
    let mut cmd = docker_command();
    cmd.args(["version", "--format", "{{.Server.Version}}"]);
    capture(cmd).map(|(ok, _)| ok).unwrap_or(false)
}

fn sysbox_runtime_present() -> bool {
    let mut cmd = docker_command();
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

    #[test]
    fn capture_succeeds_for_5s_probe_under_8s_ceiling() {
        // Real Colima VM measured `docker info KernelVersion` at 5.15s
        // (2026-10-03) — must NOT be killed by the platform probe ceiling.
        // 5s sits between the old 4s ceiling (would have killed it) and
        // the new 8s ceiling (must succeed). If this regression flips
        // the ceiling back to 4s, this test starts failing immediately.
        // Only the lower bound is pinned: the upper bound is
        // scheduler-sensitive (heavy host load can let `sleep 5` drift
        // past 5s wall-clock) and the Some(...) outcome already proves
        // the ceiling was respected.
        let mut cmd = Command::new("sleep");
        cmd.arg("5");
        let start = Instant::now();
        let result = capture_with_timeout(cmd, PROBE_TIMEOUT);
        let elapsed = start.elapsed();
        assert!(
            result.is_some(),
            "5s probe under the 8s PROBE_TIMEOUT must return Some, not be killed (elapsed={elapsed:?})"
        );
        assert!(
            elapsed.as_secs() >= 4,
            "5s probe must survive past the OLD 4s ceiling (elapsed={elapsed:?}); \
             a regression here means the ceiling was lowered back to 4s"
        );
    }
}
