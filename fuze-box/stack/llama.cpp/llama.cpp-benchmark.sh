#!/usr/bin/env bash
# setup-llamacpp-bench.sh
# Bench llama.cpp against any .gguf models we can find, including in Ollama's model paths.
# Outputs CSV + ranked summary into ./logs and prints the summary at the end.

set -euo pipefail

############################
# Tunables (env overridable)
############################
: "${LLAMACPP_DIR:=/opt/llama.cpp}"          # where to (build &) run llama.cpp
: "${GGUF_DIR:=}"                            # extra directory you want scanned for *.gguf
: "${BATCH_LIST:=32 64}"                     # batches to try
: "${CTX:=1024}"                             # context length
: "${NPRED:=256}"                            # tokens to generate/measure
: "${THREADS:=$(nproc)}"                     # CPU threads (used for CPU pieces)
: "${RUN_TIMEOUT:=300}"                      # seconds per bench attempt
: "${NGL_TRY:="999 200 128 96 80 64 48 40 32 24 16 8 0"}"  # GPU layers to try (999 ≈ all that fit)

# Directories to scan for GGUFs (will be de-duped)
SCAN_DIRS=()
[[ -n "${GGUF_DIR}" ]]        && SCAN_DIRS+=("${GGUF_DIR}")
[[ -n "${OLLAMA_MODELS:-}" ]] && SCAN_DIRS+=("${OLLAMA_MODELS}")
SCAN_DIRS+=("$HOME/.ollama/models" "/FuZe/ollama/models" "/opt/ollama/models" "/var/lib/ollama/models")

############################
# Prep logs & metadata
############################
HOSTNAME="$(hostname -s || echo host)"
TS="$(date +%Y%m%d_%H%M%S)"
LOG_DIR="$(pwd)/logs"
mkdir -p "${LOG_DIR}"
CSV="${LOG_DIR}/llamacpp_bench_${TS}.csv"
SUMMARY="${LOG_DIR}/${HOSTNAME}-${TS}.benchmark"

echo "== llama.cpp GGUF bench =="
echo "llama.cpp : ${LLAMACPP_DIR}"
echo "Scan dirs : ${SCAN_DIRS[*]}"
echo "Batches   : ${BATCH_LIST}"
echo "Ctx/NPRED : ${CTX}/${NPRED}"
echo "CSV       : ${CSV}"
echo "Summary   : ${SUMMARY}"
echo

############################
# Ensure llama.cpp binaries
############################
need_build=0
LLAMA_MAIN=""
LLAMA_BENCH=""

if [[ -x "${LLAMACPP_DIR}/bin/llama-bench" && -x "${LLAMACPP_DIR}/bin/main" ]]; then
  LLAMA_BENCH="${LLAMACPP_DIR}/bin/llama-bench"
  LLAMA_MAIN="${LLAMACPP_DIR}/bin/main"
else
  # try PATH
  if command -v llama-bench >/dev/null 2>&1 && command -v main >/dev/null 2>&1; then
    LLAMA_BENCH="$(command -v llama-bench)"
    LLAMA_MAIN="$(command -v main)"
  else
    need_build=1
  fi
fi

if [[ "${need_build}" -eq 1 ]]; then
  echo "== Building llama.cpp (CUDA) at ${LLAMACPP_DIR} =="
  sudo mkdir -p "${LLAMACPP_DIR}"
  if [[ ! -d "${LLAMACPP_DIR}/.git" ]]; then
    sudo rm -rf "${LLAMACPP_DIR}"
    sudo git clone --depth=1 https://github.com/ggerganov/llama.cpp.git "${LLAMACPP_DIR}"
  fi
  pushd "${LLAMACPP_DIR}" >/dev/null
  sudo apt-get update -y
  sudo apt-get install -y build-essential cmake git
  mkdir -p build
  pushd build >/dev/null
  cmake -DLLAMA_CUBLAS=ON -DCMAKE_BUILD_TYPE=Release ..
  make -j"$(nproc)" main llama-bench
  popd >/dev/null
  popd >/dev/null
  LLAMA_BENCH="${LLAMACPP_DIR}/build/bin/llama-bench"
  LLAMA_MAIN="${LLAMACPP_DIR}/build/bin/main"
fi

[[ -x "${LLAMA_BENCH}" ]] || { echo "ERROR: llama-bench not found/executable"; exit 1; }
[[ -x "${LLAMA_MAIN}"  ]] || { echo "ERROR: main not found/executable"; exit 1; }

############################
# Collect GGUF candidates
############################
declare -A DEDUP
MODELS=()

for d in "${SCAN_DIRS[@]}"; do
  [[ -d "$d" ]] || continue
  # find *.gguf but skip obvious blob dirs
  while IFS= read -r -d '' f; do
    # de-dupe by inode path
    key="$(readlink -f "$f" || echo "$f")"
    if [[ -n "${DEDUP[$key]:-}" ]]; then continue; fi
    DEDUP["$key"]=1
    MODELS+=("$key")
  done < <(find "$d" -type f -name '*.gguf' -print0 2>/dev/null)
done

# If no GGUFs found, tell user clearly and exit
if [[ "${#MODELS[@]}" -eq 0 ]]; then
  echo "No .gguf models found under scanned paths."
  echo "Tip: set GGUF_DIR to a folder with GGUFs, or drop GGUF files under ~/.ollama/models or /FuZe/ollama/models."
  exit 2
fi

echo "== Found ${#MODELS[@]} GGUF model(s) =="
for m in "${MODELS[@]}"; do echo " - $m"; done
echo

############################
# Detect GPUs (index + name)
############################
GPU_IDX=()
GPU_NAME=()

if command -v nvidia-smi >/dev/null 2>&1; then
  mapfile -t GPU_IDX < <(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null || true)
  mapfile -t GPU_NAME < <(nvidia-smi --query-gpu=name  --format=csv,noheader 2>/dev/null || true)
else
  echo "WARNING: nvidia-smi not found; assuming CPU-only."
fi

if [[ "${#GPU_IDX[@]}" -eq 0 ]]; then
  echo "WARNING: No NVIDIA GPUs detected. Runs will be CPU-only (-ngl 0)."
  NGL_TRY="0"
  GPU_IDX=("cpu0")
  GPU_NAME=("CPU-only")
fi

############################
# CSV header
############################
echo "timestamp,host,gpu_index,gpu_name,model_basename,model_path,ngl,batch,ctx,npred,tokens_per_sec,runner,exit_code,notes" > "${CSV}"

############################
# Helpers
############################
run_one_bench() {
  local visible="$1"       # CUDA_VISIBLE_DEVICES value (GPU index or "")
  local gpu_label="$2"     # label for CSV (index or 'cpu0')
  local gpu_name="$3"
  local model="$4"
  local ngl="$5"
  local batch="$6"

  local base="$(basename "$model")"
  local runlog="${LOG_DIR}/bench_${gpu_label//\//-}_${base//[^A-Za-z0-9_.-]/_}_ngl${ngl}_b${batch}.log"
  local runner="llama-bench"
  local ec=0
  local tokps=""

  # bind to single GPU if present
  if [[ "$gpu_label" != "cpu0" ]]; then
    export CUDA_VISIBLE_DEVICES="${visible}"
  else
    export CUDA_VISIBLE_DEVICES=""
  fi

  # prefer llama-bench (more stable output)
  set +e
  timeout -k 5 "${RUN_TIMEOUT}" \
    "${LLAMA_BENCH}" \
      -m "${model}" \
      -t "${THREADS}" \
      -ngl "${ngl}" \
      -p "${CTX}" \
      -n "${NPRED}" \
      -b "${batch}" \
      --no-warmup \
      > "${runlog}" 2>&1
  ec=$?
  set -e

  if [[ $ec -ne 0 ]]; then
    # try main as fallback (short gen)
    runner="main"
    set +e
    timeout -k 5 "${RUN_TIMEOUT}" \
      "${LLAMA_MAIN}" \
        -m "${model}" \
        -t "${THREADS}" \
        -ngl "${ngl}" \
        -c "${CTX}" \
        -n "${NPRED}" \
        -b "${batch}" \
        -p "Benchmark test. Please ignore." \
        --log-disable \
        > "${runlog}" 2>&1
    ec=$?
    set -e
  fi

  # parse tokens/sec from the log
  # llama-bench typical: perf_throughput_tokens_per_second=XX.XX
  tokps="$(grep -Eo 'tokens[_ ]per[_ ]second[= :]*[0-9]+(\.[0-9]+)?' "${runlog}" | tail -n1 | awk -F'[= ]' '{print $NF}' || true)"
  if [[ -z "${tokps}" ]]; then
    # main often prints "... (XX.XX tok/s)"
    tokps="$(grep -Eo '([0-9]+(\.[0-9]+)?)\s*(tok/s|tokens/s|t/s)' "${runlog}" | tail -n1 | awk '{print $1}' || true)"
  fi
  [[ -z "${tokps}" ]] && tokps="NA"

  local ts_now
  ts_now="$(date -Iseconds)"
  echo "${ts_now},${HOSTNAME},${gpu_label},${gpu_name//,/;},${base},${model},${ngl},${batch},${CTX},${NPRED},${tokps},${runner},${ec}," >> "${CSV}"

  # Return code to caller
  return "${ec}"
}

############################
# Main loop
############################
echo "== Running benchmarks =="
for i in "${!GPU_IDX[@]}"; do
  gpu_idx="${GPU_IDX[$i]}"
  gpu_name="${GPU_NAME[$i]}"
  echo "-- GPU ${gpu_idx}: ${gpu_name}"

  for model in "${MODELS[@]}"; do
    echo "   -> Model: $(basename "$model")"
    worked=0
    for ngl in ${NGL_TRY}; do
      # For CPU-only, force -ngl 0
      if [[ "${gpu_idx}" == "cpu0" && "${ngl}" != "0" ]]; then continue; fi

      for b in ${BATCH_LIST}; do
        echo "      ngl=${ngl} batch=${b} ..."
        if run_one_bench "${gpu_idx}" "${gpu_idx}" "${gpu_name}" "${model}" "${ngl}" "${b}"; then
          worked=1
        fi
      done
      # Optional: break early on first success of any batch for this ngl
      # (comment out next 2 lines if you want all permutations regardless)
      # if [[ "${worked}" -eq 1 ]]; then break; fi
    done

    if [[ "${worked}" -ne 1 ]]; then
      echo "      ! All attempts failed for ${model} on GPU ${gpu_idx}"
    fi
  done
done

############################
# Final summary
############################
{
  echo "=== llama.cpp Bench Summary @ ${HOSTNAME} ${TS} ==="
  echo "CSV: ${CSV}"
  echo
  echo "Top results by tokens/sec:"
  # header + top 15 by tok/s (numeric), skipping rows with NA
  # shellcheck disable=SC2002
  {
    echo "tokens_per_sec,gpu,model,ngl,batch,ctx,npred,runner"
    awk -F',' 'NR>1 && $11!="NA" {print $11","$3","$5","$7","$8","$9","$10","$12}' "${CSV}" \
      | sort -t',' -k1,1gr \
      | head -n 15
  } | column -t -s','
  echo
  echo "Per-model bests:"
  # pick best per model path
  awk -F',' 'NR>1 && $11!="NA" {key=$6; if(!(key in best) || $11>best[key]){best[key]=$11; row[$0]=$0}} END {for (k in best){print best[k]","k}}' "${CSV}" \
    | sort -t',' -k1,1gr \
    | awk -F',' '{printf "%8s  %s\n",$1,$2}'
} | tee "${SUMMARY}"

echo "✔ DONE. CSV: ${CSV}"
echo "✔ DONE. Summary: ${SUMMARY}"

