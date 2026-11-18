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

RUNNER_ORG="${RUNNER_ORG:-${GITHUB_ORG:-jleechanorg}}"
GITHUB_ORG="$RUNNER_ORG"
RUNNER_REPO="${RUNNER_REPO:-}"
RUNNER_NAME="${RUNNER_NAME:-mac-native-ci-1}"
RUNNER_DIR="${RUNNER_DIR:-$HOME/actions-runner-macos-ci}"
EXISTING_RUNNER_DIR="${EXISTING_RUNNER_DIR:-$HOME/actions-runner}"
LABELS="${LABELS:-${RUNNER_LABELS:-self-hosted-native-macos}}"
RUNNER_LABELS="$LABELS"
RUNNER_VERSION="${RUNNER_VERSION:-2.338.2}"
WORK_DIR="${WORK_DIR:-}"
PLIST_LABEL="org.jleechanorg.ezgha-native-macos-runner"
GH_BIN="${GH_BIN:-gh}"
SCRATCH_DIR_HELPER="${SCRATCH_DIR_HELPER:-$HOME/.claude/skills/scratch-space/scripts/scratch-dir.sh}"

DRY_RUN=0
VERIFY=0
UNINSTALL=0
RECONFIGURE=0
OFFLINE=0

usage() {
  cat <<'USAGE'
Usage: setup-native-macos-runner.sh [OPTIONS]
  --dry-run            Print planned setup, config.sh command, and LaunchAgent plist without mutating host
  --verify             Verify existing runner dir, .runner, .ezgha-labels, live GitHub labels, work dir, and LaunchAgent
  --reconfigure        Force unload, removal of local .runner/.credentials*, and fresh ./config.sh --replace
  --offline            Skip live GitHub API label verification during --verify
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
    --reconfigure) RECONFIGURE=1; shift ;;
    --offline) OFFLINE=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --org) RUNNER_ORG="${2:?missing --org value}"; GITHUB_ORG="$RUNNER_ORG"; shift 2 ;;
    --repo) RUNNER_REPO="${2:?missing --repo value}"; shift 2 ;;
    --name) RUNNER_NAME="${2:?missing --name value}"; shift 2 ;;
    --runner-dir) RUNNER_DIR="${2:?missing --runner-dir value}"; shift 2 ;;
    --labels) LABELS="${2:?missing --labels value}"; RUNNER_LABELS="$LABELS"; shift 2 ;;
    --work-dir) WORK_DIR="${2:?missing --work-dir value}"; shift 2 ;;
    --version) RUNNER_VERSION="${2:?missing --version value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 64 ;;
  esac
done

canonical_path() {
  python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

RUNNER_DIR="$(canonical_path "$RUNNER_DIR")"
EXISTING_RUNNER_DIR="$(canonical_path "$EXISTING_RUNNER_DIR")"
RESERVED_TF_HOME="$(canonical_path "$HOME/actions-runner")"
RESERVED_SMTP_HOME="$(canonical_path "$HOME/actions-runner-smtp-egress")"
RESERVED_TF_OP="$(canonical_path "/Users/jleechan/actions-runner")"
RESERVED_SMTP_OP="$(canonical_path "/Users/jleechan/actions-runner-smtp-egress")"

# Fail-closed guard: never touch the TestFlight signing or SMTP-egress runner directories.
is_reserved_runner_dir() {
  local target="$1" reserved
  [ -n "$target" ] || return 0
  [ "$target" != "/" ] || return 0
  for reserved in "$RESERVED_TF_HOME" "$RESERVED_SMTP_HOME" "$RESERVED_TF_OP" "$RESERVED_SMTP_OP"; do
    case "$target" in
      "$reserved"|"$reserved"/*) return 0 ;;
    esac
  done
  return 1
}

if is_reserved_runner_dir "$RUNNER_DIR"; then
  echo "ERROR: refusing unsafe or reserved runner dir: '$RUNNER_DIR'" >&2
  exit 2
fi

normalize_labels() {
  local raw="$1" item trimmed out=""
  local IFS=','
  for item in $raw; do
    trimmed="$(printf '%s' "$item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -n "$trimmed" ] || continue
    out="${out:+${out},}${trimmed}"
  done
  printf '%s' "$out"
}

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
LABELS="$(normalize_labels "$LABELS")"
RUNNER_LABELS="$LABELS"

resolve_work_dir() {
  if [ -n "$WORK_DIR" ]; then
    local explicit="${WORK_DIR%/}"
    if [[ "$explicit" != /* ]] || [ "$explicit" = "/" ]; then
      echo "ERROR: --work-dir must be a non-root absolute path (got '$WORK_DIR')" >&2
      exit 1
    fi
    printf '%s' "$explicit"
    return 0
  fi

  local resolved="" parent=""
  if [ -x "$SCRATCH_DIR_HELPER" ]; then
    resolved="$("$SCRATCH_DIR_HELPER" native-macos-ci-work 2>/dev/null || true)"
    resolved="${resolved%/}"
    if [[ "$resolved" == /* ]] && [ "$resolved" != "/" ]; then
      parent="$(dirname "$resolved")"
      if [ "$parent" != "/tmp" ] && { [ -d "$resolved" ] || [ -d "$parent" ]; }; then
        printf '%s' "$resolved"
        return 0
      fi
    fi
  fi

  local diskm_bin="" scratch_root=""
  if [ -n "${DISK_MAGICIAN_DISKM_BIN:-}" ] && [ -x "${DISK_MAGICIAN_DISKM_BIN}" ]; then
    diskm_bin="${DISK_MAGICIAN_DISKM_BIN}"
  elif command -v diskm >/dev/null 2>&1; then
    diskm_bin="$(command -v diskm)"
  fi
  if [ -n "$diskm_bin" ]; then
    scratch_root="$("$diskm_bin" volume path scratch 2>/dev/null || true)"
    scratch_root="${scratch_root%/}"
    if [[ "$scratch_root" == /* ]] && [ "$scratch_root" != "/" ] && [ "$scratch_root" != "/tmp" ] && [ -d "$scratch_root" ]; then
      printf '%s' "${scratch_root}/native-macos-ci-work"
      return 0
    fi
  fi

  echo "ERROR: could not resolve an existing Scratch directory via scratch-dir.sh or 'diskm volume path scratch'; pass --work-dir explicitly" >&2
  exit 1
}

WORK_DIR="$(resolve_work_dir)" || exit 1
PLIST_PATH="${HOME}/Library/LaunchAgents/${PLIST_LABEL}.plist"
LOG_DIR="${HOME}/Library/Logs/${PLIST_LABEL}"

if [ -n "$RUNNER_REPO" ]; then
  RUNNER_URL="https://github.com/${RUNNER_REPO}"
  TOKEN_API="repos/${RUNNER_REPO}/actions/runners/registration-token"
  RUNNERS_API="repos/${RUNNER_REPO}/actions/runners"
else
  RUNNER_URL="https://github.com/${RUNNER_ORG}"
  TOKEN_API="orgs/${RUNNER_ORG}/actions/runners/registration-token"
  RUNNERS_API="orgs/${GITHUB_ORG}/actions/runners"
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
  # SessionCreate=true spawns a new security audit session detached from the
  # GUI login keychain session used by worldai-testflight-native-mac.
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
  <key>SessionCreate</key>
  <true/>
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
  [ -f "${RUNNER_DIR}/.ezgha-labels" ] || { echo "FAIL: missing ${RUNNER_DIR}/.ezgha-labels" >&2; exit 1; }
  [ -f "$PLIST_PATH" ] || { echo "FAIL: missing $PLIST_PATH" >&2; exit 1; }
  if command -v plutil >/dev/null 2>&1; then
    session_create="$(plutil -extract SessionCreate raw -o - "$PLIST_PATH" 2>/dev/null || true)"
  else
    session_create="$(python3 -c 'import plistlib,sys; v=plistlib.loads(open(sys.argv[1],"rb").read()).get("SessionCreate"); print("true" if v is True else ("false" if v is False else ""))' "$PLIST_PATH" 2>/dev/null || true)"
  fi
  [ "$session_create" = "true" ] || { echo "FAIL: $PLIST_PATH must set SessionCreate=true (got '${session_create:-missing}')" >&2; exit 1; }
  actual_name="$(jq -r '.agentName // ""' "${RUNNER_DIR}/.runner")"
  actual_work="$(jq -r '.workFolder // ""' "${RUNNER_DIR}/.runner")"
  actual_url="$(jq -r '.gitHubUrl // ""' "${RUNNER_DIR}/.runner")"
  actual_labels="$(tr -d '\r\n' < "${RUNNER_DIR}/.ezgha-labels")"
  [ "$actual_name" = "$RUNNER_NAME" ] || { echo "FAIL: .runner agentName='$actual_name' != '$RUNNER_NAME'" >&2; exit 1; }
  [ "$actual_work" = "$WORK_DIR" ] || { echo "FAIL: .runner workFolder='$actual_work' != '$WORK_DIR'" >&2; exit 1; }
  [ -z "$actual_url" ] || [ "$actual_url" = "$RUNNER_URL" ] || { echo "FAIL: .runner gitHubUrl='$actual_url' != '$RUNNER_URL'" >&2; exit 1; }
  [ "$actual_labels" = "$RUNNER_LABELS" ] || { echo "FAIL: .ezgha-labels='$actual_labels' != '$RUNNER_LABELS'" >&2; exit 1; }
  if [ "$OFFLINE" -eq 0 ] && command -v "$GH_BIN" >/dev/null 2>&1; then
    runners_pages="$("$GH_BIN" api --paginate "$RUNNERS_API")"
    runner_json="$(printf '%s\n' "$runners_pages" | jq -sc --arg name "$RUNNER_NAME" '[.[].runners[]? | select(.name == $name)] | .[0] // empty')"
    [ -n "$runner_json" ] || { echo "FAIL: runner '$RUNNER_NAME' not found in live $RUNNERS_API" >&2; exit 1; }
    live_labels_csv="$(printf '%s\n' "$runner_json" | jq -r '[.labels[]?.name // empty] | map(ascii_downcase) | unique | join(",")')"
    expected_sorted_csv="$(printf '%s' "$RUNNER_LABELS" | tr ',' '\n' | tr '[:upper:]' '[:lower:]' | sort -u | paste -sd, -)"
    if printf '%s\n' "$live_labels_csv" | tr ',' '\n' | grep -qxE 'self-hosted|worldai-testflight-native-mac'; then
      echo "FAIL: live runner '$RUNNER_NAME' carries forbidden label in '$live_labels_csv'" >&2
      exit 1
    fi
    [ "$live_labels_csv" = "$expected_sorted_csv" ] || { echo "FAIL: live labels '$live_labels_csv' != expected '$expected_sorted_csv'" >&2; exit 1; }
  fi
  launchctl print "gui/$(id -u)/${PLIST_LABEL}" >/dev/null || { echo "FAIL: launchd job ${PLIST_LABEL} not loaded" >&2; exit 1; }
  echo "OK: ${RUNNER_NAME} verified at ${RUNNER_DIR} (work=${WORK_DIR}, labels=${RUNNER_LABELS})"
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

# Register or refresh configuration when .runner/.ezgha-labels is missing, differs, or --reconfigure is passed.
needs_config=1
if [ "$RECONFIGURE" -eq 0 ] && [ -f "${RUNNER_DIR}/.runner" ] && [ -f "${RUNNER_DIR}/.ezgha-labels" ]; then
  existing_name="$(jq -r '.agentName // ""' "${RUNNER_DIR}/.runner" 2>/dev/null || true)"
  existing_work="$(jq -r '.workFolder // ""' "${RUNNER_DIR}/.runner" 2>/dev/null || true)"
  existing_url="$(jq -r '.gitHubUrl // ""' "${RUNNER_DIR}/.runner" 2>/dev/null || true)"
  existing_labels="$(tr -d '\r\n' < "${RUNNER_DIR}/.ezgha-labels" 2>/dev/null || true)"
  if [ "$existing_name" = "$RUNNER_NAME" ] && [ "$existing_work" = "$WORK_DIR" ] && [ "$existing_url" = "$RUNNER_URL" ] && [ "$existing_labels" = "$RUNNER_LABELS" ]; then
    needs_config=0
  fi
fi

if [ "$needs_config" -eq 1 ]; then
  reg_token="$("$GH_BIN" api -X POST "$TOKEN_API" --jq '.token')"
  [ -n "$reg_token" ] || { echo "ERROR: failed to mint registration token from $TOKEN_API" >&2; exit 3; }
  if [ -f "$PLIST_PATH" ]; then
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
  fi
  rm -f "${RUNNER_DIR}/.runner" "${RUNNER_DIR}/.credentials" "${RUNNER_DIR}/.credentials_rsaparams"
  (
    cd "$RUNNER_DIR"
    ./config.sh --unattended \
      --url "$RUNNER_URL" \
      --token "$reg_token" \
      --name "$RUNNER_NAME" \
      --work "$WORK_DIR" \
      --labels "$RUNNER_LABELS" \
      --no-default-labels \
      --replace
  )
  printf '%s\n' "$RUNNER_LABELS" > "${RUNNER_DIR}/.ezgha-labels"
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
