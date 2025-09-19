#!/usr/bin/env bash
# This script configures passwordless sudo for the 'fuze' user.
# It creates a dedicated sudoers file in /etc/sudoers.d/
# This is safer than editing /etc/sudoers directly.

set -euo pipefail

# Ensure the script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root. Please run with 'sudo'." 
   exit 1
fi

USERNAME="fuze"
SUDOERS_FILE="/etc/sudoers.d/99-${USERNAME}-passwordless"

echo "Configuring passwordless sudo for user: ${USERNAME}"

# Write the sudoers rule to the new file
# The 'tee' command is used to write the file as root.
tee "$SUDOERS_FILE" > /dev/null <<EOF
# Allow ${USERNAME} user to run all commands without a password
${USERNAME} ALL=(ALL) NOPASSWD: ALL
EOF

# Set the correct file permissions (read-only for root)
chmod 0440 "$SUDOERS_FILE"

echo "Successfully configured passwordless sudo for '${USERNAME}'."
echo "Please run your next command with 'sudo' to test it. You should not be prompted for a password."
