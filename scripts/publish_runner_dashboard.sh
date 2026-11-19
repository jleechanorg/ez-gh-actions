#!/usr/bin/env bash
# Collect an aggregate-only runner snapshot and optionally publish GitHub Pages.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Static assets live in the repository's dashboard/ directory (repo root), NOT next to
# this script. Resolve via the repo root so the default works when invoked from the
# installed layout (~/.local/libexec/ezgha/) as well as from a checkout. Every test set
# EZGHA_DASHBOARD_ASSET_DIR explicitly, which is why this broken default shipped in
# PR #81 and was never exercised -- the first real --collect-only run failed with
# "scripts/dashboard/index.html: No such file or directory".
# The assets live in two different relative places depending on layout:
#   checkout:   <repo>/scripts/publish_runner_dashboard.sh + <repo>/dashboard/
#   installed:  ~/.local/libexec/ezgha/publish_runner_dashboard.sh
#               + ~/.local/libexec/ezgha/dashboard/  (installer copies assets alongside)
# Try the sibling directory first (installed layout, and also a checkout if someone
# builds assets there), then the repo root. Whichever actually contains index.html wins;
# surface a clear error rather than installing from a missing path.
if [[ -z "${EZGHA_DASHBOARD_ASSET_DIR:-}" ]]; then
  for candidate in "$SCRIPT_DIR/dashboard" "$SCRIPT_DIR/../dashboard"; do
    if [[ -f "$candidate/index.html" ]]; then
      EZGHA_DASHBOARD_ASSET_DIR="$(cd "$candidate" && pwd)"
      break
    fi
  done
fi
DASHBOARD_DIR="${EZGHA_DASHBOARD_ASSET_DIR:-$SCRIPT_DIR/dashboard}"
SNAPSHOT_BUILDER="$SCRIPT_DIR/build_runner_dashboard_snapshot.py"
HOST_PROBE="$SCRIPT_DIR/runner_dashboard_host_probe.sh"
PROBE_DIR="${EZGHA_DASHBOARD_PROBE_DIR:-}"
REMOTE_LINUX_HOST="${EZGHA_DASHBOARD_LINUX_HOST:-jeff-ubuntu}"
# shellcheck disable=SC2016  # Expand HOME on the remote host, not the publisher.
REMOTE_SCRIPTS_DIR='$HOME/.local/libexec/ezgha'
DEFAULT_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/ezgha"
LOCK_DIR_IS_DEFAULT=false
if [[ -n "${EZGHA_DASHBOARD_LOCK_DIR:-}" ]]; then
  LOCK_DIR="$EZGHA_DASHBOARD_LOCK_DIR"
else
  LOCK_DIR="$DEFAULT_STATE_DIR/runner-dashboard.lock"
  LOCK_DIR_IS_DEFAULT=true
fi
PUBLISH_BRANCH="${EZGHA_DASHBOARD_PUBLISH_BRANCH:-gh-pages}"
PUBLISH_REMOTE="${EZGHA_DASHBOARD_PUBLISH_REMOTE:-https://github.com/jleechanorg/ez-gh-actions.git}"
OWNERSHIP_MARKER=".ezgha-runner-dashboard-owned"
OWNERSHIP_CONTENT="ezgha-runner-dashboard:v1"
PROBE_TIMEOUT_SECONDS="${EZGHA_DASHBOARD_PROBE_TIMEOUT_SECONDS:-45}"
GIT_TIMEOUT_SECONDS="${EZGHA_DASHBOARD_GIT_TIMEOUT_SECONDS:-120}"
PUBLISH_PATHS=(
  .nojekyll
  "$OWNERSHIP_MARKER"
  dashboard.js
  index.html
  status.json
  style.css
)
WORK_DIR=""
PUBLISH_DIR=""
SITE_STAGE_DIR=""
SITE_BACKUP_DIR=""
SITE_OUTPUT_DIR=""

usage() {
  echo "usage: $0 --collect-only OUTPUT_DIR | --publish" >&2
}

process_identity() {
  LC_ALL=C ps -p "$1" -o lstart= -o command= 2>/dev/null | sed 's/^[[:space:]]*//'
}

cleanup() {
  local owner_pid="" owner_identity="" live_identity=""
  if [[ -n "$SITE_BACKUP_DIR" && -e "$SITE_BACKUP_DIR" ]]; then
    if [[ -n "$SITE_OUTPUT_DIR" && ! -e "$SITE_OUTPUT_DIR" ]]; then
      mv "$SITE_BACKUP_DIR" "$SITE_OUTPUT_DIR"
    else
      rm -rf "$SITE_BACKUP_DIR"
    fi
  fi
  [[ -z "$SITE_STAGE_DIR" ]] || rm -rf "$SITE_STAGE_DIR"
  [[ -z "$WORK_DIR" ]] || rm -rf "$WORK_DIR"
  [[ -z "$PUBLISH_DIR" ]] || rm -rf "$PUBLISH_DIR"
  [[ ! -f "$LOCK_DIR/owner.pid" ]] || owner_pid="$(cat "$LOCK_DIR/owner.pid" 2>/dev/null || true)"
  [[ ! -f "$LOCK_DIR/owner.identity" ]] || owner_identity="$(cat "$LOCK_DIR/owner.identity" 2>/dev/null || true)"
  live_identity="$(process_identity "$$" || true)"
  if [[ "$owner_pid" == "$$" && -n "$owner_identity" && "$owner_identity" == "$live_identity" ]]; then
    rm -rf "$LOCK_DIR"
  fi
}

acquire_lock() {
  local owner_pid owner_identity live_identity stale_lock
  mkdir -p "$(dirname "$LOCK_DIR")"
  if [[ "$LOCK_DIR_IS_DEFAULT" == true ]]; then
    chmod 0700 "$DEFAULT_STATE_DIR"
  fi
  for _ in 1 2; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      printf '%s\n' "$$" > "$LOCK_DIR/owner.pid"
      process_identity "$$" > "$LOCK_DIR/owner.identity"
      [[ -s "$LOCK_DIR/owner.identity" ]] || {
        rm -rf "$LOCK_DIR"
        echo "could not record publisher lock identity" >&2
        exit 75
      }
      trap cleanup EXIT
      trap 'exit 129' HUP
      trap 'exit 130' INT
      trap 'exit 143' TERM
      return
    fi
    owner_pid="$(cat "$LOCK_DIR/owner.pid" 2>/dev/null || true)"
    owner_identity="$(cat "$LOCK_DIR/owner.identity" 2>/dev/null || true)"
    live_identity=""
    if [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
      live_identity="$(process_identity "$owner_pid" || true)"
    fi
    if [[ -n "$owner_identity" && "$owner_identity" == "$live_identity" ]]; then
      echo "runner dashboard publisher is already active (pid $owner_pid)" >&2
      exit 75
    fi
    stale_lock="$LOCK_DIR.stale.$$"
    if mv "$LOCK_DIR" "$stale_lock" 2>/dev/null; then
      rm -rf "$stale_lock"
    fi
  done
  echo "could not acquire publisher lock" >&2
  exit 75
}

run_probe() {
  local output="$1"
  shift
  python3 - "$PROBE_TIMEOUT_SECONDS" "$output" "$@" <<'PY'
import os
import signal
import subprocess
import sys

timeout = int(sys.argv[1])
output = sys.argv[2]
command = sys.argv[3:]
try:
    with open(output, "wb") as handle:
        process = subprocess.Popen(
            command,
            stdout=handle,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        try:
            returncode = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            raise
        if returncode != 0:
            raise subprocess.CalledProcessError(returncode, command)
except (OSError, subprocess.SubprocessError):
    with open(output, "w", encoding="utf-8") as handle:
        handle.write("{}\n")
PY
}

run_bounded() {
  local seconds="$1"
  shift
  python3 - "$seconds" "$@" <<'PY'
import os
import signal
import subprocess
import sys

try:
    process = subprocess.Popen(
        sys.argv[2:],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    try:
        returncode = process.wait(timeout=int(sys.argv[1]))
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        raise
    if returncode != 0:
        raise subprocess.CalledProcessError(returncode, sys.argv[2:])
except (OSError, subprocess.SubprocessError):
    raise SystemExit(1)
PY
}

build_site() {
  local output_dir="$1" observed_at published_at
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ezgha-dashboard-collect.XXXXXX")"
  observed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [[ -n "$PROBE_DIR" ]]; then
    run_probe "$WORK_DIR/mac.json" "$PROBE_DIR/mac.sh"
    run_probe "$WORK_DIR/linux.json" "$PROBE_DIR/linux.sh"
  else
    if [[ "$(uname -s)" != "Darwin" ]]; then
      printf '{}\n' > "$WORK_DIR/mac.json"
    else
      run_probe "$WORK_DIR/mac.json" "$HOST_PROBE" --host-class mac
    fi
    run_probe "$WORK_DIR/linux.json" \
      ssh -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE_LINUX_HOST" \
      "$REMOTE_SCRIPTS_DIR/runner_dashboard_host_probe.sh" --host-class linux
  fi

  mkdir -p "$output_dir"
  install -m 0644 "$DASHBOARD_DIR/index.html" "$output_dir/index.html"
  install -m 0644 "$DASHBOARD_DIR/style.css" "$output_dir/style.css"
  install -m 0644 "$DASHBOARD_DIR/dashboard.js" "$output_dir/dashboard.js"
  : > "$output_dir/.nojekyll"
  published_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # Queue probe is best-effort and additive. It splits queued runs into real waiting
  # work vs zero-job ghosts GitHub refuses to transition. If it fails, the snapshot is
  # still published with the queue marked unavailable -- a queue outage must never
  # blank out the capacity view, and unknown is never rendered as zero.
  # Opt-out via EZGHA_DASHBOARD_QUEUE_PROBE=0 (default on). The probe needs gh auth;
  # where it is absent (tests, an unauthenticated host) the capacity view must still
  # publish, so failure here is never fatal.
  if [[ "${EZGHA_DASHBOARD_QUEUE_PROBE:-1}" != "0" ]]; then
    # EZGHA_DASHBOARD_QUEUE_PROBE_CMD overrides the probe executable so tests can
    # inject a fixture. Stubbing `gh` on PATH is not sufficient here: this host
    # ships a gh wrapper at ~/.local/bin/gh that re-execs the real binary.
    # Array, not a word-split string: an override may contain spaces (a fixture path
    # under a temp dir, for instance) and must not be split on them.
    if [[ -n "${EZGHA_DASHBOARD_QUEUE_PROBE_CMD:-}" ]]; then
      read -r -a QUEUE_PROBE_CMD <<< "$EZGHA_DASHBOARD_QUEUE_PROBE_CMD"
    else
      QUEUE_PROBE_CMD=(python3 "$SCRIPT_DIR/queue_probe.py")
    fi
    QUEUE_MAX_REQUESTS="${EZGHA_DASHBOARD_QUEUE_MAX_REQUESTS:-80}"
    if [[ "$QUEUE_MAX_REQUESTS" =~ ^0*([0-9]+)$ ]]; then
      QUEUE_MAX_REQUESTS="${BASH_REMATCH[1]}"
      if (( ${#QUEUE_MAX_REQUESTS} > 9 )) || (( 10#$QUEUE_MAX_REQUESTS > 80 )); then
        QUEUE_MAX_REQUESTS=80
      elif (( 10#$QUEUE_MAX_REQUESTS < 1 )); then
        QUEUE_MAX_REQUESTS=1
      else
        QUEUE_MAX_REQUESTS=$(( 10#$QUEUE_MAX_REQUESTS ))
      fi
    else
      QUEUE_MAX_REQUESTS=80
    fi
    queue_rc=0
    timeout "${EZGHA_DASHBOARD_QUEUE_TIMEOUT:-240}" \
        "${QUEUE_PROBE_CMD[@]}" \
        --repo jleechanorg/worldarchitect.ai \
        --repo jleechanorg/worldai_frontend \
        --max-requests "$QUEUE_MAX_REQUESTS" \
        --output "$WORK_DIR/queue.json" || queue_rc=$?
    if [[ -s "$WORK_DIR/queue.json" ]] && python3 - "$WORK_DIR/queue.json" >/dev/null 2>&1 <<'PY'
import json, math, sys
from pathlib import Path
def _reject(token):
    raise ValueError(token)
def _finite_float(s):
    v = float(s)
    if not math.isfinite(v):
        raise ValueError(s)
    return v
try:
    doc = json.loads(
        Path(sys.argv[1]).read_text(encoding="utf-8"),
        parse_constant=_reject,
        parse_float=_finite_float,
    )
except (OSError, UnicodeDecodeError, ValueError):
    sys.exit(1)
if not isinstance(doc, dict) or type(doc.get("schema_version")) is not int or doc["schema_version"] != 1:
    sys.exit(1)
raw = doc.get("queue") if isinstance(doc.get("queue"), dict) else doc
repos = raw.get("repos")
if not isinstance(repos, list) or not all(isinstance(item, dict) for item in repos):
    sys.exit(1)
PY
    then
      if (( queue_rc != 0 )); then
        python3 - "$WORK_DIR/queue.json" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
doc = json.loads(p.read_text(encoding="utf-8"))
doc["ok"] = False
doc["partial"] = True
if isinstance(doc.get("queue"), dict):
    doc["queue"]["ok"] = False
    doc["queue"]["partial"] = True
p.write_text(json.dumps(doc), encoding="utf-8")
PY
        echo "queue probe exited non-zero with partial payload; preserving diagnostics" >&2
      fi
    elif [[ -e "$WORK_DIR/queue.json" ]] || (( queue_rc != 0 )); then
      # Keep the uncertainty: the builder maps repos:null to queue.ok=false, partial=true.
      printf '{"schema_version":1,"ok":false,"partial":true,"repos":null}\n' > "$WORK_DIR/queue.json"
      echo "queue probe invalid or failed; publishing capacity with queue unavailable (partial)" >&2
    fi
  fi
  queue_args=()
  [[ -s "$WORK_DIR/queue.json" ]] && queue_args=(--queue "$WORK_DIR/queue.json")
  if [[ "${EZGHA_DASHBOARD_LATENCY_PROBE:-1}" != "0" ]]; then
    if [[ -n "${EZGHA_DASHBOARD_LATENCY_PROBE_CMD:-}" ]]; then
      read -r -a LATENCY_PROBE_CMD <<< "$EZGHA_DASHBOARD_LATENCY_PROBE_CMD"
    else
      LATENCY_PROBE_CMD=(python3 "$SCRIPT_DIR/ci_latency_probe.py")
    fi
    if ! timeout "${EZGHA_DASHBOARD_LATENCY_TIMEOUT:-120}" \
        "${LATENCY_PROBE_CMD[@]}" \
        --repo jleechanorg/worldarchitect.ai \
        --repo jleechanorg/worldai_frontend \
        --limit 30 \
        --job-run-limit 20 \
        --output "$WORK_DIR/latency.json"; then
      rm -f "$WORK_DIR/latency.json"
      echo "latency probe failed; publishing capacity with latency unavailable" >&2
    fi
  fi
  latency_args=()
  [[ -s "$WORK_DIR/latency.json" ]] && latency_args=(--latency "$WORK_DIR/latency.json")
  cmux_args=()
  if [[ -n "${EZGHA_DASHBOARD_CMUX_PROBE_CMD:-}" ]]; then
    read -r -a CMUX_PROBE_CMD <<< "$EZGHA_DASHBOARD_CMUX_PROBE_CMD"
    if ! timeout "${EZGHA_DASHBOARD_CMUX_TIMEOUT:-60}" \
        "${CMUX_PROBE_CMD[@]}" > "$WORK_DIR/cmux.json"; then
      rm -f "$WORK_DIR/cmux.json"
      echo "cmux probe failed; publishing capacity without cmux pool" >&2
    fi
    [[ -s "$WORK_DIR/cmux.json" ]] && cmux_args=(--cmux "$WORK_DIR/cmux.json")
  fi
  python3 "$SNAPSHOT_BUILDER" \
    --mac-host "$WORK_DIR/mac.json" \
    --linux-host "$WORK_DIR/linux.json" \
    ${queue_args[@]+"${queue_args[@]}"} \
    ${latency_args[@]+"${latency_args[@]}"} \
    ${cmux_args[@]+"${cmux_args[@]}"} \
    --observed-at "$observed_at" \
    --published-at "$published_at" \
    --output "$output_dir/status.json"
  rm -rf "$WORK_DIR"
  WORK_DIR=""
}

collect_site() {
  local output_dir="$1" output_parent output_name
  [[ ! -L "$output_dir" ]] || {
    echo "refusing symlink collect-only output" >&2
    exit 1
  }
  output_parent="$(dirname "$output_dir")"
  output_name="$(basename "$output_dir")"
  mkdir -p "$output_parent"
  SITE_OUTPUT_DIR="$output_dir"
  SITE_STAGE_DIR="$(mktemp -d "$output_parent/.${output_name}.tmp.XXXXXX")"
  build_site "$SITE_STAGE_DIR"

  if [[ -e "$output_dir" ]]; then
    [[ -d "$output_dir" ]] || {
      echo "refusing non-directory collect-only output" >&2
      exit 1
    }
    SITE_BACKUP_DIR="$output_parent/.${output_name}.backup.$$"
    mv "$output_dir" "$SITE_BACKUP_DIR"
  fi
  if ! mv "$SITE_STAGE_DIR" "$output_dir"; then
    echo "could not replace collect-only output" >&2
    exit 1
  fi
  SITE_STAGE_DIR=""
  [[ -z "$SITE_BACKUP_DIR" ]] || rm -rf "$SITE_BACKUP_DIR"
  SITE_BACKUP_DIR=""
  SITE_OUTPUT_DIR=""
}

validate_remote() {
  case "$PUBLISH_REMOTE" in
    https://github.com/*|git@github.com:*) return ;;
    *)
      if [[ "${EZGHA_DASHBOARD_ALLOW_LOCAL_REMOTE:-0}" == "1" ]]; then
        return
      fi
      echo "refusing non-GitHub publish remote" >&2
      exit 1
      ;;
  esac
}

publish_site() {
  local actual_paths expected_paths
  validate_remote
  PUBLISH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ezgha-dashboard-publish.XXXXXX")"
  if ! run_bounded "$GIT_TIMEOUT_SECONDS" git clone --quiet "$PUBLISH_REMOTE" "$PUBLISH_DIR"; then
    echo "could not create isolated publish checkout" >&2
    exit 1
  fi

  if git -C "$PUBLISH_DIR" show-ref --verify --quiet "refs/remotes/origin/$PUBLISH_BRANCH"; then
    git -C "$PUBLISH_DIR" switch --quiet --track -c "$PUBLISH_BRANCH" "origin/$PUBLISH_BRANCH"
    [[ -z "$(git -C "$PUBLISH_DIR" status --porcelain)" ]] || {
      echo "refusing dirty isolated publish checkout" >&2
      exit 1
    }
    if [[ ! -f "$PUBLISH_DIR/$OWNERSHIP_MARKER" || -L "$PUBLISH_DIR/$OWNERSHIP_MARKER" ]] ||
      [[ "$(cat "$PUBLISH_DIR/$OWNERSHIP_MARKER")" != "$OWNERSHIP_CONTENT" ]]; then
      echo "refusing existing branch without dashboard ownership marker" >&2
      exit 1
    fi
    git -C "$PUBLISH_DIR" rm -rf --quiet -- .
  else
    git -C "$PUBLISH_DIR" switch --quiet --orphan "$PUBLISH_BRANCH"
    git -C "$PUBLISH_DIR" rm -rf --quiet . >/dev/null 2>&1 || true
    [[ -z "$(git -C "$PUBLISH_DIR" status --porcelain)" ]] || {
      echo "refusing dirty isolated publish checkout" >&2
      exit 1
    }
  fi

  build_site "$PUBLISH_DIR"
  printf '%s\n' "$OWNERSHIP_CONTENT" > "$PUBLISH_DIR/$OWNERSHIP_MARKER"
  git -C "$PUBLISH_DIR" add -- "${PUBLISH_PATHS[@]}"
  actual_paths="$(git -C "$PUBLISH_DIR" ls-files | LC_ALL=C sort)"
  expected_paths="$(printf '%s\n' "${PUBLISH_PATHS[@]}" | LC_ALL=C sort)"
  [[ "$actual_paths" == "$expected_paths" ]] || {
    echo "refusing publish branch outside dashboard allowlist" >&2
    exit 1
  }
  if git -C "$PUBLISH_DIR" diff --cached --quiet; then
    return
  fi
  git -C "$PUBLISH_DIR" commit --quiet -m "chore(runner-dashboard): publish status"
  if ! run_bounded "$GIT_TIMEOUT_SECONDS" git -C "$PUBLISH_DIR" push --quiet origin "HEAD:$PUBLISH_BRANCH"; then
    echo "dashboard push was rejected, failed, or timed out" >&2
    exit 1
  fi
}

[[ $# -ge 1 ]] || { usage; exit 64; }
acquire_lock
case "$1" in
  --collect-only)
    [[ $# -eq 2 ]] || { usage; exit 64; }
    collect_site "$2"
    ;;
  --publish)
    [[ $# -eq 1 ]] || { usage; exit 64; }
    publish_site
    ;;
  *)
    usage
    exit 64
    ;;
esac
