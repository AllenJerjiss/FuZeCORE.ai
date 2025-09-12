#!/usr/bin/env bash
# ollama-benchmark.sh
# One-at-a-time model tuning + benchmarking with an always-on puller on :11434
# Variants are named with a normalized GPU label: <alias>-nvidia-<gpu>-ng<NUM>

set -euo pipefail

########## PATH ROOTS ##########################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${LOG_DIR:-${ROOT_DIR}/logs}"
mkdir -p "$LOG_DIR"

########## CONFIG (override with env) ##########################################
PERSISTENT_PORT="${PERSISTENT_PORT:-11434}"  # always-on downloader, never killed
TEST_PORT_A="${TEST_PORT_A:-11435}"          # test instance A (GPU-A)
TEST_PORT_B="${TEST_PORT_B:-11436}"          # test instance B (GPU-B)

# Your persistent Ollama store (what :11434 uses)
# (you said models live here)
OLLAMA_MODELS_DIR="${OLLAMA_MODELS_DIR:-/FuZe/models/ollama}"

# Base models to try, plus a short alias for optimized variants
MODELS=(
  "llama4:16x17b|llama4-16x17b"
  "deepseek-r1:70b|deepseek-r1-70b"
  "llama4:128x17b|llama4-128x17b"
)

# num_gpu sweep high->low
NUM_GPU_CANDIDATES="${NUM_GPU_CANDIDATES:-80 72 64 56 48 40 32 24 16}"

# Bench params
CTX="${CTX:-1024}"
BATCH="${BATCH:-32}"
PRED="${PRED:-256}"

# 0 = stop after first working num_gpu; 1 = bench all working
EXHAUSTIVE="${EXHAUSTIVE:-0}"
VERBOSE="${VERBOSE:-1}"

# Timeouts (seconds)
WAIT_API_SECS="${WAIT_API_SECS:-60}"
TIMEOUT_GEN="${TIMEOUT_GEN:-90}"   # more generous for big models
TIMEOUT_TAGS="${TIMEOUT_TAGS:-10}"

SERVICE_HOME="${SERVICE_HOME:-/root}"

# GPU name substrings we try to bind to A/B:
MATCH_GPU_A="${MATCH_GPU_A:-5090}"
MATCH_GPU_B="${MATCH_GPU_B:-3090 Ti}"

################################################################################

readonly OLLAMA_BIN="/usr/local/bin/ollama"
readonly HOSTNAME_NOW="$(hostname -s 2>/dev/null || hostname)"
readonly TS="$(date +%Y%m%d_%H%M%S)"
readonly CSV_FILE="${LOG_DIR}/ollama_bench_${TS}.csv"
readonly SUMMARY_FILE="${LOG_DIR}/${HOSTNAME_NOW}-${TS}.benchmark"
readonly CREATE_LOG="${LOG_DIR}/ollama_create_${TS}.log"
readonly PULL_FROM="127.0.0.1:${PERSISTENT_PORT}"
ENDPOINTS=("127.0.0.1:${TEST_PORT_A}" "127.0.0.1:${TEST_PORT_B}")

c_bold="\033[1m"; c_red="\033[31m"; c_green="\033[32m"; c_yellow="\033[33m"; c_reset="\033[0m"
log(){ echo -e "$*"; }
info(){ [ "$VERBOSE" -ne 0 ] && echo -e "${c_bold}==${c_reset} $*"; }
ok(){ echo -e "${c_green}✔${c_reset} $*"; }
warn(){ echo -e "${c_yellow}!${c_reset} $*"; }
err(){ echo -e "${c_red}✖${c_reset} $*" >&2; }
need(){ command -v "$1" >/dev/null 2>&1 || { err "Missing dependency: $1"; exit 1; }; }

mkdir -p "$OLLAMA_MODELS_DIR"
need curl; need jq; need awk; need sed; need systemctl; need nvidia-smi
if ! command -v lsof >/dev/null 2>&1 && ! command -v ss >/dev/null 2>&1; then
  warn "Neither lsof nor ss found — port cleanup may be limited."
fi

# CSV header
echo "ts,endpoint,unit,suffix,base_model,variant_label,model_tag,num_gpu,num_ctx,batch,num_predict,tokens_per_sec,gpu_label,gpu_name,gpu_uuid,gpu_mem_mib" >"$CSV_FILE"

json_last_line(){ grep -E '"done":\s*true' | tail -n1; }
gpu_table(){ nvidia-smi --query-gpu=index,uuid,name,memory.total --format=csv,noheader | sed 's/, /,/g'; }

calc_tokps(){ awk -v ec="$1" -v ed="$2" 'BEGIN{ if(ed<=0){print "0.00"} else {printf("%.2f", ec/(ed/1e9))} }'; }

curl_tags(){ local ep="$1"; curl -fsS --max-time "$TIMEOUT_TAGS" "http://${ep}/api/tags" || return 1; }

# Build payload with jq (safe quoting), then POST
curl_gen(){
  local ep="$1" model="$2" opts_json="$3" prompt="$4" to="$5"
  local payload
  payload="$(jq -n --arg m "$model" --arg p "$prompt" --argjson o "$opts_json" '{model:$m, options:$o, prompt:$p}')"
  curl -sS --max-time "$to" -H 'Content-Type: application/json' -d "$payload" "http://${ep}/api/generate" || return 1
}

# Small helper: print a key from systemd unit Environment= line
service_env(){
  local unit="$1" key="$2"
  systemctl show "$unit" -p Environment 2>/dev/null | tr '\n' ' ' | sed -nE "s/.*${key}=([^ ]+).*/\1/p"
}

unit_for_ep(){
  local ep="$1" port="${ep##*:}"
  case "$port" in
    "$TEST_PORT_A") echo "ollama-test-a.service";;
    "$TEST_PORT_B") echo "ollama-test-b.service";;
    "$PERSISTENT_PORT") echo "ollama-persist.service";;
    *) echo "ollama-unknown-${port}.service";;
  esac
}
suffix_for_ep(){
  local ep="$1" port="${ep##*:}"
  case "$port" in "$TEST_PORT_A") echo "A";; "$TEST_PORT_B") echo "B";; *) echo "X";; esac
}

kill_port_listener(){
  local port="$1" pid=""
  if command -v lsof >/dev/null 2>&1; then
    pid="$(lsof -iTCP -sTCP:LISTEN -P 2>/dev/null | awk -v p=":${port}" '$9 ~ p {print $2}' | head -n1 || true)"
  elif command -v ss >/dev/null 2>&1; then
    pid="$(ss -ltnp 2>/dev/null | awk -v p=":${port}" '$4 ~ p {print $7}' | sed -E 's/.*pid=([0-9]+).*/\1/' | head -n1 || true)"
  fi
  if [ -n "${pid:-}" ]; then
    warn "Killing listener PID ${pid} on :${port}"
    kill -9 "$pid" || true
  fi
}

wait_api(){
  local ep="$1" secs="${2:-$WAIT_API_SECS}" t=0
  while [ "$t" -lt "$secs" ]; do
    curl -fsS --max-time 1 "http://${ep}/api/tags" >/dev/null 2>&1 && return 0
    sleep 1; t=$((t+1))
  done
  return 1
}

# Return: "name,uuid,memMiB" (or ",," if unknown)
offload_triplet(){
  local unit="$1" row uuid
  uuid="$(systemctl show "$unit" -p Environment 2>/dev/null | tr '\n' ' ' | sed -E 's/.*CUDA_VISIBLE_DEVICES=([^ ]+).*/\1/')"
  [ -z "${uuid:-}" ] && { echo ",,"; return 0; }
  row="$(gpu_table | grep "$uuid" || true)"
  [ -z "$row" ] && { echo ",,"; return 0; }
  IFS=',' read -r idx u name mem <<<"$row"
  echo "$name,$u,${mem%% MiB}"
}

normalize_gpu_label(){
  # Input: raw GPU name; Output: nvidia-<digits>[ti|super]...
  # Examples:
  #  "NVIDIA GeForce RTX 5090"     -> nvidia-5090
  #  "NVIDIA GeForce RTX 3090 Ti"  -> nvidia-3090ti
  local raw="$1"
  local s
  s="$(echo "$raw" | tr '[:upper:]' '[:lower:]')"
  # strip vendor and common series words
  s="$(echo "$s" | sed -E 's/(nvidia|geforce|rtx)//g')"
  # collapse whitespace, remove non-alnum
  s="$(echo "$s" | tr -cd '[:alnum:] \n' | tr -s ' ')"
  # join words, force " ti" -> "ti", same for " super"
  s="$(echo "$s" | sed -E 's/ ti$/ti/; s/ super$/super/; s/ //g')"
  echo "nvidia-$s"
}

gpu_label_for_ep(){
  local ep="$1" unit lbl name uuid mem
  unit="$(unit_for_ep "$ep")"
  IFS=',' read -r name uuid mem <<<"$(offload_triplet "$unit")"
  if [ -z "${name:-}" ]; then
    echo "nvidia-unknown"
  else
    normalize_gpu_label "$name"
  fi
}

have_model(){
  local tag="$1"
  OLLAMA_HOST="http://${PULL_FROM}" "$OLLAMA_BIN" list 2>/dev/null | awk '{print $1}' | grep -Fxq "$tag"
}
pull_if_missing(){
  local base="$1"
  if have_model "$base"; then
    info "Base ${base} present on ${PULL_FROM}"
  else
    info "Pulling ${base} via ${PULL_FROM}"
    OLLAMA_HOST="http://${PULL_FROM}" "$OLLAMA_BIN" pull "$base" || warn "pull of $base failed"
  fi
}

write_unit(){
  local name="$1" listen="$2" uuid_env="$3" desc="$4"
  cat >/etc/systemd/system/"$name" <<EOF
[Unit]
Description=${desc}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HOME=${SERVICE_HOME}
Environment=OLLAMA_HOST=127.0.0.1:${listen}
Environment=OLLAMA_MODELS=${OLLAMA_MODELS_DIR}
${uuid_env:+Environment=CUDA_VISIBLE_DEVICES=${uuid_env}}
ExecStart=${OLLAMA_BIN} serve
ExecStartPre=/usr/bin/mkdir -p ${OLLAMA_MODELS_DIR}
WorkingDirectory=${OLLAMA_MODELS_DIR}
Restart=always
RestartSec=2s
LimitNOFILE=1048576
User=root

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

restart_ep(){
  local ep="$1" unit port
  unit="$(unit_for_ep "$ep")"; port="${ep##*:}"
  if [ "$port" != "$PERSISTENT_PORT" ]; then
    systemctl stop "$unit" >/dev/null 2>&1 || true
    kill_port_listener "$port"
  fi
  systemctl start "$unit" || true
}

pick_uuid_by_name_substr(){
  local needle="$1"
  gpu_table | while IFS=',' read -r idx uuid name mem; do
    echo "$name" | grep -qi "$needle" && { echo "$uuid"; return 0; }
  done
}

# Wait until a created variant becomes visible on a test endpoint.
# Restarts the test unit once if not seen halfway through the wait.
wait_variant_visible(){
  local ep="$1" variant="$2" secs="${3:-12}" i=0
  local unit; unit="$(unit_for_ep "$ep")"
  while [ "$i" -lt "$secs" ]; do
    if curl -fsS "http://${ep}/api/tags" | jq -r '.models[].name' | grep -Fxq "$variant"; then
      return 0
    fi
    if [ "$i" -eq $((secs/2)) ]; then
      systemctl restart "$unit" || true
      wait_api "$ep" || true
    fi
    sleep 1
    i=$((i+1))
  done
  return 1
}

prepare_services(){
  info "Preparing directories and services"
  mkdir -p "$OLLAMA_MODELS_DIR" "$LOG_DIR"

  local all; all="$(gpu_table)"
  log "$(echo "$all" | sed 's/^/GPU: /')"

  # Is a daemon already on :11434?
  if curl -fsS "http://127.0.0.1:${PERSISTENT_PORT}/api/tags" >/dev/null 2>&1; then
    info "Using existing Ollama on :${PERSISTENT_PORT}"
    HAVE_PERSIST=1
  else
    HAVE_PERSIST=0
    # managed persistent downloader on :11434 (shared store)
    write_unit "ollama-persist.service" "$PERSISTENT_PORT" "" "Ollama (persistent on :${PERSISTENT_PORT})"
    systemctl enable --now ollama-persist.service || true
  fi

  # Bind A/B to GPUs by name, else by index order
  local uuid_a uuid_b
  uuid_a="$(pick_uuid_by_name_substr "$MATCH_GPU_A" || true)"
  uuid_b="$(pick_uuid_by_name_substr "$MATCH_GPU_B" || true)"
  if [ -z "${uuid_a:-}" ] || [ -z "${uuid_b:-}" ] || [ "$uuid_a" = "$uuid_b" ]; then
    warn "GPU name match failed/identical — falling back to index order."
    uuid_a="$(echo "$all" | awk -F',' 'NR==1{print $2}')"
    uuid_b="$(echo "$all" | awk -F',' 'NR==2{print $2}')"
  fi

  write_unit "ollama-test-a.service" "$TEST_PORT_A" "$uuid_a" "Ollama (TEST A on :${TEST_PORT_A}, GPU ${uuid_a})"
  write_unit "ollama-test-b.service" "$TEST_PORT_B" "$uuid_b" "Ollama (TEST B on :${TEST_PORT_B}, GPU ${uuid_b})"

  systemctl enable --now ollama-test-a.service || true
  systemctl enable --now ollama-test-b.service || true

  # Log which model dir each test daemon is actually using
  info "TEST A OLLAMA_MODELS: $(service_env ollama-test-a.service OLLAMA_MODELS)"
  info "TEST B OLLAMA_MODELS: $(service_env ollama-test-b.service OLLAMA_MODELS)"

  info "Waiting for APIs"
  wait_api "127.0.0.1:${PERSISTENT_PORT}" || warn "API :${PERSISTENT_PORT} not reachable yet"
  wait_api "127.0.0.1:${TEST_PORT_A}" || warn "API :${TEST_PORT_A} slow to start"
  wait_api "127.0.0.1:${TEST_PORT_B}" || warn "API :${TEST_PORT_B} slow to start"

  info "ollama version: $($OLLAMA_BIN --version || echo 'unknown')"
  # Confirm bases visible on :11434
  for m in "${MODELS[@]}"; do
    base="${m%%|*}"
    if have_model "$base"; then
      info "Base ${base} present on ${PERSISTENT_PORT}"
    else
      warn "Base ${base} NOT present on ${PERSISTENT_PORT} (will pull on demand)"
    fi
  done
}

append_csv_row(){ echo "$*" >>"$CSV_FILE"; }

bench_once(){ # ep model label num_gpu gpu_label
  local ep="$1" model="$2" label="$3" ng="${4:-}" gpu_lbl="$5"
  local sfx unit gname guid gmem opts tokps

  sfx="$(suffix_for_ep "$ep")"
  unit="$(unit_for_ep "$ep")"
  IFS=',' read -r gname guid gmem <<<"$(offload_triplet "$unit")"

  # Options JSON
  opts="$(jq -n \
      --argjson ctx "$CTX" \
      --argjson batch "$BATCH" \
      --argjson pred "$PRED" \
      --argjson ng "${ng:-null}" \
      '($ng|type) as $t | {num_ctx:$ctx,batch:$batch,temperature:0,mirostat:0,seed:1,num_predict:$pred} + (if $t=="number" then {num_gpu:$ng} else {} end)')"

  local prompt="Write ok repeatedly for benchmarking."
  local out; out="$(curl_gen "$ep" "$model" "$opts" "$prompt" "$TIMEOUT_GEN" || true)"
  local last; last="$(echo "$out" | json_last_line || true)"
  if [ -z "$last" ]; then
    warn "[bench] ${sfx}  ${model}  ->  no data (timeout/error)"
    return 1
  fi
  local ec ed; ec="$(echo "$last" | jq -r '.eval_count // 0')"
  ed="$(echo "$last" | jq -r '.eval_duration // 0')"
  tokps="$(calc_tokps "$ec" "$ed")"

  append_csv_row "$(date -Iseconds),$ep,$unit,$sfx,${base},${label},${model},${ng:-default},$CTX,$BATCH,$PRED,$tokps,${gpu_lbl},${gname},${guid},${gmem}"
  ok "[bench] ${sfx}  ${model}  ->  ${tokps} tok/s (ctx=$CTX, batch=$BATCH, num_gpu=${ng:-default})"
  echo "$tokps"
}

bench_base_as_is(){ # ep baseTag
  local ep="$1" base="$2" unit; unit="$(unit_for_ep "$ep")"
  local gpu_lbl; gpu_lbl="$(gpu_label_for_ep "$ep")"
  systemctl restart "$unit" || true
  wait_api "$ep" || { warn "API $ep not up for base-as-is"; return 1; }
  # If base not visible on test endpoint, try one fast restart+wait
  if ! curl_tags "$ep" | jq -r '.models[].name' 2>/dev/null | grep -Fxq "$base"; then
    warn "Base ${base} NOT visible on ${ep}; restarting test service once..."
    systemctl restart "$unit" || true
    wait_api "$ep" || true
    sleep 2
  fi
  bench_once "$ep" "$base" "base-as-is" "" "$gpu_lbl" >/dev/null || return 1
}

# Create optimized variant with a transient Modelfile (built via :11434)
bake_variant(){ # newname base num_gpu
  local newname="$1" base="$2" ng="$3"
  { echo "FROM ${base}"; echo "PARAMETER num_gpu ${ng}"; } \
    | OLLAMA_HOST="http://${PULL_FROM}" "$OLLAMA_BIN" create -f - "$newname" \
        >>"$CREATE_LOG" 2>&1
}

tune_and_bench_one(){ # ep baseTag aliasBase
  local ep="$1" base="$2" alias_base="$3"
  local gpu_lbl; gpu_lbl="$(gpu_label_for_ep "$ep")"
  info "----> [${ep}] Tuning ${base} -> variants ${alias_base}-${gpu_lbl}-ng<NUM>"
  pull_if_missing "$base"

  # for visibility: ensure base is accessible on the bench endpoint (not required to create)
  if ! curl_tags "$ep" | jq -r '.models[].name' 2>/dev/null | grep -Fxq "$base"; then
    warn "Base ${base} NOT visible on ${ep}. This is ok for build (we build on :${PERSISTENT_PORT}), but benches will run via ${ep}."
  fi

  bench_base_as_is "$ep" "$base" || warn "base-as-is bench skipped for $base on $ep"

  local first_ok=0 best_tokps="0.00" best_name="" best_ng=""
  local unit; unit="$(unit_for_ep "$ep")"
  systemctl restart "$unit" || true
  wait_api "$ep" || warn "API $ep not up before sweep; will try anyhow"

  for ng in $NUM_GPU_CANDIDATES; do
    info "     Trying num_gpu=${ng} (build on :${PERSISTENT_PORT}) ..."
    local newname="${alias_base}-${gpu_lbl}-ng${ng}"

    if ! bake_variant "$newname" "$base" "$ng"; then
      warn "     x bake failed (see ${CREATE_LOG})"
      # surface last few lines inline for faster triage
      { echo "        └─ last create log lines:"; tail -n 8 "$CREATE_LOG" | sed 's/^/           /'; } || true
      continue
    fi

    # Ensure the newly created variant is visible on the target test endpoint
    if ! wait_variant_visible "$ep" "${newname}:latest"; then
      warn "     variant ${newname}:latest not visible on ${ep} after wait; restarting test service"
      systemctl restart "$(unit_for_ep "$ep")" || true
      wait_api "$ep" || true
      if ! wait_variant_visible "$ep" "${newname}:latest" 6; then
        warn "     still not visible; skipping bench of ${newname}"
        continue
      fi
    fi

    # bench on the test endpoint
    local tokps; tokps="$(bench_once "$ep" "${newname}:latest" "optimized" "$ng" "$gpu_lbl" || echo "0.00")"
    awk -v a="$tokps" -v b="$best_tokps" 'BEGIN{exit !(a>b)}' && { best_tokps="$tokps"; best_name="$newname"; best_ng="$ng"; }

    if [ "$EXHAUSTIVE" -eq 0 ] && awk -v a="$tokps" 'BEGIN{exit !(a>0)}'; then
      first_ok=1
      ok "     First working: ${newname} at ${tokps} tok/s"
      break
    fi
  done

  if [ -n "$best_name" ]; then
    ok "Best on ${ep}: ${best_name} (num_gpu=${best_ng}) at ${best_tokps} tok/s"
    echo "${ep},${alias_base},${best_name},${best_ng},${best_tokps}" >>"${SUMMARY_FILE}.raw"
  else
    warn "No working num_gpu for ${base} on ${ep}"
  fi
}

##################################### MAIN #####################################
echo -e "${c_bold}== One-at-a-time auto-tune + bench (POSIX) ==${c_reset}"
log "Persistent : ${PULL_FROM}"
log "Test EPs   : 127.0.0.1:${TEST_PORT_A}  127.0.0.1:${TEST_PORT_B}"
log "Models     : $(printf '%s ' "${MODELS[@]}")"
log "CSV        : ${CSV_FILE}"
log "Summary    : ${SUMMARY_FILE}"

prepare_services

wait_api "$PULL_FROM" || { err "Persistent API ${PULL_FROM} not reachable"; exit 1; }

for ep in "${ENDPOINTS[@]}"; do
  restart_ep "$ep" || true
  wait_api "$ep" || warn "API $ep is not up yet (continuing)"
done

for m in "${MODELS[@]}"; do
  base="${m%%|*}"; alias_base="${m##*|}"
  for ep in "${ENDPOINTS[@]}"; do
    [ "${ep##*:}" = "$PERSISTENT_PORT" ] && continue
    restart_ep "$ep" || true
    if ! wait_api "$ep"; then
      err "ERROR: API ${ep} did not come up — skipping ${base} on ${ep}"
      continue
    fi
    tune_and_bench_one "$ep" "$base" "$alias_base"
  done
done

{
  echo "=== Final Summary @ ${HOSTNAME_NOW} ${TS} ==="
  echo "CSV: ${CSV_FILE}"
  echo
  if [ -s "${SUMMARY_FILE}.raw" ]; then
    echo "Best optimized per (endpoint, model):"
    column -t -s',' "${SUMMARY_FILE}.raw" 2>/dev/null || cat "${SUMMARY_FILE}.raw"
  else
    echo "No optimized variants succeeded."
  fi
  echo
  echo "Top-5 runs overall (by tokens/sec) from CSV:"
  tail -n +2 "$CSV_FILE" | sort -t',' -k12,12gr | head -n5 \
    | awk -F',' '{printf "  %-2s %-18s %-28s %-14s %6.2f tok/s  (%s %s ngpu=%s)\n",$4,$5,$6,$13,$12,$1,$2,$8}'
} | tee "${SUMMARY_FILE}"

ok "DONE. CSV: ${CSV_FILE}"
ok "DONE. Summary: ${SUMMARY_FILE}"
# NOTE: :11434 is never killed by this script; only :11435 and :11436 are started/stopped.

