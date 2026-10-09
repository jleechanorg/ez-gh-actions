# Borg Failure Ladder Plan

> Updated 2026-08-27 after the host-lifecycle safety incident. Repository
> automation has no authority to restart, shut down, or deliberately panic the
> physical host. Verification in this plan is read-only or hermetic.

## Goal

Failures collapse inward: job/process, one container/slot, fleet admission, then
the VM. The physical host remains available for diagnosis and operator recovery.

## Failure ladder

| Layer | Automatic response | Recovery boundary |
|---|---|---|
| Job/process | Resource limits terminate the offending child. | Ephemeral container replacement. |
| Slot/container | A persistent per-slot circuit pauses that slot. | Bounded cooldown and gradual retry. |
| Fleet | A fleet circuit closes admission without stopping existing jobs. | Bounded cooldown and gradual retry. |
| VM | Finite cgroups contain aggregate runner demand. | VM supervisor or explicit operator action. |
| Physical host | No automated lifecycle action. | Operator diagnosis and recovery only. |

## Consolidated work

1. Remove repository mechanisms and instructions that grant automation host
   lifecycle authority. Keep an executable policy regression test.
2. Keep crash-capture checks diagnostic-only; they may report missing readiness
   but may not run remediation or alter boot state.
3. Preserve finite job, container, VM, and agent-slice resource limits. Admission
   closes before aggregate demand escapes those boundaries.
4. Fix rapid slot reclaim/respawn churn using hermetic tests and local evidence;
   do not validate with synthetic load, pressure, panic, service restarts, or VM
   lifecycle changes.
5. Restore the 10-Linux capacity contract only after the daemon is deployed by a
   designated operator and all ten local slots remain present with a
   `Runner.Worker` process during a stable observation window.

## Safe verification

Permitted: Rust unit tests without live backends, shell fixture tests, syntax and
format checks, static policy checks, and read-only inspection.

Forbidden: synthetic CPU/memory/disk pressure, panic or OOM triggers, Docker
runner creation/removal, service or VM lifecycle changes, and any physical-host
lifecycle action.

## Completion boundary

Repository completion requires the policy and hermetic tests to agree. It does
not prove the live host safe. Live completion additionally requires an operator
to remove boot-enabled host-lifecycle automation and panic auto-recovery, then a
read-only stability observation of all 10 Linux slots. Until those conditions
hold simultaneously, the ironclad host-survival verdict remains **FAIL**.
