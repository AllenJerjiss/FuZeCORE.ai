#!/usr/bin/env bash
# Unified Stack Tool (driver)
# Thin wrapper to select and run per-stack benchmark scripts.
# Usage: ./ust.sh [@envfile.env] <stack> [command] [args...]
# Stacks: ollama | vLLM | llama.cpp | Triton

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="${SCRIPT_DIR}"

usage(){
  echo "Usage: $0 [@envfile.env] <stack> [command] [args...]"
  echo "Stacks: ollama | vLLM | llama.cpp | Triton"
  echo "Commands per stack:"
  echo "  ollama   : benchmark (default) | install | service-cleanup | store-cleanup | cleanup-variants"
  echo "  vLLM     : benchmark (default) | install"
  echo "  llama.cpp: benchmark (default) | import-gguf | install"
  echo "  Triton   : benchmark (default) | install"
}

# Optional env file(s) loader: any leading args of form @file or *.env
while [ $# -gt 0 ]; do
  case "$1" in
    @*|*.env)
      envf="${1#@}"
      if [ -f "$envf" ]; then
        set -a; . "$envf"; set +a
        shift; continue
      else
        echo "Env file not found: $envf" >&2; exit 2
      fi
      ;;
    *) break ;;
  esac
done

stack="${1:-}" || true
if [ -z "$stack" ]; then usage; exit 1; fi
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
  analyze|analysis|summary)
    exec "${STACK_ROOT}/common/analyze.sh" "$@" ;;
esac

# For normal stacks, the next token is the command (default: benchmark)
cmd="${1:-benchmark}" || true
shift $(( $#>0 ? 1 : 0 )) || true

# Enforce root for consistent service and log handling (auto-escalate, preserve env)
if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E "$0" "$stack" "$cmd" "$@"
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
      import-gguf|import-from-ollama|import) exec "${STACK_ROOT}/llama.cpp/import-gguf-from-ollama.sh" "$@" ;;
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
    exit 2 ;;
esac
