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
grep -q 'ACTIONS_RUNNER_INPUT_TOKEN=<redacted>' <<<"$dry_out" || fail "dry-run CONFIG_CMD must pass token via ACTIONS_RUNNER_INPUT_TOKEN"
! grep -q -- '--token' <<<"$dry_out" || fail "dry-run CONFIG_CMD must never pass --token in argv"
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
mkdir -p "$RUNNER_DIR_T/bin" "$RUNNER_DIR_T/externals"
: > "$RUNNER_DIR_T/env.sh"
cat > "$RUNNER_DIR_T/bin/Runner.Listener" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$RUNNER_DIR_T/bin/Runner.Listener"

cat > "$RUNNER_DIR_T/config.sh" <<STUB
#!/usr/bin/env bash
set -euo pipefail
if [ -z "\${ACTIONS_RUNNER_INPUT_TOKEN:-}" ]; then
  echo "config.sh error: missing ACTIONS_RUNNER_INPUT_TOKEN" >&2
  exit 1
fi
if [ -e "$RUNNER_DIR_T/.runner" ] || [ -e "$RUNNER_DIR_T/.credentials" ] || [ -e "$RUNNER_DIR_T/.credentials_rsaparams" ]; then
  echo "ConfigurationManager error: runner is already configured" >&2
  exit 1
fi
printf 'config.sh %s\n' "\$*" >> "$TMP/config.log"
printf '{"agentId":101,"agentName":"mac-native-ci-1","workFolder":"%s","gitHubUrl":"https://github.com/jleechanorg"}\n' "$TMP/scratch/native-macos-ci-work" > "$RUNNER_DIR_T/.runner"
printf 'creds\n' > "$RUNNER_DIR_T/.credentials"
printf 'rsa\n' > "$RUNNER_DIR_T/.credentials_rsaparams"
if [ -n "\${CONFIG_RAN_MARKER:-}" ]; then
  : > "\$CONFIG_RAN_MARKER"
fi
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
lookup_repo_map() {
  local map="$1" target="$2" entry
  local IFS=','
  for entry in $map; do
    if [ "${entry%%=*}" = "$target" ]; then
      printf '%s' "${entry#*=}"
      return 0
    fi
  done
  return 1
}
case "$*" in
  *"actions/runners/registration-token"*)
    emit_json '{"token":"stub-reg-token"}'
    ;;
  *"actions/runner-groups/"*"/runners"*)
    default_group_runners='{"total_count":1,"runners":[{"id":101,"name":"mac-native-ci-1"}]}'
    emit_json "${GROUP_RUNNERS_JSON:-$default_group_runners}"
    ;;
  *"actions/runner-groups/"*"/repositories"*)
    default_group_repos='{"total_count":0,"repositories":[]}'
    emit_json "${GROUP_REPOS_JSON:-$default_group_repos}"
    ;;
  *"actions/runner-groups"*)
    default_groups='{"total_count":1,"runner_groups":[{"id":1,"name":"Default","default":true,"allows_public_repositories":false}]}'
    emit_json "${RUNNER_GROUPS_JSON:-$default_groups}"
    ;;
  *"orgs/"*"/repos"*)
    emit_json "${ORG_REPOS_JSON:-[]}"
    ;;
  *"repos/"*"/actions/permissions/fork-pr-contributor-approval"*)
    repo_slug="$(printf '%s' "$*" | sed -E 's#.*repos/[^/]+/([^/]+)/actions/permissions/fork-pr-contributor-approval.*#\1#')"
    default_policy='{"approval_policy":"first_time_contributors"}'
    if [ -n "${REPO_FORK_APPROVAL_MAP:-}" ] && mapped_pol="$(lookup_repo_map "$REPO_FORK_APPROVAL_MAP" "$repo_slug")"; then
      emit_json "{\"approval_policy\":\"${mapped_pol}\"}"
    else
      emit_json "${REPO_FORK_APPROVAL_JSON:-${FORK_APPROVAL_JSON:-$default_policy}}"
    fi
    ;;
  *"repos/"*"/actions/permissions"*)
    repo_slug="$(printf '%s' "$*" | sed -E 's#.*repos/[^/]+/([^/]+)/actions/permissions.*#\1#')"
    if [ -n "${REPO_ACTIONS_PERMS_MAP:-}" ] && mapped_en="$(lookup_repo_map "$REPO_ACTIONS_PERMS_MAP" "$repo_slug")"; then
      emit_json "{\"enabled\":${mapped_en}}"
    else
      emit_json "${REPO_ACTIONS_PERMS_JSON:-{\"enabled\":true}}"
    fi
    ;;
  *"actions/permissions/fork-pr-contributor-approval"*)
    default_policy='{"approval_policy":"first_time_contributors"}'
    emit_json "${FORK_APPROVAL_JSON:-$default_policy}"
    ;;
  *"actions/runners"*)
    default_live='{"runners":[{"id":101,"name":"mac-native-ci-1","labels":[{"name":"self-hosted-native-macos"}]}]}'
    if [ -n "${LIVE_RUNNERS_POST_CONFIG_JSON:-}" ] && [ -n "${CONFIG_RAN_MARKER:-}" ] && [ -f "$CONFIG_RAN_MARKER" ]; then
      emit_json "$LIVE_RUNNERS_POST_CONFIG_JSON"
    else
      emit_json "${LIVE_RUNNERS_JSON:-$default_live}"
    fi
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
! grep -q -- '--token' "$TMP/config.log" || fail "config.sh must never receive --token in argv"
[ "$(tr -d '\r\n' < "$RUNNER_DIR_T/.ezgha-labels")" = "self-hosted-native-macos" ] || fail ".ezgha-labels must persist configured labels"
first_unload_line="$(grep -n "launchctl unload $PLIST_T" "$TMP/launchctl.log" | head -n1 | cut -d: -f1 || true)"
[ -n "$first_unload_line" ] || fail "reconfigure must unload existing LaunchAgent"

# --verify passes when SessionCreate=true, .ezgha-labels matches, and live GitHub labels match.
HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  "$SETUP_SCRIPT" --verify >/dev/null

# --verify fails if live GitHub runner has forbidden 'self-hosted' or 'worldai-testflight-native-mac' or mismatched labels.
for bad_live in \
  '{"runners":[{"id":101,"name":"mac-native-ci-1","labels":[{"name":"self-hosted-native-macos"},{"name":"self-hosted"}]}]}' \
  '{"runners":[{"id":101,"name":"mac-native-ci-1","labels":[{"name":"worldai-testflight-native-mac"}]}]}' \
  '{"runners":[{"id":101,"name":"mac-native-ci-1","labels":[{"name":"other-label"}]}]}'; do
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

# Fresh account without pre-existing ~/Library/LaunchAgents must still succeed.
FRESH_HOME="$TMP/fresh-home"
mkdir -p "$FRESH_HOME"
BASH_ENV=/dev/null HOME="$FRESH_HOME" PATH="$TMP/bin:$PATH" \
  bash "$INSTALL_LAUNCHAGENTS" install org.jleechanorg.ezgha-gh-actions-cost-alert >/dev/null
test -f "$FRESH_HOME/Library/LaunchAgents/org.jleechanorg.ezgha-gh-actions-cost-alert.plist" || \
  fail "fresh account without Library/LaunchAgents must succeed and render cost-alert plist"
if compgen -G "$TMP/home/.local/state/ezgha/.gh-actions-cost-alert.sh.backup.*" >/dev/null; then
  fail "successful cost-alert install must remove script backup"
fi

# Failed launchctl load for org.jleechanorg.ezgha-gh-actions-cost-alert must roll back BOTH plist and libexec script.
COST_FAIL_HOME="$TMP/cost-fail-home"
COST_FAIL_BIN="$TMP/cost-fail-bin"
mkdir -p "$COST_FAIL_HOME/Library/LaunchAgents" "$COST_FAIL_HOME/.local/libexec/ezgha" "$COST_FAIL_BIN"
printf 'prior-cost-plist\n' > "$COST_FAIL_HOME/Library/LaunchAgents/org.jleechanorg.ezgha-gh-actions-cost-alert.plist"
printf 'prior-cost-script\n' > "$COST_FAIL_HOME/.local/libexec/ezgha/gh-actions-cost-alert.sh"
chmod +x "$COST_FAIL_HOME/.local/libexec/ezgha/gh-actions-cost-alert.sh"
cat > "$COST_FAIL_BIN/launchctl" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "load" ] && [[ "${2:-}" == *gh-actions-cost-alert.plist ]]; then
  exit 42
fi
exit 0
STUB
chmod +x "$COST_FAIL_BIN/launchctl"
cost_fail_rc=0
BASH_ENV=/dev/null HOME="$COST_FAIL_HOME" PATH="$COST_FAIL_BIN:$PATH" \
  bash "$INSTALL_LAUNCHAGENTS" install org.jleechanorg.ezgha-gh-actions-cost-alert >/dev/null 2>&1 || cost_fail_rc=$?
[ "$cost_fail_rc" -eq 42 ] || fail "failed cost-alert load must exit 42 (got $cost_fail_rc)"
[ "$(cat "$COST_FAIL_HOME/Library/LaunchAgents/org.jleechanorg.ezgha-gh-actions-cost-alert.plist")" = "prior-cost-plist" ] || \
  fail "failed cost-alert load must restore prior plist"
[ "$(cat "$COST_FAIL_HOME/.local/libexec/ezgha/gh-actions-cost-alert.sh")" = "prior-cost-script" ] || \
  fail "failed cost-alert load must restore prior gh-actions-cost-alert.sh"
if compgen -G "$COST_FAIL_HOME/.local/state/ezgha/.gh-actions-cost-alert.sh.backup.*" >/dev/null; then
  fail "failed cost-alert load must clean up temporary script backup"
fi
pass "label-scoped install of org.jleechanorg.ezgha-gh-actions-cost-alert preserves incumbents, rolls back script+plist on load failure, handles fresh account, and renders valid plist"

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

printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/outside-runsvc.sh"
chmod +x "$TMP/outside-runsvc.sh"
ln -sfn "$TMP/outside-runsvc.sh" "$RUNNER_DIR_T/runsvc.sh"
if HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
    "$SETUP_SCRIPT" --verify --offline >/dev/null 2>&1; then
  fail "--verify must reject runsvc.sh symlinked outside RUNNER_DIR"
fi
rm -f "$RUNNER_DIR_T/runsvc.sh"

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
mkdir -p "$TMP/home/actions-runner/bin" "$TMP/home/actions-runner/externals"
cp "$RUNNER_DIR_T/bin/Runner.Listener" "$TMP/home/actions-runner/bin/Runner.Listener"
cp "$RUNNER_DIR_T/config.sh" "$TMP/home/actions-runner/config.sh"
cp "$RUNNER_DIR_T/run.sh" "$TMP/home/actions-runner/run.sh"
cp "$RUNNER_DIR_T/run-helper.sh.template" "$TMP/home/actions-runner/run-helper.sh.template"
cp "$RUNNER_DIR_T/env.sh" "$TMP/home/actions-runner/env.sh"
rm -f "${RUNNER_DIR_T:?}/config.sh" "${RUNNER_DIR_T:?}/run.sh" "${RUNNER_DIR_T:?}/run-helper.sh.template" "${RUNNER_DIR_T:?}/env.sh"
rm -rf "${RUNNER_DIR_T:?}/externals"
if HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
    "$SETUP_SCRIPT" --verify --offline >/dev/null 2>&1; then
  fail "--verify must fail when env.sh or externals is missing"
fi
: > "$TMP/launchctl.log"
: > "$TMP/launchctl.loaded"
HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  EXISTING_RUNNER_DIR="$TMP/home/actions-runner" "$SETUP_SCRIPT" >/dev/null
[ -x "$RUNNER_DIR_T/config.sh" ] && [ -x "$RUNNER_DIR_T/run.sh" ] && [ -f "$RUNNER_DIR_T/env.sh" ] && [ -d "$RUNNER_DIR_T/externals" ] || fail "incomplete provisioning must repair config.sh, run.sh, env.sh, and externals on retry"
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

# 11. Kernel flock serializes mutating operations, ignores --dry-run/--verify, and releases immediately on SIGKILL.
LOCK_FILE_T="$TMP/home/.local/state/ezgha/setup-native-macos-runner.org.jleechanorg.ezgha-native-macos-runner.flock"
rm -f "$TMP/setup-flock.ready"
python3 - "$LOCK_FILE_T" "$TMP/setup-flock.ready" <<'PY' &
import fcntl, sys, time
from pathlib import Path

lock_path = Path(sys.argv[1])
ready_path = Path(sys.argv[2])
lock_path.parent.mkdir(parents=True, exist_ok=True)
f = open(lock_path, "a+")
fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
ready_path.write_text("locked\n")
time.sleep(30)
PY
holder_pid=$!
while [ ! -f "$TMP/setup-flock.ready" ]; do sleep 0.05; done

HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh" \
  "$SETUP_SCRIPT" --dry-run >/dev/null || fail "--dry-run must not block on lifecycle flock"
printf '{"agentId":101,"agentName":"mac-native-ci-1","workFolder":"%s","gitHubUrl":"https://github.com/jleechanorg"}\n' "$TMP/scratch/native-macos-ci-work" > "$RUNNER_DIR_T/.runner"
: > "$TMP/launchctl.loaded"
HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh" \
  "$SETUP_SCRIPT" --verify --offline >/dev/null || fail "--verify --offline must not block on lifecycle flock"

setup_lockto_rc=0
SETUP_LOCK_TIMEOUT_SEC=1 HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" \
  "$SETUP_SCRIPT" --uninstall >/dev/null 2>"$TMP/setup-lockto.err" || setup_lockto_rc=$?
if [ "$setup_lockto_rc" -eq 0 ]; then
  kill -9 "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  fail "mutating --uninstall must fail when lifecycle flock is held by a live process"
fi
grep -q 'ERROR: timed out waiting for setup lock' "$TMP/setup-lockto.err" || {
  kill -9 "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  fail "setup lock timeout must print ERROR: timed out waiting for setup lock on stderr (got: $(cat "$TMP/setup-lockto.err"))"
}

# SIGKILL active flock holder -> next mutating --uninstall immediately acquires the kernel lock and succeeds.
kill -9 "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true
SETUP_LOCK_TIMEOUT_SEC=5 HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" \
  "$SETUP_SCRIPT" --uninstall >/dev/null || fail "mutating --uninstall must immediately acquire kernel flock after SIGKILL of holder"
[ -f "$LOCK_FILE_T" ] || fail "flock inode must remain intact after release"
[ ! -d "${LOCK_FILE_T%.flock}.lock" ] || fail "legacy .lock directory must not exist"
pass "kernel flock serializes mutating operations, skips --dry-run/--verify, and releases immediately on SIGKILL"

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
if [ -z "\${ACTIONS_RUNNER_INPUT_TOKEN:-}" ]; then
  echo "config.sh error: missing ACTIONS_RUNNER_INPUT_TOKEN" >&2
  exit 1
fi
printf 'config.sh %s\n' "\$*" >> "$TMP/config.log"
printf '{"agentId":101,"agentName":"mac-native-ci-1","workFolder":"%s","gitHubUrl":"https://github.com/jleechanorg"}\n' "$TMP/scratch/native-macos-ci-work" > "$RUNNER_DIR_T/.runner"
printf 'creds\n' > "$RUNNER_DIR_T/.credentials"
printf 'rsa\n' > "$RUNNER_DIR_T/.credentials_rsaparams"
if [ -n "\${CONFIG_RAN_MARKER:-}" ]; then
  : > "\$CONFIG_RAN_MARKER"
fi
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

PUB_OPEN_GROUPS='{"total_count":1,"runner_groups":[{"id":1,"name":"Default","default":true,"allows_public_repositories":true,"restricted_to_workflows":false,"selected_workflows":[]}]}'
PUB_WF_EMPTY_GROUPS='{"total_count":1,"runner_groups":[{"id":1,"name":"Default","default":true,"allows_public_repositories":true,"restricted_to_workflows":true,"selected_workflows":[]}]}'
PUB_WF_RESTRICTED_GROUPS='{"total_count":1,"runner_groups":[{"id":1,"name":"Default","default":true,"allows_public_repositories":true,"restricted_to_workflows":true,"selected_workflows":["jleechanorg/disk_magician/.github/workflows/ci.yml@refs/heads/main"]}]}'
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
RUNNER_GROUPS_JSON="$PUB_OPEN_GROUPS" FORK_APPROVAL_JSON='{"approval_policy":"all_external_contributors"}' \
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  "$SETUP_SCRIPT" --verify >/dev/null 2>&1 || vfork_rc=$?
[ "$vfork_rc" -eq 5 ] || fail "--verify with allows_public_repositories=true + restricted_to_workflows=false must exit 5 even with all_external_contributors (got $vfork_rc)"

vfork_empty_rc=0
RUNNER_GROUPS_JSON="$PUB_WF_EMPTY_GROUPS" FORK_APPROVAL_JSON='{"approval_policy":"all_external_contributors"}' \
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  "$SETUP_SCRIPT" --verify >/dev/null 2>&1 || vfork_empty_rc=$?
[ "$vfork_empty_rc" -eq 5 ] || fail "--verify with allows_public_repositories=true + empty selected_workflows must exit 5 (got $vfork_empty_rc)"

RUNNER_GROUPS_JSON="$PUB_WF_RESTRICTED_GROUPS" FORK_APPROVAL_JSON='{"approval_policy":"all_external_contributors"}' \
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  "$SETUP_SCRIPT" --verify >/dev/null || fail "--verify must pass with restricted_to_workflows=true + selected_workflows + all_external_contributors"

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
REPO_META_JSON='{"private":false}' FORK_APPROVAL_JSON='{"approval_policy":"all_external_contributors"}' \
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  "$SETUP_SCRIPT" --reconfigure --repo jleechanorg/pub >/dev/null 2>&1 || pub_repo_rc=$?
[ "$pub_repo_rc" -eq 5 ] || fail "public --repo must exit 5 without --allow-public-fork-exposure even when all_external_contributors is set (got $pub_repo_rc)"

REPO_META_JSON='{"private":false}' FORK_APPROVAL_JSON='{"approval_policy":"all_external_contributors"}' \
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  "$SETUP_SCRIPT" --reconfigure --repo jleechanorg/pub --allow-public-fork-exposure >/dev/null || fail "public --repo with --allow-public-fork-exposure must succeed"
RUNNER_GROUPS_JSON="$MIXED_GROUPS" FORK_APPROVAL_JSON='{"approval_policy":"first_time_contributors"}' \
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  "$SETUP_SCRIPT" --reconfigure --runner-group macos-restricted >/dev/null || fail "restoring restricted runner group after --repo check must pass"
pass "server-side fork protection, --runner-group, --allow-public-fork-exposure, and --repo checks hold"

# 15. Two-contender concurrent mutating runs prove kernel flock mutual exclusion across critical section.
HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" \
  "$SETUP_SCRIPT" --uninstall >/dev/null
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
[ "$src1" -eq 0 ] && [ "$src2" -eq 0 ] || fail "two-contender setup flock must succeed for both contenders (rc1=$src1 rc2=$src2)"
[ -f "$LOCK_FILE_T" ] && [ ! -d "${LOCK_FILE_T%.flock}.lock" ] && [ ! -d "${LOCK_FILE_T%.flock}.lock.reclaim" ] || fail "setup flock must leave no legacy lockdir"
TRACE_FILE="$TMP/setup-race.trace" python3 - <<'PY' || fail "two-contender setup flock allowed concurrent entry"
import os
from pathlib import Path
lines = [l.strip() for l in Path(os.environ["TRACE_FILE"]).read_text().splitlines() if l.strip()]
assert len(lines) == 4, f"expected 4 trace lines, got {lines!r}"
assert lines[0].startswith("ENTER ") and lines[1] == "EXIT " + lines[0].split()[1], f"overlap detected: {lines!r}"
assert lines[2].startswith("ENTER ") and lines[3] == "EXIT " + lines[2].split()[1], f"overlap detected: {lines!r}"
assert lines[0].split()[1] != lines[2].split()[1], f"expected two distinct contenders: {lines!r}"
PY
pass "two-contender setup kernel flock enforces mutual exclusion"

# 16. Round-11 P0 hardening: --offline mutating rejection, ALLOW_PUBLIC_FORK_EXPOSURE validation,
#     .ezgha-group + agentId + live group membership binding, and lstart-based live lock protection.
offline_rc=0
HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  "$SETUP_SCRIPT" --offline >/dev/null 2>&1 || offline_rc=$?
[ "$offline_rc" -eq 2 ] || fail "--offline without --verify/--dry-run must exit 2 (got $offline_rc)"

offline_reconfig_rc=0
HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  "$SETUP_SCRIPT" --offline --reconfigure >/dev/null 2>&1 || offline_reconfig_rc=$?
[ "$offline_reconfig_rc" -eq 2 ] || fail "--offline --reconfigure must exit 2 (got $offline_reconfig_rc)"

bad_exposure_rc=0
ALLOW_PUBLIC_FORK_EXPOSURE=true HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  "$SETUP_SCRIPT" --dry-run >/dev/null 2>&1 || bad_exposure_rc=$?
[ "$bad_exposure_rc" -eq 2 ] || fail "ALLOW_PUBLIC_FORK_EXPOSURE=true must exit 2 (got $bad_exposure_rc)"

# Changing --runner-group triggers reconfiguration and --verify enforces .ezgha-group, agentId, and live group membership.
cp "$TMP/plist.ok" "$PLIST_T"
: > "$TMP/launchctl.loaded"
[ "$(tr -d '\r\n' < "$RUNNER_DIR_T/.ezgha-group")" = "macos-restricted" ] || fail ".ezgha-group must persist configured group from test 14"

# Same group again is idempotent (no config.sh rerun).
: > "$TMP/config.log"
RUNNER_GROUPS_JSON="$MIXED_GROUPS" FORK_APPROVAL_JSON='{"approval_policy":"first_time_contributors"}' \
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  "$SETUP_SCRIPT" --runner-group macos-restricted >/dev/null
[ ! -s "$TMP/config.log" ] || fail "matching --runner-group must not re-run config.sh"

# Switching from macos-restricted to default triggers reconfiguration, and switching back to macos-restricted triggers --runnergroup.
: > "$TMP/config.log"
RUNNER_GROUPS_JSON="$MIXED_GROUPS" FORK_APPROVAL_JSON='{"approval_policy":"first_time_contributors"}' \
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  "$SETUP_SCRIPT" --allow-public-fork-exposure >/dev/null
grep -q 'config.sh ' "$TMP/config.log" || fail "changing from --runner-group macos-restricted to default must trigger reconfiguration"
[ "$(tr -d '\r\n' < "$RUNNER_DIR_T/.ezgha-group")" = "" ] || fail ".ezgha-group must be updated on reconfiguration to default"

: > "$TMP/config.log"
RUNNER_GROUPS_JSON="$MIXED_GROUPS" FORK_APPROVAL_JSON='{"approval_policy":"first_time_contributors"}' \
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  "$SETUP_SCRIPT" --runner-group macos-restricted >/dev/null
grep -q -- '--runnergroup macos-restricted' "$TMP/config.log" || fail "changing from default to --runner-group macos-restricted must trigger reconfiguration"
[ "$(tr -d '\r\n' < "$RUNNER_DIR_T/.ezgha-group")" = "macos-restricted" ] || fail ".ezgha-group must persist configured group"

RUNNER_GROUPS_JSON="$MIXED_GROUPS" FORK_APPROVAL_JSON='{"approval_policy":"first_time_contributors"}' \
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  "$SETUP_SCRIPT" --verify --runner-group macos-restricted >/dev/null || fail "--verify with matching --runner-group and group membership must pass"

if RUNNER_GROUPS_JSON="$MIXED_GROUPS" FORK_APPROVAL_JSON='{"approval_policy":"first_time_contributors"}' \
    GROUP_RUNNERS_JSON='{"total_count":0,"runners":[]}' \
    HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
    "$SETUP_SCRIPT" --verify --runner-group macos-restricted >/dev/null 2>&1; then
  fail "--verify must fail when live runner is not a member of org runner group"
fi

if RUNNER_GROUPS_JSON="$MIXED_GROUPS" FORK_APPROVAL_JSON='{"approval_policy":"first_time_contributors"}' \
    LIVE_RUNNERS_JSON='{"runners":[{"id":999,"name":"mac-native-ci-1","labels":[{"name":"self-hosted-native-macos"}]}]}' \
    HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
    "$SETUP_SCRIPT" --verify --runner-group macos-restricted >/dev/null 2>&1; then
  fail "--verify must fail when local .runner agentId mismatches live runner id"
fi

if RUNNER_GROUPS_JSON="$MIXED_GROUPS" FORK_APPROVAL_JSON='{"approval_policy":"first_time_contributors"}' \
    HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
    "$SETUP_SCRIPT" --verify >/dev/null 2>&1; then
  fail "--verify must fail when .ezgha-group mismatches requested default group"
fi

rm -f "$RUNNER_DIR_T/.ezgha-group"
if HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
    "$SETUP_SCRIPT" --verify --offline --runner-group macos-restricted >/dev/null 2>&1; then
  fail "--verify must fail closed when .ezgha-group is missing for --runner-group"
fi
printf 'macos-restricted\n' > "$RUNNER_DIR_T/.ezgha-group"
pass "flag validation and runner-group/agentId binding hold"

# 17. Isolating top-level symlinks from EXISTING_RUNNER_DIR (e.g., bin -> $EXISTING_RUNNER_DIR/bin.2.338.2)
#     and enforcing chmod 600 on .credentials / .credentials_rsaparams after config.sh.
EXISTING_SYM="$TMP/existing-sym-runner"
ISOLATED_SYM="$TMP/home/isolated-sym-runner"
mkdir -p "$EXISTING_SYM/bin.2.338.2" "$EXISTING_SYM/externals.2.338.2/node20/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$EXISTING_SYM/bin.2.338.2/Runner.Listener"
chmod +x "$EXISTING_SYM/bin.2.338.2/Runner.Listener"
printf '#!/usr/bin/env bash\nexit 0\n' > "$EXISTING_SYM/externals.2.338.2/node20/bin/node"
chmod +x "$EXISTING_SYM/externals.2.338.2/node20/bin/node"
ln -sfn "$EXISTING_SYM/bin.2.338.2" "$EXISTING_SYM/bin"
ln -sfn "$EXISTING_SYM/externals.2.338.2" "$EXISTING_SYM/externals"
cat > "$EXISTING_SYM/config.sh" <<STUB
#!/usr/bin/env bash
set -euo pipefail
if [ -z "\${ACTIONS_RUNNER_INPUT_TOKEN:-}" ]; then
  echo "config.sh error: missing ACTIONS_RUNNER_INPUT_TOKEN" >&2
  exit 1
fi
printf 'config.sh %s\n' "\$*" >> "$TMP/config.log"
printf '{"agentId":101,"agentName":"mac-native-ci-1","workFolder":"%s","gitHubUrl":"https://github.com/jleechanorg"}\n' "$TMP/scratch/native-macos-ci-work" > "\$(pwd)/.runner"
umask 022
printf 'creds\n' > "\$(pwd)/.credentials"
printf 'rsa\n' > "\$(pwd)/.credentials_rsaparams"
if [ -n "\${CONFIG_RAN_MARKER:-}" ]; then
  : > "\$CONFIG_RAN_MARKER"
fi
STUB
chmod +x "$EXISTING_SYM/config.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$EXISTING_SYM/run.sh"
chmod +x "$EXISTING_SYM/run.sh"
: > "$EXISTING_SYM/run-helper.sh.template"
: > "$EXISTING_SYM/env.sh"

rm -f "$TMP/config-ran-17"
CONFIG_RAN_MARKER="$TMP/config-ran-17" \
  LIVE_RUNNERS_JSON='{"runners":[]}' \
  LIVE_RUNNERS_POST_CONFIG_JSON='{"runners":[{"id":101,"name":"mac-native-ci-1","labels":[{"name":"self-hosted-native-macos"}]}]}' \
  RUNNER_GROUPS_JSON="$MIXED_GROUPS" FORK_APPROVAL_JSON='{"approval_policy":"first_time_contributors"}' \
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  EXISTING_RUNNER_DIR="$EXISTING_SYM" "$SETUP_SCRIPT" --runner-dir "$ISOLATED_SYM" --runner-group macos-restricted >/dev/null

[ -L "$ISOLATED_SYM/bin" ] || fail "cloned bin must be a symlink"
[ "$(readlink "$ISOLATED_SYM/bin")" = "bin.2.338.2" ] || fail "cloned bin symlink must be relative bin.2.338.2 (got: $(readlink "$ISOLATED_SYM/bin"))"
[ -L "$ISOLATED_SYM/externals" ] || fail "cloned externals must be a symlink"
[ "$(readlink "$ISOLATED_SYM/externals")" = "externals.2.338.2" ] || fail "cloned externals symlink must be relative externals.2.338.2 (got: $(readlink "$ISOLATED_SYM/externals"))"
ISOLATED_SYM="$ISOLATED_SYM" EXISTING_SYM="$EXISTING_SYM" python3 - <<'PY' || fail "cloned symlink resolution or credential permissions check failed"
import os
from pathlib import Path

isolated = Path(os.environ["ISOLATED_SYM"]).resolve()
existing = Path(os.environ["EXISTING_SYM"]).resolve()
bin_real = (isolated / "bin").resolve()
ext_real = (isolated / "externals").resolve()
assert bin_real == isolated / "bin.2.338.2", f"bin resolved to {bin_real}, expected {isolated / 'bin.2.338.2'}"
assert ext_real == isolated / "externals.2.338.2", f"externals resolved to {ext_real}, expected {isolated / 'externals.2.338.2'}"
assert existing not in bin_real.parents and bin_real != existing, f"bin leaked into existing runner dir: {bin_real}"
assert existing not in ext_real.parents and ext_real != existing, f"externals leaked into existing runner dir: {ext_real}"
for cred in (".credentials", ".credentials_rsaparams"):
    mode = os.stat(isolated / cred).st_mode & 0o777
    assert mode == 0o600, f"{cred} mode={oct(mode)}, expected 0o600"
PY
pass "cloned absolute symlinks resolve inside RUNNER_DIR as relative symlinks and credentials are chmod 600"

# 18. --repo/--runner-group mutual exclusion, per-repo fork-approval override check, strict numeric agentId,
#     and normal setup live GitHub drift detection + post-config verification.
rg_repo_rc=0
HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  "$SETUP_SCRIPT" --dry-run --repo jleechanorg/pub --runner-group Default >/dev/null 2>&1 || rg_repo_rc=$?
[ "$rg_repo_rc" -eq 2 ] || fail "--repo combined with --runner-group must exit 2 (got $rg_repo_rc)"

rg_env_repo_rc=0
RUNNER_GROUP="Default" HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  "$SETUP_SCRIPT" --dry-run --repo jleechanorg/pub >/dev/null 2>&1 || rg_env_repo_rc=$?
[ "$rg_env_repo_rc" -eq 2 ] || fail "RUNNER_GROUP env var combined with --repo must exit 2 (got $rg_env_repo_rc)"

# Per-repo fork-pr-contributor-approval override must fail closed (exit 5) even when org policy is all_external_contributors.
cp "$TMP/plist.ok" "$PLIST_T"
: > "$TMP/launchctl.loaded"
printf '{"agentId":101,"agentName":"mac-native-ci-1","workFolder":"%s","gitHubUrl":"https://github.com/jleechanorg"}\n' "$TMP/scratch/native-macos-ci-work" > "$RUNNER_DIR_T/.runner"
printf 'self-hosted-native-macos\n' > "$RUNNER_DIR_T/.ezgha-labels"
printf '\n' > "$RUNNER_DIR_T/.ezgha-group"

ORG_REPOS_OVERRIDE='[{"name":"pub-weak","private":false,"archived":false},{"name":"pub-disabled","private":false,"archived":false},{"name":"pub-arch","private":false,"archived":true}]'
pub_override_rc=0
pub_override_err="$(
  RUNNER_GROUPS_JSON="$PUB_WF_RESTRICTED_GROUPS" \
  FORK_APPROVAL_JSON='{"approval_policy":"all_external_contributors"}' \
  ORG_REPOS_JSON="$ORG_REPOS_OVERRIDE" \
  REPO_ACTIONS_PERMS_MAP="pub-disabled=false,pub-weak=true" \
  REPO_FORK_APPROVAL_MAP="pub-weak=first_time_contributors" \
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
    "$SETUP_SCRIPT" --verify 2>&1 >/dev/null
)" || pub_override_rc=$?
[ "$pub_override_rc" -eq 5 ] || fail "per-repo fork-approval override must exit 5 on --verify (got $pub_override_rc)"
grep -q 'jleechanorg/pub-weak' <<<"$pub_override_err" || fail "per-repo failure must name offending repo jleechanorg/pub-weak (got: $pub_override_err)"

RUNNER_GROUPS_JSON="$PUB_WF_RESTRICTED_GROUPS" \
FORK_APPROVAL_JSON='{"approval_policy":"all_external_contributors"}' \
ORG_REPOS_JSON="$ORG_REPOS_OVERRIDE" \
REPO_ACTIONS_PERMS_MAP="pub-disabled=false,pub-weak=true" \
REPO_FORK_APPROVAL_MAP="pub-weak=all_external_contributors" \
HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  "$SETUP_SCRIPT" --verify >/dev/null || fail "--verify must pass when org and enabled public repos use all_external_contributors"

# Selected-visibility runner group with allows_public_repositories=true checks group repositories endpoint.
SEL_PUB_GROUPS='{"total_count":1,"runner_groups":[{"id":7,"name":"sel-pub","default":false,"visibility":"selected","allows_public_repositories":true,"restricted_to_workflows":true,"selected_workflows":["jleechanorg/pub-weak/.github/workflows/ci.yml@refs/heads/main"]}]}'
GROUP_REPOS_SEL='{"total_count":1,"repositories":[{"name":"pub-weak","private":false,"archived":false}]}'
printf 'sel-pub\n' > "$RUNNER_DIR_T/.ezgha-group"
sel_override_rc=0
RUNNER_GROUPS_JSON="$SEL_PUB_GROUPS" \
GROUP_REPOS_JSON="$GROUP_REPOS_SEL" \
FORK_APPROVAL_JSON='{"approval_policy":"all_external_contributors"}' \
REPO_ACTIONS_PERMS_MAP="pub-weak=true" \
REPO_FORK_APPROVAL_MAP="pub-weak=first_time_contributors" \
HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  "$SETUP_SCRIPT" --verify --runner-group sel-pub >/dev/null 2>&1 || sel_override_rc=$?
[ "$sel_override_rc" -eq 5 ] || fail "selected-visibility group with weak public repo must exit 5 (got $sel_override_rc)"
printf 'macos-restricted\n' > "$RUNNER_DIR_T/.ezgha-group"

# Missing or non-numeric .runner agentId must fail closed (never fall back to name-only matching).
printf '{"agentName":"mac-native-ci-1","workFolder":"%s","gitHubUrl":"https://github.com/jleechanorg"}\n' "$TMP/scratch/native-macos-ci-work" > "$RUNNER_DIR_T/.runner"
if RUNNER_GROUPS_JSON="$MIXED_GROUPS" FORK_APPROVAL_JSON='{"approval_policy":"first_time_contributors"}' \
    HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
    "$SETUP_SCRIPT" --verify --runner-group macos-restricted >/dev/null 2>&1; then
  fail "--verify must reject .runner without numeric agentId (no name-only fallback)"
fi
if HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
    "$SETUP_SCRIPT" --verify --offline --runner-group macos-restricted >/dev/null 2>&1; then
  fail "--verify --offline must reject .runner without numeric agentId"
fi

# Normal setup detects live GitHub drift (missing runner / wrong group / wrong labels) when local metadata matches,
# triggers reconfiguration, and fails closed if post-config live state still mismatches.
printf '{"agentId":101,"agentName":"mac-native-ci-1","workFolder":"%s","gitHubUrl":"https://github.com/jleechanorg"}\n' "$TMP/scratch/native-macos-ci-work" > "$RUNNER_DIR_T/.runner"
: > "$TMP/config.log"
rm -f "$TMP/config-ran-18"
CONFIG_RAN_MARKER="$TMP/config-ran-18" \
  RUNNER_GROUPS_JSON="$MIXED_GROUPS" FORK_APPROVAL_JSON='{"approval_policy":"first_time_contributors"}' \
  LIVE_RUNNERS_JSON='{"runners":[]}' \
  LIVE_RUNNERS_POST_CONFIG_JSON='{"runners":[{"id":101,"name":"mac-native-ci-1","labels":[{"name":"self-hosted-native-macos"}]}]}' \
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  "$SETUP_SCRIPT" --runner-group macos-restricted >/dev/null
grep -q 'config.sh ' "$TMP/config.log" || fail "normal setup must reconfigure when live runner is missing on GitHub"
! grep -q -- '--replace' "$TMP/config.log" || fail "normal setup must NOT pass --replace when no live runner has RUNNER_NAME"

: > "$TMP/config.log"
bad_post_rc=0
RUNNER_GROUPS_JSON="$MIXED_GROUPS" FORK_APPROVAL_JSON='{"approval_policy":"first_time_contributors"}' \
  GROUP_RUNNERS_JSON='{"total_count":0,"runners":[]}' \
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  "$SETUP_SCRIPT" --runner-group macos-restricted >/dev/null 2>&1 || bad_post_rc=$?
[ "$bad_post_rc" -eq 4 ] || fail "normal setup must fail closed (exit 4) when runner remains outside target group after config.sh (got $bad_post_rc)"
grep -q 'config.sh ' "$TMP/config.log" || fail "normal setup must detect out-of-group drift and invoke config.sh"
[ ! -e "$TMP/launchctl.loaded" ] || fail "failed post-config verification must leave LaunchAgent stopped"
pass "--repo/--runner-group exclusion, per-repo fork-approval overrides, strict agentId, and normal-setup live drift checks pass"

# 19. Post-config.sh API absence fails closed (exit 4) without calling launchctl load and preserves backup.
rm -rf "${RUNNER_DIR_T:?}"/.backup-pre-reconfigure.*
printf '{"agentId":101,"agentName":"mac-native-ci-1","workFolder":"%s","gitHubUrl":"https://github.com/jleechanorg"}\n' "$TMP/scratch/native-macos-ci-work" > "$RUNNER_DIR_T/.runner"
: > "$TMP/config.log"
: > "$TMP/launchctl.log"
rm -f "$TMP/launchctl.loaded"
post_absent_rc=0
POST_CONFIG_VERIFY_ATTEMPTS=1 POST_CONFIG_VERIFY_SLEEP_SEC=0 \
  RUNNER_GROUPS_JSON="$MIXED_GROUPS" FORK_APPROVAL_JSON='{"approval_policy":"first_time_contributors"}' \
  LIVE_RUNNERS_JSON='{"runners":[]}' \
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  "$SETUP_SCRIPT" --runner-group macos-restricted >/dev/null 2>&1 || post_absent_rc=$?
[ "$post_absent_rc" -eq 4 ] || fail "post-config.sh API absence must exit 4 fail-closed (got $post_absent_rc)"
grep -q 'config.sh ' "$TMP/config.log" || fail "post-config absence test must have invoked config.sh"
! grep -q 'launchctl load' "$TMP/launchctl.log" || fail "post-config API absence must never call launchctl load"
[ ! -e "$TMP/launchctl.loaded" ] || fail "post-config API absence must leave LaunchAgent stopped"
absent_backups=("$RUNNER_DIR_T"/.backup-pre-reconfigure.*)
[ "${#absent_backups[@]}" -eq 1 ] && [ -d "${absent_backups[0]}" ] || fail "post-config API absence must preserve .backup-pre-reconfigure.<pid>"
rm -rf "${RUNNER_DIR_T:?}"/.backup-pre-reconfigure.*
pass "post-config.sh API absence exits 4 fail-closed without calling launchctl load"

# 20. Safe --replace guard: fresh setup refuses live name collision (exit 6), succeeds without --replace when absent,
#     passes --replace when local .runner agentId matches, and never passes --token in argv.
FRESH_COLLIDE="$TMP/home/fresh-collide-runner"
mkdir -p "$FRESH_COLLIDE"
: > "$TMP/config.log"
: > "$TMP/launchctl.log"
rm -f "$TMP/launchctl.loaded"
collide_rc=0
collide_err="$(
  RUNNER_GROUPS_JSON="$MIXED_GROUPS" FORK_APPROVAL_JSON='{"approval_policy":"first_time_contributors"}' \
  LIVE_RUNNERS_JSON='{"runners":[{"id":999,"name":"mac-native-ci-1","labels":[{"name":"self-hosted-native-macos"}]}]}' \
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  EXISTING_RUNNER_DIR="$EXISTING_SYM" \
  "$SETUP_SCRIPT" --runner-dir "$FRESH_COLLIDE" --runner-group macos-restricted 2>&1 >/dev/null
)" || collide_rc=$?
[ "$collide_rc" -eq 6 ] || fail "fresh setup with colliding live runner id=999 must exit 6 (got $collide_rc)"
grep -q '999' <<<"$collide_err" || fail "collision refusal must name conflicting live runner id 999 (got: $collide_err)"
[ ! -s "$TMP/config.log" ] || fail "collision refusal must abort BEFORE invoking config.sh"

: > "$TMP/config.log"
rm -f "$TMP/config-ran-20"
CONFIG_RAN_MARKER="$TMP/config-ran-20" \
  RUNNER_GROUPS_JSON="$MIXED_GROUPS" FORK_APPROVAL_JSON='{"approval_policy":"first_time_contributors"}' \
  LIVE_RUNNERS_JSON='{"runners":[]}' \
  LIVE_RUNNERS_POST_CONFIG_JSON='{"runners":[{"id":101,"name":"mac-native-ci-1","labels":[{"name":"self-hosted-native-macos"}]}]}' \
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  EXISTING_RUNNER_DIR="$EXISTING_SYM" \
  "$SETUP_SCRIPT" --runner-dir "$FRESH_COLLIDE" --runner-group macos-restricted >/dev/null
grep -q 'config.sh ' "$TMP/config.log" || fail "fresh setup without live collision must invoke config.sh"
! grep -q -- '--replace' "$TMP/config.log" || fail "fresh setup without live collision must NOT pass --replace"
! grep -q -- '--token' "$TMP/config.log" || fail "config.sh must never receive --token in argv"

: > "$TMP/config.log"
RUNNER_GROUPS_JSON="$MIXED_GROUPS" FORK_APPROVAL_JSON='{"approval_policy":"first_time_contributors"}' \
  LIVE_RUNNERS_JSON='{"runners":[{"id":101,"name":"mac-native-ci-1","labels":[{"name":"self-hosted-native-macos"}]}]}' \
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  EXISTING_RUNNER_DIR="$EXISTING_SYM" \
  "$SETUP_SCRIPT" --runner-dir "$FRESH_COLLIDE" --reconfigure --runner-group macos-restricted >/dev/null
grep -q -- '--replace' "$TMP/config.log" || fail "--reconfigure with matching local agentId=101 must pass --replace"
! grep -q -- '--token' "$TMP/config.log" || fail "--reconfigure must never pass --token in argv"
pass "safe --replace collision guard and ACTIONS_RUNNER_INPUT_TOKEN handling hold"

# 21. Realpath containment: existing RUNNER_DIR with bin/Runner.Listener symlinked into EXISTING_RUNNER_DIR
#     fails --verify and gets repaired into an isolated copy (including nested symlinks rewritten relatively).
ln -sfn "$EXISTING_SYM/externals.2.338.2/node20/bin/node" "$EXISTING_SYM/bin.2.338.2/nested-node-link"
LEAK_RUNNER="$TMP/home/leak-symlink-runner"
mkdir -p "$LEAK_RUNNER/bin" "$LEAK_RUNNER/externals"
ln -sfn "$EXISTING_SYM/bin.2.338.2/Runner.Listener" "$LEAK_RUNNER/bin/Runner.Listener"
cp "$EXISTING_SYM/config.sh" "$LEAK_RUNNER/config.sh"
cp "$EXISTING_SYM/run.sh" "$LEAK_RUNNER/run.sh"
: > "$LEAK_RUNNER/run-helper.sh.template"
: > "$LEAK_RUNNER/env.sh"
printf '{"agentId":101,"agentName":"mac-native-ci-1","workFolder":"%s","gitHubUrl":"https://github.com/jleechanorg"}\n' "$TMP/scratch/native-macos-ci-work" > "$LEAK_RUNNER/.runner"
printf 'self-hosted-native-macos\n' > "$LEAK_RUNNER/.ezgha-labels"
printf 'macos-restricted\n' > "$LEAK_RUNNER/.ezgha-group"
python3 - "$TMP/plist.ok" "$PLIST_T" "$LEAK_RUNNER" <<'PY'
import plistlib, sys
from pathlib import Path
d = plistlib.loads(Path(sys.argv[1]).read_bytes())
r = sys.argv[3]
d["WorkingDirectory"] = r
d["ProgramArguments"] = ["/bin/bash", f"{r}/run.sh"]
Path(sys.argv[2]).write_bytes(plistlib.dumps(d))
PY
: > "$TMP/launchctl.loaded"

if HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
    "$SETUP_SCRIPT" --verify --offline --runner-dir "$LEAK_RUNNER" --runner-group macos-restricted >/dev/null 2>&1; then
  fail "--verify must fail when bin/Runner.Listener symlinks outside RUNNER_DIR"
fi

RUNNER_GROUPS_JSON="$MIXED_GROUPS" FORK_APPROVAL_JSON='{"approval_policy":"first_time_contributors"}' \
  LIVE_RUNNERS_JSON='{"runners":[{"id":101,"name":"mac-native-ci-1","labels":[{"name":"self-hosted-native-macos"}]}]}' \
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  EXISTING_RUNNER_DIR="$EXISTING_SYM" \
  "$SETUP_SCRIPT" --runner-dir "$LEAK_RUNNER" --runner-group macos-restricted >/dev/null

LEAK_RUNNER="$LEAK_RUNNER" EXISTING_SYM="$EXISTING_SYM" python3 - <<'PY' || fail "repaired runner symlinks escaped RUNNER_DIR"
import os
from pathlib import Path

runner = Path(os.environ["LEAK_RUNNER"]).resolve()
existing = Path(os.environ["EXISTING_SYM"]).resolve()
listener_real = (runner / "bin" / "Runner.Listener").resolve()
assert str(listener_real).startswith(str(runner) + "/"), f"Runner.Listener escaped: {listener_real}"
assert existing not in listener_real.parents and listener_real != existing, f"Runner.Listener still points into existing: {listener_real}"
nested = runner / "bin.2.338.2" / "nested-node-link"
assert os.path.islink(nested), "nested symlink should remain a symlink"
assert os.readlink(nested) == "../externals.2.338.2/node20/bin/node", f"unexpected nested readlink: {os.readlink(nested)!r}"
nested_real = nested.resolve()
assert str(nested_real).startswith(str(runner) + "/"), f"nested symlink escaped: {nested_real}"
PY
HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  "$SETUP_SCRIPT" --verify --offline --runner-dir "$LEAK_RUNNER" --runner-group macos-restricted >/dev/null || \
  fail "--verify must pass after repairing symlink-leaking RUNNER_DIR"
pass "realpath containment catches escaping Runner.Listener symlinks and repairs nested symlinks cleanly"

# 22. Codex P0-1: Refused setup against a fresh runner dir (missing binaries & .runner) must NOT stop the incumbent LaunchAgent.
: > "$TMP/launchctl.loaded"
: > "$TMP/launchctl.log"
: > "$TMP/config.log"
precheck_collide_rc=0
RUNNER_GROUPS_JSON="$MIXED_GROUPS" FORK_APPROVAL_JSON='{"approval_policy":"first_time_contributors"}' \
  LIVE_RUNNERS_JSON='{"runners":[{"id":999,"name":"mac-native-ci-1","labels":[{"name":"self-hosted-native-macos"}]}]}' \
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  EXISTING_RUNNER_DIR="$EXISTING_SYM" \
  "$SETUP_SCRIPT" --runner-dir "$TMP/fresh-collision-dir" --runner-group macos-restricted >/dev/null 2>&1 || precheck_collide_rc=$?
[ "$precheck_collide_rc" -eq 6 ] || fail "fresh collision precheck must exit 6 (got $precheck_collide_rc)"
[ -f "$TMP/launchctl.loaded" ] || fail "collision refusal must leave incumbent LaunchAgent loaded"
! grep -Eq 'launchctl (unload|bootout)' "$TMP/launchctl.log" || fail "collision refusal must NOT call launchctl unload or bootout"
[ ! -s "$TMP/config.log" ] || fail "collision refusal must NOT invoke config.sh"
pass "pre-staging collision guard aborts with exit 6 without stopping incumbent LaunchAgent"

# 23. Codex P0-2: Failed --reconfigure preserves ownership proof in .backup-pre-reconfigure.*/.runner so retry succeeds with --replace and cleans all backups.
RETRY_RUNNER="$TMP/home/retry-reconfig-runner"
mkdir -p "$RETRY_RUNNER/bin" "$RETRY_RUNNER/externals"
cp "$EXISTING_SYM/bin.2.338.2/Runner.Listener" "$RETRY_RUNNER/bin/Runner.Listener"
cp "$EXISTING_SYM/run.sh" "$RETRY_RUNNER/run.sh"
: > "$RETRY_RUNNER/run-helper.sh.template"
: > "$RETRY_RUNNER/env.sh"
cat > "$RETRY_RUNNER/config.sh" <<'STUB'
#!/usr/bin/env bash
echo "transient config.sh failure" >&2
exit 1
STUB
chmod +x "$RETRY_RUNNER/config.sh"
printf '{"agentId":101,"agentName":"mac-native-ci-1","workFolder":"%s","gitHubUrl":"https://github.com/jleechanorg"}\n' "$TMP/scratch/native-macos-ci-work" > "$RETRY_RUNNER/.runner"
printf 'old-creds\n' > "$RETRY_RUNNER/.credentials"
printf 'old-rsa\n' > "$RETRY_RUNNER/.credentials_rsaparams"
printf 'self-hosted-native-macos\n' > "$RETRY_RUNNER/.ezgha-labels"
printf 'macos-restricted\n' > "$RETRY_RUNNER/.ezgha-group"
: > "$TMP/launchctl.loaded"
: > "$TMP/launchctl.log"
retry_fail_rc=0
RUNNER_GROUPS_JSON="$MIXED_GROUPS" FORK_APPROVAL_JSON='{"approval_policy":"first_time_contributors"}' \
  LIVE_RUNNERS_JSON='{"runners":[{"id":101,"name":"mac-native-ci-1","labels":[{"name":"self-hosted-native-macos"}]}]}' \
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  "$SETUP_SCRIPT" --runner-dir "$RETRY_RUNNER" --reconfigure --runner-group macos-restricted >/dev/null 2>&1 || retry_fail_rc=$?
[ "$retry_fail_rc" -eq 4 ] || fail "initial failed --reconfigure must exit 4 (got $retry_fail_rc)"
[ ! -e "$RETRY_RUNNER/.runner" ] || fail "initial failed --reconfigure must remove .runner"
retry_backups=("$RETRY_RUNNER"/.backup-pre-reconfigure.*)
[ "${#retry_backups[@]}" -eq 1 ] && [ -f "${retry_backups[0]}/.runner" ] || fail "initial failed --reconfigure must retain .backup-pre-reconfigure.<pid>/.runner"

cp "$EXISTING_SYM/config.sh" "$RETRY_RUNNER/config.sh"
: > "$TMP/config.log"
rm -f "$TMP/launchctl.loaded"
RUNNER_GROUPS_JSON="$MIXED_GROUPS" FORK_APPROVAL_JSON='{"approval_policy":"first_time_contributors"}' \
  LIVE_RUNNERS_JSON='{"runners":[{"id":101,"name":"mac-native-ci-1","labels":[{"name":"self-hosted-native-macos"}]}]}' \
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" DISK_MAGICIAN_DISKM_BIN="$TMP/bin/diskm-vol" SCRATCH_DIR_HELPER="$TMP/bin/scratch-dir-ok.sh" GH_BIN="$TMP/bin/gh-runner" \
  "$SETUP_SCRIPT" --runner-dir "$RETRY_RUNNER" --reconfigure --runner-group macos-restricted >/dev/null
grep -q -- '--replace' "$TMP/config.log" || fail "retry --reconfigure without --force-replace-name must derive prev_agent_id=101 from backup and pass --replace"
[ -f "$TMP/launchctl.loaded" ] || fail "retry --reconfigure must reload LaunchAgent"
shopt -s nullglob
leftover_retry_backups=("$RETRY_RUNNER"/.backup-pre-reconfigure.*)
shopt -u nullglob
[ "${#leftover_retry_backups[@]}" -eq 0 ] || fail "successful retry --reconfigure must remove all .backup-pre-reconfigure.* directories (found: ${leftover_retry_backups[*]})"
pass "failed --reconfigure preserves agentId ownership proof in backup .runner for --replace retry and cleans all backups on success"
