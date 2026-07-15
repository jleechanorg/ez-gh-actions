#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBLISHER="$ROOT/scripts/publish_runner_dashboard.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PROBES="$WORK/probes"
mkdir -p "$PROBES"

write_probe() {
  local path="$1" host_class="$2" configured="$3" executing="$4"
  sed -n '1,$p' > "$path" <<EOF
#!/usr/bin/env bash
echo '{"schema_version":1,"host_class":"$host_class","sources":{"config":{"ok":true},"service":{"ok":true},"docker":{"ok":true},"process_probe":{"ok":true},"disk":{"ok":true},"watchdog_state":{"ok":true}},"fleet":{"configured":$configured,"executing":$executing,"idle":1,"cycling":0,"down":0,"reserved":$configured},"disk":{"status":"healthy"},"watchdog":{"consecutive_misses":0,"restart_after":3},"raw":"must-not-publish","host":"secret-host"}'
EOF
  chmod +x "$path"
}
write_probe "$PROBES/mac.sh" mac 6 5
write_probe "$PROBES/linux.sh" linux 16 15

SITE="$WORK/site"
EZGHA_DASHBOARD_PROBE_DIR="$PROBES" \
EZGHA_DASHBOARD_ASSET_DIR="$ROOT/dashboard" \
EZGHA_DASHBOARD_LOCK_DIR="$WORK/collect.lock" \
bash "$PUBLISHER" --collect-only "$SITE"
for file in .nojekyll index.html style.css dashboard.js status.json; do
  test -f "$SITE/$file"
done
SITE="$SITE" python3 - <<'PY'
import json
import os
from pathlib import Path

payload = json.loads((Path(os.environ["SITE"]) / "status.json").read_text())
assert payload["sources"] == {
    "mac_host": {"ok": True},
    "linux_host": {"ok": True},
}
serialized = json.dumps(payload)
assert "must-not-publish" not in serialized
assert "secret-host" not in serialized
PY

DEFAULT_HOME="$WORK/default-home"
mkdir -p "$DEFAULT_HOME"
HOME="$DEFAULT_HOME" \
EZGHA_DASHBOARD_PROBE_DIR="$PROBES" \
EZGHA_DASHBOARD_ASSET_DIR="$ROOT/dashboard" \
bash "$PUBLISHER" --collect-only "$WORK/default-lock-site"
DEFAULT_STATE_DIR="$DEFAULT_HOME/.local/state/ezgha"
test -d "$DEFAULT_STATE_DIR"
MODE="$(stat -f %Lp "$DEFAULT_STATE_DIR" 2>/dev/null || stat -c %a "$DEFAULT_STATE_DIR")"
test "$MODE" = "700"

printf 'keep until replacement succeeds\n' > "$SITE/sentinel.txt"
set +e
OUTPUT="$({
  EZGHA_DASHBOARD_PROBE_DIR="$PROBES" \
  EZGHA_DASHBOARD_ASSET_DIR="$WORK/missing-assets" \
  EZGHA_DASHBOARD_LOCK_DIR="$WORK/failing-collect.lock" \
  bash "$PUBLISHER" --collect-only "$SITE"
} 2>&1)"
STATUS=$?
set -e
test "$STATUS" -ne 0
test "$(cat "$SITE/sentinel.txt")" = "keep until replacement succeeds"

EZGHA_DASHBOARD_PROBE_DIR="$PROBES" \
EZGHA_DASHBOARD_ASSET_DIR="$ROOT/dashboard" \
EZGHA_DASHBOARD_LOCK_DIR="$WORK/recollect.lock" \
bash "$PUBLISHER" --collect-only "$SITE"
test ! -e "$SITE/sentinel.txt"

REMOTE="$WORK/dashboard.git"
git init -q --bare "$REMOTE"
GIT_CONFIG_GLOBAL="$WORK/gitconfig"
git config -f "$GIT_CONFIG_GLOBAL" user.name "Runner Dashboard Test"
git config -f "$GIT_CONFIG_GLOBAL" user.email "jleechan2015@users.noreply.github.com"

publish() {
  GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" \
  GIT_CONFIG_NOSYSTEM=1 \
  EZGHA_DASHBOARD_ALLOW_LOCAL_REMOTE=1 \
  EZGHA_DASHBOARD_PUBLISH_REMOTE="$REMOTE" \
  EZGHA_DASHBOARD_PROBE_DIR="$PROBES" \
  EZGHA_DASHBOARD_ASSET_DIR="$ROOT/dashboard" \
  EZGHA_DASHBOARD_LOCK_DIR="$WORK/publish.lock" \
  bash "$PUBLISHER" --publish
}
publish

EXPECTED="$(printf '%s\n' \
  .ezgha-runner-dashboard-owned \
  .nojekyll \
  dashboard.js \
  index.html \
  status.json \
  style.css | LC_ALL=C sort)"
ACTUAL="$(git --git-dir="$REMOTE" ls-tree -r --name-only gh-pages | LC_ALL=C sort)"
test "$ACTUAL" = "$EXPECTED"
test "$(git --git-dir="$REMOTE" show gh-pages:.ezgha-runner-dashboard-owned)" = \
  "ezgha-runner-dashboard:v1"
publish
test "$(git --git-dir="$REMOTE" ls-tree -r --name-only gh-pages | LC_ALL=C sort)" = \
  "$EXPECTED"

SEED="$WORK/seed"
git init -q "$SEED"
git -C "$SEED" config user.name "Runner Dashboard Test"
git -C "$SEED" config user.email "jleechan2015@users.noreply.github.com"
printf 'existing public content\n' > "$SEED/existing.html"
git -C "$SEED" add existing.html
git -C "$SEED" commit -qm "seed unowned branch"
git -C "$SEED" remote add origin "$REMOTE"
git -C "$SEED" push -q origin HEAD:legacy-pages
set +e
OUTPUT="$({
  EZGHA_DASHBOARD_PUBLISH_BRANCH=legacy-pages publish
} 2>&1)"
STATUS=$?
set -e
test "$STATUS" -ne 0
[[ "$OUTPUT" == *"ownership marker"* ]]
test "$(git --git-dir="$REMOTE" show legacy-pages:existing.html)" = "existing public content"

echo "runner dashboard publisher tests passed"
