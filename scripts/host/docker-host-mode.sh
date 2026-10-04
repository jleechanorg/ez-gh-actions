#!/usr/bin/env bash
set -euo pipefail
[ "$(uname -s)" != Darwin ] || { echo vm-backed; exit 0; }
endpoint="${1:-${DOCKER_HOST:-unix:///var/run/docker.sock}}"
kernel="$(env -u DOCKER_CONTEXT DOCKER_HOST="$endpoint" docker info --format '{{.KernelVersion}}' 2>/dev/null)" \
  || { echo "unknown endpoint: kernel probe failed" >&2; exit 2; }
case "$endpoint" in
  unix:///var/run/docker.sock|unix:///run/docker.sock)
    [ -n "$kernel" ] || { echo "unknown endpoint: native kernel probe failed" >&2; exit 2; }
    [ "$kernel" = "$(uname -r)" ] || { echo "unknown endpoint: kernel does not match this host" >&2; exit 2; }
    echo host-docker ;;
  "unix://${HOME}/.colima/default/docker.sock") echo vm-backed ;;
  *) echo "unknown endpoint: $endpoint" >&2; exit 2 ;;
esac
