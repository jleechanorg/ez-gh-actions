use std::fs::OpenOptions;
use std::process::Command;

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

    Platform {
        os,
        arch: std::env::consts::ARCH,
        kvm_usable: kvm_usable(),
        has_tart: which::which("tart").is_ok(),
        has_virsh: which::which("virsh").is_ok(),
        docker_ok: docker_daemon_ok(),
        sysbox_runtime: sysbox_runtime_present(),
        total_mem_mb: total_mem_mb(),
        cpus: std::thread::available_parallelism()
            .map(|n| n.get() as u32)
            .unwrap_or(1),
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
    Command::new("docker")
        .args(["version", "--format", "{{.Server.Version}}"])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

fn sysbox_runtime_present() -> bool {
    Command::new("docker")
        .args(["info", "--format", "{{json .Runtimes}}"])
        .output()
        .map(|o| o.status.success() && String::from_utf8_lossy(&o.stdout).contains("sysbox-runc"))
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
        Command::new("sysctl")
            .args(["-n", "hw.memsize"])
            .output()
            .ok()
            .and_then(|o| {
                String::from_utf8_lossy(&o.stdout)
                    .trim()
                    .parse::<u64>()
                    .ok()
            })
            .map(|b| b / 1024 / 1024)
            .unwrap_or(0)
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        0
    }
}
