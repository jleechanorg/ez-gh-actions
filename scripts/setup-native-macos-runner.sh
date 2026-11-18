#!/usr/bin/env bash
# setup-native-macos-runner.sh — Idempotent setup & verifier for a general-CI
# native macOS GitHub Actions runner (`mac-native-ci-1`) isolated from the
# TestFlight signing runner (`/Users/jleechan/actions-runner`) and from Linux
# `self-hosted` jobs.
#
# Usage:
#   setup-native-macos-runner.sh [--dry-run] [--verify] [--uninstall]
#     [--org ORG] [--repo OWNER/REPO] [--name RUNNER_NAME]
#     [--runner-dir DIR] [--labels CSV] [--work-dir DIR] [--version VER]
set -euo pipefail

RUNNER_ORG="${RUNNER_ORG:-jleechanorg}"
RUNNER_REPO="${RUNNER_REPO:-}"
RUNNER_NAME="${RUNNER_NAME:-mac-native-ci-1}"
RUNNER_DIR="${RUNNER_DIR:-$HOME/actions-runner-macos-ci}"
EXISTING_RUNNER_DIR="${EXISTING_RUNNER_DIR:-$HOME/actions-runner}"
LABELS="${LABELS:-self-hosted-native-macos}"
RUNNER_VERSION="${RUNNER_VERSION:-2.338.2}"
WORK_DIR="${WORK_DIR:-}"
PLIST_LABEL="org.jleechanorg.ezgha-native-macos-runner"
GH_BIN="${GH_BIN:-gh}"
SCRATCH_DIR_HELPER="${SCRATCH_DIR_HELPER:-$HOME/.claude/skills/scratch-space/scripts/scratch-dir.sh}"

DRY_RUN=0
VERIFY=0
UNINSTALL=0

usage() {
  cat <<'USAGE'
Usage: setup-native-macos-runner.sh [OPTIONS]
  --dry-run            Print planned setup, config.sh command, and LaunchAgent plist without mutating host
  --verify             Verify existing runner dir, .runner metadata, work dir, and LaunchAgent state
  --uninstall          Unload and remove org.jleechanorg.ezgha-native-macos-runner LaunchAgent
  --org ORG            GitHub org scope (default: jleechanorg)
  --repo OWNER/REPO    Optional repo scope (overrides --org)
  --name NAME          Runner name (default: mac-native-ci-1)
  --runner-dir DIR     Install directory (default: $HOME/actions-runner-macos-ci)
  --labels CSV         Comma-separated labels (default: self-hosted-native-macos)
  --work-dir DIR       Work directory (default: Scratch native-macos-ci-work)
  --version VER        Actions runner version fallback download (default: 2.338.2)
  -h, --help           Show help
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --verify) VERIFY=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --org) RUNNER_ORG="${2:?missing --org value}"; shift 2 ;;
    --repo) RUNNER_REPO="${2:?missing --repo value}"; shift 2 ;;
    --name) RUNNER_NAME="${2:?missing --name value}"; shift 2 ;;
    --runner-dir) RUNNER_DIR="${2:?missing --runner-dir value}"; shift 2 ;;
    --labels) LABELS="${2:?missing --labels value}"; shift 2 ;;
    --work-dir) WORK_DIR="${2:?missing --work-dir value}"; shift 2 ;;
    --version) RUNNER_VERSION="${2:?missing --version value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 64 ;;
  esac
done

normalize_dir() {
  local d="${1%/}"
  [ -n "$d" ] || d="/"
  printf '%s' "$d"
}

RUNNER_DIR="$(normalize_dir "$RUNNER_DIR")"
EXISTING_RUNNER_DIR="$(normalize_dir "$EXISTING_RUNNER_DIR")"

# Fail-closed guard: never touch the TestFlight signing runner directory.
if [ -z "$RUNNER_DIR" ] || [ "$RUNNER_DIR" = "/" ] || \
   [ "$RUNNER_DIR" = "$(normalize_dir "$HOME/actions-runner")" ] || \
   [ "$RUNNER_DIR" = "/Users/jleechan/actions-runner" ]; then
  echo "ERROR: refusing unsafe or TestFlight-reserved runner dir: '$RUNNER_DIR'" >&2
  exit 2
fi

# Fail-closed guard: reject labels that cause Linux CI spillover or TestFlight collision.
validate_labels() {
  local raw="$1" item trimmed lower
  [ -n "$raw" ] || { echo "ERROR: --labels must not be empty" >&2; exit 2; }
  local IFS=','
  for item in $raw; do
    trimmed="$(printf '%s' "$item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    lower="$(printf '%s' "$trimmed" | tr '[:upper:]' '[:lower:]')"
    case "$lower" in
      "")
        echo "ERROR: empty label element in '$raw'" >&2
        exit 2
        ;;
      self-hosted)
        echo "ERROR: bare 'self-hosted' label is forbidden (would pull Linux CI jobs onto Mac)" >&2
        exit 2
        ;;
      worldai-testflight-native-mac)
        echo "ERROR: 'worldai-testflight-native-mac' label is reserved for TestFlight signing runner" >&2
        exit 2
        ;;
    esac
  done
}

validate_labels "$LABELS"

resolve_work_dir() {
  if [ -n "$WORK_DIR" ]; then
    printf '%s' "$WORK_DIR"
    return 0
  fi
  local resolved=""
  if [ -x "$SCRATCH_DIR_HELPER" ]; then
    resolved="$("$SCRATCH_DIR_HELPER" native-macos-ci-work 2>/dev/null || true)"
  elif command -v diskm >/dev/null 2>&1; then
    resolved="$(diskm scratch-dir native-macos-ci-work 2>/dev/null || true)"
  fi
  if [ -n "$resolved" ]; then
    printf '%s' "${resolved%/}"
  else
    printf '%s' "${TMPDIR:-/tmp}/native-macos-ci-work"
  fi
}

WORK_DIR="$(resolve_work_dir)"
PLIST_PATH="${HOME}/Library/LaunchAgents/${PLIST_LABEL}.plist"
LOG_DIR="${HOME}/Library/Logs/${PLIST_LABEL}"

if [ -n "$RUNNER_REPO" ]; then
  RUNNER_URL="https://github.com/${RUNNER_REPO}"
  TOKEN_API="repos/${RUNNER_REPO}/actions/runners/registration-token"
else
  RUNNER_URL="https://github.com/${RUNNER_ORG}"
  TOKEN_API="orgs/${RUNNER_ORG}/actions/runners/registration-token"
fi

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

render_plist() {
  local runner_dir_xml log_dir_xml home_xml path_xml
  runner_dir_xml="$(xml_escape "$RUNNER_DIR")"
  log_dir_xml="$(xml_escape "$LOG_DIR")"
  home_xml="$(xml_escape "$HOME")"
  path_xml="$(xml_escape "${HOME}/.local/bin:${HOME}/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")"
  # Intentionally omit SessionCreate=false so general CI jobs do not attach to
  # the interactive login keychain used by worldai-testflight-native-mac.
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${runner_dir_xml}/run.sh</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${runner_dir_xml}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>${home_xml}</string>
    <key>LANG</key>
    <string>en_US.UTF-8</string>
    <key>PATH</key>
    <string>${path_xml}</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>30</integer>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>${log_dir_xml}/stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${log_dir_xml}/stderr.log</string>
</dict>
</plist>
PLIST
}

if [ "$UNINSTALL" -eq 1 ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] would unload and remove $PLIST_PATH"
    exit 0
  fi
  if [ -f "$PLIST_PATH" ]; then
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    launchctl bootout "gui/$(id -u)/${PLIST_LABEL}" 2>/dev/null || true
    rm -f "$PLIST_PATH"
    echo "removed: $PLIST_PATH"
  else
    echo "already absent: $PLIST_PATH"
  fi
  exit 0
fi

if [ "$VERIFY" -eq 1 ]; then
  [ -x "${RUNNER_DIR}/bin/Runner.Listener" ] || { echo "FAIL: missing ${RUNNER_DIR}/bin/Runner.Listener" >&2; exit 1; }
  [ -f "${RUNNER_DIR}/.runner" ] || { echo "FAIL: missing ${RUNNER_DIR}/.runner" >&2; exit 1; }
  [ -f "$PLIST_PATH" ] || { echo "FAIL: missing $PLIST_PATH" >&2; exit 1; }
  ! grep -q 'SessionCreate' "$PLIST_PATH" || { echo "FAIL: $PLIST_PATH must not set SessionCreate" >&2; exit 1; }
  actual_name="$(jq -r '.agentName // ""' "${RUNNER_DIR}/.runner")"
  actual_work="$(jq -r '.workFolder // ""' "${RUNNER_DIR}/.runner")"
  [ "$actual_name" = "$RUNNER_NAME" ] || { echo "FAIL: .runner agentName='$actual_name' != '$RUNNER_NAME'" >&2; exit 1; }
  [ "$actual_work" = "$WORK_DIR" ] || { echo "FAIL: .runner workFolder='$actual_work' != '$WORK_DIR'" >&2; exit 1; }
  launchctl print "gui/$(id -u)/${PLIST_LABEL}" >/dev/null || { echo "FAIL: launchd job ${PLIST_LABEL} not loaded" >&2; exit 1; }
  echo "OK: ${RUNNER_NAME} verified at ${RUNNER_DIR} (work=${WORK_DIR}, labels=${LABELS})"
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "RUNNER_NAME=${RUNNER_NAME}"
  echo "RUNNER_DIR=${RUNNER_DIR}"
  echo "WORK_DIR=${WORK_DIR}"
  echo "RUNNER_URL=${RUNNER_URL}"
  echo "LABELS=${LABELS}"
  echo "PLIST_PATH=${PLIST_PATH}"
  if [ -x "${EXISTING_RUNNER_DIR}/bin/Runner.Listener" ] && [ -f "${EXISTING_RUNNER_DIR}/config.sh" ]; then
    echo "BINARY_SOURCE=apfs-clone:${EXISTING_RUNNER_DIR}"
  else
    echo "BINARY_SOURCE=download:v${RUNNER_VERSION}"
  fi
  echo "CONFIG_CMD=${RUNNER_DIR}/config.sh --unattended --url ${RUNNER_URL} --token <redacted-token> --name ${RUNNER_NAME} --work ${WORK_DIR} --labels ${LABELS} --no-default-labels --replace"
  render_plist
  exit 0
fi

mkdir -p "$RUNNER_DIR" "$WORK_DIR" "${HOME}/Library/LaunchAgents" "$LOG_DIR"

if [ ! -x "${RUNNER_DIR}/bin/Runner.Listener" ]; then
  if [ -x "${EXISTING_RUNNER_DIR}/bin/Runner.Listener" ] && [ -f "${EXISTING_RUNNER_DIR}/config.sh" ]; then
    echo "Provisioning runner binaries via clone from ${EXISTING_RUNNER_DIR}..."
    shopt -s nullglob
    for item in "${EXISTING_RUNNER_DIR}"/bin* "${EXISTING_RUNNER_DIR}"/externals* \
                "${EXISTING_RUNNER_DIR}/config.sh" "${EXISTING_RUNNER_DIR}/run.sh" \
                "${EXISTING_RUNNER_DIR}/run-helper.sh.template" "${EXISTING_RUNNER_DIR}/env.sh" \
                "${EXISTING_RUNNER_DIR}/safe_sleep.sh"; do
      [ -e "$item" ] || continue
      base="$(basename "$item")"
      cp -Rc "$item" "${RUNNER_DIR}/${base}" 2>/dev/null || cp -a "$item" "${RUNNER_DIR}/${base}"
    done
    shopt -u nullglob
  else
    echo "Downloading actions-runner v${RUNNER_VERSION} (osx-arm64)..."
    tmp_tgz="$(mktemp)"
    trap 'rm -f "${tmp_tgz:?}"' EXIT
    tarball_url="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-osx-arm64-${RUNNER_VERSION}.tar.gz"
    curl -fsSL "$tarball_url" -o "$tmp_tgz"
    tar -xzf "$tmp_tgz" -C "$RUNNER_DIR"
    rm -f "$tmp_tgz"
    trap - EXIT
  fi
fi

# Register or refresh configuration only when .runner is missing or misconfigured.
needs_config=1
if [ -f "${RUNNER_DIR}/.runner" ]; then
  existing_name="$(jq -r '.agentName // ""' "${RUNNER_DIR}/.runner" 2>/dev/null || true)"
  existing_work="$(jq -r '.workFolder // ""' "${RUNNER_DIR}/.runner" 2>/dev/null || true)"
  existing_url="$(jq -r '.gitHubUrl // ""' "${RUNNER_DIR}/.runner" 2>/dev/null || true)"
  if [ "$existing_name" = "$RUNNER_NAME" ] && [ "$existing_work" = "$WORK_DIR" ] && [ "$existing_url" = "$RUNNER_URL" ]; then
    needs_config=0
  fi
fi

if [ "$needs_config" -eq 1 ]; then
  reg_token="$("$GH_BIN" api -X POST "$TOKEN_API" --jq '.token')"
  [ -n "$reg_token" ] || { echo "ERROR: failed to mint registration token from $TOKEN_API" >&2; exit 3; }
  (
    cd "$RUNNER_DIR"
    ./config.sh --unattended \
      --url "$RUNNER_URL" \
      --token "$reg_token" \
      --name "$RUNNER_NAME" \
      --work "$WORK_DIR" \
      --labels "$LABELS" \
      --no-default-labels \
      --replace
  )
fi

printf 'LANG=en_US.UTF-8\n' > "${RUNNER_DIR}/.env"

candidate="${PLIST_PATH}.candidate.$$"
render_plist > "$candidate"
if [ -f "$PLIST_PATH" ]; then
  launchctl unload "$PLIST_PATH" 2>/dev/null || true
fi
mv "$candidate" "$PLIST_PATH"
launchctl load -w "$PLIST_PATH"
launchctl print "gui/$(id -u)/${PLIST_LABEL}" >/dev/null
echo "OK: ${RUNNER_NAME} installed and loaded (${PLIST_LABEL})"
