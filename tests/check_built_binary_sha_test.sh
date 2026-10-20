#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/binary" <<'BIN'
#!/usr/bin/env bash
printf '%s\n' "$FIXTURE_VERSION"
BIN
chmod +x "$tmp/binary"
cd "$root"
head="$(git rev-parse HEAD)"
check() {
  local expected="$1" version="$2" status=0
  FIXTURE_VERSION="$version" bash scripts/check_built_binary_sha.sh "$tmp/binary" >"$tmp/output" 2>&1 || status=$?
  if [[ "$status" != "$expected" ]]; then
    cat "$tmp/output" >&2
    printf 'FAIL: version %s: expected %s got %s\n' "$version" "$expected" "$status" >&2
    exit 1
  fi
}
check 0 "ezgha 0.1.0-${head:0:7}"
check 0 "ezgha 0.1.0-${head:0:12}"
check 0 "ezgha 0.1.0-$head"
check 1 "ezgha 0.1.0-0000000000000000000000000000000000000000"
check 1 "ezgha 0.1.0-${head:0:7}-dirty"
check 1 "ezgha 0.1.0-unknown"
check 1 "ezgha 0.1.0-${head:0:6}"
check 1 "other 0.1.0-${head:0:7}"
check 1 $'ezgha 0.1.0-'"${head:0:7}"$'\nextra'
# A matching seven-character prefix is insufficient when a longer SHA differs.
next=0; [[ "${head:7:1}" == 0 ]] && next=1
check 1 "ezgha 0.1.0-${head:0:7}${next}"
printf 'PASS: 10 binary SHA verifier fixtures\n'
