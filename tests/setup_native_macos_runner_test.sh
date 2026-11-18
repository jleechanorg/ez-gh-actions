#!/usr/bin/env bash
# Hermetic tests for reproducible native macOS CI runner setup and cost-alert launchd install.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP_SCRIPT="$ROOT/scripts/setup-native-macos-runner.sh"
INSTALL_LAUNCHAGENTS="$ROOT/launchd/install-launchagents.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

mkdir -p "$TMP/home/Library/LaunchAgents" "$TMP/home/.local/libexec/ezgha" "$TMP/bin" "$TMP/scratch/native-macos-ci-work"

cat > "$TMP/bin/diskm" <<STUB
#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" = "scratch-dir" ]; then
  sub="\${2:-}"
  if [ -n "\$sub" ]; then
    printf '%s\n' "$TMP/scratch/\$sub"
  else
    printf '%s\n' "$TMP/scratch"
  fi
  exit 0
fi
exit 1
STUB

cat > "$TMP/bin/launchctl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh should not be invoked during --dry-run: $*" >&2
exit 99
STUB

chmod +x "$TMP/bin/diskm" "$TMP/bin/launchctl" "$TMP/bin/gh"

# 1. --dry-run defaults: --no-default-labels, --labels self-hosted-native-macos,
#    default install dir /Users/jleechan/actions-runner-macos-ci (when HOME=/Users/jleechan),
#    never touching /Users/jleechan/actions-runner, Scratch work dir native-macos-ci-work,
#    and LaunchAgent plist without SessionCreate=false.
dry_out="$(
  HOME="/Users/jleechan" \
  PATH="$TMP/bin:$PATH" \
  DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm" \
  GH_BIN="$TMP/bin/gh" \
  "$SETUP_SCRIPT" --dry-run
)"

grep -q -- '--no-default-labels' <<<"$dry_out" || fail "registration must include --no-default-labels"
grep -qE -- '--labels[= ]self-hosted-native-macos([[:space:]]|$)' <<<"$dry_out" || fail "registration must include --labels self-hosted-native-macos"
grep -q '/Users/jleechan/actions-runner-macos-ci' <<<"$dry_out" || fail "runner install dir must default to /Users/jleechan/actions-runner-macos-ci"
! grep -qE '^(RUNNER_DIR=|.*<string>)/Users/jleechan/actions-runner(</string>|/run\.sh|$)' <<<"$dry_out" || fail "setup script must never target /Users/jleechan/actions-runner as runner dir"
grep -q "$TMP/scratch/native-macos-ci-work" <<<"$dry_out" || fail "work dir must resolve via Scratch (native-macos-ci-work)"
! grep -q 'SessionCreate' <<<"$dry_out" || fail "general CI runner LaunchAgent must NOT set SessionCreate=false"
grep -q 'org.jleechanorg.ezgha-native-macos-runner' <<<"$dry_out" || fail "dry-run must include LaunchAgent label org.jleechanorg.ezgha-native-macos-runner"
pass "setup-native-macos-runner.sh --dry-run uses isolated dir, Scratch work dir, safe labels, and no SessionCreate=false"

# 2. Rejects dangerous labels (bare self-hosted or worldai-testflight-native-mac) and TestFlight runner dir.
for bad_label in "self-hosted" "self-hosted-native-macos,self-hosted" "worldai-testflight-native-mac" "self-hosted-native-macos,worldai-testflight-native-mac"; do
  if HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm" GH_BIN="$TMP/bin/gh" \
      "$SETUP_SCRIPT" --dry-run --labels "$bad_label" >/dev/null 2>&1; then
    fail "must reject forbidden label combination: $bad_label"
  fi
done
if HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm" GH_BIN="$TMP/bin/gh" \
    "$SETUP_SCRIPT" --dry-run --runner-dir "$TMP/home/actions-runner" >/dev/null 2>&1; then
  fail "must refuse TestFlight runner directory ~/actions-runner"
fi
pass "forbidden labels (self-hosted, worldai-testflight-native-mac) and ~/actions-runner dir fail closed"

# 3. Label-scoped launchd install of org.jleechanorg.ezgha-gh-actions-cost-alert in isolated temp HOME
#    must preserve incumbent scripts and render a valid hourly plist.
printf 'incumbent queue monitor\n' > "$TMP/home/.local/libexec/ezgha/runner-offline-queued-alert.sh"
BASH_ENV=/dev/null HOME="$TMP/home" PATH="$TMP/bin:$PATH" \
  bash "$INSTALL_LAUNCHAGENTS" install org.jleechanorg.ezgha-gh-actions-cost-alert >/dev/null

cmp -s "$TMP/home/.local/libexec/ezgha/runner-offline-queued-alert.sh" <(printf 'incumbent queue monitor\n') || \
  fail "targeted cost-alert install overwrote incumbent scripts"
test -x "$TMP/home/.local/libexec/ezgha/gh-actions-cost-alert.sh" || \
  fail "gh-actions-cost-alert.sh was not installed to ~/.local/libexec/ezgha"
COST_PLIST="$TMP/home/Library/LaunchAgents/org.jleechanorg.ezgha-gh-actions-cost-alert.plist"
test -f "$COST_PLIST" || fail "cost-alert plist was not rendered"

COST_PLIST="$COST_PLIST" HOME_T="$TMP/home" python3 - <<'PY'
import os
import plistlib
from pathlib import Path

payload = plistlib.loads(Path(os.environ["COST_PLIST"]).read_bytes())
home = os.environ["HOME_T"]
assert payload["Label"] == "org.jleechanorg.ezgha-gh-actions-cost-alert"
assert payload["ProgramArguments"] == [
    "/bin/bash",
    f"{home}/.local/libexec/ezgha/gh-actions-cost-alert.sh",
]
assert payload["StartInterval"] == 3600
assert payload["RunAtLoad"] is True
serialized = str(payload)
assert "@" not in serialized
assert "worktree" not in serialized.lower()
PY
pass "label-scoped install of org.jleechanorg.ezgha-gh-actions-cost-alert preserves incumbents and renders valid plist"
