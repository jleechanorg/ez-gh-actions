use crate::config::IsolationLevel;
use crate::platform::Platform;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Backend {
    /// Tart VMs (macOS Apple Silicon). Detected, not yet driven by ezgha.
    Tart,
    /// libvirt/KVM VMs (Linux). Detected, not yet driven by ezgha.
    Libvirt,
    /// Docker with the sysbox-runc runtime (stronger container isolation).
    DockerSysbox,
    /// Plain Docker with hard resource limits.
    Docker,
}

impl Backend {
    /// Host-blast-radius containment this backend provides on THIS host.
    /// Docker counts as VM-grade when the daemon itself runs inside a VM
    /// (Colima/Lima/Docker Desktop): per-job isolation is still container-
    /// grade, but a runaway job cannot take the host down — which is what
    /// the `minimum_isolation` policy guards.
    pub fn isolation(self, daemon_in_vm: bool) -> IsolationLevel {
        match self {
            Backend::Tart | Backend::Libvirt => IsolationLevel::Vm,
            Backend::DockerSysbox | Backend::Docker => {
                if daemon_in_vm {
                    IsolationLevel::Vm
                } else {
                    IsolationLevel::Container
                }
            }
        }
    }

    /// Whether ezgha can actually start runners on this backend today.
    /// Tart/libvirt are detected and reported by `doctor`, but driving them
    /// (image management, cloud-init, VM lifecycle) is milestone 2.
    pub fn implemented(self) -> bool {
        matches!(self, Backend::DockerSysbox | Backend::Docker)
    }

    pub fn name(self) -> &'static str {
        match self {
            Backend::Tart => "tart (VM)",
            Backend::Libvirt => "libvirt (VM)",
            Backend::DockerSysbox => "docker+sysbox (container)",
            Backend::Docker => "docker (container)",
        }
    }
}

/// Every backend this host could offer, strongest isolation first.
pub fn candidates(plat: &Platform) -> Vec<Backend> {
    let mut out = Vec::new();
    if plat.os == "macos" && plat.has_tart {
        out.push(Backend::Tart);
    }
    if plat.os == "linux" && plat.kvm_usable && plat.has_virsh {
        out.push(Backend::Libvirt);
    }
    if plat.docker_ok && plat.sysbox_runtime {
        out.push(Backend::DockerSysbox);
    }
    if plat.docker_ok {
        out.push(Backend::Docker);
    }
    out
}

pub enum Selection {
    /// Best implemented backend, plus any stronger-but-unimplemented ones we
    /// skipped (so callers can warn instead of silently degrading).
    Chosen {
        backend: Backend,
        skipped_stronger: Vec<Backend>,
    },
    /// Host has a usable backend but policy demands stronger isolation.
    PolicyBlocked {
        best_available: Backend,
        required: IsolationLevel,
    },
    /// Nothing usable at all.
    None,
}

pub fn select(plat: &Platform, minimum: IsolationLevel) -> Selection {
    let cands = candidates(plat);
    let mut skipped = Vec::new();
    for backend in &cands {
        if !backend.implemented() {
            skipped.push(*backend);
            continue;
        }
        if backend.isolation(plat.daemon_in_vm) < minimum {
            return Selection::PolicyBlocked {
                best_available: *backend,
                required: minimum,
            };
        }
        return Selection::Chosen {
            backend: *backend,
            skipped_stronger: skipped,
        };
    }
    Selection::None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plat(
        os: &'static str,
        kvm: bool,
        tart: bool,
        virsh: bool,
        docker: bool,
        sysbox: bool,
    ) -> Platform {
        Platform {
            os,
            arch: "x86_64",
            kvm_usable: kvm,
            has_tart: tart,
            has_virsh: virsh,
            docker_ok: docker,
            sysbox_runtime: sysbox,
            daemon_in_vm: false,
            total_mem_mb: 8192,
            cpus: 8,
        }
    }

    #[test]
    fn macos_prefers_tart_in_candidates() {
        let c = candidates(&plat("macos", false, true, false, true, false));
        assert_eq!(c, vec![Backend::Tart, Backend::Docker]);
    }

    #[test]
    fn linux_kvm_prefers_libvirt_in_candidates() {
        let c = candidates(&plat("linux", true, false, true, true, false));
        assert_eq!(c, vec![Backend::Libvirt, Backend::Docker]);
    }

    #[test]
    fn sysbox_outranks_plain_docker() {
        let c = candidates(&plat("linux", false, false, false, true, true));
        assert_eq!(c, vec![Backend::DockerSysbox, Backend::Docker]);
    }

    #[test]
    fn select_skips_unimplemented_vm_and_warns() {
        match select(
            &plat("linux", true, false, true, true, false),
            IsolationLevel::Container,
        ) {
            Selection::Chosen {
                backend,
                skipped_stronger,
            } => {
                assert_eq!(backend, Backend::Docker);
                assert_eq!(skipped_stronger, vec![Backend::Libvirt]);
            }
            _ => panic!("expected Chosen"),
        }
    }

    #[test]
    fn select_fails_closed_when_policy_requires_vm() {
        match select(
            &plat("linux", false, false, false, true, false),
            IsolationLevel::Vm,
        ) {
            Selection::PolicyBlocked {
                best_available,
                required,
            } => {
                assert_eq!(best_available, Backend::Docker);
                assert_eq!(required, IsolationLevel::Vm);
            }
            _ => panic!("expected PolicyBlocked"),
        }
    }

    #[test]
    fn no_backend_when_nothing_usable() {
        assert!(matches!(
            select(
                &plat("linux", false, false, false, false, false),
                IsolationLevel::Container
            ),
            Selection::None
        ));
    }

    #[test]
    fn docker_in_vm_daemon_satisfies_vm_policy() {
        let mut p = plat("linux", false, false, false, true, false);
        p.daemon_in_vm = true;
        match select(&p, IsolationLevel::Vm) {
            Selection::Chosen { backend, .. } => assert_eq!(backend, Backend::Docker),
            _ => panic!("VM-contained daemon must satisfy vm policy"),
        }
    }

    #[test]
    fn bare_metal_daemon_refused_under_vm_policy() {
        let p = plat("linux", false, false, false, true, false);
        assert!(matches!(
            select(&p, IsolationLevel::Vm),
            Selection::PolicyBlocked { .. }
        ));
    }
}
