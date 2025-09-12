#!/usr/bin/env bash
# triton-benchmark.sh — apples-to-apples wrapper for TRT-LLM/Triton (OpenAI-compatible server)
set -euo pipefail

########## CONFIG (override with env) ##########################################
LOG_DIR="${LOG_DIR:-/FuZe/logs}"
PORT_BASE="${PORT_BASE:-8500}"
TIMEOUT_READY="${TIMEOUT_READY:-150}"
TIMEOUT_GEN="${TIMEOUT_GEN:-90}"
VERBOSE="${VERBOSE:-1}"

# Models: a list of logical model IDs you want to test.
# For each, set ENGINE_DIR_<SAFE_NAME> (or MODEL_ARGS_<SAFE_NAME>) envs to feed your launch cmd.
TRITON_MODELS="${TRITON_MODELS:-deepseek-r1-70b llama4-16x17b llama4-128x17b}"

# REQUIRED: launch command template that starts an OpenAI-style server.
# Must accept: ${PORT} and any model-specific vars you define (e.g., ${ENGINE_DIR}).
# GPU binding is done by CUDA_VISIBLE_DEVICES outside the command.
TRITON_OPENAI_CMD="${TRITON_OPENAI_CMD:-}"

# Optional per-model precision/notes to embed in CSV (e.g., precision=fp16)
declare -A MODEL_NOTES
# Example (uncomment and adapt):
# MODEL_NOTES[deepseek-r1-70b]='precision=fp16'
# MODEL_NOTES[llama4-16x17b]='precision=fp16'
# MODEL_NOTES[llama4-128x17b]='precision=fp8'
################################################################################

c_bold="\033[1m"; c_red="\033[31m"; c_green="\033[32m"; c_yellow="\033[33m"; c_reset="\033[0m"
log(){ echo -e "$*"; }
info(){ [ "${VERBOSE}" -ne 0 ] && echo -e "${c_bold}==${c_reset} $*"; }
ok(){ echo -e "${c_green}✔${c_reset} $*"; }
warn(){ echo -e "${c_yellow}!${c_reset} $*"; }
err(){ echo -e "${c_red}✖${c_reset} $*" >&2; }

need(){ command -v "$1" >/dev/null 2>&1 || { err "Missing dependency: $1"; exit 1; }; }
need nvidia-smi; need awk; need sed; need curl; need jq; need timeout; need date; need bash

HOST="$(hostname -s 2>/dev/null || hostname)"
TS="$(date +%Y%m%d_%H%M%S)"

mkdir -p "${LOG_DIR}" 2>/dev/null || true
[ -w "${LOG_DIR}" ] || { LOG_DIR="./logs"; mkdir -p "${LOG_DIR}"; warn "Using ${LOG_DIR} fallback."; }
CSV_FILE="${LOG_DIR}/triton_bench_${TS}.csv"
SUMMARY_FILE="${LOG_DIR}/${HOST}-triton-${TS}.benchmark"

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

safe_name(){ echo "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_' ; }

bench_one(){ # gpu_idx model_id
  local gpu="$1" mid="$2"
  [ -z "${TRITON_OPENAI_CMD}" ] && { warn "TRITON_OPENAI_CMD not set; skipping ${mid}"; return 1; }

  local row idx uuid name mem label devs port pid
  row="$(gpu_table | awk -F',' -v I="$gpu" '$1==I{print;exit}')"
  [ -z "$row" ] && { warn "GPU idx $gpu not found"; return 1; }
  IFS=',' read -r idx uuid name mem <<<"$row"
  label="$(pick_label "$name")"
  devs="$gpu"
  port=$((PORT_BASE + gpu))

  # Per-model variables
  local sname; sname="$(safe_name "$mid")"
  # Allow user to export ENGINE_DIR_<SAFE_NAME> etc.
  local ENGINE_DIR_VAR="ENGINE_DIR_${sname}"
  local MODEL_ARGS_VAR="MODEL_ARGS_${sname}"
  local ENGINE_DIR="${!ENGINE_DIR_VAR:-}"
  local MODEL_ARGS="${!MODEL_ARGS_VAR:-}"
  local NOTES="${MODEL_NOTES[$mid]:-}"

  # Compose launch command
  # shellcheck disable=SC2001,SC2086
  local cmd; cmd="$(echo "${TRITON_OPENAI_CMD}" \
    | sed "s|\${PORT}|${port}|g" \
    | sed "s|\${ENGINE_DIR}|${ENGINE_DIR}|g" \
    | sed "s|\${MODEL_ARGS}|${MODEL_ARGS}|g")"

  info "Starting TRT-LLM/Triton OpenAI server on GPU${gpu} (${name}) model=${mid} port=${port}"
  info "CMD: ${cmd}"
  set +e
  CUDA_VISIBLE_DEVICES="${gpu}" bash -lc "${cmd} > /tmp/triton_${port}.log 2>&1 & echo \$!" >/tmp/triton_${port}.pid
  pid="$(cat /tmp/triton_${port}.pid || true)"
  set -e
  [ -z "${pid}" ] && { warn "Failed to start server for ${mid} on GPU${gpu}"; return 1; }
  trap "kill -9 ${pid} >/dev/null 2>&1 || true" EXIT

  if ! wait_ready "http://127.0.0.1:${port}"; then
    warn "Server not ready on ${port} for ${mid}"
    kill -9 "${pid}" >/dev/null 2>&1 || true
    trap - EXIT
    return 1
  fi

  local prompt="Write ok repeatedly for benchmarking."
  local start_ns end_ns dt_s ctok tokps
  start_ns="$(date +%s%N)"
  set +e
  resp="$(timeout "${TIMEOUT_GEN}"s curl -fsS -H 'Content-Type: application/json' \
    -d "$(jq -n --arg p "$prompt" --argjson max 256 '{model:"any",messages:[{role:"user",content:$p}],temperature:0,max_tokens:$max}')" \
    "http://127.0.0.1:${port}/v1/chat/completions" || true)"
  end_ns="$(date +%s%N)"
  set -e
  dt_s="$(awk -v a="$start_ns" -v b="$end_ns" 'BEGIN{printf("%.3f",(b-a)/1e9)}')"

  ctok="$(echo "${resp:-}" | jq -r '.usage.completion_tokens // 0' 2>/dev/null || echo 0)"
  [ -z "${ctok}" ] && ctok=0
  tokps="$(awk -v t="$ctok" -v s="$dt_s" 'BEGIN{ if(s<=0){print "0.00"} else {printf("%.2f", t/s)} }')"

  local tag="tp=1"   # assume single-GPU apples-to-apples
  local extra="{\"notes\":\"${NOTES}\"}"
  echo "$(date -Iseconds),triton,127.0.0.1:${port},${mid},${tag},${label},${devs},1024,32,256,${extra},${tokps},${name},${uuid},${mem%% MiB}" >> "${CSV_FILE}"
  ok "tok/s=${tokps} (comp_tokens=${ctok}, dt=${dt_s}s)"

  kill -9 "${pid}" >/dev/null 2>&1 || true
  trap - EXIT
  echo "$tokps"
}

main(){
  echo -e "${c_bold}== Triton / TensorRT-LLM apples-to-apples benchmark ==${c_reset}"
  echo "Models: ${TRITON_MODELS}"
  echo "TRITON_OPENAI_CMD: ${TRITON_OPENAI_CMD:-<unset>}"
  echo "CSV: ${CSV_FILE}"

  if [ -z "${TRITON_OPENAI_CMD}" ]; then
    err "TRITON_OPENAI_CMD is not set. Example:"
    echo "  export TRITON_OPENAI_CMD='python3 -m tensorrt_llm.runtime.server --engine_dir \${ENGINE_DIR} --port \${PORT} --host 127.0.0.1'"
    exit 1
  fi

  mapfile -t gpus < <(gpu_table | awk -F',' '{print $1}')
  [ ${#gpus[@]} -eq 0 ] && { err "No NVIDIA GPUs found"; exit 1; }

  for mid in ${TRITON_MODELS}; do
    for gpu in "${gpus[@]}"; do
      tokps="$(bench_one "$gpu" "$mid" || echo "0.00")"
      echo "${HOST},triton,${mid},GPU${gpu},best=${tokps}" >> "${SUMMARY_FILE}.raw"
    done
  done

  {
    echo "=== Final Summary @ ${HOST} ${TS} (triton) ==="
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
      | awk -F',' '{printf "  %-9s %-20s %-8s %6.2f tok/s  (%s)\n",$2,$4,$6,$12,$11}'
  } | tee "${SUMMARY_FILE}"

  ok "DONE. CSV: ${CSV_FILE}"
  ok "DONE. Summary: ${SUMMARY_FILE}"
}
main "$@"

