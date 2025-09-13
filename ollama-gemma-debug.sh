#!/usr/bin/env bash
# Orchestrator: cleanup → benchmark → export (Ollama, Gemma debug profile)
# Location: repo root
# Usage: ./ollama-gemma-debug.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UST="${ROOT_DIR}/fuze-box/stack/ust.sh"
ENV_FILE="${ROOT_DIR}/fuze-box/stack/FuZe-CORE-gemma-debug.env"

if [ ! -x "$UST" ]; then
  echo "ust.sh not found or not executable: $UST" >&2
  exit 2
fi
if [ ! -f "$ENV_FILE" ]; then
  echo "Gemma debug env not found: $ENV_FILE" >&2
  exit 2
fi

# Re-exec as root preserving env (ust enforces root and reads @env file)
if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E "$0" "$@"
fi

echo "[1/3] Cleanup (services, variants)"
"$UST" "@${ENV_FILE}" ollama service-cleanup || true
"$UST" "@${ENV_FILE}" ollama cleanup-variants || true

echo "[2/3] Benchmark (ollama with Gemma debug profile)"
"$UST" "@${ENV_FILE}" ollama benchmark

echo "[3/3] Export GGUFs from Ollama"
"$UST" "@${ENV_FILE}" ollama export-gguf

echo "Done. See logs under /var/log/fuze-stack."

