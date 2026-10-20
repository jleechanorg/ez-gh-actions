#!/usr/bin/env bash
# Arm B: is 9p host page cache charged to lima-vm@colima.service?
# Observe-only. No lima stop, no drop_caches, no fleet drain.
set -euo pipefail
PROBE="${HOME}/.cache/ezgha-9p-probe.bin"
SIZE_MIB="${NINEP_PROBE_MIB:-1024}"
fail() { echo "FAIL: $*" >&2; exit 1; }

python3 - "$PROBE" "$SIZE_MIB" <<'PY'
import os, sys, time, subprocess, pathlib

probe = pathlib.Path(sys.argv[1])
size_mib = int(sys.argv[2])
base = "/sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/app.slice"

def lima_dir():
    for name in os.listdir(base):
        if name.startswith("app-lima") and name.endswith(".slice"):
            return os.path.join(base, name, "lima-vm@colima.service")
    raise SystemExit("FAIL: no lima-vm cgroup")

def stat_file(d):
    vals = {}
    for line in open(os.path.join(d, "memory.stat"), encoding="utf-8"):
        k, v = line.split()
        if k in ("file", "anon", "inactive_file"):
            vals[k] = int(v)
    vals["current"] = int(open(os.path.join(d, "memory.current")).read())
    return vals

def host_cached():
    for line in open("/proc/meminfo", encoding="utf-8"):
        if line.startswith("Cached:"):
            return int(line.split()[1]) * 1024
    raise SystemExit("FAIL: no Cached in meminfo")

cg = lima_dir()
before = stat_file(cg)
host_before = host_cached()
print(f"before lima file={before['file']} anon={before['anon']} current={before['current']} host_cached={host_before}")

probe.parent.mkdir(parents=True, exist_ok=True)
if probe.exists():
    probe.unlink()
# Unique file so the first guest read is a cache miss. fallocate: metadata only
# until the guest/9p server faults pages in.
os.posix_fallocate(os.open(probe, os.O_CREAT | os.O_RDWR, 0o600), 0, size_mib * 1024 * 1024)

# Guest path: Colima 9p of host $HOME is typically the same path inside.
guest_path = str(probe)
cmd = ["limactl", "shell", "colima", "--", "dd", f"if={guest_path}", "of=/dev/null", "bs=1M", f"count={size_mib}", "status=none"]
t0 = time.time()
try:
    subprocess.run(cmd, check=True, timeout=180)
except FileNotFoundError:
    print("FAIL: limactl not found", file=sys.stderr)
    sys.exit(1)
except subprocess.CalledProcessError as e:
    print(f"FAIL: guest dd failed ({e}). 9p home may not be at {guest_path}", file=sys.stderr)
    sys.exit(1)
elapsed = time.time() - t0
after = stat_file(cg)
host_after = host_cached()
probe.unlink(missing_ok=True)

df = after["file"] - before["file"]
da = after["anon"] - before["anon"]
dh = host_after - host_before
expect = size_mib * 1024 * 1024
print(f"after  lima file={after['file']} anon={after['anon']} current={after['current']} host_cached={host_after}")
print(f"delta  lima_file={df} lima_anon={da} host_cached={dh} probe_bytes={expect} elapsed_s={elapsed:.1f}")

# Charged-inside-cgroup: lima file rise is at least half the probe (cache
# accounting is not 1:1). Bypass: host Cached rises a lot while lima file does not.
if df >= expect * 0.5:
    print("PASS: 9p read charged inside lima-vm cgroup (file delta >= 50% of probe)")
    sys.exit(0)
if dh >= expect * 0.5 and df < expect * 0.2:
    print("FAIL: 9p host cache bypass (host Cached rose, lima file did not)", file=sys.stderr)
    sys.exit(1)
print("INCONCLUSIVE: deltas too mixed for a binary cgroup-charge claim", file=sys.stderr)
sys.exit(3)
PY
