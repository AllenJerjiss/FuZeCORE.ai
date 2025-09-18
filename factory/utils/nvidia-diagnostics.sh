#!/usr/bin/env bash
# NVIDIA diagnostics collector
# Usage: sudo ./nvidia-diagnostics.sh
# The script collects system info useful for diagnosing NVIDIA GPU detection and writes to a timestamped file under /tmp or current directory.

set -euo pipefail
IFS=$'\n\t'

OUT_DIR="$(pwd)"
TS=$(date -u +"%Y%m%dT%H%M%SZ")
OUT_FILE="$OUT_DIR/nvidia-diagnostics-$TS.txt"

echo "Collecting NVIDIA diagnostics to $OUT_FILE"
{
  echo "===== TIMESTAMP ====="
  date -u
  echo

  echo "===== UNAME ====="
  uname -a
  echo

  echo "===== /etc/os-release (if exists) ====="
  if [ -r /etc/os-release ]; then
    cat /etc/os-release
  else
    echo "/etc/os-release not readable"
  fi
  echo

  echo "===== lspci -nnk (NVIDIA lines) ====="
  lspci -nnk | grep -i nvidia -A6 || true
  echo

  echo "===== full lspci for VGA/3D/Display ====="
  lspci -vnn | egrep -i 'VGA|3D|Display' || true
  echo

  echo "===== which nvidia-smi and nvidia-smi output ====="
  which nvidia-smi || true
  nvidia-smi --query-gpu=index,name,driver_version,memory.total --format=csv,noheader || nvidia-smi || true
  echo

  echo "===== lsmod (nvidia/nouveau) ====="
  lsmod | egrep 'nvidia|nouveau' || true
  echo

  echo "===== dmesg (recent NVIDIA/nvrm/nouveau messages) ====="
  dmesg | egrep -i 'nvidia|nvrm|nouveau' || true
  echo

  echo "===== journalctl (this boot) for nvidia/nouveau ====="
  if command -v journalctl >/dev/null 2>&1; then
    journalctl -b --no-pager | egrep -i 'nvidia|nouveau|nvrm' || true
  else
    echo "journalctl not available"
  fi
  echo

  echo "===== Package manager NVIDIA packages (dpkg/rpm) ====="
  if command -v dpkg >/dev/null 2>&1; then
    dpkg -l | egrep 'nvidia|nvidia-driver|nvidia-kernel' || true
  elif command -v rpm >/dev/null 2>&1; then
    rpm -qa | egrep -i 'nvidia' || true
  else
    echo "No dpkg or rpm detected"
  fi
  echo

  echo "===== mokutil Secure Boot state (if available) ====="
  if command -v mokutil >/dev/null 2>&1; then
    sudo -n mokutil --sb-state || mokutil --sb-state || true
  else
    echo "mokutil not installed"
  fi
  echo

  echo "===== dkms status (if available) ====="
  if command -v dkms >/dev/null 2>&1; then
    sudo -n dkms status || dkms status || true
  else
    echo "dkms not installed"
  fi
  echo

  echo "===== end ====="
} > "$OUT_FILE" 2>&1

chmod a+r "$OUT_FILE"

echo "Diagnostics written to: $OUT_FILE"

echo "You can paste the file contents or upload it for analysis."