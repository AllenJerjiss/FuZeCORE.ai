#!/usr/bin/env bash
# unified_stack_test.sh
set -euo pipefail

# Which stack to run: all | ollama | llamacpp | vllm | triton
STACK="${1:-all}"
shift || true

# Where logs go; all child scripts should honor this
LOG_DIR="${LOG_DIR:-/FuZe/logs}"
mkdir -p "$LOG_DIR" 2>/dev/null || true

# Share a single timestamp across all runs so we can merge CSVs
RUN_TS="${RUN_TS:-$(date +%Y%m%d_%H%M%S)}"
export RUN_TS LOG_DIR

# Resolve script locations relative to THIS file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OLLAMA_SCRIPT="$SCRIPT_DIR/ollama/ollama-benchmark.sh"
LLAMACPP_SCRIPT="$SCRIPT_DIR/llama.cpp/llama.cpp-benchmark.sh"
VLLM_SCRIPT="$SCRIPT_DIR/vLLM/vllm-benchmark.sh"
TRITON_SCRIPT="$SCRIPT_DIR/Triton/triton-benchmark.sh"

if [ ! -x "$OLLAMA_SCRIPT" ] && [ "$STACK" != "llamacpp" ] && [ "$STACK" != "vllm" ] && [ "$STACK" != "triton" ]; then
  echo "! $OLLAMA_SCRIPT is not executable (chmod +x)"; fi
if [ ! -x "$LLAMACPP_SCRIPT" ] && { [ "$STACK" = "llamacpp" ] || [ "$STACK" = "all" ]; }; then
  echo "! $LLAMACPP_SCRIPT is not executable (chmod +x)"; fi
if [ ! -x "$VLLM_SCRIPT" ] && { [ "$STACK" = "vllm" ] || [ "$STACK" = "all" ]; }; then
  echo "! $VLLM_SCRIPT is not executable (chmod +x)"; fi
if [ ! -x "$TRITON_SCRIPT" ] && { [ "$STACK" = "triton" ] || [ "$STACK" = "all" ]; }; then
  echo "! $TRITON_SCRIPT is not executable (chmod +x)"; fi

run_stack() {
  local name="$1" path="$2"
  shift 2
  if [ ! -x "$path" ]; then
    echo "! Skipping $name (script missing or not executable): $path"
    return 0
  fi
  echo "== Running $name =="
  # ollama + triton often need root; auto-sudo if we’re not root
  if [[ "$name" =~ ^(ollama|triton)$ ]] && [ "$(id -u)" -ne 0 ]; then
    sudo RUN_TS="$RUN_TS" LOG_DIR="$LOG_DIR" "$path" "$@" || echo "! $name failed (continuing)"
  else
    RUN_TS="$RUN_TS" LOG_DIR="$LOG_DIR" "$path" "$@" || echo "! $name failed (continuing)"
  fi
}

case "$STACK" in
  all)
    run_stack "ollama"   "$OLLAMA_SCRIPT"   "$@"
    run_stack "llamacpp" "$LLAMACPP_SCRIPT" "$@"
    run_stack "vllm"     "$VLLM_SCRIPT"     "$@"
    run_stack "triton"   "$TRITON_SCRIPT"   "$@"
    ;;
  ollama)   run_stack "ollama"   "$OLLAMA_SCRIPT"   "$@" ;;
  llamacpp) run_stack "llamacpp" "$LLAMACPP_SCRIPT" "$@" ;;
  vllm)     run_stack "vllm"     "$VLLM_SCRIPT"     "$@" ;;
  triton)   run_stack "triton"   "$TRITON_SCRIPT"   "$@" ;;
  *)
    echo "Usage: $0 [all|ollama|llamacpp|vllm|triton] [flags to pass through]"
    exit 1
    ;;
esac

# Collect CSVs from this batch
mapfile -t CSVs < <(find "$LOG_DIR" -maxdepth 1 -type f -name "*_${RUN_TS}.csv" | sort)
if [ "${#CSVs[@]}" -eq 0 ]; then
  echo "No CSVs found for RUN_TS=${RUN_TS} in ${LOG_DIR}."
  exit 0
fi

ALL_CSV="${LOG_DIR}/llm_bench_${RUN_TS}_ALL.csv"
# unified header (matches per-stack CSVs we set up)
echo "ts,stack,endpoint,unit,suffix,gpu_label,model,variant,num_gpu,num_ctx,batch,num_predict,tokens_per_sec,gpu_name,gpu_uuid,gpu_mem_mib,notes" >"$ALL_CSV"
for c in "${CSVs[@]}"; do
  tail -n +2 "$c" >> "$ALL_CSV"
done

echo "== Combined CSV =="
echo "  $ALL_CSV"
echo
echo "== Top-10 overall by tokens/sec =="
tail -n +2 "$ALL_CSV" | sort -t',' -_

