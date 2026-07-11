# Host-ops sudo block — bead ez-gh-actions-0725 (system-scope remainder)

**Not executed by any agent.** This is a copy-pasteable reference for the
human operator to run deliberately on jeff-ubuntu. Everything above the
line "## System-scope commands" was achievable at user scope and is
already implemented + committed in this repo (see `systemd/agents.slice`,
`scripts/host/agent-cli-scoped.sh`, `scripts/host/psi-oom-watcher.sh` +
`systemd/psi-oom-watcher.{service,timer}`). This document covers only the
pieces that genuinely require root.

## Sequencing constraint (read first)

Per the panel decision on bead `ez-gh-actions-ah94` (Tier 1 do-now): the
OOM-prevention layer below **must land before or with** any planned
swapfile expansion (that expansion is a separate ops-lane task, described
on `ah94` as "in motion" — not part of this bead). **zram must NOT be
enabled** until this OOM layer is verified working in production —
thin-provisioning brownout risk on zram makes it strictly worse than a
plain swapfile if memory pressure isn't already being caught upstream.

## Finding: systemd-oomd is already installed and running

Checked live on jeff-ubuntu 2026-07-10 (read-only, no changes made):

```
$ systemctl status systemd-oomd
● systemd-oomd.service - Userspace Out-Of-Memory (OOM) Killer
     Active: active (running)
$ dpkg -l | grep systemd-oomd
ii  systemd-oomd   255.4-1ubuntu8.16   amd64   userspace out-of-memory (OOM) killer
$ systemctl show -p ManagedOOMMemoryPressure,ManagedOOMSwap user.slice user-1000.slice
ManagedOOMSwap=auto
ManagedOOMMemoryPressure=auto
```

systemd-oomd ships enabled by default on Ubuntu 24.04 and is already
managing `user.slice`, `user-1000.slice`, and the root slice with its
**compiled-in defaults** (`SwapUsedLimit=90%`,
`DefaultMemoryPressureLimit=60%`, `DefaultMemoryPressureDurationSec=30s` —
`/etc/systemd/oomd.conf` exists but every line is commented out, i.e. pure
defaults, no local tuning). It has fired at least once historically
(journalctl shows it killing a Chrome tab under sustained >50% pressure).

**These defaults evidently were NOT tight enough to prevent the
2026-07-10 incident** (16GB swapfile pegged 99-100% for multiple days,
D-state process pileup, load 218, watchdog reboot). Two independent
remediation paths, pick ONE (both are documented below since availability/
preference may vary):

- **Option A (recommended, lower blast radius): tune the existing
  systemd-oomd via a drop-in.** No new package, no new failure surface —
  just tighter thresholds on infrastructure already proven to be wired
  into the right cgroups. This is the path of least new risk.
- **Option B: install earlyoom instead/in addition.** earlyoom is NOT
  currently installed (`apt-cache policy earlyoom` shows
  `Installed: (none)`, `Candidate: 1.7-2`) — this requires `apt-get
  install`, hence sudo, hence this document rather than something the
  agent could do unprivileged. Only pursue this if you specifically want
  earlyoom's PID-oom-score-based selection logic instead of/alongside
  systemd-oomd's PSI+swap-based cgroup selection — running both is
  possible but adds operational complexity (two daemons that can each
  independently decide to kill something) for limited extra coverage,
  since Option A already targets the same PSI signal systemd-oomd already
  has full-system visibility into (this repo's user-scope
  `psi-oom-watcher.sh` fallback deliberately only sees `/proc/pressure/memory`
  and its own user's processes — a real system daemon has strictly more
  visibility and should be preferred where available).

Do NOT enable zram until whichever option you pick has been observed
actually intervening (or confirmed absent-intervention because pressure
stayed healthy) through at least one full day of normal multi-agent load.

---

## System-scope commands

### Option A — tune systemd-oomd (recommended first move)

```bash
# 1. Create a drop-in tightening the pressure/swap thresholds. Numbers
#    chosen to fire meaningfully before the host watchdog's max-load-1
#    territory (this host's /etc/watchdog.conf currently reads
#    max-load-1=96 as of 2026-07-10 -- confirm the live value with
#    `grep max-load /etc/watchdog.conf` before picking thresholds, since a
#    prior remediation pass may have already changed it from the 24 value
#    referenced in this repo's CLAUDE.md). Tighter than stock 60%/30s:
#    30%/15s sustained pressure is a much earlier signal, well before
#    D-state pileup has a chance to compound.
sudo mkdir -p /etc/systemd/oomd.conf.d
sudo tee /etc/systemd/oomd.conf.d/10-tighter-thresholds.conf > /dev/null <<'EOF'
[OOM]
SwapUsedLimit=80%
DefaultMemoryPressureLimit=30%
DefaultMemoryPressureDurationSec=15s
EOF

# 2. Explicitly confirm user.slice stays managed (it already is via
#    "auto" default, but this makes the intent durable/explicit against
#    future distro default changes):
sudo mkdir -p /etc/systemd/system/user-1000.slice.d
sudo tee /etc/systemd/system/user-1000.slice.d/10-managed-oom.conf > /dev/null <<'EOF'
[Slice]
ManagedOOMMemoryPressure=kill
ManagedOOMMemoryPressureLimit=30%
ManagedOOMSwap=kill
EOF

# 3. Apply.
sudo systemctl daemon-reload
sudo systemctl restart systemd-oomd

# 4. Verify it picked up the new config.
systemd-analyze cat-config systemd/oomd.conf
systemctl status systemd-oomd
```

### Option B — install earlyoom (alternative/supplemental)

```bash
sudo apt-get update
sudo apt-get install -y earlyoom

# Tune via /etc/default/earlyoom (Debian/Ubuntu packaging convention).
# -m / -s here are PERCENT-FREE thresholds (not PSI directly -- earlyoom's
# PSI-aware mode is enabled by default when the kernel supports it via
# --avoid/--prefer flags for target selection, but its core trigger is
# available-memory + swap-free percentage, tuned here to fire earlier than
# the historical incident's near-100% swap saturation):
sudo tee /etc/default/earlyoom > /dev/null <<'EOF'
# -m <percent>  : trigger when available memory falls below this percent
# -s <percent>  : trigger when available swap falls below this percent
# -r <seconds>  : report memory status at this interval (0 = only on kill)
# --avoid       : regex of processes to NEVER kill (protects the ezgha
#                 daemon and the Colima/qemu VM process explicitly -- see
#                 the equivalent exclusion added to this repo's user-scope
#                 psi-oom-watcher.sh fallback after a live dry-run showed
#                 it would otherwise target the Colima VM's qemu process)
EARLYOOM_ARGS="-m 15 -s 20 -r 60 --avoid '(^|/)(ezgha|qemu-system-x86_64|systemd)$'"
EOF

sudo systemctl enable --now earlyoom
sudo systemctl status earlyoom
```

**If running Option B alongside the already-active systemd-oomd**, be
aware both daemons watch overlapping signals independently — this is not
inherently unsafe (both only ever kill, never corrupt state, and both
target the highest-badness/highest-pressure candidate) but means you
cannot cleanly attribute which one acted from symptoms alone; check
`journalctl -u systemd-oomd -u earlyoom --since <incident-time>` together
when diagnosing after the fact.

---

## Post-install verification (either option)

```bash
# Confirm the daemon is active and watching the right scope:
systemctl status systemd-oomd   # or: systemctl status earlyoom

# Watch live PSI alongside the daemon's own log during a synthetic load
# test (e.g. a deliberate `stress-ng --vm 4 --vm-bytes 90% --timeout 60s`
# on a non-production window) to confirm it intervenes before load
# average approaches the watchdog's max-load-1 threshold:
watch -n1 'cat /proc/pressure/memory; echo ---; uptime'
journalctl -u systemd-oomd -f   # or -u earlyoom -f, in a second pane
```

Only after this verification passes should the separate swapfile-expansion
ops lane (tracked on `ah94`, not this bead) proceed, and only after THAT
should zram even be reconsidered — and per the panel decision, zram stays
forbidden regardless until there is production evidence this layer
actually intervenes correctly under real load, not just a synthetic test.
