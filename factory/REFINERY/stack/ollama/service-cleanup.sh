#!/usr/bin/env bash
# service-cleanup.sh — Remove persistent Ollama services
set -euo pipefail

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
	echo "[service-cleanup.sh] Requires root privileges, escalating with sudo..."
	sudo --preserve-env=PATH "$0" "$@"
	exit $?
fi

# First, check if there are any ollama services at all to avoid grep error
if ! systemctl list-units --type=service --all | grep -q 'ollama'; then
    echo "No Ollama services found to clean up."
    exit 0
fi

echo "Found Ollama services. Stopping and disabling them..."
ollama_services=$(systemctl list-units --type=service | grep 'ollama' | awk '{print $1}')

if [[ -n "$ollama_services" ]]; then
	for svc in $ollama_services; do
		echo "Processing service: $svc"
		if systemctl is-active --quiet "$svc"; then
			systemctl stop "$svc" && echo "  - Stopped."
		fi
		if systemctl is-enabled --quiet "$svc"; then
			systemctl disable "$svc" && echo "  - Disabled."
		fi
		systemctl reset-failed "$svc" || true
	done
	echo "Ollama service cleanup complete."
else
    # This block should theoretically not be reached due to the initial check,
    # but is kept as a safeguard.
	echo "No active or enabled Ollama services were found to modify."
fi

