#!/usr/bin/env bash
# vllm-benchmark.sh
set -euo pipefail

STACK="vllm"
LOG_DIR="${LOG_DIR:-/FuZe/logs}"
RUN_TS="${RUN_TS:-$(date +%Y%m%d_%H%M%S)}"
CSV_FILE="${LOG_DIR}/${STACK}_bench_${RUN_TS}.csv"
echo "ts,stack,endpoint,unit,suffix,gpu_label,model,variant,num_gpu,num_ctx,batch,num_predict,tokens_per_sec,gpu_name,gpu_uuid,gpu_mem_mib,notes" >"$CSV_FILE"

# List of models for vLLM (HF names or local paths). Example:
# export VLLM_MODELS="meta-llama/Llama-3.1-8B-Instruct mistralai/Mixtral-8x7B-Instruct-v0.1"
VLLM_MODELS="${VLLM_MODELS:-}"
TP_SIZE="${TP_SIZE:-1}"     # tensor-parallel size
CTX="${CTX:-1024}"
BATCH="${BATCH:-32}"
PRED="${PRED:-256}"
EXHAUSTIVE="${EXHAUSTIVE:-0}"

if ! python3 -c 'import vllm' >/dev/null 2>&1; then
  echo "! vLLM not installed in current Python. Skipping."
  exit 0
fi
if [ -z "$VLLM_MODELS" ]; then
  echo "! No VLLM_MODELS provided; skipping vLLM benchmark."
  exit 0
fi

gpu_table(){ nvidia-smi --query-gpu=index,uuid,name,memory.total --format=csv,noheader | sed 's/, /,/g'; }
gpu_label(){
  local name="$(echo "$1" | tr 'A-Z' 'a-z')"
  local suffix="$(echo "$name" | sed -E 's/.*rtx[[:space:]]*([0-9]{4}([[:space:]]*ti)?).*/\1/' | tr -d ' ')"
  [ -z "$suffix" ] && suffix="$(echo "$name" | grep -oE '[0-9]{4}(ti)?' | head -n1)"
  suffix="$(echo "$suffix" | tr -d ' ')"
  [ -z "$suffix" ] && { echo "nvidia"; return; }
  echo "nvidia-${suffix}"
}

# Single-GPU runs (apples-to-apples with the others)
while IFS=',' read -r idx uuid name mem; do
  gpul="$(gpu_label "$name")"
  ep="GPU${idx}"
  unit="vLLM"
  sfx="$idx"

  for m in $VLLM_MODELS; do
    echo "==> [$ep] $m (TP=${TP_SIZE}, ctx=$CTX, batch=$BATCH, pred=$PRED)"
    # Isolate device via CUDA_VISIBLE_DEVICES
    out="$( CUDA_VISIBLE_DEVICES=$idx python3 -m vllm.benchmark.throughput \
            --model "$m" \
            --tensor-parallel-size "$TP_SIZE" \
            --tokenizer "$m" \
            --input-len "$BATCH" \
            --output-len "$PRED" \
            --dtype float16 2>&1 || true )"
    # vLLM prints "Throughput (token/s): X"
    ts_val="$(echo "$out" | grep -i 'Throughput' | tail -n1 | awk -F': ' '{print $2}' | tr -d ' ' )"
    [ -z "$ts_val" ] && ts_val="0.00"
    echo "$(date -Iseconds),$STACK,$ep,$unit,$sfx,$gpul,$m,$m,default,$CTX,$BATCH,$PRED,$ts_val,$name,$uuid,${mem%% MiB}," >>"$CSV_FILE"
  done
done < <(gpu_table)

echo "✔ DONE. CSV: ${CSV_FILE}"

