#!/usr/bin/env bash
# Hermetic coverage for the ezgha-host-health-alert producer's Cloud Logging
# payload type (alerting-delivery-audit-2026-11-16, jleechanorg/roadmap):
# emit() must pass --payload-type=json so entries land as jsonPayload.
#
# The two CRITICAL log-based alert policies filter on
#   severity>=ERROR AND jsonPayload.cause=("fleet"|"disk")
# (see ensure_policies in scripts/ezgha-host-health-alert.sh). Without the
# flag, `gcloud logging write` stores the JSON string as textPayload,
# jsonPayload.cause never matches, and the policies are dead — a real disk
# breach on 2026-11-13 went unpaged until a hand-written canary entry
# (2026-11-17) proved policy + Slack delivery work once jsonPayload exists.
# The sibling producers (runner-offline-queued-alert.sh,
# testflight-workflow-alert.sh) already pass --payload-type=json.
#
# Driven entirely by the script's audit-mode env hooks (HEALTH_ALERT_*), so no
# docker/ssh/systemctl/gcloud is touched. The gcloud stub records its argv and
# captures the payload argument for JSON validation.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$ROOT/scripts/ezgha-host-health-alert.sh"
W="$(mktemp -d)"
trap 'rm -rf "${W:?}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }; pass() { echo "PASS: $*"; }

cat > "$W/gcloud" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
if [ "$1" = "logging" ] && [ "$2" = "write" ]; then
  printf '%s' "$4" > "$STUB_PAYLOAD"
fi
STUB
chmod +x "$W/gcloud"

# A first disk-floor breach emits exactly one WARNING entry with cause=disk
# through emit(); every alert path in the script funnels through emit().
env \
  GCLOUD_BIN="$W/gcloud" STUB_LOG="$W/log" STUB_PAYLOAD="$W/payload" \
  HEALTH_ALERT_HOST="testhost" HEALTH_ALERT_PLATFORM="Linux" \
  HEALTH_ALERT_STATE_DIR="$W/state" \
  HEALTH_ALERT_SERVICE_OK=1 HEALTH_ALERT_PEER_OK=1 \
  HEALTH_ALERT_PEER_FREE_GB=100 HEALTH_ALERT_PEER_CONTAINERS=4 HEALTH_ALERT_PEER_SERVICE=active \
  HEALTH_ALERT_FREE_GB=25 HEALTH_ALERT_CONTAINER_COUNT=18 \
  HEALTH_ALERT_ALERTS_FILE="$W/alerts-none.jsonl" \
  "$S" >"$W/out" 2>"$W/err" || true

[ -s "$W/log" ] || fail "expected the disk-floor breach to emit a Cloud Logging entry"

# ── 1. The write must declare a JSON payload, not default to text ───────────
grep -q -- '--payload-type=json' "$W/log" \
  || fail "emit() must pass --payload-type=json so jsonPayload.cause policies can match (entries land as textPayload otherwise)"

# ── 2. The payload must really be JSON (gcloud rejects invalid JSON and the
#       producer swallows write failures, so this is the silent-loss guard) ──
[ -s "$W/payload" ] || fail "stub captured no payload argument"
jq -e . "$W/payload" >/dev/null \
  || fail "payload must be valid JSON or gcloud --payload-type=json rejects it (and emit() swallows the failure)"
jq -e '.cause == "disk"' "$W/payload" >/dev/null \
  || fail "payload must carry cause=disk for the disk policy filter"

pass "emit() writes --payload-type=json with a valid JSON payload carrying cause"
