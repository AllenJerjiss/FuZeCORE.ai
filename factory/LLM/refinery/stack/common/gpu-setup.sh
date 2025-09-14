#!/usr/bin/env bash
# gpu-setup.sh — Ensure NVIDIA GPU driver and CUDA toolkit (nvcc) are installed
# - Detects NVIDIA GPU presence
# - Installs/upgrades recommended NVIDIA driver (Ubuntu/Debian) if missing
# - Installs CUDA toolkit (nvcc) if missing
# - No-ops on systems without NVIDIA GPU

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root (sudo)." >&2
  exit 1
fi

have_cmd(){ command -v "$1" >/dev/null 2>&1; }

detect_nvidia_gpu(){
  if have_cmd nvidia-smi; then
    nvidia-smi >/dev/null 2>&1 && return 0 || true
  fi
  # Fallback: lspci check
  if have_cmd lspci && lspci | grep -qi 'vga.*nvidia\|3d.*nvidia'; then
    return 0
  fi
  return 1
}

ensure_packages(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y "$@"
}

echo "== GPU setup: probing for NVIDIA GPU =="
if ! detect_nvidia_gpu; then
  echo "No NVIDIA GPU detected — skipping driver/CUDA setup."
  exit 0
fi

echo "NVIDIA GPU detected. Ensuring driver and CUDA toolkit..."

# Ensure driver tools are present
if ! have_cmd nvidia-smi; then
  echo "Installing NVIDIA driver tools..."
  ensure_packages ubuntu-drivers-common
  ubuntu-drivers autoinstall || true
fi

# Ensure CUDA toolkit (nvcc)
if ! have_cmd nvcc; then
  echo "Installing CUDA toolkit (may take a while)..."
  # Prefer distro toolkit if available
  if apt-cache policy nvidia-cuda-toolkit 2>/dev/null | grep -q Candidate; then
    ensure_packages nvidia-cuda-toolkit
  else
    # Try CUDA 12.x meta if available in repos
    if apt-cache policy cuda-toolkit-12-5 2>/dev/null | grep -q Candidate; then
      ensure_packages cuda-toolkit-12-5
    elif apt-cache policy cuda-toolkit-12-4 2>/dev/null | grep -q Candidate; then
      ensure_packages cuda-toolkit-12-4
    else
      echo "WARN: No CUDA toolkit package found in APT repos. Please install NVIDIA CUDA Toolkit manually." >&2
    fi
  fi
fi

echo
echo "== GPU setup summary =="
have_cmd nvidia-smi && nvidia-smi | sed -n '1,10p' || echo "nvidia-smi not available"
if have_cmd nvcc; then
  echo "nvcc: $(nvcc --version | sed -n '1,3p')"
else
  echo "nvcc not found — CUDA toolkit may not be installed."
fi

echo "Note: Some driver changes may require a reboot."

