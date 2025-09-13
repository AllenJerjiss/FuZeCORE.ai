#!/usr/bin/env bash
# Unified Stack Tool (driver)
# Thin wrapper to select and run per-stack benchmark scripts.
# Usage: ./ust.sh <stack>
# Stacks: ollama | vLLM | llama.cpp | Triton

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="${SCRIPT_DIR}"

usage(){
  echo "Usage: $0 <stack> [command] [args...]"
  echo "Stacks: ollama | vLLM | llama.cpp | Triton"
  echo "Commands per stack:"
  echo "  ollama   : benchmark (default) | install | service-cleanup | store-cleanup | cleanup-variants"
  echo "  vLLM     : benchmark (default) | install"
  echo "  llama.cpp: benchmark (default) | install"
  echo "  Triton   : benchmark (default) | install"
}

stack="${1:-}" || true
cmd="${2:-benchmark}" || true
shift $(( $#>0 ? 1 : 0 )) || true
shift $(( $#>0 ? 1 : 0 )) || true

if [ -z "$stack" ]; then usage; exit 1; fi

# Top-level GPU preparation (not tied to a specific stack)
case "$stack" in
  gpu|gpu-prepare|gpu-setup)
    exec "${STACK_ROOT}/common/gpu-setup.sh" "$@"
    ;;
  preflight|check|doctor)
    exec "${STACK_ROOT}/common/preflight.sh" "$@"
    ;;
  logs|log-migrate|migrate-logs)
    exec "${STACK_ROOT}/common/migrate-logs.sh" "$@"
    ;;
esac

# Enforce a single way to run stack commands: as root (sudo -E)
if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root: sudo -E $0 $stack ${cmd:-}" >&2
  exit 1
fi

case "$stack" in
  ollama|Ollama)
    case "$cmd" in
      bench|benchmark)           exec "${STACK_ROOT}/ollama/benchmark.sh" "$@" ;;
      install)                   exec "${STACK_ROOT}/ollama/install.sh" "$@" ;;
      service-cleanup|svc-clean) exec "${STACK_ROOT}/ollama/service-cleanup.sh" "$@" ;;
      store-cleanup|store)       exec "${STACK_ROOT}/ollama/store-cleanup.sh" "$@" ;;
      export-gguf|export)        exec "${STACK_ROOT}/ollama/export-gguf.sh" "$@" ;;
      cleanup-variants|variants) exec "${STACK_ROOT}/ollama/cleanup-variants.sh" "$@" ;;
      *) echo "Unknown ollama command: $cmd" >&2; usage; exit 2;;
    esac ;;
  vllm|vLLM|VLLM)
    case "$cmd" in
      bench|benchmark) exec "${STACK_ROOT}/vLLM/benchmark.sh" "$@" ;;
      install)         exec "${STACK_ROOT}/vLLM/install.sh" "$@" ;;
      *) echo "Unknown vLLM command: $cmd" >&2; usage; exit 2;;
    esac ;;
  llama.cpp|llamacpp|llama-cpp)
    case "$cmd" in
      bench|benchmark) exec "${STACK_ROOT}/llama.cpp/benchmark.sh" "$@" ;;
      install)         exec "${STACK_ROOT}/llama.cpp/install.sh" "$@" ;;
      *) echo "Unknown llama.cpp command: $cmd" >&2; usage; exit 2;;
    esac ;;
  triton|Triton)
    case "$cmd" in
      bench|benchmark) exec "${STACK_ROOT}/Triton/benchmark.sh" "$@" ;;
      install)         exec "${STACK_ROOT}/Triton/install.sh" "$@" ;;
      *) echo "Unknown Triton command: $cmd" >&2; usage; exit 2;;
    esac ;;
  *)
    echo "Unknown stack: $stack" >&2
    usage
    exit 2
    ;;
esac
