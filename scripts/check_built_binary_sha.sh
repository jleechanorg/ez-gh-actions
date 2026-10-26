#!/usr/bin/env bash
# Verify the build.rs short-SHA version contract, failing closed on dirty builds.
set -euo pipefail
binary="${1:?usage: check_built_binary_sha.sh BINARY}"
head_sha="$(git rev-parse HEAD)"
version="$("$binary" --version)"
if [[ ! "$version" =~ ^ezgha\ [^[:space:]]+-([0-9a-f]{7,40})$ ]]; then
  printf 'FAIL: malformed or dirty binary version: %s\n' "$version" >&2
  exit 1
fi
installed_sha="${BASH_REMATCH[1]}"
# Match the complete embedded abbreviation, not a fixed seven-character prefix.
if [[ "${head_sha:0:${#installed_sha}}" != "$installed_sha" ]]; then
  printf 'FAIL: HEAD %s does not match binary SHA %s\n' "$head_sha" "$installed_sha" >&2
  exit 1
fi
printf 'PASS: installed binary SHA %s matches HEAD %s\n' "$installed_sha" "$head_sha"
