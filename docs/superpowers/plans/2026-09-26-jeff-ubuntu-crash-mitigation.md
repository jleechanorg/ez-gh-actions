# Jeff-Ubuntu Crash Mitigation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Install crash-capture logging, the favored-core cap, a vmcore triage script, and a scheduled soak on Jeff-Ubuntu, then run maintenance window W and the S1 soak defined in `docs/superpowers/specs/2026-09-26-jeff-ubuntu-crash-mitigation-design.md` (the "spec").

**Architecture:** All host artifacts are git-tracked in `~/projects_other/user_scope` (spec E19/E20): a sysctl drop-in, a modprobe file, a systemd system unit plus script for the cap, a MacBook launchd receiver template, a user timer for `soakctl watch`, and a `crash` batch triage script. Root-phase installation is one script that a human runs with sudo; every asserter is read-only and prints `PASS`/`FAIL` tokens the spec's criteria consume.

**Tech Stack:** bash, systemd (system + user), sysctl, netconsole/netpoll, launchd (MacBook), `crash` 8.0.4 + Ubuntu dbgsym, `soakctl`, pytest (user_scope test convention).

**Preconditions (spec § 11):** P1 sudo for Tasks 7–9; P2 human present for W1/W3; P3 `eno2` adjacency (Task 4, under sudo in W0); P5 dbgsym with matching Build ID (Task 6, no root) is a hard gate before W3; P6 operator exception for the lockup/panic sysctls and the SysRq proof.

**Bead discipline:** commit prefix `claude/claude-fable-5-1:`; commit + push only; the deploy steps (Tasks 7–9) are run by the deploy-owner with the human, never by a dispatched sub-agent (ez-gh-actions CLAUDE.md single-writer rule applies to host mutation too).

---

## Task 1: Sysctl drop-in + assert script (user_scope)

**Files:**
- Create: `config/sysctl.d/90-jeff-ubuntu-crash-capture.conf`
- Create: `scripts/assert-crash-capture.sh`
- Test: `tests/test_crash_capture_artifacts.py`

**Step 1: Write the failing test**

```python
# tests/test_crash_capture_artifacts.py
import pathlib, re, subprocess
ROOT = pathlib.Path(__file__).resolve().parents[1]

EXPECTED = {
    "kernel.panic_on_oops": "1",
    "kernel.softlockup_panic": "1",
    "kernel.hardlockup_panic": "1",
    "kernel.panic": "10",
    "kernel.hung_task_panic": "0",
}

def _parse(path):
    out = {}
    for line in path.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if "=" in line:
            k, v = (s.strip() for s in line.split("=", 1))
            out[k] = v
    return out

def test_sysctl_file_sets_exactly_the_capture_keys():
    got = _parse(ROOT / "config/sysctl.d/90-jeff-ubuntu-crash-capture.conf")
    assert got == EXPECTED

def test_assert_script_is_readonly_and_tokenized():
    src = (ROOT / "scripts/assert-crash-capture.sh").read_text()
    assert "sysctl -w" not in src and "/proc/sys" not in src
    assert re.search(r'echo "PASS C1"', src) and "FAIL C1" in src

def test_assert_script_bash_syntax():
    subprocess.run(["bash", "-n", str(ROOT / "scripts/assert-crash-capture.sh")], check=True)
```

**Step 2: Run test to verify it fails**

Run: `cd ~/projects_other/user_scope && python3 -m pytest tests/test_crash_capture_artifacts.py -q`
Expected: FAIL with `FileNotFoundError`.

**Step 3: Write the artifacts**

```
# config/sysctl.d/90-jeff-ubuntu-crash-capture.conf
# Jeff-Ubuntu crash capture (bd-dea.10, spec D2/D3). kdump-config already forces
# panic_on_oops=1; stated here so a kdump-tools change cannot silently flip it.
kernel.panic_on_oops = 1
kernel.softlockup_panic = 1
kernel.hardlockup_panic = 1
kernel.panic = 10
kernel.hung_task_panic = 0
```

```bash
#!/usr/bin/env bash
# scripts/assert-crash-capture.sh — read-only check of spec criteria C1/C2.
set -euo pipefail
f=/etc/sysctl.d/90-jeff-ubuntu-crash-capture.conf
[ -f "$f" ] || { echo "FAIL C1-file $f missing"; exit 1; }
for kv in panic_on_oops:1 softlockup_panic:1 hardlockup_panic:1 panic:10 hung_task_panic:0; do
  k=${kv%%:*}; want=${kv##*:}; got=$(sysctl -n "kernel.$k")
  [ "$got" = "$want" ] || { echo "FAIL C1 kernel.$k=$got want $want"; exit 1; }
done
echo "PASS C1"
[ "$(cat /sys/kernel/kexec_crash_loaded)" = 1 ] && echo "PASS C2" || { echo "FAIL C2 kexec_crash_loaded=0"; exit 1; }
```

**Step 4: Run test to verify it passes**

Run: `python3 -m pytest tests/test_crash_capture_artifacts.py -q` → `3 passed`.

**Step 5: Commit**

```bash
git add config/sysctl.d/90-jeff-ubuntu-crash-capture.conf scripts/assert-crash-capture.sh tests/test_crash_capture_artifacts.py
git commit -m "claude/claude-fable-5-1: add Jeff-Ubuntu crash-capture sysctl drop-in and asserter (bd-dea.10)"
```

---

## Task 2: Favored-core cap script + system unit

**Files:**
- Create: `scripts/favored-core-cap.sh`
- Create: `systemd/favored-core-cap.service`
- Modify: `tests/test_crash_capture_artifacts.py` (append)

**Step 1: Append failing tests**

```python
def test_favored_core_cap_script_modes(tmp_path):
    # Simulate sysfs so the script is testable without root.
    for c in range(4):
        d = tmp_path / f"cpu{c}/cpufreq"; d.mkdir(parents=True)
        (d / "cpuinfo_max_freq").write_text("5800000\n")
        (d / "scaling_max_freq").write_text("5800000\n")
    env = {"FAVORED_CORE_SYSFS": str(tmp_path), "PATH": "/usr/bin:/bin"}
    s = str(ROOT / "scripts/favored-core-cap.sh")
    r = subprocess.run([s, "assert"], env=env, capture_output=True, text=True)
    assert r.returncode == 1 and "FAIL S1-cap" in r.stdout
    subprocess.run([s, "apply"], env=env, check=True)
    assert (tmp_path / "cpu3/cpufreq/scaling_max_freq").read_text().strip() == "5500000"
    r = subprocess.run([s, "assert"], env=env, capture_output=True, text=True)
    assert r.returncode == 0 and r.stdout.startswith("PASS S1-cap")
    subprocess.run([s, "revert"], env=env, check=True)
    assert (tmp_path / "cpu0/cpufreq/scaling_max_freq").read_text().strip() == "5800000"

def test_favored_core_unit_is_oneshot_with_revert():
    u = (ROOT / "systemd/favored-core-cap.service").read_text()
    assert "Type=oneshot" in u and "RemainAfterExit=yes" in u
    assert "ExecStart=/usr/local/libexec/favored-core-cap.sh apply" in u
    assert "ExecStop=/usr/local/libexec/favored-core-cap.sh revert" in u
```

**Step 2: Run** → FAIL (script missing).

**Step 3: Write**

```bash
#!/usr/bin/env bash
# scripts/favored-core-cap.sh — cap the two TVB favored cores (cpu0-3) to the
# common P-core bin. Experiment S1 of bd-dea.10. Modes: apply | revert | assert.
set -euo pipefail
SYSFS="${FAVORED_CORE_SYSFS:-/sys/devices/system/cpu}"
CAP_KHZ="${FAVORED_CORE_CAP_KHZ:-5500000}"
CPUS="${FAVORED_CORE_CPUS:-0 1 2 3}"
mode="${1:-assert}"
for c in $CPUS; do
  f="$SYSFS/cpu$c/cpufreq"
  case "$mode" in
    apply)  echo "$CAP_KHZ" > "$f/scaling_max_freq" ;;
    revert) cat "$f/cpuinfo_max_freq" > "$f/scaling_max_freq" ;;
    assert) got=$(cat "$f/scaling_max_freq")
            [ "$got" = "$CAP_KHZ" ] || { echo "FAIL S1-cap cpu$c scaling_max_freq=$got want $CAP_KHZ"; exit 1; } ;;
    *) echo "usage: $0 apply|revert|assert" >&2; exit 2 ;;
  esac
done
[ "$mode" = assert ] && echo "PASS S1-cap cpus=[$CPUS] khz=$CAP_KHZ"
exit 0
```

```ini
# systemd/favored-core-cap.service
[Unit]
Description=Cap TVB favored cores cpu0-3 to 5.5 GHz (bd-dea.10 experiment S1)
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/libexec/favored-core-cap.sh apply
ExecStop=/usr/local/libexec/favored-core-cap.sh revert

[Install]
WantedBy=multi-user.target
```

**Step 4: Run** `python3 -m pytest tests/test_crash_capture_artifacts.py -q` → `5 passed`.

**Step 5: Commit** `claude/claude-fable-5-1: add favored-core cap script and unit (bd-dea.10 S1)`.

---

## Task 3: netconsole unit + MacBook receiver

**Files:**
- Create: `scripts/netconsole-eno2.sh`
- Create: `systemd/netconsole-eno2.service`
- Create: `config/netconsole/com.jleechan.netconsole-receiver.plist.template`
- Create: `scripts/netconsole-receiver.sh` (MacBook side)
- Modify: `tests/test_crash_capture_artifacts.py` (append)

Design (spec D2.4, revised twice): no NetworkManager connection on `eno2`; the unit adds a `/32` host address (the kernel documents `src-ip` as an interface address) and sets the link up; the target MAC defaults to broadcast with an explicit `NETCONSOLE_TGT_MAC` override for switches that suppress broadcast; the module is loaded by a unit ordered after the `eno2` device, never by `modules-load.d`.

**Step 1: Append failing tests**

```python
def test_netconsole_script_has_no_mac_and_no_nm():
    src = (ROOT / "scripts/netconsole-eno2.sh").read_text()
    assert "netconsole=+6666@" in src and "/eno2,6666@192.168.254.199/" in src
    assert not re.search(r"[0-9a-f]{2}(:[0-9a-f]{2}){5}", src)   # no hardcoded MAC
    assert "nmcli" not in src and "ip link set" in src and "ip addr replace" in src and "/32" in src
    subprocess.run(["bash", "-n", str(ROOT / "scripts/netconsole-eno2.sh")], check=True)

def test_netconsole_unit_orders_after_device():
    u = (ROOT / "systemd/netconsole-eno2.service").read_text()
    assert "After=sys-subsystem-net-devices-eno2.device" in u
    assert "BindsTo=sys-subsystem-net-devices-eno2.device" in u
    assert "ExecStart=/usr/local/libexec/netconsole-eno2.sh" in u

def test_netconsole_receiver_template_uses_home_placeholder():
    t = (ROOT / "config/netconsole/com.jleechan.netconsole-receiver.plist.template").read_text()
    assert "@HOME@" in t and "KeepAlive" in t and "6666" in t
```

**Step 2: Run** → FAIL.

**Step 3: Write**

```bash
#!/usr/bin/env bash
# scripts/netconsole-eno2.sh — load netconsole on the idle wired NIC (bd-dea.10 D2.4).
# Source address is synthetic (netpoll does not use the routing table); target MAC
# omitted => Ethernet broadcast, so a rotating MacBook MAC cannot break delivery.
set -euo pipefail
DEV="${NETCONSOLE_DEV:-eno2}"
SRC="${NETCONSOLE_SRC_IP:-192.168.254.130}"
TGT="${NETCONSOLE_TGT_IP:-192.168.254.199}"
TGT_MAC="${NETCONSOLE_TGT_MAC:-}"        # empty => Ethernet broadcast (switches may suppress; T4 proves)
ip link set "$DEV" up
ip addr replace "${SRC}/32" dev "$DEV"   # kernel docs: src-ip must be an interface address; /32 adds no subnet route
modprobe netconsole "netconsole=+6666@${SRC}/${DEV},6666@${TGT}/${TGT_MAC}"
echo "netconsole-eno2: loaded $(date +%s)" > /dev/kmsg
```

```ini
# systemd/netconsole-eno2.service
[Unit]
Description=netconsole over eno2 to the MacBook receiver (bd-dea.10 D2.4)
BindsTo=sys-subsystem-net-devices-eno2.device
After=sys-subsystem-net-devices-eno2.device

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/libexec/netconsole-eno2.sh
ExecStop=/sbin/modprobe -r netconsole

[Install]
WantedBy=multi-user.target
```

```bash
#!/usr/bin/env bash
# scripts/netconsole-receiver.sh — MacBook UDP sink for Jeff-Ubuntu netconsole.
set -euo pipefail
LOG="${NETCONSOLE_LOG:-$HOME/Library/Logs/netconsole-jeff-ubuntu.log}"
mkdir -p "$(dirname "$LOG")"
exec nc -ukl 6666 >> "$LOG"
```

```xml
<!-- config/netconsole/com.jleechan.netconsole-receiver.plist.template -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.jleechan.netconsole-receiver</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>@HOME@/.local/libexec/netconsole-receiver.sh</string>
  </array>
  <key>EnvironmentVariables</key><dict><key>NETCONSOLE_LOG</key><string>@HOME@/Library/Logs/netconsole-jeff-ubuntu.log</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>@HOME@/Library/Logs/netconsole-receiver.stderr.log</string>
</dict></plist>
```

**Step 4: Run tests** → `8 passed`.

**Step 5: Commit** `claude/claude-fable-5-1: add netconsole-eno2 unit and MacBook receiver template (bd-dea.10 D2.4)`.

---

## Task 4: eno2 adjacency probe (W0b, root) — decides whether netconsole ships

**Step 1:** In window W0, as root: `ip link set eno2 up && ip addr replace 192.168.254.130/32 dev eno2 && arping -c 3 -I eno2 192.168.254.199`. A reply proves L2 adjacency. Also confirm `192.168.254.130` is unused from the Wi-Fi side beforehand: `ping -c 1 -W 1 192.168.254.130` must fail (run before adding the address).

**Step 2:** Load the unit (Task 7) and probe delivery both ways: first with broadcast (default), then, if the MacBook log shows nothing within 5 s of `echo probe > /dev/kmsg`, with `NETCONSOLE_TGT_MAC=<current MacBook en0 MAC>` in the unit's environment. Record in bd-dea.10: `netconsole: OK (broadcast|mac)` or `netconsole: UNAVAILABLE (<reason>)`. If UNAVAILABLE, criterion C7 is recorded as `FAIL C7 unavailable-<reason>` and D2.4 is dropped; nothing else blocks.

---

## Task 5: `soak-watch` user timer

**Files:**
- Create: `systemd/user/soak-watch.service`, `systemd/user/soak-watch.timer`
- Modify: `tests/test_crash_capture_artifacts.py` (append)

**Step 1: Test**

```python
def test_soak_watch_timer_every_5_min():
    t = (ROOT / "systemd/user/soak-watch.timer").read_text()
    s = (ROOT / "systemd/user/soak-watch.service").read_text()
    assert "OnUnitActiveSec=5min" in t and "WantedBy=timers.target" in t
    assert "ExecStart=%h/.local/bin/soakctl watch" in s
```

**Step 2:** FAIL. **Step 3: Write**

```ini
# systemd/user/soak-watch.service
[Unit]
Description=soakctl watch (updates soak beads, records crash-as-data)
[Service]
Type=oneshot
ExecStart=%h/.local/bin/soakctl watch
```

```ini
# systemd/user/soak-watch.timer
[Unit]
Description=Run soakctl watch every 5 minutes
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
```

**Step 4:** `8 passed`. Install (no root): `install -m 0644 systemd/user/soak-watch.* ~/.config/systemd/user/ && systemctl --user daemon-reload && systemctl --user enable --now soak-watch.timer`. Verify: `systemctl --user list-timers | grep soak-watch`. Also close the stale soak: `soakctl close cfs-cgroupdisable-16runners-20260703 --reason "superseded by bd-dea.10 S1"`.

**Step 5: Commit** `claude/claude-fable-5-1: schedule soakctl watch as a user timer (bd-dea.10 D4)`.

---

## Task 6: vmcore triage script + dbgsym fetch (no root)

**Files:**
- Create: `scripts/vmcore-triage.sh`
- Modify: `tests/test_crash_capture_artifacts.py` (append)

**Step 1: Test**

```python
def test_vmcore_triage_emits_evidence_blocks_and_never_decides_alone():
    src = (ROOT / "scripts/vmcore-triage.sh").read_text()
    assert "VERDICT: INCONCLUSIVE reason=human-review-required" in src
    assert "sysrq-induced" in src
    assert "bt -r" in src and "dis -r" in src
    for cls in ("CONTROL-FLOW-MISMATCH", "BAD-TARGET-CONSUMED", "UAF-SUPPORTED"):
        assert f"VERDICT: {cls}" not in src   # the script never classifies; humans do (spec § 5)
    subprocess.run(["bash", "-n", str(ROOT / "scripts/vmcore-triage.sh")], check=True)
    r = subprocess.run([str(ROOT / "scripts/vmcore-triage.sh"), "/nonexistent"], capture_output=True, text=True)
    assert r.returncode != 0 and "VERDICT: INCONCLUSIVE" in r.stdout
```

**Step 2:** FAIL. **Step 3: Write**

```bash
#!/usr/bin/env bash
# scripts/vmcore-triage.sh <dump.<ts>> [vmlinux]
# Prints the spec § 5 evidence blocks from `crash` and ends with an INCONCLUSIVE
# line; a human applies the § 5 table and a second reviewer concurs (C12).
set -uo pipefail
dump="${1:-}"; kver="$(uname -r)"
vmlinux="${2:-$HOME/.local/share/vmlinux/vmlinux-$kver}"
out="${TRIAGE_OUT:-$HOME/.local/state/vmcore-triage}"; mkdir -p "$out"
rep="$out/triage-$(date +%Y%m%dT%H%M%S).txt"
[ -r "$dump" ] || { echo "VERDICT: INCONCLUSIVE reason=dump-unreadable $dump"; exit 1; }
[ -r "$vmlinux" ] || { echo "VERDICT: INCONCLUSIVE reason=vmlinux-missing $vmlinux (Task 6 step 4)"; exit 1; }
crash -s "$vmlinux" "$dump" > "$rep" 2>&1 <<'EOF'
sys
log | tail -120
bt
bt -f
bt -r
kmem -s | grep -E "cfs_rq|task_group|cgroup|psi|kmalloc-(64|96|128|192|256|512)"
ps -A | head -40
runq
quit
EOF
grep -q "PANIC:" "$rep" || { echo "VERDICT: INCONCLUSIVE reason=crash-could-not-load report=$rep"; exit 1; }
if grep -q "sysrq_handle_crash" "$rep"; then
  echo "VERDICT: INCONCLUSIVE reason=sysrq-induced (capture proof, not a real crash) report=$rep"; exit 0
fi
# Frame #1's return address is the instruction after the call that jumped to the bad RIP.
ret=$(grep -m1 -E "^ *#1 " "$rep" | grep -oE "\[ffffffff[0-9a-f]+\]" | tr -d '[]' | head -1)
rip=$(grep -m1 -oE "RIP: [0-9a-f]{4}:[0-9a-f]+" "$rep" | awk -F: '{print $3}')
fault=$(grep -m1 -oE "address: (0x)?[0-9a-f]+" "$rep" | awk '{print $2}')
{
  echo "### call-site disassembly (last line is the transfer instruction), ret=$ret rip=$rip fault=$fault"
  crash -s "$vmlinux" "$dump" 2>&1 <<EOF
dis -r $ret
kmem $rip
kmem $fault
quit
EOF
} >> "$rep"
echo "evidence: $rep"
echo "apply spec § 5: compare RIP=$rip with the register/immediate that supplied the transfer target (see 'bt -r' and the dis -r block); for memory-sourced operands run: crash -s $vmlinux $dump  then  rd -x <addr> 1"
echo "VERDICT: INCONCLUSIVE reason=human-review-required report=$rep"
exit 0
```

**Step 4:** tests pass. Fetch the dbgsym without root and verify the Build ID (hard gate W0a):

```bash
mkdir -p ~/.local/share/vmlinux && cd /tmp
# Preferred: Launchpad's tool resolves the exact ddeb name for the running ABI (ubuntu-dev-tools, no root):
pull-lp-ddebs linux-image-6.17.0-29-generic 6.17.0-29.29~24.04.1 2>/dev/null || pull-lp-ddebs linux-image-unsigned-6.17.0-29-generic 6.17.0-29.29~24.04.1
# Fallback: list the pool and pick whichever of the two names exists:
curl -fsSL "http://ddebs.ubuntu.com/pool/main/l/linux-hwe-6.17/" | grep -oE 'linux-image-(unsigned-)?6\.17\.0-29-generic-dbgsym_[^"]+_amd64\.ddeb' | sort -u
dpkg -x linux-image-*6.17.0-29-generic-dbgsym_*.ddeb /tmp/dbg && cp /tmp/dbg/usr/lib/debug/boot/vmlinux-6.17.0-29-generic ~/.local/share/vmlinux/
# Build-ID match against the running kernel:
readelf -n ~/.local/share/vmlinux/vmlinux-6.17.0-29-generic | grep -o "Build ID: [0-9a-f]*"
python3 - <<'PY'
import struct; d=open('/sys/kernel/notes','rb').read(); o=0
while o+12<=len(d):
    n,s,t=struct.unpack('<III',d[o:o+12]); name=d[o+12:o+12+n].rstrip(b'\0'); desc=d[o+12+((n+3)&~3):o+12+((n+3)&~3)+s]
    if name==b'GNU' and t==3: print('running Build ID:',desc.hex())
    o+=12+((n+3)&~3)+((s+3)&~3)
PY
```
Expected: the two Build IDs are identical; otherwise P5 is unmet and W3 must not run.

**Step 5: Commit** `claude/claude-fable-5-1: add vmcore triage evidence script for bd-dea.10 § 5`.

---

## Task 7: Root-phase installer (human runs with sudo) — spec W2

Precondition P6: the operator has approved the § 8 exception in a live message; otherwise run with `--no-panic-sysctls`, which skips the sysctl file.

**Files:**
- Create: `scripts/install-crash-capture.sh`
- Modify: `tests/test_crash_capture_artifacts.py` (append: `bash -n` + assert it never calls `reboot`/`shutdown`/`sysrq-trigger`)

```bash
#!/usr/bin/env bash
# scripts/install-crash-capture.sh — root phase for bd-dea.10 D1/D2 artifacts.
# OPERATOR-ONLY: sudo bash scripts/install-crash-capture.sh [--with-netconsole] [--no-panic-sysctls]
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 2; }
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
with_nc=0; no_sysctl=0
for a in "$@"; do case "$a" in --with-netconsole) with_nc=1;; --no-panic-sysctls) no_sysctl=1;; esac; done
if [ "$no_sysctl" = 0 ]; then
  install -m 0644 "$R/config/sysctl.d/90-jeff-ubuntu-crash-capture.conf" /etc/sysctl.d/
  sysctl --system >/dev/null
fi
install -m 0755 "$R/scripts/favored-core-cap.sh" /usr/local/libexec/favored-core-cap.sh
install -m 0644 "$R/systemd/favored-core-cap.service" /etc/systemd/system/
if [ "$with_nc" = 1 ]; then
  install -m 0755 "$R/scripts/netconsole-eno2.sh" /usr/local/libexec/netconsole-eno2.sh
  install -m 0644 "$R/systemd/netconsole-eno2.service" /etc/systemd/system/
fi
systemctl daemon-reload
[ "$with_nc" = 1 ] && systemctl enable --now netconsole-eno2.service
echo "installed; favored-core-cap.service is NOT enabled yet (W4 does that after the SysRq-c proof)"
```

Run order inside window W (spec § D4): W2 `sudo bash scripts/install-crash-capture.sh --with-netconsole --no-panic-sysctls` (drop `--with-netconsole` if Task 4 said UNAVAILABLE) → C7 probe → W3 SysRq proof → W4 `sudo bash scripts/install-crash-capture.sh` (adds the sysctl file) → `bash scripts/assert-crash-capture.sh`. MacBook side: `scp scripts/netconsole-receiver.sh macbook:~/.local/libexec/` and install the plist per `~/.claude/skills/launchd-plist-template/SKILL.md` (substitute `@HOME@`, `launchctl bootstrap gui/$(id -u) …`).

**Commit** `claude/claude-fable-5-1: add root-phase crash-capture installer (bd-dea.10 W2)`.

---

## Task 8: Maintenance window W0–W4 (human + deploy-owner; not scriptable by design)

Order is a gate ladder; do not skip forward.

0. **W0 gates:** (a) Task 6 step 4 Build-ID match printed; (b) Task 4 result recorded; (c) OPERATOR-ONLY: edit `/etc/default/grub.d/kdump-tools.cfg` so the crashkernel words read `crashkernel=1536M,high crashkernel=128M,low`, run `update-grub`, keep the `.bak-<date>` copy the earlier fixes left.
1. **W1 memtest:** drain (`systemctl --user stop ezgha.service`; container count 0); `bash scripts/queue_memtest.sh` (existing) → reboot into Memtest86+ → ≥ 4 passes → photo → comment on bd-memtest501.
2. **W1b BIOS:** set the CPU power limits to Intel Default Settings (PL1 = 125 W; leave PL2 = 253 W and TVB); photograph the screen; after boot `cat /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw` must print 125000000 → C11.
3. **W2:** verify `kexec_crash_loaded=1` and `kexec_crash_size ≥ 1610612736`; run Task 7 with `--no-panic-sysctls`; C7 probe.
4. **W3 SysRq-c proof** (requires P6; still drained; human watching). OPERATOR-ONLY, typed by the human, never scripted: as root enable SysRq and write the character `c` to the SysRq trigger file under `/proc`. Expect: crash kernel boots, `kdump-tools-dump.service` writes `/var/crash/<ts>/dump.<ts>`, host returns on its own. After return: C2, C3, C4, then `scripts/vmcore-triage.sh /var/crash/<ts>/dump.<ts>` → `VERDICT: INCONCLUSIVE reason=sysrq-induced`, and the report loads in `crash` without a "do not match" error → C10. If no dump or `crash` rejects it: fix the named gap (reservation, dbgsym), reboot, repeat once; record the outcome in bd-dea.10.
5. **W4:** run Task 7 again without `--no-panic-sysctls` → C1; `sudo systemctl enable --now favored-core-cap.service && /usr/local/libexec/favored-core-cap.sh assert` → C5; `sudo cat /sys/kernel/debug/sched/itmt_enabled` → C6.

---

## Task 9: W5 — start the fleet and the soak

```bash
systemctl --user start ezgha.service
sleep 120 && ./doctor-runner                     # C9: 10 slots, none DOWN / IDLE-STARVED
soakctl start "favcore-cap-5500-10runners-$(date +%Y%m%d)" --target 200 --bead bd-dea.10 \
  --config "6.17.0-29 nohz=off; cpu0-3 scaling_max 5.5GHz; 10 ephemeral runners; softlockup/hardlockup panic=1; kernel.panic=10; kdump armed 640MiB; netconsole->macbook"
soakctl status                                   # C8 (timer from Task 5 must be active)
```

Record the start in bd-dea.10 and in `~/roadmap/jeff-ubuntu/design-2026-09-26-crash-mitigation.md` § Status.

---

## Task 10: After a crash or at 200 h / 400 h — decision execution

- **Crash:** within 24 h run Task 6's script on the newest dump, apply spec § 5 steps 1–2 to the report (reconstruct the transfer from the `dis -r` block; compare `RIP` with the `pt_regs` register or re-read immediate/trampoline; for UAF-SUPPORTED, demonstrate the lifetime violation with `kmem`, list walks, and the pre-crash teardown log), and post `S1 CLASS <CONTROL-FLOW-MISMATCH|BAD-TARGET-CONSUMED|UAF-SUPPORTED> <n>` or `S1 INCONCLUSIVE <gap>` with the report path to bd-dea.10. Ask Codex to re-read the same report and add a concurring or dissenting `br` comment (C12). Only spec § 5 step 3 (two dumps, or one plus corroboration) opens an S2 bead; a single class never does. The soak clock records elapsed as data.
- **200 h clean:** `soakctl` target is extended by closing and restarting with `--target 400` and the same config string, noting "extension of <name>" in the reason.
- **400 h clean:** post `S1 CLEAN 400h`, open the S3 reverse-test bead (revert the cap only, PL1 stays at Intel default, soak 200 h), and the S2c bead (TVB off, diagnostic tool, RMA path).

---

## Task 11: Bookkeeping

- user_scope: `br --db .beads/beads.db comments add bd-dea.10 "<design paths, W schedule, precondition status>"`; close bd-postreboot28 into S2a; note bd-py7 blocked on the S1 verdict; note bd-microcode ranked below S2c (spec § 6).
- roadmap: update `~/roadmap/jeff-ubuntu/design-2026-09-26-crash-mitigation.md` § Status after each task; append to `~/roadmap/nextsteps-2026-08-01-jeff-ubuntu-crash.md` when W runs.
- ez-gh-actions: `bash tests/forbid_host_reboot_primitives_test.sh` must still print `PASS` (C13) — this repo only carries the two design documents.
