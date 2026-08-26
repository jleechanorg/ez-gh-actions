#!/usr/bin/env bash
# Patch live /etc/watchdog.conf so repair cannot vote for a host reboot.
# Requires sudo -n (passwordless). Does not replace the whole file.
#
# Blast radius: only repair-maximum and repair-timeout. max-load-* unchanged
# (live 96/72/48). After a successful shed, watchdog(8) must not reboot because
# load is still high (Jeff-Ubuntu 2026-08-25 17:34).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SRC="${REPO_ROOT}/config/watchdog.conf"
fail() { echo "FAIL: $*" >&2; exit 1; }
need_sudo() { echo "NEED_SUDO: $*" >&2; exit 2; }

[ -f "$SRC" ] || fail "missing $SRC"
grep -qE '^repair-maximum = 0$' "$SRC" || fail "$SRC missing repair-maximum = 0"
grep -qE '^repair-timeout = 60$' "$SRC" || fail "$SRC missing repair-timeout = 60"

if [ "${APPLY_WATCHDOG_DRY_RUN:-0}" = "1" ]; then
  echo "DRY_RUN: would set /etc/watchdog.conf repair-maximum=0 repair-timeout=60 then SIGHUP watchdog"
  exit 0
fi

sudo -n true 2>/dev/null || need_sudo "sudo -n is required to patch /etc/watchdog.conf (repair-maximum=0)"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
# Start from live /etc so unrelated keys stay. Fall back to tracked copy.
if [ -r /etc/watchdog.conf ]; then
  cp /etc/watchdog.conf "$tmp"
else
  cp "$SRC" "$tmp"
fi

python3 - "$tmp" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text()
lines = text.splitlines(keepends=True)

def upsert(key, value):
    global lines
    out = []
    found = False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("#"):
            # Uncomment a matching key if we are replacing the live commented default.
            body = stripped.lstrip("#").strip()
            if body.startswith(key) and "=" in body:
                out.append(f"{key} = {value}\n")
                found = True
                continue
            out.append(line)
            continue
        if stripped.startswith(key) and "=" in stripped:
            out.append(f"{key} = {value}\n")
            found = True
            continue
        out.append(line)
    if not found:
        if out and not out[-1].endswith("\n"):
            out[-1] += "\n"
        out.append(f"{key} = {value}\n")
    lines = out

upsert("repair-maximum", "0")
upsert("repair-timeout", "60")
p.write_text("".join(lines))
PY

sudo -n cp "$tmp" /etc/watchdog.conf
sudo -n chmod 644 /etc/watchdog.conf
# Reload without restarting the watchdog daemon's device ping if possible.
if sudo -n killall -HUP watchdog 2>/dev/null; then
  echo "SIGHUP watchdog"
else
  sudo -n systemctl reload watchdog 2>/dev/null \
    || sudo -n systemctl restart watchdog 2>/dev/null \
    || echo "WARN: patched /etc/watchdog.conf but could not signal watchdog" >&2
fi

export ASSERT_LIVE_WATCHDOG=1
bash "${REPO_ROOT}/scripts/host/assert-no-host-reboot-vote.sh"
