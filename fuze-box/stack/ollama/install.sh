#!/usr/bin/env bash
# install_ollama_tooling.sh
# - Installs Ollama if missing
# - Ensures model store at /FuZe/models/ollama
# - Installs common CLI deps used by your benchmark scripts

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root (sudo)." >&2
  exit 1
fi

apt-get update -y
apt-get install -y curl jq lsof gawk sed procps coreutils

# Install Ollama if missing
if ! command -v ollama >/dev/null 2>&1; then
  echo "== Installing Ollama =="
  curl -fsSL https://ollama.com/install.sh | sh
else
  echo "== Ollama already installed: $(ollama --version || true)"
fi

# Ensure shared model store
mkdir -p /FuZe/models/ollama
chmod 755 /FuZe /FuZe/models /FuZe/models/ollama || true

# Handy symlink for human navigation (optional)
if [ ! -e /FuZe/ollama ]; then
  ln -s /FuZe/models/ollama /FuZe/ollama || true
fi

echo
echo "✔ Ollama tooling ready."
echo "   Models dir: /FuZe/models/ollama"
echo "   Version   : $(ollama --version || echo 'unknown')"

