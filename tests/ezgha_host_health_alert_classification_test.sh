#!/usr/bin/env bash
# Hermetic coverage for ezgha-host-health-alert.sh failure classification
# (bead jleechan-v8ms): a host-disk verdict must never page as "runners down".
#
# Every probe is driven by the script's audit-mode env hooks (HEALTH_ALERT_*), so
# no docker/ssh/systemctl/gcloud is touched. The gcloud stub records the exact
# CLI arguments, which is how the emitted severity and payload are asserted.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$ROOT/scripts/ezgha-host-health-alert.sh"
W="$(mktemp -d)"
trap 'rm -rf "${W:?}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }; pass() { echo "PASS: $*"; }
cat > "$W/gcloud" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
STUB
chmod +x "$W/gcloud"

NOW=$(date +%s)
json_log() { printf '{"status":"%s", "last_sent_fleet":0, "last_sent_disk":0, "disk_breach_since":%s, "updated_at":"x"}\n' "$1" "$2"; }
state_dir() { mkdir -p "$W/state-$1"; }
# fixed base env: fleet + peer healthy, disk under floor unless overridden per case
run() { # case free_gb containers [extra env...]
  local case="$1" free="$2" cnt="$3"; shift 3
  state_dir "$case"
  env \
    GCLOUD_BIN="$W/gcloud" STUB_LOG="$W/log-$case" \
    HEALTH_ALERT_HOST="testhost" HEALTH_ALERT_PLATFORM="Linux" \
    HEALTH_ALERT_STATE_DIR="$W/state-$case" \
    HEALTH_ALERT_SERVICE_OK=1 HEALTH_ALERT_PEER_OK=1 \
    HEALTH_ALERT_PEER_FREE_GB=100 HEALTH_ALERT_PEER_CONTAINERS=4 HEALTH_ALERT_PEER_SERVICE=active \
    HEALTH_ALERT_FREE_GB="$free" HEALTH_ALERT_CONTAINER_COUNT="$cnt" \
    "$@" "$S" >"$W/out-$case" 2>"$W/err-$case" || true
}
errors() { if [ -f "$W/log-$1" ]; then grep -c -- "--severity=ERROR" "$W/log-$1" || true; else echo 0; fi; }
warnings() { if [ -f "$W/log-$1" ]; then grep -c -- "--severity=WARNING" "$W/log-$1" || true; else echo 0; fi; }
infos() { if [ -f "$W/log-$1" ]; then grep -c -- "--severity=INFO" "$W/log-$1" || true; else echo 0; fi; }

# ── 1. Disk under floor, first breach: logged at WARNING, never ERROR ────────
run diska 25 18
[ "$(errors diska)" = 0 ] || fail "a fresh disk-floor breach must not page (ERROR) — disk is not a fleet outage"
[ "$(warnings diska)" = 1 ] || fail "a fresh disk-floor breach must still be logged at WARNING"
grep -q '"cause":"disk"' "$W/log-diska" || fail "disk payload must carry cause=disk"
grep -q '"status":"DEGRADED"' "$W/log-diska" || fail "disk-only verdict status must be DEGRADED, not DOWN"
pass "fresh disk-floor breach logs WARNING + cause=disk, no page"

# ── 2. State must live under the configured state dir, never /tmp ────────────
[ -f "$W/state-diska/host-health-alert-testhost.json" ] || fail "state file must be written under HEALTH_ALERT_STATE_DIR"
grep -q 'disk_breach_since' "$W/state-diska/host-health-alert-testhost.json" || fail "state must persist disk_breach_since"
pass "throttle state persists outside /tmp"

# ── 3. Disk breach sustained past the self-heal window: escalates once ───────
state_dir diskb; json_log DEGRADED $(( NOW - 1200 )) > "$W/state-diskb/host-health-alert-testhost.json"
run diskb 25 18
[ "$(errors diskb)" = 1 ] || fail "a disk breach past DISK_PAGE_AFTER_MIN must escalate to ERROR"
grep -q '"cause":"disk"' "$W/log-diskb" || fail "escalated page must be attributed to disk"
grep -q '"disk_breach_min":' "$W/log-diskb" || fail "escalated page must report breach minutes"
pass "sustained disk breach escalates with cause=disk"

# ── 4. Sustained breach repeats are throttled by the persisted cooldown ──────
cat "$W/state-diskb/host-health-alert-testhost.json" > "$W/state-diskb/seed.json"
json_log DISK $(( NOW - 60 )) > "$W/state-diskb/host-health-alert-testhost.json"
sed -i.bak "s/\"last_sent_disk\":0/\"last_sent_disk\":$(( NOW - 60 ))/" "$W/state-diskb/host-health-alert-testhost.json"
run diskb 25 18
[ "$(errors diskb)" = 1 ] || fail "repeat inside the cooldown must be throttled"
pass "repeat page throttled by persisted cooldown"

# ── 5. Emergency floor pages immediately, still as cause=disk ────────────────
run diske 10 18
[ "$(errors diske)" = 1 ] || fail "free space below DISK_EMERGENCY_GB must page immediately"
grep -q '"cause":"disk"' "$W/log-diske" || fail "emergency page must be attributed to disk, not fleet"
pass "emergency disk floor pages immediately with cause=disk"

# ── 6. Real fleet failure pages once, as cause=fleet ────────────────────────
run fleet 100 0
[ "$(errors fleet)" = 1 ] || fail "0 runner containers must page"
grep -q '"cause":"fleet"' "$W/log-fleet" || fail "fleet outage page must carry cause=fleet"
grep -q '"status":"DOWN"' "$W/log-fleet" || fail "fleet outage verdict must be DOWN"
pass "fleet outage pages with cause=fleet"

# ── 7. Fleet failure plus disk pressure still pages fleet (disk listed) ─────
run fleetdisk 20 0
[ "$(errors fleetdisk)" = 1 ] || fail "fleet failure with disk pressure must page once"
grep -q '"cause":"fleet"' "$W/log-fleetdisk" || fail "combined failure must be attributed to fleet"
grep -q "host disk space critical" "$W/log-fleetdisk" || fail "combined page must list the disk check too"
pass "combined fleet+disk pages as fleet with disk detail"

# ── 8. Recovery emits INFO with the recovered cause and clears state ────────
state_dir rec; json_log DOWN 0 > "$W/state-rec/host-health-alert-testhost.json"
run rec 100 18
[ "$(infos rec)" -ge 1 ] || fail "recovery from DOWN must emit an INFO entry"
grep -q '"status":"RECOVERED"' "$W/log-rec" || fail "recovery payload must be RECOVERED"
grep -q '"status":"OK"' "$W/state-rec/host-health-alert-testhost.json" || fail "recovery must reset state to OK"
[ "$(errors rec)" = 0 ] || fail "healthy run must not page"
pass "recovery logs INFO and resets state"

# ── 9. Healthy host is silent ───────────────────────────────────────────────
run healthy 100 18
[ ! -f "$W/log-healthy" ] || fail "healthy run must not call gcloud at all"
pass "healthy run stays silent"

# ── 10. --ensure-policies (dry-run) declares both cause-scoped policies ─────
DRY_OUT=$(GCLOUD_BIN="$W/gcloud" STUB_LOG="$W/log-pol" "$S" --ensure-policies --dry-run 2>&1 || true)
printf '%s' "$DRY_OUT" | grep -q 'Runners Down Alert' || fail "--ensure-policies must declare the fleet policy"
printf '%s' "$DRY_OUT" | grep -q 'host disk below safety floor' || fail "--ensure-policies must declare the disk policy"
[ ! -f "$W/log-pol" ] || fail "--ensure-policies --dry-run must not mutate GCP"
pass "policy ensure (dry-run) declares fleet + disk policies"
grep -q 'jsonPayload.cause=\\"fleet\\"' "$S" || fail "fleet policy filter must be cause-scoped"
grep -q 'jsonPayload.cause=\\"disk\\"' "$S" || fail "disk policy filter must be cause-scoped"
pass "policy filters are cause-scoped"

echo "ALL PASS"
