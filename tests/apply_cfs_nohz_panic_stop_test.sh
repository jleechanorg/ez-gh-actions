#!/usr/bin/env bash
# Fixture integration coverage for the operator-gated CFS/nohz + kdump repair.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

run_case() {
  local label="$1" main_tokens="$2" dropin_tokens="$3"
  local root="$TMP/$label/root" bin="$TMP/$label/bin" trace="$TMP/$label/trace" state="$TMP/$label/sysctl-state"
  mkdir -p "$root/etc/default/grub.d" "$root/etc/sysctl.d" "$root/boot/grub" "$bin"
  printf 'GRUB_CMDLINE_LINUX_DEFAULT="%s"\n' "$main_tokens" > "$root/etc/default/grub"
  printf 'GRUB_CMDLINE_LINUX_DEFAULT="%s"\n' "$dropin_tokens" > "$root/etc/default/grub.d/kdump-tools.cfg"
  printf 'generated grub bytes\n' > "$root/boot/grub/grub.cfg"
  printf 'kernel.panic=0\nkernel.panic_on_oops=0\n' > "$state"
  printf 'old sysctl drop-in\n' > "$root/etc/sysctl.d/99-ezgha-oops-reboot.conf"
  printf 'old nohz drop-in\n' > "$root/etc/default/grub.d/zz-ezgha-nohz-panic.cfg"
  : > "$trace"

  # shellcheck disable=SC2016 # Generated fixture intentionally retains its own expansions.
  printf '#!/usr/bin/env bash\nprintf "sysctl %%s\\n" "$*" >> "%s"\nif [ "${1:-}" = "-n" ]; then case "${2:-}" in kernel.panic) sed -n "s/^kernel.panic=//p" "%s";; kernel.panic_on_oops) sed -n "s/^kernel.panic_on_oops=//p" "%s";; *) exit 1;; esac; exit 0; fi\nif [ "${1:-}" = "-w" ]; then for assignment in "${@:2}"; do key="${assignment%%%%=*}"; value="${assignment#*=}"; sed -i "s/^${key}=.*/${key}=${value}/" "%s"; done; exit 0; fi\nexit 1\n' "$trace" "$state" "$state" "$state" > "$bin/sysctl"
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
  grep -Fqx 'kernel.panic=10' "$state" || fail "$label did not set live kernel.panic"
  grep -Fqx 'kernel.panic_on_oops=1' "$state" || fail "$label did not set live kernel.panic_on_oops"
}

run_case exact 'quiet crashkernel=512M splash' 'crashkernel=512M,high'
run_case comma_qualified 'quiet crashkernel=512M,high splash' 'crashkernel=512M,high'
run_case repeated 'crashkernel=512M quiet crashkernel=2G crashkernel=512M,high' 'crashkernel=512M,high'

# Fail closed before update-grub unless kdump-tools.cfg is the sole remaining
# effective crashkernel source.
bad_root="$TMP/bad/root"
bad_bin="$TMP/bad/bin"
bad_state="$TMP/bad/sysctl-state"
mkdir -p "$bad_root/etc/default/grub.d" "$bad_root/etc/sysctl.d" "$bad_root/boot/grub" "$bad_bin"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet crashkernel=2G"\n' > "$bad_root/etc/default/grub"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"\n' > "$bad_root/etc/default/grub.d/kdump-tools.cfg"
printf 'generated grub bytes\n' > "$bad_root/boot/grub/grub.cfg"
printf 'kernel.panic=4\nkernel.panic_on_oops=0\n' > "$bad_state"
printf 'old sysctl drop-in\n' > "$bad_root/etc/sysctl.d/99-ezgha-oops-reboot.conf"
printf 'old nohz drop-in\n' > "$bad_root/etc/default/grub.d/zz-ezgha-nohz-panic.cfg"
# shellcheck disable=SC2016 # Generated fixture intentionally retains its own expansions.
printf '#!/usr/bin/env bash\nif [ "${1:-}" = "-n" ]; then case "${2:-}" in kernel.panic) sed -n "s/^kernel.panic=//p" "%s";; kernel.panic_on_oops) sed -n "s/^kernel.panic_on_oops=//p" "%s";; *) exit 1;; esac; exit 0; fi\nexit 99\n' "$bad_state" "$bad_state" > "$bad_bin/sysctl"
printf '#!/usr/bin/env bash\necho unsafe-update-grub >&2\nexit 99\n' > "$bad_bin/update-grub"
chmod +x "$bad_bin/sysctl" "$bad_bin/update-grub"
cp "$bad_root/etc/default/grub" "$TMP/bad/original-grub"
cp "$bad_root/etc/sysctl.d/99-ezgha-oops-reboot.conf" "$TMP/bad/original-sysctl"
cp "$bad_root/etc/default/grub.d/zz-ezgha-nohz-panic.cfg" "$TMP/bad/original-nohz"
# A missing distro source must fail before even reading/applying live sysctls.
rm "$bad_root/etc/default/grub.d/kdump-tools.cfg"
bad_rc=0
APPLY_PANIC_STOP_ROOT="$bad_root" \
  APPLY_PANIC_STOP_SYSCTL="$bad_bin/sysctl" \
  APPLY_PANIC_STOP_UPDATE_GRUB="$bad_bin/update-grub" \
  bash "$REPO_ROOT/scripts/host/apply-cfs-nohz-panic-stop.sh" >/dev/null 2>&1 || bad_rc=$?
[ "$bad_rc" -ne 0 ] || fail "missing kdump-tools source passed"
cmp -s "$TMP/bad/original-grub" "$bad_root/etc/default/grub" || fail "missing kdump source changed GRUB"
cmp -s "$TMP/bad/original-sysctl" "$bad_root/etc/sysctl.d/99-ezgha-oops-reboot.conf" || fail "missing kdump source changed sysctl drop-in"
cmp -s "$TMP/bad/original-nohz" "$bad_root/etc/default/grub.d/zz-ezgha-nohz-panic.cfg" || fail "missing kdump source changed nohz drop-in"
grep -Fqx 'kernel.panic=4' "$bad_state" || fail "missing kdump source changed live kernel.panic"
grep -Fqx 'kernel.panic_on_oops=0' "$bad_state" || fail "missing kdump source changed live kernel.panic_on_oops"

# An invalid source (present but without a crashkernel token) is also rejected
# before any mutation.
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"\n' > "$bad_root/etc/default/grub.d/kdump-tools.cfg"
bad_rc=0
APPLY_PANIC_STOP_ROOT="$bad_root" \
  APPLY_PANIC_STOP_SYSCTL="$bad_bin/sysctl" \
  APPLY_PANIC_STOP_UPDATE_GRUB="$bad_bin/update-grub" \
  bash "$REPO_ROOT/scripts/host/apply-cfs-nohz-panic-stop.sh" >/dev/null 2>&1 || bad_rc=$?
[ "$bad_rc" -ne 0 ] || fail "missing kdump-tools crashkernel source passed"
cmp -s "$TMP/bad/original-grub" "$bad_root/etc/default/grub" || fail "invalid kdump source changed GRUB"
cmp -s "$TMP/bad/original-sysctl" "$bad_root/etc/sysctl.d/99-ezgha-oops-reboot.conf" || fail "invalid kdump source changed sysctl drop-in"
cmp -s "$TMP/bad/original-nohz" "$bad_root/etc/default/grub.d/zz-ezgha-nohz-panic.cfg" || fail "invalid kdump source changed nohz drop-in"
grep -Fqx 'kernel.panic=4' "$bad_state" || fail "invalid kdump source changed live kernel.panic"
grep -Fqx 'kernel.panic_on_oops=0' "$bad_state" || fail "invalid kdump source changed live kernel.panic_on_oops"

# A failing update-grub must restore the exact original main GRUB source.
rollback_root="$TMP/rollback/root"
rollback_bin="$TMP/rollback/bin"
rollback_trace="$TMP/rollback/trace"
rollback_err="$TMP/rollback/stderr"
rollback_state="$TMP/rollback/sysctl-state"
rollback_generated="$rollback_root/boot/grub/grub.cfg"
rollback_update_count="$TMP/rollback/update-count"
mkdir -p "$rollback_root/etc/default/grub.d" "$rollback_root/etc/sysctl.d" "$rollback_root/boot/grub" "$rollback_bin"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet crashkernel=2G splash"\n' > "$rollback_root/etc/default/grub"
cp "$rollback_root/etc/default/grub" "$TMP/rollback/original-grub"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="crashkernel=512M,high"\n' > "$rollback_root/etc/default/grub.d/kdump-tools.cfg"
printf 'original generated grub bytes\n' > "$rollback_generated"
cp "$rollback_generated" "$TMP/rollback/original-generated"
printf 'kernel.panic=4\nkernel.panic_on_oops=0\n' > "$rollback_state"
printf 'old sysctl drop-in\n' > "$rollback_root/etc/sysctl.d/99-ezgha-oops-reboot.conf"
printf 'old nohz drop-in\n' > "$rollback_root/etc/default/grub.d/zz-ezgha-nohz-panic.cfg"
cp "$rollback_root/etc/sysctl.d/99-ezgha-oops-reboot.conf" "$TMP/rollback/original-sysctl"
cp "$rollback_root/etc/default/grub.d/zz-ezgha-nohz-panic.cfg" "$TMP/rollback/original-nohz"
# shellcheck disable=SC2016 # Generated fixtures intentionally retain their own expansions.
printf '#!/usr/bin/env bash\nprintf "sysctl %%s\\n" "$*" >> "%s"\nif [ "${1:-}" = "-n" ]; then case "${2:-}" in kernel.panic) sed -n "s/^kernel.panic=//p" "%s";; kernel.panic_on_oops) sed -n "s/^kernel.panic_on_oops=//p" "%s";; *) exit 1;; esac; exit 0; fi\nif [ "${1:-}" = "-w" ]; then for assignment in "${@:2}"; do key="${assignment%%%%=*}"; value="${assignment#*=}"; sed -i "s/^${key}=.*/${key}=${value}/" "%s"; done; exit 0; fi\nexit 1\n' "$rollback_trace" "$rollback_state" "$rollback_state" "$rollback_state" > "$rollback_bin/sysctl"
# shellcheck disable=SC2016 # Generated fixture intentionally retains its own expansions.
printf '#!/usr/bin/env bash\nprintf "update-grub\\n" >> "%s"\ncount=0; [ -f "%s" ] && count=$(cat "%s")\nprintf "%%s" "$((count + 1))" > "%s"\nprintf "partially mutated generated grub bytes %%s\\n" "$((count + 1))" > "%s"\nexit 7\n' "$rollback_trace" "$rollback_update_count" "$rollback_update_count" "$rollback_update_count" "$rollback_generated" > "$rollback_bin/update-grub"
printf '#!/usr/bin/env bash\nprintf "root %%s\\n" "$*" >> "%s"\nexec "$@"\n' "$rollback_trace" > "$rollback_bin/run-root"
chmod +x "$rollback_bin/sysctl" "$rollback_bin/update-grub" "$rollback_bin/run-root"
rollback_rc=0
APPLY_PANIC_STOP_ROOT="$rollback_root" \
  APPLY_PANIC_STOP_ROOT_CMD="$rollback_bin/run-root" \
  APPLY_PANIC_STOP_SYSCTL="$rollback_bin/sysctl" \
  APPLY_PANIC_STOP_UPDATE_GRUB="$rollback_bin/update-grub" \
  bash "$REPO_ROOT/scripts/host/apply-cfs-nohz-panic-stop.sh" >/dev/null 2>"$rollback_err" || rollback_rc=$?
[ "$rollback_rc" -ne 0 ] || fail "failing update-grub returned success"
cmp -s "$TMP/rollback/original-grub" "$rollback_root/etc/default/grub" \
  || fail "failing update-grub did not restore the exact original GRUB source"
cmp -s "$TMP/rollback/original-sysctl" "$rollback_root/etc/sysctl.d/99-ezgha-oops-reboot.conf" \
  || fail "failing update-grub did not restore the persistent sysctl drop-in"
cmp -s "$TMP/rollback/original-nohz" "$rollback_root/etc/default/grub.d/zz-ezgha-nohz-panic.cfg" \
  || fail "failing update-grub did not restore the persistent nohz drop-in"
cmp -s "$TMP/rollback/original-generated" "$rollback_generated" \
  || fail "failing update-grub did not restore generated GRUB bytes"
grep -Fqx 'kernel.panic=4' "$rollback_state" \
  || fail "failing update-grub did not restore live kernel.panic"
grep -Fqx 'kernel.panic_on_oops=0' "$rollback_state" \
  || fail "failing update-grub did not restore live kernel.panic_on_oops"
grep -Fqx "root $rollback_bin/update-grub" "$rollback_trace" \
  || fail "failing update-grub bypassed the privileged wrapper"
[ "$(grep -Fc "root $rollback_bin/update-grub" "$rollback_trace")" -eq 2 ] \
  || fail "failing update-grub did not invoke privileged rollback regeneration"
grep -q 'could not regenerate GRUB from restored sources' "$rollback_err" \
  || fail "double update-grub failure was not reported loudly"

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
