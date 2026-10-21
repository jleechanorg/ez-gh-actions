//! Opt-in recovery threshold. Bounds are conditional on the operator's measured
//! aggregate burn/delay/growth envelope, not a filesystem quota or OOM guarantee.
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct DiskRecovery {
    /// Filesystem containing managed scratch, measured with statvfs f_bavail.
    pub scratch_root: std::path::PathBuf,
    pub aggregate_burn_gib_per_minute: u64,
    pub detection_and_dispatch_delay_secs: u64,
    pub active_job_growth_gib: u64,
    pub protected_reserve_gib: u64,
}

impl DiskRecovery {
    pub fn high_water_gib(&self, low: u64) -> Result<u64> {
        if !self.scratch_root.is_absolute()
            || low < 30
            || self.aggregate_burn_gib_per_minute == 0
            || self.detection_and_dispatch_delay_secs == 0
            || self.active_job_growth_gib == 0
            || self.protected_reserve_gib == 0
        {
            bail!("disk recovery requires floor >= 30 GiB and positive measured envelope values");
        }
        let delay_loss = self
            .aggregate_burn_gib_per_minute
            .checked_mul(self.detection_and_dispatch_delay_secs)
            .and_then(|v| v.checked_add(59))
            .context("disk recovery envelope overflow")?
            / 60;
        low.checked_add(delay_loss)
            .and_then(|v| v.checked_add(self.active_job_growth_gib))
            .and_then(|v| v.checked_add(self.protected_reserve_gib))
            .context("disk recovery high-water overflow")
    }
}

#[derive(Debug, Default)]
pub struct RecoveryLatch {
    pub(crate) open: bool,
}
impl RecoveryLatch {
    pub fn floor(&self, low: u64, high: u64) -> u64 {
        if self.open {
            low
        } else {
            high
        }
    }
    pub fn observe(&mut self, admitted: bool) {
        self.open = admitted;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn policy() -> DiskRecovery {
        DiskRecovery {
            scratch_root: "/tmp/managed-scratch".into(),
            aggregate_burn_gib_per_minute: 6,
            detection_and_dispatch_delay_secs: 75,
            active_job_growth_gib: 4,
            protected_reserve_gib: 3,
        }
    }
    #[test]
    fn measured_envelope_derives_threshold_and_rounds_up() {
        // ceil(6 * 75 / 60) = 8; 30 + 8 + 4 + 3 = 45, not a round-number guess.
        assert_eq!(policy().high_water_gib(30).unwrap(), 45);
        // Conditional worst-case delayed depletion + active growth leaves reserve.
        assert!(45 - 8 - 4 >= 30 + 3);
    }
    #[test]
    fn invalid_and_overflow_envelopes_refused() {
        let mut p = policy();
        p.aggregate_burn_gib_per_minute = u64::MAX;
        assert!(p.high_water_gib(30).is_err());
        p = policy();
        p.active_job_growth_gib = 0;
        assert!(p.high_water_gib(30).is_err());
        assert!(policy().high_water_gib(29).is_err());
    }
    #[test]
    fn restart_and_any_failed_joint_admission_require_high_water() {
        let mut gate = RecoveryLatch::default();
        assert_eq!(gate.floor(30, 45), 45);
        gate.observe(true);
        assert_eq!(gate.floor(30, 45), 30);
        // Low memory, PSI refusal, unknown measurement and disk floor all close it.
        gate.observe(false);
        assert_eq!(gate.floor(30, 45), 45);
    }
}
