//! Best-effort systemd watchdog pings. No-op when NOTIFY_SOCKET is unset (macOS launchd).

/// Reset the systemd watchdog timer if running under Type=notify.
pub fn ping() {
    let _ = sd_notify::notify(false, &[sd_notify::NotifyState::Watchdog]);
}
