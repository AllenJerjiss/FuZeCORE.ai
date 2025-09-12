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
OLLAMA_SH="${ROOT_DIR}/ollama/benchmark.sh"
LLAMACPP_SH="${ROOT_DIR}/llama.cpp/benchmark.sh"
VLLM_SH="${ROOT_DIR}/vLLM/benchmark.sh"
TRITON_SH="${ROOT_DIR}/Triton/benchmark.sh"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need awk; need sed; need sort; need head; need tail; need find

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
# Combine CSVs produced in this run
# 1) Prefer files matching *_bench_${RUN_TS}.csv
# 2) If none, fall back to ANY *_bench_*.csv (newest first)
# 3) If still none, synthesize a header with the NEW schema
###############################################################################
gather_csvs() {
  local pattern="$1"
  find "$LOG_DIR" -maxdepth 1 -type f -name "$pattern" -printf '%T@ %p\n' \
    | sort -nr \
    | awk '{print $2}'
}

mapfile -t match_csvs < <(gather_csvs "*_bench_${RUN_TS}.csv")

if [[ ${#match_csvs[@]} -eq 0 ]]; then
  echo "No CSVs found for RUN_TS=${RUN_TS} in ${LOG_DIR} — falling back to recent CSVs."
  mapfile -t match_csvs < <(gather_csvs "*_bench_*.csv")
fi

if [[ ${#match_csvs[@]} -eq 0 ]]; then
  echo "Still no CSVs; creating a stub combined file with header."
  # New schema header (matches benchmark.sh output):
  echo "host,timestamp,endpoint,gpu_name,gpu_uuid,label,model,num_gpu,endpoint_suffix,eval_count,eval_duration,tokens_per_sec" >"$ALL_CSV"
else
  # Header from first CSV, then bodies from all
  head -n1 "${match_csvs[0]}" >"$ALL_CSV"
  for f in "${match_csvs[@]}"; do
    tail -n +2 "$f" >>"$ALL_CSV" || true
  done
fi

echo
echo "== Combined CSV =="
echo "  $ALL_CSV"
echo

# >>> TOP10 using new schema:
# cols: 1 host, 2 ts, 3 endpoint, 4 gpu_name, 5 gpu_uuid, 6 label, 7 model,
#       8 num_gpu, 9 endpoint_suffix, 10 eval_count, 11 eval_duration, 12 tokens_per_sec
echo "== Top-10 overall by tokens/sec =="
if [ -s "$ALL_CSV" ]; then
  tail -n +2 "$ALL_CSV" \
    | sort -t',' -k12,12gr \
    | head -n10 \
    | awk -F',' '{printf "  %-18s %-14s %-10s  %7.2f tok/s  (EP=%s  GPU=%s  ngpu=%s)\n",$7,$6,$9,$12,$3,$4,$8}'
else
  echo "No CSV rows."
fi

echo "DONE."

