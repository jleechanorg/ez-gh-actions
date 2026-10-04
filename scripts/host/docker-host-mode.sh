#!/usr/bin/env bash
# Classify the selected Docker endpoint for QEMU containment.
set -euo pipefail
endpoint="${1:-${DOCKER_HOST:-unix:///var/run/docker.sock}}"
kernel="$(env -u DOCKER_CONTEXT DOCKER_HOST="$endpoint" docker info --format '{{.KernelVersion}}' 2>/dev/null || true)"
case "$endpoint" in
  unix:///var/run/docker.sock|unix:///run/docker.sock)
    if [ -n "$kernel" ] && [ "$kernel" = "$(uname -r)" ]; then
      printf '%s\n' host-docker
    else
      printf '%s\n' vm-backed
    fi ;;
  *) printf '%s\n' vm-backed ;;
esac
