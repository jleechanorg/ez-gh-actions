#!/usr/bin/env bash
# Targeted installation of the TestFlight monitor must preserve existing scripts.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT
mkdir -p "$TMP/home/.local/libexec/ezgha" "$TMP/home/Library/LaunchAgents" "$TMP/bin"
printf 'incumbent queue monitor\n' > "$TMP/home/.local/libexec/ezgha/runner-offline-queued-alert.sh"
cat > "$TMP/bin/launchctl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMP/bin/launchctl"
BASH_ENV=/dev/null HOME="$TMP/home" PATH="$TMP/bin:$PATH" bash "$ROOT/launchd/install-launchagents.sh" install \
  org.jleechanorg.ezgha-testflight-workflow-alert >/dev/null
cmp -s "$TMP/home/.local/libexec/ezgha/runner-offline-queued-alert.sh" <(printf 'incumbent queue monitor\n') || {
  echo "FAIL: targeted TestFlight alert install overwrote the incumbent queue monitor" >&2; exit 1;
}
test -x "$TMP/home/.local/libexec/ezgha/testflight-workflow-alert.sh"
test -f "$TMP/home/Library/LaunchAgents/org.jleechanorg.ezgha-testflight-workflow-alert.plist"
echo "PASS: targeted TestFlight alert install preserves incumbent scripts"
