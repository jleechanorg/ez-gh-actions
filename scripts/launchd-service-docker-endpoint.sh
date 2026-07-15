#!/usr/bin/env bash
# Select the same Docker daemon as the persisted launchd service on macOS.
use_launchd_service_docker_endpoint() {
  local platform="${1:-}"
  local launchd_plist LAUNCHD_DOCKER_HOST

  [ "$platform" = "macos" ] || return 0
  launchd_plist="$HOME/Library/LaunchAgents/org.jleechanorg.ezgha.plist"
  if LAUNCHD_DOCKER_HOST=$(plutil -extract EnvironmentVariables.DOCKER_HOST raw -o - "$launchd_plist" 2>/dev/null) \
      && [ -n "$LAUNCHD_DOCKER_HOST" ]; then
    export DOCKER_HOST="$LAUNCHD_DOCKER_HOST"
    unset DOCKER_CONTEXT
  fi
}
