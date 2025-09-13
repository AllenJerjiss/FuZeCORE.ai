#!/usr/bin/env bash
# install_llamacpp_tooling.sh
# - Builds llama.cpp server (CUDA if available; else CPU)
# - Installs binaries to /usr/local/bin
# - Leaves GGUF models to you (put them in /FuZe/models/gguf)

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root (sudo)." >&2
  exit 1
fi

apt-get update -y
apt-get install -y git build-essential cmake ninja-build jq curl lsb-release pciutils

LLAMA_DIR="/opt/llama.cpp"
if [ ! -d "$LLAMA_DIR/.git" ]; then
  echo "== Cloning llama.cpp =="
  rm -rf "$LLAMA_DIR"
  git clone --depth=1 https://github.com/ggerganov/llama.cpp "$LLAMA_DIR"
else
  echo "== Updating llama.cpp =="
  git -C "$LLAMA_DIR" fetch --depth=1 origin
  git -C "$LLAMA_DIR" reset --hard origin/HEAD
fi

mkdir -p /FuZe/models/gguf

# Try to ensure GPU toolchain if NVIDIA GPU is present
if command -v nvidia-smi >/dev/null 2>&1 || lspci | grep -qi 'nvidia'; then
  echo "== NVIDIA GPU detected: ensuring driver + CUDA toolkit =="
  "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common/gpu-setup.sh" || true
fi

# Configure and build
echo "== Configuring build =="
if command -v nvcc >/dev/null 2>&1; then
  echo "   -> CUDA detected (nvcc). Building with CUDA/cuBLAS."
  cmake -S "$LLAMA_DIR" -B "$LLAMA_DIR/build" -G Ninja \
        -DGGML_CUDA=1 -DCMAKE_BUILD_TYPE=Release
else
  echo "   -> No nvcc present. Building CPU-only."
  cmake -S "$LLAMA_DIR" -B "$LLAMA_DIR/build" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release
fi
cmake --build "$LLAMA_DIR/build" -j

# Install server & cli
install -m 0755 "$LLAMA_DIR/build/bin/server"     /usr/local/bin/llama-server
[ -f "$LLAMA_DIR/build/bin/llama-cli" ] && install -m 0755 "$LLAMA_DIR/build/bin/llama-cli" /usr/local/bin/llama-cli || true

echo
echo "✔ llama.cpp installed."
echo "   Binaries:  /usr/local/bin/llama-server  (/usr/local/bin/llama-cli)"
echo "   GGUF dir:  /FuZe/models/gguf"
