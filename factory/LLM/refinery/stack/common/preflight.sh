#!/usr/bin/env bash
# preflight.sh — Verify environment readiness for all stacks (Ollama, vLLM, llama.cpp, Triton)
# - Checks GPU/driver/CUDA, key binaries, services, ports, and model directories
# - Prints concise status with suggestions when something is missing

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "$SCRIPT_DIR/common.sh"

# Initialize with common functions
init_common "preflight"

HAVE_WARN=0; HAVE_ERR=0
mark_warn(){ HAVE_WARN=1; }
mark_err(){ HAVE_ERR=1; }

section_sys(){
  info "System Status"
  if command -v lsb_release >/dev/null 2>&1; then
    ok "OS       : $(lsb_release -sd 2>/dev/null || true)"
  elif [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release; ok "OS       : ${PRETTY_NAME:-unknown}"
  else
    warn "OS       : unknown (no lsb_release/os-release)"; mark_warn
  fi
  ok "Kernel   : $(uname -r)"
}

section_gpu(){
  info "GPU / CUDA"
  if have_cmd nvidia-smi && nvidia-smi >/dev/null 2>&1; then
    nvidia-smi | sed -n '1,10p'
    ok "Driver OK (nvidia-smi)"
  else
    if have_cmd lspci && lspci | grep -qi 'nvidia'; then
      warn "NVIDIA device present but nvidia-smi not working — run: ./ust.sh gpu-prepare"; mark_warn
    else
      ok "No NVIDIA GPU detected — CPU-only stacks will work; GPU stacks will fall back"
    fi
  fi
  if have_cmd nvcc; then
    ok "CUDA nvcc: $(nvcc --version | sed -n '1,2p' | paste -sd' ' -)"
  else
    if have_cmd nvidia-smi; then
      warn "nvcc missing (CUDA toolkit not installed). llama.cpp CUDA build will be skipped. Use: ./ust.sh gpu-prepare"; mark_warn
    fi
  fi
}

section_bins(){
  info "Binaries"
  if have_cmd ollama; then ok "ollama     : $(ollama --version 2>/dev/null || echo present)"; else warn "ollama     : missing (install via: ./ust.sh ollama install)"; mark_warn; fi
  if have_cmd vllmapi; then ok "vllmapi    : present (/usr/local/bin/vllmapi)"; else warn "vllmapi    : missing (install via: ./ust.sh vLLM install)"; mark_warn; fi
  if have_cmd llama-server || have_cmd server; then ok "llama.cpp  : $( (llama-server --version 2>/dev/null || server --version 2>/dev/null || echo present) | head -n1)"; else warn "llama.cpp  : missing (install via: ./ust.sh llama.cpp install)"; mark_warn; fi
  if have_cmd perf_analyzer; then ok "perf_analyzer: present"; else warn "perf_analyzer: missing (install NVIDIA Triton SDK tools if needed)"; mark_warn; fi
}

port_listen(){ local p="$1"; ss -ntl 2>/dev/null | awk -v p=":$p" '$4 ~ p'; }

section_services(){
  info "Services / Ports"
  # Ollama persistent
  local st
  if have_cmd systemctl; then
    st=$(systemctl is-active ollama.service 2>/dev/null || true)
    [ "$st" = active ] && ok "ollama.service active" || warn "ollama.service: $st (optional)"
  fi
  if curl -fsS --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
    ok ":11434 reachable (Ollama)"
  else
    warn ":11434 not reachable — use dedicated cleanup scripts if needed"; mark_warn
  fi
  for p in 11435 11436; do
    if port_listen "$p" >/dev/null; then ok ":$p listening"; else warn ":$p not in use (created on demand by benchmarks)"; fi
  done
}

section_models(){
  info "Model Stores"
  local om=/FuZe/models/ollama gg=/FuZe/models/gguf
  if [ -d "$om" ]; then
    local o; o=$(stat -c '%U:%G %a' "$om" 2>/dev/null || true)
    ok "Ollama store : $om ($o)"
  else
    warn "Ollama store : missing ($om). Will be created on demand."; fi
  if [ -d "$gg" ]; then
    ok "GGUF store   : $gg"
  else
    warn "GGUF store   : missing ($gg). Create it or run export-gguf when ready."; fi
}

main(){
  section_sys
  echo
  section_gpu
  echo
  section_bins
  echo
  section_services
  echo
  section_models
  echo
  if [ "$HAVE_ERR" -eq 0 ] && [ "$HAVE_WARN" -eq 0 ]; then
    ok "Preflight OK — all key prerequisites look good."
  else
    if [ "$HAVE_ERR" -eq 0 ]; then
      warn "Preflight completed with warnings (see above)."
    else
      err "Preflight found errors. Please address above items."
    fi
  fi
}

main "$@"

