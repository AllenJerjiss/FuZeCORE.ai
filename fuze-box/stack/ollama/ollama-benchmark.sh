#!/usr/bin/env bash
# unified_stack_test.sh (aka ust.sh)
set -euo pipefail

STACK="${1:-all}"
shift || true

LOG_DIR="${LOG_DIR:-/FuZe/logs}"
mkdir -p "$LOG_DIR" 2>/dev/null || true

RUN_TS="${RUN_TS:-$(date +%Y%m%d_%H%M%S)}"
export RUN_TS LOG_DIR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OLLAMA_SCRIPT="$SCRIPT_DIR/ollama/ollama-benchmark.sh"
LLAMACPP_SCRIPT="$SCRIPT_DIR/llama.cpp/llama.cpp-benchmark.sh"
VLLM_SCRIPT="$SCRIPT_DIR/vLLM/vllm-benchmark.sh"
TRITON_SCRIPT="$SCRIPT_DIR/Triton/triton-benchmark.sh"

run_stack() {
  local name="$1" path="$2"
  shift 2
  if [ ! -x "$path" ]; then
    echo "! Skipping $name (script missing or not executable): $path"
    return 0
  fi
  echo "== Running $name =="
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
    echo "Usage: $0 [all|ollama|llamacpp|vllm|triton] [flags...]"
    exit 1
    ;;
esac

# Collect CSVs from this batch (any stack)
mapfile -t CSVs < <(find "$LOG_DIR" -maxdepth 1 -type f -name "*_${RUN_TS}.csv" | sort || true)
if [ "${#CSVs[@]}" -eq 0 ]; then
  echo "No CSVs found for RUN_TS=${RUN_TS} in ${LOG_DIR}."
  exit 0
fi

ALL_CSV="${LOG_DIR}/llm_bench_${RUN_TS}_ALL.csv"
echo "ts,stack,endpoint,unit,suffix,gpu_label,model,variant,num_gpu,num_ctx,batch,num_predict,tokens_per_sec,gpu_name,gpu_uuid,gpu_mem_mib,notes" >"$ALL_CSV"
for c in "${CSVs[@]}"; do
  tail -n +2 "$c" >> "$ALL_CSV" || true
done

echo "== Combined CSV =="
echo "  $ALL_CSV"
echo
echo "== Top-10 overall by tokens/sec =="
# Use -k13,13nr for portability (BusyBox/older coreutils)
tail -n +2 "$ALL_CSV" | sort -t',' -k13,13nr | head -n10 \
 | awk -F',' '{printf "  %-7s %-3s %-20s %-34s %-12s %7.2f tok/s  (%s %s ngpu=%s)\n",$2,$5,$7,$8,$6,$13,$1,$3,$9}'

echo "DONE."

