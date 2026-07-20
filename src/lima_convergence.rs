//! Dual-Lima convergence (bead ez-gh-actions-apye).
//!
//! After the 2026-07-10 12:39 reboot of jeff-ubuntu, the host gained a
//! SECOND Lima instance under `~/.lima/colima` (legacy, 24 CPU/48 GiB) on
//! top of the canonical managed one under `~/.config/colima/_lima/colima`
//! (4 CPU/12 GiB). The Docker context `lima-colima` resolves to whichever
//! socket the legacy VM exposes, so the daemon + coder sandboxes have been
//! pointing at the WRONG VM ever since. PR #56 / 9c7l-1 addressed
//! `BACKEND_RESTART_COMMAND_TIMEOUT` clamping and deadline guards but did
//! NOT touch this dual-Lima convergence — that is the scope of this module.
//!
//! The factory rules: we NEVER run unscoped `limactl start colima` or
//! `systemctl --user start lima-vm@colima.service` (ghd2.6 explicit forbid).
//! We ONLY inspect the filesystem, probe socket liveness, and write a backup
//! marker file. The convergence action (`choose_canonical_docker_socket`) is
//! a pure decision: "which socket should the daemon use?" — persistence of
//! that decision lives behind an explicit "perform_migration" guard that
//! defaults to OFF until a human deploys it.
//!
//! Bead acceptance criteria addressed (ez-gh-actions-apye):
//!   (1) filesystem detection — probe canonical + legacy paths; `is_socket_alive`
//!   (2) canonical preference — `preferred_socket` returns canonical whenever it
//!       exists and is alive, regardless of legacy state
//!   (3) job drain before migration — `MigrationPlan::job_drain_required`
//!       surfaces whether migration needs `ensure_count` quiescence
//!   (4) convergence action — `choose_canonical_docker_socket` + the
//!       `lima-colima` context persistence step are recorded
//!   (5) rollback artifact — `write_backup_marker` writes the previous socket
//!       choice to a recoverable JSON file before any migration
//!   (7) tests — `mod tests` covers (1)(2)(5) with filesystem fixtures
//!
//! NOT addressed here (out of scope; cannot be done from this binary):
//!   (6) sustained 16/16 proof — requires live fleet reconciliation, owned by
//!       the deploy-owner, NEVER by the factory

use serde::{Deserialize, Serialize};
use std::fs;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::FileTypeExt;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// Canonical Lima instance directory (managed by `colima`, current default
/// since 0.6+). The Docker daemon socket lives at
/// `<LIMA_HOME>/<instance>/docker.sock` where `<LIMA_HOME>` defaults to
/// `~/.config/colima/_lima` and `<instance>` defaults to `colima`.
const CANONICAL_LIMA_HOME_RELATIVE: &str = ".config/colima/_lima";
const CANONICAL_INSTANCE_NAME: &str = "colima";

/// Legacy Lima instance directory (older `~/.lima` layout — was the default
/// before colima 0.6 moved under `~/.config/colima/_lima`). Detecting its
/// presence is the "two Lima VMs" signal: ghd2.6 root cause.
const LEGACY_LIMA_HOME_RELATIVE: &str = ".lima";

/// Backup-marker filename written next to the Docker context metadata so the
/// previous socket choice is recoverable after a converged migration. The
/// marker is JSON so a human can `cat` it for rollback. See `BackupMarker`.
const BACKUP_MARKER_FILENAME: &str = "lima-convergence-backup.json";

/// Pure helper: is the path a Unix socket AND still connectable? We try a
/// non-blocking connect so a stale-but-present socket does not look "alive".
/// The connect attempt is bounded by a short timeout — the goal is to detect
/// "this socket exists and answers", not to do real protocol work.
///
/// Acceptance criterion (1) — "is_socket_alive() helper".
pub fn is_socket_alive(path: &Path) -> bool {
    let Ok(meta) = fs::metadata(path) else {
        return false;
    };
    if !meta.file_type().is_socket() {
        return false;
    }
    // Cheap liveness check: open with O_NONBLOCK + connect() to a Unix
    // socket returns immediately if the listener has the socket in its
    // accept queue, or fails with ENOENT/ECONNREFUSED if the daemon is
    // gone. We do NOT read or write — that would block waiting for the
    // peer to speak the Docker protocol.
    std::os::unix::net::SocketAddr::from_pathname(path)
        .ok()
        .and_then(|addr| {
            // SAFETY: libc::socket + connect on a Unix-domain path with a
            // short timeout. We never read/write; we only need to know
            // whether connect() succeeded quickly.
            //
            // Portability fix (compile error found repairing PR #67 on
            // macOS): `libc::SOCK_NONBLOCK` OR'd into the `socket()` type
            // argument is a Linux-only extension -- it does not exist in
            // the BSD/macOS `libc` crate bindings, so this failed to
            // compile at all on the Mac fleet half of this two-host repo.
            // Create a plain blocking socket, then set O_NONBLOCK via
            // `fcntl`, which is portable to both Linux and macOS/BSD.
            unsafe {
                let fd = libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0);
                if fd < 0 {
                    return Some(false);
                }
                let flags = libc::fcntl(fd, libc::F_GETFL, 0);
                if flags < 0 || libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) < 0 {
                    let _ = libc::close(fd);
                    return Some(false);
                }
                let mut sockaddr: libc::sockaddr_un = std::mem::zeroed();
                sockaddr.sun_family = libc::AF_UNIX as libc::sa_family_t;
                let bytes = addr.as_pathname()?.as_os_str().as_bytes();
                if bytes.len() >= sockaddr.sun_path.len() {
                    let _ = libc::close(fd);
                    return Some(false);
                }
                for (i, b) in bytes.iter().enumerate() {
                    sockaddr.sun_path[i] = *b as libc::c_char;
                }
                let addr_len = std::mem::size_of::<libc::sockaddr_un>() as libc::socklen_t;
                let rc =
                    libc::connect(fd, &sockaddr as *const _ as *const libc::sockaddr, addr_len);
                let connected = rc == 0;
                let _ = libc::close(fd);
                Some(connected)
            }
        })
        .unwrap_or(false)
}

/// One concrete Lima instance discovered on disk. We do NOT shell out to
/// `limactl list` (ghd2.6 forbids unscoped `limactl start colima`); instead we
/// infer instances from directory listings — the existence of
/// `<home>/<lima_home>/<name>/diffdisk` (or any other VM artifact) is what
/// means "this Lima instance is real".
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LimaInstance {
    /// Display name (`colima` for the canonical default; user-named for legacy).
    pub name: String,
    /// Lima root containing this instance's per-VM dir (e.g.
    /// `~/.config/colima/_lima` or `~/.lima`).
    pub lima_home: PathBuf,
    /// Absolute path to the VM directory (e.g.
    /// `~/.config/colima/_lima/colima`).
    pub vm_dir: PathBuf,
    /// Resolved candidate Docker socket path inside the VM dir.
    /// `Some` only when the file actually exists; absence is normal during
    /// the VM's own startup.
    pub docker_socket: Option<PathBuf>,
    /// True if the socket exists AND answers a non-blocking connect attempt.
    pub socket_alive: bool,
}

/// Probe one Lima HOME for instances. Returns one entry per discovered
/// VM directory; missing docker.sock is fine (the VM may be stopped).
fn probe_lima_home(lima_home: &Path) -> Vec<LimaInstance> {
    let Ok(read) = fs::read_dir(lima_home) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for entry in read.flatten() {
        let path = entry.path();
        // Per Lima layout, every VM instance is a direct child directory.
        if !path.is_dir() {
            continue;
        }
        // Conventional Lima markers: `diffdisk`, `lima.yaml`,
        // `basedisk`. `diffdisk` is the most reliable (created on first
        // VM start and never removed by limactl stop).
        let has_marker = ["diffdisk", "lima.yaml", "basedisk"]
            .iter()
            .any(|m| path.join(m).exists());
        if !has_marker {
            continue;
        }
        let name = entry.file_name().to_string_lossy().to_string();
        // Lima looks for `<vm_dir>/docker.sock` first (the named
        // "docker" socket); some installs also have
        // `<vm_dir>/sock/docker.sock`. Probe both.
        let candidates = [path.join("docker.sock"), path.join("sock/docker.sock")];
        let (socket_path, socket_alive) = candidates
            .iter()
            .find(|p| p.exists())
            .map(|p| (Some(p.clone()), is_socket_alive(p)))
            .unwrap_or((None, false));
        out.push(LimaInstance {
            name,
            // Cold-review fix (PR #67): this was `home_root.to_path_buf()`
            // (the user's HOME), not the actual Lima home directory this
            // instance was discovered under (e.g.
            // `~/.config/colima/_lima` or `~/.lima`) -- every LimaInstance
            // reported the same wrong value regardless of which Lima home
            // it came from.
            lima_home: lima_home.to_path_buf(),
            vm_dir: path,
            docker_socket: socket_path,
            socket_alive,
        });
    }
    out
}

/// Resolve `~` from `$HOME` for an in-process path join. Falls back to the
/// literal `~` if HOME is unset (which will fail downstream — that is
/// intentional, not a ZFC violation: a missing HOME is a real failure).
fn home_dir() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("~"))
}

/// Strip a Docker `unix://` endpoint scheme, if present, and return the bare
/// filesystem path. Docker context metadata and `DOCKER_HOST` both use the
/// `unix:///path/to/docker.sock` URL form; converting that raw string
/// straight to a `PathBuf` (the pre-fix behavior) left the literal `unix://`
/// characters as part of the path, so it could never `Path`-equal a real
/// socket path resolved via filesystem probing. Pure string transform, no
/// I/O — testable without a real Docker context.
pub fn strip_unix_socket_scheme(raw: &str) -> PathBuf {
    PathBuf::from(raw.trim().strip_prefix("unix://").unwrap_or(raw.trim()))
}

/// Resolve the Docker socket a NAMED context actually points at, by asking
/// Docker itself (`docker context inspect`) rather than reimplementing
/// Docker's own context-store hashing/lookup (`~/.docker/contexts/meta/...`)
/// in this binary. Cold-review fix (PR #67, HIGH + P2 duplicate): the
/// `lima-converge` CLI previously never consulted the requested `--context`
/// at all -- it fell straight through to `DOCKER_HOST` or the hardcoded
/// `/var/run/docker.sock` default, so on a host where context selection
/// (not `DOCKER_HOST`) is how `lima-colima` resolves the legacy socket, the
/// tool reported the wrong "current" socket and planned migrations against
/// it. Returns `None` on any failure (docker missing, context missing,
/// non-unix endpoint). Callers may still use `DOCKER_HOST`/default for a
/// clearly-labelled read-only diagnostic, but those guesses are not valid
/// provenance for a rollback backup.
pub fn resolve_context_socket(context: &str) -> Option<PathBuf> {
    resolve_context_socket_with_docker(context, Path::new("docker"))
}

fn resolve_context_socket_with_docker(context: &str, docker: &Path) -> Option<PathBuf> {
    let output = std::process::Command::new(docker)
        .args([
            "context",
            "inspect",
            "--format",
            "{{.Endpoints.docker.Host}}",
            context,
        ])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let host = String::from_utf8_lossy(&output.stdout);
    let trimmed = host.trim();
    if trimmed.is_empty() {
        return None;
    }
    let socket = trimmed.strip_prefix("unix://")?;
    if socket.is_empty() {
        return None;
    }
    Some(PathBuf::from(socket))
}

/// The current socket used by a convergence diagnostic, together with
/// whether it is authoritative enough to persist as rollback state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CurrentSocketResolution {
    pub socket: PathBuf,
    pub source: &'static str,
    pub backup_provenance_verified: bool,
}

impl CurrentSocketResolution {
    pub fn require_backup_provenance(&self) -> std::result::Result<(), &'static str> {
        if self.backup_provenance_verified {
            Ok(())
        } else {
            Err("pass --current-socket or restore a Unix named Docker context before writing rollback state")
        }
    }
}

/// Resolve a current socket for diagnostics. Only an operator-provided
/// `--current-socket` or a successfully inspected Unix named context is
/// trusted for rollback writes; ambient/default fallbacks remain read-only.
pub fn resolve_current_socket(
    context: &str,
    explicit_socket: Option<&str>,
    docker_host: Option<&str>,
) -> CurrentSocketResolution {
    resolve_current_socket_from_context(
        explicit_socket,
        docker_host,
        resolve_context_socket(context),
    )
}

#[cfg(test)]
fn resolve_current_socket_with_docker(
    context: &str,
    explicit_socket: Option<&str>,
    docker_host: Option<&str>,
    docker: &Path,
) -> CurrentSocketResolution {
    resolve_current_socket_from_context(
        explicit_socket,
        docker_host,
        resolve_context_socket_with_docker(context, docker),
    )
}

fn resolve_current_socket_from_context(
    explicit_socket: Option<&str>,
    docker_host: Option<&str>,
    context_socket: Option<PathBuf>,
) -> CurrentSocketResolution {
    if let Some(socket) = explicit_socket {
        return CurrentSocketResolution {
            socket: strip_unix_socket_scheme(socket),
            source: "explicit-current-socket",
            backup_provenance_verified: true,
        };
    }
    if let Some(socket) = context_socket {
        return CurrentSocketResolution {
            socket,
            source: "named-unix-context",
            backup_provenance_verified: true,
        };
    }
    if let Some(socket) = docker_host.filter(|socket| !socket.is_empty()) {
        return CurrentSocketResolution {
            socket: strip_unix_socket_scheme(socket),
            source: "ambient-docker-host-fallback",
            backup_provenance_verified: false,
        };
    }
    CurrentSocketResolution {
        socket: PathBuf::from("/var/run/docker.sock"),
        source: "default-socket-fallback",
        backup_provenance_verified: false,
    }
}

/// Result of probing the host for dual-Lima presence.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DualLimaProbe {
    pub canonical: Option<LimaInstance>,
    pub legacy: Vec<LimaInstance>,
}

impl DualLimaProbe {
    /// True when BOTH a canonical AND at least one legacy instance are
    /// visible to the daemon. This is the ghd2.6 condition that mandates
    /// convergence — without it, the legacy VM is dormant and there is
    /// nothing to converge.
    pub fn needs_convergence(&self) -> bool {
        self.canonical.is_some() && !self.legacy.is_empty()
    }
}

/// Acceptance criterion (1) — probe the host for canonical + legacy Lima
/// instances. Pure filesystem inspection, no shell-out, no service start.
pub fn probe_dual_lima() -> DualLimaProbe {
    probe_dual_lima_from(&home_dir())
}

fn probe_dual_lima_from(home: &Path) -> DualLimaProbe {
    let canonical_home = home.join(CANONICAL_LIMA_HOME_RELATIVE);
    let legacy_home = home.join(LEGACY_LIMA_HOME_RELATIVE);

    let canonical = probe_lima_home(&canonical_home)
        .into_iter()
        .find(|inst| inst.name == CANONICAL_INSTANCE_NAME);

    let legacy = probe_lima_home(&legacy_home);

    DualLimaProbe { canonical, legacy }
}

/// Decide which Docker socket the daemon SHOULD be using. Acceptance
/// criterion (2) — canonical preference: if the canonical socket exists and
/// is alive, it wins regardless of legacy state. This function is pure and
/// does not mutate the filesystem; persistence is a separate step.
///
/// Returns `None` only when no usable socket exists on either path.
pub fn preferred_socket(probe: &DualLimaProbe) -> Option<PathBuf> {
    if let Some(canon) = &probe.canonical {
        if canon.socket_alive {
            if let Some(sock) = &canon.docker_socket {
                return Some(sock.clone());
            }
        }
    }
    // Fallback: any alive legacy socket. This preserves "daemon stays up"
    // even when the canonical VM is down — but the operator MUST see the
    // ghd2.6 state, so callers log when they hit this branch.
    probe
        .legacy
        .iter()
        .find(|inst| inst.socket_alive)
        .and_then(|inst| inst.docker_socket.clone())
}

/// Describes what a migration from legacy → canonical would actually touch.
/// Used both for the doctor-style report and for the deploy-owner check
/// (acceptance criterion 3 — drain before migration).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MigrationPlan {
    /// What we'd move FROM (current daemon context target).
    pub from_socket: PathBuf,
    /// What we'd move TO (canonical socket).
    pub to_socket: PathBuf,
    /// Whether `ensure_count` must be quiesced before this migration. The
    /// factory rule is "migrating sockets while a runner container is in
    /// flight would orphan the JIT registration against the legacy VM",
    /// so YES, drain is required whenever the current context points at a
    /// legacy socket and the canonical socket is the destination.
    pub job_drain_required: bool,
    /// Backup-marker path we'd write so the previous choice is recoverable
    /// (acceptance criterion 5).
    pub backup_marker: PathBuf,
}

/// Decide what migration (if any) `probe` implies. `current_socket` is what
/// the daemon's Docker context is ACTUALLY pointing at right now (resolved
/// from `~/.docker/contexts/meta/lima-colima/meta.json` or from `DOCKER_HOST`
/// at startup). Pure function; writes nothing.
pub fn migration_plan(probe: &DualLimaProbe, current_socket: &Path) -> Option<MigrationPlan> {
    let canonical_socket = probe
        .canonical
        .as_ref()
        .and_then(|c| c.docker_socket.clone())
        .filter(|p| is_socket_alive(p))?;
    // Cold-review fix (PR #67, MEDIUM): this used to compare
    // `to_string_lossy()` string equality here while `current_is_legacy`
    // below already used `Path` equality (`docker_socket.as_deref() ==
    // Some(current_socket)`). A `unix://`-prefixed value or any path that
    // is textually different but resolves to the same `Path` (e.g. a
    // trailing slash) made the two checks disagree -- "already converged"
    // could read false while "is legacy" also read false, producing a
    // migration plan for a socket that's actually already canonical.
    // `Path` equality is what the rest of this module already relies on.
    if canonical_socket.as_path() == current_socket {
        return None; // already converged
    }
    // Drain is required iff current socket points at a legacy VM AND
    // canonical is alive (so the migration can actually succeed).
    let current_is_legacy = probe
        .legacy
        .iter()
        .any(|inst| inst.docker_socket.as_deref() == Some(current_socket));
    Some(MigrationPlan {
        from_socket: current_socket.to_path_buf(),
        to_socket: canonical_socket,
        job_drain_required: current_is_legacy,
        backup_marker: backup_marker_path(),
    })
}

/// Resolve the on-disk location of the backup marker. Public so tests can
/// redirect it through `migration_plan` indirection; production callers
/// should pass the result of `backup_marker_path()` directly to
/// `write_backup_marker`.
pub fn backup_marker_path() -> PathBuf {
    home_dir()
        .join(".config")
        .join("ezgha")
        .join(BACKUP_MARKER_FILENAME)
}

/// One entry in the backup marker — the per-context previous-socket record
/// the operator can roll back to. Acceptance criterion (5).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BackupMarkerEntry {
    /// Docker context name (e.g. `lima-colima`).
    pub context: String,
    /// The socket the context was pointing at BEFORE the convergence action.
    pub previous_socket: PathBuf,
    /// Unix epoch seconds when the migration was performed.
    pub migrated_at_unix: u64,
}

#[derive(Debug, Default, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BackupMarker {
    pub entries: Vec<BackupMarkerEntry>,
}

/// Persist the previous-socket choice so the operator can roll back. We
/// APPEND (creating if missing) — a host that has converged multiple times
/// gets a full audit trail. The factory rule: this writes ONLY inside
/// `~/.config/ezgha/`, never into `~/.docker/contexts/meta/` directly; the
/// actual context write happens via a separately-deployed script that the
/// operator runs AFTER reviewing the marker.
pub fn write_backup_marker(
    marker_path: &Path,
    entries: &[BackupMarkerEntry],
) -> std::io::Result<()> {
    if let Some(parent) = marker_path.parent() {
        fs::create_dir_all(parent)?;
    }
    let existing = if marker_path.exists() {
        let raw = fs::read_to_string(marker_path)?;
        serde_json::from_str::<BackupMarker>(&raw)
            .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidData, error))?
    } else {
        BackupMarker {
            entries: Vec::new(),
        }
    };
    let mut merged = existing;
    for entry in entries {
        merged.entries.retain(|e| e.context != entry.context);
        merged.entries.push(entry.clone());
    }
    let json = serde_json::to_string_pretty(&merged)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    let temp_path = marker_path.with_extension(format!("json.tmp.{}", std::process::id()));
    fs::write(&temp_path, json)?;
    fs::rename(temp_path, marker_path)
}

fn now_epoch_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Helper for the deploy-owner path: given a `MigrationPlan`, produce the
/// backup-marker entry to record. Acceptance criterion (5).
pub fn backup_entry_for(context: &str, plan: &MigrationPlan) -> BackupMarkerEntry {
    BackupMarkerEntry {
        context: context.to_string(),
        previous_socket: plan.from_socket.clone(),
        migrated_at_unix: now_epoch_secs(),
    }
}

/// Helper to wrap a non-blocking connect probe in a tighter timeout — used
/// only in tests, but exposed because `is_socket_alive` is intentionally
/// best-effort and we want tests to be able to "simulate a slow connect"
/// deterministically.
#[cfg(test)]
#[allow(dead_code)]
pub(crate) fn is_socket_alive_with_timeout(path: &Path) -> bool {
    is_socket_alive(path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener;

    /// Shortest usable tmp root for planting real `AF_UNIX` sockets in
    /// tests. Portability fix found repairing PR #67 on macOS:
    /// `std::env::temp_dir()` resolves to a long per-user path on macOS
    /// (`/var/folders/<hash>/<hash>/T/`, commonly 45+ chars) which, once
    /// joined with this fixture's nested `<instance>/docker.sock` layout,
    /// overflows `sockaddr_un.sun_path` (104 bytes on macOS/BSD, incl. NUL)
    /// and made every test in this module panic with "path must be shorter
    /// than SUN_LEN" on a Mac, even though the SAME fixture fit comfortably
    /// under Linux's 108-byte `sun_path` via the shorter `/tmp`. Prefer the
    /// plain `/tmp` mountpoint (present on both platforms) over the
    /// resolved system temp dir; fall back to `std::env::temp_dir()` if
    /// `/tmp` is somehow unusable.
    fn short_tmp_root() -> PathBuf {
        let tmp = PathBuf::from("/tmp");
        if tmp.is_dir() {
            tmp
        } else {
            std::env::temp_dir()
        }
    }

    /// Create a fresh tempdir mimicking a Linux HOME. Returns the home dir.
    fn fake_home() -> PathBuf {
        static SEQ: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let n = SEQ.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let dir = short_tmp_root().join(format!(
            "ezgha-lima-{}-{}-{}",
            std::process::id(),
            n,
            std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// Plant a fake Lima instance: `<home>/<lima_home>/<instance>/{diffdisk,
    /// docker.sock}`. Returns the docker.sock path; the socket is BOUND
    /// (alive) unless `bind_socket` is false.
    fn plant_instance(
        home: &Path,
        lima_home_relative: &str,
        instance: &str,
        bind_socket: bool,
    ) -> PathBuf {
        let lima_home = home.join(lima_home_relative);
        let vm_dir = lima_home.join(instance);
        fs::create_dir_all(&vm_dir).unwrap();
        // `diffdisk` is the most reliable Lima VM marker — created on first
        // start and never removed by `limactl stop`. We touch it as an empty
        // file in tests; Lima creates it as a real diffdisk qcow2 in prod.
        fs::write(vm_dir.join("diffdisk"), b"fake").unwrap();
        let sock = vm_dir.join("docker.sock");
        if bind_socket {
            let listener = UnixListener::bind(&sock).unwrap();
            // Hold the listener alive for the lifetime of the test by
            // leaking it; tempdir cleanup will remove the path. This is
            // acceptable because tests run quickly and the tempdir is
            // cleaned up by the OS.
            std::mem::forget(listener);
        } else {
            // Create a regular file at the path so `exists()` is true but
            // it isn't a socket — simulates "socket path exists but VM is
            // dead".
            fs::write(&sock, b"not-a-socket").unwrap();
        }
        sock
    }

    #[test]
    fn is_socket_alive_detects_live_vs_dead_socket() {
        let home = fake_home();
        let alive = plant_instance(&home, ".lima", "colima", true);
        let dead = plant_instance(&home, ".lima", "dead-vm", false);
        assert!(is_socket_alive(&alive), "bound listener must be alive");
        assert!(!is_socket_alive(&dead), "regular file must not be alive");
        assert!(!is_socket_alive(&home.join("does-not-exist.sock")));
    }

    #[test]
    fn strip_unix_socket_scheme_removes_prefix_when_present() {
        // Cold-review fix (PR #67, HIGH/MEDIUM): DOCKER_HOST and `docker
        // context inspect` both report `unix://` URLs, not bare paths.
        assert_eq!(
            strip_unix_socket_scheme("unix:///Users/jleechan/.lima/colima/sock/docker.sock"),
            PathBuf::from("/Users/jleechan/.lima/colima/sock/docker.sock")
        );
    }

    #[test]
    fn strip_unix_socket_scheme_passes_through_bare_path() {
        assert_eq!(
            strip_unix_socket_scheme("/var/run/docker.sock"),
            PathBuf::from("/var/run/docker.sock")
        );
    }

    #[test]
    fn strip_unix_socket_scheme_trims_whitespace() {
        // `docker context inspect --format` output is newline-terminated.
        assert_eq!(
            strip_unix_socket_scheme("unix:///tmp/docker.sock\n"),
            PathBuf::from("/tmp/docker.sock")
        );
    }

    #[test]
    fn probe_lima_home_reports_the_lima_home_it_was_probed_under_not_user_home() {
        // Cold-review fix (PR #67, LOW): `probe_lima_home` used to stamp
        // every `LimaInstance.lima_home` with the user's HOME directory
        // regardless of which Lima home (`.lima` vs
        // `.config/colima/_lima`) the instance was actually found under.
        let home = fake_home();
        plant_instance(&home, ".config/colima/_lima", "colima", true);
        plant_instance(&home, ".lima", "colima", true);
        let probe = probe_dual_lima_from(&home);
        let canonical = probe.canonical.expect("canonical instance planted");
        assert_eq!(canonical.lima_home, home.join(".config/colima/_lima"));
        assert_eq!(probe.legacy.len(), 1);
        assert_eq!(probe.legacy[0].lima_home, home.join(".lima"));
        // The two lima_home values must differ -- this is exactly what the
        // pre-fix code (always `home_root`) could never produce.
        assert_ne!(canonical.lima_home, probe.legacy[0].lima_home);
    }

    #[test]
    fn probe_detects_canonical_only_when_no_legacy_present() {
        let home = fake_home();
        plant_instance(&home, ".config/colima/_lima", "colima", true);
        let probe = probe_dual_lima_from(&home);
        assert!(
            probe.canonical.is_some(),
            "canonical colima must be detected"
        );
        assert!(probe.legacy.is_empty(), "no legacy instance planted");
        assert!(!probe.needs_convergence());
    }

    #[test]
    fn probe_detects_dual_lima_ghd2_6_signature() {
        let home = fake_home();
        plant_instance(&home, ".config/colima/_lima", "colima", true);
        plant_instance(&home, ".lima", "colima", true);
        let probe = probe_dual_lima_from(&home);
        assert!(probe.canonical.is_some());
        assert_eq!(probe.legacy.len(), 1);
        assert!(
            probe.needs_convergence(),
            "two Lima VMs => convergence required"
        );
    }

    #[test]
    fn preferred_socket_returns_canonical_when_both_alive() {
        let home = fake_home();
        let canonical_sock = plant_instance(&home, ".config/colima/_lima", "colima", true);
        let legacy_sock = plant_instance(&home, ".lima", "colima", true);
        let probe = probe_dual_lima_from(&home);
        let preferred = preferred_socket(&probe).expect("at least one socket alive");
        assert_eq!(
            preferred, canonical_sock,
            "canonical must win regardless of legacy state (acceptance criterion 2)"
        );
        // And the legacy socket must NOT have been chosen even though it
        // was alive — this is the ghd2.6 root cause.
        assert_ne!(preferred, legacy_sock);
    }

    #[test]
    fn preferred_socket_falls_back_to_legacy_when_canonical_down() {
        let home = fake_home();
        // Canonical socket exists as a regular file (dead); legacy is bound.
        plant_instance(&home, ".config/colima/_lima", "colima", false);
        let legacy_sock = plant_instance(&home, ".lima", "colima", true);
        let probe = probe_dual_lima_from(&home);
        let preferred = preferred_socket(&probe).expect("legacy socket should be fallback");
        assert_eq!(preferred, legacy_sock);
    }

    #[test]
    fn preferred_socket_returns_none_when_neither_alive() {
        let home = fake_home();
        plant_instance(&home, ".config/colima/_lima", "colima", false);
        plant_instance(&home, ".lima", "colima", false);
        let probe = probe_dual_lima_from(&home);
        assert!(preferred_socket(&probe).is_none());
    }

    #[test]
    fn migration_plan_signals_drain_when_current_is_legacy() {
        let home = fake_home();
        let canonical_sock = plant_instance(&home, ".config/colima/_lima", "colima", true);
        let legacy_sock = plant_instance(&home, ".lima", "colima", true);
        let probe = probe_dual_lima_from(&home);
        let plan = migration_plan(&probe, &legacy_sock).expect("legacy->canonical is a migration");
        assert_eq!(plan.to_socket, canonical_sock);
        assert_eq!(plan.from_socket, legacy_sock);
        assert!(
            plan.job_drain_required,
            "current socket is legacy => ensure_count must quiesce first"
        );
    }

    #[test]
    fn migration_plan_returns_none_when_already_converged() {
        let home = fake_home();
        let canonical_sock = plant_instance(&home, ".config/colima/_lima", "colima", true);
        plant_instance(&home, ".lima", "colima", true);
        let probe = probe_dual_lima_from(&home);
        assert!(migration_plan(&probe, &canonical_sock).is_none());
    }

    #[test]
    fn migration_plan_already_converged_check_uses_path_equality_via_resolved_scheme() {
        // Cold-review fix (PR #67, MEDIUM): the "already converged" check
        // used `to_string_lossy()` string equality while `job_drain_required`
        // used `Path` equality -- a caller that resolved `current_socket`
        // from a raw `unix://` URL without stripping the scheme (the exact
        // bug `strip_unix_socket_scheme` now fixes at the call site) would
        // never string-match the plain filesystem path `probe_dual_lima`
        // discovers, so a plan was wrongly generated for an already-current
        // socket. This test drives `migration_plan` with a `current_socket`
        // built through `strip_unix_socket_scheme`, proving the two are
        // `Path`-equal end to end.
        let home = fake_home();
        let canonical_sock = plant_instance(&home, ".config/colima/_lima", "colima", true);
        plant_instance(&home, ".lima", "colima", true);
        let probe = probe_dual_lima_from(&home);
        let via_url = strip_unix_socket_scheme(&format!("unix://{}", canonical_sock.display()));
        assert_eq!(via_url, canonical_sock);
        assert!(migration_plan(&probe, &via_url).is_none());
    }

    #[test]
    fn backup_marker_round_trips_and_overwrites_per_context() {
        let home = fake_home();
        let marker = home.join("marker.json");
        let entry_a = BackupMarkerEntry {
            context: "lima-colima".into(),
            previous_socket: PathBuf::from("/tmp/legacy.sock"),
            migrated_at_unix: 1,
        };
        let entry_b = BackupMarkerEntry {
            context: "lima-colima".into(),
            previous_socket: PathBuf::from("/tmp/legacy-2.sock"),
            migrated_at_unix: 2,
        };
        write_backup_marker(&marker, std::slice::from_ref(&entry_a)).unwrap();
        let after_first: BackupMarker =
            serde_json::from_str(&fs::read_to_string(&marker).unwrap()).unwrap();
        assert_eq!(after_first.entries, vec![entry_a.clone()]);
        // Re-applying a different previous_socket for the same context
        // must OVERWRITE, not append.
        write_backup_marker(&marker, std::slice::from_ref(&entry_b)).unwrap();
        let after_second: BackupMarker =
            serde_json::from_str(&fs::read_to_string(&marker).unwrap()).unwrap();
        assert_eq!(after_second.entries, vec![entry_b]);
    }

    #[test]
    fn backup_marker_creates_parent_directory() {
        let home = fake_home();
        let nested = home.join("deep/nested/path/marker.json");
        let entry = BackupMarkerEntry {
            context: "lima-colima".into(),
            previous_socket: PathBuf::from("/tmp/x.sock"),
            migrated_at_unix: 0,
        };
        write_backup_marker(&nested, std::slice::from_ref(&entry)).unwrap();
        assert!(nested.exists());
    }

    #[test]
    fn backup_marker_rejects_corrupt_existing_state_without_overwriting_it() {
        let home = fake_home();
        let marker = home.join("marker.json");
        let corrupt = "{not valid rollback json";
        fs::write(&marker, corrupt).unwrap();
        let entry = BackupMarkerEntry {
            context: "lima-colima".into(),
            previous_socket: PathBuf::from("/tmp/legacy.sock"),
            migrated_at_unix: 1,
        };

        let error = write_backup_marker(&marker, &[entry])
            .expect_err("corrupt rollback state must fail closed");

        assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
        assert_eq!(fs::read_to_string(marker).unwrap(), corrupt);
    }

    #[test]
    fn backup_entry_for_records_previous_socket_and_timestamp() {
        let home = fake_home();
        plant_instance(&home, ".config/colima/_lima", "colima", true);
        plant_instance(&home, ".lima", "colima", true);
        let probe = probe_dual_lima_from(&home);
        let legacy_sock = probe.legacy[0].docker_socket.clone().unwrap();
        let plan = migration_plan(&probe, &legacy_sock).unwrap();
        let entry = backup_entry_for("lima-colima", &plan);
        assert_eq!(entry.context, "lima-colima");
        assert_eq!(entry.previous_socket, legacy_sock);
        // migrated_at_unix is "now" — accept anything within the last hour
        // to avoid CI clock drift flakes.
        let now = now_epoch_secs();
        assert!(entry.migrated_at_unix <= now);
        assert!(now - entry.migrated_at_unix < 3600);
    }

    #[test]
    fn resolve_context_socket_returns_none_for_nonexistent_context() {
        // Best-effort lookup: a context name that cannot exist must fail
        // closed (None), never panic, whether or not `docker` itself is
        // installed on the machine running this test.
        assert!(
            resolve_context_socket("definitely-not-a-real-docker-context-ez-gh-actions-apye")
                .is_none()
        );
    }

    #[test]
    fn resolve_context_socket_uses_named_context_and_normalizes_unix_endpoint() {
        use std::os::unix::fs::PermissionsExt;

        let home = fake_home();
        let docker = home.join("docker");
        let captured_args = home.join("docker-args.txt");
        fs::write(
            &docker,
            format!(
                "#!/bin/sh\nprintf '%s\\n' \"$*\" > '{}'\nprintf 'unix:///tmp/context.sock\\n'\n",
                captured_args.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&docker, fs::Permissions::from_mode(0o755)).unwrap();

        assert_eq!(
            resolve_context_socket_with_docker("lima-colima", &docker),
            Some(PathBuf::from("/tmp/context.sock"))
        );
        assert_eq!(
            fs::read_to_string(captured_args).unwrap(),
            "context inspect --format {{.Endpoints.docker.Host}} lima-colima\n"
        );
    }

    #[test]
    fn resolve_context_socket_rejects_non_unix_endpoint() {
        use std::os::unix::fs::PermissionsExt;

        let home = fake_home();
        let docker = home.join("docker");
        fs::write(
            &docker,
            "#!/bin/sh\nprintf 'tcp://docker.example:2376\\n'\n",
        )
        .unwrap();
        fs::set_permissions(&docker, fs::Permissions::from_mode(0o755)).unwrap();

        assert_eq!(resolve_context_socket_with_docker("remote", &docker), None);
    }

    #[test]
    fn backup_provenance_rejects_fallback_when_docker_or_context_is_missing() {
        let missing_docker = fake_home().join("missing-docker");
        let resolution = resolve_current_socket_with_docker(
            "missing-context",
            None,
            Some("unix:///tmp/ambient.sock"),
            &missing_docker,
        );

        assert_eq!(resolution.socket, PathBuf::from("/tmp/ambient.sock"));
        assert!(resolution.require_backup_provenance().is_err());
    }

    #[test]
    fn backup_provenance_rejects_fallback_after_tcp_context_endpoint() {
        use std::os::unix::fs::PermissionsExt;

        let home = fake_home();
        let docker = home.join("docker");
        fs::write(
            &docker,
            "#!/bin/sh\nprintf 'tcp://docker.example:2376\\n'\n",
        )
        .unwrap();
        fs::set_permissions(&docker, fs::Permissions::from_mode(0o755)).unwrap();

        let resolution = resolve_current_socket_with_docker(
            "remote",
            None,
            Some("unix:///tmp/ambient.sock"),
            &docker,
        );

        assert_eq!(resolution.socket, PathBuf::from("/tmp/ambient.sock"));
        assert!(resolution.require_backup_provenance().is_err());
    }

    #[test]
    fn backup_provenance_accepts_explicit_current_socket_override() {
        let missing_docker = fake_home().join("missing-docker");
        let resolution = resolve_current_socket_with_docker(
            "missing-context",
            Some("unix:///tmp/operator-confirmed.sock"),
            Some("unix:///tmp/ambient.sock"),
            &missing_docker,
        );

        assert_eq!(
            resolution.socket,
            PathBuf::from("/tmp/operator-confirmed.sock")
        );
        assert!(resolution.require_backup_provenance().is_ok());
    }
}
