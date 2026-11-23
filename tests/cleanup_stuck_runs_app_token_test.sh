#!/usr/bin/env bash
# Regression test (bd-1sl6): cleanup-stuck-runs.sh must load the ezgha GitHub
# App token from ~/.config/ezgha/gh_token when GH_TOKEN is unset, and preserve
# any pre-existing GH_TOKEN.
#
# Usage: bash tests/cleanup_stuck_runs_app_token_test.sh
set -euo pipefail
unset BASH_ENV

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fake_home="$tmpdir/home"
mkdir -p "$fake_home/.config/ezgha"
printf 'app-tok-12345\n' >"$fake_home/.config/ezgha/gh_token"

cat >"$tmpdir/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
unset BASH_ENV
printf '%s\n' "${GH_TOKEN:-UNSET}" >>"$GH_TOKEN_LOG"
if [[ "$1" == "api" && "$*" == *"status=queued"* ]]; then
  printf '{"workflow_runs":[]}\n'
  exit 0
fi
echo "unexpected gh invocation: $*" >&2
exit 1
SH
chmod +x "$tmpdir/gh"

export PATH="$tmpdir:$PATH"
export HOME="$fake_home"
export QUEUE_REPOS="acme/repoA"

# Case 1: GH_TOKEN unset -> loads ~/.config/ezgha/gh_token
export GH_TOKEN_LOG="$tmpdir/case1.log"
env -u GH_TOKEN ./scripts/cleanup-stuck-runs.sh --superseded >/dev/null
[[ "$(cat "$GH_TOKEN_LOG")" == "app-tok-12345" ]]

# Case 2: GH_TOKEN already set -> preserves existing GH_TOKEN
export GH_TOKEN_LOG="$tmpdir/case2.log"
GH_TOKEN="existing-pat-999" ./scripts/cleanup-stuck-runs.sh --superseded >/dev/null
[[ "$(cat "$GH_TOKEN_LOG")" == "existing-pat-999" ]]

# Case 3: empty token file when GH_TOKEN unset -> leaves GH_TOKEN unset
: >"$fake_home/.config/ezgha/gh_token"
export GH_TOKEN_LOG="$tmpdir/case3.log"
env -u GH_TOKEN ./scripts/cleanup-stuck-runs.sh --superseded >/dev/null
[[ "$(cat "$GH_TOKEN_LOG")" == "UNSET" ]]

# Case 4: unreadable token file (chmod 000) when GH_TOKEN unset -> does not crash, leaves GH_TOKEN unset
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  printf 'secret-unreadable\n' >"$fake_home/.config/ezgha/gh_token"
  chmod 000 "$fake_home/.config/ezgha/gh_token"
  export GH_TOKEN_LOG="$tmpdir/case4.log"
  env -u GH_TOKEN ./scripts/cleanup-stuck-runs.sh --superseded >/dev/null
  chmod 600 "$fake_home/.config/ezgha/gh_token"
  [[ "$(cat "$GH_TOKEN_LOG")" == "UNSET" ]]
fi

# Case 5: unset HOME when GH_TOKEN unset -> does not fail under set -u
export GH_TOKEN_LOG="$tmpdir/case5.log"
env -u GH_TOKEN -u HOME ./scripts/cleanup-stuck-runs.sh --superseded >/dev/null
[[ "$(cat "$GH_TOKEN_LOG")" == "UNSET" ]]

echo "cleanup-stuck-runs app token loader test passed"
