#!/usr/bin/env bash
# llama.cpp-benchmark.sh
# A/B serve-and-bench for llama.cpp server with local logs and CSV compatible with ust.sh
# - Starts two server instances bound to specific GPUs (via CUDA_VISIBLE_DEVICES=GPU_UUID)
# - Finds GGUF models by pattern or env-provided paths
# - Sweeps n-gpu-layers (NGL) values, reports tokens/sec from /completion timings
# - Writes logs/llamacpp_bench_<ts>.csv and a human summary

set -euo pipefail

########## PATH ROOTS ##########################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${LOG_DIR:-${ROOT_DIR}/logs}"
mkdir -p "$LOG_DIR"

# Auto-source Ollama-exported GGUF mappings if present
MODELS_ENV_FILE="${LLAMACPP_MODELS_ENV:-${SCRIPT_DIR}/models.env}"
if [ -f "$MODELS_ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$MODELS_ENV_FILE"
fi

########## CONFIG (override with env) ##########################################
PORT_A="${PORT_A:-11435}"                 # test instance A (GPU-A)
PORT_B="${PORT_B:-11436}"                 # test instance B (GPU-B)

# llama.cpp server binary (prefer /usr/local/bin/llama-server; fallback to 'server' on PATH)
LLAMACPP_BIN="${LLAMACPP_BIN:-}"
if [ -z "${LLAMACPP_BIN}" ]; then
  if command -v llama-server >/dev/null 2>&1; then
    LLAMACPP_BIN="$(command -v llama-server)"
  elif command -v server >/dev/null 2>&1; then
    LLAMACPP_BIN="$(command -v server)"
  else
    echo "✖ cannot find llama.cpp server binary (llama-server or server). Set LLAMACPP_BIN=/path/to/server" >&2
    exit 1
  fi
fi

# Where your GGUF files live. We’ll search this folder for patterns based on alias names.
MODEL_DIR="${MODEL_DIR:-/FuZe/models/gguf}"

# Models to bench (alias and a loose filename pattern).
# We try to find the first *.gguf file in MODEL_DIR matching the pattern.
# Override exact files via envs:
#   LLAMACPP_PATH_llama4_16x17b=/abs/path/model.gguf (alias -> env key uses non-alnum => underscores)
MODELS=(
  "llama4:16x17b|llama4-16x17b|llama*16*17b*.*gguf"
  "deepseek-r1:70b|deepseek-r1-70b|deepseek*70b*.*gguf"
  "llama4:128x17b|llama4-128x17b|llama*128*17b*.*gguf"
)

# Sweep of NGL (n-gpu-layers). “-1” means auto/offload all layers.
# Feel free to trim this for faster runs.
NGL_CANDIDATES=${NGL_CANDIDATES:-"-1 64 48 32 24 16 0"}

# Bench params
BENCH_NUM_CTX="${BENCH_NUM_CTX:-}"
if [ -n "$BENCH_NUM_CTX" ]; then CTX="$BENCH_NUM_CTX"; else CTX="${CTX:-1024}"; fi
BATCH="${BATCH:-32}"
PRED="${PRED:-256}"
TEMPERATURE="${TEMPERATURE:-0.0}"

# Stop after first working NGL?
EXHAUSTIVE="${EXHAUSTIVE:-0}"
VERBOSE="${VERBOSE:-1}"

# GPU name substrings for A/B binding (fallback: first two GPUs by index)
MATCH_GPU_A="${MATCH_GPU_A:-5090}"
MATCH_GPU_B="${MATCH_GPU_B:-3090 Ti}"

########## OUTPUT ##############################################################
HOSTNAME_NOW="$(hostname -s 2>/dev/null || hostname)"
TS="$(date +%Y%m%d_%H%M%S)"
CSV_FILE="${LOG_DIR}/llamacpp_bench_${TS}.csv"
SUMMARY_FILE="${LOG_DIR}/${HOSTNAME_NOW}-${TS}.benchmark"

########## UTILS ###############################################################
c_bold="\033[1m"; c_red="\033[31m"; c_green="\033[32m"; c_yellow="\033[33m"; c_reset="\033[0m"
log(){ echo -e "$*"; }
info(){ [ "${VERBOSE}" -ne 0 ] && echo -e "${c_bold}==${c_reset} $*"; }
ok(){ echo -e "${c_green}✔${c_reset} $*"; }
warn(){ echo -e "${c_yellow}!${c_reset} $*"; }
err(){ echo -e "${c_red}✖${c_reset} $*" >&2; }

need(){ command -v "$1" >/dev/null 2>&1 || { err "Missing dependency: $1"; exit 1; }; }
need curl; need jq; need awk; need sed; need nvidia-smi

gpu_table(){ nvidia-smi --query-gpu=index,uuid,name,memory.total --format=csv,noheader | sed 's/, /,/g'; }

normalize_gpu_label(){
  # "NVIDIA GeForce RTX 3090 Ti" -> "nvidia-3090ti"
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
  local ep="$1" secs="${2:-60}" t=0
  while [ "$t" -lt "$secs" ]; do
    curl -fsS --max-time 1 "http://${ep}/health" >/dev/null 2>&1 && return 0
    # some builds expose /health, others respond on /completion quickly
    curl -fsS --max-time 1 -H 'Content-Type: application/json' \
      -d '{"prompt":"ping","n_predict":1,"stream":false}' \
      "http://${ep}/completion" >/dev/null 2>&1 && return 0
    sleep 1; t=$((t+1))
  done
  return 1
}

find_model_file(){
  local alias_base="$1" pattern="$2"
  # allow explicit override via env LLAMACPP_PATH_<alias_base with non-alnum -> underscores>
  local key="LLAMACPP_PATH_$(echo "$alias_base" | tr -c '[:alnum:]' '_')"
  local v="${!key:-}"
  if [ -n "$v" ] && [ -f "$v" ]; then echo "$v"; return 0; fi
  shopt -s nullglob
  local matches=("${MODEL_DIR}"/$pattern)
  shopt -u nullglob
  [ ${#matches[@]} -gt 0 ] && { echo "${matches[0]}"; return 0; }
  return 1
}

start_server(){
  local uuid="$1" port="$2" model_file="$3" ngl="$4"
  local logf="${LOG_DIR}/llamacpp_${port}_${TS}.log"
  CUDA_VISIBLE_DEVICES="$uuid" nohup "$LLAMACPP_BIN" \
    --model "$model_file" \
    --host 127.0.0.1 --port "$port" \
    --ctx-size "$CTX" --batch-size "$BATCH" \
    --n-gpu-layers "$ngl" \
    --parallel 1 \
    --no-mmap \
    >"$logf" 2>&1 &
  echo $!
}

stop_server(){
  local pid="$1"; [ -n "$pid" ] && kill -9 "$pid" >/dev/null 2>&1 || true
}

bench_once(){ # ep base_tag variant_label model_tag ngl gpu_lbl
  local ep="$1" base="$2" vlabel="$3" mtag="$4" ngl="$5" gpu_lbl="$6"
  local sfx="X"; [ "${ep##*:}" = "$PORT_A" ] && sfx="A"; [ "${ep##*:}" = "$PORT_B" ] && sfx="B"

  local prompt="Write 'ok' repeatedly."
  local out
  out="$(curl -fsS -H 'Content-Type: application/json' \
      -d "$(jq -n --arg p "$prompt" --argjson n "$PRED" --argjson t "$TEMPERATURE" '{prompt:$p, n_predict:$n, temperature:$t, stream:false}')" \
      "http://${ep}/completion" 2>/dev/null || true)"

  if [ -z "$out" ]; then
    warn "[bench] ${sfx}  ${mtag} -> no data (timeout/error)"
    return 1
  fi

  # Use timings if available; else fall back to usage-style estimation if present
  local n_tokens ms tokps
  n_tokens="$(echo "$out" | jq -r '.timings.predicted_n // .usage.completion_tokens // 0')"
  ms="$(echo "$out" | jq -r '.timings.predicted_ms // 0')"
  if [[ "$ms" != "0" ]]; then
    tokps="$(awk -v n="$n_tokens" -v m="$ms" 'BEGIN{ if(m<=0){print "0.00"} else { printf("%.2f", n/(m/1000.0)) } }')"
  else
    # no timings: treat as unknown
    tokps="0.00"
  fi

  echo "$(date -Iseconds),$ep,proc,$sfx,$base,$vlabel,$mtag,${ngl},$CTX,$BATCH,$PRED,$tokps,${gpu_lbl},,,," >>"$CSV_FILE"
  ok "[bench] ${sfx}  ${mtag}  ->  ${tokps} tok/s (ctx=$CTX, batch=$BATCH, ngl=${ngl})"
}

##################################### MAIN #####################################
echo "ts,endpoint,unit,suffix,base_model,variant_label,model_tag,num_gpu,num_ctx,batch,num_predict,tokens_per_sec,gpu_label,gpu_name,gpu_uuid,gpu_mem_mib" >"$CSV_FILE"

echo -e "${c_bold}== llama.cpp serve + bench ==${c_reset}"
echo "LOGS       : $LOG_DIR"
echo "CSV        : $CSV_FILE"
echo

# GPU bind
uuids="$(discover_uuid_pair)"
UUID_A="${UUID_A:-${uuids%,*}}"
UUID_B="${UUID_B:-${uuids#*,}}"
GLABEL_A="$(gpu_label_for_uuid "$UUID_A")"
GLABEL_B="$(gpu_label_for_uuid "$UUID_B")"

echo "GPU A UUID : $UUID_A  ($GLABEL_A)"
echo "GPU B UUID : $UUID_B  ($GLABEL_B)"
echo

pids=()
cleanup(){ for p in "${pids[@]:-}"; do stop_server "$p"; done; }
trap cleanup EXIT

for entry in "${MODELS[@]}"; do
  base="${entry%%|*}"
  rest="${entry#*|}"
  alias_base="${rest%%|*}"
  pattern="${rest#*|}"

  model_file="$(find_model_file "$alias_base" "$pattern" || true)"
  if [ -z "$model_file" ]; then
    warn "Model file not found for alias=${alias_base} in ${MODEL_DIR} (pattern: ${pattern}). Skipping."
    continue
  fi
  info "Using ${alias_base} -> ${model_file}"

  # A: base-as-is (ngl=0) then sweep
  pid_a="$(start_server "$UUID_A" "$PORT_A" "$model_file" 0)"; pids+=("$pid_a")
  if ! wait_api "127.0.0.1:${PORT_A}" 30; then
    warn "Server on :${PORT_A} not ready; skipping A for ${alias_base}"
  else
    bench_once "127.0.0.1:${PORT_A}" "$base" "base-as-is" "${alias_base}" "default" "$GLABEL_A" || true
  fi
  stop_server "$pid_a"; pids=("${pids[@]:1}")

  best_tokps="0.00"; best_label=""
  for ngl in $NGL_CANDIDATES; do
    info "A: trying ngl=${ngl} ..."
    pid_a="$(start_server "$UUID_A" "$PORT_A" "$model_file" "$ngl")"; pids+=("$pid_a")
    if wait_api "127.0.0.1:${PORT_A}" 30; then
      vname="${alias_base}-${GLABEL_A}-ngl${ngl}"
      tokps_line="$(bench_once "127.0.0.1:${PORT_A}" "$base" "optimized" "${vname}" "$ngl" "$GLABEL_A" || true)"
    fi
    stop_server "$pid_a"; pids=("${pids[@]:1}")
    if [ "$EXHAUSTIVE" = "0" ] && [ "${tokps_line:-0}" != "0.00" ]; then break; fi
  done

  # B: same sweep on second GPU
  pid_b="$(start_server "$UUID_B" "$PORT_B" "$model_file" 0)"; pids+=("$pid_b")
  if ! wait_api "127.0.0.1:${PORT_B}" 30; then
    warn "Server on :${PORT_B} not ready; skipping B for ${alias_base}"
  else
    bench_once "127.0.0.1:${PORT_B}" "$base" "base-as-is" "${alias_base}" "default" "$GLABEL_B" || true
  fi
  stop_server "$pid_b"; pids=("${pids[@]:1}")

  for ngl in $NGL_CANDIDATES; do
    info "B: trying ngl=${ngl} ..."
    pid_b="$(start_server "$UUID_B" "$PORT_B" "$model_file" "$ngl")"; pids+=("$pid_b")
    if wait_api "127.0.0.1:${PORT_B}" 30; then
      vname="${alias_base}-${GLABEL_B}-ngl${ngl}"
      bench_once "127.0.0.1:${PORT_B}" "$base" "optimized" "${vname}" "$ngl" "$GLABEL_B" || true
    fi
    stop_server "$pid_b"; pids=("${pids[@]:1}")
    if [ "$EXHAUSTIVE" = "0" ]; then break; fi
  done
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
