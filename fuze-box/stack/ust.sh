#!/usr/bin/env bash
# unified_stack_test.sh (ust.sh)
# Orchestrates per-stack benchmark scripts and produces a combined CSV + Top-10.

set -euo pipefail

###############################################################################
# Paths & setup
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"
LOG_DIR="${LOG_DIR:-${ROOT_DIR}/logs}"
mkdir -p "$LOG_DIR"

RUN_TS="${RUN_TS:-$(date +%Y%m%d_%H%M%S)}"
ALL_CSV="${LOG_DIR}/llm_bench_${RUN_TS}_ALL.csv"

###############################################################################
# Stack scripts
###############################################################################
OLLAMA_SH="${ROOT_DIR}/ollama/ollama-benchmark.sh"
LLAMACPP_SH="${ROOT_DIR}/llama.cpp/llama.cpp-benchmark.sh"
VLLM_SH="${ROOT_DIR}/vLLM/vllm-benchmark.sh"
TRITON_SH="${ROOT_DIR}/Triton/triton-benchmark.sh"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need awk; need sed; need sort; need head; need tail

run_one() {
  local name="$1" path="$2"
  if [[ ! -x "$path" ]]; then
    echo "! Skipping ${name} (script missing or not executable): ${path}"
    return 0
  fi
  echo "== Running ${name} =="
  if [[ $EUID -ne 0 ]]; then
    sudo env LOG_DIR="$LOG_DIR" RUN_TS="$RUN_TS" "$path" || echo "! ${name} failed (continuing)"
  else
    env LOG_DIR="$LOG_DIR" RUN_TS="$RUN_TS" "$path" || echo "! ${name} failed (continuing)"
  fi
}

###############################################################################
# Which stacks to run
###############################################################################
# Usage: ./ust.sh [ollama|llamacpp|vllm|triton]...
# Default: run everything we find.
REQUESTED=("$@")
if [[ ${#REQUESTED[@]} -eq 0 ]]; then
  REQUESTED=(ollama llamacpp vllm triton)
fi

for s in "${REQUESTED[@]}"; do
  case "$s" in
    ollama)   run_one "ollama"   "$OLLAMA_SH" ;;
    llamacpp) run_one "llamacpp" "$LLAMACPP_SH" ;;
    vllm)     run_one "vllm"     "$VLLM_SH" ;;
    triton)   run_one "triton"   "$TRITON_SH" ;;
    *)
      echo "! Unknown stack: $s (skipping)"
      ;;
  esac
done

###############################################################################
# Combine CSVs produced in this run (match *_bench_${RUN_TS}.csv)
###############################################################################
match_csvs=()
while IFS= read -r -d '' f; do
  match_csvs+=("$f")
done < <(find "$LOG_DIR" -maxdepth 1 -type f -name "*_bench_${RUN_TS}.csv" -print0 | sort -z)

if [[ ${#match_csvs[@]} -eq 0 ]]; then
  echo "No CSVs found for RUN_TS=${RUN_TS} in ${LOG_DIR}."
  # still print a stub combined file so downstream tools don't explode
  echo "ts,endpoint,unit,suffix,base_model,variant_label,model_tag,num_gpu,num_ctx,batch,num_predict,tokens_per_sec,gpu_label,gpu_name,gpu_uuid,gpu_mem_mib" >"$ALL_CSV"
else
  # Header from first CSV, then bodies from all
  head -n1 "${match_csvs[0]}" >"$ALL_CSV"
  for f in "${match_csvs[@]}"; do
    tail -n +2 "$f" >>"$ALL_CSV"
  done
fi

echo
echo "== Combined CSV =="
echo "  $ALL_CSV"
echo

# >>> TOP10 (replacement)
echo "== Top-10 overall by tokens/sec =="
if [ -s "$ALL_CSV" ]; then
  # tokens_per_sec is column 12 in our combined schema
  tail -n +2 "$ALL_CSV" | sort -t',' -k12,12gr | head -n10 \
    | awk -F',' '{printf "  %-2s %-18s %-28s %-14s %6.2f tok/s  (%s %s ngpu=%s)\n",$4,$5,$6,$13,$12,$1,$2,$8}'
else
  echo "No CSV rows."
fi
# >>> END TOP10
echo "DONE."

