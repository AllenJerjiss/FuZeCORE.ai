#!/usr/bin/env bash
# vllm-benchmark.sh — apples-to-apples runner for vLLM (OpenAI server mode)
set -euo pipefail

########## CONFIG ##############################################################
LOG_DIR="${LOG_DIR:-/FuZe/logs}"
PORT_BASE="${PORT_BASE:-8300}"            # per-run port (offset by GPU index)
VLLM_MODELS=${VLLM_MODELS:-"meta-llama/Meta-Llama-3-8B-Instruct Qwen/Qwen2.5-7B-Instruct"}  # override me

# Inference shape / knobs
CTX="${CTX:-1024}"
PRED="${PRED:-256}"
TP_CANDIDATES="${TP_CANDIDATES:-1}"       # tensor-parallel sizes (single-GPU apples-to-apples -> 1)
TIMEOUT_READY="${TIMEOUT_READY:-120}"     # sec to wait for server readiness
TIMEOUT_GEN="${TIMEOUT_GEN:-90}"          # sec to wait for generation HTTP call
VERBOSE="${VERBOSE:-1}"
################################################################################

c_bold="\033[1m"; c_red="\033[31m"; c_green="\033[32m"; c_yellow="\033[33m"; c_reset="\033[0m"
log(){ echo -e "$*"; }
info(){ [ "${VERBOSE}" -ne 0 ] && echo -e "${c_bold}==${c_reset} $*"; }
ok(){ echo -e "${c_green}✔${c_reset} $*"; }
warn(){ echo -e "${c_yellow}!${c_reset} $*"; }
err(){ echo -e "${c_red}✖${c_reset} $*" >&2; }

need(){ command -v "$1" >/dev/null 2>&1 || { err "Missing dependency: $1"; exit 1; }; }
need python3; need nvidia-smi; need awk; need sed; need curl; need jq; need timeout; need date

HOST="$(hostname -s 2>/dev/null || hostname)"
TS="$(date +%Y%m%d_%H%M%S)"

mkdir -p "${LOG_DIR}" 2>/dev/null || true
[ -w "${LOG_DIR}" ] || { LOG_DIR="./logs"; mkdir -p "${LOG_DIR}"; warn "Using ${LOG_DIR} fallback."; }
CSV_FILE="${LOG_DIR}/vllm_bench_${TS}.csv"
SUMMARY_FILE="${LOG_DIR}/${HOST}-vllm-${TS}.benchmark"

echo "ts,framework,endpoint_or_pid,model_id,tag_or_variant,gpu_label,device_ids,num_ctx,batch,num_predict,extra_params,tokens_per_sec,gpu_name,gpu_uuid,gpu_mem_mib" > "${CSV_FILE}"

gpu_table(){ nvidia-smi --query-gpu=index,uuid,name,memory.total --format=csv,noheader | sed 's/, /,/g'; }
pick_label(){ local n="$(echo "$1" | tr 'A-Z' 'a-z')"; echo "$n" | grep -q "5090" && { echo "5090"; return; }; echo "$n" | grep -q "3090" && { echo "3090ti"; return; }; echo "$n" | sed -E 's/[^a-z0-9]+/-/g'; }

wait_ready(){
  local url="$1" t=0
  while [ $t -lt "${TIMEOUT_READY}" ]; do
    curl -fsS --max-time 2 "${url}/v1/models" >/dev/null 2>&1 && return 0
    sleep 1; t=$((t+1))
  done
  return 1
}

bench_one(){ # gpu_idx model tp
  local gpu="$1" model="$2" tp="$3"
  local row idx uuid name mem label devs port pid
  row="$(gpu_table | awk -F',' -v I="$gpu" '$1==I{print;exit}')"
  [ -z "$row" ] && { warn "GPU idx $gpu not found"; return 1; }
  IFS=',' read -r idx uuid name mem <<<"$row"
  label="$(pick_label "$name")"
  devs="$gpu"
  port=$((PORT_BASE + gpu))

  info "Starting vLLM on GPU${gpu} (${name}) model=${model} tp=${tp} port=${port}"
  set +e
  CUDA_VISIBLE_DEVICES="$gpu" \
  python3 -u -m vllm.entrypoints.openai.api_server \
    --host 127.0.0.1 --port "${port}" \
    --model "${model}" \
    --tensor-parallel-size "${tp}" \
    --dtype auto \
    --max-model-len "${CTX}" \
    >"/tmp/vllm_${port}.log" 2>&1 &
  pid=$!
  set -e
  # ensure cleanup
  trap "kill -9 ${pid} >/dev/null 2>&1 || true" EXIT

  if ! wait_ready "http://127.0.0.1:${port}"; then
    warn "vLLM server not ready on ${port}"; kill -9 "${pid}" >/dev/null 2>&1 || true; return 1
  fi

  local prompt="Write ok repeatedly for benchmarking."
  local start_ns end_ns dt_s ctok tokps
  start_ns="$(date +%s%N)"
  set +e
  resp="$(timeout "${TIMEOUT_GEN}"s curl -fsS -H 'Content-Type: application/json' \
    -d "$(jq -n --arg m "$model" --arg p "$prompt" --argjson max "$PRED" '{model:$m,messages:[{role:"user",content:$p}],temperature:0,max_tokens:$max}')" \
    "http://127.0.0.1:${port}/v1/chat/completions" || true)"
  end_ns="$(date +%s%N)"
  set -e
  dt_s="$(awk -v a="$start_ns" -v b="$end_ns" 'BEGIN{printf("%.3f",(b-a)/1e9)}')"

  ctok="$(echo "${resp:-}" | jq -r '.usage.completion_tokens // 0' 2>/dev/null || echo 0)"
  [ -z "${ctok}" ] && ctok=0
  tokps="$(awk -v t="$ctok" -v s="$dt_s" 'BEGIN{ if(s<=0){print "0.00"} else {printf("%.2f", t/s)} }')"

  local tag="tp=${tp}"
  local extra="{\"dtype\":\"auto\"}"
  echo "$(date -Iseconds),vllm,127.0.0.1:${port},${model},${tag},${label},${devs},${CTX},${BATCH},${PRED},${extra},${tokps},${name},${uuid},${mem%% MiB}" >> "${CSV_FILE}"
  ok "tok/s=${tokps} (comp_tokens=${ctok}, dt=${dt_s}s)"

  kill -9 "${pid}" >/dev/null 2>&1 || true
  trap - EXIT
  echo "$tokps"
}

main(){
  echo -e "${c_bold}== vLLM apples-to-apples benchmark ==${c_reset}"
  echo "Models: ${VLLM_MODELS}"
  echo "CSV: ${CSV_FILE}"

  mapfile -t gpus < <(gpu_table | awk -F',' '{print $1}')
  [ ${#gpus[@]} -eq 0 ] && { err "No NVIDIA GPUs found"; exit 1; }

  for model in ${VLLM_MODELS}; do
    for gpu in "${gpus[@]}"; do
      best="0.00"
      for tp in ${TP_CANDIDATES}; do
        tokps="$(bench_one "$gpu" "$model" "$tp" || echo "0.00")"
        awk -v a="$tokps" -v b="$best" 'BEGIN{exit !(a>b)}' && best="$tokps"
      done
      info "Best for GPU${gpu} on ${model}: ${best} tok/s"
      echo "${HOST},vllm,${model},GPU${gpu},best=${best}" >> "${SUMMARY_FILE}.raw"
    done
  done

  {
    echo "=== Final Summary @ ${HOST} ${TS} (vLLM) ==="
    echo "CSV: ${CSV_FILE}"
    echo
    if [ -s "${SUMMARY_FILE}.raw" ]; then
      echo "Best per (model,GPU):"
      column -t -s',' "${SUMMARY_FILE}.raw" 2>/dev/null || cat "${SUMMARY_FILE}.raw"
    else
      echo "No successful runs recorded."
    fi
    echo
    echo "Top-5 overall:"
    tail -n +2 "${CSV_FILE}" | sort -t',' -k12,12gr | head -n5 \
      | awk -F',' '{printf "  %-9s %-45s %-8s %6.2f tok/s  (ctx=%s pred=%s %s)\n",$2,$4,$6,$12,$8,$10,$11}'
  } | tee "${SUMMARY_FILE}"

  ok "DONE. CSV: ${CSV_FILE}"
  ok "DONE. Summary: ${SUMMARY_FILE}"
}
main "$@"

