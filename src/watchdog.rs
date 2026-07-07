//! Best-effort systemd watchdog pings. No-op when NOTIFY_SOCKET is unset (macOS launchd).

use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::time::Duration;

/// Reset the systemd watchdog timer if running under Type=notify.
pub fn ping() {
    let _ = sd_notify::notify(false, &[sd_notify::NotifyState::Watchdog]);
}

#[must_use]
pub struct Heartbeat {
    stop: Arc<AtomicBool>,
    handle: Option<std::thread::JoinHandle<()>>,
}

impl Drop for Heartbeat {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }
}

/// Start a background watchdog heartbeat for long `serve` reconciliation cycles.
///
/// systemd exposes WATCHDOG_USEC only when WatchdogSec is active. Without it,
/// or outside Type=notify, this returns a cheap no-op guard.
pub fn start_background() -> Heartbeat {
    let interval = match heartbeat_interval_from_env() {
        Some(interval) => interval,
        None => {
            return Heartbeat {
                stop: Arc::new(AtomicBool::new(true)),
                handle: None,
            };
        }
    };
    let stop = Arc::new(AtomicBool::new(false));
    let worker_stop = Arc::clone(&stop);
    let handle = std::thread::Builder::new()
        .name("ezgha-watchdog-heartbeat".into())
        .spawn(move || {
            while !worker_stop.load(Ordering::Relaxed) {
                ping();
                sleep_interruptibly(interval, &worker_stop);
            }
        })
        .ok();
    Heartbeat { stop, handle }
}

fn heartbeat_interval_from_env() -> Option<Duration> {
    std::env::var_os("NOTIFY_SOCKET")?;
    let usec: u64 = std::env::var("WATCHDOG_USEC").ok()?.parse().ok()?;
    heartbeat_interval_from_watchdog_usec(usec)
}

fn heartbeat_interval_from_watchdog_usec(usec: u64) -> Option<Duration> {
    if usec == 0 {
        return None;
    }
    let interval = Duration::from_micros(usec / 3);
    Some(interval.clamp(Duration::from_secs(1), Duration::from_secs(30)))
}

fn sleep_interruptibly(duration: Duration, stop: &AtomicBool) {
    let deadline = std::time::Instant::now() + duration;
    while !stop.load(Ordering::Relaxed) {
        let remaining = deadline.saturating_duration_since(std::time::Instant::now());
        if remaining.is_zero() {
            break;
        }
        std::thread::sleep(remaining.min(Duration::from_millis(200)));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn heartbeat_interval_is_fraction_of_systemd_budget() {
        assert_eq!(
            heartbeat_interval_from_watchdog_usec(300_000_000),
            Some(Duration::from_secs(30))
        );
        assert_eq!(
            heartbeat_interval_from_watchdog_usec(15_000_000),
            Some(Duration::from_secs(5))
        );
    }

    #[test]
    fn heartbeat_interval_is_bounded() {
        assert_eq!(
            heartbeat_interval_from_watchdog_usec(500_000),
            Some(Duration::from_secs(1))
        );
        assert_eq!(
            heartbeat_interval_from_watchdog_usec(900_000_000),
            Some(Duration::from_secs(30))
        );
        assert_eq!(heartbeat_interval_from_watchdog_usec(0), None);
    }
}
