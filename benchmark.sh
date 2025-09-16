#!/usr/bin/env bash
# benchmark.sh — Lightweight CLI for FuZe stack benchmarking
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
    --stack STACK       Target stack: ollama | vLLM | llama.cpp | Triton
    --model PATTERN     Model pattern/regex to match
    --gpu LIST          GPU specification (e.g., "0,1" for multi-GPU)
    --combined LIST     Multi-GPU model splitting (e.g., "0,1,2")
    --debug             Enable debug mode
    --clean             Clean before benchmarking
    -h, --help          Show this help

EXAMPLES:
    $0 --stack ollama                           # Benchmark Ollama with defaults
    $0 --stack vLLM --model gemma3             # Benchmark vLLM with gemma3 models
    $0 --stack ollama --gpu 0,1 --debug        # Multi-GPU Ollama with debug
    $0 --stack ollama --combined 0,1,2 --model deepseek   # Multi-GPU model splitting
    $0 --clean --stack llama.cpp               # Clean then benchmark llama.cpp

WORKFLOW:
    1. Optional: --clean runs cleanup via ust.sh clean-bench
    2. Runs benchmark via ust.sh <stack> benchmark with specified parameters
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
DEBUG=0
CLEAN=0

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
        --debug)
            DEBUG=1
            shift
            ;;
        --clean)
            CLEAN=1
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

# Validate required parameters
if [ -z "$STACK" ]; then
    echo "ERROR: --stack is required" >&2
    echo "Use --help for usage information." >&2
    exit 1
fi

# Validate stack
case "$STACK" in
    ollama|vLLM|llama.cpp|Triton) ;;
    *) 
        echo "ERROR: Invalid stack '$STACK'. Must be: ollama | vLLM | llama.cpp | Triton" >&2
        exit 1 
        ;;
esac

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

# Step 2: Prepare benchmark arguments for the specific stack
echo "=== Running $STACK benchmark ==="

# Add stack
UST_ARGS=("$STACK" "benchmark")

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

# Handle debug mode
if [ "$DEBUG" -eq 1 ]; then
    ENV_VARS+=("VERBOSE=1" "DEBUG=1")
    echo "Debug mode enabled"
fi

# Export variables for ust.sh access
if [ -n "$COMBINED" ]; then
    export COMBINED="$COMBINED"
fi
if [ -n "$MODEL" ]; then
    export MODEL="$MODEL"
fi

# Execute the benchmark via ust.sh
echo "Executing: $UST ${UST_ARGS[*]}"
if [ ${#ENV_VARS[@]} -gt 0 ]; then
    echo "Environment: ${ENV_VARS[*]}"
    env "${ENV_VARS[@]}" "$UST" "${UST_ARGS[@]}"
else
    "$UST" "${UST_ARGS[@]}"
fi
