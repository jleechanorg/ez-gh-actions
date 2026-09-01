# systemd-oomd workload-first cgroup containment review

**Date:** 2026-08-31
**Scope:** Reviewer B research lane for the crash-containment design and companion plan. This reviews only the stated host-Docker, systemd, cgroup-v2, and `systemd-oomd` assumptions.

## Consensus

The proposed hierarchy can provide the intended *workload-first `systemd-oomd` response* when all runner container cgroups are genuine descendants of the system-managed `actions.slice`, cgroup v2 and memory accounting are active, and `user@1000.service` is left at `ManagedOOMMemoryPressure=auto` without a monitored ancestor. `ManagedOOMMemoryPressure=kill` monitors the configured unit but makes only eligible descendants candidates; `actions.slice` itself is not selected. With Docker container scopes below it, an eligible leaf scope is the expected victim. [systemd resource-control source](https://github.com/systemd/systemd/blob/main/man/systemd.resource-control.xml#L1523-L1552) [systemd-oomd source](https://github.com/systemd/systemd/blob/main/man/systemd-oomd.service.xml#L33-L52)

The finite aggregate limits are also meaningful containment controls. On cgroup v2, memory controls are hierarchical; `MemoryHigh=` maps to throttling/reclaim and `MemoryMax=` maps to the hard boundary that invokes cgroup-local OOM when reclaim cannot contain usage. [systemd resource-control source](https://github.com/systemd/systemd/blob/main/man/systemd.resource-control.xml#L365-L414) [kernel cgroup-v2 documentation](https://github.com/torvalds/linux/blob/master/Documentation/admin-guide/cgroup-v2.rst#L1377-L1425)

## Findings

1. **Confirmed: the system-manager `actions.slice` is the right ownership scope for host-Docker scopes, but parentage must be verified at runtime.** Docker supports `--cgroup-parent` as the parent cgroup option, and Docker's cgroup-v2 documentation shows systemd-driver containers as `*.scope` cgroups. A user-manager `actions.slice` cannot constrain those system-manager scopes. The plan correctly requires `/sys/fs/cgroup/actions.slice` and each managed container's configured parent as effective-state evidence. [Docker run reference](https://docs.docker.com/reference/cli/docker/container/run/#cgroup-parent) [Docker cgroup-v2 metrics documentation](https://docs.docker.com/engine/containers/runmetrics/#find-the-cgroup-for-a-given-container)

2. **Confirmed: `ManagedOOMMemoryPressure=auto` on `user@1000.service` disables its direct monitoring.** `auto` means `systemd-oomd` does not actively use that cgroup for monitoring/detection. It can still become a candidate only when an ancestor has `kill`; the described hierarchy has no such ancestor. This supports the plan's narrow claim that `user@` is no longer the broad monitored pressure root. [systemd resource-control source](https://github.com/systemd/systemd/blob/main/man/systemd.resource-control.xml#L1541-L1551)

3. **Caveat: this does not establish a total global order of “runners, then agents, never desktop.”** Each `ManagedOOMMemoryPressure=kill` root is evaluated from that root's own PSI. When pressure triggers, oomd chooses the descendant with the highest reclaim activity under that root. It does not provide an ordering between independent monitored roots such as `actions.slice`, `agents.slice`, and `automation.slice`. Therefore the design can guarantee that an `actions.slice` PSI action selects a runner descendant, but cannot claim actions are always selected before agents. [oomd.conf source](https://github.com/systemd/systemd/blob/main/man/oomd.conf.xml#L178-L204) [oomd selection implementation](https://github.com/systemd/systemd/blob/main/src/oom/oomd-manager.c#L586-L643)

4. **Caveat: `MemoryMax=` is a containment boundary, not a proof that an entire runner container exits.** Kernel cgroup OOM operates inside the limited cgroup. By default `memory.oom.group` is `0`; whole-cgroup killing requires it to be `1` (or an equivalent verified Docker/runtime behavior). The spec's "one runner exceeds its limit -> that container fails" and "per-container limits act first" are stronger than the cited kernel contract unless the effective container `memory.oom.group` policy is asserted. [kernel cgroup-v2 documentation](https://github.com/torvalds/linux/blob/master/Documentation/admin-guide/cgroup-v2.rst#L1403-L1425) [kernel `memory.oom.group` documentation](https://github.com/torvalds/linux/blob/master/Documentation/admin-guide/cgroup-v2.rst#L1477-L1493)

5. **Caveat: the proposed bounded pressure proof tests a kernel `MemoryMax` event, not `systemd-oomd` policy.** A `512M` child with a bounded allocator can prove that the child-local cgroup OOM counter increments and that unrelated processes survive. It does not prove the configured 50% PSI threshold, the default 30-second pressure duration, that `systemd-oomd` is active, or that oomd selected a leaf descendant. The plan should label it a hard-limit proof and add a separate controlled oomd proof or explicit `oomctl`/journal evidence for the monitored roots. [kernel `memory.events` documentation](https://github.com/torvalds/linux/blob/master/Documentation/admin-guide/cgroup-v2.rst#L1495-L1547) [oomd pressure defaults](https://github.com/systemd/systemd/blob/main/man/oomd.conf.xml#L178-L204)

6. **Caveat: a 12-GiB arithmetic reserve reduces risk but cannot prove desktop survival during a host-wide kernel OOM.** `MemoryHigh=` may be exceeded and only throttles/reclaims; `MemoryMax=` confines an inability-to-reclaim event to the workload cgroup. However, host-wide pressure from memory outside the capped workload aggregates can still invoke the global kernel OOM killer. Treat “desktop remains alive” as an integration result of the live pressure proof, not a static property of the three budget totals. [kernel cgroup-v2 documentation](https://github.com/torvalds/linux/blob/master/Documentation/admin-guide/cgroup-v2.rst#L1377-L1425) [systemd-oomd requirements](https://github.com/systemd/systemd/blob/main/man/systemd-oomd.service.xml#L69-L95)

7. **Caveat: `MemorySwapMax=0` weakens oomd reaction time under abrupt exhaustion.** systemd's own documentation states that without swap, pressure rises more abruptly and oomd may not respond in time; the hard cgroup limits remain the fallback. This does not make the choice invalid, but the plan should not describe oomd as deterministic or prompt under no-swap conditions. [systemd-oomd source](https://github.com/systemd/systemd/blob/main/man/systemd-oomd.service.xml#L77-L87)

## Required Coverage for the Existing Plan

- Verify a unified cgroup-v2 hierarchy and memory accounting before accepting host Docker; these are `systemd-oomd` prerequisites. [systemd-oomd source](https://github.com/systemd/systemd/blob/main/man/systemd-oomd.service.xml#L69-L75)
- Verify effective, not configured, limits (`EffectiveMemoryHigh`, `EffectiveMemoryMax`, `EffectiveTasksMax`, and `cpu.max`), including every ancestor. systemd reports effective memory limits as the most stringent unit/parent limit. [systemd resource-control source](https://github.com/systemd/systemd/blob/main/man/systemd.resource-control.xml#L396-L414)
- Verify actual per-container cgroup paths beneath `/actions.slice`, not just Docker's `CgroupParent` intent. The cgroup-v2 controller hierarchy is top-down, and available controllers must be enabled through the parent hierarchy. [kernel cgroup-v2 documentation](https://github.com/torvalds/linux/blob/master/Documentation/admin-guide/cgroup-v2.rst#L143-L180)
- Verify `user@UID.service=auto` and that no ancestor of it has `ManagedOOMMemoryPressure=kill`; verify `oomctl` lists only intended workload monitoring roots.
- For a claim that a runner rather than merely a process fails, verify the effective `memory.oom.group` setting for the container scope and test the container's exit/replenishment behavior.
- Separate proof labels: `MemoryMax` child-OOM containment; PSI/oomd monitoring and victim-selection proof; and host/desktop survival proof.

## Source Coverage

- systemd primary documentation and implementation: `systemd.resource-control`, `systemd-oomd`, `oomd.conf`, and the oomd candidate-selection implementation.
- Linux primary documentation: cgroup-v2 memory, hierarchy, PSI, and OOM-group semantics.
- Docker primary documentation: cgroup-v2 runtime layout and `--cgroup-parent` interface.

No secondary sources, live-host mutation, service inspection, or implementation files were used in this lane.
