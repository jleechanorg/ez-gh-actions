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

## Installing the user-scope pieces (agents.slice + psi-oom-watcher)

Added 2026-07-10 (third adversarial re-verification pass) — the unit
comments for `systemd/psi-oom-watcher.service` referenced "the README note
on this unit pair for install steps," but no such note existed anywhere
in this repo, and `install.sh`'s existing copy loops only sweep
`ezgha-*.service`/`ezgha-*.timer` (this bead's units are deliberately NOT
prefixed `ezgha-`, to keep them out of that auto-enabling loop — see the
comments in `systemd/agents.slice`). Concretely, that meant there was no
documented way to actually install the automatic caller — weakening the
"has an automatic caller" claim, since nothing installed the caller
either. This section is that missing documentation.

**None of the commands below require sudo.** They install unit files and
reload the user systemd manager's config — they do NOT `enable --now`
anything (that activation step is deliberately left for the human
operator to run separately, once ready):

```bash
# From this repo's checkout (adjust the path if running from elsewhere):
REPO_ROOT="$(pwd)"   # or wherever your ez-gh-actions checkout is

# 1. agents.slice -- no placeholders to substitute, copy as-is.
mkdir -p ~/.config/systemd/user
cp "${REPO_ROOT}/systemd/agents.slice" ~/.config/systemd/user/

# 2. psi-oom-watcher.service + .timer -- the .service has @SCRIPTS_DIR@ /
#    @HOME@ placeholders (same convention as the ezgha-* aux units, see
#    install.sh's own substitution step) that must be substituted before
#    systemd will accept the unit. SCRIPTS_DIR here is the same stable
#    libexec path install.sh already uses for the ezgha-* units, so the
#    watcher script needs to be copied there too:
mkdir -p ~/.local/libexec/ezgha
install -m 0755 "${REPO_ROOT}/scripts/host/psi-oom-watcher.sh" ~/.local/libexec/ezgha/
sed -e "s|@SCRIPTS_DIR@|${HOME}/.local/libexec/ezgha|g" \
    -e "s|@HOME@|${HOME}|g" \
    "${REPO_ROOT}/systemd/psi-oom-watcher.service" > ~/.config/systemd/user/psi-oom-watcher.service
cp "${REPO_ROOT}/systemd/psi-oom-watcher.timer" ~/.config/systemd/user/

# 3. Load the new unit definitions (does NOT start/enable anything):
systemctl --user daemon-reload

# 4. Sanity-check what got installed, still without activating anything:
systemctl --user cat agents.slice
systemctl --user cat psi-oom-watcher.service
systemctl --user cat psi-oom-watcher.timer

# 5. ACTIVATION -- deliberately a separate, explicit step. This is where
#    a human operator decides to actually turn the watcher on:
#      systemctl --user enable --now psi-oom-watcher.timer
#    agents.slice does not need (and cannot usefully be) "enabled" --
#    it activates automatically the first time a process is launched into
#    it via scripts/host/agent-cli-scoped.sh (see that script's own
#    comments for usage).
```

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

- **Option A (recommended for the memory-PRESSURE kill path only — see the
  "swap-path scope boundary" finding below for what this does NOT cover):
  tune the existing systemd-oomd via a drop-in.** No new package, no new
  failure surface — just a tighter memory-pressure threshold on
  infrastructure already proven to be wired into the right cgroups, paired
  with a required per-unit `ManagedOOMPreference=omit` exemption for
  `ezgha.service` (step 0 below) that genuinely protects the Colima VM
  from pressure-triggered kills.
  **Option A intentionally does NOT touch systemd-oomd's swap-usage kill
  path at all** (see the finding below for why: the `omit` exemption
  cannot protect a user-owned unit from that specific path, so tightening
  it would have made the exposure worse, not better — this was caught in
  adversarial re-verification of an earlier draft of this doc that did
  tighten it). Swap-triggered protection for the Colima VM is **only**
  available via Option B.
- **Option B: install earlyoom.** The best available protection against
  the swap-usage kill path specifically — earlyoom's victim selection
  isn't a systemd-oomd cgroup xattr, so it isn't subject to the
  root-owned-only restriction on that path (see finding below). **Read
  the "earlyoom `--avoid` scope boundary" finding below before assuming
  this is a hard guarantee — it is a strong soft preference, not an
  exclusion.** earlyoom is NOT currently installed (`apt-cache policy
  earlyoom` shows `Installed: (none)`, `Candidate: 1.7-2`) — this requires
  `apt-get install`, hence sudo, hence this document rather than something
  the agent could do unprivileged.

Do NOT enable zram until whichever option you pick has been observed
actually intervening (or confirmed absent-intervention because pressure
stayed healthy) through at least one full day of normal multi-agent load.

## Finding: the Colima VM lives INSIDE ezgha.service's own cgroup

Checked live on jeff-ubuntu 2026-07-10 (read-only, no changes made) during
adversarial verification of this bead's first draft:

```
$ pgrep -f qemu-system-x86_64
24265
$ cat /proc/24265/cgroup
0::/user.slice/user-1000.slice/user@1000.service/app.slice/ezgha.service
$ systemctl --user status ezgha.service
● ezgha.service - ez-gh-actions ephemeral GitHub Actions runners
     Memory: 33.6G (peak: 36.3G swap: 171.3M)
     CGroup: /user.slice/user-1000.slice/user@1000.service/app.slice/ezgha.service
             ├─ 3766 /home/jleechan/.cargo/bin/ezgha ... serve
             ├─ 4252 limactl usernet ...
             ├─ 22414 limactl hostagent ...
             └─ 24265 /usr/bin/qemu-system-x86_64 -m 49152 ...
```

The Colima VM (qemu process + its limactl helpers) is not in a separate
slice or scope — it's a direct child process tree of the ezgha daemon
itself, so its ~33.6G memory footprint is entirely inside
`ezgha.service`'s own cgroup accounting. This means: **tightening
`DefaultMemoryPressureLimit` on `user.slice`/`user-1000.slice` (step 2
below) makes `ezgha.service` — and therefore the Colima VM inside it — a
live SIGKILL candidate the moment aggregate pressure in that subtree
crosses the new tighter threshold, UNLESS explicitly exempted.** Unlike
this bead's own `psi-oom-watcher.sh` fallback, systemd-oomd has no
cooldown, no grace period, and no exclusion list of its own — it kills
immediately once its candidate-selection logic picks a cgroup.

**The fix is a real, already-committed, already-verified artifact in this
repo**, not just a doc note: `systemd/ezgha.service.d/10-oomd-omit.conf`
sets `ManagedOOMPreference=omit` on `ezgha.service`. Per
`systemd.resource-control(5)`, this extended-attribute-based exemption is
respected for the **memory-pressure** kill path because `ezgha.service`
and the monitored ancestor (`user-1000.slice`) are owned by the same UID
(verified via the delegated `cgroup.controllers` check performed earlier
in this bead). Confirmed via `systemd-analyze verify --user` (paired with
a stub base unit, since a bare drop-in fragment can't be verified
standalone) — parses cleanly. **This step requires NO sudo** (it's a
`~/.config/systemd/user/` override, owned by the invoking user) but DOES
require restarting `ezgha.service` for the omit xattr to attach to its
live cgroup — coordinate with the ezgha deploy-owner per repo CLAUDE.md
single-writer rule; do not restart opportunistically.

## Finding: the omit exemption does NOT cover systemd-oomd's swap-usage kill path (scope boundary)

Found during a second adversarial re-verification pass (2026-07-10) of an
earlier draft of this doc, which originally also tightened
`SwapUsedLimit` and set `ManagedOOMSwap=kill` in Option A. Verified
against `man systemd.resource-control` on this exact host (systemd
255.4-1ubuntu8.16):

> When calculating candidates to relieve **swap usage**, systemd-oomd will
> only respect these extended attributes if the unit's cgroup is **owned
> by root**.
>
> When calculating candidates to relieve **memory pressure**,
> systemd-oomd will only respect these extended attributes if the unit's
> cgroup is owned by root, **or if the unit's cgroup owner, and the owner
> of the monitored ancestor cgroup are the same**.

These are two genuinely different rules. `ezgha.service` is a
`~/.config/systemd/user/` unit running under `user@1000.service` — it is
architecturally UID 1000, never root, for as long as it stays a `--user`
unit. That means:

- **Memory-pressure path: the `ManagedOOMPreference=omit` exemption IS
  respected** (same-owner clause applies — verified above). This is real
  protection, already committed.
- **Swap-usage path: the exemption is NOT respected** (root-owned-only
  clause; no same-owner exception exists for this path). No drop-in this
  repo can write against a `--user` unit closes this gap — it is an
  architectural limitation of running the daemon as a user service, not a
  bug in this fix.

**Consequence for Option A: this doc's earlier draft tightened
`SwapUsedLimit=80%` and set `ManagedOOMSwap=kill` on `user-1000.slice` —
that combination would have exposed the Colima VM to an *unprotected*
swap-triggered SIGKILL, and *sooner* than systemd-oomd's stock defaults
(90%) would have, i.e. actively worse than doing nothing.** This doc has
been corrected: **Option A below only tunes the memory-pressure path** (a
real, protected improvement) and deliberately leaves the swap-usage path
at whatever systemd-oomd's existing stock/current configuration already
is — not tightened, not otherwise touched, so this doc does not newly
introduce or worsen the pre-existing swap-path exposure. The 2026-07-10
incident that motivated this whole bead was specifically a swap-exhaustion
event, so if swap-path protection for the Colima VM matters to you,
**Option A does not provide it — install Option B (earlyoom)** — but read
the next finding before assuming Option B is a hard guarantee either.

## Finding: earlyoom's `--avoid` is a soft preference, not a hard exclusion — and the exact pattern below was previously broken by comm truncation

Found during a third adversarial re-verification pass (2026-07-10). Two
separate, independently-verified problems in an earlier draft of this
doc's Option B config:

**1. The regex pattern would never have matched the Colima VM at all.**
The earlier draft used `--avoid '(^|/)(ezgha|qemu-system-x86_64|systemd)$'`.
Live on this host, the qemu process's kernel `comm` field (what `--avoid`
actually matches against — confirmed via earlyoom's own README: "The
regex is matched against the basename of the process as shown in
`/proc/PID/comm`") is `qemu-system-x86` — the kernel truncates `comm` at
15 bytes, and `qemu-system-x86_64` is 18 bytes, so the trailing `_64` is
silently dropped. The pattern's `$` anchor requires that exact trailing
`_64`, so it could never match the truncated value actually present.
Fixed below: the pattern now uses `qemu-system-x86` (the real, truncated,
observed value) instead of the full untruncated binary name.

**2. `--avoid` is NOT a hard exclusion, and there is no `--ignore` flag in
the actual installable package.** Verified by downloading and inspecting
the real `.deb` this doc's `apt-get install` command installs
(`apt-get download earlyoom` → extracted `earlyoom_1.7-2_amd64.deb`,
read `usr/bin/earlyoom --help`, `usr/share/man/man1/earlyoom.1.gz`, and
`usr/share/doc/earlyoom/README.md.gz` directly — not guessed, not taken
on faith from any other source). The manpage's own wording:
`--avoid REGEX` — *"avoid killing processes matching REGEX (subtracts 300
from oom_score)"*. That is a soft priority adjustment, not an exclusion —
earlyoom's own README explicitly frames `--avoid`/`--prefer` as a pair of
symmetric nudges, not an allow/deny mechanism. **Version 1.7-2 (the exact
apt-cache candidate on this host, confirmed earlier in this doc) has NO
`--ignore` flag, no equivalent hard-exclusion flag, and no `--ignore` in
its `--help` output, man page, or README at all** — the only relevant
flags that exist are `--avoid` and `--prefer` (both soft, both act via
oom_score adjustment: -300 / an unspecified positive bump respectively).
An `-i` flag DOES exist in this version, but it means something entirely
different (per the changelog: "optionally (-i option) ignore any positive
adjustments set in `/proc/*/oom_score_adj`" — a global toggle for whether
earlyoom respects the kernel's own oom_score_adj values, unrelated to
per-process exclusion by name).

**Consequence: even with the truncation fixed below, `--avoid` on its own
is a preference, not a guarantee** — under a severe-enough swap-exhaustion
event, earlyoom could theoretically still select a `--avoid`-listed
process if every other candidate's adjusted score is somehow still higher
(unlikely for a 33GB process, but not impossible by construction). **The
genuinely strong, verified protection is `OOMScoreAdjust=-1000`**, now set
on `ezgha.service` itself in `systemd/ezgha.service.d/10-oomd-omit.conf`
(see that file's own comments for the full explanation) — a kernel-level
per-process value, inherited by the qemu/limactl descendants, respected by
BOTH the raw kernel OOM killer AND earlyoom's default (non-`-i`) victim
selection, confirmed via `man systemd.exec`: *"-1000 (to disable OOM
killing of processes of this unit)"*. This directive requires no sudo (a
`--user` unit override) and was added specifically to close the gap that
`--avoid` alone cannot close. The fixed `--avoid` pattern below is kept as
defense-in-depth on top of it, not as the primary mechanism.

---

## System-scope commands

### Option A — tune systemd-oomd's memory-PRESSURE path only (does not cover the swap-usage path — see finding above)

**SAFETY: this is deliberately split into TWO separate code blocks with an
explicit stop between them.** Copy-pasting a single continuous fence that
spans both "install the exemption" and "tighten the threshold" creates a
real hazard: nothing stops a human from pasting the whole thing at once,
which would tighten systemd-oomd's pressure threshold BEFORE the
exemption is actually live on `ezgha.service`'s cgroup (the omit xattr
only attaches on the unit's NEXT restart, not immediately on
`daemon-reload`) — briefly exposing the Colima VM during exactly the
window this doc exists to close. Run block 1, wait for its `read -p` gate
to confirm the exemption is live, THEN run block 2. Do not run block 2
until block 1's gate is satisfied.

**Block 1 — install the exemption (no sudo) + confirm it's live:**

```bash
# REQUIRED FIRST (no sudo needed): install the per-unit exemption so
# ezgha.service (and the Colima VM living inside its cgroup, see finding
# above) is never a memory-PRESSURE systemd-oomd kill candidate,
# regardless of how tight block 2 below makes the ancestor slice's
# pressure threshold. This does NOT protect against the swap-usage kill
# path (architectural limitation, see finding above) -- that's precisely
# why block 2 deliberately does not touch SwapUsedLimit at all.
mkdir -p ~/.config/systemd/user/ezgha.service.d
cp systemd/ezgha.service.d/10-oomd-omit.conf ~/.config/systemd/user/ezgha.service.d/
systemctl --user daemon-reload

# The omit xattr (and the OOMScoreAdjust value in the same drop-in) only
# attach when the unit's cgroup is (re)created -- i.e. on ezgha.service's
# NEXT restart, not on this daemon-reload. This is a live-daemon restart --
# do not run it as part of this rehearsal; hand off to the deploy-owner
# alongside whatever restart they're already doing for other reasons, or
# schedule one deliberately, per repo CLAUDE.md single-writer rule.
#
# GATE: do not proceed to Block 2 until this restart has happened AND the
# line below confirms it. This blocks accidental copy-paste-everything:
read -p "Press Enter ONLY after confirming 'systemctl --user show -p ManagedOOMPreference ezgha.service' prints ManagedOOMPreference=omit (i.e. ezgha.service has been restarted since this drop-in was installed): "
systemctl --user show -p ManagedOOMPreference,OOMScoreAdjust ezgha.service
# Expected output:
#   ManagedOOMPreference=omit
#   OOMScoreAdjust=-1000
# If it does NOT show these values, ezgha.service has not yet been
# restarted since this drop-in was installed -- STOP, do not run Block 2,
# arrange the restart first.
```

**Block 2 — tighten the threshold (sudo required), only after Block 1's gate is confirmed:**

```bash
# 1. Create a drop-in tightening ONLY the memory-pressure threshold.
#    Numbers chosen to fire meaningfully before the host watchdog's
#    max-load-1 territory (this host's /etc/watchdog.conf currently reads
#    max-load-1=96 as of 2026-07-10 -- confirm the live value with
#    `grep max-load /etc/watchdog.conf` before picking thresholds, since a
#    prior remediation pass may have already changed it from the 24 value
#    referenced in this repo's CLAUDE.md). Tighter than stock 60%/30s:
#    30%/15s sustained pressure is a much earlier signal, well before
#    D-state pileup has a chance to compound.
#    DELIBERATELY NOT SET HERE: SwapUsedLimit. Left at systemd-oomd's
#    existing/stock value -- do not add it. See the "swap-path scope
#    boundary" finding above for why: the omit exemption above cannot
#    protect a `--user` unit like ezgha.service on the swap-usage path
#    (root-owned-only restriction, no same-owner exception), so tightening
#    SwapUsedLimit here would expose the Colima VM to an unprotected,
#    sooner-firing SIGKILL -- worse than not touching it at all.
sudo mkdir -p /etc/systemd/oomd.conf.d
sudo tee /etc/systemd/oomd.conf.d/10-tighter-pressure-threshold.conf > /dev/null <<'EOF'
[OOM]
DefaultMemoryPressureLimit=30%
DefaultMemoryPressureDurationSec=15s
EOF

# 2. Explicitly confirm user.slice stays managed for the PRESSURE path
#    only (it already is via "auto" default, but this makes the intent
#    durable/explicit against future distro default changes).
#    DELIBERATELY NOT SET HERE: ManagedOOMSwap=kill -- same rationale as
#    step 1. Leaving ManagedOOMSwap at its existing "auto" value keeps the
#    swap-usage path at its current (already-existing, not worsened)
#    exposure rather than actively tightening an unprotected kill path.
sudo mkdir -p /etc/systemd/system/user-1000.slice.d
sudo tee /etc/systemd/system/user-1000.slice.d/10-managed-oom-pressure.conf > /dev/null <<'EOF'
[Slice]
ManagedOOMMemoryPressure=kill
ManagedOOMMemoryPressureLimit=30%
EOF

# 3. Apply (order matters: only do this AFTER Block 1's gate confirmed the
#    exemption is already live via an ezgha.service restart).
sudo systemctl daemon-reload
sudo systemctl restart systemd-oomd

# 4. Verify it picked up the new config, AND verify the exemption is
#    actually attached to ezgha.service's live cgroup (the omit xattr):
systemd-analyze cat-config systemd/oomd.conf
systemctl status systemd-oomd
systemctl --user show -p ManagedOOMPreference ezgha.service   # expect: omit
systemctl show -p ManagedOOMSwap user-1000.slice              # expect: auto (untouched, NOT kill)
```

### Option B — install earlyoom (alternative/supplemental)

**Prerequisite (do this first, no sudo needed): install the
`OOMScoreAdjust=-1000` protection** described in the "earlyoom `--avoid`
scope boundary" finding above (same Block 1 as Option A — if you already
ran Option A's Block 1, this is already done; if you're doing Option B
standalone, run Option A's Block 1 first). This is the mechanism that
actually protects Colima under earlyoom's default victim selection — the
`--avoid` regex below is defense-in-depth on top of it, not the primary
protection.

```bash
sudo apt-get update
sudo apt-get install -y earlyoom

# Tune via /etc/default/earlyoom (Debian/Ubuntu packaging convention).
# -m / -s here are PERCENT-FREE thresholds (not PSI directly -- earlyoom's
# core trigger is available-memory + swap-free percentage, tuned here to
# fire earlier than the historical incident's near-100% swap saturation).
sudo tee /etc/default/earlyoom > /dev/null <<'EOF'
# -m <percent>  : trigger when available memory falls below this percent
# -s <percent>  : trigger when available swap falls below this percent
# -r <seconds>  : report memory status at this interval (0 = only on kill)
# --avoid       : SOFT preference only (subtracts 300 from oom_score per
#                 `man earlyoom` on the exact 1.7-2 package this apt-get
#                 installs -- verified by extracting the real .deb, not
#                 guessed). This is NOT a guaranteed exclusion; the real
#                 protection for the Colima VM is the OOMScoreAdjust=-1000
#                 drop-in on ezgha.service (see the "earlyoom --avoid
#                 scope boundary" finding above and the prerequisite note
#                 immediately above this code block) -- this --avoid regex
#                 is defense-in-depth on top of that, not a substitute for
#                 it. Pattern uses "qemu-system-x86" (NOT the untruncated
#                 "qemu-system-x86_64") because earlyoom matches against
#                 the kernel's comm field, which truncates at 15 bytes --
#                 confirmed live on this host: `cat /proc/<qemu-pid>/comm`
#                 returns "qemu-system-x86", dropping the trailing "_64".
EARLYOOM_ARGS="-m 15 -s 20 -r 60 --avoid '(^|/)(ezgha|qemu-system-x86|systemd)$'"
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
