#!/usr/bin/env bash
# setup-native-macos-runner.sh — Idempotent setup & verifier for a general-CI
# native macOS GitHub Actions runner (`mac-native-ci-1`). Uses separate
# runner/Scratch `_work` paths and `--no-default-labels --labels self-hosted-native-macos`
# (`SessionCreate=true`) from the TestFlight signing runner
# (`/Users/jleechan/actions-runner`) and Linux `self-hosted` jobs, while sharing
# the operator's macOS UID/`$HOME` (not a user-account sandbox); public-repo
# workflows targeting `self-hosted-native-macos` must gate out untrusted fork PRs.
#
# Usage:
#   setup-native-macos-runner.sh [--dry-run] [--verify] [--uninstall]
#     [--org ORG] [--repo OWNER/REPO] [--name RUNNER_NAME]
#     [--runner-dir DIR] [--labels CSV] [--work-dir DIR] [--version VER]
set -euo pipefail

RUNNER_ORG="${RUNNER_ORG:-${GITHUB_ORG:-jleechanorg}}"
GITHUB_ORG="$RUNNER_ORG"
RUNNER_REPO="${RUNNER_REPO:-}"
RUNNER_NAME="${NATIVE_MACOS_RUNNER_NAME:-mac-native-ci-1}"
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
PLIST_PATH="${HOME}/Library/LaunchAgents/${PLIST_LABEL}.plist"
LOG_DIR="${HOME}/Library/Logs/${PLIST_LABEL}"
STATE_LOCK_TIMEOUT_SEC="${SETUP_LOCK_TIMEOUT_SEC:-30}"
SETUP_LOCK_DIR=""
STAGE_DIR=""
TMP_TGZ=""
BACKUP_DIR=""
CANDIDATE_PLIST=""

release_setup_lock() {
  if [ -n "${SETUP_LOCK_DIR:-}" ] && [ -d "$SETUP_LOCK_DIR" ]; then
    local rel_dir="${SETUP_LOCK_DIR}.release.$$"
    if mv "$SETUP_LOCK_DIR" "$rel_dir" 2>/dev/null; then
      rm -rf "$rel_dir" 2>/dev/null || true
    else
      rm -f "${SETUP_LOCK_DIR}/pid" 2>/dev/null || true
      rmdir "$SETUP_LOCK_DIR" 2>/dev/null || true
    fi
    SETUP_LOCK_DIR=""
  fi
}

cleanup_setup() {
  [ -z "${STAGE_DIR:-}" ] || rm -rf "$STAGE_DIR"
  [ -z "${TMP_TGZ:-}" ] || rm -f "$TMP_TGZ"
  [ -z "${CANDIDATE_PLIST:-}" ] || rm -f "$CANDIDATE_PLIST"
  release_setup_lock
}
trap cleanup_setup EXIT

acquire_setup_lock() {
  local state_dir="${HOME}/.local/state/ezgha"
  local safe_label lockdir pidfile deadline
  local owner_pid="" owner_pid2="" missing_pid_polls=0
  safe_label="$(printf '%s' "$PLIST_LABEL" | tr -cd 'A-Za-z0-9_.-')"
  lockdir="${state_dir}/setup-native-macos-runner.${safe_label}.lock"
  pidfile="${lockdir}/pid"
  deadline=$((SECONDS + STATE_LOCK_TIMEOUT_SEC))
  mkdir -p "$state_dir"
  while true; do
    if mkdir "$lockdir" 2>/dev/null; then
      printf '%s\n' "$$" > "${pidfile}.tmp.$$" && mv -f "${pidfile}.tmp.$$" "$pidfile"
      SETUP_LOCK_DIR="$lockdir"
      return 0
    fi
    if [ -f "$pidfile" ]; then
      owner_pid="$(tr -d '[:space:]' < "$pidfile" 2>/dev/null || true)"
      if [[ "$owner_pid" =~ ^[0-9]+$ ]]; then
        missing_pid_polls=0
        if ! kill -0 "$owner_pid" 2>/dev/null; then
          owner_pid2="$(tr -d '[:space:]' < "$pidfile" 2>/dev/null || true)"
          if [ "$owner_pid2" = "$owner_pid" ] && mv "$lockdir" "${lockdir}.reclaim.$$" 2>/dev/null; then
            rm -rf "${lockdir}.reclaim.$$"
          fi
          continue
        fi
      else
        missing_pid_polls=$((missing_pid_polls + 1))
      fi
    else
      missing_pid_polls=$((missing_pid_polls + 1))
    fi
    if [ "$missing_pid_polls" -ge 10 ]; then
      owner_pid2=""
      if [ -f "$pidfile" ]; then
        owner_pid2="$(tr -d '[:space:]' < "$pidfile" 2>/dev/null || true)"
      fi
      if ! [[ "$owner_pid2" =~ ^[0-9]+$ ]] && mv "$lockdir" "${lockdir}.reclaim.$$" 2>/dev/null; then
        rm -rf "${lockdir}.reclaim.$$"
        missing_pid_polls=0
        continue
      fi
      missing_pid_polls=0
    fi
    if (( SECONDS >= deadline )); then
      echo "ERROR: timed out waiting for setup lock $lockdir" >&2
      return 1
    fi
    sleep 0.2
  done
}

stop_launchagent() {
  local uid gui_target
  uid="$(id -u)"
  gui_target="gui/${uid}/${PLIST_LABEL}"
  if [ -f "$PLIST_PATH" ]; then
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
  fi
  if launchctl print "$gui_target" >/dev/null 2>&1; then
    launchctl bootout "$gui_target" 2>/dev/null || true
  fi
  local _attempt
  for _attempt in 1 2 3 4 5; do
    launchctl print "$gui_target" >/dev/null 2>&1 || return 0
    sleep 1
  done
  launchctl print "$gui_target" >/dev/null 2>&1 || return 0
  return 1
}

if [ "$UNINSTALL" -eq 1 ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] would unload and remove $PLIST_PATH"
    exit 0
  fi
  acquire_setup_lock || exit 1
  if ! stop_launchagent; then
    echo "ERROR: launchd job ${PLIST_LABEL} is still loaded; retaining ${PLIST_PATH}" >&2
    exit 1
  fi
  if [ -f "$PLIST_PATH" ]; then
    rm -f "$PLIST_PATH"
    echo "removed: $PLIST_PATH"
  else
    echo "already absent: $PLIST_PATH"
  fi
  exit 0
fi

# Fail-closed guard: never touch $HOME, /, or TestFlight/SMTP-egress runner directories (including case-insensitive APFS aliases and parents).
is_reserved_runner_dir() {
  local target="$1"
  shift
  [ -n "$target" ] || return 0
  [ "$target" != "/" ] || return 0
  python3 - "$target" "$HOME" "$RESERVED_TF_HOME" "$RESERVED_SMTP_HOME" "$RESERVED_TF_OP" "$RESERVED_SMTP_OP" "$@" <<'PY'
import os
import sys
from pathlib import Path

target_raw = sys.argv[1]
home_raw = sys.argv[2]
reserved_raws = sys.argv[3:]

def existing_ancestors(p: Path):
    cur = p
    while True:
        if cur.exists():
            yield cur
        if cur.parent == cur:
            break
        cur = cur.parent

def same_fs(a: Path, b: Path) -> bool:
    try:
        return a.exists() and b.exists() and os.path.samefile(a, b)
    except OSError:
        return False

target_real = Path(os.path.realpath(target_raw))
target_abs = Path(os.path.abspath(target_raw))
home_real = Path(os.path.realpath(home_raw))

if str(target_real) == "/" or target_real == home_real or same_fs(target_real, home_real) or same_fs(target_abs, home_real):
    sys.exit(0)

t_cf = os.path.normpath(str(target_abs)).casefold()
tr_cf = os.path.normpath(str(target_real)).casefold()
home_cf = os.path.normpath(str(home_real)).casefold()
home_abs_cf = os.path.normpath(os.path.abspath(home_raw)).casefold()

for x in (t_cf, tr_cf):
    if x == "/" or x == home_cf or x == home_abs_cf:
        sys.exit(0)

for res_raw in reserved_raws:
    if not res_raw:
        continue
    res_real = Path(os.path.realpath(res_raw))
    if target_real == res_real or res_real in target_real.parents or target_real in res_real.parents:
        sys.exit(0)
    res_cf = os.path.normpath(str(res_real)).casefold()
    res_abs_cf = os.path.normpath(os.path.abspath(res_raw)).casefold()
    for x in (t_cf, tr_cf):
        for r in (res_cf, res_abs_cf):
            if not r or r == "/":
                continue
            if x == r or x.startswith(r + "/") or r.startswith(x + "/"):
                sys.exit(0)
    for anc in list(existing_ancestors(target_abs)) + list(existing_ancestors(target_real)):
        if same_fs(anc, res_real):
            sys.exit(0)
    if target_real.exists():
        for res_anc in existing_ancestors(res_real):
            if same_fs(target_real, res_anc):
                sys.exit(0)

sys.exit(1)
PY
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

# Fail-closed guard: require self-hosted-native-macos and reject labels that cause Linux CI spillover or TestFlight collision.
validate_labels() {
  local raw="$1" item trimmed lower has_native=0
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
      self-hosted-native-macos)
        has_native=1
        ;;
    esac
  done
  if [ "$has_native" -ne 1 ]; then
    echo "ERROR: --labels must include 'self-hosted-native-macos'" >&2
    exit 2
  fi
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
if is_reserved_runner_dir "$WORK_DIR" "$RUNNER_DIR"; then
  echo "ERROR: refusing unsafe, reserved, or overlapping work dir: '$WORK_DIR' (runner dir: '$RUNNER_DIR')" >&2
  exit 2
fi

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
  # GUI login keychain session used by worldai-testflight-native-mac, while
  # still sharing the operator's macOS user account ($HOME); public-repo
  # workflows targeting self-hosted-native-macos must gate out untrusted fork PRs.
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

runner_binaries_ready() {
  local dir="$1"
  [ -x "${dir}/bin/Runner.Listener" ] && [ -x "${dir}/config.sh" ] && [ -x "${dir}/run.sh" ]
}

if [ "$VERIFY" -eq 1 ]; then
  [ -x "${RUNNER_DIR}/bin/Runner.Listener" ] || { echo "FAIL: missing ${RUNNER_DIR}/bin/Runner.Listener" >&2; exit 1; }
  [ -x "${RUNNER_DIR}/config.sh" ] || { echo "FAIL: missing ${RUNNER_DIR}/config.sh" >&2; exit 1; }
  [ -x "${RUNNER_DIR}/run.sh" ] || { echo "FAIL: missing ${RUNNER_DIR}/run.sh" >&2; exit 1; }
  [ -d "$WORK_DIR" ] || { echo "FAIL: missing work dir ${WORK_DIR}" >&2; exit 1; }
  [ -f "${RUNNER_DIR}/.runner" ] || { echo "FAIL: missing ${RUNNER_DIR}/.runner" >&2; exit 1; }
  [ -f "${RUNNER_DIR}/.ezgha-labels" ] || { echo "FAIL: missing ${RUNNER_DIR}/.ezgha-labels" >&2; exit 1; }
  [ -f "$PLIST_PATH" ] || { echo "FAIL: missing $PLIST_PATH" >&2; exit 1; }
  python3 - "$PLIST_PATH" "$PLIST_LABEL" "$RUNNER_DIR" <<'PY' || exit 1
import os
import plistlib
import sys
from pathlib import Path

plist_path, expected_label, runner_dir = sys.argv[1], sys.argv[2], sys.argv[3]
data = plistlib.loads(Path(plist_path).read_bytes())

if data.get("Label") != expected_label:
    print(f"FAIL: {plist_path} Label={data.get('Label')!r} != {expected_label!r}", file=sys.stderr)
    sys.exit(1)
if data.get("SessionCreate") is not True:
    print(f"FAIL: {plist_path} must set SessionCreate=true (got {data.get('SessionCreate')!r})", file=sys.stderr)
    sys.exit(1)

runner_real = os.path.realpath(runner_dir)
wd = data.get("WorkingDirectory") or ""
if os.path.realpath(wd) != runner_real:
    print(f"FAIL: {plist_path} WorkingDirectory={wd!r} != {runner_dir!r}", file=sys.stderr)
    sys.exit(1)

prog = data.get("ProgramArguments")
expected_runs = {
    os.path.realpath(os.path.join(runner_real, "run.sh")),
    os.path.realpath(os.path.join(runner_real, "runsvc.sh")),
}
if not isinstance(prog, list) or len(prog) < 2 or prog[0] != "/bin/bash" or not isinstance(prog[1], str) or os.path.realpath(prog[1]) not in expected_runs:
    print(f"FAIL: {plist_path} ProgramArguments={prog!r} must target ['/bin/bash', '{runner_dir}/run.sh'] or ['/bin/bash', '{runner_dir}/runsvc.sh']", file=sys.stderr)
    sys.exit(1)
if not os.path.isfile(prog[1]) or not os.access(prog[1], os.R_OK):
    print(f"FAIL: {plist_path} ProgramArguments script missing or unreadable: {prog[1]}", file=sys.stderr)
    sys.exit(1)
PY
  actual_name="$(jq -r '.agentName // ""' "${RUNNER_DIR}/.runner")"
  actual_work="$(jq -r '.workFolder // ""' "${RUNNER_DIR}/.runner")"
  actual_url="$(jq -r '.gitHubUrl // ""' "${RUNNER_DIR}/.runner")"
  actual_labels="$(tr -d '\r\n' < "${RUNNER_DIR}/.ezgha-labels")"
  [ "$actual_name" = "$RUNNER_NAME" ] || { echo "FAIL: .runner agentName='$actual_name' != '$RUNNER_NAME'" >&2; exit 1; }
  [ "$actual_work" = "$WORK_DIR" ] || { echo "FAIL: .runner workFolder='$actual_work' != '$WORK_DIR'" >&2; exit 1; }
  [ -z "$actual_url" ] || [ "$actual_url" = "$RUNNER_URL" ] || { echo "FAIL: .runner gitHubUrl='$actual_url' != '$RUNNER_URL'" >&2; exit 1; }
  [ "$actual_labels" = "$RUNNER_LABELS" ] || { echo "FAIL: .ezgha-labels='$actual_labels' != '$RUNNER_LABELS'" >&2; exit 1; }
  if ! printf '%s\n' "$actual_labels" | tr ',' '\n' | tr '[:upper:]' '[:lower:]' | grep -qx 'self-hosted-native-macos'; then
    echo "FAIL: .ezgha-labels must include self-hosted-native-macos (got '$actual_labels')" >&2
    exit 1
  fi
  if [ "$OFFLINE" -eq 0 ]; then
    command -v "$GH_BIN" >/dev/null 2>&1 || { echo "FAIL: gh binary '$GH_BIN' not found (pass --offline to skip live GitHub check)" >&2; exit 1; }
    runners_pages="$("$GH_BIN" api --paginate "$RUNNERS_API")"
    runner_json="$(printf '%s\n' "$runners_pages" | jq -sc --arg name "$RUNNER_NAME" '[.[].runners[]? | select(.name == $name)] | .[0] // empty')"
    [ -n "$runner_json" ] || { echo "FAIL: runner '$RUNNER_NAME' not found in live $RUNNERS_API" >&2; exit 1; }
    live_labels_csv="$(printf '%s\n' "$runner_json" | jq -r '[.labels[]?.name // empty] | map(ascii_downcase) | unique | join(",")')"
    expected_sorted_csv="$(printf '%s' "$RUNNER_LABELS" | tr ',' '\n' | tr '[:upper:]' '[:lower:]' | sort -u | paste -sd, -)"
    if printf '%s\n' "$live_labels_csv" | tr ',' '\n' | grep -qxE 'self-hosted|worldai-testflight-native-mac'; then
      echo "FAIL: live runner '$RUNNER_NAME' carries forbidden label in '$live_labels_csv'" >&2
      exit 1
    fi
    if ! printf '%s\n' "$live_labels_csv" | tr ',' '\n' | grep -qx 'self-hosted-native-macos'; then
      echo "FAIL: live runner '$RUNNER_NAME' missing required label self-hosted-native-macos in '$live_labels_csv'" >&2
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
  if runner_binaries_ready "$EXISTING_RUNNER_DIR"; then
    echo "BINARY_SOURCE=apfs-clone:${EXISTING_RUNNER_DIR}"
  else
    echo "BINARY_SOURCE=download:v${RUNNER_VERSION}"
  fi
  echo "CONFIG_CMD=${RUNNER_DIR}/config.sh --unattended --url ${RUNNER_URL} --token <redacted-token> --name ${RUNNER_NAME} --work ${WORK_DIR} --labels ${LABELS} --no-default-labels --replace"
  render_plist
  exit 0
fi

acquire_setup_lock || exit 1
mkdir -p "$RUNNER_DIR" "$WORK_DIR" "${HOME}/Library/LaunchAgents" "$LOG_DIR"

if ! runner_binaries_ready "$RUNNER_DIR"; then
  STAGE_DIR="$(mktemp -d "${RUNNER_DIR}.stage.XXXXXX")"
  if runner_binaries_ready "$EXISTING_RUNNER_DIR"; then
    echo "Provisioning runner binaries via staged clone from ${EXISTING_RUNNER_DIR}..."
    shopt -s nullglob
    for item in "${EXISTING_RUNNER_DIR}"/bin* "${EXISTING_RUNNER_DIR}"/externals* \
                "${EXISTING_RUNNER_DIR}/config.sh" "${EXISTING_RUNNER_DIR}/run.sh" \
                "${EXISTING_RUNNER_DIR}/run-helper.sh.template" "${EXISTING_RUNNER_DIR}/env.sh" \
                "${EXISTING_RUNNER_DIR}/safe_sleep.sh"; do
      [ -e "$item" ] || continue
      base="$(basename "$item")"
      cp -Rc "$item" "${STAGE_DIR}/${base}" 2>/dev/null || cp -a "$item" "${STAGE_DIR}/${base}"
    done
    shopt -u nullglob
  else
    echo "Downloading actions-runner v${RUNNER_VERSION} (osx-arm64)..."
    TMP_TGZ="$(mktemp)"
    tarball_url="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-osx-arm64-${RUNNER_VERSION}.tar.gz"
    curl -fsSL "$tarball_url" -o "$TMP_TGZ"
    tar -xzf "$TMP_TGZ" -C "$STAGE_DIR"
    rm -f "$TMP_TGZ"
    TMP_TGZ=""
  fi
  if ! runner_binaries_ready "$STAGE_DIR"; then
    echo "ERROR: staged runner binaries incomplete in ${STAGE_DIR}" >&2
    exit 1
  fi
  if ! stop_launchagent; then
    echo "ERROR: failed to stop ${PLIST_LABEL} before promoting staged runner binaries" >&2
    exit 1
  fi
  shopt -s nullglob
  for item in "${STAGE_DIR}"/*; do
    [ -e "$item" ] || continue
    base="$(basename "$item")"
    rm -rf "${RUNNER_DIR:?}/${base}"
    mv "$item" "${RUNNER_DIR}/${base}"
  done
  shopt -u nullglob
  rm -rf "$STAGE_DIR"
  STAGE_DIR=""
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
  if ! stop_launchagent; then
    echo "ERROR: failed to stop ${PLIST_LABEL}; aborting before removing existing credentials" >&2
    exit 1
  fi

  BACKUP_DIR="${RUNNER_DIR}/.backup-pre-reconfigure.$$"
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  for f in .runner .credentials .credentials_rsaparams .runner_migrated .credentials_migrated .ezgha-labels; do
    if [ -f "${RUNNER_DIR}/${f}" ]; then
      cp -p "${RUNNER_DIR}/${f}" "${BACKUP_DIR}/${f}"
    fi
  done

  rm -f "${RUNNER_DIR}/.runner" "${RUNNER_DIR}/.credentials" "${RUNNER_DIR}/.credentials_rsaparams" "${RUNNER_DIR}/.runner_migrated" "${RUNNER_DIR}/.credentials_migrated"
  config_rc=0
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
  ) || config_rc=$?

  if [ "$config_rc" -ne 0 ]; then
    rm -f "${RUNNER_DIR}/.runner" "${RUNNER_DIR}/.credentials" "${RUNNER_DIR}/.credentials_rsaparams" "${RUNNER_DIR}/.runner_migrated" "${RUNNER_DIR}/.credentials_migrated"
    echo "ERROR: config.sh failed (rc=${config_rc}); service ${PLIST_LABEL} remains stopped and old credentials were not restored. Backup preserved at ${BACKUP_DIR}; re-run --reconfigure after resolving the registration failure." >&2
    exit 4
  fi

  rm -rf "$BACKUP_DIR"
  BACKUP_DIR=""
  printf '%s\n' "$RUNNER_LABELS" > "${RUNNER_DIR}/.ezgha-labels"
fi

printf 'LANG=en_US.UTF-8\n' > "${RUNNER_DIR}/.env"

CANDIDATE_PLIST="${PLIST_PATH}.candidate.$$"
render_plist > "$CANDIDATE_PLIST"
plist_matches=0
if [ -f "$PLIST_PATH" ] && cmp -s "$CANDIDATE_PLIST" "$PLIST_PATH"; then
  plist_matches=1
fi
is_loaded=0
if launchctl print "gui/$(id -u)/${PLIST_LABEL}" >/dev/null 2>&1; then
  is_loaded=1
fi

if [ "$needs_config" -eq 0 ] && [ "$RECONFIGURE" -eq 0 ] && [ "$plist_matches" -eq 1 ]; then
  rm -f "$CANDIDATE_PLIST"
  CANDIDATE_PLIST=""
  if [ "$is_loaded" -eq 1 ]; then
    echo "OK: ${RUNNER_NAME} unchanged; leaving loaded (${PLIST_LABEL})"
  else
    launchctl load -w "$PLIST_PATH"
    launchctl print "gui/$(id -u)/${PLIST_LABEL}" >/dev/null
    echo "OK: ${RUNNER_NAME} loaded (${PLIST_LABEL})"
  fi
else
  if ! stop_launchagent; then
    echo "ERROR: failed to stop ${PLIST_LABEL} before updating ${PLIST_PATH}" >&2
    exit 1
  fi
  mv "$CANDIDATE_PLIST" "$PLIST_PATH"
  CANDIDATE_PLIST=""
  launchctl load -w "$PLIST_PATH"
  launchctl print "gui/$(id -u)/${PLIST_LABEL}" >/dev/null
  echo "OK: ${RUNNER_NAME} installed and loaded (${PLIST_LABEL})"
fi
