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
: > "$RUNNER_DIR_T/run-helper.sh.template"

cat > "$TMP/bin/launchctl-track" <<STUB
#!/usr/bin/env bash
printf 'launchctl %s\n' "\$*" >> "$TMP/launchctl.log"
state_file="$TMP/launchctl.loaded"
case "\${1:-}" in
  load|bootstrap)
    : > "\$state_file"
    ;;
  unload|bootout)
    if [ -n "\${LAUNCHCTL_REFUSE_STOP:-}" ]; then
      exit 1
    fi
    rm -f "\$state_file"
    ;;
  print)
    if [ -n "\${LAUNCHCTL_RACE_TAG:-}" ] && [ ! -f "$TMP/race_seen_\${LAUNCHCTL_RACE_TAG}" ]; then
      : > "$TMP/race_seen_\${LAUNCHCTL_RACE_TAG}"
      printf 'ENTER %s\n' "\${LAUNCHCTL_RACE_TAG}" >> "\${LAUNCHCTL_TRACE_FILE:?}"
      sleep "\${LAUNCHCTL_TRACE_SLEEP:-0.5}"
      printf 'EXIT %s\n' "\${LAUNCHCTL_RACE_TAG}" >> "\${LAUNCHCTL_TRACE_FILE:?}"
    fi
    if [ -n "\${LAUNCHCTL_PRINT_ERR_RC:-}" ]; then
      echo "\${LAUNCHCTL_PRINT_ERR_MSG:-launchctl: lookup error}" >&2
      exit "\${LAUNCHCTL_PRINT_ERR_RC}"
    fi
    if [ -f "\$state_file" ]; then
      exit 0
    fi
    echo "Could not find service \"\${2:-}\" in domain" >&2
    exit 113
    ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/launchctl-track"
cp "$TMP/bin/launchctl-track" "$TMP/bin/launchctl"

cat > "$TMP/bin/gh-runner" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ -n "${GH_RUNNER_CALL_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$GH_RUNNER_CALL_LOG"
fi
jq_expr=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [ "${args[$i]}" = "--jq" ] && (( i + 1 < ${#args[@]} )); then
    jq_expr="${args[$((i + 1))]}"
  fi
done
emit_json() {
  local raw="$1"
  if [ -n "$jq_expr" ]; then
    printf '%s\n' "$raw" | jq -r "$jq_expr"
  else
    printf '%s\n' "$raw"
  fi
}
case "$*" in
  *"actions/runners/registration-token"*)
    emit_json '{"token":"stub-reg-token"}'
    ;;
  *"actions/runner-groups"*)
    default_groups='{"total_count":1,"runner_groups":[{"id":1,"name":"Default","default":true,"allows_public_repositories":false}]}'
    emit_json "${RUNNER_GROUPS_JSON:-$default_groups}"
    ;;
  *"actions/permissions/fork-pr-contributor-approval"*)
    default_policy='{"approval_policy":"first_time_contributors"}'
    emit_json "${FORK_APPROVAL_JSON:-$default_policy}"
    ;;
  *"actions/runners"*)
    default_live='{"runners":[{"id":101,"name":"mac-native-ci-1","labels":[{"name":"self-hosted-native-macos"}]}]}'
    emit_json "${LIVE_RUNNERS_JSON:-$default_live}"
    ;;
  *"repos/"*)
    default_repo='{"private":true}'
    emit_json "${REPO_META_JSON:-$default_repo}"
    ;;
  *)
    echo "unexpected gh call: $*" >&2
    exit 99
    ;;
esac
STUB
chmod +x "$TMP/bin/gh-runner"

# Pre-populate existing installation with old labels and existing plist to test reconfiguration.
printf '{"agentId":101,"agentName":"mac-native-ci-1","workFolder":"%s","gitHubUrl":"https://github.com/jleechanorg"}\n' "$TMP/scratch/native-macos-ci-work" > "$RUNNER_DIR_T/.runner"
printf 'old-creds\n' > "$RUNNER_DIR_T/.credentials"
printf 'old-rsa\n' > "$RUNNER_DIR_T/.credentials_rsaparams"
printf 'old-label\n' > "$RUNNER_DIR_T/.ezgha-labels"
PLIST_T="$TMP/home/Library/LaunchAgents/org.jleechanorg.ezgha-native-macos-runner.plist"
printf '<plist version="1.0"><dict><key>Label</key><string>org.jleechanorg.ezgha-native-macos-runner</string></dict></plist>\n' > "$PLIST_T"
: > "$TMP/launchctl.loaded"
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
cp "$TMP/plist.ok" "$PLIST_T"
pass "reconfiguration, .ezgha-labels, live gh label verification, and SessionCreate=true enforcement pass"

# 4b. Ambient GitHub Actions RUNNER_NAME must NOT override default mac-native-ci-1 in --dry-run or --verify,
#     while NATIVE_MACOS_RUNNER_NAME and --name DO override it.
ambient_dry_out="$(
  GITHUB_ACTIONS=true \
  RUNNER_NAME="GitHub Actions 1000690174" \
  HOME="$TMP/home" \
  PATH="$TMP/bin:$PATH" \
  DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" \
  SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" \
  GH_BIN="$TMP/bin/gh" \
  "$SETUP_SCRIPT" --dry-run
)"
grep -q '^RUNNER_NAME=mac-native-ci-1$' <<<"$ambient_dry_out" || \
  fail "ambient RUNNER_NAME must not override default mac-native-ci-1 in --dry-run"
grep -q -- '--name mac-native-ci-1' <<<"$ambient_dry_out" || \
  fail "ambient RUNNER_NAME must not override --name mac-native-ci-1 in CONFIG_CMD"

GITHUB_ACTIONS=true RUNNER_NAME="GitHub Actions 1000690174" \
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh" \
  "$SETUP_SCRIPT" --verify --offline >/dev/null || \
  fail "ambient RUNNER_NAME must not break --verify for mac-native-ci-1"

env_override_dry_out="$(
  GITHUB_ACTIONS=true \
  RUNNER_NAME="GitHub Actions 1000690174" \
  NATIVE_MACOS_RUNNER_NAME="custom-mac-1" \
  HOME="$TMP/home" \
  PATH="$TMP/bin:$PATH" \
  DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" \
  SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" \
  GH_BIN="$TMP/bin/gh" \
  "$SETUP_SCRIPT" --dry-run
)"
grep -q '^RUNNER_NAME=custom-mac-1$' <<<"$env_override_dry_out" || \
  fail "NATIVE_MACOS_RUNNER_NAME must override default runner name in --dry-run"
grep -q -- '--name custom-mac-1' <<<"$env_override_dry_out" || \
  fail "NATIVE_MACOS_RUNNER_NAME must override --name in CONFIG_CMD"

cli_override_dry_out="$(
  GITHUB_ACTIONS=true \
  RUNNER_NAME="GitHub Actions 1000690174" \
  NATIVE_MACOS_RUNNER_NAME="custom-mac-1" \
  HOME="$TMP/home" \
  PATH="$TMP/bin:$PATH" \
  DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" \
  SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" \
  GH_BIN="$TMP/bin/gh" \
  "$SETUP_SCRIPT" --dry-run --name custom-mac-2
)"
grep -q '^RUNNER_NAME=custom-mac-2$' <<<"$cli_override_dry_out" || \
  fail "--name must override NATIVE_MACOS_RUNNER_NAME and default in --dry-run"
grep -q -- '--name custom-mac-2' <<<"$cli_override_dry_out" || \
  fail "--name must override --name in CONFIG_CMD"
pass "ambient GitHub Actions RUNNER_NAME is ignored while NATIVE_MACOS_RUNNER_NAME and --name override cleanly"

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

# 6. --uninstall runs before resolve_work_dir, unloads even without plist, and retains plist if still loaded.
: > "$TMP/launchctl.loaded"
HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-missing" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-fail.sh" \
  "$SETUP_SCRIPT" --uninstall >/dev/null || fail "--uninstall must succeed even when Scratch cannot be resolved"
[ ! -e "$PLIST_T" ] || fail "--uninstall must remove plist after service is unloaded"
[ ! -e "$TMP/launchctl.loaded" ] || fail "--uninstall must unload launchd job"

# Missing plist but still-loaded service must still run bootout and clear loaded state.
: > "$TMP/launchctl.loaded"
: > "$TMP/launchctl.log"
HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-missing" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-fail.sh" \
  "$SETUP_SCRIPT" --uninstall >/dev/null
grep -q 'launchctl bootout gui/' "$TMP/launchctl.log" || fail "--uninstall must attempt bootout even when plist is missing"
[ ! -e "$TMP/launchctl.loaded" ] || fail "--uninstall must unload still-loaded service when plist is missing"

# Refusing to unload must exit non-zero and retain plist.
cp "$TMP/plist.ok" "$PLIST_T"
: > "$TMP/launchctl.loaded"
if LAUNCHCTL_REFUSE_STOP=1 HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-missing" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-fail.sh" \
    "$SETUP_SCRIPT" --uninstall >/dev/null 2>&1; then
  fail "--uninstall must fail when service remains loaded"
fi
[ -f "$PLIST_T" ] || fail "--uninstall must retain plist when service remains loaded"
HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" \
  "$SETUP_SCRIPT" --uninstall >/dev/null

# 7. Required self-hosted-native-macos label & filesystem-identity/HOME checks on RUNNER_DIR and WORK_DIR.
if HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh" \
    "$SETUP_SCRIPT" --dry-run --labels "ci-extra" >/dev/null 2>&1; then
  fail "--labels without self-hosted-native-macos must be rejected"
fi
HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh" \
  "$SETUP_SCRIPT" --dry-run --labels "self-hosted-native-macos,ci-extra" >/dev/null || \
  fail "--labels with self-hosted-native-macos plus safe extra label must succeed"

for bad_runner in "$TMP/home" "$TMP/home/Actions-Runner" "$TMP/home/Actions-Runner/sub"; do
  if HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh" \
      "$SETUP_SCRIPT" --dry-run --runner-dir "$bad_runner" >/dev/null 2>&1; then
    fail "must reject unsafe/case-alias RUNNER_DIR: $bad_runner"
  fi
done
for bad_work in "$TMP/home" "$TMP/home/actions-runner" "$TMP/home/actions-runner/work" "$TMP/home/Actions-Runner/work"; do
  if HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh" \
      "$SETUP_SCRIPT" --dry-run --work-dir "$bad_work" >/dev/null 2>&1; then
    fail "must reject unsafe/reserved WORK_DIR: $bad_work"
  fi
done
if HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh" \
    "$SETUP_SCRIPT" --dry-run --work-dir "$TMP/overlap-x" --runner-dir "$TMP/overlap-x/sub" >/dev/null 2>&1; then
  fail "must reject nested RUNNER_DIR inside WORK_DIR"
fi
if HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh" \
    "$SETUP_SCRIPT" --dry-run --work-dir "$TMP/overlap-x/sub" --runner-dir "$TMP/overlap-x" >/dev/null 2>&1; then
  fail "must reject nested WORK_DIR inside RUNNER_DIR"
fi
if HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh" \
    "$SETUP_SCRIPT" --dry-run --work-dir "$TMP/overlap-x" --runner-dir "$TMP/overlap-x" >/dev/null 2>&1; then
  fail "must reject identical WORK_DIR and RUNNER_DIR"
fi
pass "required label and HOME/filesystem-identity/overlap reserved dir guards hold for RUNNER_DIR and WORK_DIR"

# 8. --verify enforces GH_BIN without --offline, [ -d "$WORK_DIR" ], and LaunchAgent WorkingDirectory/ProgramArguments.
cp "$TMP/plist.ok" "$PLIST_T"
: > "$TMP/launchctl.loaded"
if HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/no-such-gh" \
    "$SETUP_SCRIPT" --verify >/dev/null 2>&1; then
  fail "--verify without --offline must fail when GH_BIN is missing"
fi
HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/no-such-gh" \
  "$SETUP_SCRIPT" --verify --offline >/dev/null || fail "--verify --offline should succeed without GH_BIN"

rmdir "$TMP/scratch/native-macos-ci-work"
if HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
    "$SETUP_SCRIPT" --verify --offline >/dev/null 2>&1; then
  fail "--verify must fail when WORK_DIR does not exist"
fi
mkdir -p "$TMP/scratch/native-macos-ci-work"

python3 - "$PLIST_T" "$TMP/other-runner" <<'PY'
import plistlib, sys
from pathlib import Path
p = Path(sys.argv[1])
d = plistlib.loads(p.read_bytes())
d["WorkingDirectory"] = sys.argv[2]
p.write_bytes(plistlib.dumps(d))
PY
if HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
    "$SETUP_SCRIPT" --verify --offline >/dev/null 2>&1; then
  fail "--verify must fail when plist WorkingDirectory mismatches RUNNER_DIR"
fi

cp "$TMP/plist.ok" "$PLIST_T"
printf '#!/usr/bin/env bash\nexit 0\n' > "$RUNNER_DIR_T/runsvc.sh"
chmod +x "$RUNNER_DIR_T/runsvc.sh"
python3 - "$PLIST_T" "$RUNNER_DIR_T/runsvc.sh" <<'PY'
import plistlib, sys
from pathlib import Path
p = Path(sys.argv[1])
d = plistlib.loads(p.read_bytes())
d["ProgramArguments"] = ["/bin/bash", sys.argv[2]]
p.write_bytes(plistlib.dumps(d))
PY
HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  "$SETUP_SCRIPT" --verify --offline >/dev/null || fail "--verify must accept readable runsvc.sh in ProgramArguments"

rm -f "$RUNNER_DIR_T/runsvc.sh"
if HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
    "$SETUP_SCRIPT" --verify --offline >/dev/null 2>&1; then
  fail "--verify must reject missing runsvc.sh referenced by plist ProgramArguments"
fi

cp "$TMP/plist.ok" "$PLIST_T"
python3 - "$PLIST_T" "$TMP/other-runner/run.sh" <<'PY'
import plistlib, sys
from pathlib import Path
p = Path(sys.argv[1])
d = plistlib.loads(p.read_bytes())
d["ProgramArguments"] = ["/bin/bash", sys.argv[2]]
p.write_bytes(plistlib.dumps(d))
PY
if HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
    "$SETUP_SCRIPT" --verify --offline >/dev/null 2>&1; then
  fail "--verify must fail when plist ProgramArguments mismatches RUNNER_DIR/run.sh or runsvc.sh"
fi
cp "$TMP/plist.ok" "$PLIST_T"
pass "--verify enforces GH_BIN, WORK_DIR existence, and plist target paths"

# 9. Interrupted binary provisioning (Runner.Listener present, config.sh missing) repairs cleanly on retry,
#    stopping the LaunchAgent before promoting staged binaries and reloading afterward.
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl must not be invoked during hermetic binary repair: $*" >&2
exit 99
STUB
chmod +x "$TMP/bin/curl"
mkdir -p "$TMP/home/actions-runner/bin"
cp "$RUNNER_DIR_T/bin/Runner.Listener" "$TMP/home/actions-runner/bin/Runner.Listener"
cp "$RUNNER_DIR_T/config.sh" "$TMP/home/actions-runner/config.sh"
cp "$RUNNER_DIR_T/run.sh" "$TMP/home/actions-runner/run.sh"
cp "$RUNNER_DIR_T/run-helper.sh.template" "$TMP/home/actions-runner/run-helper.sh.template"
rm -f "$RUNNER_DIR_T/config.sh" "$RUNNER_DIR_T/run.sh" "$RUNNER_DIR_T/run-helper.sh.template"
: > "$TMP/launchctl.log"
: > "$TMP/launchctl.loaded"
HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  EXISTING_RUNNER_DIR="$TMP/home/actions-runner" "$SETUP_SCRIPT" >/dev/null
[ -x "$RUNNER_DIR_T/config.sh" ] && [ -x "$RUNNER_DIR_T/run.sh" ] || fail "incomplete provisioning must repair config.sh and run.sh on retry"
grep -q "launchctl unload $PLIST_T" "$TMP/launchctl.log" || fail "binary repair must stop LaunchAgent before promoting staged binaries"
[ -f "$TMP/launchctl.loaded" ] || fail "binary repair must reload LaunchAgent after repairing binaries"
pass "incomplete runner provisioning stops LaunchAgent, repairs missing binaries, and reloads"

# 10. No-change rerun leaves loaded LaunchAgent running; failed stop aborts before deleting creds;
#     failed config.sh fails closed (exit 4), preserves .backup-pre-reconfigure.*, does NOT restore creds, and leaves service stopped.
: > "$TMP/launchctl.log"
: > "$TMP/launchctl.loaded"
HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  "$SETUP_SCRIPT" >/dev/null
if grep -Eq 'launchctl (unload|bootout|load)' "$TMP/launchctl.log"; then
  fail "idempotent no-change rerun must not unload or reload an already-loaded LaunchAgent"
fi

if LAUNCHCTL_REFUSE_STOP=1 HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
    "$SETUP_SCRIPT" --reconfigure >/dev/null 2>&1; then
  fail "--reconfigure must abort if LaunchAgent refuses to stop"
fi
[ -f "$RUNNER_DIR_T/.credentials" ] || fail "failed stop must abort before removing .credentials"

cat > "$RUNNER_DIR_T/config.sh" <<'STUB'
#!/usr/bin/env bash
echo "simulated config.sh failure" >&2
exit 1
STUB
chmod +x "$RUNNER_DIR_T/config.sh"
printf '{"agentId":101,"agentName":"mac-native-ci-1","workFolder":"%s","gitHubUrl":"https://github.com/jleechanorg"}\n' "$TMP/scratch/native-macos-ci-work" > "$RUNNER_DIR_T/.runner"
printf 'preserved-creds\n' > "$RUNNER_DIR_T/.credentials"
printf 'preserved-rsa\n' > "$RUNNER_DIR_T/.credentials_rsaparams"
printf 'preserved-migrated-runner\n' > "$RUNNER_DIR_T/.runner_migrated"
printf 'preserved-migrated-creds\n' > "$RUNNER_DIR_T/.credentials_migrated"
: > "$TMP/launchctl.loaded"
: > "$TMP/launchctl.log"
reconfig_rc=0
reconfig_err="$(
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
    "$SETUP_SCRIPT" --reconfigure 2>&1 >/dev/null
)" || reconfig_rc=$?
[ "$reconfig_rc" -eq 4 ] || fail "failed config.sh must exit 4 fail-closed (got $reconfig_rc)"
grep -q 'ERROR:.*\.backup-pre-reconfigure\.' <<<"$reconfig_err" || fail "failed config.sh must print ERROR naming preserved backup directory (got: $reconfig_err)"
grep -q -- '--reconfigure' <<<"$reconfig_err" || fail "failed config.sh error must instruct operator to re-run --reconfigure"
[ ! -e "$RUNNER_DIR_T/.runner" ] && [ ! -e "$RUNNER_DIR_T/.credentials" ] && [ ! -e "$RUNNER_DIR_T/.credentials_rsaparams" ] && \
  [ ! -e "$RUNNER_DIR_T/.runner_migrated" ] && [ ! -e "$RUNNER_DIR_T/.credentials_migrated" ] || \
  fail "failed config.sh must fail closed and NOT restore old .runner/.credentials*/migrated files"
[ ! -e "$TMP/launchctl.loaded" ] || fail "failed config.sh must leave LaunchAgent stopped (not reloaded)"
! grep -q 'launchctl load' "$TMP/launchctl.log" || fail "failed config.sh must never call launchctl load"
backup_dirs=("$RUNNER_DIR_T"/.backup-pre-reconfigure.*)
[ "${#backup_dirs[@]}" -eq 1 ] && [ -d "${backup_dirs[0]}" ] || fail "failed config.sh must preserve .backup-pre-reconfigure.<pid> directory"
[ "$(cat "${backup_dirs[0]}/.credentials")" = "preserved-creds" ] || fail "preserved backup must retain .credentials"
[ "$(cat "${backup_dirs[0]}/.credentials_rsaparams")" = "preserved-rsa" ] || fail "preserved backup must retain .credentials_rsaparams"
[ "$(cat "${backup_dirs[0]}/.runner_migrated")" = "preserved-migrated-runner" ] || fail "preserved backup must retain .runner_migrated"
[ "$(cat "${backup_dirs[0]}/.credentials_migrated")" = "preserved-migrated-creds" ] || fail "preserved backup must retain .credentials_migrated"
[ -f "${backup_dirs[0]}/.runner" ] || fail "preserved backup must retain .runner"
pass "idempotent rerun skips reload, stop failure protects creds, and failed reconfigure fails closed with preserved backup"

# 11. Lifecycle lock blocks concurrent mutating operations, ignores --dry-run/--verify, and reclaims stale dead-PID locks.
LOCK_DIR_T="$TMP/home/.local/state/ezgha/setup-native-macos-runner.org.jleechanorg.ezgha-native-macos-runner.lock"
mkdir -p "$LOCK_DIR_T"
sleep 30 &
holder_pid=$!
printf '%s\n' "$holder_pid" > "$LOCK_DIR_T/pid"

HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh" \
  "$SETUP_SCRIPT" --dry-run >/dev/null || fail "--dry-run must not block on lifecycle lock"
printf '{"agentId":101,"agentName":"mac-native-ci-1","workFolder":"%s","gitHubUrl":"https://github.com/jleechanorg"}\n' "$TMP/scratch/native-macos-ci-work" > "$RUNNER_DIR_T/.runner"
: > "$TMP/launchctl.loaded"
HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh" \
  "$SETUP_SCRIPT" --verify --offline >/dev/null || fail "--verify must not block on lifecycle lock"

if SETUP_LOCK_TIMEOUT_SEC=1 HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" \
    "$SETUP_SCRIPT" --uninstall >/dev/null 2>&1; then
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  fail "mutating --uninstall must fail when lifecycle lock is held by a live PID"
fi
kill "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true

printf '%s\n' "$holder_pid" > "$LOCK_DIR_T/pid"
SETUP_LOCK_TIMEOUT_SEC=5 HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" \
  "$SETUP_SCRIPT" --uninstall >/dev/null || fail "mutating --uninstall must reclaim stale dead-PID lifecycle lock"
[ ! -d "$LOCK_DIR_T" ] || fail "lifecycle lockdir must be released on exit"
pass "lifecycle lock serializes mutating operations, skips --dry-run/--verify, and reclaims stale locks"

# 12. run-helper.sh.template readiness + .env preservation.
rm -f "$RUNNER_DIR_T/run-helper.sh.template"
cp "$TMP/plist.ok" "$PLIST_T"
: > "$TMP/launchctl.loaded"
if HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
    "$SETUP_SCRIPT" --verify --offline >/dev/null 2>&1; then
  fail "--verify must fail when run-helper.sh.template is missing"
fi
cat > "$RUNNER_DIR_T/config.sh" <<STUB
#!/usr/bin/env bash
set -euo pipefail
printf 'config.sh %s\n' "\$*" >> "$TMP/config.log"
printf '{"agentName":"mac-native-ci-1","workFolder":"%s","gitHubUrl":"https://github.com/jleechanorg"}\n' "$TMP/scratch/native-macos-ci-work" > "$RUNNER_DIR_T/.runner"
printf 'creds\n' > "$RUNNER_DIR_T/.credentials"
printf 'rsa\n' > "$RUNNER_DIR_T/.credentials_rsaparams"
STUB
chmod +x "$RUNNER_DIR_T/config.sh"
cp "$RUNNER_DIR_T/config.sh" "$TMP/home/actions-runner/config.sh"
printf 'JAVA_HOME=/opt/java\n' > "$RUNNER_DIR_T/.env"
HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  EXISTING_RUNNER_DIR="$TMP/home/actions-runner" "$SETUP_SCRIPT" >/dev/null
[ -f "$RUNNER_DIR_T/run-helper.sh.template" ] || fail "setup must repair missing run-helper.sh.template"
grep -q '^JAVA_HOME=/opt/java$' "$RUNNER_DIR_T/.env" || fail "setup must preserve existing .env instead of truncating it"
pass "run-helper.sh.template readiness and existing .env preservation hold"

# 13. Fail-closed launchctl print lookup error (rc=2) preserves plist and credentials.
cp "$TMP/plist.ok" "$PLIST_T"
: > "$TMP/launchctl.loaded"
printf 'keep-creds\n' > "$RUNNER_DIR_T/.credentials"
if LAUNCHCTL_PRINT_ERR_RC=2 HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" \
    "$SETUP_SCRIPT" --uninstall >/dev/null 2>&1; then
  fail "--uninstall must fail closed on launchctl print error rc=2"
fi
[ -f "$PLIST_T" ] || fail "--uninstall must preserve plist when launchctl print returns error rc=2"
if LAUNCHCTL_PRINT_ERR_RC=2 HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
    "$SETUP_SCRIPT" --reconfigure >/dev/null 2>&1; then
  fail "--reconfigure must fail closed on launchctl print error rc=2"
fi
[ -f "$RUNNER_DIR_T/.credentials" ] && [ "$(cat "$RUNNER_DIR_T/.credentials")" = "keep-creds" ] || fail "--reconfigure must preserve credentials when launchctl print returns error rc=2"
pass "launchctl print lookup errors fail closed and preserve plist and credentials"

# 14. Fork PR exposure protection, --runner-group, --allow-public-fork-exposure, and --repo.
rg_dry_out="$(
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh" \
    "$SETUP_SCRIPT" --dry-run --runner-group macos-restricted
)"
grep -q '^RUNNER_GROUP=macos-restricted$' <<<"$rg_dry_out" || fail "--dry-run must echo RUNNER_GROUP="
grep -q -- '--runnergroup macos-restricted' <<<"$rg_dry_out" || fail "--dry-run CONFIG_CMD must include --runnergroup"

PUB_OPEN_GROUPS='{"total_count":1,"runner_groups":[{"id":1,"name":"Default","default":true,"allows_public_repositories":true}]}'
MIXED_GROUPS='{"total_count":2,"runner_groups":[{"id":1,"name":"Default","default":true,"allows_public_repositories":true},{"id":2,"name":"macos-restricted","default":false,"allows_public_repositories":false}]}'
: > "$TMP/gh-fork.log"
fork_rc=0
GH_RUNNER_CALL_LOG="$TMP/gh-fork.log" RUNNER_GROUPS_JSON="$PUB_OPEN_GROUPS" FORK_APPROVAL_JSON='{"approval_policy":"first_time_contributors"}' \
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  "$SETUP_SCRIPT" --reconfigure >/dev/null 2>&1 || fork_rc=$?
[ "$fork_rc" -eq 5 ] || fail "setup with allows_public_repositories=true + first_time_contributors must exit 5 (got $fork_rc)"
! grep -q 'registration-token' "$TMP/gh-fork.log" || fail "fork-protection failure must abort BEFORE minting registration-token"

vfork_rc=0
: > "$TMP/launchctl.loaded"
RUNNER_GROUPS_JSON="$PUB_OPEN_GROUPS" FORK_APPROVAL_JSON='{"approval_policy":"first_time_contributors"}' \
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  "$SETUP_SCRIPT" --verify >/dev/null 2>&1 || vfork_rc=$?
[ "$vfork_rc" -eq 5 ] || fail "--verify with allows_public_repositories=true + first_time_contributors must exit 5 (got $vfork_rc)"

RUNNER_GROUPS_JSON="$PUB_OPEN_GROUPS" FORK_APPROVAL_JSON='{"approval_policy":"all_external_contributors"}' \
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  "$SETUP_SCRIPT" --verify >/dev/null || fail "--verify must pass with all_external_contributors"

RUNNER_GROUPS_JSON="$PUB_OPEN_GROUPS" FORK_APPROVAL_JSON='{"approval_policy":"first_time_contributors"}' \
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  "$SETUP_SCRIPT" --verify --allow-public-fork-exposure >/dev/null || fail "--verify must pass with --allow-public-fork-exposure"

missing_rg_rc=0
RUNNER_GROUPS_JSON="$MIXED_GROUPS" \
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  "$SETUP_SCRIPT" --verify --runner-group no-such-group >/dev/null 2>&1 || missing_rg_rc=$?
[ "$missing_rg_rc" -eq 5 ] || fail "missing --runner-group must exit 5 (got $missing_rg_rc)"

: > "$TMP/config.log"
RUNNER_GROUPS_JSON="$MIXED_GROUPS" FORK_APPROVAL_JSON='{"approval_policy":"first_time_contributors"}' \
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  "$SETUP_SCRIPT" --reconfigure --runner-group macos-restricted >/dev/null || fail "restricted runner group with allows_public_repositories=false must pass"
grep -q -- '--runnergroup macos-restricted' "$TMP/config.log" || fail "reconfigure with --runner-group must pass --runnergroup to config.sh"

# Repo-scoped fork protection checks.
pub_repo_rc=0
REPO_META_JSON='{"private":false}' FORK_APPROVAL_JSON='{"approval_policy":"first_time_contributors"}' \
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  "$SETUP_SCRIPT" --reconfigure --repo jleechanorg/pub >/dev/null 2>&1 || pub_repo_rc=$?
[ "$pub_repo_rc" -eq 5 ] || fail "public --repo with first_time_contributors must exit 5 (got $pub_repo_rc)"
pass "server-side fork protection, --runner-group, --allow-public-fork-exposure, and --repo checks hold"

# 15. Two-contender concurrent stale-lock recovery proves mutual exclusion across critical section.
HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" \
  "$SETUP_SCRIPT" --uninstall >/dev/null
mkdir -p "$LOCK_DIR_T"
printf '%s\n' "$holder_pid" > "$LOCK_DIR_T/pid"
date +%s > "$LOCK_DIR_T/ts"
: > "$TMP/setup-race.trace"
LAUNCHCTL_RACE_TAG=1 LAUNCHCTL_TRACE_FILE="$TMP/setup-race.trace" LAUNCHCTL_TRACE_SLEEP=0.5 \
  SETUP_LOCK_TIMEOUT_SEC=10 HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" \
  "$SETUP_SCRIPT" --uninstall >/dev/null &
spid1=$!
LAUNCHCTL_RACE_TAG=2 LAUNCHCTL_TRACE_FILE="$TMP/setup-race.trace" LAUNCHCTL_TRACE_SLEEP=0.5 \
  SETUP_LOCK_TIMEOUT_SEC=10 HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" \
  "$SETUP_SCRIPT" --uninstall >/dev/null &
spid2=$!
src1=0; wait "$spid1" || src1=$?
src2=0; wait "$spid2" || src2=$?
[ "$src1" -eq 0 ] && [ "$src2" -eq 0 ] || fail "two-contender setup lock recovery must succeed for both contenders (rc1=$src1 rc2=$src2)"
[ ! -d "$LOCK_DIR_T" ] && [ ! -d "${LOCK_DIR_T}.reclaim" ] || fail "setup lockdir and reclaim mutex must both be released"
TRACE_FILE="$TMP/setup-race.trace" python3 - <<'PY' || fail "two-contender setup lock allowed concurrent entry"
import os
from pathlib import Path
lines = [l.strip() for l in Path(os.environ["TRACE_FILE"]).read_text().splitlines() if l.strip()]
assert len(lines) == 4, f"expected 4 trace lines, got {lines!r}"
assert lines[0].startswith("ENTER ") and lines[1] == "EXIT " + lines[0].split()[1], f"overlap detected: {lines!r}"
assert lines[2].startswith("ENTER ") and lines[3] == "EXIT " + lines[2].split()[1], f"overlap detected: {lines!r}"
assert lines[0].split()[1] != lines[2].split()[1], f"expected two distinct contenders: {lines!r}"
PY
pass "two-contender setup stale-lock recovery enforces mutual exclusion"
