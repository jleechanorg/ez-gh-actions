#!/usr/bin/env bash
# Fixture integration coverage for the operator-gated CFS/nohz + kdump repair.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

run_case() {
  local label="$1" main_tokens="$2" dropin_tokens="$3"
  local root="$TMP/$label/root" bin="$TMP/$label/bin" trace="$TMP/$label/trace"
  mkdir -p "$root/etc/default/grub.d" "$root/etc/sysctl.d" "$bin"
  printf 'GRUB_CMDLINE_LINUX_DEFAULT="%s"\n' "$main_tokens" > "$root/etc/default/grub"
  printf 'GRUB_CMDLINE_LINUX_DEFAULT="%s"\n' "$dropin_tokens" > "$root/etc/default/grub.d/kdump-tools.cfg"
  : > "$trace"

  printf '#!/usr/bin/env bash\nprintf "sysctl %%s\\n" "$*" >> "%s"\n' "$trace" > "$bin/sysctl"
  printf '#!/usr/bin/env bash\nprintf "update-grub\\n" >> "%s"\n' "$trace" > "$bin/update-grub"
  printf '#!/usr/bin/env bash\nprintf "root %%s\\n" "$*" >> "%s"\nexec "$@"\n' "$trace" > "$bin/run-root"
  chmod +x "$bin/sysctl" "$bin/update-grub" "$bin/run-root"

  APPLY_PANIC_STOP_ROOT="$root" \
    APPLY_PANIC_STOP_ROOT_CMD="$bin/run-root" \
    APPLY_PANIC_STOP_SYSCTL="$bin/sysctl" \
    APPLY_PANIC_STOP_UPDATE_GRUB="$bin/update-grub" \
    bash "$REPO_ROOT/scripts/host/apply-cfs-nohz-panic-stop.sh" >/dev/null

  if grep -Eq '(^|[[:space:]"])crashkernel=' "$root/etc/default/grub"; then
    fail "$label left a crashkernel token in the main GRUB source"
  fi
  [ "$(grep -Eo 'crashkernel=[^[:space:]\"]+' "$root/etc/default/grub.d/kdump-tools.cfg" | wc -l)" -eq 1 ] \
    || fail "$label did not retain exactly one kdump-tools crashkernel token"
  grep -qx 'update-grub' "$trace" || fail "$label did not regenerate GRUB"
  grep -Fqx "root $bin/update-grub" "$trace" || fail "$label did not run update-grub through the privileged wrapper"
}

run_case exact 'quiet crashkernel=512M splash' 'crashkernel=512M,high'
run_case comma_qualified 'quiet crashkernel=512M,high splash' 'crashkernel=512M,high'
run_case repeated 'crashkernel=512M quiet crashkernel=2G crashkernel=512M,high' 'crashkernel=512M,high'

# Fail closed before update-grub unless kdump-tools.cfg is the sole remaining
# effective crashkernel source.
bad_root="$TMP/bad/root"
bad_bin="$TMP/bad/bin"
mkdir -p "$bad_root/etc/default/grub.d" "$bad_root/etc/sysctl.d" "$bad_bin"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet crashkernel=2G"\n' > "$bad_root/etc/default/grub"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"\n' > "$bad_root/etc/default/grub.d/kdump-tools.cfg"
printf '#!/usr/bin/env bash\nexit 0\n' > "$bad_bin/sysctl"
printf '#!/usr/bin/env bash\necho unsafe-update-grub >&2\nexit 99\n' > "$bad_bin/update-grub"
chmod +x "$bad_bin/sysctl" "$bad_bin/update-grub"
bad_rc=0
APPLY_PANIC_STOP_ROOT="$bad_root" \
  APPLY_PANIC_STOP_SYSCTL="$bad_bin/sysctl" \
  APPLY_PANIC_STOP_UPDATE_GRUB="$bad_bin/update-grub" \
  bash "$REPO_ROOT/scripts/host/apply-cfs-nohz-panic-stop.sh" >/dev/null 2>&1 || bad_rc=$?
[ "$bad_rc" -ne 0 ] || fail "missing kdump-tools crashkernel source passed"

# A failing update-grub must restore the exact original main GRUB source.
rollback_root="$TMP/rollback/root"
rollback_bin="$TMP/rollback/bin"
rollback_trace="$TMP/rollback/trace"
mkdir -p "$rollback_root/etc/default/grub.d" "$rollback_root/etc/sysctl.d" "$rollback_bin"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet crashkernel=2G splash"\n' > "$rollback_root/etc/default/grub"
cp "$rollback_root/etc/default/grub" "$TMP/rollback/original-grub"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="crashkernel=512M,high"\n' > "$rollback_root/etc/default/grub.d/kdump-tools.cfg"
printf '#!/usr/bin/env bash\nexit 0\n' > "$rollback_bin/sysctl"
printf '#!/usr/bin/env bash\nexit 7\n' > "$rollback_bin/update-grub"
printf '#!/usr/bin/env bash\nprintf "root %%s\\n" "$*" >> "%s"\nexec "$@"\n' "$rollback_trace" > "$rollback_bin/run-root"
chmod +x "$rollback_bin/sysctl" "$rollback_bin/update-grub" "$rollback_bin/run-root"
rollback_rc=0
APPLY_PANIC_STOP_ROOT="$rollback_root" \
  APPLY_PANIC_STOP_ROOT_CMD="$rollback_bin/run-root" \
  APPLY_PANIC_STOP_SYSCTL="$rollback_bin/sysctl" \
  APPLY_PANIC_STOP_UPDATE_GRUB="$rollback_bin/update-grub" \
  bash "$REPO_ROOT/scripts/host/apply-cfs-nohz-panic-stop.sh" >/dev/null 2>&1 || rollback_rc=$?
[ "$rollback_rc" -ne 0 ] || fail "failing update-grub returned success"
cmp -s "$TMP/rollback/original-grub" "$rollback_root/etc/default/grub" \
  || fail "failing update-grub did not restore the exact original GRUB source"
grep -Fqx "root $rollback_bin/update-grub" "$rollback_trace" \
  || fail "failing update-grub bypassed the privileged wrapper"

remediation="$(bash "$REPO_ROOT/scripts/host/kdump-remediation.sh")"
echo "$remediation" | grep -q 'apply-cfs-nohz-panic-stop.sh' \
  || fail "remediation does not name the supported repair"
if echo "$remediation" | grep -q 'configure-grub-kdump.sh'; then
  fail "remediation still names the unsafe duplicate-crashkernel script"
fi

if rg -n '(^|[[:space:]])(sudo[[:space:]]+bash[[:space:]]+)?scripts/host/configure-grub-kdump\.sh' \
  "$REPO_ROOT/docs/verify-exit-criteria.sh" "$REPO_ROOT/scripts/host/crash-capture-verify.sh" >/dev/null; then
  fail "a live verifier still recommends the unsafe configure-grub-kdump.sh path"
fi

echo "APPLY_CFS_NOHZ_PANIC_STOP_TEST: PASS"
