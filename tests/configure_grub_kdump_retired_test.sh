#!/usr/bin/env bash
# The retired GRUB/kdump entrypoint must refuse before it can touch the host.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$REPO_ROOT/scripts/host/configure-grub-kdump.sh"
TMP="$(mktemp -d)"
TRIPWIRE_BIN="$TMP/bin"
TRIPWIRE_LOG="$TMP/tripwire.log"
STDERR="$TMP/stderr"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "$TRIPWIRE_BIN"
for command in apt-get cp date grep rm sed systemctl update-grub xargs; do
  cat > "$TRIPWIRE_BIN/$command" <<'EOF'
#!/bin/bash
printf '%s\n' "${0##*/}" >> "$TRIPWIRE_LOG"
exit 97
EOF
  chmod +x "$TRIPWIRE_BIN/$command"
done

rc=0
PATH="$TRIPWIRE_BIN" TRIPWIRE_LOG="$TRIPWIRE_LOG" "$TARGET" >/dev/null 2>"$STDERR" || rc=$?

[ "$rc" -eq 1 ] || fail "retired entrypoint exited $rc instead of refusing with status 1"
[ ! -s "$TRIPWIRE_LOG" ] || fail "retired entrypoint invoked external command(s): $(tr '\n' ' ' < "$TRIPWIRE_LOG")"
/usr/bin/grep -Fq 'scripts/host/apply-cfs-nohz-panic-stop.sh' "$STDERR" \
  || fail "refusal does not name the supported procedure"
/usr/bin/grep -Fq 'docs/notes/kdump-dedup-maint-window.md' "$STDERR" \
  || fail "refusal does not name the maintenance-window note"

printf 'CONFIGURE_GRUB_KDUMP_RETIRED_TEST: PASS\n'
