#!/usr/bin/env bash
# ollama-benchmark.sh
# One-at-a-time model tuning + benchmarking with an always-on puller on :11434
# - Builds optimized variants with clear GPU-tagged names
# - Benches base-as-is + optimized per test GPU
# - Keeps persistent port 11434 up (shared model store)
# - CSV + summary in local ./logs (or override LOG_DIR)

set -euo pipefail

########## CONFIG (override via env) ###########################################
PERSISTENT_PORT="${PERSISTENT_PORT:-11434}"      # always-on downloader, never killed
TEST_PORT_A="${TEST_PORT_A:-11435}"              # test instance A (bound to GPU-A)
TEST_PORT_B="${TEST_PORT_B:-11436}"              # test instance B (bound to GPU-B)

# DEFAULT to your stated location; override if needed
OLLAMA_MODELS_DIR="${OLLAMA_MODELS_DIR:-/FuZe/models/ollama}"

# Base models to try, plus alias (used in variant tag)
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
TIMEOUT_GEN="${TIMEOUT_GEN:-90}"
TIMEOUT_TAGS="${TIMEOUT_TAGS:-10}"

# Which daemon performs "create" (bake) of variants:
#   persistent : build on :11434 (recommended: avoids bouncing test daemons)
#   endpoint   : build on the test endpoint itself
BUILD_ON="${BUILD_ON:-persistent}"

# GPU name substrings we try to bind to A/B (fallback = index order)
MATCH_GPU_A="${MATCH_GPU_A:-5090}"
MATCH_GPU_B="${MATCH_GPU_B:-3090 Ti}"

# Service HOME for test daemons
SERVICE_HOME="${SERVICE_HOME:-/root}"

# Stack name shown in logs
STACK=ollama
################################################################################

# Resolve script + local logs dir (default if LOG_DIR not set)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${LOG_DIR:-${STACK_ROOT}/logs}"
mkdir -p "$LOG_DIR"

readonly OLLAMA_BIN="${OLLAMA_BIN:-/usr/local/bin/ollama}"
readonly HOSTNAME_NOW="$(hostname -s 2>/dev/null || hostname)"
readonly TS="$(date +%Y%m%d_%H%M%S)"
readonly CSV_FILE="${LOG_DIR}/${STACK}_bench_${TS}.csv"
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

need curl; need jq; need awk; need sed; need systemctl; need nvidia-smi
if ! command -v lsof >/dev/null 2>&1 && ! command -v ss >/dev/null 2>&1; then
  warn "Neither lsof nor ss found — port cleanup may be limited."
fi

# CSV schema (DON’T change col order: aggregators depend on tokens_per_sec at col 11)
echo "ts,endpoint,unit,suffix,model,variant,num_gpu,num_ctx,batch,num_predict,tokens_per_sec,gpu_name,gpu_uuid,gpu_mem_mib" >"$CSV_FILE"

json_last_line(){ grep -E '"done":\s*true' | tail -n1; }
gpu_table(){ nvidia-smi --query-gpu=index,uuid,name,memory.total --format=csv,noheader | sed 's/, /,/g'; }
calc_tokps(){ awk -v ec="$1" -v ed="$2" 'BEGIN{ if(ed<=0){print "0.00"} else {printf("%.2f", ec/(ed/1e9))} }'; }

curl_tags(){ local ep="$1"; curl -fsS --max-time "$TIMEOUT_TAGS" "http://${ep}/api/tags" || return 1; }
curl_version(){ local ep="$1"; curl -fsS --max-time "$TIMEOUT_TAGS" "http://${ep}/api/version" || true; }

# Build generation payload with jq (safe)
curl_gen(){
  local ep="$1" model="$2" opts_json="$3" prompt="$4" to="$5"
  local payload
  payload="$(jq -n --arg m "$model" --arg p "$prompt" --argjson o "$opts_json" '{model:$m, options:$o, prompt:$p}')"
  curl -sS --max-time "$to" -H 'Content-Type: application/json' -d "$payload" "http://${ep}/api/generate" || return 1
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

offload_summary(){ # unit -> "name uuid memMiB"
  local unit="$1" uuid row
  uuid="$(systemctl show "$unit" -p Environment 2>/dev/null | tr '\n' ' ' | sed -E 's/.*CUDA_VISIBLE_DEVICES=([^ ]+).*/\1/')"
  [ -z "${uuid:-}" ] && { echo ",,"; return 0; }
  row="$(gpu_table | grep "$uuid" || true)"
  [ -z "$row" ] && { echo ",,"; return 0; }
  IFS=',' read -r _idx u name mem <<<"$row"
  echo "$name,$u,${mem%% MiB}"
}

gpu_label_from_name(){
  local name="${1:-}"
  local low="$(echo "$name" | tr '[:upper:]' '[:lower:]')"
  if   echo "$low" | grep -q '5090'; then echo "nvidia-5090"
  elif echo "$low" | grep -q '5080'; then echo "nvidia-5080"
  elif echo "$low" | grep -q '5070'; then echo "nvidia-5070"
  elif echo "$low" | grep -q '3090 ti'; then echo "nvidia-3090ti"
  elif echo "$low" | grep -q '3090'; then echo "nvidia-3090"
  else echo "nvidia"; fi
}

gpu_label_for_ep(){ # ep -> nvidia-5090 / nvidia-3090ti / nvidia
  local ep="$1" unit gname guid gmem
  unit="$(unit_for_ep "$ep")"
  read -r gname guid gmem <<<"$(offload_summary "$unit")"
  gpu_label_from_name "$gname"
}

have_tag_on_ep(){ # ep, tag -> 0/1
  local ep="$1" tag="$2"
  curl_tags "$ep" | jq -r '.models[].name' 2>/dev/null | grep -Fxq "$tag"
}

have_tag_on_persist(){ # tag -> 0/1
  local tag="$1"
  OLLAMA_HOST="http://${PULL_FROM}" "$OLLAMA_BIN" list 2>/dev/null | awk '{print $1}' | grep -Fxq "$tag"
}

pull_if_missing_on_persist(){ # baseTag
  local base="$1"
  if have_tag_on_persist "$base"; then
    info "Base ${base} present on ${PULL_FROM}"
  else
    info "Pulling ${base} via ${PULL_FROM} (this may take a while)"
    OLLAMA_HOST="http://${PULL_FROM}" "$OLLAMA_BIN" pull "$base" || warn "pull of $base failed"
  fi
}

ensure_base_present(){ # ep baseTag -> ensure endpoint can see base (shared store)
  local ep="$1" base="$2"
  if have_tag_on_ep "$ep" "$base"; then
    info "Base ${base} visible on ${ep}"
    return 0
  fi
  # try to ensure the store has it via persistent
  pull_if_missing_on_persist "$base"
  sleep 1
  if have_tag_on_ep "$ep" "$base"; then
    info "Base ${base} now visible on ${ep}"
    return 0
  fi
  warn "Base ${base} NOT visible on ${ep}. Likely model store mismatch between daemons."
  return 1
}

write_unit(){ # name listen uuid_env desc
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
  gpu_table | while IFS=',' read -r _idx uuid name _mem; do
    echo "$name" | grep -qi "$needle" && { echo "$uuid"; return 0; }
  done
}

prepare_services(){
  info "Preparing directories and services"
  mkdir -p "$OLLAMA_MODELS_DIR" "$LOG_DIR"

  local all; all="$(gpu_table)"
  log "$(echo "$all" | sed 's/^/GPU: /')"

  # Persistent downloader on :11434 — use existing if present
  if curl -fsS --max-time 1 "http://${PULL_FROM}/api/version" >/dev/null 2>&1; then
    info "Using existing Ollama on :${PERSISTENT_PORT}"
  else
    write_unit "ollama-persist.service" "$PERSISTENT_PORT" "" "Ollama (persistent downloader on :${PERSISTENT_PORT})"
    systemctl enable --now ollama-persist.service
  fi

  # choose GPU UUIDs
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

  info "Waiting for APIs"
  wait_api "127.0.0.1:${PERSISTENT_PORT}" || { err "API :${PERSISTENT_PORT} did not come up"; exit 1; }
  wait_api "127.0.0.1:${TEST_PORT_A}" || warn "API :${TEST_PORT_A} slow to start (will retry per model)"
  wait_api "127.0.0.1:${TEST_PORT_B}" || warn "API :${TEST_PORT_B} slow to start (will retry per model)"
}

# Create optimized variant with a transient Modelfile; chooses builder daemon
bake_variant(){ # base newname num_gpu
  local base="$1" newname="$2" ng="$3"
  local builder_ep
  case "$BUILD_ON" in
    persistent) builder_ep="$PULL_FROM";;
    endpoint)   builder_ep="$CURRENT_EP";;   # CURRENT_EP set by tune loop
    *) builder_ep="$PULL_FROM";;
  esac

  {
    echo "### ${newname}  FROM ${base}  num_gpu=${ng}  builder=${builder_ep}"
    echo "FROM ${base}"
    echo "PARAMETER num_gpu ${ng}"
  } >>"$CREATE_LOG"

  { 
    printf 'FROM %s\nPARAMETER num_gpu %s\n' "$base" "$ng" \
      | OLLAMA_HOST="http://${builder_ep}" "$OLLAMA_BIN" create -f - "$newname"
  } >>"$CREATE_LOG" 2>&1
}

append_csv_row(){ echo "$*" >>"$CSV_FILE"; }

bench_once(){ # ep modelTag variantLabel baseTag num_gpu
  local ep="$1" model="$2" vlabel="$3" base="$4" ng="${5:-}"
  local sfx unit gname guid gmem opts tokps

  sfx="$(suffix_for_ep "$ep")"
  unit="$(unit_for_ep "$ep")"
  read -r gname guid gmem <<<"$(offload_summary "$unit")"

  # options JSON as one-liner to avoid jq parse errors
  opts="$(jq -n \
      --argjson ctx "$CTX" \
      --argjson batch "$BATCH" \
      --argjson pred "$PRED" \
      --argjson ng "${ng:-null}" \
      '($ng|type) as $t
       | {num_ctx:$ctx,batch:$batch,temperature:0,mirostat:0,seed:1,num_predict:$pred}
         + (if $t=="number" then {num_gpu:$ng} else {} end)')"

  local prompt="Write ok repeatedly for benchmarking."
  local out; out="$(curl_gen "$ep" "$model" "$opts" "$prompt" "$TIMEOUT_GEN" || true)"
  local last; last="$(echo "$out" | json_last_line || true)"
  if [ -z "$last" ]; then
    warn "[bench] ${sfx}  ${base}  ${model}  -> no data (timeout/error)"
    return 1
  fi
  local ec ed; ec="$(echo "$last" | jq -r '.eval_count // 0')"
  ed="$(echo "$last" | jq -r '.eval_duration // 0')"
  tokps="$(calc_tokps "$ec" "$ed")"

  # CSV: variant column is the EXACT tag we ran (clarity)
  append_csv_row "$(date -Iseconds),$ep,$unit,$sfx,$base,$model,${ng:-default},$CTX,$BATCH,$PRED,$tokps,$gname,$guid,$gmem"
  ok "[$sfx] ${base}  ->  ${model}  ${tokps} tok/s  (ctx=$CTX, batch=$BATCH, num_gpu=${ng:-default})"
  echo "$tokps"
}

bench_base_as_is(){ # ep baseTag
  local ep="$1" base="$2" unit; unit="$(unit_for_ep "$ep")"
  systemctl restart "$unit" || true
  wait_api "$ep" || { warn "API $ep not up for base-as-is"; return 1; }
  bench_once "$ep" "$base" "base-as-is" "$base" "" >/dev/null || return 1
}

tune_and_bench_one(){ # ep baseTag aliasBase
  local ep="$1" base="$2" alias_base="$3"
  CURRENT_EP="$ep"  # used by bake_variant when BUILD_ON=endpoint
  local gplabel; gplabel="$(gpu_label_for_ep "$ep")"

  info "----> [${ep}] Tuning ${base} -> variants ${alias_base}-${gplabel}-ng<NUM_GPU>"
  ensure_base_present "$ep" "$base" || warn "Continuing, but base not visible on $ep"

  # Bench base tag exactly as-is
  bench_base_as_is "$ep" "$base" || warn "base-as-is bench skipped for $base on $ep"

  local best_tokps="0.00" best_name="" best_ng=""
  local unit; unit="$(unit_for_ep "$ep")"
  systemctl restart "$unit" || true
  wait_api "$ep" || warn "API $ep not up before sweep; will try anyhow"

  for ng in $NUM_GPU_CANDIDATES; do
    local newname="${alias_base}-${gplabel}-ng${ng}"
    info "     Trying ${newname} (build on ${BUILD_ON}, bench on ${ep}) ..."
    if ! bake_variant "$base" "$newname" "$ng"; then
      warn "     x bake failed for ${newname} (see ${CREATE_LOG})"
      continue
    fi

    # Bench the newly created tag
    local tokps; tokps="$(bench_once "$ep" "$newname" "optimized" "$base" "$ng" || echo "0.00")"
    awk -v a="$tokps" -v b="$best_tokps" 'BEGIN{exit !(a>b)}' && { best_tokps="$tokps"; best_name="$newname"; best_ng="$ng"; }

    # If not exhaustive: tag the first working as :latest for convenience and stop
    if [ "$EXHAUSTIVE" -eq 0 ] && awk -v a="$tokps" 'BEGIN{exit !(a>0)}'; then
      local latest="${alias_base}-${gplabel}"
      info "     Tagging convenience latest: ${latest}:latest -> ${newname}"
      # Re-bake latest pointing to same params so it’s an independent tag
      bake_variant "$base" "$latest" "$ng" || warn "     tag-latest bake failed for ${latest}"
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

ver="$("$OLLAMA_BIN" --version 2>/dev/null || true)"; ver="${ver:-$(OLLAMA_HOST="http://${PULL_FROM}" "$OLLAMA_BIN" --version 2>/dev/null || true)}"
info "ollama version: ${ver:-unknown}"

# Base tags should exist in shared store (pull via persistent if missing)
for m in "${MODELS[@]}"; do
  base="${m%%|*}"
  pull_if_missing_on_persist "$base"
done

# restart test endpoints once up-front
for ep in "${ENDPOINTS[@]}"; do
  restart_ep "$ep" || true
  wait_api "$ep" || warn "API $ep is not up yet (continuing)"
done

# Run all models on each endpoint
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
    # ep,alias,tag,ng,tokps
    column -t -s',' "${SUMMARY_FILE}.raw" 2>/dev/null || cat "${SUMMARY_FILE}.raw"
  else
    echo "No optimized variants succeeded."
  fi
  echo
  echo "Top-5 runs overall (by tokens/sec) from CSV:"
  tail -n +2 "$CSV_FILE" | sort -t',' -k11,11gr | head -n5 \
    | awk -F',' '{printf "  %-2s %-18s %-30s %-13s %6.2f tok/s  (%s %s ngpu=%s)\n",$4,$5,$6, (index($6,"nvidia-")?substr($6,index($6,"nvidia-")):""), $11,$1,$2,$7}'
} | tee "${SUMMARY_FILE}"

ok "DONE. CSV: ${CSV_FILE}"
ok "DONE. Summary: ${SUMMARY_FILE}"

# Hints for inspection:
#   tail -n 200 "${CREATE_LOG}"
#   OLLAMA_HOST=http://127.0.0.1:${TEST_PORT_A} ${OLLAMA_BIN} ls | grep nvidia-
#   OLLAMA_HOST=http://127.0.0.1:${TEST_PORT_B} ${OLLAMA_BIN} ls | grep nvidia-

