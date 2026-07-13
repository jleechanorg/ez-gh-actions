#!/bin/bash
# scripts/host/configure-grub-kdump.sh
# Configure GRUB to enable kdump (crashkernel) and remove cgroup_disable=cpu.
# This script must be run with sudo/root privileges.

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root (using sudo)." >&2
    exit 1
fi

GRUB_FILE="/etc/default/grub"

if [ ! -f "$GRUB_FILE" ]; then
    echo "Error: GRUB configuration file not found at $GRUB_FILE" >&2
    exit 1
fi

echo "Backing up $GRUB_FILE to ${GRUB_FILE}.bak..."
cp "$GRUB_FILE" "${GRUB_FILE}.bak"

# Read current GRUB_CMDLINE_LINUX_DEFAULT
line=$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" || true)

if [ -z "$line" ]; then
    echo "Error: GRUB_CMDLINE_LINUX_DEFAULT not found in $GRUB_FILE" >&2
    exit 1
fi

# Extract the value inside quotes
value=$(echo "$line" | sed -E 's/^GRUB_CMDLINE_LINUX_DEFAULT="([^"]*)"/\1/')

echo "Current GRUB_CMDLINE_LINUX_DEFAULT: \"$value\""

# 1. Remove cgroup_disable=cpu
new_value=$(echo "$value" | sed -E 's/\b(cgroup_disable=cpu)\b//g')

# 2. Add crashkernel=512M if not present
if [[ ! "$new_value" =~ \b(crashkernel=[^[:space:]]+)\b ]]; then
    new_value="$new_value crashkernel=512M"
fi

# Clean up any duplicate spaces
new_value=$(echo "$new_value" | xargs)

echo "New GRUB_CMDLINE_LINUX_DEFAULT: \"$new_value\""

# Update GRUB file
sed -i.tmp -E "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$new_value\"|" "$GRUB_FILE"
rm -f "${GRUB_FILE}.tmp"

echo "GRUB configuration updated successfully."
echo "Running update-grub..."
update-grub

echo "=========================================================="
echo "SUCCESS: GRUB configured and update-grub completed."
echo "Please reboot the host system to apply the changes."
echo "=========================================================="
