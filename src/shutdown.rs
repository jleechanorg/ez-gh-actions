//! Graceful-shutdown flag for the serve loop (bead ez-gh-actions-30p).
//!
//! The daemon is plain-`std`, blocking, single-threaded. A SIGTERM/SIGINT
//! handler flips a process-global `AtomicBool`; the serve loop polls it at its
//! seams and, once observed, drains in-flight registrations and exits cleanly.
//! The handler itself does ONLY an atomic store (async-signal-safe: no alloc,
//! no I/O). Platform-agnostic via `libc::sigaction` (works under systemd and
//! launchd identically; macOS has no NOTIFY_SOCKET so sd_notify is a no-op).

use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

static SHUTDOWN: AtomicBool = AtomicBool::new(false);

extern "C" fn handle_signal(_sig: libc::c_int) {
    // Async-signal-safe: atomic store only.
    SHUTDOWN.store(true, Ordering::SeqCst);
}

/// Install SIGTERM + SIGINT handlers. Call once before entering the serve loop.
pub fn install_handlers() {
    // SAFETY: `handle_signal` is async-signal-safe (a single atomic store),
    // and we install with an empty mask and no flags. sigaction is the
    // portable, well-defined way to register a handler on Linux and macOS.
    unsafe {
        let mut action: libc::sigaction = std::mem::zeroed();
        action.sa_sigaction = handle_signal as *const () as usize;
        libc::sigemptyset(&mut action.sa_mask);
        action.sa_flags = 0;
        libc::sigaction(libc::SIGTERM, &action, std::ptr::null_mut());
        libc::sigaction(libc::SIGINT, &action, std::ptr::null_mut());
    }
}

/// True once a SIGTERM/SIGINT has been observed.
pub fn is_requested() -> bool {
    SHUTDOWN.load(Ordering::SeqCst)
}

/// Sleep up to `duration`, returning early (≤ ~200ms latency) if shutdown is
/// requested. Reuses the `watchdog::sleep_interruptibly` poll idiom against the
/// shutdown flag, so SIGTERM latency in the serve loop drops from ≤ one
/// serve_tick (30s) to ≤ poll granularity.
pub fn sleep_interruptibly(duration: Duration) {
    crate::watchdog::sleep_interruptibly(duration, &SHUTDOWN);
}

#[cfg(test)]
pub fn reset_for_test() {
    SHUTDOWN.store(false, Ordering::SeqCst);
}

#[cfg(test)]
pub fn request_for_test() {
    SHUTDOWN.store(true, Ordering::SeqCst);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flag_starts_clear_and_request_sets_it() {
        reset_for_test();
        assert!(!is_requested());
        request_for_test();
        assert!(is_requested());
        reset_for_test();
        assert!(!is_requested());
    }

    #[test]
    fn sleep_interruptibly_returns_early_when_requested() {
        request_for_test();
        let start = std::time::Instant::now();
        sleep_interruptibly(Duration::from_secs(30));
        assert!(start.elapsed() < Duration::from_secs(1), "must return promptly when flag set");
        reset_for_test();
    }
}
