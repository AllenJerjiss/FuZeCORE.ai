#!/usr/bin/env bash
#!/usr/bin/env bash
# cracker.sh — Lightweight CLI for FuZe stack benchmarking
# Comprehensive frontend for multi-GPU model benchmarking across AI stacks
# Simple interface that delegates to ust.sh orchestrator for actual work

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UST="${ROOT_DIR}/factory/LLM/refinery/stack/ust.sh"

# Verify ust.sh exists
if [ ! -f "$UST" ]; then
    echo "ERROR: Orchestrator not found: $UST" >&2
    exit 1
fi

usage() {
    cat <<USAGE
Usage: $(basename "$0") [OPTIONS]

A lightweight CLI for FuZe stack benchmarking that delegates to the ust.sh orchestrator.

OPTIONS:
    --stack STACK           Target stack: ollama | vLLM | llama.cpp | Triton
    --model PATTERN         Model pattern/regex to match
    --gpu LIST              GPU specification (e.g., "0,1" for multi-GPU)
    --combined LIST         Multi-GPU model splitting (e.g., "0,1,2")
    --num-predict N         Number of tokens to predict (default: 60)
    --num-ctx N             Context window size (default: 4096)
    --temperature FLOAT     Temperature for generation (0.0-2.0, default: 0.7)
    --timeout N             Timeout in seconds for generation (default: 60)
    --fast-mode             Enable fast mode (no tag baking during search)
    --exhaustive            Try all candidates for broader coverage
    --auto-ng               Enable AUTO_NG optimization (derive layers from model)
    --install               Install the specified stack instead of benchmarking
    --analyze               Run analysis after benchmarking
    --collect-results       Collect and aggregate benchmark results
    --summarize             Generate comprehensive benchmark reports
    --debug                 Enable debug mode
    --export-gguf           Export models from Ollama to GGUF format
    --import-gguf           Import GGUF models from Ollama for llama.cpp
    --service-cleanup       Setup persistent Ollama service (requires --stack ollama)
    --store-cleanup         Normalize Ollama model storage (requires --stack ollama)
    --cleanup-variants      Remove benchmark-created variants (requires --stack ollama)
    --clean                 Clean before benchmarking
    --clean-all             Comprehensive cleanup: logs, CSVs, variants (dry-run with --debug)
    -h, --help              Show this help

EXAMPLES:
    $0 --stack ollama                                       # Benchmark Ollama with defaults
    $0 --stack vLLM --model gemma3                         # Benchmark vLLM with gemma3 models
    $0 --stack ollama --gpu 0,1 --debug                    # Multi-GPU Ollama with debug
    $0 --stack ollama --combined 0,1,2 --model deepseek    # Multi-GPU model splitting
    $0 --clean --stack llama.cpp                           # Clean then benchmark llama.cpp
    $0 --stack ollama --temperature 0.7 --num-ctx 8192     # Custom temperature and context
    $0 --stack ollama --fast-mode --exhaustive             # Fast exhaustive benchmarking
    $0 --stack ollama --auto-ng --debug                    # Enable AUTO_NG optimization with debug
    $0 --stack vLLM --install                               # Install vLLM stack
    $0 --stack llama.cpp --install --debug                 # Install llama.cpp with debug output
    $0 --stack ollama --export-gguf                         # Export Ollama models to GGUF format
    $0 --stack llama.cpp --import-gguf                      # Import GGUF models from Ollama
    $0 --stack ollama --service-cleanup                     # Setup persistent Ollama service
    $0 --stack ollama --store-cleanup                       # Normalize Ollama model storage
    $0 --stack ollama --cleanup-variants --debug            # Preview variant cleanup (dry-run)
    $0 --clean-all --debug                                  # Preview comprehensive cleanup
    $0 --clean-all                                          # Full cleanup: logs, CSVs, variants
    $0 --stack ollama --analyze                             # Benchmark then analyze results
    $0 --collect-results                                    # Aggregate all benchmark results
    $0 --summarize                                          # Generate comprehensive reports

WORKFLOW:
    1. Optional: --clean runs cleanup via ust.sh clean-bench
    2. With --install: Runs installation via ust.sh <stack> install
    3. Default: Runs benchmark via ust.sh <stack> benchmark with specified parameters
    4. All actual work delegated to ust.sh orchestrator
    3. All actual work delegated to ust.sh orchestrator

For more control, use ust.sh directly:
    $UST --help
USAGE
}

# Parse arguments
STACK=""
MODEL=""
GPU=""
COMBINED=""
NUM_PREDICT=""
NUM_CTX=""
TEMPERATURE=""
TIMEOUT=""
FAST_MODE=0
EXHAUSTIVE=0
AUTO_NG=0
INSTALL=0
ANALYZE=0
COLLECT_RESULTS=0
SUMMARIZE=0
DEBUG=0
CLEAN=0
EXPORT_GGUF=0
IMPORT_GGUF=0
SERVICE_CLEANUP=0
STORE_CLEANUP=0
CLEANUP_VARIANTS=0
CLEAN_ALL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --stack)
            STACK="$2"
            shift 2
            ;;
        --model)
            MODEL="$2"
            shift 2
            ;;
        --gpu)
            GPU="$2"
            shift 2
            ;;
        --combined)
            COMBINED="$2"
            shift 2
            ;;
        --num-predict)
            NUM_PREDICT="$2"
            shift 2
            ;;
        --num-ctx)
            NUM_CTX="$2"
            shift 2
            ;;
        --temperature)
            TEMPERATURE="$2"
            shift 2
            ;;
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --fast-mode)
            FAST_MODE=1
            shift
            ;;
        --exhaustive)
            EXHAUSTIVE=1
            shift
            ;;
        --auto-ng)
            AUTO_NG=1
            shift
            ;;
        --install)
            INSTALL=1
            shift
            ;;
        --analyze)
            ANALYZE=1
            shift
            ;;
        --collect-results)
            COLLECT_RESULTS=1
            shift
            ;;
        --summarize)
            SUMMARIZE=1
            shift
            ;;
        --debug)
            DEBUG=1
            shift
            ;;
        --clean)
            CLEAN=1
            shift
            ;;
        --export-gguf)
            EXPORT_GGUF=1
            shift
            ;;
        --import-gguf)
            IMPORT_GGUF=1
            shift
            ;;
        --service-cleanup)
            SERVICE_CLEANUP=1
            shift
            ;;
        --store-cleanup)
            STORE_CLEANUP=1
            shift
            ;;
        --cleanup-variants)
            CLEANUP_VARIANTS=1
            shift
            ;;
        --clean-all)
            CLEAN_ALL=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            echo "Use --help for usage information." >&2
            exit 1
            ;;
    esac
done

# Handle analysis-only operations (don't require stack)
if [ "$COLLECT_RESULTS" -eq 1 ]; then
    echo "=== Collecting and aggregating benchmark results ==="
    exec "$UST" collect-results "$@"
fi

if [ "$SUMMARIZE" -eq 1 ]; then
    echo "=== Generating comprehensive benchmark reports ==="
    exec "$UST" summarize-benchmarks "$@"
fi

# Validate required parameters for stack operations
if [ -z "$STACK" ] && [ "$CLEAN_ALL" -eq 0 ]; then
    echo "ERROR: --stack is required for benchmark, install, and analysis operations" >&2
    echo "Use --help for usage information." >&2
    exit 1
fi

# Validate stack if provided
if [ -n "$STACK" ]; then
    case "$STACK" in
        ollama|vLLM|llama.cpp|Triton) ;;
        *) 
            echo "ERROR: Invalid stack '$STACK'. Must be: ollama | vLLM | llama.cpp | Triton" >&2
            exit 1 
            ;;
    esac
fi

# Build ust.sh arguments
UST_ARGS=()

# Step 1: Optional cleanup
if [ "$CLEAN" -eq 1 ]; then
    echo "=== Cleaning benchmark artifacts ==="
    if ! "$UST" clean-bench --yes; then
        echo "ERROR: Cleanup failed" >&2
        exit 1
    fi
    echo "✓ Cleanup completed"
    echo
fi

# Step 1.5: Model Import/Export operations
if [ "$EXPORT_GGUF" -eq 1 ]; then
    if [ "$STACK" != "ollama" ]; then
        echo "ERROR: --export-gguf requires --stack ollama" >&2
        exit 1
    fi
    echo "=== Exporting GGUF models from Ollama ==="
    # Build export arguments
    EXPORT_ARGS=()
    [ "$DEBUG" -eq 1 ] && EXPORT_ARGS+=("--dry-run")  # Use dry-run for debug mode
    exec "$UST" ollama export-gguf "${EXPORT_ARGS[@]}"
fi

if [ "$IMPORT_GGUF" -eq 1 ]; then
    if [ "$STACK" != "llama.cpp" ]; then
        echo "ERROR: --import-gguf requires --stack llama.cpp" >&2
        exit 1
    fi
    echo "=== Importing GGUF models from Ollama to llama.cpp ==="
    # Build import arguments  
    IMPORT_ARGS=()
    [ "$DEBUG" -eq 1 ] && IMPORT_ARGS+=("--dry-run")  # Use dry-run for debug mode
    exec "$UST" llama.cpp import-gguf "${IMPORT_ARGS[@]}"
fi

# Step 1.6: Service Management operations
if [ "$SERVICE_CLEANUP" -eq 1 ]; then
    if [ "$STACK" != "ollama" ]; then
        echo "ERROR: --service-cleanup requires --stack ollama" >&2
        exit 1
    fi
    echo "=== Setting up persistent Ollama service ==="
    exec "$UST" ollama service-cleanup
fi

if [ "$STORE_CLEANUP" -eq 1 ]; then
    if [ "$STACK" != "ollama" ]; then
        echo "ERROR: --store-cleanup requires --stack ollama" >&2
        exit 1
    fi
    echo "=== Normalizing Ollama model storage ==="
    exec "$UST" ollama store-cleanup
fi

if [ "$CLEANUP_VARIANTS" -eq 1 ]; then
    if [ "$STACK" != "ollama" ]; then
        echo "ERROR: --cleanup-variants requires --stack ollama" >&2
        exit 1
    fi
    echo "=== Cleaning up benchmark-created model variants ==="
    # Build cleanup arguments
    CLEANUP_ARGS=()
    [ "$DEBUG" -eq 1 ] || CLEANUP_ARGS+=("--force" "--yes")  # Use force mode unless debug
    exec "$UST" ollama cleanup-variants "${CLEANUP_ARGS[@]}"
fi

# Step 1.7: Comprehensive Cleanup operations  
if [ "$CLEAN_ALL" -eq 1 ]; then
    echo "=== Comprehensive cleanup: logs, CSVs, and variants ==="
    # Build comprehensive cleanup arguments
    CLEAN_ALL_ARGS=("--variants")  # Always include variant cleanup
    if [ "$DEBUG" -eq 1 ]; then
        echo "Debug mode: Running dry-run preview"
    else
        CLEAN_ALL_ARGS+=("--yes")  # Use force mode unless debug
    fi
    exec "$UST" clean-bench "${CLEAN_ALL_ARGS[@]}"
fi

# Step 2: Prepare arguments for the specific stack
if [ "$INSTALL" -eq 1 ]; then
    echo "=== Installing $STACK stack ==="
    UST_ARGS=("$STACK" "install")
else
    echo "=== Running $STACK benchmark ==="
    
    # Auto-select environment file based on model pattern and env mode
    UST_ARGS=("$STACK" "benchmark")
fi

# Build environment variables and parameters
ENV_VARS=()

# Handle GPU specification
if [ -n "$GPU" ]; then
    # Convert GPU list to CUDA_VISIBLE_DEVICES format
    CUDA_GPUS="$GPU"
    ENV_VARS+=("CUDA_VISIBLE_DEVICES=$CUDA_GPUS")
    
    # For multi-GPU setups, enable Ollama spreading
    if [[ "$GPU" == *","* ]] && [ "$STACK" = "ollama" ]; then
        ENV_VARS+=("OLLAMA_SCHED_SPREAD=1")
        echo "Multi-GPU mode: $CUDA_GPUS (OLLAMA_SCHED_SPREAD enabled)"
    else
        echo "GPU mode: $CUDA_GPUS"
    fi
fi

# Handle combined GPU mode (multi-GPU model splitting)
if [ -n "$COMBINED" ]; then
    if [ -z "$MODEL" ]; then
        echo "ERROR: --combined requires --model to specify which model to split" >&2
        exit 1
    fi
    
    # Convert gpu list format
    CUDA_GPUS="$COMBINED"
    ENV_VARS+=("CUDA_VISIBLE_DEVICES=$CUDA_GPUS")
    ENV_VARS+=("OLLAMA_SCHED_SPREAD=1")
    ENV_VARS+=("FUZE_COMBINED_MODE=1")
    ENV_VARS+=("FUZE_GPU_CONFIG=$COMBINED")
    
    echo "Multi-GPU model splitting: $CUDA_GPUS (model: $MODEL)"
fi

# Handle model pattern
if [ -n "$MODEL" ]; then
    ENV_VARS+=("MODEL_PATTERN=$MODEL")
    echo "Model pattern: $MODEL"
fi

# Pass stack name for enhanced alias generation
if [ -n "$STACK" ]; then
    ENV_VARS+=("FUZE_STACK_NAME=$STACK")
fi

# Handle debug mode
if [ "$DEBUG" -eq 1 ]; then
    ENV_VARS+=("VERBOSE=1" "DEBUG=1")
    echo "Debug mode enabled"
fi

if [ -n "$NUM_PREDICT" ]; then
    ENV_VARS+=("BENCH_NUM_PREDICT=$NUM_PREDICT")
    echo "Number of tokens to predict: $NUM_PREDICT"
fi

if [ -n "$NUM_CTX" ]; then
    ENV_VARS+=("BENCH_NUM_CTX=$NUM_CTX")
    echo "Context window size: $NUM_CTX"
fi

if [ -n "$TEMPERATURE" ]; then
    ENV_VARS+=("TEMPERATURE=$TEMPERATURE")
    echo "Temperature: $TEMPERATURE"
fi

if [ -n "$TIMEOUT" ]; then
    ENV_VARS+=("TIMEOUT_GEN=$TIMEOUT")
    echo "Generation timeout: $TIMEOUT seconds"
fi

if [ "$FAST_MODE" -eq 1 ]; then
    ENV_VARS+=("FAST_MODE=1")
    echo "Fast mode enabled (no tag baking during search)"
fi

if [ "$EXHAUSTIVE" -eq 1 ]; then
    ENV_VARS+=("EXHAUSTIVE=1")
    echo "Exhaustive mode enabled (try all candidates)"
fi

if [ "$AUTO_NG" -eq 1 ]; then
    ENV_VARS+=("AUTO_NG=1")
    echo "AUTO_NG optimization enabled (derive layers from model)"
fi

# Export variables for ust.sh access
if [ -n "$COMBINED" ]; then
    export COMBINED="$COMBINED"
fi
if [ -n "$MODEL" ]; then
    export MODEL="$MODEL"
fi
if [ -n "$NUM_PREDICT" ]; then
    export NUM_PREDICT="$NUM_PREDICT"
fi
if [ -n "$NUM_CTX" ]; then
    export NUM_CTX="$NUM_CTX"
fi
if [ -n "$TEMPERATURE" ]; then
    export TEMPERATURE="$TEMPERATURE"
fi
if [ -n "$TIMEOUT" ]; then
    export TIMEOUT="$TIMEOUT"
fi
if [ "$FAST_MODE" -eq 1 ]; then
    export FAST_MODE="$FAST_MODE"
fi
if [ "$EXHAUSTIVE" -eq 1 ]; then
    export EXHAUSTIVE="$EXHAUSTIVE"
fi
if [ "$AUTO_NG" -eq 1 ]; then
    export AUTO_NG="$AUTO_NG"
fi

# Execute the benchmark via ust.sh
echo "Executing: $UST ${UST_ARGS[*]}"
if [ ${#ENV_VARS[@]} -gt 0 ]; then
    echo "Environment: ${ENV_VARS[*]}"
    env "${ENV_VARS[@]}" "$UST" "${UST_ARGS[@]}"
else
    "$UST" "${UST_ARGS[@]}"
fi

# Post-benchmark analysis if requested
if [ "$ANALYZE" -eq 1 ] && [ "$INSTALL" -eq 0 ]; then
    echo ""
    echo "=== Post-benchmark analysis ==="
    # First collect results to ensure latest benchmarks are included
    echo "Collecting latest results..."
    "$UST" collect-results >/dev/null 2>&1 || true
    # Then run analysis
    "$UST" analyze --stack "$STACK"
fi
