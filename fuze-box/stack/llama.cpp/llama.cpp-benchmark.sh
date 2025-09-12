#!/usr/bin/env bash
# llamacpp-benchmark.sh
set -euo pipefail

STACK="llamacpp"
LOG_DIR="${LOG_DIR:-/FuZe/logs}"
OLLAMA_MODELS_DIR="${OLLAMA_MODELS_DIR:-/FuZe/ollama/models}"
RUN_TS="${RUN_TS:-$(date +%Y%m%d_%H%M%S)}"

CTX="${CTX:-1024}"
BATCH="${BATCH:-32}"
PRED="${PRED:-256}"
EXHAUSTIVE="${EXHAUSTIVE:-0}"
VERBOSE="${VERBOSE:-1}"

# Sweep for n-gpu-layers (similar idea to num_gpu)
NGL_CANDIDATES="${NGL_CANDIDATES:-80 72 64 56 48 40 32 24 16 0}"

mkdir -p "$LOG_DIR" 2>/dev/null || true
CSV_FILE="${LOG_DIR}/${STACK}_bench_${RUN_TS}.csv"
echo "ts,stack,endpoint,unit,suffix,gpu_label,model,variant,num_gpu,num_ctx,batch,num_predict,tokens_per_sec,gpu_name,gpu_uuid,gpu_mem_mib,notes" >"$CSV_FILE"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "✖ Missing dependency: $1" >&2; exit 1; }; }
need nvidia-smi; need awk; need sed; need grep

LLAMA_CLI="${LLAMA_CLI:-/usr/local/bin/llama-cli}"
LLAMA_BENCH="${LLAMA_BENCH:-/usr/local/bin/llama-bench}"
if ! command -v "$LLAMA_CLI" >/dev/null 2>&1 && ! command -v "$LLAMA_BENCH" >/dev/null 2>&1; then
  echo "✖ Neither llama-cli nor llama-bench found. Install/build llama.cpp first." >&2
  exit 1
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

calc_tokps(){ awk -v ec="$1" -v ed="$2" 'BEGIN{ if(ed<=0){print "0.00"} else {printf("%.2f", ec/(ed/1e9))} }'; }

# Find GGUFs in the Ollama store
mapfile -t GGUFs < <(find "${OLLAMA_MODELS_DIR}" -type f -name '*.gguf' 2>/dev/null | sort)
if [ "${#GGUFs[@]}" -eq 0 ]; then
  echo "! No GGUFs found under ${OLLAMA_MODELS_DIR}; nothing to benchmark."
  exit 0
fi

echo "== GPUs =="
gpu_table | sed 's/^/  /'

echo "== GGUF models found =="
printf "  %s\n" "${GGUFs[@]}"

# Bench a single run (returns tokens/s)
bench_one_cli(){
  local model="$1" ngl="$2" ctx="$3" batch="$4" pred="$5" out log
  # Limit visibility to a single CUDA device via CUDA_VISIBLE_DEVICES before calling
  out="$( "$LLAMA_CLI" -m "$model" -p "ok ok ok ok ok" --n-predict "$pred" -c "$ctx" -b "$batch" -ngl "$ngl" 2>&1 || true )"
  # Try to parse a tokens/s; llama.cpp often prints "eval speed: X tokens/s"
  echo "$out" | grep -iE 'eval[ _-]?speed|tokens/s' | tail -n1 \
    | awk '{for(i=1;i<=NF;i++) if ($i ~ /[0-9]+\.[0-9]+/) {val=$i} } END{ if (val=="") print "0.00"; else print val }'
}

bench_one_bench(){
  local model="$1" ngl="$2" ctx="$3" batch="$4" pred="$5"
  # llama-bench syntax varies by rev; this is a best-effort
  out="$( "$LLAMA_BENCH" -m "$model" -n "$pred" -c "$ctx" -b "$batch" -ngl "$ngl" 2>&1 || true )"
  echo "$out" | grep -iE 'tok/s|tokens/s|throughput' | tail -n1 \
    | awk '{for(i=1;i<=NF;i++) if ($i ~ /[0-9]+\.[0-9]+/) {val=$i} } END{ if (val=="") print "0.00"; else print val }'
}

append_csv_row(){ echo "$*" >>"$CSV_FILE"; }

# Loop GPUs (by physical index), then GGUFs, then ngl sweep
while IFS=',' read -r idx uuid name mem; do
  gpul="$(gpu_label "$name")"
  ep="GPU${idx}"  # endpoint label for CSV
  unit="llama.cpp" # unit label
  sfx="$idx"

  for model in "${GGUFs[@]}"; do
    best_ts="0.00"; best_variant=""
    for ngl in $NGL_CANDIDATES; do
      echo "==> [$ep] $model  ngl=$ngl"
      # Isolate to one device
      if command -v "$LLAMA_CLI" >/dev/null 2>&1; then
        ts_val="$(CUDA_VISIBLE_DEVICES=${idx} "$LLAMA_CLI" -m "$model" -p "ok ok ok" --n-predict "$PRED" -c "$CTX" -b "$BATCH" -ngl "$ngl" 2>&1 \
          | grep -iE 'eval[ _-]?speed|tokens/s' | tail -n1 \
          | awk '{for(i=1;i<=NF;i++) if ($i ~ /[0-9]+\.[0-9]+/) {val=$i} } END{ if (val=="") print "0.00"; else print val }')"
      else
        ts_val="$(CUDA_VISIBLE_DEVICES=${idx} "$LLAMA_BENCH" -m "$model" -n "$PRED" -c "$CTX" -b "$BATCH" -ngl "$ngl" 2>&1 \
          | grep -iE 'tok/s|tokens/s|throughput' | tail -n1 \
          | awk '{for(i=1;i<=NF;i++) if ($i ~ /[0-9]+\.[0-9]+/) {val=$i} } END{ if (val=="") print "0.00"; else print val }')"
      fi

      append_csv_row "$(date -Iseconds),$STACK,$ep,$unit,$sfx,$gpul,$(basename "$model"),$(basename "$model")-ngl$ngl,$ngl,$CTX,$BATCH,$PRED,$ts_val,$name,$uuid,${mem%% MiB},"
      # stop on first >0 if not exhaustive
      awk -v a="$ts_val" -v b="$best_ts" 'BEGIN{exit !(a>b)}' && { best_ts="$ts_val"; best_variant="$(basename "$model")-ngl$ngl"; }
      [ "$EXHAUSTIVE" -eq 0 ] && awk -v a="$ts_val" 'BEGIN{exit !(a>0)}' && break
    done
    echo "Best [$ep] $(basename "$model"): $best_variant at ${best_ts} tok/s"
  done
done < <(gpu_table)

echo "✔ DONE. CSV: ${CSV_FILE}"

