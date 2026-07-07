#!/usr/bin/env bash
# Regression test for Gate 4: the verifier must use a fresh nonce-tracked
# canary proof from `ezgha canary-once`, not stale historical selftest runs.
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
if [ "\${1:-}" = "--config" ] && [ "\${3:-}" = "canary-once" ]; then
  cat <<'JSON'
{
  "nonce": "ezgha-canary-test",
  "repo": "jleechanorg/ez-gh-actions",
  "workflow": "selftest.yml",
  "run_id": 777,
  "job_id": 888,
  "runner_name": "ez-runner-test-2",
  "status": "completed",
  "conclusion": "success",
  "queued_at": "2026-07-07T08:00:00Z",
  "started_at": "2026-07-07T08:00:10Z",
  "completed_at": "2026-07-07T08:00:20Z",
  "time_to_start_seconds": 10,
  "time_to_complete_seconds": 20,
  "slo_start_seconds": 90,
  "slo_breached": false,
  "url": "https://github.example/runs/777"
}
JSON
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
rg -q "Fresh canary run 777 started on ez-runner-test-2 in 10s" /tmp/ezgha-gate4-test.out
rg -q "Gate 4: Fresh nonce-tracked canary ran successfully on the ezgha fleet" /tmp/ezgha-gate4-test.out
