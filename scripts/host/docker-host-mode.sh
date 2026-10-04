#!/usr/bin/env bash
set -euo pipefail
print_endpoint=0
if [ "${1:-}" = --print-endpoint ]; then print_endpoint=1; shift; fi
[ "$#" -le 1 ] || { echo "usage: $0 [--print-endpoint] [endpoint]" >&2; exit 2; }
if [ "$#" -eq 1 ]; then
  endpoint="$1"
elif [ -n "${DOCKER_CONTEXT:-}" ]; then
  endpoint="$(docker context inspect "$DOCKER_CONTEXT" --format '{{.Endpoints.docker.Host}}')" \
    || { echo "unknown endpoint: named context lookup failed" >&2; exit 2; }
elif [ -n "${DOCKER_HOST:-}" ]; then
  endpoint="$DOCKER_HOST"
else
  endpoint="$(docker context inspect --format '{{.Endpoints.docker.Host}}')" \
    || { echo "unknown endpoint: active context lookup failed" >&2; exit 2; }
fi
[ -n "$endpoint" ] || { echo "unknown endpoint: context has no endpoint" >&2; exit 2; }
if [ "$print_endpoint" -eq 1 ]; then printf '%s\n' "$endpoint"; exit 0; fi
kernel="$(env -u DOCKER_CONTEXT DOCKER_HOST="$endpoint" docker info --format '{{.KernelVersion}}' 2>/dev/null)" \
  || { echo "unknown endpoint: kernel probe failed" >&2; exit 2; }
[ -n "$kernel" ] || { echo "unknown endpoint: empty kernel probe" >&2; exit 2; }
[ "$(uname -s)" != Darwin ] || { echo vm-backed; exit 0; }
case "$endpoint" in
  unix:///var/run/docker.sock|unix:///run/docker.sock)
    [ "$kernel" = "$(uname -r)" ] || { echo "unknown endpoint: kernel does not match this host" >&2; exit 2; }
    echo host-docker ;;
  "unix://${HOME}/.colima/default/docker.sock") echo vm-backed ;;
  *) echo "unknown endpoint: $endpoint" >&2; exit 2 ;;
esac
