#!/usr/bin/env bash
# ollama-benchmark.sh
# One-at-a-time model tuning + benchmarking with an always-on puller on :11434

set -euo pipefail

########## CONFIG (override with env) ##########################################
PERSISTENT_PORT="${PERSISTENT_PORT:-11434}"  # always-on downloader/creator, never killed
TEST_PORT_A="${TEST_PORT_A:-11435}"          # test instance A (bound to GPU-A)
TEST_PORT_B="${TEST_PORT_B:-11436}"          # test instance B (bound to GPU-B)

OLLAMA_MODELS_DIR="${OLLAMA_MODELS_DIR:-/FuZe/ollama/models}"
LOG_DIR="${LOG_DIR:-/FuZe/logs}"

# Base models to try, plus alias for optimized variants (basename before GPU suffix)
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
TIMEOUT_PULL="${TIMEOUT_PULL:-600}"

SERVICE_HOME="${SERVICE_HOME:-/root}"

# GPU name substrings we try to bind to A/B (case-insensitive)
MATCH_GPU_A="${MATCH_GPU_A:-5090}"
MATCH_GPU_B="${MATCH_GPU_B:-3090 Ti}"

STACK=ollama
################################################################################

need(){ command -v "$1" >/dev/null 2>&1 || { echo "✖ Missing dependency: $1" >&2; exit 1; }; }
need curl; need jq; need awk; need sed; need systemctl; need nvidia-smi; need date; need timeout
command -v lsof >/dev/null 2>&1 || command -v ss >/dev/null 2>&1 || echo "! Neither lsof nor ss found — port cleanup may be limited."

readonly OLLAMA_BIN="${OLLAMA_BIN:-/usr/local/bin/ollama}"
readonly HOSTNAME_NOW="$(hostname -s 2>/dev/null || hostname)"
readonly TS="${RUN_TS:-$(date +%Y%m%d_%H%M%S)}"

mkdir -p "${LOG_DIR}" 2>/dev/null || true
if [ ! -w "${LOG_DIR}" ]; then
  echo "! LOG_DIR ${LOG_DIR} not writable; falling back to ./logs"
  LOG_DIR="./logs"; mkdir -p "${LOG_DIR}"
fi

CSV_FILE="${LOG_DIR}/${STACK}_bench_${TS}.csv"
SUMMARY_FILE="${LOG_DIR}/${HOSTNAME_NOW}-${TS}.benchmark"

# CSV header: include 'stack' and 'notes'
echo "ts,stack,endpoint,unit,suffix,gpu_label,model,variant,num_gpu,num_ctx,batch,num_predict,tokens_per_sec,gpu_name,gpu_uuid,gpu_mem_mib,notes" >"$CSV_FILE"

c_bold="\033[1m"; c_red="\033[31m"; c_green="\033[32m"; c_yellow="\033[33m"; c_reset="\033[0m"
log(){ echo -e "$*"; }
info(){ [ "$VERBOSE" -ne 0 ] && echo -e "${c_bold}==${c_reset} $*"; }
ok(){ echo -e "${c_green}✔${c_reset} $*"; }
warn(){ echo -e "${c_yellow}!${c_reset} $*"; }
err(){ echo -e "${c_red}✖${c_reset} $*" >&2; }

PERSIST_EP="127.0.0.1:${PERSISTENT_PORT}"
ENDPOINTS=("127.0.0.1:${TEST_PORT_A}" "127.0.0.1:${TEST_PORT_B}")

gpu_table(){ nvidia-smi --query-gpu=index,uuid,name,memory.total --format=csv,noheader | sed 's/, /,/g'; }
json_last_line(){ grep -E '"done":\s*true' | tail -n1; }
calc_tokps(){ awk -v ec="$1" -v ed="$2" 'BEGIN{ if(ed<=0){print "0.00"} else {printf("%.2f", ec/(ed/1e9))} }'; }

curl_gen(){
  local ep="$1" model="$2" opts_json="$3" prompt="$4" to="$5"
  local payload
  payload="$(jq -n --arg m "$model" --arg p "$prompt" --argjson o "$opts_json" '{model:$m, options:$o, prompt:$p}')"
  curl -sS --max-time "$to" -H 'Content-Type: application/json' -d "$payload" "http://${ep}/api/generate" || return 1
}

unit_for_ep(){
  local port="${1##*:}"
  case "$port" in
    "$TEST_PORT_A") echo "ollama-test-a.service";;
    "$TEST_PORT_B") echo "ollama-test-b.service";;
    "$PERSISTENT_PORT") echo "ollama-persist.service";;
    *) echo "ollama-unknown-${port}.service";;
  esac
}
suffix_for_ep(){ local port="${1##*:}"; [ "$port" = "$TEST_PORT_A" ] && echo "A" || { [ "$port" = "$TEST_PORT_B" ] && echo "B" || echo "X"; } }

kill_port_listener(){
  local port="$1" pid=""
  if command -v lsof >/dev/null 2>&1; then
    pid="$(lsof -iTCP -sTCP:LISTEN -P 2>/dev/null | awk -v p=":${port}" '$9 ~ p {print $2}' | head -n1 || true)"
  else
    pid="$(ss -ltnp 2>/dev/null | awk -v p=":${port}" '$4 ~ p {print $7}' | sed -E 's/.*pid=([0-9]+).*/\1/' | head -n1 || true)"
  fi
  [ -n "${pid:-}" ] && { warn "Killing listener PID ${pid} on :${port}"; kill -9 "$pid" || true; }
}

wait_api(){
  local ep="$1" secs="${2:-$WAIT_API_SECS}" t=0
  while [ "$t" -lt "$secs" ]; do
    curl -fsS --max-time 1 "http://${ep}/api/tags" >/dev/null 2>&1 && return 0
    sleep 1; t=$((t+1))
  done
  return 1
}

gpu_info_by_uuid(){
  local uuid="$1" row; row="$(gpu_table | grep "$uuid" || true)"
  [ -z "$row" ] && { echo ",,"; return 0; }
  IFS=',' read -r idx u name mem <<<"$row"
  echo "$name,$u,${mem%% MiB}"
}

gpu_uuid_of_unit(){
  local unit="$1"
  systemctl show "$unit" -p Environment 2>/dev/null \
    | tr '\n' ' ' | sed -E 's/.*CUDA_VISIBLE_DEVICES=([^ ]+).*/\1/'
}

gpu_label(){
  local name="$(echo "$1" | tr 'A-Z' 'a-z')"
  local suffix="$(echo "$name" | sed -E 's/.*rtx[[:space:]]*([0-9]{4}([[:space:]]*ti)?).*/\1/' | tr -d ' ')"
  [ -z "$suffix" ] && suffix="$(echo "$name" | grep -oE '[0-9]{4}(ti)?' | head -n1)"
  suffix="$(echo "$suffix" | tr -d ' ')"
  [ -z "$suffix" ] && { echo "nvidia"; return; }
  echo "nvidia-${suffix}"
}

have_model(){ local tag="$1"; OLLAMA_HOST="http://${PERSIST_EP}" "$OLLAMA_BIN" list 2>/dev/null | awk '{print $1}' | grep -Fxq "$tag"; }
pull_if_missing(){
  local base="$1"
  if have_model "$base"; then
    info "Base ${base} present (via ${PERSIST_EP})"
  else
    info "Pulling ${base} via ${PERSIST_EP} (timeout ${TIMEOUT_PULL}s)"
    OLLAMA_HOST="http://${PERSIST_EP}" timeout "${TIMEOUT_PULL}"s "$OLLAMA_BIN" pull "$base" || warn "pull of $base failed"
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
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=OLLAMA_MODELS=${OLLAMA_MODELS_DIR}
Environment=OLLAMA_HOST=127.0.0.1:${listen}
${uuid_env:+Environment=CUDA_VISIBLE_DEVICES=${uuid_env}}
WorkingDirectory=${SERVICE_HOME}
ExecStartPre=/bin/sh -lc 'mkdir -p "${OLLAMA_MODELS}"; :'
ExecStart=${OLLAMA_BIN} serve
Restart=always
RestartSec=1s
LimitNOFILE=1048576
NoNewPrivileges=true
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

tail_unit_logs(){ local u="$1"; journalctl -n 30 -u "$u" --no-pager 2>/dev/null || true; }

restart_ep(){
  local ep="$1" unit port; unit="$(unit_for_ep "$ep")"; port="${ep##*:}"
  if [ "$port" != "$PERSISTENT_PORT" ]; then
    systemctl restart "$unit" >/dev/null 2>&1 || true
    if ! wait_api "$ep" 10; then
      warn "$unit did not come up quickly; stopping + killing port and starting"
      systemctl stop "$unit" >/dev/null 2>&1 || true
      kill_port_listener "$port"
      systemctl start "$unit" || true
    fi
  else
    systemctl enable --now "$unit" || true
  fi
}

pick_uuid_by_name_substr(){
  local needle="$1"
  gpu_table | while IFS=',' read -r idx uuid name mem; do
    echo "$name" | grep -qi "$needle" && { echo "$uuid"; return 0; }
  done
}

prepare_services(){
  info "Preparing directories and services"
  mkdir -p "$OLLAMA_MODELS_DIR" "$LOG_DIR"

  local all; all="$(gpu_table)"
  echo "$all" | sed 's/^/GPU: /'

  echo "== ollama version: $("$OLLAMA_BIN" --version 2>&1 || true)"

  write_unit "ollama-persist.service" "$PERSISTENT_PORT" "" "Ollama (persistent on :${PERSISTENT_PORT})"
  if ! systemctl enable --now ollama-persist.service; then
    err "ollama-persist.service failed to start"; tail_unit_logs "ollama-persist.service"
  fi

  local uuid_a uuid_b
  uuid_a="$(pick_uuid_by_name_substr "$MATCH_GPU_A" || true)"
  uuid_b="$(pick_uuid_by_name_substr "$MATCH_GPU_B" || true)"
  if [ -z "${uuid_a:-}" ] || [ -z "${uuid_b:-}" ] || [ "$uuid_a" = "$uuid_b" ]; then
    warn "GPU name match failed/identical — falling back to index order."
    uuid_a="$(echo "$all" | awk -F',' 'NR==1{print $2}')"
    uuid_b="$(echo "$all" | awk -F',' 'NR==2{print $2}')"
  fi

  write_unit "ollama-test-a.service" "$TEST_PORT_A" "$uuid_a" "Ollama (TEST A :${TEST_PORT_A} GPU=${uuid_a})"
  write_unit "ollama-test-b.service" "$TEST_PORT_B" "$uuid_b" "Ollama (TEST B :${TEST_PORT_B} GPU=${uuid_b})"

  systemctl enable --now ollama-test-a.service || { warn "ollama-test-a failed"; tail_unit_logs "ollama-test-a.service"; }
  systemctl enable --now ollama-test-b.service || { warn "ollama-test-b failed"; tail_unit_logs "ollama-test-b.service"; }

  info "Waiting for APIs"
  wait_api "$PERSIST_EP" || { err "API ${PERSIST_EP} did not come up"; tail_unit_logs "ollama-persist.service"; exit 1; }
  wait_api "127.0.0.1:${TEST_PORT_A}" || warn "API :${TEST_PORT_A} slow to start (will retry per model)"
  wait_api "127.0.0.1:${TEST_PORT_B}" || warn "API :${TEST_PORT_B} slow to start (will retry per model)"
}

append_csv_row(){ echo "$*" >>"$CSV_FILE"; }

bench_once(){ # ep model label num_gpu gpu_label
  local ep="$1" model="$2" label="$3" ng="${4:-}" gpul="$5"
  local sfx unit gname guid gmem opts tokps

  sfx="$(suffix_for_ep "$ep")"
  unit="$(unit_for_ep "$ep")"
  local uuid; uuid="$(gpu_uuid_of_unit "$unit")"
  read -r gname guid gmem <<<"$(gpu_info_by_uuid "$uuid")"

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
    warn "[bench] ${sfx} ${model} on ${ep} -> no data (timeout/error)"
    append_csv_row "$(date -Iseconds),$STACK,$ep,$unit,$sfx,$gpul,$model,$label,${ng:-default},$CTX,$BATCH,$PRED,0.00,,,,""no_data_or_timeout"""
    return 1
  fi
  local ec ed; ec="$(echo "$last" | jq -r '.eval_count // 0')"
  ed="$(echo "$last" | jq -r '.eval_duration // 0')"
  tokps="$(calc_tokps "$ec" "$ed")"

  append_csv_row "$(date -Iseconds),$STACK,$ep,$unit,$sfx,$gpul,$model,$label,${ng:-default},$CTX,$BATCH,$PRED,$tokps,$gname,$guid,$gmem,"
  ok "[bench] ${sfx} ${label} on ${gpul}  ->  ${tokps} tok/s (ctx=$CTX, batch=$BATCH, num_gpu=${ng:-default})"
  echo "$tokps"
}

bake_variant(){ # base alias_base gpu_label num_gpu => returns created name
  local base="$1" alias_base="$2" gpul="$3" ng="$4"
  local newname="${alias_base}-${gpul}-ng${ng}"
  local mf="$(mktemp)"
  { echo "FROM ${base}"; echo "PARAMETER num_gpu ${ng}"; } > "$mf"
  local logf="${LOG_DIR}/create_${alias_base}_${gpul}_ng${ng}_${TS}.log"
  if ! OLLAMA_HOST="http://${PERSIST_EP}" "$OLLAMA_BIN" create -f "$mf" "$newname" >"$logf" 2>&1; then
    warn "create failed for ${newname}; see ${logf}"
    rm -f "$mf"
    return 1
  fi
  rm -f "$mf"
  echo "$newname"
}

bench_base_as_is(){ # ep baseTag gpu_label
  local ep="$1" base="$2" gpul="$3" unit; unit="$(unit_for_ep "$ep")"
  systemctl restart "$unit" >/dev/null 2>&1 || true
  wait_api "$ep" || { warn "API $ep not up for base-as-is"; tail_unit_logs "$unit"; return 1; }
  bench_once "$ep" "$base" "$base" "" "$gpul" >/dev/null || return 1
}

tune_and_bench_one(){ # ep baseTag aliasBase
  local ep="$1" base="$2" alias_base="$3"
  info "----> [${ep}] Tuning ${base} -> ${alias_base}"
  pull_if_missing "$base"

  local unit; unit="$(unit_for_ep "$ep")"
  local uuid; uuid="$(gpu_uuid_of_unit "$unit")"
  local gname _ gmem; read -r gname _ gmem <<<"$(gpu_info_by_uuid "$uuid")"
  local gpul; gpul="$(gpu_label "$gname")"

  bench_base_as_is "$ep" "$base" "$gpul" || warn "base-as-is bench skipped for $base on $ep"

  systemctl restart "$unit" >/dev/null 2>&1 || true
  wait_api "$ep" || warn "API $ep not up before sweep; will try anyhow"

  local best_tokps="0.00" best_name="" best_ng=""

  for ng in $NUM_GPU_CANDIDATES; do
    info "     Trying num_gpu=${ng} (build on :${PERSISTENT_PORT}) ..."
    local newname; newname="$(bake_variant "$base" "$alias_base" "$gpul" "$ng" || echo "")"
    [ -z "$newname" ] && continue
    local tokps; tokps="$(bench_once "$ep" "$newname" "$newname" "$ng" "$gpul" || echo "0.00")"
    awk -v a="$tokps" -v b="$best_tokps" 'BEGIN{exit !(a>b)}' && { best_tokps="$tokps"; best_name="$newname"; best_ng="$ng"; }
    [ "$EXHAUSTIVE" -eq 0 ] && awk -v a="$tokps" 'BEGIN{exit !(a>0)}' && break
  done

  if [ -n "$best_name" ]; then
    ok "Best on ${ep}: ${best_name} (num_gpu=${best_ng}) at ${best_tokps} tok/s"
    echo "${ep},${alias_base},${best_name},${gpul},${best_ng},${best_tokps}" >>"${SUMMARY_FILE}.raw"
  else
    warn "No working num_gpu for ${base} on ${ep}"
  fi
}

# MAIN
echo -e "${c_bold}== One-at-a-time auto-tune + bench (POSIX) ==${c_reset}"
echo "Persistent : ${PERSIST_EP}"
echo "Test EPs   : 127.0.0.1:${TEST_PORT_A}  127.0.0.1:${TEST_PORT_B}"
echo "Models     : $(printf '%s ' "${MODELS[@]}")"
echo "CSV        : ${CSV_FILE}"
echo "Summary    : ${SUMMARY_FILE}"

prepare_services

wait_api "$PERSIST_EP" || { err "Persistent API ${PERSIST_EP} not reachable"; exit 1; }

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
      tail_unit_logs "$(unit_for_ep "$ep")"
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
  tail -n +2 "$CSV_FILE" | sort -t',' -k13,13gr | head -n5 \
    | awk -F',' '{printf "  %-2s %-18s %-28s %-12s %6.2f tok/s  (%s %s ngpu=%s)\n",$5,$7,$8,$6,$13,$1,$3,$9}'
} | tee "${SUMMARY_FILE}"

ok "DONE. CSV: ${CSV_FILE}"
ok "DONE. Summary: ${SUMMARY_FILE}"

