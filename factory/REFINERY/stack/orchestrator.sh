#!/usr/bin/env bash
#
# Unified Stack Tool (driver)
# Usage: ./orchestrator.sh [@envfile.env] [global_opts] <stack> [command] [args...]
# Stacks: ollama | vLLM | llama.cpp | Triton

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="${SCRIPT_DIR}"

source "${SCRIPT_DIR}/common/common.sh"
init_common "orchestrator"

# --- Argument Parsing ---
declare -a stack_args
while [ $# -gt 0 ]; do
  case "$1" in
    @*|*.env)
      envf="${1#@}"
      if [ -f "$envf" ]; then
        info "Loading environment: $envf"
        set -a; . "$envf"; set +a
      else
        error_exit "Environment file not found: $envf"
      fi
      shift
      ;;
    --gpu)
      export GPU_DEVICES="${2:?--gpu requires an argument}"
      info "Set GPU_DEVICES=$GPU_DEVICES"
      shift 2
      ;;
    --combined)
      export COMBINED_DEVICES="${2:?--combined requires an argument}"
      info "Set COMBINED_DEVICES=$COMBINED_DEVICES"
      shift 2
      ;;
    --model)
      export MODEL_PATTERN="${2:?--model requires an argument}"
      info "Set MODEL_PATTERN=$MODEL_PATTERN"
      shift 2
      ;;
    -*)
      error_exit "Unknown global option: $1"
      ;;
    *)
      stack_args+=("$1")
      shift
      ;;
  esac
done

# Now, process stack arguments
set -- "${stack_args[@]}"

# --- Command Dispatch Logic ---

# The first argument is either a global command or a stack name.
# Handle help case first.
if [ -z "${1:-}" ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  usage
  exit 0
fi

# STAGE 1: Check for and dispatch GLOBAL commands.
# These commands are not tied to a specific stack.
case "$1" in
  gpu-setup|preflight|clean-bench|analyze|install|collect-results|summarize-benchmarks|migrate-logs)
    # It's a global command. The first argument is the command itself.
    global_cmd="$1"
    shift # Remove the global command from the list of args
    
    # Now execute the correct script based on the command.
    case "$global_cmd" in
      gpu-setup)    "${STACK_ROOT}/common/gpu-setup.sh" "$@" ;;
      preflight)    "${STACK_ROOT}/common/preflight.sh" "$@" ;;
      clean-bench)  "${STACK_ROOT}/common/clean-bench.sh" "$@" ;;
      analyze)      "${STACK_ROOT}/common/analyze.sh" "$@" ;;
      install)
        # Handle the recursive test call from install.sh itself
        if [ "${1:-}" = "--test" ]; then
          # Source install.sh to get the run_tests function, then run it
          source "${STACK_ROOT}/common/install.sh"
          run_tests
        else
          # Otherwise, run a normal installation
          "${STACK_ROOT}/common/install.sh" "$@"
        fi
        ;;
      collect-results) "${STACK_ROOT}/common/collect-results.sh" "$@" ;;
      summarize-benchmarks) "${STACK_ROOT}/common/summarize-benchmarks.sh" "$@" ;;
      migrate-logs) "${STACK_ROOT}/common/migrate-logs.sh" "$@" ;;
    esac
    # Exit after running a global command.
    exit $?
    ;;
esac

# STAGE 2: If it wasn't a global command, it must be a STACK.
stack="${1:-}"
shift || true

cmd="${1:-benchmark}"
# Don't shift cmd, the stack script will handle its own args.

# Always set up model filtering from args before stack dispatch
setup_model_filter_from_args "$@"

usage(){
  cat <<USAGE
Usage: $0 [@envfile.env] [global_opts] <stack> [command] [args...]

GLOBAL OPTIONS:
  --gpu <indices>      Specify GPU device indices (e.g., "0,1")
  --combined <indices> Specify indices for a multi-GPU instance
  --model <pattern>    Filter models to benchmark (e.g., "gpt-oss-20b")
  @<file>             Load environment variables from a file

STACKS:
  ollama     Ollama LLM server stack
  vLLM       vLLM inference engine
  llama.cpp  llama.cpp C++ implementation
  Triton     NVIDIA Triton inference server

GLOBAL COMMANDS (work across all stacks):
  gpu-setup          Setup NVIDIA GPU drivers and CUDA
  preflight          System health checks and validation
  clean-bench        Clean benchmark artifacts safely
  analyze            Interactive benchmark analysis

STACK-SPECIFIC COMMANDS:
  ollama   : benchmark (default) | install | service-cleanup | store-cleanup | cleanup-variants
  vLLM     : benchmark (default) | install
  llama.cpp: benchmark (default) | import-gguf | install
  Triton   : benchmark (default) | install

EXAMPLES:
  $0 --gpu 0 preflight                    # System health check on GPU 0
  $0 --model gpt-oss-20b ollama benchmark # Run Ollama benchmarks on a specific model
  $0 clean-bench --dry-run                # Preview cleanup actions
USAGE
}
# ... (rest of the script is the same until the case statement for ollama)
# ...
# ...
case "$stack" in
  ollama|Ollama)
    case "$cmd" in
      bench|benchmark)
        # Ensure monitor stops on exit
        trap '"${STACK_ROOT}/common/gpu_monitor.sh" stop' EXIT
        "${STACK_ROOT}/common/gpu_monitor.sh" start

        if command -v nvidia-smi >/dev/null 2>&1; then
          export GPU_LABELS="$(nvidia-smi --query-gpu=name,serial --format=csv,noheader 2>/dev/null | awk -F', ' 'BEGIN{ORS=""} {
            if(NR>1) print ",";
            s = tolower($1);
            gsub(/nvidia|geforce|rtx|[[:space:]]|-/, "", s);
            serial_suffix = substr($2, length($2)-1);
            print (NR-1) ":" s serial_suffix
          }')"
        fi
        "${STACK_ROOT}/ollama/ollama-benchmark.sh" "$@" ;;
      install)                   "${STACK_ROOT}/common/install.sh" --try-cache ollama "$@" ;;
      service-cleanup|svc-clean) "${STACK_ROOT}/ollama/service-cleanup.sh" "$@" ;;
      store-cleanup|store)       "${STACK_ROOT}/ollama/store-cleanup.sh" "$@" ;;
      export-gguf|export)        "${STACK_ROOT}/ollama/export-gguf.sh" "$@" ;;
      cleanup-variants|variants) "${STACK_ROOT}/ollama/cleanup-variants.sh" "$@" ;;
      *) error_exit "Unknown ollama command: $cmd" ;;
    esac ;;
  vllm|vLLM|VLLM)
    case "$cmd" in
      bench|benchmark) "${STACK_ROOT}/vLLM/benchmark.sh" "$@" ;;
      install)         "${STACK_ROOT}/vLLM/install.sh" "$@" ;;
      *) error_exit "Unknown vLLM command: $cmd" ;;
    esac ;;
  llama.cpp|llamacpp|llama-cpp)
    case "$cmd" in
      bench|benchmark) "${STACK_ROOT}/llama.cpp/benchmark.sh" "$@" ;;
      import-gguf|import-from-ollama|import) "${STACK_ROOT}/llama.cpp/import-gguf-from-ollama.sh" "$@" ;;
      install)         "${STACK_ROOT}/llama.cpp/install.sh" "$@" ;;
      *) error_exit "Unknown llama.cpp command: $cmd" ;;
    esac ;;
  triton|Triton)
    case "$cmd" in
      bench|benchmark) "${STACK_ROOT}/Triton/benchmark.sh" "$@" ;;
      install)         "${STACK_ROOT}/Triton/install.sh" "$@" ;;
      *) error_exit "Unknown Triton command: $cmd" ;;
    esac ;;
  *)
    error_exit "Unknown stack: $stack" ;;
esac

