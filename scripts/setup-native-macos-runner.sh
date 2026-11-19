#!/usr/bin/env bash
# setup-native-macos-runner.sh — Idempotent setup & verifier for a general-CI
# native macOS GitHub Actions runner (`mac-native-ci-1`). Uses separate
# runner/Scratch `_work` paths and `--no-default-labels --labels self-hosted-native-macos`
# (`SessionCreate=true`) from the TestFlight signing runner
# (`/Users/jleechan/actions-runner`) and Linux `self-hosted` jobs, while sharing
# the operator's macOS UID/`$HOME` (not a user-account sandbox).
#
# Security model:
#   `pull_request` YAML `if:` guards execute from the fork's head commit and are
#   NOT a security boundary against modified fork workflows, and GitHub's
#   `fork-pr-contributor-approval` setting does NOT gate `pull_request_target`
#   workflows; therefore `allows_public_repositories=false` on the target runner
#   group (or `private=true` with `--repo`) is required and enforced fail-closed
#   by `setup-native-macos-runner.sh` (unless `--allow-public-fork-exposure` is
#   explicitly passed after operator workflow review).
# Authority: operator ask (2026-11-18: "fix this we accidentally using gh macOS actions instead of running it on thi machine ... also wes hould have gh actions cost alerts they seemed to not be firing") and origin/main:AGENTS.md:241-250,257-258 (Safety & Monitoring Principles & /code-standards gates).
#
# Usage:
#   setup-native-macos-runner.sh [--dry-run] [--verify] [--uninstall]
#     [--org ORG] [--repo OWNER/REPO] [--runner-group GROUP]
#     [--allow-public-fork-exposure] [--force-replace-name]
#     [--name RUNNER_NAME] [--runner-dir DIR] [--labels CSV]
#     [--work-dir DIR] [--version VER]
set -euo pipefail

RUNNER_ORG="${RUNNER_ORG:-${GITHUB_ORG:-jleechanorg}}"
GITHUB_ORG="$RUNNER_ORG"
RUNNER_REPO="${RUNNER_REPO:-}"
RUNNER_GROUP="${RUNNER_GROUP:-}"
RUNNER_GROUP_SET=0
if [ -n "$RUNNER_GROUP" ]; then
  RUNNER_GROUP_SET=1
fi
ALLOW_PUBLIC_FORK_EXPOSURE="${ALLOW_PUBLIC_FORK_EXPOSURE:-0}"
FORCE_REPLACE_NAME="${FORCE_REPLACE_NAME:-0}"
POST_CONFIG_VERIFY_ATTEMPTS="${POST_CONFIG_VERIFY_ATTEMPTS:-15}"
POST_CONFIG_VERIFY_SLEEP_SEC="${POST_CONFIG_VERIFY_SLEEP_SEC:-2}"
GH_CALL_TIMEOUT_SEC="${GH_CALL_TIMEOUT_SEC:-30}"
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
  --dry-run                       Print planned setup, config.sh command, and LaunchAgent plist without mutating host
  --verify                        Verify existing runner dir, .runner, .ezgha-labels, live GitHub labels, fork protection, work dir, and LaunchAgent
  --reconfigure                   Force unload, removal of local .runner/.credentials*, and fresh ./config.sh (passing --replace only when live runner matches local agentId)
  --offline                       Skip live GitHub API check during --verify (--dry-run never calls GitHub)
  --uninstall                     Unload and remove org.jleechanorg.ezgha-native-macos-runner LaunchAgent
  --org ORG                       GitHub org scope (default: jleechanorg)
  --repo OWNER/REPO               Optional repo scope (overrides --org)
  --runner-group GROUP            Optional GitHub org runner group name (passed as --runnergroup to config.sh)
  --allow-public-fork-exposure    Explicitly allow setup/verify on a public-capable runner group or public --repo after operator workflow review
  --force-replace-name            Allow --replace even when a live runner with the same name exists without matching local .runner agentId
  --name NAME                     Runner name (default: mac-native-ci-1)
  --runner-dir DIR                Install directory (default: $HOME/actions-runner-macos-ci)
  --labels CSV                    Comma-separated labels (default: self-hosted-native-macos)
  --work-dir DIR                  Work directory (default: Scratch native-macos-ci-work)
  --version VER                   Actions runner version fallback download (default: 2.338.2)
  -h, --help                      Show help
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
    --runner-group) RUNNER_GROUP="${2:?missing --runner-group value}"; RUNNER_GROUP_SET=1; shift 2 ;;
    --allow-public-fork-exposure) ALLOW_PUBLIC_FORK_EXPOSURE=1; shift ;;
    --force-replace-name) FORCE_REPLACE_NAME=1; shift ;;
    --name) RUNNER_NAME="${2:?missing --name value}"; shift 2 ;;
    --runner-dir) RUNNER_DIR="${2:?missing --runner-dir value}"; shift 2 ;;
    --labels) LABELS="${2:?missing --labels value}"; RUNNER_LABELS="$LABELS"; shift 2 ;;
    --work-dir) WORK_DIR="${2:?missing --work-dir value}"; shift 2 ;;
    --version) RUNNER_VERSION="${2:?missing --version value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 64 ;;
  esac
done

# Authority: defensive operational guards/bounds (SETUP_LOCK_TIMEOUT_SEC=30, POST_CONFIG_VERIFY_ATTEMPTS=15, POST_CONFIG_VERIFY_SLEEP_SEC=2, GH_CALL_TIMEOUT_SEC=30, --offline scope, --repo/--runner-group exclusion) per operator ask (2026-11-18, #L16) and origin/main:AGENTS.md:246-247,257-258 (self-outage prevention; unrequested defaults disclosed in PR #238).
mode_count=$((VERIFY + UNINSTALL + RECONFIGURE + DRY_RUN))
if [ "$mode_count" -gt 1 ]; then
  echo "ERROR: conflicting action flags (--verify, --uninstall, --reconfigure, --dry-run are mutually exclusive)" >&2
  exit 2
fi

if [ -n "$RUNNER_REPO" ] && [ "$RUNNER_GROUP_SET" -eq 1 ]; then
  echo "ERROR: --runner-group cannot be combined with --repo (runner groups are org/enterprise-scoped)" >&2
  exit 2
fi

if [ "$OFFLINE" -eq 1 ] && [ "$VERIFY" -eq 0 ]; then
  echo "ERROR: --offline is only valid with --verify (mutating setup requires live server-side fork-protection check)" >&2
  exit 2
fi

case "$ALLOW_PUBLIC_FORK_EXPOSURE" in
  0|1) ;;
  *) echo "ERROR: invalid ALLOW_PUBLIC_FORK_EXPOSURE='$ALLOW_PUBLIC_FORK_EXPOSURE' (expected 0 or 1)" >&2; exit 2 ;;
esac

case "$FORCE_REPLACE_NAME" in
  0|1) ;;
  *) echo "ERROR: invalid FORCE_REPLACE_NAME='$FORCE_REPLACE_NAME' (expected 0 or 1)" >&2; exit 2 ;;
esac

case "$POST_CONFIG_VERIFY_ATTEMPTS" in
  ''|*[!0-9]*) echo "ERROR: invalid POST_CONFIG_VERIFY_ATTEMPTS='$POST_CONFIG_VERIFY_ATTEMPTS' (expected positive integer)" >&2; exit 2 ;;
esac
if [ "$POST_CONFIG_VERIFY_ATTEMPTS" -lt 1 ]; then
  echo "ERROR: invalid POST_CONFIG_VERIFY_ATTEMPTS='$POST_CONFIG_VERIFY_ATTEMPTS' (expected >= 1)" >&2
  exit 2
fi

case "$POST_CONFIG_VERIFY_SLEEP_SEC" in
  ''|*[!0-9]*) echo "ERROR: invalid POST_CONFIG_VERIFY_SLEEP_SEC='$POST_CONFIG_VERIFY_SLEEP_SEC' (expected non-negative integer)" >&2; exit 2 ;;
esac

case "$GH_CALL_TIMEOUT_SEC" in
  ''|*[!0-9]*) echo "ERROR: invalid GH_CALL_TIMEOUT_SEC='$GH_CALL_TIMEOUT_SEC' (expected positive integer)" >&2; exit 2 ;;
esac
if [ "$GH_CALL_TIMEOUT_SEC" -lt 1 ]; then
  echo "ERROR: invalid GH_CALL_TIMEOUT_SEC='$GH_CALL_TIMEOUT_SEC' (expected >= 1)" >&2
  exit 2
fi

# Ponytail standalone-libexec rationale: resolve_python3 and fcntl.flock remain inline so setup-native-macos-runner.sh runs standalone without sibling helper dependencies (matching launchd/install-launchagents.sh).
resolve_python3() {
  local cand=""
  if [ -n "${PYTHON3_BIN:-}" ] && [ -x "${PYTHON3_BIN}" ]; then
    printf '%s' "$PYTHON3_BIN"
    return 0
  fi
  cand="$(command -v python3 2>/dev/null || true)"
  if [ -n "$cand" ] && [ -x "$cand" ]; then
    printf '%s' "$cand"
    return 0
  fi
  for cand in /usr/bin/python3 /opt/homebrew/bin/python3; do
    if [ -x "$cand" ]; then
      printf '%s' "$cand"
      return 0
    fi
  done
  return 1
}

canonical_path() {
  local py_bin
  py_bin="$(resolve_python3)" || { echo "ERROR: python3 not found" >&2; return 1; }
  "$py_bin" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

run_with_timeout() {
  local timeout_sec="$1"
  shift
  local timeout_bin="" rc=0
  if command -v timeout >/dev/null 2>&1; then
    timeout_bin="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_bin="gtimeout"
  fi
  if [ -n "$timeout_bin" ]; then
    "$timeout_bin" -k 5 "$timeout_sec" "$@" 9>&- || rc=$?
    return "$rc"
  fi
  local out_tmp
  out_tmp="$(mktemp)" || return 1
  (
    exec 9>&-
    exec "$@"
  ) > "$out_tmp" &
  local pid=$!
  local deadline=$((SECONDS + timeout_sec))
  while kill -0 "$pid" 2>/dev/null && (( SECONDS < deadline )); do
    sleep 0.5
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    sleep 0.2
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rm -f "$out_tmp"
    return 124
  fi
  wait "$pid" || rc=$?
  cat "$out_tmp"
  rm -f "$out_tmp"
  return "$rc"
}

run_gh_api() {
  run_with_timeout "$GH_CALL_TIMEOUT_SEC" "$GH_BIN" "$@"
}

EXISTING_RUNNER_DIR_RAW="${EXISTING_RUNNER_DIR%/}"
RUNNER_DIR="$(canonical_path "$RUNNER_DIR")"
EXISTING_RUNNER_DIR="$(canonical_path "$EXISTING_RUNNER_DIR")"
RESERVED_TF_HOME="$(canonical_path "$HOME/actions-runner")"
RESERVED_SMTP_HOME="$(canonical_path "$HOME/actions-runner-smtp-egress")"
RESERVED_TF_OP="$(canonical_path "/Users/jleechan/actions-runner")"
RESERVED_SMTP_OP="$(canonical_path "/Users/jleechan/actions-runner-smtp-egress")"
PLIST_PATH="${HOME}/Library/LaunchAgents/${PLIST_LABEL}.plist"
LOG_DIR="${HOME}/Library/Logs/${PLIST_LABEL}"
STATE_LOCK_TIMEOUT_SEC="${SETUP_LOCK_TIMEOUT_SEC:-30}"
SETUP_LOCK_FILE=""
SETUP_LOCK_HELD=0
STAGE_TMP=""
TMP_TGZ=""
BACKUP_DIR=""
CANDIDATE_PLIST=""

release_setup_lock() {
  if [ "${SETUP_LOCK_HELD:-0}" -eq 1 ]; then
    exec 9>&-
    SETUP_LOCK_HELD=0
  fi
}

cleanup_setup() {
  [ -z "${STAGE_TMP:-}" ] || rm -rf "${STAGE_TMP:?}"
  [ -z "${TMP_TGZ:-}" ] || rm -f "$TMP_TGZ"
  [ -z "${CANDIDATE_PLIST:-}" ] || rm -f "$CANDIDATE_PLIST"
  release_setup_lock
}
trap cleanup_setup EXIT

acquire_setup_lock() {
  local state_dir="${HOME}/.local/state/ezgha"
  local safe_label py_bin="" rc=0
  safe_label="$(printf '%s' "$PLIST_LABEL" | tr -cd 'A-Za-z0-9_.-')"
  SETUP_LOCK_FILE="${state_dir}/setup-native-macos-runner.${safe_label}.flock"
  if ! py_bin="$(resolve_python3)"; then
    echo "ERROR: python3 not found; cannot acquire setup lock $SETUP_LOCK_FILE" >&2
    return 1
  fi
  mkdir -p "$(dirname "$SETUP_LOCK_FILE")" || return 1
  if ! exec 9>>"$SETUP_LOCK_FILE"; then
    echo "ERROR: failed to open setup lock $SETUP_LOCK_FILE" >&2
    return 1
  fi
  chmod 600 "$SETUP_LOCK_FILE" 2>/dev/null || true
  "$py_bin" - "$STATE_LOCK_TIMEOUT_SEC" <<'PY' || rc=$?
import errno
import fcntl
import sys
import time

timeout = max(0.0, float(sys.argv[1]))
deadline = time.monotonic() + timeout
while True:
    try:
        fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
        sys.exit(0)
    except OSError as exc:
        if exc.errno not in (errno.EACCES, errno.EAGAIN):
            print(f"ERROR: flock failed: {exc}", file=sys.stderr)
            sys.exit(2)
    if time.monotonic() >= deadline:
        sys.exit(1)
    time.sleep(0.1)
PY
  if [ "$rc" -ne 0 ]; then
    exec 9>&-
    if [ "$rc" -eq 1 ]; then
      echo "ERROR: timed out waiting for setup lock $SETUP_LOCK_FILE" >&2
    fi
    return 1
  fi
  SETUP_LOCK_HELD=1
  return 0
}

launchagent_confirmed_unloaded() {
  local gui_target="$1" out="" rc=0
  out="$(launchctl print "$gui_target" 2>&1 9>&-)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    return 1
  fi
  if [ "$rc" -eq 113 ]; then
    return 0
  fi
  if printf '%s' "$out" | grep -qiE 'could not find service|service .* not found|unknown service'; then
    return 0
  fi
  return 1
}

stop_launchagent() {
  local uid gui_target
  uid="$(id -u)" || return 1
  gui_target="gui/${uid}/${PLIST_LABEL}"
  if [ -f "$PLIST_PATH" ]; then
    launchctl unload "$PLIST_PATH" 2>/dev/null 9>&- || true
  fi
  if launchctl print "$gui_target" >/dev/null 2>&1 9>&-; then
    launchctl bootout "$gui_target" 2>/dev/null 9>&- || true
  fi
  local _attempt
  for _attempt in 1 2 3 4 5; do
    if launchagent_confirmed_unloaded "$gui_target"; then
      return 0
    fi
    sleep 1
  done
  if launchagent_confirmed_unloaded "$gui_target"; then
    return 0
  fi
  return 1
}

if [ "$UNINSTALL" -eq 1 ]; then
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

# Authority: fail-closed path-isolation guard per operator ask (2026-11-18, #L16) and origin/main:AGENTS.md:246-247 (self-outage prevention: never touch $HOME, /, or TestFlight/SMTP-egress runner dirs, including case-insensitive APFS aliases and parents).
is_reserved_runner_dir() {
  local target="$1" py_bin="" rc=0
  shift
  [ -n "$target" ] || return 0
  [ "$target" != "/" ] || return 0
  py_bin="$(resolve_python3)" || return 0
  "$py_bin" - "$target" "$HOME" "$RESERVED_TF_HOME" "$RESERVED_SMTP_HOME" "$RESERVED_TF_OP" "$RESERVED_SMTP_OP" "$@" <<'PY' || rc=$?
import os
import sys
from pathlib import Path

try:
    target_raw = sys.argv[1]
    home_raw = sys.argv[2]
    reserved_raws = sys.argv[3:]

    def existing_ancestors(p: Path):
        cur = p
        while True:
            try:
                os.stat(cur)
                yield cur
            except FileNotFoundError:
                pass
            if cur.parent == cur:
                break
            cur = cur.parent

    def same_fs(a: Path, b: Path) -> bool:
        try:
            return os.path.samefile(a, b)
        except FileNotFoundError:
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
        target_exists = True
        try:
            os.stat(target_real)
        except FileNotFoundError:
            target_exists = False
        if target_exists:
            for res_anc in existing_ancestors(res_real):
                if same_fs(target_real, res_anc):
                    sys.exit(0)

    sys.exit(1)
except SystemExit:
    raise
except OSError as exc:
    print(f"ERROR: reserved-dir check failed closed: {exc}", file=sys.stderr)
    sys.exit(0)
except Exception as exc:
    print(f"ERROR: reserved-dir check failed closed: {exc}", file=sys.stderr)
    sys.exit(2)
PY
  if [ "$rc" -eq 1 ]; then
    return 1
  fi
  return 0
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

# Authority: fail-closed label-isolation guard per operator ask (2026-11-18, #L16) and origin/main:AGENTS.md:246-247,257 (require self-hosted-native-macos; reject bare self-hosted and worldai-testflight-native-mac).
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

is_temp_work_dir() {
  local target="$1" py_bin="" rc=0
  [ -n "$target" ] || return 0
  py_bin="$(resolve_python3)" || return 0
  "$py_bin" - "$target" "${TMPDIR:-}" <<'PY' || rc=$?
import os
import sys

try:
    target_raw = sys.argv[1]
    tmpdir_raw = sys.argv[2]

    def resolve_nearest_real(p: str) -> str:
        abs_p = os.path.abspath(p)
        cur = abs_p
        tail = []
        while not os.path.exists(cur):
            parent, name = os.path.split(cur)
            if parent == cur:
                break
            tail.append(name)
            cur = parent
        base_real = os.path.realpath(cur)
        if tail:
            return os.path.normpath(os.path.join(base_real, *reversed(tail)))
        return os.path.normpath(base_real)

    cand_paths = {
        os.path.normpath(os.path.abspath(target_raw)).casefold(),
        os.path.normpath(os.path.realpath(target_raw)).casefold(),
        resolve_nearest_real(target_raw).casefold(),
    }

    banned_raw = ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]
    if tmpdir_raw:
        banned_raw.append(tmpdir_raw)

    banned_roots = set()
    for root in banned_raw:
        if not root:
            continue
        for candidate in (os.path.abspath(root), os.path.realpath(root), resolve_nearest_real(root)):
            norm = os.path.normpath(candidate).casefold()
            if norm and norm != "/":
                banned_roots.add(norm)

    for cand in cand_paths:
        if cand == "/":
            sys.exit(0)
        for root in banned_roots:
            if cand == root or cand.startswith(root + "/"):
                sys.exit(0)

    sys.exit(1)
except SystemExit:
    raise
except Exception as exc:
    print(f"ERROR: temp-dir check failed closed: {exc}", file=sys.stderr)
    sys.exit(2)
PY
  if [ "$rc" -eq 1 ]; then
    return 1
  fi
  return 0
}

resolve_work_dir() {
  if [ -n "$WORK_DIR" ]; then
    local explicit="${WORK_DIR%/}"
    if [[ "$explicit" != /* ]] || [ "$explicit" = "/" ]; then
      echo "ERROR: --work-dir must be a non-root absolute path (got '$WORK_DIR')" >&2
      exit 1
    fi
    if is_temp_work_dir "$explicit"; then
      echo "ERROR: refusing temporary directory for --work-dir: '$explicit' (must not resolve under /tmp, /private/tmp, /var/folders, or \$TMPDIR)" >&2
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
      if ! is_temp_work_dir "$resolved" && { [ -d "$resolved" ] || [ -d "$parent" ]; }; then
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
    if [[ "$scratch_root" == /* ]] && [ "$scratch_root" != "/" ] && ! is_temp_work_dir "$scratch_root" && [ -d "$scratch_root" ]; then
      printf '%s' "${scratch_root}/native-macos-ci-work"
      return 0
    fi
  fi

  echo "ERROR: could not resolve an existing Scratch directory via scratch-dir.sh or 'diskm volume path scratch'; pass --work-dir explicitly" >&2
  exit 1
}

WORK_DIR="$(resolve_work_dir)" || exit 1
if is_temp_work_dir "$WORK_DIR" || is_reserved_runner_dir "$WORK_DIR" "$RUNNER_DIR"; then
  echo "ERROR: refusing unsafe, temporary, reserved, or overlapping work dir: '$WORK_DIR' (runner dir: '$RUNNER_DIR')" >&2
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
  # still sharing the operator's macOS user account ($HOME).
  # NOTE: pull_request YAML `if:` guards execute from the fork's head commit and
  # are NOT a security boundary against modified fork workflows, and GitHub's
  # fork-pr-contributor-approval setting does NOT gate pull_request_target;
  # allows_public_repositories=false on the runner group or private --repo is
  # required and enforced fail-closed (unless --allow-public-fork-exposure).
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
  local dir="$1" py_bin=""
  [ -d "$dir" ] || return 1
  py_bin="$(resolve_python3)" || return 1
  "$py_bin" - "$dir" <<'PY'
import os
import sys

root = sys.argv[1]
if not os.path.isdir(root):
    sys.exit(1)
root_real = os.path.realpath(root)
prefix = root_real.rstrip("/") + "/"

def is_inside(path: str) -> bool:
    rp = os.path.realpath(path)
    return rp.startswith(prefix)

for rel in ("bin/Runner.Listener", "config.sh", "run.sh"):
    p = os.path.join(root, rel)
    if not (os.path.isfile(p) and os.access(p, os.X_OK) and is_inside(p)):
        sys.exit(1)

for rel in ("run-helper.sh.template", "env.sh"):
    p = os.path.join(root, rel)
    if not (os.path.isfile(p) and is_inside(p)):
        sys.exit(1)

runsvc = os.path.join(root, "runsvc.sh")
if os.path.lexists(runsvc) and not (os.path.isfile(runsvc) and is_inside(runsvc)):
    sys.exit(1)

has_externals = False
try:
    entries = list(os.scandir(root))
except OSError:
    sys.exit(1)

for entry in entries:
    if entry.name == "externals" or entry.name.startswith("externals."):
        if os.path.isdir(entry.path) and is_inside(entry.path):
            has_externals = True
if not has_externals:
    sys.exit(1)

top_scripts = {"config.sh", "run.sh", "runsvc.sh", "run-helper.sh.template", "env.sh", "safe_sleep.sh"}
walk_roots = []
for entry in entries:
    if entry.name.startswith("bin") or entry.name.startswith("externals") or entry.name in top_scripts:
        if os.path.islink(entry.path):
            if not is_inside(entry.path):
                sys.exit(1)
        if (entry.name.startswith("bin") or entry.name.startswith("externals")) and os.path.isdir(entry.path):
            walk_roots.append(entry.path)
            if os.path.islink(entry.path):
                walk_roots.append(os.path.realpath(entry.path))

seen_dirs = set()
for wroot in walk_roots:
    wreal = os.path.realpath(wroot)
    if not wreal.startswith(prefix) and wreal != root_real:
        sys.exit(1)
    if wreal in seen_dirs:
        continue
    seen_dirs.add(wreal)
    for cur, dirnames, filenames in os.walk(wreal, followlinks=False):
        for name in dirnames + filenames:
            p = os.path.join(cur, name)
            if os.path.islink(p) and not is_inside(p):
                sys.exit(1)

sys.exit(0)
PY
}

VERIFIED_RUNNER_GROUP_ID=""

runner_configured() {
  local dir="${1:-$RUNNER_DIR}"
  [ -f "${dir}/.runner" ] && [ -f "${dir}/.credentials" ]
}

# Authority: fail-closed server-side fork-PR protection per operator ask (2026-11-18, #L16) and origin/main:AGENTS.md:246-247,257 (exit 5 before token minting/setup/verify).
verify_server_fork_protection() {
  command -v "$GH_BIN" >/dev/null 2>&1 || {
    echo "ERROR: gh binary '$GH_BIN' not found (required for server-side fork-protection check)" >&2
    exit 5
  }
  VERIFIED_RUNNER_GROUP_ID=""
  local is_priv="" groups_json="" group_json="" allows_pub="" restricted_wf="" selected_wf_count=""
  if [ -n "$RUNNER_REPO" ]; then
    if ! is_priv="$(run_gh_api api "repos/${RUNNER_REPO}" --jq '.private')"; then
      echo "ERROR: failed to query visibility for repo '${RUNNER_REPO}'" >&2
      exit 5
    fi
    if [ "$is_priv" != "true" ]; then
      if [ "$ALLOW_PUBLIC_FORK_EXPOSURE" = "1" ]; then
        echo "WARNING: non-private repo '${RUNNER_REPO}' (private=${is_priv:-<unset>}) allowed via --allow-public-fork-exposure; pull_request_target bypasses GitHub fork-approval settings, so public access requires explicit operator workflow review" >&2
      else
        echo "ERROR: repo '${RUNNER_REPO}' has private='${is_priv:-<unset>}' (non-private); pull_request_target bypasses GitHub fork-approval settings so public access requires explicit operator workflow review + --allow-public-fork-exposure (or moving the runner to a private-only repo/runner group)" >&2
        exit 5
      fi
    fi
  else
    if ! groups_json="$(run_gh_api api --paginate "orgs/${RUNNER_ORG}/actions/runner-groups")"; then
      echo "ERROR: failed to query runner groups for org '${RUNNER_ORG}'" >&2
      exit 5
    fi
    if ! group_json="$(printf '%s\n' "$groups_json" | jq -sc --arg g "$RUNNER_GROUP" '[.[].runner_groups[]? | (if $g != "" then select(.name == $g) else select(.default == true) end)] | .[0] // empty')"; then
      echo "ERROR: failed to parse runner groups JSON for org '${RUNNER_ORG}'" >&2
      exit 5
    fi
    if [ -z "$group_json" ]; then
      echo "ERROR: runner group '${RUNNER_GROUP:-<default>}' not found in org '${RUNNER_ORG}'" >&2
      exit 5
    fi
    if ! VERIFIED_RUNNER_GROUP_ID="$(printf '%s\n' "$group_json" | jq -r '.id // empty')"; then
      echo "ERROR: failed to parse runner group id in org '${RUNNER_ORG}'" >&2
      exit 5
    fi
    [ -n "$VERIFIED_RUNNER_GROUP_ID" ] || {
      echo "ERROR: runner group '${RUNNER_GROUP:-<default>}' missing id in org '${RUNNER_ORG}'" >&2
      exit 5
    }
    if ! allows_pub="$(printf '%s\n' "$group_json" | jq -r 'if has("allows_public_repositories") then (.allows_public_repositories | tostring) else "" end')" || \
       ! restricted_wf="$(printf '%s\n' "$group_json" | jq -r 'if has("restricted_to_workflows") then (.restricted_to_workflows | tostring) else "unknown" end')" || \
       ! selected_wf_count="$(printf '%s\n' "$group_json" | jq -r '(.selected_workflows // []) | length')"; then
      echo "ERROR: failed to parse runner group policy fields in org '${RUNNER_ORG}'" >&2
      exit 5
    fi
    if [ "$allows_pub" != "false" ]; then
      if [ "$ALLOW_PUBLIC_FORK_EXPOSURE" = "1" ]; then
        echo "WARNING: org '${RUNNER_ORG}' runner group '${RUNNER_GROUP:-<default>}' (id=${VERIFIED_RUNNER_GROUP_ID}, allows_public_repositories=${allows_pub:-<unset>}, restricted_to_workflows=${restricted_wf}, selected_workflows=${selected_wf_count}) allowed via --allow-public-fork-exposure; pull_request_target bypasses GitHub fork-approval settings, so public access requires explicit operator workflow review" >&2
      else
        echo "ERROR: org '${RUNNER_ORG}' runner group '${RUNNER_GROUP:-<default>}' (id=${VERIFIED_RUNNER_GROUP_ID}) has allows_public_repositories='${allows_pub:-<unset>}' (restricted_to_workflows=${restricted_wf}, selected_workflows=${selected_wf_count}); pull_request_target bypasses GitHub fork-approval settings so public access requires explicit operator workflow review + --allow-public-fork-exposure (or moving the runner to a private-only runner group with allows_public_repositories=false)" >&2
        exit 5
      fi
    fi
  fi
}

verify_live_runner_state_once() {
  local mode="$1" local_agent_id="$2"
  local runners_pages="" runner_json="" live_status=""
  local group_runners_pages="" in_group=0 live_labels_csv="" expected_sorted_csv=""

  if ! runners_pages="$(run_gh_api api --paginate "$RUNNERS_API")"; then
    echo "ERROR: failed to query live runners from $RUNNERS_API" >&2
    return 2
  fi
  if ! runner_json="$(printf '%s\n' "$runners_pages" | jq -sc --arg name "$RUNNER_NAME" --arg id "$local_agent_id" '[.[].runners[]? | select(((.id | tostring) == $id) and (.name == $name))] | .[0] // empty')"; then
    echo "ERROR: failed to parse live runners JSON from $RUNNERS_API" >&2
    return 2
  fi
  if [ -z "$runner_json" ]; then
    echo "FAIL: runner '$RUNNER_NAME' (agentId=$local_agent_id) not found in live $RUNNERS_API" >&2
    return 1
  fi

  if [ "$mode" = "verify" ]; then
    if ! live_status="$(printf '%s\n' "$runner_json" | jq -r '.status // empty' | tr '[:upper:]' '[:lower:]')"; then
      echo "ERROR: failed to parse live runner status for '$RUNNER_NAME' (agentId=$local_agent_id)" >&2
      return 2
    fi
    if [ "$live_status" != "online" ]; then
      echo "FAIL: live runner '$RUNNER_NAME' (agentId=$local_agent_id) status is '${live_status:-<unset>}' (expected 'online')" >&2
      return 1
    fi
  fi

  if ! live_labels_csv="$(printf '%s\n' "$runner_json" | jq -r '[.labels[]?.name // empty] | map(ascii_downcase) | unique | join(",")')"; then
    echo "ERROR: failed to parse live labels for runner '$RUNNER_NAME' (agentId=$local_agent_id)" >&2
    return 2
  fi
  if ! expected_sorted_csv="$(printf '%s' "$RUNNER_LABELS" | tr ',' '\n' | tr '[:upper:]' '[:lower:]' | sort -u | paste -sd, -)"; then
    echo "ERROR: failed to normalize expected labels '$RUNNER_LABELS'" >&2
    return 2
  fi
  if printf '%s\n' "$live_labels_csv" | tr ',' '\n' | grep -qxE 'self-hosted|worldai-testflight-native-mac'; then
    echo "FAIL: live runner '$RUNNER_NAME' (agentId=$local_agent_id) carries forbidden label in '$live_labels_csv'" >&2
    return 1
  fi
  if ! printf '%s\n' "$live_labels_csv" | tr ',' '\n' | grep -qx 'self-hosted-native-macos'; then
    echo "FAIL: live runner '$RUNNER_NAME' (agentId=$local_agent_id) missing required label self-hosted-native-macos in '$live_labels_csv'" >&2
    return 1
  fi
  if [ "$live_labels_csv" != "$expected_sorted_csv" ]; then
    echo "FAIL: live labels '$live_labels_csv' != expected '$expected_sorted_csv'" >&2
    return 1
  fi

  if [ -z "$RUNNER_REPO" ]; then
    if [ -z "$VERIFIED_RUNNER_GROUP_ID" ]; then
      echo "FAIL: missing verified runner group id for '${RUNNER_GROUP:-<default>}' in org '${RUNNER_ORG}'" >&2
      return 1
    fi
    if ! group_runners_pages="$(run_gh_api api --paginate "orgs/${RUNNER_ORG}/actions/runner-groups/${VERIFIED_RUNNER_GROUP_ID}/runners")"; then
      echo "ERROR: failed to query runners for org '${RUNNER_ORG}' runner group '${RUNNER_GROUP:-<default>}' (id=${VERIFIED_RUNNER_GROUP_ID})" >&2
      return 2
    fi
    if ! in_group="$(printf '%s\n' "$group_runners_pages" | jq -sc --arg id "$local_agent_id" --arg name "$RUNNER_NAME" '[.[].runners[]? | select(((.id | tostring) == $id) and (.name == $name))] | length')"; then
      echo "ERROR: failed to parse runners JSON for org '${RUNNER_ORG}' runner group '${RUNNER_GROUP:-<default>}' (id=${VERIFIED_RUNNER_GROUP_ID})" >&2
      return 2
    fi
    if [[ ! "$in_group" =~ ^[0-9]+$ ]] || [ "$in_group" -lt 1 ]; then
      echo "FAIL: runner '$RUNNER_NAME' (agentId=$local_agent_id) is not a member of org '${RUNNER_ORG}' runner group '${RUNNER_GROUP:-<default>}' (id=${VERIFIED_RUNNER_GROUP_ID})" >&2
      return 1
    fi
  fi
  return 0
}

# Authority: live runner agentId/group/label binding per operator ask (2026-11-18, #L16) and origin/main:AGENTS.md:246-247,257 (shared across setup, post_config, and --verify).
verify_live_runner_state() {
  local mode="${1:?missing mode}"
  local local_agent_id="" max_attempts=1 attempt=1 once_rc=0

  if [ "$mode" = "verify" ] || { [ -z "$RUNNER_REPO" ] && [ -z "$VERIFIED_RUNNER_GROUP_ID" ]; }; then
    verify_server_fork_protection
  fi

  if ! runner_configured "$RUNNER_DIR"; then
    echo "FAIL: missing ${RUNNER_DIR}/.runner or ${RUNNER_DIR}/.credentials" >&2
    return 1
  fi
  local_agent_id="$(jq -r '.agentId // empty' "${RUNNER_DIR}/.runner" 2>/dev/null || true)"
  if [[ ! "$local_agent_id" =~ ^[0-9]+$ ]] || [ "$local_agent_id" -le 0 ]; then
    echo "FAIL: .runner missing valid positive numeric agentId (got '${local_agent_id}')" >&2
    return 1
  fi

  if [ "$mode" = "post_config" ]; then
    max_attempts="$POST_CONFIG_VERIFY_ATTEMPTS"
  fi

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    once_rc=0
    verify_live_runner_state_once "$mode" "$local_agent_id" || once_rc=$?
    if [ "$once_rc" -eq 0 ]; then
      return 0
    fi
    if [ "$mode" = "setup" ] && [ "$once_rc" -eq 2 ]; then
      exit 1
    fi
    if [ "$attempt" -lt "$max_attempts" ]; then
      echo "INFO: post-config live runner verification for '$RUNNER_NAME' (agentId=$local_agent_id) incomplete (attempt ${attempt}/${max_attempts}); retrying in ${POST_CONFIG_VERIFY_SLEEP_SEC}s..." >&2
      sleep "$POST_CONFIG_VERIFY_SLEEP_SEC"
    fi
  done

  return 1
}

verify_runner_online() {
  local max_attempts="${1:-1}"
  local local_agent_id="" attempt=1 runners_pages="" runner_json="" live_status=""

  if ! runner_configured "$RUNNER_DIR"; then
    echo "FAIL: missing ${RUNNER_DIR}/.runner or ${RUNNER_DIR}/.credentials" >&2
    return 1
  fi
  local_agent_id="$(jq -r '.agentId // empty' "${RUNNER_DIR}/.runner" 2>/dev/null || true)"
  if [[ ! "$local_agent_id" =~ ^[0-9]+$ ]] || [ "$local_agent_id" -le 0 ]; then
    echo "FAIL: .runner missing valid positive numeric agentId (got '${local_agent_id}')" >&2
    return 1
  fi

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    live_status=""
    if runners_pages="$(run_gh_api api --paginate "$RUNNERS_API")"; then
      if runner_json="$(printf '%s\n' "$runners_pages" | jq -sc --arg name "$RUNNER_NAME" --arg id "$local_agent_id" '[.[].runners[]? | select(((.id | tostring) == $id) and (.name == $name))] | .[0] // empty')"; then
        if [ -n "$runner_json" ]; then
          if ! live_status="$(printf '%s\n' "$runner_json" | jq -r '.status // empty' | tr '[:upper:]' '[:lower:]')"; then
            live_status=""
          fi
          if [ "$live_status" = "online" ]; then
            return 0
          fi
          echo "INFO: runner '$RUNNER_NAME' (agentId=$local_agent_id) status is '${live_status:-<unset>}' (attempt ${attempt}/${max_attempts})" >&2
        else
          echo "INFO: runner '$RUNNER_NAME' (agentId=$local_agent_id) not found in live $RUNNERS_API (attempt ${attempt}/${max_attempts})" >&2
        fi
      else
        echo "WARNING: failed to parse live runners JSON from $RUNNERS_API (attempt ${attempt}/${max_attempts})" >&2
      fi
    else
      echo "WARNING: failed to query live runners from $RUNNERS_API (attempt ${attempt}/${max_attempts})" >&2
    fi
    if [ "$attempt" -lt "$max_attempts" ]; then
      sleep "$POST_CONFIG_VERIFY_SLEEP_SEC"
    fi
  done

  echo "ERROR: runner '$RUNNER_NAME' (agentId=$local_agent_id) is not online on GitHub (last status='${live_status:-<unset>}'; inspect ${LOG_DIR} or pass --reconfigure if registration is invalid)" >&2
  return 1
}

if [ "$VERIFY" -eq 1 ]; then
  [ -x "${RUNNER_DIR}/bin/Runner.Listener" ] || { echo "FAIL: missing ${RUNNER_DIR}/bin/Runner.Listener" >&2; exit 1; }
  [ -x "${RUNNER_DIR}/config.sh" ] || { echo "FAIL: missing ${RUNNER_DIR}/config.sh" >&2; exit 1; }
  [ -x "${RUNNER_DIR}/run.sh" ] || { echo "FAIL: missing ${RUNNER_DIR}/run.sh" >&2; exit 1; }
  [ -f "${RUNNER_DIR}/run-helper.sh.template" ] || { echo "FAIL: missing ${RUNNER_DIR}/run-helper.sh.template" >&2; exit 1; }
  [ -f "${RUNNER_DIR}/env.sh" ] || { echo "FAIL: missing ${RUNNER_DIR}/env.sh" >&2; exit 1; }
  if [ ! -d "${RUNNER_DIR}/externals" ] && ! compgen -G "${RUNNER_DIR}/externals.*" >/dev/null; then
    echo "FAIL: missing ${RUNNER_DIR}/externals" >&2
    exit 1
  fi
  if ! runner_binaries_ready "$RUNNER_DIR"; then
    echo "FAIL: runner binaries in ${RUNNER_DIR} are incomplete or contain symlink targets resolving outside ${RUNNER_DIR}" >&2
    exit 1
  fi
  [ -d "$WORK_DIR" ] || { echo "FAIL: missing work dir ${WORK_DIR}" >&2; exit 1; }
  runner_configured "$RUNNER_DIR" || { echo "FAIL: missing ${RUNNER_DIR}/.runner or ${RUNNER_DIR}/.credentials" >&2; exit 1; }
  [ -f "${RUNNER_DIR}/.ezgha-labels" ] || { echo "FAIL: missing ${RUNNER_DIR}/.ezgha-labels" >&2; exit 1; }
  [ -f "$PLIST_PATH" ] || { echo "FAIL: missing $PLIST_PATH" >&2; exit 1; }
  py_bin="$(resolve_python3)" || { echo "FAIL: python3 not found" >&2; exit 1; }
  "$py_bin" - "$PLIST_PATH" "$PLIST_LABEL" "$RUNNER_DIR" <<'PY' || exit 1
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
runner_prefix = runner_real.rstrip("/") + "/"
expected_runs = {
    os.path.realpath(os.path.join(runner_real, "run.sh")),
    os.path.realpath(os.path.join(runner_real, "runsvc.sh")),
}
prog_real = os.path.realpath(prog[1]) if isinstance(prog, list) and len(prog) >= 2 and isinstance(prog[1], str) else ""
if not isinstance(prog, list) or len(prog) < 2 or prog[0] != "/bin/bash" or not isinstance(prog[1], str) or not prog_real.startswith(runner_prefix) or prog_real not in expected_runs:
    print(f"FAIL: {plist_path} ProgramArguments={prog!r} must target ['/bin/bash', '{runner_dir}/run.sh'] or ['/bin/bash', '{runner_dir}/runsvc.sh'] inside {runner_dir}", file=sys.stderr)
    sys.exit(1)
if not os.path.isfile(prog[1]) or not os.access(prog[1], os.R_OK):
    print(f"FAIL: {plist_path} ProgramArguments script missing or unreadable: {prog[1]}", file=sys.stderr)
    sys.exit(1)
PY
  local_agent_id="$(jq -r '.agentId // empty' "${RUNNER_DIR}/.runner" 2>/dev/null || true)"
  if [[ ! "$local_agent_id" =~ ^[0-9]+$ ]] || [ "$local_agent_id" -le 0 ]; then
    echo "FAIL: .runner missing valid positive numeric agentId (got '${local_agent_id}')" >&2
    exit 1
  fi
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
    verify_live_runner_state verify || exit 1
  fi
  if [ -f "${RUNNER_DIR}/.ezgha-group" ]; then
    actual_group="$(tr -d '\r\n' < "${RUNNER_DIR}/.ezgha-group")"
    [ "$actual_group" = "$RUNNER_GROUP" ] || { echo "FAIL: .ezgha-group='$actual_group' != '$RUNNER_GROUP'" >&2; exit 1; }
  elif [ -n "$RUNNER_GROUP" ]; then
    echo "FAIL: missing .ezgha-group for --runner-group '$RUNNER_GROUP'" >&2
    exit 1
  fi
  launchctl print "gui/$(id -u)/${PLIST_LABEL}" >/dev/null 9>&- || { echo "FAIL: launchd job ${PLIST_LABEL} not loaded" >&2; exit 1; }
  echo "OK: ${RUNNER_NAME} verified at ${RUNNER_DIR} (work=${WORK_DIR}, labels=${RUNNER_LABELS})"
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "RUNNER_NAME=${RUNNER_NAME}"
  echo "RUNNER_DIR=${RUNNER_DIR}"
  echo "WORK_DIR=${WORK_DIR}"
  echo "RUNNER_URL=${RUNNER_URL}"
  echo "RUNNER_GROUP=${RUNNER_GROUP}"
  echo "ALLOW_PUBLIC_FORK_EXPOSURE=${ALLOW_PUBLIC_FORK_EXPOSURE}"
  echo "LABELS=${LABELS}"
  echo "PLIST_PATH=${PLIST_PATH}"
  if runner_binaries_ready "$EXISTING_RUNNER_DIR"; then
    echo "BINARY_SOURCE=apfs-clone:${EXISTING_RUNNER_DIR}"
  else
    echo "BINARY_SOURCE=download:v${RUNNER_VERSION}"
  fi
  dry_config_cmd="ACTIONS_RUNNER_INPUT_TOKEN=<redacted> ${RUNNER_DIR}/config.sh --unattended --url ${RUNNER_URL} --name ${RUNNER_NAME} --work ${WORK_DIR} --labels ${LABELS} --no-default-labels"
  if [ "$FORCE_REPLACE_NAME" -eq 1 ]; then
    dry_config_cmd+=" --replace"
  fi
  if [ -n "$RUNNER_GROUP" ]; then
    dry_config_cmd+=" --runnergroup ${RUNNER_GROUP}"
  fi
  echo "CONFIG_CMD=${dry_config_cmd}"
  render_plist
  exit 0
fi

acquire_setup_lock || exit 1
verify_server_fork_protection

# Authority: safe --replace collision guard per operator ask (2026-11-18, #L16) and origin/main:AGENTS.md:246-247 (self-outage prevention: never hijack another host's runner registration).
resolve_replace_collision_policy() {
  local prev_id="${1:-}" pre_runners_pages="" colliding_ids=""
  use_replace=0
  if ! pre_runners_pages="$(run_gh_api api --paginate "$RUNNERS_API")"; then
    echo "ERROR: failed to query live runners from $RUNNERS_API before configuration" >&2
    exit 1
  fi
  colliding_ids="$(printf '%s\n' "$pre_runners_pages" | jq -sr --arg name "$RUNNER_NAME" '[.[].runners[]? | select(.name == $name) | (.id | tostring)] | unique | join(",")')"
  if [ -n "$colliding_ids" ]; then
    if [ "$FORCE_REPLACE_NAME" -eq 1 ]; then
      use_replace=1
    elif [ -n "$prev_id" ] && [ "$colliding_ids" = "$prev_id" ]; then
      use_replace=1
    else
      echo "ERROR: live runner '${RUNNER_NAME}' (id=${colliding_ids}) already exists on GitHub (${RUNNERS_API}) while local .runner agentId is '${prev_id:-<none>}'; refusing --replace to avoid colliding with another host's runner (pass --force-replace-name to override)" >&2
      exit 6
    fi
  fi
}

# Register or refresh configuration when .runner/.credentials/.ezgha-labels/.ezgha-group is missing, differs, live GitHub state drifted, or --reconfigure is passed.
# Run this determination and the live name-collision precheck BEFORE staging binaries or stopping the incumbent LaunchAgent.
needs_config=1
if [ "$RECONFIGURE" -eq 0 ] && runner_configured "$RUNNER_DIR" && [ -f "${RUNNER_DIR}/.ezgha-labels" ] && [ -f "${RUNNER_DIR}/.ezgha-group" ]; then
  existing_agent_id="$(jq -r '.agentId // empty' "${RUNNER_DIR}/.runner" 2>/dev/null || true)"
  existing_name="$(jq -r '.agentName // ""' "${RUNNER_DIR}/.runner" 2>/dev/null || true)"
  existing_work="$(jq -r '.workFolder // ""' "${RUNNER_DIR}/.runner" 2>/dev/null || true)"
  existing_url="$(jq -r '.gitHubUrl // ""' "${RUNNER_DIR}/.runner" 2>/dev/null || true)"
  existing_labels="$(tr -d '\r\n' < "${RUNNER_DIR}/.ezgha-labels" 2>/dev/null || true)"
  existing_group="$(tr -d '\r\n' < "${RUNNER_DIR}/.ezgha-group" 2>/dev/null || true)"
  if [[ "$existing_agent_id" =~ ^[0-9]+$ ]] && [ "$existing_agent_id" -gt 0 ] && \
     [ "$existing_name" = "$RUNNER_NAME" ] && [ "$existing_work" = "$WORK_DIR" ] && \
     [ "$existing_url" = "$RUNNER_URL" ] && [ "$existing_labels" = "$RUNNER_LABELS" ] && \
     [ "$existing_group" = "$RUNNER_GROUP" ]; then
    needs_config=0
  fi
fi

if [ "$needs_config" -eq 0 ]; then
  if ! verify_live_runner_state setup; then
    echo "Live GitHub runner state drifted or missing; scheduling reconfiguration..." >&2
    needs_config=1
  fi
fi

use_replace=0
prev_agent_id=""
if [ "$needs_config" -eq 1 ]; then
  if [ -f "${RUNNER_DIR}/.runner" ]; then
    raw_prev_agent_id="$(jq -r '.agentId // empty' "${RUNNER_DIR}/.runner" 2>/dev/null || true)"
    if [[ "$raw_prev_agent_id" =~ ^[0-9]+$ ]] && [ "$raw_prev_agent_id" -gt 0 ]; then
      prev_agent_id="$raw_prev_agent_id"
    fi
  elif [ -d "$RUNNER_DIR" ]; then
    shopt -s nullglob
    backup_runner_files=("${RUNNER_DIR}"/.backup-pre-reconfigure.*/.runner)
    shopt -u nullglob
    if [ "${#backup_runner_files[@]}" -gt 0 ]; then
      backup_ids=""
      for bf in "${backup_runner_files[@]}"; do
        [ -f "$bf" ] || continue
        cand_id="$(jq -r '.agentId // empty' "$bf" 2>/dev/null || true)"
        if [ -n "$cand_id" ]; then
          backup_ids="${backup_ids:+${backup_ids}$'\n'}${cand_id}"
        fi
      done
      if [ -n "$backup_ids" ]; then
        unique_backup_ids="$(printf '%s\n' "$backup_ids" | sort -u)"
        if [ "$(printf '%s\n' "$unique_backup_ids" | wc -l | tr -d '[:space:]')" -eq 1 ] && \
           [[ "$unique_backup_ids" =~ ^[0-9]+$ ]] && [ "$unique_backup_ids" -gt 0 ]; then
          prev_agent_id="$unique_backup_ids"
        fi
      fi
    fi
  fi

  resolve_replace_collision_policy "$prev_agent_id"
fi

prepare_staged_binaries() {
  mkdir -p "$(dirname "$RUNNER_DIR")"
  STAGE_TMP="$(mktemp -d "${RUNNER_DIR%/}.staging.XXXXXX")"
  if runner_binaries_ready "$EXISTING_RUNNER_DIR"; then
    echo "Provisioning runner binaries via staged clone from ${EXISTING_RUNNER_DIR}..."
    existing_canon="$(canonical_path "$EXISTING_RUNNER_DIR")"
    shopt -s nullglob
    for item in "${EXISTING_RUNNER_DIR}"/bin* "${EXISTING_RUNNER_DIR}"/externals* \
                "${EXISTING_RUNNER_DIR}/config.sh" "${EXISTING_RUNNER_DIR}/run.sh" \
                "${EXISTING_RUNNER_DIR}/runsvc.sh" \
                "${EXISTING_RUNNER_DIR}/run-helper.sh.template" "${EXISTING_RUNNER_DIR}/env.sh" \
                "${EXISTING_RUNNER_DIR}/safe_sleep.sh"; do
      [ -e "$item" ] || continue
      base="$(basename "$item")"
      if [ -L "$item" ]; then
        link_target="$(readlink "$item")"
        if [[ "$link_target" != /* && "$link_target" != *..* ]]; then
          ln -sfn "$link_target" "${STAGE_TMP}/${base}"
        else
          rel_target=""
          if [[ "$link_target" == "${EXISTING_RUNNER_DIR_RAW}/"* ]]; then
            rel_target="${link_target#"${EXISTING_RUNNER_DIR_RAW}/"}"
          elif [[ "$link_target" == "${existing_canon}/"* ]]; then
            rel_target="${link_target#"${existing_canon}/"}"
          else
            target_canon="$(canonical_path "$link_target" 2>/dev/null || true)"
            if [[ "$target_canon" == "${existing_canon}/"* ]]; then
              rel_target="${target_canon#"${existing_canon}/"}"
            fi
          fi
          if [ -n "$rel_target" ] && [[ "$rel_target" != /* && "$rel_target" != *..* ]]; then
            ln -sfn "$rel_target" "${STAGE_TMP}/${base}"
          else
            cp -RL "$item" "${STAGE_TMP}/${base}"
          fi
        fi
      else
        cp -Rc "$item" "${STAGE_TMP}/${base}" 2>/dev/null || cp -a "$item" "${STAGE_TMP}/${base}"
      fi
    done
    shopt -u nullglob
    py_bin="$(resolve_python3)" || { echo "ERROR: python3 not found" >&2; exit 1; }
    "$py_bin" - "$STAGE_TMP" "$EXISTING_RUNNER_DIR_RAW" "$existing_canon" <<'PY'
import os
import shutil
import sys

stage_dir, existing_raw, existing_canon = sys.argv[1], sys.argv[2], sys.argv[3]
stage_real = os.path.realpath(stage_dir)
stage_prefix = stage_real.rstrip("/") + "/"
prefixes = sorted({p.rstrip("/") + "/" for p in (existing_raw, existing_canon) if p}, key=len, reverse=True)

def strip_prefix(path: str):
    for pref in prefixes:
        if path.startswith(pref):
            return path[len(pref):]
    return None

def materialize(link_path: str, resolved: str):
    if not os.path.exists(resolved):
        return
    os.unlink(link_path)
    if os.path.isdir(resolved):
        shutil.copytree(resolved, link_path, symlinks=False)
    else:
        shutil.copy2(resolved, link_path)

for cur, dirnames, filenames in os.walk(stage_real, followlinks=False):
    for name in dirnames + filenames:
        p = os.path.join(cur, name)
        if not os.path.islink(p):
            continue
        raw_link = os.readlink(p)
        resolved = os.path.realpath(p)
        rel = strip_prefix(raw_link) or strip_prefix(resolved)
        if rel is not None:
            candidate = os.path.join(stage_real, rel)
            if os.path.lexists(candidate):
                new_rel = os.path.relpath(candidate, start=os.path.dirname(os.path.abspath(p)))
                os.unlink(p)
                os.symlink(new_rel, p)
            else:
                materialize(p, resolved)
        elif not resolved.startswith(stage_prefix) and resolved != stage_real:
            materialize(p, resolved)
PY
  else
    echo "Downloading actions-runner v${RUNNER_VERSION} (osx-arm64)..."
    TMP_TGZ="$(mktemp)"
    tarball_url="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-osx-arm64-${RUNNER_VERSION}.tar.gz"
    curl -fsSL "$tarball_url" -o "$TMP_TGZ" 9>&-
    tar -xzf "$TMP_TGZ" -C "$STAGE_TMP"
    rm -f "$TMP_TGZ"
    TMP_TGZ=""
  fi
  if ! runner_binaries_ready "$STAGE_TMP"; then
    echo "ERROR: staged runner binaries incomplete in ${STAGE_TMP}" >&2
    exit 1
  fi
}

promote_staged_binaries() {
  [ -n "${STAGE_TMP:-}" ] && [ -d "${STAGE_TMP:-}" ] || {
    echo "ERROR: staged binaries directory missing" >&2
    exit 1
  }
  mkdir -p "$RUNNER_DIR"
  local item base old
  shopt -s nullglob
  for old in "${RUNNER_DIR:?}"/bin* "${RUNNER_DIR:?}"/externals* "${RUNNER_DIR:?}"/run.sh "${RUNNER_DIR:?}"/runsvc.sh "${RUNNER_DIR:?}"/config.sh "${RUNNER_DIR:?}"/env.sh "${RUNNER_DIR:?}"/run-helper.sh.template "${RUNNER_DIR:?}"/safe_sleep.sh; do
    rm -rf "${old:?}"
  done
  for item in "${STAGE_TMP}"/*; do
    [ -e "$item" ] || [ -L "$item" ] || continue
    base="$(basename "$item")"
    rm -rf "${RUNNER_DIR:?}/${base}"
    mv "$item" "${RUNNER_DIR}/${base}"
  done
  shopt -u nullglob
  rm -rf "${STAGE_TMP:?}"
  STAGE_TMP=""
  if ! runner_binaries_ready "$RUNNER_DIR"; then
    echo "ERROR: promoted runner binaries incomplete or contain escaping symlinks in ${RUNNER_DIR}" >&2
    exit 1
  fi
}

binaries_staged=0
if ! runner_binaries_ready "$RUNNER_DIR"; then
  prepare_staged_binaries
  binaries_staged=1
fi

reg_token=""
if [ "$needs_config" -eq 1 ]; then
  if ! reg_token="$(run_gh_api api -X POST "$TOKEN_API" --jq '.token')" || [ -z "$reg_token" ]; then
    echo "ERROR: failed to mint registration token from $TOKEN_API" >&2
    exit 3
  fi
  resolve_replace_collision_policy "$prev_agent_id"
fi

mkdir -p "$WORK_DIR" "${HOME}/Library/LaunchAgents" "$LOG_DIR"

if [ "$binaries_staged" -eq 1 ] || [ "$needs_config" -eq 1 ]; then
  if ! stop_launchagent; then
    echo "ERROR: failed to stop ${PLIST_LABEL}; aborting before modifying runner installation" >&2
    exit 1
  fi
fi

if [ "$binaries_staged" -eq 1 ]; then
  promote_staged_binaries
else
  mkdir -p "$RUNNER_DIR"
fi

if [ "$needs_config" -eq 1 ]; then
  BACKUP_DIR="${RUNNER_DIR}/.backup-pre-reconfigure.$$"
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  for f in .runner .credentials .credentials_rsaparams .runner_migrated .credentials_migrated .ezgha-labels .ezgha-group; do
    if [ -f "${RUNNER_DIR}/${f}" ]; then
      cp -p "${RUNNER_DIR}/${f}" "${BACKUP_DIR}/${f}"
    fi
  done

  rm -f "${RUNNER_DIR}/.runner" "${RUNNER_DIR}/.credentials" "${RUNNER_DIR}/.credentials_rsaparams" "${RUNNER_DIR}/.runner_migrated" "${RUNNER_DIR}/.credentials_migrated"
  if [ ! -d "$RUNNER_DIR" ] || [ ! -x "${RUNNER_DIR}/config.sh" ]; then
    echo "ERROR: missing executable ${RUNNER_DIR}/config.sh; service ${PLIST_LABEL} remains stopped. Backup preserved at ${BACKUP_DIR}." >&2
    exit 4
  fi
  config_rc=0
  (
    cd "$RUNNER_DIR" || exit 97
    config_args=(
      --unattended
      --url "$RUNNER_URL"
      --name "$RUNNER_NAME"
      --work "$WORK_DIR"
      --labels "$RUNNER_LABELS"
      --no-default-labels
    )
    if [ "$use_replace" -eq 1 ]; then
      config_args+=(--replace)
    fi
    if [ -n "$RUNNER_GROUP" ]; then
      config_args+=(--runnergroup "$RUNNER_GROUP")
    fi
    ACTIONS_RUNNER_INPUT_TOKEN="$reg_token" "${RUNNER_DIR}/config.sh" "${config_args[@]}" 9>&-
  ) || config_rc=$?

  if [ "$config_rc" -ne 0 ]; then
    rm -f "${RUNNER_DIR}/.runner" "${RUNNER_DIR}/.credentials" "${RUNNER_DIR}/.credentials_rsaparams" "${RUNNER_DIR}/.runner_migrated" "${RUNNER_DIR}/.credentials_migrated"
    echo "ERROR: config.sh failed (rc=${config_rc}); service ${PLIST_LABEL} remains stopped and old credentials were not restored. Backup preserved at ${BACKUP_DIR}; re-run --reconfigure after resolving the registration failure." >&2
    exit 4
  fi

  post_agent_id="$(jq -r '.agentId // empty' "${RUNNER_DIR}/.runner" 2>/dev/null || true)"
  if [[ ! "$post_agent_id" =~ ^[0-9]+$ ]] || [ "$post_agent_id" -le 0 ]; then
    echo "ERROR: config.sh completed without a valid positive numeric .runner agentId (got '${post_agent_id}'); service ${PLIST_LABEL} remains stopped. Backup preserved at ${BACKUP_DIR}." >&2
    exit 4
  fi

  chmod 600 "${RUNNER_DIR}/.credentials" "${RUNNER_DIR}/.credentials_rsaparams" 2>/dev/null || true
  if ! verify_live_runner_state post_config; then
    echo "ERROR: newly configured runner '${RUNNER_NAME}' (agentId=${post_agent_id}) failed live GitHub state/group/label verification; service ${PLIST_LABEL} remains stopped. Backup preserved at ${BACKUP_DIR}." >&2
    exit 4
  fi
  printf '%s\n' "$RUNNER_LABELS" > "${RUNNER_DIR}/.ezgha-labels"
  printf '%s\n' "$RUNNER_GROUP" > "${RUNNER_DIR}/.ezgha-group"
fi

if [ ! -f "${RUNNER_DIR}/.env" ]; then
  printf 'LANG=en_US.UTF-8\n' > "${RUNNER_DIR}/.env"
fi

CANDIDATE_PLIST="${PLIST_PATH}.candidate.$$"
render_plist > "$CANDIDATE_PLIST"
plist_matches=0
if [ -f "$PLIST_PATH" ] && cmp -s "$CANDIDATE_PLIST" "$PLIST_PATH"; then
  plist_matches=1
fi
is_loaded=0
if launchctl print "gui/$(id -u)/${PLIST_LABEL}" >/dev/null 2>&1 9>&-; then
  is_loaded=1
fi

service_started_by_setup=0
if [ "$needs_config" -eq 0 ] && [ "$RECONFIGURE" -eq 0 ] && [ "$plist_matches" -eq 1 ]; then
  rm -f "$CANDIDATE_PLIST"
  CANDIDATE_PLIST=""
  if [ "$is_loaded" -eq 1 ]; then
    verify_runner_online 1 || exit 1
    echo "OK: ${RUNNER_NAME} unchanged; leaving loaded (${PLIST_LABEL})"
  else
    if ! launchctl load -w "$PLIST_PATH" 9>&-; then
      echo "ERROR: failed to load ${PLIST_LABEL} from ${PLIST_PATH}" >&2
      exit 1
    fi
    service_started_by_setup=1
    if ! launchctl print "gui/$(id -u)/${PLIST_LABEL}" >/dev/null 9>&-; then
      echo "ERROR: launchd did not register ${PLIST_LABEL}" >&2
      stop_launchagent || true
      exit 1
    fi
    if ! verify_runner_online "$POST_CONFIG_VERIFY_ATTEMPTS"; then
      if [ "$needs_config" -eq 1 ] || [ "$service_started_by_setup" -eq 1 ]; then
        stop_launchagent || true
      fi
      exit 1
    fi
    echo "OK: ${RUNNER_NAME} loaded (${PLIST_LABEL})"
  fi
else
  if ! stop_launchagent; then
    echo "ERROR: failed to stop ${PLIST_LABEL} before updating ${PLIST_PATH}" >&2
    exit 1
  fi
  mv "$CANDIDATE_PLIST" "$PLIST_PATH"
  CANDIDATE_PLIST=""
  if ! launchctl load -w "$PLIST_PATH" 9>&-; then
    echo "ERROR: failed to load ${PLIST_LABEL} from ${PLIST_PATH}${BACKUP_DIR:+ (backup preserved at ${BACKUP_DIR})}" >&2
    if [ "$needs_config" -eq 1 ]; then
      exit 4
    fi
    exit 1
  fi
  service_started_by_setup=1
  if ! launchctl print "gui/$(id -u)/${PLIST_LABEL}" >/dev/null 9>&-; then
    echo "ERROR: launchd did not register ${PLIST_LABEL}${BACKUP_DIR:+ (backup preserved at ${BACKUP_DIR})}" >&2
    stop_launchagent || true
    if [ "$needs_config" -eq 1 ]; then
      exit 4
    fi
    exit 1
  fi
  if ! verify_runner_online "$POST_CONFIG_VERIFY_ATTEMPTS"; then
    if [ "$needs_config" -eq 1 ] || [ "$service_started_by_setup" -eq 1 ]; then
      stop_launchagent || true
    fi
    if [ "$needs_config" -eq 1 ]; then
      exit 4
    fi
    exit 1
  fi
  echo "OK: ${RUNNER_NAME} installed and loaded (${PLIST_LABEL})"
fi

if [ -n "${BACKUP_DIR:-}" ]; then
  rm -rf "${BACKUP_DIR:?}"
  BACKUP_DIR=""
fi
if [ -d "${RUNNER_DIR:-}" ]; then
  shopt -s nullglob
  for b in "${RUNNER_DIR:?}"/.backup-pre-reconfigure.*; do
    rm -rf "${b:?}"
  done
  shopt -u nullglob
fi
