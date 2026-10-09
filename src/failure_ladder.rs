//! Persistent, local-only failure circuits for runner admission.
//!
//! This ledger deliberately records only failures observed while starting a
//! local runner/container.  It does not interpret GitHub job conclusions and
//! it never performs container, VM, or host lifecycle actions.  Its caller
//! persists it after a transition and uses [`FailureLadder::excluded_slots`]
//! and [`FailureLadder::fleet_admission_is_paused`] to make admission fail at
//! the smallest possible layer.

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::io::Write;
use std::path::Path;

#[cfg(test)]
thread_local! {
    static TEST_SAVE_CALL_COUNT: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
    static TEST_FAIL_SAVE_ON_CALL: std::cell::Cell<Option<usize>> = const { std::cell::Cell::new(None) };
}

/// Test-only seam used to deterministically exercise callers' persistence
/// failure handling without relying on filesystem permissions or races.
#[cfg(test)]
pub(crate) fn set_test_save_failure_on_call(call: Option<usize>) {
    TEST_FAIL_SAVE_ON_CALL.with(|target| target.set(call));
}

#[cfg(test)]
pub(crate) fn reset_test_save_failure() {
    TEST_SAVE_CALL_COUNT.with(|count| count.set(0));
    TEST_FAIL_SAVE_ON_CALL.with(|target| target.set(None));
}

/// Conservative, independently validated circuit thresholds.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub struct FailureLadderPolicy {
    /// Failed local starts required to open one slot's circuit.
    pub slot_failure_threshold: u32,
    /// Rolling window in which failed starts are counted.
    pub slot_window_secs: u64,
    /// How long an opened slot is excluded from allocation.
    pub slot_cooldown_secs: u64,
    /// Concurrently open, distinct slot circuits required to pause admission.
    pub fleet_open_slots_threshold: u32,
    /// How long the fleet admission pause lasts.
    pub fleet_cooldown_secs: u64,
}

impl Default for FailureLadderPolicy {
    fn default() -> Self {
        Self {
            slot_failure_threshold: 3,
            slot_window_secs: 10 * 60,
            slot_cooldown_secs: 15 * 60,
            fleet_open_slots_threshold: 3,
            fleet_cooldown_secs: 10 * 60,
        }
    }
}

impl FailureLadderPolicy {
    /// Reject policy values that could accidentally turn a circuit into a
    /// permanent admission stop or an immediate retry loop.
    pub fn validate(&self) -> Result<()> {
        if self.slot_failure_threshold == 0 {
            bail!("failure_ladder.slot_failure_threshold must be at least 1");
        }
        if self.slot_window_secs == 0 {
            bail!("failure_ladder.slot_window_secs must be greater than 0");
        }
        if self.slot_cooldown_secs == 0 {
            bail!("failure_ladder.slot_cooldown_secs must be greater than 0");
        }
        if self.fleet_open_slots_threshold == 0 {
            bail!("failure_ladder.fleet_open_slots_threshold must be at least 1");
        }
        if self.fleet_cooldown_secs == 0 {
            bail!("failure_ladder.fleet_cooldown_secs must be greater than 0");
        }
        Ok(())
    }
}

/// A durable local-failure ledger.  `BTreeMap` keeps the TOML deterministic
/// for operators and tests.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct FailureLadder {
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    slots: BTreeMap<String, SlotFailureState>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    fleet_open_until_epoch_secs: Option<u64>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct SlotFailureState {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    failure_epoch_secs: Vec<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    open_until_epoch_secs: Option<u64>,
}

/// The state changes caused by one recorded local event.  Callers should alert
/// only when one of the `*_opened` or `*_closed` flags is true, rather than on
/// every reconciliation tick.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct FailureLadderTransition {
    pub slot: Option<u32>,
    pub slot_failure_count: usize,
    pub slot_opened: bool,
    pub slot_closed: bool,
    pub fleet_opened: bool,
    pub fleet_closed: bool,
}

impl FailureLadder {
    /// Load a ledger from `path`.  A missing file is the healthy empty state;
    /// a present-but-corrupt file is an error so callers fail closed instead
    /// of silently forgetting opened circuits.
    pub fn load(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref();
        if !path.exists() {
            return Ok(Self::default());
        }
        let raw = fs::read_to_string(path)
            .with_context(|| format!("read failure-ladder state {}", path.display()))?;
        let state: Self = toml::from_str(&raw)
            .with_context(|| format!("parse failure-ladder state {}", path.display()))?;
        state.validate_persisted().with_context(|| {
            format!(
                "validate failure-ladder state {} (refusing corrupt ledger)",
                path.display()
            )
        })?;
        Ok(state)
    }

    /// Persist atomically with a temporary sibling followed by rename.
    pub fn save(&self, path: impl AsRef<Path>) -> Result<()> {
        #[cfg(test)]
        let fail_this_call = TEST_SAVE_CALL_COUNT.with(|count| {
            let call = count.get().saturating_add(1);
            count.set(call);
            TEST_FAIL_SAVE_ON_CALL.with(|target| target.get() == Some(call))
        });
        #[cfg(test)]
        if fail_this_call {
            bail!("simulated failure-ladder persistence failure");
        }
        let path = path.as_ref();
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("create failure-ladder directory {}", parent.display()))?;
        }
        let raw = toml::to_string_pretty(self).context("serialize failure-ladder state")?;
        let tmp = path.with_extension(format!("toml.tmp.{}", std::process::id()));
        let mut tmp_file = fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .open(&tmp)
            .with_context(|| format!("open failure-ladder temporary state {}", tmp.display()))?;
        tmp_file
            .write_all(raw.as_bytes())
            .with_context(|| format!("write failure-ladder temporary state {}", tmp.display()))?;
        tmp_file
            .sync_all()
            .with_context(|| format!("sync failure-ladder temporary state {}", tmp.display()))?;
        fs::rename(&tmp, path).with_context(|| {
            format!(
                "rename failure-ladder temporary state {} -> {}",
                tmp.display(),
                path.display()
            )
        })?;
        if let Some(parent) = path.parent() {
            fs::File::open(parent)
                .with_context(|| format!("open failure-ladder directory {}", parent.display()))?
                .sync_all()
                .with_context(|| format!("sync failure-ladder directory {}", parent.display()))?;
        }
        Ok(())
    }

    /// Record one observed local start failure.  Opening a slot circuit does
    /// not affect its siblings.  Once enough *distinct* slots are open, a
    /// separate, finite fleet admission pause is opened.
    pub fn record_failure(
        &mut self,
        policy: FailureLadderPolicy,
        slot: u32,
        now_epoch_secs: u64,
    ) -> Result<FailureLadderTransition> {
        policy.validate()?;
        let mut transition = self.expire(now_epoch_secs);
        transition.slot = Some(slot);

        let state = self.slots.entry(slot.to_string()).or_default();
        state
            .failure_epoch_secs
            .retain(|then| now_epoch_secs.saturating_sub(*then) <= policy.slot_window_secs);
        state.failure_epoch_secs.push(now_epoch_secs);
        transition.slot_failure_count = state.failure_epoch_secs.len();

        if !state.is_open(now_epoch_secs)
            && state.failure_epoch_secs.len() >= policy.slot_failure_threshold as usize
        {
            state.open_until_epoch_secs =
                Some(now_epoch_secs.saturating_add(policy.slot_cooldown_secs));
            // A slot receives a fresh bounded retry budget after its cooldown.
            // Without this reset, a policy whose cooldown is shorter than its
            // window could reopen from historic failures after one retry.
            state.failure_epoch_secs.clear();
            transition.slot_opened = true;
        }

        if transition.slot_opened
            && !self.fleet_admission_is_paused(now_epoch_secs)
            && self.open_slot_count(now_epoch_secs) >= policy.fleet_open_slots_threshold as usize
        {
            self.fleet_open_until_epoch_secs =
                Some(now_epoch_secs.saturating_add(policy.fleet_cooldown_secs));
            transition.fleet_opened = true;
        }
        Ok(transition)
    }

    /// A successful local start clears all failure history for that slot.  A
    /// fleet pause remains finite and is not cancelled early: this avoids
    /// admission flapping during a systemic incident.
    pub fn record_success(&mut self, slot: u32, now_epoch_secs: u64) -> FailureLadderTransition {
        let mut transition = self.expire(now_epoch_secs);
        transition.slot = Some(slot);
        if let Some(old) = self.slots.remove(&slot.to_string()) {
            transition.slot_closed = transition.slot_closed || old.is_open(now_epoch_secs);
        }
        transition
    }

    /// True while this slot is excluded from new allocation.
    pub fn slot_is_open(&self, slot: u32, now_epoch_secs: u64) -> bool {
        self.slots
            .get(&slot.to_string())
            .is_some_and(|state| state.is_open(now_epoch_secs))
    }

    /// True while all new runner starts must be paused.  Existing containers
    /// are intentionally outside this module's authority.
    pub fn fleet_admission_is_paused(&self, now_epoch_secs: u64) -> bool {
        self.fleet_open_until_epoch_secs
            .is_some_and(|until| now_epoch_secs < until)
    }

    /// Slot indices currently excluded from allocation.
    pub fn excluded_slots(&self, now_epoch_secs: u64) -> HashSet<u32> {
        self.slots
            .iter()
            .filter_map(|(slot, state)| {
                state
                    .is_open(now_epoch_secs)
                    .then(|| slot.parse::<u32>().ok())
                    .flatten()
            })
            .collect()
    }

    /// Number of currently open slot circuits; exposed for concise status and
    /// alert messages without exposing the on-disk schema.
    pub fn open_slot_count(&self, now_epoch_secs: u64) -> usize {
        self.slots
            .values()
            .filter(|state| state.is_open(now_epoch_secs))
            .count()
    }

    /// Clear elapsed circuit deadlines so expiry is a one-time explicit
    /// transition and the next persisted state no longer carries stale opens.
    fn expire(&mut self, now_epoch_secs: u64) -> FailureLadderTransition {
        let mut transition = FailureLadderTransition::default();
        for state in self.slots.values_mut() {
            if state
                .open_until_epoch_secs
                .is_some_and(|until| now_epoch_secs >= until)
            {
                state.open_until_epoch_secs = None;
                transition.slot_closed = true;
            }
        }
        if self
            .fleet_open_until_epoch_secs
            .is_some_and(|until| now_epoch_secs >= until)
        {
            self.fleet_open_until_epoch_secs = None;
            transition.fleet_closed = true;
        }
        transition
    }

    fn validate_persisted(&self) -> Result<()> {
        for slot in self.slots.keys() {
            slot.parse::<u32>()
                .with_context(|| format!("failure-ladder slot key must be a u32, got {slot:?}"))?;
        }
        Ok(())
    }
}

impl SlotFailureState {
    fn is_open(&self, now_epoch_secs: u64) -> bool {
        self.open_until_epoch_secs
            .is_some_and(|until| now_epoch_secs < until)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn test_path(label: &str) -> std::path::PathBuf {
        static SEQUENCE: AtomicUsize = AtomicUsize::new(0);
        let n = SEQUENCE.fetch_add(1, Ordering::SeqCst);
        std::env::temp_dir()
            .join(format!(
                "ezgha-failure-ladder-{label}-{}-{n}",
                std::process::id()
            ))
            .join("failure_ladder.toml")
    }

    #[test]
    fn default_policy_is_conservative_and_valid() {
        let policy = FailureLadderPolicy::default();
        assert_eq!(policy.slot_failure_threshold, 3);
        assert_eq!(policy.slot_window_secs, 600);
        assert_eq!(policy.slot_cooldown_secs, 900);
        assert_eq!(policy.fleet_open_slots_threshold, 3);
        assert_eq!(policy.fleet_cooldown_secs, 600);
        policy.validate().unwrap();
    }

    #[test]
    fn policy_rejects_zero_safety_boundaries() {
        let invalid = [
            FailureLadderPolicy {
                slot_failure_threshold: 0,
                ..FailureLadderPolicy::default()
            },
            FailureLadderPolicy {
                slot_window_secs: 0,
                ..FailureLadderPolicy::default()
            },
            FailureLadderPolicy {
                slot_cooldown_secs: 0,
                ..FailureLadderPolicy::default()
            },
            FailureLadderPolicy {
                fleet_open_slots_threshold: 0,
                ..FailureLadderPolicy::default()
            },
            FailureLadderPolicy {
                fleet_cooldown_secs: 0,
                ..FailureLadderPolicy::default()
            },
        ];
        for policy in invalid {
            assert!(policy.validate().is_err());
        }
    }

    #[test]
    fn failures_outside_the_rolling_window_do_not_open_a_slot() {
        let policy = FailureLadderPolicy::default();
        let mut ladder = FailureLadder::default();
        ladder.record_failure(policy, 4, 0).unwrap();
        ladder.record_failure(policy, 4, 601).unwrap();
        let transition = ladder.record_failure(policy, 4, 1_202).unwrap();
        assert_eq!(transition.slot_failure_count, 1);
        assert!(!transition.slot_opened);
        assert!(!ladder.slot_is_open(4, 1_202));
    }

    #[test]
    fn third_failure_opens_only_that_slot_until_cooldown_expires() {
        let policy = FailureLadderPolicy::default();
        let mut ladder = FailureLadder::default();
        ladder.record_failure(policy, 4, 10).unwrap();
        ladder.record_failure(policy, 4, 11).unwrap();
        let transition = ladder.record_failure(policy, 4, 12).unwrap();
        assert!(transition.slot_opened);
        assert!(ladder.slot_is_open(4, 911));
        assert!(!ladder.slot_is_open(4, 912));
        assert!(ladder.excluded_slots(911).contains(&4));
        assert!(!ladder.excluded_slots(912).contains(&4));
    }

    #[test]
    fn successful_start_resets_a_slot_failure_history() {
        let policy = FailureLadderPolicy::default();
        let mut ladder = FailureLadder::default();
        ladder.record_failure(policy, 2, 10).unwrap();
        ladder.record_failure(policy, 2, 11).unwrap();
        let transition = ladder.record_success(2, 12);
        assert!(!transition.slot_closed);
        assert!(!ladder.slot_is_open(2, 12));
        assert_eq!(
            ladder
                .record_failure(policy, 2, 13)
                .unwrap()
                .slot_failure_count,
            1
        );
    }

    #[test]
    fn three_distinct_open_slots_pause_fleet_admission() {
        let policy = FailureLadderPolicy::default();
        let mut ladder = FailureLadder::default();
        for slot in 1..=3 {
            ladder.record_failure(policy, slot, 10).unwrap();
            ladder.record_failure(policy, slot, 11).unwrap();
            let transition = ladder.record_failure(policy, slot, 12).unwrap();
            assert_eq!(transition.fleet_opened, slot == 3);
        }
        assert!(ladder.fleet_admission_is_paused(12));
        assert!(!ladder.fleet_admission_is_paused(612));
    }

    #[test]
    fn round_trip_preserves_open_circuits() {
        let path = test_path("round-trip");
        let policy = FailureLadderPolicy::default();
        let mut ladder = FailureLadder::default();
        for slot in 1..=3 {
            for now in 1..=3 {
                ladder.record_failure(policy, slot, now).unwrap();
            }
        }
        ladder.save(&path).unwrap();
        let restored = FailureLadder::load(&path).unwrap();
        assert_eq!(restored, ladder);
        assert!(restored.slot_is_open(1, 3));
        assert!(restored.fleet_admission_is_paused(3));
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn corrupt_state_fails_closed() {
        let path = test_path("corrupt");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, "not = [valid").unwrap();
        let error = FailureLadder::load(&path).unwrap_err();
        assert!(error.to_string().contains("parse failure-ladder state"));
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }
}
