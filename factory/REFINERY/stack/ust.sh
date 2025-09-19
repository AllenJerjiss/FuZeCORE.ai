#!/usr/bin/env bash
# Unified Stack Tool (driver)
# Thin wrapper to select and run per-stack benchmark scripts.
# Usage: ./ust.sh [@envfile.env] <stack> [command] [args...]
# Stacks: ollama | vLLM | llama.cpp | Triton

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="${SCRIPT_DIR}"

# Source common functions for consistent behavior
source "${SCRIPT_DIR}/common/common.sh"
init_common "ust"

usage(){
  cat <<USAGE
Usage: $0 [@envfile.env] <stack> [command] [args...]

STACKS:
  ollama     Ollama LLM server stack
  vLLM       vLLM inference engine  
  llama.cpp  llama.cpp C++ implementation
  Triton     NVIDIA Triton inference server

GLOBAL COMMANDS (work across all stacks):
  gpu-setup          Setup NVIDIA GPU drivers and CUDA
  preflight          System health checks and validation
  clean-bench        Clean benchmark artifacts safely
  migrate-logs       Consolidate logs to system location
  analyze            Interactive benchmark analysis
  collect-results    Aggregate results from all stacks
  summarize-benchmarks Generate comprehensive reports

STACK-SPECIFIC COMMANDS:
  ollama   : benchmark (default) | install | service-cleanup | store-cleanup | cleanup-variants | export-gguf
  vLLM     : benchmark (default) | install
  llama.cpp: benchmark (default) | import-gguf | install  
  Triton   : benchmark (default) | install

EXAMPLES:
  $0 preflight                    # System health check
  $0 ollama benchmark            # Run Ollama benchmarks
  $0 clean-bench --dry-run       # Preview cleanup actions
  $0 analyze                     # Interactive result analysis
  $0 @custom.env vLLM benchmark  # Use custom environment
USAGE
}

# Optional env file(s) loader: any leading args of form @file or *.env
while [ $# -gt 0 ]; do
  case "$1" in
    @*|*.env)
      envf="${1#@}"
      if [ -f "$envf" ]; then
        info "Loading environment: $envf"
        set -a; . "$envf"; set +a
        shift; continue
      else
        error_exit "Environment file not found: $envf"
      fi
      ;;
    --gpu)
      if [ -n "${2:-}" ]; then
        export GPU_DEVICES="$2"
        info "Set GPU_DEVICES=$GPU_DEVICES"
        shift 2; continue
      else
        error_exit "--gpu flag requires a value (e.g. --gpu 0,1)"
      fi
      ;;
    --combined)
      if [ -n "${2:-}" ]; then
        export COMBINED_DEVICES="$2"
        info "Set COMBINED_DEVICES=$COMBINED_DEVICES"
        shift 2; continue
      else
        error_exit "--combined flag requires a value (e.g. --combined 0,1,2)"
      fi
      ;;
    *) break ;;
  esac
done

stack="${1:-}" || true
if [ -z "$stack" ] || [ "$stack" = "-h" ] || [ "$stack" = "--help" ]; then 
  usage
  exit 0
fi
shift $(( $#>0 ? 1 : 0 )) || true

# Top-level utilities (not tied to a specific stack)
case "$stack" in
  gpu|gpu-prepare|gpu-setup)
    exec "${STACK_ROOT}/common/gpu-setup.sh" "$@" ;;
  preflight|check|doctor)
    exec "${STACK_ROOT}/common/preflight.sh" "$@" ;;
  logs|log-migrate|migrate-logs)
    exec "${STACK_ROOT}/common/migrate-logs.sh" "$@" ;;
  clean|cleanup|clean-bench)
    exec "${STACK_ROOT}/common/clean-bench.sh" "$@" ;;
  analyze|analysis)
    exec "${STACK_ROOT}/common/analyze.sh" "$@" ;;
  collect|collect-results)
    exec "${STACK_ROOT}/common/collect-results.sh" "$@" ;;
  summarize|summarize-benchmarks|summary|report)
    exec "${STACK_ROOT}/common/summarize-benchmarks.sh" "$@" ;;
  install-common|install-stack)
    exec "${STACK_ROOT}/common/install.sh" "$@" ;;
esac

# For normal stacks, the next token is the command (default: benchmark)
cmd="${1:-benchmark}" || true
shift $(( $#>0 ? 1 : 0 )) || true

# Smart root escalation: only for commands that actually need it
needs_root() {
  case "$stack" in
    ollama)
      case "$cmd" in
        service-cleanup|store-cleanup|cleanup-variants|install) return 0 ;;
        *) return 1 ;;
      esac ;;
    vLLM|llama.cpp|Triton)
      case "$cmd" in
        install) return 0 ;;
        *) return 1 ;;
      esac ;;
    *) return 1 ;;
  esac
}

# Auto-escalate to root only when necessary
if needs_root && [ "$(id -u)" -ne 0 ]; then
  info "Command requires root privileges, escalating..."
  exec sudo -E "$0" "$stack" "$cmd" "$@"
fi

case "$stack" in
  ollama|Ollama)
    case "$cmd" in
      bench|benchmark)           
        # Generate GPU labels: 3090ti, 5090, etc. based on model names
        if command -v nvidia-smi >/dev/null 2>&1; then
          export GPU_LABELS="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | awk 'BEGIN{ORS=""} {
            if(NR>1) print ","; 
            # Normalize GPU names: "NVIDIA GeForce RTX 3090 Ti" -> "3090ti"
            s = tolower($0);
            gsub(/nvidia|geforce|rtx|[[:space:]]/, "", s); 
            print s
          }')"
        fi
        # Handle combined mode with dynamic environment generation
        if [[ -n "${COMBINED:-}" ]]; then
          generate_dynamic_env "$MODEL" "$COMBINED"
        fi
        exec "${STACK_ROOT}/ollama/ollama-benchmark.sh" "$@" ;;
      install)                   exec "${STACK_ROOT}/common/install.sh" --try-cache ollama "$@" ;;
      service-cleanup|svc-clean) exec "${STACK_ROOT}/ollama/service-cleanup.sh" "$@" ;;
      store-cleanup|store)       exec "${STACK_ROOT}/ollama/store-cleanup.sh" "$@" ;;
      export-gguf|export)        exec "${STACK_ROOT}/ollama/export-gguf.sh" "$@" ;;
      cleanup-variants|variants) exec "${STACK_ROOT}/ollama/cleanup-variants.sh" "$@" ;;
      *) error_exit "Unknown ollama command: $cmd" ;;
    esac ;;
  vllm|vLLM|VLLM)
    case "$cmd" in
      bench|benchmark) exec "${STACK_ROOT}/vLLM/benchmark.sh" "$@" ;;
      install)         exec "${STACK_ROOT}/vLLM/install.sh" "$@" ;;
      *) error_exit "Unknown vLLM command: $cmd" ;;
    esac ;;
  llama.cpp|llamacpp|llama-cpp)
    case "$cmd" in
      bench|benchmark) exec "${STACK_ROOT}/llama.cpp/benchmark.sh" "$@" ;;
      import-gguf|import-from-ollama|import) exec "${STACK_ROOT}/llama.cpp/import-gguf-from-ollama.sh" "$@" ;;
      install)         exec "${STACK_ROOT}/llama.cpp/install.sh" "$@" ;;
      *) error_exit "Unknown llama.cpp command: $cmd" ;;
    esac ;;
  triton|Triton)
    case "$cmd" in
      bench|benchmark) exec "${STACK_ROOT}/Triton/benchmark.sh" "$@" ;;
      install)         exec "${STACK_ROOT}/Triton/install.sh" "$@" ;;
      *) error_exit "Unknown Triton command: $cmd" ;;
    esac ;;
  *)
    error_exit "Unknown stack: $stack" ;;
esac
