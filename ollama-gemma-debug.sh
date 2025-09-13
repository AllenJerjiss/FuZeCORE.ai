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

echo "[0/4] Install/Upgrade Ollama (stock service)"
"$UST" "@${ENV_FILE}" ollama install || true

echo "[1/4] Cleanup (services, variants)"
"$UST" "@${ENV_FILE}" ollama service-cleanup || true
"$UST" "@${ENV_FILE}" ollama cleanup-variants || true

echo "[2/4] Benchmark (ollama with Gemma debug profile)"
"$UST" "@${ENV_FILE}" ollama benchmark

echo "[3/4] Export GGUFs from Ollama"
"$UST" "@${ENV_FILE}" ollama export-gguf || true

echo "[4/4] Analyze latest results (ollama)"
"$UST" "@${ENV_FILE}" analyze --stack ollama || true

echo "Done. See logs under /var/log/fuze-stack."
