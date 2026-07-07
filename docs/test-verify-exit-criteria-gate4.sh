#!/usr/bin/env bash
# Regression test for Gate 4: a transient/rate-limited jobs lookup for one
# selftest run must not abort the whole verifier when a later run proves
# prefix-aligned execution.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/home/.cargo/bin" "$TMP/home/.config/ezgha" "$TMP/bin"

cat >"$TMP/home/.cargo/bin/ezgha" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "--config" ] && [ "\${3:-}" = "test-alert" ]; then
  echo "test alert delivered for event_key=\${5:-test}"
  exit 0
fi
echo "ezgha 0.1.0-$(git -C "$ROOT" rev-parse --short HEAD)"
EOF
chmod +x "$TMP/home/.cargo/bin/ezgha"

cat >"$TMP/home/.config/ezgha/config.toml" <<'EOF'
version = 1

[github]
scope = "org"
target = "jleechanorg"

[runner]
count = 2
name_prefix = "ez-runner-test"
image = "ezgha-runner:latest"
labels = ["self-hosted", "ezgha"]

[limits]
cpus = 1.0
memory_mb = 2048
pids = 512
min_free_disk_gb = 10

[policy]
minimum_isolation = "container"
EOF

cat >"$TMP/bin/cargo" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"is-active ezgha.service"*) echo active ;;
  *"is-enabled ezgha.service"*) echo enabled ;;
  *"list-timers --all"*) echo "now later x x ezgha-watchdog.timer ezgha-watchdog.service" ;;
  *"is-enabled ezgha-watchdog.timer"*) echo enabled ;;
  *"is-active ezgha-watchdog.timer"*) echo active ;;
  *"is-active ezgha-watchdog.service"*) echo inactive ;;
  *) echo active ;;
esac
EOF

cat >"$TMP/bin/limactl" <<'EOF'
#!/usr/bin/env bash
printf 'NAME STATUS\ncolima Running\n'
EOF

cat >"$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "info" ]; then
  echo "29.5.3"
  exit 0
fi
if [ "$1" = "ps" ]; then
  printf 'ez-runner-test-1\nez-runner-test-2\n'
  exit 0
fi
exit 0
EOF

cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "run" ] && [ "$2" = "list" ]; then
  cat <<'JSON'
[
  {"databaseId":111,"status":"completed","conclusion":"success"},
  {"databaseId":222,"status":"completed","conclusion":"success"},
  {"databaseId":333,"status":"completed","conclusion":"success"},
  {"databaseId":444,"status":"completed","conclusion":"success"},
  {"databaseId":555,"status":"completed","conclusion":"success"},
  {"databaseId":666,"status":"completed","conclusion":"success"}
]
JSON
  exit 0
fi

if [ "$1" = "api" ] && [[ "$2" == *"/actions/runs/111/jobs" ]]; then
  echo "HTTP 403: You have exceeded a secondary rate limit" >&2
  exit 1
fi

if [ "$1" = "api" ] && [[ "$2" =~ /actions/runs/(222|333|444|555|666)/jobs ]]; then
  rid="${BASH_REMATCH[1]}"
  printf '{"jobs":[{"runner_name":"ez-runner-test-%d"}]}\n' "$((rid / 111))"
  exit 0
fi

if [ "$1" = "api" ] && [ "$2" = "orgs/jleechanorg/actions/runners" ]; then
  cat <<'JSON'
{"runners":[
  {"id":1,"name":"ez-runner-test-1","status":"online","busy":true},
  {"id":2,"name":"ez-runner-test-2","status":"online","busy":true},
  {"id":3,"name":"ez-org-runner-1","status":"online","busy":true},
  {"id":4,"name":"ez-org-runner-2","status":"online","busy":true}
]}
JSON
  exit 0
fi

if [ "$1" = "api" ] && [ "$2" = "rate_limit" ]; then
  if [ "${3:-}" = "--jq" ] && [[ "${4:-}" == *".remaining" ]]; then echo 4000; exit 0; fi
  if [ "${3:-}" = "--jq" ] && [[ "${4:-}" == *".limit" ]]; then echo 5000; exit 0; fi
  echo '{"resources":{"core":{"remaining":4000,"limit":5000}}}'
  exit 0
fi

echo "unexpected gh invocation: $*" >&2
exit 1
EOF

chmod +x "$TMP/bin/"*

PATH="$TMP/bin:$PATH" HOME="$TMP/home" "$ROOT/docs/verify-exit-criteria.sh" >/tmp/ezgha-gate4-test.out
rg -q "Prefix-aligned selftest run: 222 on ez-runner-test-2" /tmp/ezgha-gate4-test.out
rg -q "Prefix-aligned selftest run: 666 on ez-runner-test-6" /tmp/ezgha-gate4-test.out
