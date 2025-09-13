#!/usr/bin/env bash
# vllm-benchmark.sh
# A/B serve-and-bench for vLLM OpenAI-compatible server.
# - Spawns two vLLM servers bound to specific GPUs (CUDA_VISIBLE_DEVICES=GPU_UUID)
# - Bench via /v1/completions; compute tok/s = completion_tokens / wall_time
# - Same CSV schema as other stacks

set -euo pipefail

########## PATH ROOTS ##########################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${LOG_DIR:-${ROOT_DIR}/logs}"
mkdir -p "$LOG_DIR"

########## CONFIG (override with env) ##########################################
PORT_A="${PORT_A:-11435}"
PORT_B="${PORT_B:-11436}"

PYTHON_BIN="${PYTHON_BIN:-python3}"

# Models (must be HF names or local dirs that vLLM can load)
# Override via VLLM_MODEL_<alias> env (non-alnum -> underscores) or set VLLM_MODELS array directly.
MODELS=(
  "llama4:16x17b|llama4-16x17b|${VLLM_MODEL_llama4_16x17b:-meta-llama/Llama-3.1-8B-Instruct}"
  "deepseek-r1:70b|deepseek-r1-70b|${VLLM_MODEL_deepseek_r1_70b:-deepseek-ai/DeepSeek-R1-Distill-Qwen-32B}"
  "llama4:128x17b|llama4-128x17b|${VLLM_MODEL_llama4_128x17b:-meta-llama/Llama-3.1-70B-Instruct}"
)

BENCH_NUM_CTX="${BENCH_NUM_CTX:-}"
if [ -n "$BENCH_NUM_CTX" ]; then CTX="$BENCH_NUM_CTX"; else CTX="${CTX:-4096}"; fi  # --max-model-len
BATCH="${BATCH:-16}"               # request batch not used; vLLM batches internally
PRED="${PRED:-256}"                # n tokens to generate per request
TEMPERATURE="${TEMPERATURE:-0.0}"
DTYPE="${DTYPE:-float16}"          # float16|bfloat16|auto
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.90}"

EXHAUSTIVE="${EXHAUSTIVE:-0}"      # kept for symmetry; vLLM has fewer toggles
VERBOSE="${VERBOSE:-1}"

MATCH_GPU_A="${MATCH_GPU_A:-5090}"
MATCH_GPU_B="${MATCH_GPU_B:-3090 Ti}"

########## OUTPUT ##############################################################
HOSTNAME_NOW="$(hostname -s 2>/dev/null || hostname)"
TS="$(date +%Y%m%d_%H%M%S)"
CSV_FILE="${LOG_DIR}/vllm_bench_${TS}.csv"
SUMMARY_FILE="${LOG_DIR}/${HOSTNAME_NOW}-${TS}.benchmark"

########## UTILS ###############################################################
c_bold="\033[1m"; c_red="\033[31m"; c_green="\033[32m"; c_yellow="\033[33m"; c_reset="\033[0m"
log(){ echo -e "$*"; }
info(){ [ "${VERBOSE}" -ne 0 ] && echo -e "${c_bold}==${c_reset} $*"; }
ok(){ echo -e "${c_green}✔${c_reset} $*"; }
warn(){ echo -e "${c_yellow}!${c_reset} $*"; }
err(){ echo -e "${c_red}✖${c_reset} $*" >&2; }

need(){ command -v "$1" >/dev/null 2>&1 || { err "Missing dependency: $1"; exit 1; }; }
need curl; need jq; need awk; need sed; need nvidia-smi; need "${PYTHON_BIN}"

gpu_table(){ nvidia-smi --query-gpu=index,uuid,name,memory.total --format=csv,noheader | sed 's/, /,/g'; }
normalize_gpu_label(){
  local raw="$1" s
  s="$(echo "$raw" | tr '[:upper:]' '[:lower:]')"
  s="$(echo "$s" | sed -E 's/(nvidia|geforce|rtx)//g')"
  s="$(echo "$s" | tr -cd '[:alnum:] \n' | tr -s ' ')"
  s="$(echo "$s" | sed -E 's/ ti$/ti/; s/ super$/super/; s/ //g')"
  echo "nvidia-$s"
}
pick_uuid_by_name_substr(){
  local needle="$1"
  gpu_table | while IFS=',' read -r _idx uuid name _mem; do
    echo "$name" | grep -qi "$needle" && { echo "$uuid"; return 0; }
  done
}
discover_uuid_pair(){
  local all; all="$(gpu_table)"
  local ua ub
  ua="$(pick_uuid_by_name_substr "$MATCH_GPU_A" || true)"
  ub="$(pick_uuid_by_name_substr "$MATCH_GPU_B" || true)"
  if [ -z "$ua" ] || [ -z "$ub" ] || [ "$ua" = "$ub" ]; then
    warn "GPU name match failed/identical — falling back to index order."
    ua="$(echo "$all" | awk -F',' 'NR==1{print $2}')"
    ub="$(echo "$all" | awk -F',' 'NR==2{print $2}')"
  fi
  echo "$ua,$ub"
}
gpu_label_for_uuid(){
  local uuid="$1"
  local row; row="$(gpu_table | awk -F',' -v u="$uuid" '$2==u{print $0}')"
  local _idx u name mem; IFS=',' read -r _idx u name mem <<<"$row"
  normalize_gpu_label "$name"
}

wait_api(){
  local ep="$1" secs="${2:-90}" t=0
  while [ "$t" -lt "$secs" ]; do
    curl -fsS --max-time 1 "http://${ep}/v1/models" >/dev/null 2>&1 && return 0
    sleep 1; t=$((t+1))
  done
  return 1
}

start_vllm(){
  local uuid="$1" port="$2" model="$3"
  local logf="${LOG_DIR}/vllm_${port}_${TS}.log"
  CUDA_VISIBLE_DEVICES="$uuid" nohup "${PYTHON_BIN}" -m vllm.entrypoints.openai.api_server \
    --host 127.0.0.1 --port "$port" \
    --model "$model" \
    --dtype "$DTYPE" \
    --max-model-len "$CTX" \
    --gpu-memory-utilization "$GPU_MEM_UTIL" \
    >"$logf" 2>&1 &
  echo $!
}

stop_proc(){ local pid="$1"; [ -n "$pid" ] && kill -9 "$pid" >/dev/null 2>&1 || true; }

bench_once(){ # ep base_tag variant_label model_name gpu_lbl
  local ep="$1" base="$2" vlabel="$3" mname="$4" gpu_lbl="$5"
  local sfx="X"; [ "${ep##*:}" = "$PORT_A" ] && sfx="A"; [ "${ep##*:}" = "$PORT_B" ] && sfx="B"

  local prompt="Write 'ok' repeatedly."
  local req="$(jq -n --arg m "$mname" --arg p "$prompt" --argjson n "$PRED" --argjson t "$TEMPERATURE" '{model:$m, prompt:$p, max_tokens:$n, temperature:$t}')"

  local t0 t1 elapsed tokps ctoks
  t0=$(date +%s%N)
  local out; out="$(curl -fsS -H 'Content-Type: application/json' -d "$req" "http://${ep}/v1/completions" 2>/dev/null || true)"
  t1=$(date +%s%N)

  if [ -z "$out" ]; then
    warn "[bench] ${sfx}  ${mname} -> no data (timeout/error)"
    return 1
  fi

  ctoks="$(echo "$out" | jq -r '.usage.completion_tokens // 0')"
  elapsed="$(awk -v t0="$t0" -v t1="$t1" 'BEGIN{printf "%.3f", (t1-t0)/1e9}')"
  if [ "$elapsed" = "0.000" ]; then tokps="0.00"; else tokps="$(awk -v n="$ctoks" -v s="$elapsed" 'BEGIN{printf "%.2f", (s<=0?0:n/s)}')"; fi

  echo "$(date -Iseconds),$ep,proc,$sfx,$base,$vlabel,$mname,default,$CTX,$BATCH,$PRED,$tokps,${gpu_lbl},,,," >>"$CSV_FILE"
  ok "[bench] ${sfx}  ${mname}  ->  ${tokps} tok/s (ctx=$CTX, max_tokens=$PRED, dtype=$DTYPE)"
}

##################################### MAIN #####################################
echo "ts,endpoint,unit,suffix,base_model,variant_label,model_tag,num_gpu,num_ctx,batch,num_predict,tokens_per_sec,gpu_label,gpu_name,gpu_uuid,gpu_mem_mib" >"$CSV_FILE"

echo -e "${c_bold}== vLLM serve + bench ==${c_reset}"
echo "LOGS       : $LOG_DIR"
echo "CSV        : $CSV_FILE"
echo

uuids="$(discover_uuid_pair)"
UUID_A="${UUID_A:-${uuids%,*}}"
UUID_B="${UUID_B:-${uuids#*,}}"
GLABEL_A="$(gpu_label_for_uuid "$UUID_A")"
GLABEL_B="$(gpu_label_for_uuid "$UUID_B")"

echo "GPU A UUID : $UUID_A  ($GLABEL_A)"
echo "GPU B UUID : $UUID_B  ($GLABEL_B)"
echo

pids=()
trap 'for p in "${pids[@]:-}"; do stop_proc "$p"; done' EXIT

for entry in "${MODELS[@]}"; do
  base="${entry%%|*}"
  rest="${entry#*|}"
  alias_base="${rest%%|*}"
  model_name="${rest#*|}"

  info "Model ${alias_base} -> ${model_name}"

  # A
  pid="$(start_vllm "$UUID_A" "$PORT_A" "$model_name")"; pids+=("$pid")
  if wait_api "127.0.0.1:${PORT_A}" 120; then
    bench_once "127.0.0.1:${PORT_A}" "$base" "base-as-is" "$model_name" "$GLABEL_A" || true
  else
    warn "A endpoint not ready for ${model_name}"
  fi
  stop_proc "$pid"; pids=("${pids[@]:1}")

  # B
  pid="$(start_vllm "$UUID_B" "$PORT_B" "$model_name")"; pids+=("$pid")
  if wait_api "127.0.0.1:${PORT_B}" 120; then
    bench_once "127.0.0.1:${PORT_B}" "$base" "base-as-is" "$model_name" "$GLABEL_B" || true
  else
    warn "B endpoint not ready for ${model_name}"
  fi
  stop_proc "$pid"; pids=("${pids[@]:1}")
done

{
  echo "=== Final Summary @ ${HOSTNAME_NOW} ${TS} ==="
  echo "CSV: ${CSV_FILE}"
  echo
  echo "Top-5 runs overall (by tokens/sec) from CSV:"
  tail -n +2 "$CSV_FILE" | sort -t',' -k12,12gr | head -n5 \
    | awk -F',' '{printf "  %-2s %-18s %-28s %-14s %6.2f tok/s  (%s %s ngpu=%s)\n",$4,$5,$6,$13,$12,$1,$2,$8}'
} | tee "${SUMMARY_FILE}"

ok "DONE. CSV: ${CSV_FILE}"
ok "DONE. Summary: ${SUMMARY_FILE}"
