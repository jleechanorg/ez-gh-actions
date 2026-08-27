#!/bin/bash
# Retired: this legacy entrypoint must never modify a host.

printf '%s\n' \
  'ERROR: scripts/host/configure-grub-kdump.sh is retired and refuses to run.' \
  'Use scripts/host/apply-cfs-nohz-panic-stop.sh for the supported procedure.' \
  'Read docs/notes/kdump-dedup-maint-window.md before a maintenance window.' >&2
exit 1
