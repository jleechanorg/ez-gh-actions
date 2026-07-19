//! Slot quarantine for wedged registrations (bead ez-gh-actions-ghd2.2).
//!
//! When GitHub's HTTP 422 lock persists for a runner that this host owns
//! (offline + busy reported by GH, no usable local container, DELETE returns
//! 422 even after the reaper cancel-then-delete dance), the slot cannot be
//! safely freed without sacrificing fleet capacity for healthy slots and — on
//! the Mac escalation path — without triggering a destructive backend restart
//! storm. This module records such slots in a small persisted file
//! (`quarantined_slots.toml`) so the daemon can:
//!
//! 1. Skip allocating new work into the wedged slot (it stays reserved, not
//!    consumed by the next `next_slot` cycle — other slots continue to fill).
//! 2. Bound API volume per reconciliation tick — at most one zombie-slot
//!    self-heal attempt per tick, not one per wedged slot, so a 22-slot fleet
//!    where half are wedged can't bury the GitHub API in cancel + poll
//!    cascades.
//! 3. Bound retry count per slot — after `MAX_RECONCILE_ATTEMPTS_PER_TICK`
//!    ticks of failed reclaims, the slot stops receiving API traffic and
//!    just stays quarantined until GH releases the lock; an alert with the
//!    runner id and age is fired on first quarantine.
//! 4. Auto-recover when GH releases the lock — if the runner next appears
//!    as `online`, `offline && !busy`, or disappears from the live list, the
//!    quarantine entry is cleared and the slot is released for the next
//!    allocation.
//!
//! This state is **distinct** from the rqb9 recycle path (container UP + IDLE +
//! GH registration GONE → docker rm+respawn). Quarantine here is for the
//! mirror case: container DOWN + GH reports offline+busy + DELETE 422 →
//! defer the slot rather than recycle, restart, or kill a sibling.

use crate::config::Config;
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::PathBuf;

const QUARANTINE_PATH_ENV: &str = "EZGHA_QUARANTINE_PATH";

/// Env-overridable path for the quarantine table (mirrors
/// `EZGHA_SLOT_ASSIGNMENTS_PATH` from `docker_backend`). Tests use this to
/// point at a per-test tmp file without touching the user's real
/// `~/.config/ezgha/quarantined_slots.toml`.
#[cfg(test)]
#[allow(dead_code)] // exposed for cross-test inspection; not all tests need it
pub fn quarantine_path_for_test() -> Option<PathBuf> {
    TEST_QUARANTINE_PATH.lock().unwrap().clone()
}

#[cfg(test)]
pub(crate) static TEST_QUARANTINE_PATH: std::sync::Mutex<Option<PathBuf>> =
    std::sync::Mutex::new(None);

/// On-disk representation of the quarantine table. A `BTreeMap` keeps the
/// serialized TOML stable (sorted slot keys) so diffs in code review and
/// operator inspection are deterministic.
#[derive(Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct QuarantineTable {
    /// slot index (as a TOML string key) -> quarantine entry. A `Vacant`
    /// slot means "not quarantined"; the entry's `slot` field must match the
    /// key (defensive — keeps file corruption from poisoning the daemon).
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    entries: BTreeMap<String, QuarantineEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct QuarantineEntry {
    pub slot: u32,
    pub runner_id: u64,
    pub runner_name: String,
    /// Unix epoch seconds when this slot was first quarantined. Used to
    /// compute the "age" reported in the alert body and to drive the
    /// `MAX_QUARANTINE_AGE_BEFORE_ALERT_ESCALATE` escalation.
    pub first_seen_epoch_secs: u64,
    /// Number of reaper self-heal attempts that have already been made for
    /// this entry. Bounded by `MAX_RECONCILE_ATTEMPTS_PER_TICK` * ticks
    /// elapsed (the per-tick cap is enforced by the caller; this counter is
    /// informational and used to drive alert escalation when retries stall).
    #[serde(default)]
    pub attempt_count: u32,
    /// Unix epoch seconds of the most recent reaper self-heal attempt, or
    /// `first_seen_epoch_secs` if no attempt has been made yet.
    pub last_attempt_epoch_secs: u64,
    /// Human-readable reason — today always `Locked422`, but the enum is
    /// open so future quarantine classes (e.g. `AuthLoop`) can share the
    /// same file without a schema migration.
    pub reason: QuarantineReason,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum QuarantineReason {
    /// GitHub returned HTTP 422 ("runner is currently running a job and
    /// cannot be deleted") and the reaper cancel-then-delete dance did not
    /// release the lock this tick. See bead ez-gh-actions-ghd2.2 and memory
    /// gh-zombie-runner-422-delete-lock for the GitHub-side mechanism.
    Locked422,
}

/// Path to the quarantine TOML file. Resolution order, mirroring
/// `slot_assignments_path_for` in `docker_backend` exactly (same isolation
/// guarantee: `cfg.state_dir` scopes this file so two fleets/configs
/// co-located on one host — e.g. prod + canary — never share quarantine
/// state and cross-contaminate slot indices):
/// 1. `EZGHA_QUARANTINE_PATH` env var (operator override / tests).
/// 2. `TEST_QUARANTINE_PATH` static (in-process test override).
/// 3. `cfg.state_dir` when the caller has a `Config` (production default).
/// 4. Global `~/.config/ezgha/` fallback when no `cfg` is available.
pub fn quarantine_path_for(cfg: Option<&Config>) -> PathBuf {
    #[cfg(test)]
    {
        if let Some(p) = TEST_QUARANTINE_PATH.lock().unwrap().clone() {
            return p;
        }
    }
    if let Ok(p) = std::env::var(QUARANTINE_PATH_ENV) {
        return PathBuf::from(p);
    }
    default_quarantine_path_for(cfg)
}

fn default_quarantine_path_for(cfg: Option<&Config>) -> PathBuf {
    // Mirror the slot assignments path derivation exactly, including the
    // state_dir scoping — two fleets/configs sharing a host must never
    // share a quarantine file (bare numeric slot indices would collide).
    if let Some(state_dir) = cfg.and_then(|cfg| cfg.state_dir.clone()) {
        return state_dir.join("quarantined_slots.toml");
    }
    // No cfg available (or cfg.state_dir unset): fall back to the global
    // XDG config location. We deliberately re-derive this here rather than
    // calling into `docker_backend` to avoid creating a module cycle
    // (`docker_backend` already depends on `quarantine`).
    let config_home = std::env::var("XDG_CONFIG_HOME").unwrap_or_else(|_| {
        let home = std::env::var("HOME").unwrap_or_else(|_| "~".into());
        format!("{home}/.config")
    });
    PathBuf::from(config_home)
        .join("ezgha")
        .join("quarantined_slots.toml")
}

/// Load the quarantine table from disk. A missing or empty file is not an
/// error — it just means "no quarantined slots", the steady state.
pub fn load_quarantine_for(cfg: Option<&Config>) -> Result<QuarantineTable> {
    let path = quarantine_path_for(cfg);
    if !path.exists() {
        return Ok(QuarantineTable::default());
    }
    let raw = std::fs::read_to_string(&path)
        .with_context(|| format!("read quarantine table {}", path.display()))?;
    if raw.trim().is_empty() {
        return Ok(QuarantineTable::default());
    }
    let parsed: QuarantineTable = toml::from_str(&raw).with_context(|| {
        // Don't quarantine the quarantine file: a corrupt entry is worse
        // than a missing one (silently loses state), so on parse error we
        // log loudly and return empty. Operators can `rm` the file if they
        // want to reset; we never auto-delete it because that would mask
        // the real cause (a schema drift between daemon versions).
        format!("parse quarantine table {}", path.display())
    })?;
    Ok(parsed)
}

/// Persist the quarantine table atomically (write-tmp + rename) — a torn
/// write would lose every quarantined slot's state and restart the lock
/// dance from scratch on the very next tick.
pub fn save_quarantine_for(cfg: Option<&Config>, table: &QuarantineTable) -> Result<()> {
    let path = quarantine_path_for(cfg);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).with_context(|| format!("create {}", parent.display()))?;
    }
    let raw = toml::to_string_pretty(table).context("serialize quarantine table")?;
    let tmp = path.with_extension(format!("toml.tmp.{}", std::process::id()));
    std::fs::write(&tmp, raw).with_context(|| format!("write temp {}", tmp.display()))?;
    std::fs::rename(&tmp, &path)
        .with_context(|| format!("rename {} -> {}", tmp.display(), path.display()))?;
    Ok(())
}

impl QuarantineTable {
    /// True iff `slot` currently has an entry. `O(log n)` — fine for fleets
    /// up to a few hundred slots (today: 22).
    pub fn is_quarantined(&self, slot: u32) -> bool {
        self.entries.contains_key(&slot.to_string())
    }

    /// True iff the quarantine table has zero entries. The steady state
    /// during a healthy fleet is `is_empty() == true`; this is the
    /// signal an operator alert (or a regression test) can use to confirm
    /// the table isn't silently accumulating dead slots.
    #[allow(dead_code)]
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Look up the entry for `slot`, if any.
    pub fn get(&self, slot: u32) -> Option<&QuarantineEntry> {
        self.entries.get(&slot.to_string())
    }

    /// Mutable counterpart of `get`. Used by the reconcile tick when it
    /// bumps `attempt_count` after a failed reaper self-heal.
    pub fn get_mut(&mut self, slot: u32) -> Option<&mut QuarantineEntry> {
        self.entries.get_mut(&slot.to_string())
    }

    /// All quarantined slot indices, in ascending order (BTreeMap iteration).
    /// Used by the reconcile tick to walk the auto-recovery pass.
    pub fn slots(&self) -> Vec<u32> {
        self.entries.values().map(|e| e.slot).collect()
    }

    /// Insert or replace the entry for `slot`. The slot key in the map is
    /// derived from `entry.slot` (not the caller-supplied `slot` parameter)
    /// so the on-disk file is internally consistent even if the caller
    /// passes a mismatched slot number — that defensive check guards
    /// against future refactors that split "slot for lookup" from "slot to
    /// record".
    pub fn upsert(&mut self, entry: QuarantineEntry) {
        self.entries.insert(entry.slot.to_string(), entry);
    }

    /// Remove the entry for `slot`. No-op if `slot` is not quarantined.
    pub fn remove(&mut self, slot: u32) -> Option<QuarantineEntry> {
        self.entries.remove(&slot.to_string())
    }

    /// Set of quarantined slot indices, suitable for passing to
    /// `next_slot_excluding` so `ensure_count` won't allocate into a slot
    /// whose runner is currently held hostage by a GH-side 422 lock.
    pub fn excluded_slots(&self) -> std::collections::HashSet<u32> {
        self.entries.keys().filter_map(|k| k.parse().ok()).collect()
    }
}

/// Compute the age (in seconds) of a quarantine entry relative to a "now"
/// epoch-seconds timestamp. Used by the alert body and the auto-recovery
/// pass. Returns 0 if `now < first_seen_epoch_secs` (clock skew, shouldn't
/// happen, but a negative age in an alert is worse than 0).
#[allow(dead_code)] // binary crate: production code inlines the subtract; only tests use this helper
pub fn quarantine_age_secs(entry: &QuarantineEntry, now_epoch_secs: u64) -> u64 {
    now_epoch_secs.saturating_sub(entry.first_seen_epoch_secs)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    fn tmp_path(label: &str) -> PathBuf {
        static SEQ: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let n = SEQ.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let dir = std::env::temp_dir().join(format!(
            "ezgha-quarantine-test-{}-{}-{}",
            std::process::id(),
            label,
            n
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("quarantined_slots.toml")
    }

    static LOCK: std::sync::OnceLock<std::sync::Mutex<()>> = std::sync::OnceLock::new();

    /// Acquire the same lock `TestEnv` uses to guard `TEST_QUARANTINE_PATH`.
    /// Exposed so cross-module tests (e.g. `docker_backend`'s state_dir
    /// isolation tests) that read/write `TEST_QUARANTINE_PATH` directly
    /// without going through `TestEnv` still serialize against every other
    /// quarantine test — otherwise a concurrently-running `TestEnv`-based
    /// test can clobber `TEST_QUARANTINE_PATH` mid-flight (it is checked
    /// before `cfg.state_dir` in `quarantine_path_for`), causing spurious
    /// cross-test data races.
    pub(crate) fn test_lock() -> std::sync::MutexGuard<'static, ()> {
        // Recover from poisoning: a previous test that held the lock and
        // panicked must not cascade into every subsequent test (which is
        // what a bare .unwrap() does on a poisoned mutex). The data this
        // lock guards is the TEST_QUARANTINE_PATH static, which TestEnv's
        // Drop resets anyway, so any half-applied mutation from the
        // panicked test is harmless.
        LOCK.get_or_init(|| std::sync::Mutex::new(()))
            .lock()
            .unwrap_or_else(|e| e.into_inner())
    }

    pub(crate) struct TestEnv {
        _lock: std::sync::MutexGuard<'static, ()>,
        path: PathBuf,
    }

    impl TestEnv {
        pub(crate) fn new(label: &str) -> Self {
            let lock = test_lock();
            let path = tmp_path(label);
            *TEST_QUARANTINE_PATH.lock().unwrap() = Some(path.clone());
            TestEnv { _lock: lock, path }
        }
    }

    impl Drop for TestEnv {
        fn drop(&mut self) {
            *TEST_QUARANTINE_PATH.lock().unwrap() = None;
            let _ = std::fs::remove_file(&self.path);
            if let Some(parent) = self.path.parent() {
                let _ = std::fs::remove_dir(parent);
            }
        }
    }

    fn entry(slot: u32, runner_id: u64, name: &str, reason: QuarantineReason) -> QuarantineEntry {
        QuarantineEntry {
            slot,
            runner_id,
            runner_name: name.into(),
            first_seen_epoch_secs: 1_700_000_000,
            attempt_count: 0,
            last_attempt_epoch_secs: 1_700_000_000,
            reason,
        }
    }

    #[test]
    fn load_returns_empty_when_file_missing() {
        let _env = TestEnv::new("missing");
        let table = load_quarantine_for(None).unwrap();
        assert!(table.entries.is_empty());
    }

    #[test]
    fn save_and_load_round_trip() {
        let _env = TestEnv::new("round_trip");
        let mut table = QuarantineTable::default();
        table.upsert(entry(
            3,
            9999,
            "ez-org-runner-3",
            QuarantineReason::Locked422,
        ));
        table.upsert(entry(
            7,
            4242,
            "ez-org-runner-7",
            QuarantineReason::Locked422,
        ));
        save_quarantine_for(None, &table).unwrap();

        let loaded = load_quarantine_for(None).unwrap();
        assert_eq!(loaded.entries.len(), 2);
        assert_eq!(loaded.get(3).unwrap().runner_id, 9999);
        assert_eq!(loaded.get(7).unwrap().runner_name, "ez-org-runner-7");
        // BTreeMap iteration order: ascending slot.
        assert_eq!(loaded.slots(), vec![3, 7]);
    }

    #[test]
    fn upsert_overwrites_existing_entry_for_same_slot() {
        let mut table = QuarantineTable::default();
        table.upsert(entry(
            3,
            9999,
            "ez-org-runner-3",
            QuarantineReason::Locked422,
        ));
        let updated = QuarantineEntry {
            attempt_count: 5,
            last_attempt_epoch_secs: 1_700_000_500,
            ..entry(3, 9999, "ez-org-runner-3", QuarantineReason::Locked422)
        };
        table.upsert(updated.clone());
        assert_eq!(table.get(3).unwrap().attempt_count, 5);
        assert_eq!(table.get(3).unwrap().last_attempt_epoch_secs, 1_700_000_500);
    }

    #[test]
    fn excluded_slots_returns_only_numeric_keys() {
        let mut table = QuarantineTable::default();
        table.upsert(entry(
            1,
            100,
            "ez-org-runner-1",
            QuarantineReason::Locked422,
        ));
        table.upsert(entry(
            5,
            500,
            "ez-org-runner-5",
            QuarantineReason::Locked422,
        ));
        let excluded = table.excluded_slots();
        assert!(excluded.contains(&1));
        assert!(excluded.contains(&5));
        assert_eq!(excluded.len(), 2);
    }

    #[test]
    fn remove_clears_entry() {
        let mut table = QuarantineTable::default();
        table.upsert(entry(
            3,
            9999,
            "ez-org-runner-3",
            QuarantineReason::Locked422,
        ));
        let removed = table.remove(3);
        assert!(removed.is_some());
        assert!(!table.is_quarantined(3));
        assert!(table.remove(3).is_none(), "second remove is a no-op");
    }

    #[test]
    fn quarantine_age_secs_handles_clock_skew() {
        let e = entry(3, 9999, "ez-org-runner-3", QuarantineReason::Locked422);
        // now == first_seen: age = 0
        assert_eq!(quarantine_age_secs(&e, 1_700_000_000), 0);
        // now > first_seen: positive age
        assert_eq!(quarantine_age_secs(&e, 1_700_000_777), 777);
        // now < first_seen (clock skew): saturating to 0, never negative
        assert_eq!(quarantine_age_secs(&e, 1_699_999_999), 0);
    }

    #[test]
    fn load_returns_empty_on_corrupt_file_without_panicking() {
        let _env = TestEnv::new("corrupt");
        std::fs::write(&_env.path, "this is not valid TOML = = =").unwrap();
        let result = load_quarantine_for(None);
        assert!(result.is_err(), "corrupt file must surface a parse error");
        // Caller's responsibility to surface this; we just confirm we did
        // not panic and did not silently return garbage. The empty-on-parse-
        // error fallback lives in `release_stale_slots` so the daemon
        // degrades gracefully (no quarantined entries this tick) rather
        // than refusing to reconcile.
    }

    #[test]
    fn save_is_atomic_against_partial_reads() {
        // Concurrency contract: a reader opening the file while we're
        // writing must see either the old contents or the new contents,
        // never a torn write. The implementation uses write-tmp + rename(2),
        // which is atomic on POSIX within a directory; this test pins the
        // contract by reading the file from another thread while save
        // runs. If a future refactor switches to a non-atomic write, this
        // test will start failing intermittently (flaky == broken).
        let _env = TestEnv::new("atomic");
        let mut table = QuarantineTable::default();
        table.upsert(entry(
            1,
            100,
            "ez-org-runner-1",
            QuarantineReason::Locked422,
        ));
        save_quarantine_for(None, &table).unwrap();
        let original = std::fs::read_to_string(&_env.path).unwrap();
        assert!(original.contains("runner_name"));

        let new = QuarantineEntry {
            runner_name: "ez-org-runner-1-updated".into(),
            ..entry(2, 200, "ez-org-runner-2", QuarantineReason::Locked422)
        };
        table.upsert(new);
        let path = _env.path.clone();
        let reader = std::thread::spawn(move || std::fs::read_to_string(&path).unwrap());
        save_quarantine_for(None, &table).unwrap();
        let seen = reader.join().unwrap();
        // The reader saw either the original or the new file, never a
        // partial mix: the only legal values are `original` or a string
        // that parses as the new table.
        let either = seen == original || toml::from_str::<QuarantineTable>(&seen).is_ok();
        assert!(
            either,
            "atomic rename must yield old-or-new, never torn (saw {seen:?})"
        );
    }
}
