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

# 1. --dry-run defaults with isolated HOME="$TMP/home": --no-default-labels,
#    --labels self-hosted-native-macos, default install dir $TMP/home/actions-runner-macos-ci,
#    never touching $TMP/home/actions-runner, Scratch work dir native-macos-ci-work,
#    and LaunchAgent plist WITH <key>SessionCreate</key><true/>.
cat > "$TMP/bin/scratch-dir-ok.sh" <<STUB
#!/usr/bin/env bash
set -euo pipefail
sub="\${1:-}"
if [ -n "\$sub" ]; then
  printf '%s\n' "$TMP/scratch/\$sub"
else
  printf '%s\n' "$TMP/scratch"
fi
STUB
chmod +x "$TMP/bin/scratch-dir-ok.sh"

dry_out="$(
  HOME="$TMP/home" \
  PATH="$TMP/bin:$PATH" \
  DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm" \
  SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" \
  GH_BIN="$TMP/bin/gh" \
  "$SETUP_SCRIPT" --dry-run
)"

grep -q -- '--no-default-labels' <<<"$dry_out" || fail "registration must include --no-default-labels"
grep -qE -- '--labels[= ]self-hosted-native-macos([[:space:]]|$)' <<<"$dry_out" || fail "registration must include --labels self-hosted-native-macos"
grep -q "$TMP/home/actions-runner-macos-ci" <<<"$dry_out" || fail "runner install dir must default to \$HOME/actions-runner-macos-ci"
! grep -qE "^(RUNNER_DIR=|.*<string>)$TMP/home/actions-runner(</string>|/run\\.sh|$)" <<<"$dry_out" || fail "setup script must never target \$HOME/actions-runner as runner dir"
grep -q "$TMP/scratch/native-macos-ci-work" <<<"$dry_out" || fail "work dir must resolve via Scratch (native-macos-ci-work)"
grep -q 'org.jleechanorg.ezgha-native-macos-runner' <<<"$dry_out" || fail "dry-run must include LaunchAgent label org.jleechanorg.ezgha-native-macos-runner"
DRY_PLIST="$TMP/dry-plist.plist"
awk '/^<\?xml/{flag=1} flag{print}' <<<"$dry_out" > "$DRY_PLIST"
DRY_PLIST="$DRY_PLIST" python3 - <<'PY'
import os, plistlib
from pathlib import Path
p = plistlib.loads(Path(os.environ["DRY_PLIST"]).read_bytes())
assert p.get("SessionCreate") is True, f"expected SessionCreate=True, got {p.get('SessionCreate')!r}"
PY
pass "setup-native-macos-runner.sh --dry-run uses isolated dir, Scratch work dir, safe labels, and SessionCreate=true"

# 2. Rejects dangerous labels and canonical reserved TestFlight/SMTP-egress runner dirs (aliases, .., symlinks).
for bad_label in "self-hosted" "self-hosted-native-macos,self-hosted" "worldai-testflight-native-mac" "self-hosted-native-macos,worldai-testflight-native-mac"; do
  if HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh" \
      "$SETUP_SCRIPT" --dry-run --labels "$bad_label" >/dev/null 2>&1; then
    fail "must reject forbidden label combination: $bad_label"
  fi
done
mkdir -p "$TMP/home/actions-runner" "$TMP/home/actions-runner-smtp-egress"
ln -s "$TMP/home/actions-runner" "$TMP/symlink-to-tf"
ln -s "$TMP/home/actions-runner-smtp-egress" "$TMP/symlink-to-smtp"
for bad_dir in \
  "$TMP/home/actions-runner" \
  "$TMP/home/actions-runner/." \
  "$TMP/home/actions-runner-macos-ci/../actions-runner" \
  "$TMP/symlink-to-tf" \
  "$TMP/home/actions-runner-smtp-egress" \
  "$TMP/home/actions-runner-smtp-egress/." \
  "$TMP/symlink-to-smtp"; do
  if HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh" \
      "$SETUP_SCRIPT" --dry-run --runner-dir "$bad_dir" >/dev/null 2>&1; then
    fail "must refuse canonical reserved runner directory: $bad_dir"
  fi
done
pass "forbidden labels and canonical reserved runner dirs (including . / .. / symlinks) fail closed"

# 3. Scratch resolution: fallback to `diskm volume path scratch` when scratch-dir.sh fails/empty,
#    and fail closed with exit 1 when neither yields an existing /* Scratch directory (never /tmp fallback).
cat > "$TMP/bin/scratch-dir-fail.sh" <<'STUB'
#!/usr/bin/env bash
exit 75
STUB
chmod +x "$TMP/bin/scratch-dir-fail.sh"

cat > "$TMP/bin/diskm-vol" <<STUB
#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" = "volume" ] && [ "\${2:-}" = "path" ] && [ "\${3:-}" = "scratch" ]; then
  printf '%s\n' "$TMP/scratch"
  exit 0
fi
exit 1
STUB
chmod +x "$TMP/bin/diskm-vol"

vol_out="$(
  HOME="$TMP/home" \
  PATH="$TMP/bin:$PATH" \
  DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" \
  SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-fail.sh" \
  GH_BIN="$TMP/bin/gh" \
  "$SETUP_SCRIPT" --dry-run
)"
grep -q "WORK_DIR=$TMP/scratch/native-macos-ci-work" <<<"$vol_out" || fail "must fall back to diskm volume path scratch when scratch-dir.sh fails"

cat > "$TMP/bin/diskm-missing" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$TMP/bin/diskm-missing"

if fail_out="$(
  HOME="$TMP/home" \
  PATH="$TMP/bin:$PATH" \
  DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-missing" \
  SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-fail.sh" \
  GH_BIN="$TMP/bin/gh" \
  "$SETUP_SCRIPT" --dry-run 2>&1
)"; then
  fail "must fail closed (exit 1) when Scratch cannot be resolved; got: $fail_out"
fi
! grep -q '/tmp/native-macos-ci-work' <<<"$fail_out" || fail "must never fall back to /tmp/native-macos-ci-work"
pass "Scratch fallback uses diskm volume path scratch and fails closed without /tmp fallback"

# 4. Supported reconfiguration (--reconfigure / label change) & --verify (SessionCreate=true + .ezgha-labels + live gh check).
RUNNER_DIR_T="$TMP/home/actions-runner-macos-ci"
mkdir -p "$RUNNER_DIR_T/bin"
cat > "$RUNNER_DIR_T/bin/Runner.Listener" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$RUNNER_DIR_T/bin/Runner.Listener"

cat > "$RUNNER_DIR_T/config.sh" <<STUB
#!/usr/bin/env bash
set -euo pipefail
if [ -e "$RUNNER_DIR_T/.runner" ] || [ -e "$RUNNER_DIR_T/.credentials" ] || [ -e "$RUNNER_DIR_T/.credentials_rsaparams" ]; then
  echo "ConfigurationManager error: runner is already configured" >&2
  exit 1
fi
printf 'config.sh %s\n' "\$*" >> "$TMP/config.log"
printf '{"agentName":"mac-native-ci-1","workFolder":"%s","gitHubUrl":"https://github.com/jleechanorg"}\n' "$TMP/scratch/native-macos-ci-work" > "$RUNNER_DIR_T/.runner"
printf 'creds\n' > "$RUNNER_DIR_T/.credentials"
printf 'rsa\n' > "$RUNNER_DIR_T/.credentials_rsaparams"
STUB
chmod +x "$RUNNER_DIR_T/config.sh"

cat > "$RUNNER_DIR_T/run.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$RUNNER_DIR_T/run.sh"

cat > "$TMP/bin/launchctl-track" <<STUB
#!/usr/bin/env bash
printf 'launchctl %s\n' "\$*" >> "$TMP/launchctl.log"
exit 0
STUB
chmod +x "$TMP/bin/launchctl-track"
cp "$TMP/bin/launchctl-track" "$TMP/bin/launchctl"

cat > "$TMP/bin/gh-runner" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *"actions/runners/registration-token"*)
    printf 'stub-reg-token\n'
    ;;
  *"actions/runners"*)
    default_live='{"runners":[{"name":"mac-native-ci-1","labels":[{"name":"self-hosted-native-macos"}]}]}'
    printf '%s\n' "${LIVE_RUNNERS_JSON:-$default_live}"
    ;;
  *)
    echo "unexpected gh call: $*" >&2
    exit 99
    ;;
esac
STUB
chmod +x "$TMP/bin/gh-runner"

# Pre-populate existing installation with old labels and existing plist to test reconfiguration.
printf '{"agentName":"mac-native-ci-1","workFolder":"%s","gitHubUrl":"https://github.com/jleechanorg"}\n' "$TMP/scratch/native-macos-ci-work" > "$RUNNER_DIR_T/.runner"
printf 'old-creds\n' > "$RUNNER_DIR_T/.credentials"
printf 'old-rsa\n' > "$RUNNER_DIR_T/.credentials_rsaparams"
printf 'old-label\n' > "$RUNNER_DIR_T/.ezgha-labels"
PLIST_T="$TMP/home/Library/LaunchAgents/org.jleechanorg.ezgha-native-macos-runner.plist"
printf '<plist version="1.0"><dict><key>Label</key><string>org.jleechanorg.ezgha-native-macos-runner</string></dict></plist>\n' > "$PLIST_T"
: > "$TMP/launchctl.log"
: > "$TMP/config.log"

HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  "$SETUP_SCRIPT" >/dev/null

grep -q 'config.sh .*--labels self-hosted-native-macos' "$TMP/config.log" || fail "label change must re-run config.sh"
[ "$(tr -d '\r\n' < "$RUNNER_DIR_T/.ezgha-labels")" = "self-hosted-native-macos" ] || fail ".ezgha-labels must persist configured labels"
first_unload_line="$(grep -n "launchctl unload $PLIST_T" "$TMP/launchctl.log" | head -n1 | cut -d: -f1 || true)"
[ -n "$first_unload_line" ] || fail "reconfigure must unload existing LaunchAgent"

# --verify passes when SessionCreate=true, .ezgha-labels matches, and live GitHub labels match.
HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  "$SETUP_SCRIPT" --verify >/dev/null

# --verify fails if live GitHub runner has forbidden 'self-hosted' or 'worldai-testflight-native-mac' or mismatched labels.
for bad_live in \
  '{"runners":[{"name":"mac-native-ci-1","labels":[{"name":"self-hosted-native-macos"},{"name":"self-hosted"}]}]}' \
  '{"runners":[{"name":"mac-native-ci-1","labels":[{"name":"worldai-testflight-native-mac"}]}]}' \
  '{"runners":[{"name":"mac-native-ci-1","labels":[{"name":"other-label"}]}]}'; do
  if LIVE_RUNNERS_JSON="$bad_live" HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
      "$SETUP_SCRIPT" --verify >/dev/null 2>&1; then
    fail "--verify must fail when live GitHub labels mismatch or include forbidden label: $bad_live"
  fi
done

# --verify --offline skips gh call and succeeds locally.
HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh" \
  "$SETUP_SCRIPT" --verify --offline >/dev/null

# --verify rejects SessionCreate=false or missing SessionCreate.
cp "$PLIST_T" "$TMP/plist.ok"
python3 - "$PLIST_T" <<'PY'
import plistlib, sys
from pathlib import Path
p = Path(sys.argv[1])
d = plistlib.loads(p.read_bytes())
d["SessionCreate"] = False
p.write_bytes(plistlib.dumps(d))
PY
if HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
    "$SETUP_SCRIPT" --verify --offline >/dev/null 2>&1; then
  fail "--verify must reject SessionCreate=false"
fi

python3 - "$PLIST_T" <<'PY'
import plistlib, sys
from pathlib import Path
p = Path(sys.argv[1])
d = plistlib.loads(p.read_bytes())
d.pop("SessionCreate", None)
p.write_bytes(plistlib.dumps(d))
PY
if HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
    "$SETUP_SCRIPT" --verify --offline >/dev/null 2>&1; then
  fail "--verify must reject missing SessionCreate"
fi
pass "reconfiguration, .ezgha-labels, live gh label verification, and SessionCreate=true enforcement pass"

# 5. Label-scoped launchd install of org.jleechanorg.ezgha-gh-actions-cost-alert in isolated temp HOME
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
