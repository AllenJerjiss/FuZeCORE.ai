#!/usr/bin/env bash
# gpu-setup.sh — Ensure NVIDIA GPU driver and CUDA toolkit (nvcc) are installed
# - Detects NVIDIA GPU presence
# - Installs/upgrades recommended NVIDIA driver (Ubuntu/Debian) if missing
# - Installs CUDA toolkit (nvcc) if missing
# - No-ops on systems without NVIDIA GPU

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Parse command line arguments
DRY_RUN=0
FORCE=0
SKIP_DRIVER=0
SKIP_CUDA=0

usage() {
    cat <<USAGE
Usage: $(basename "$0") [--dry-run] [--force] [--skip-driver] [--skip-cuda] [--help]

Options:
  --dry-run      Show what would be done without making changes
  --force        Install even if tools are already present
  --skip-driver  Skip NVIDIA driver installation
  --skip-cuda    Skip CUDA toolkit installation
  --help         Show this help message

This script requires root privileges for system package installation.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --force) FORCE=1; shift ;;
        --skip-driver) SKIP_DRIVER=1; shift ;;
        --skip-cuda) SKIP_CUDA=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) error_exit "Unknown argument: $1" ;;
    esac
done

show_dry_run_status

# Check if NVIDIA GPU is present
if ! has_nvidia_gpu; then
    info "No NVIDIA GPU detected. Skipping GPU setup."
    exit 0
fi

info "NVIDIA GPU detected."

# Define root operations for validation
ROOT_OPERATIONS=(
    "Update package repositories (apt-get update)"
    "Install NVIDIA driver tools (ubuntu-drivers-common)"
    "Auto-install NVIDIA drivers (ubuntu-drivers autoinstall)"
    "Install CUDA toolkit packages"
)

# Require root with operation preview
if [ "$DRY_RUN" -eq 0 ]; then
    require_root "${ROOT_OPERATIONS[@]}"
fi

# Check required system tools
require_cmds apt-get apt-cache

detect_nvidia_gpu() {
    has_nvidia_gpu
}

ensure_packages() {
    local packages=("$@")
    info "Installing packages: ${packages[*]}"
    if [ "$DRY_RUN" -eq 1 ]; then
        info "DRY RUN: Would update package cache and install: ${packages[*]}"
        return 0
    fi
    
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y || error_exit "Failed to update package cache"
    apt-get install -y "${packages[@]}" || error_exit "Failed to install packages: ${packages[*]}"
}

# Main installation logic
main() {
    info "Starting GPU setup..."
    
    # Driver installation
    if [ "$SKIP_DRIVER" -eq 0 ]; then
        if ! have_cmd nvidia-smi || [ "$FORCE" -eq 1 ]; then
            info "Installing NVIDIA driver tools..."
            if [ "$DRY_RUN" -eq 1 ]; then
                info "DRY RUN: Would install ubuntu-drivers-common and run autoinstall"
            else
                ensure_packages ubuntu-drivers-common
                info "Running automatic driver installation..."
                ubuntu-drivers autoinstall || error_exit "NVIDIA driver installation failed"
            fi
        else
            info "NVIDIA drivers already installed (nvidia-smi available)"
        fi
    else
        info "Skipping driver installation (--skip-driver)"
    fi

    # CUDA toolkit installation  
    if [ "$SKIP_CUDA" -eq 0 ]; then
        if ! have_cmd nvcc || [ "$FORCE" -eq 1 ]; then
            info "Installing CUDA toolkit..."
            if [ "$DRY_RUN" -eq 1 ]; then
                info "DRY RUN: Would attempt to install CUDA toolkit (nvidia-cuda-toolkit or cuda-toolkit-12-x)"
            else
                install_cuda_toolkit
            fi
        else
            info "CUDA toolkit already installed (nvcc available)"
        fi
    else
        info "Skipping CUDA installation (--skip-cuda)"
    fi

    show_setup_summary
}

install_cuda_toolkit() {
    info "Installing CUDA toolkit (may take a while)..."
    
    # Try different CUDA packages in order of preference
    local cuda_packages=(
        "nvidia-cuda-toolkit"
        "cuda-toolkit-12-5" 
        "cuda-toolkit-12-4"
        "cuda-toolkit-12-3"
    )
    
    local installed=false
    for pkg in "${cuda_packages[@]}"; do
        if apt-cache policy "$pkg" 2>/dev/null | grep -q Candidate; then
            info "Installing $pkg..."
            ensure_packages "$pkg"
            installed=true
            break
        else
            debug "Package $pkg not available in repositories"
        fi
    done
    
    if [ "$installed" = false ]; then
        warn "No CUDA toolkit package found in APT repositories."
        warn "Please install NVIDIA CUDA Toolkit manually:"
        warn "  https://developer.nvidia.com/cuda-downloads"
    fi
}

show_setup_summary() {
    info ""
    info "== GPU setup summary =="
    
    if have_cmd nvidia-smi; then
        info "NVIDIA driver: OK"
        if [ "$DRY_RUN" -eq 0 ]; then
            nvidia-smi | sed -n '1,10p' || warn "nvidia-smi failed to run"
        fi
    else
        warn "NVIDIA driver: NOT AVAILABLE"
    fi
    
    if have_cmd nvcc; then
        local nvcc_version
        nvcc_version="$(nvcc --version 2>/dev/null | grep 'release' | head -n1 || echo 'unknown')"
        info "CUDA toolkit: OK ($nvcc_version)"
    else
        warn "CUDA toolkit: NOT AVAILABLE"
    fi
    
    info "Setup complete!"
}

# Run main function if script is executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi

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

