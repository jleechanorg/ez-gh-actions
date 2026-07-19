#!/bin/bash
# scripts/host/configure-grub-kdump.sh
# Configure GRUB to enable kdump (crashkernel=2G), enable CPU cgroups,
# install/enable kdump-tools/kexec-tools, and update GRUB transactionally.
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

BACKUP_FILE="${GRUB_FILE}.bak.$(date +%Y%m%d%H%M%S)"
echo "Backing up $GRUB_FILE to $BACKUP_FILE..."
cp "$GRUB_FILE" "$BACKUP_FILE"

# Trap to restore backup on failure
cleanup() {
    if [ $? -ne 0 ]; then
        echo "Error detected. Restoring $GRUB_FILE from backup..." >&2
        cp "$BACKUP_FILE" "$GRUB_FILE"
        if command -v update-grub >/dev/null 2>&1; then
            update-grub || true
        fi
    fi
}
trap cleanup EXIT

# Read current GRUB_CMDLINE_LINUX_DEFAULT
line=$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" || true)

if [ -z "$line" ]; then
    echo "Error: GRUB_CMDLINE_LINUX_DEFAULT not found in $GRUB_FILE" >&2
    exit 1
fi

# Extract the value inside quotes
value=$(echo "$line" | sed -E 's/^GRUB_CMDLINE_LINUX_DEFAULT="([^"]*)"/\1/')

echo "Current GRUB_CMDLINE_LINUX_DEFAULT: \"$value\""

# 1. Remove cgroup_disable=cpu if present
new_value=$(echo "$value" | sed -E 's/\b(cgroup_disable=cpu)\b//g')

# 2. Remove any existing crashkernel=... parameter to avoid conflicts/duplicates
new_value=$(echo "$new_value" | sed -E 's/\b(crashkernel=[^[:space:]]+)\b//g')

# 3. Add sufficient crashkernel=2G
new_value="$new_value crashkernel=2G"

# Clean up any duplicate spaces
new_value=$(echo "$new_value" | xargs)

echo "New GRUB_CMDLINE_LINUX_DEFAULT: \"$new_value\""

# Update GRUB file
sed -i.tmp -E "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$new_value\"|" "$GRUB_FILE"
rm -f "${GRUB_FILE}.tmp"

echo "GRUB configuration updated in $GRUB_FILE."
echo "Running update-grub..."
update-grub

# 4. Install and enable kdump-tools / kexec-tools
echo "Installing kdump-tools and kexec-tools if missing..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y kdump-tools kexec-tools makedumpfile

# Configure kdump-tools to be active
KDUMP_TOOLS_CFG="/etc/default/kdump-tools"
if [ -f "$KDUMP_TOOLS_CFG" ]; then
    echo "Configuring kdump-tools..."
    sed -i -E 's/^USE_KDUMP=.*/USE_KDUMP=1/' "$KDUMP_TOOLS_CFG"
fi

if command -v systemctl >/dev/null 2>&1; then
    echo "Enabling and starting kdump-tools service..."
    systemctl enable kdump-tools.service || true
    systemctl start kdump-tools.service || true
fi

echo "=========================================================="
echo "SUCCESS: GRUB and kdump configured."
echo "Please reboot the host system to apply the kernel parameters."
echo "=========================================================="

# Disable failure-trap on successful completion
trap - EXIT
