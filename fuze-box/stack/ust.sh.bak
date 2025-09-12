#!/usr/bin/env bash
# unified_stack_test.sh (short: ust.sh)
set -euo pipefail

# Resolve the directory this script lives in (so paths are stable under sudo)
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default logs dir is local to the wrapper's folder
LOG_DIR="${LOG_DIR:-${BASE_DIR}/logs}"
mkdir -p "$LOG_DIR" 2>/dev/null || true

RUN_TS="${RUN_TS:-$(date +%Y%m%d_%H%M%S)}"
export RUN_TS LOG_DIR

STACK="${1:-all}"
shift || true

# Child scripts (anchored to BASE_DIR — no duplication)
OLLAMA_SCRIPT="${BASE_DIR}/ollama/ollama-benchmark.sh"
LLAMACPP_SCRIPT="${BASE_DIR}/llama.cpp/llama.cpp-benchmark.sh"
VLLM_SCRIPT="${BASE_DIR}/vLLM/vllm-benchmark.sh"
TRITON_SCRIPT="${BASE_DIR}/Triton/triton-benchmark.sh"

run_stack() {
  local name="$1" path="$2"
  shift 2 >/dev/null || true

  if [ ! -x "$path" ]; then
    echo "! Skipping ${name} (script missing or not executable): ${path}"
    return 0
  fi

  echo "== Running ${name} =="
  # Use sudo for stacks that need systemd/network services
  if [[ "$name" =~ ^(ollama|triton)$ ]] && [ "$(id -u)" -ne 0 ]; then
    sudo --preserve-env=RUN_TS,LOG_DIR "$path" "$@" || echo "! ${name} failed (continuing)"
  else
    RUN_TS="$RUN_TS" LOG_DIR="$LOG_DIR" "$path" "$@" || echo "! ${name} failed (continuing)"
  fi
}

case "${STACK}" in
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

# Combine CSVs from this run (any stack wrote *_${RUN_TS}.csv)
ALL_CSV="${LOG_DIR}/llm_bench_${RUN_TS}_ALL.csv"
echo "ts,stack,endpoint,unit,suffix,gpu_label,model,variant,num_gpu,num_ctx,batch,num_predict,tokens_per_sec,gpu_name,gpu_uuid,gpu_mem_mib,notes" >"$ALL_CSV"

found_any=0
while IFS= read -r -d '' f; do
  tail -n +2 "$f" >> "$ALL_CSV"
  found_any=1
done < <(find "$LOG_DIR" -maxdepth 1 -type f -name "*_${RUN_TS}.csv" -print0 | sort -z)

if [ "$found_any" -eq 0 ]; then
  echo "No CSVs found for RUN_TS=${RUN_TS} in ${LOG_DIR}."
  exit 0
fi

echo "== Combined CSV =="
echo "  $ALL_CSV"
echo
echo "== Top-10 overall by tokens/sec =="

# Portable sort: numeric sort on column 13 (tokens_per_sec)
if tail -n +2 "$ALL_CSV" | sort -t',' -k13,13nr >/dev/null 2>&1; then
  tail -n +2 "$ALL_CSV" | sort -t',' -k13,13nr | head -n10 \
  | awk -F',' '{printf "  %-7s %-3s %-20s %-34s %-12s %7.2f tok/s  (%s %s ngpu=%s)\n",$2,$5,$7,$8,$6,$13,$1,$3,$9}'
else
  # BusyBox fallback: use awk to sort
  tail -n +2 "$ALL_CSV" \
  | awk -F',' 'NF{print $0}' \
  | awk -F',' '{print $13"\t"$0}' \
  | sort -nr | head -n10 | cut -f2- \
  | awk -F',' '{printf "  %-7s %-3s %-20s %-34s %-12s %7.2f tok/s  (%s %s ngpu=%s)\n",$2,$5,$7,$8,$6,$13,$1,$3,$9}'
fi

echo "DONE."

