#!/usr/bin/env bash
# ollama-benchmark.sh
set -euo pipefail

########## CONFIG ##############################################################
PERSISTENT_PORT="${PERSISTENT_PORT:-11434}"  # always-on downloader (never killed)
TEST_PORT_A="${TEST_PORT_A:-11435}"          # test instance A (bound to GPU-A)
TEST_PORT_B="${TEST_PORT_B:-11436}"          # test instance B (bound to GPU-B)

# Inherit LOG_DIR from wrapper if set, else local logs/ next to this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${LOG_DIR:-${SCRIPT_DIR%/ollama}/logs}"
mkdir -p "$LOG_DIR" 2>/dev/null || true

# Models and aliases for optimized variants
MODELS=(
  "llama4:16x17b|llama4-16x17b"
  "deepseek-r1:70b|deepseek-r1-70b"
  "llama4:128x17b|llama4-128x17b"
)

NUM_GPU_CANDIDATES="${NUM_GPU_CANDIDATES:-80 72 64 56 48 40 32 24 16}"

CTX="${CTX:-1024}"
BATCH="${BATCH:-32}"
PRED="${PRED:-256}"

EXHAUSTIVE="${EXHAUSTIVE:-0}"
VERBOSE="${VERBOSE:-1}"

WAIT_API_SECS="${WAIT_API_SECS:-60}"
TIMEOUT_GEN="${TIMEOUT_GEN:-90}"
TIMEOUT_TAGS="${TIMEOUT_TAGS:-10}"
TIMEOUT_PULL="${TIMEOUT_PULL:-600}"

SERVICE_HOME="${SERVICE_HOME:-/root}"
OLLAMA_MODELS_DIR="${OLLAMA_MODELS_DIR:-/FuZe/ollama/models}"
export OLLAMA_MODELS="${OLLAMA_MODELS_DIR}"

MATCH_GPU_A="${MATCH_GPU_A:-5090}"
MATCH_GPU_B="${MATCH_GPU_B:-3090 Ti}"

STACK="ollama"
################################################################################

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need curl; need jq; need awk; need sed; need systemctl; need nvidia-smi

readonly OLLAMA_BIN="${OLLAMA_BIN:-/usr/local/bin/ollama}"
readonly HOSTNAME_NOW="$(hostname -s 2>/dev/null || hostname)"
readonly TS="${RUN_TS:-$(date +%Y%m%d_%H%M%S)}"

readonly CSV_FILE="${LOG_DIR}/${STACK}_bench_${TS}.csv"
readonly SUMMARY_FILE="${LOG_DIR}/${HOSTNAME_NOW}-${TS}.benchmark"
readonly CREATE_LOG="${LOG_DIR}/ollama_create_${TS}.log"
readonly BENCH_LOG="${LOG_DIR}/ollama_bench_${TS}.log"

readonly PULL_FROM="127.0.0.1:${PERSISTENT_PORT}"
ENDPOINTS=("127.0.0.1:${TEST_PORT_A}" "127.0.0.1:${TEST_PORT_B}")

c_bold="\033[1m"; c_red="\033[31m"; c_green="\033[32m"; c_yellow="\033[33m"; c_reset="\033[0m"
log(){ echo -e "$*"; }
info(){ [ "$VERBOSE" -ne 0 ] && echo -e "${c_bold}==${c_reset} $*"; }
ok(){ echo -e "${c_green}✔${c_reset} $*"; }
warn(){ echo -e "${c_yellow}!${c_reset} $*"; }
err(){ echo -e "${c_red}✖${c_reset} $*" >&2; }

echo "ts,stack,endpoint,unit,suffix,gpu_label,model,variant,num_gpu,num_ctx,batch,num_predict,tokens_per_sec,gpu_name,gpu_uuid,gpu_mem_mib,notes" >"$CSV_FILE"

json_last_line(){ grep -E '"done":\s*true' | tail -n1; }
gpu_table(){ nvidia-smi --query-gpu=index,uuid,name,memory.total --format=csv,noheader | sed 's/, /,/g'; }
calc_tokps(){ awk -v ec="$1" -v ed="$2" 'BEGIN{ if(ed<=0){print "0.00"} else {printf("%.2f", ec/(ed/1e9))} }'; }

unit_for_ep(){
  local ep="$1" port="${ep##*:}"
  case "$port" in
    "$TEST_PORT_A") echo "ollama-test-a.service";;
    "$TEST_PORT_B") echo "ollama-test-b.service";;
    "$PERSISTENT_PORT") echo "ollama-persist.service";;
    *) echo "ollama-unknown-${port}.service";;
  esac
}
suffix_for_ep(){ local ep="$1" port="${ep##*:}"; case "$port" in "$TEST_PORT_A") echo "A";; "$TEST_PORT_B") echo "B";; *) echo "X";; esac; }

kill_port_listener(){
  local port="$1" pid=""
  if command -v lsof >/dev/null 2>&1; then
    pid="$(lsof -iTCP -sTCP:LISTEN -P 2>/dev/null | awk -v p=":${port}" '$9 ~ p {print $2}' | head -n1 || true)"
  elif command -v ss >/dev/null 2>&1; then
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

gpu_info_from_unit(){ # -> name,uuid,memMiB
  local unit="$1" uuid row
  uuid="$(systemctl show "$unit" -p Environment 2>/dev/null | tr '\n' ' ' | sed -E 's/.*CUDA_VISIBLE_DEVICES=([^ ]+).*/\1/')"
  [ -z "${uuid:-}" ] && { echo ",,"; return 0; }
  row="$(gpu_table | grep "$uuid" || true)"
  [ -z "$row" ] && { echo ",,"; return 0; }
  IFS=',' read -r _ u name mem <<<"$row"
  echo "$name,$u,${mem%% MiB}"
}

gpu_label_from_name(){ # "NVIDIA GeForce RTX 5090" -> "nvidia-5090", "3090 Ti" -> "nvidia-3090ti"
  local name="$1" low slug
  low="$(echo "$name" | tr '[:upper:]' '[:lower:]')"
  if echo "$low" | grep -qE 'rtx[^0-9]*([0-9]{4})([[:space:]]*ti)?'; then
    local d="$(echo "$low" | sed -nE 's/.*rtx[^0-9]*([0-9]{4})([[:space:]]*ti)?.*/\1/p')"
    local ti="$(echo "$low" | sed -nE 's/.*rtx[^0-9]*([0-9]{4})([[:space:]]*ti)?.*/\2/p' | tr -d ' ')"
    slug="nvidia-${d}${ti}"
  else
    slug="nvidia-$(echo "$low" | tr -cd 'a-z0-9' | sed -E 's/^(.{1,20}).*/\1/')"
  fi
  echo "$slug"
}

curl_gen(){
  local ep="$1" model="$2" opts_json="$3" prompt="$4" to="$5"
  local payload
  payload="$(jq -n --arg m "$model" --arg p "$prompt" --argjson o "$opts_json" '{model:$m, options:$o, prompt:$p}')"
  curl -sS --max-time "$to" -H 'Content-Type: application/json' -d "$payload" "http://${ep}/api/generate" || return 1
}

have_model(){ local tag="$1"; OLLAMA_HOST="http://${PULL_FROM}" "$OLLAMA_BIN" list 2>/dev/null | awk '{print $1}' | grep -Fxq "$tag"; }
pull_if_missing(){
  local base="$1"
  if have_model "$base"; then info "Base ${base} present (via ${PULL_FROM})"
  else
    info "Pulling ${base} via ${PULL_FROM}"
    OLLAMA_HOST="http://${PULL_FROM}" "$OLLAMA_BIN" pull "$base" >>"$CREATE_LOG" 2>&1 || warn "pull of $base failed"
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
  gpu_table | while IFS=',' read -r _ uuid name _; do
    echo "$name" | grep -qi "$needle" && { echo "$uuid"; return 0; }
  done
}

ensure_services(){
  info "Preparing directories and services"
  mkdir -p "$OLLAMA_MODELS_DIR" "$LOG_DIR"

  local all; all="$(gpu_table)"
  log "$(echo "$all" | sed 's/^/GPU: /')"

  # Avoid fighting an existing :11434
  if curl -fsS --max-time 2 "http://${PULL_FROM}/api/tags" >/dev/null 2>&1; then
    info "Using existing Ollama on :${PERSISTENT_PORT}"
  else
    write_unit "ollama-persist.service" "$PERSISTENT_PORT" "" "Ollama (persistent downloader on :${PERSISTENT_PORT})"
    systemctl enable --now ollama-persist.service || warn "persist unit failed (may already run as user daemon)"
    wait_api "$PULL_FROM" || warn "Persistent API :${PERSISTENT_PORT} not up yet; will still attempt pulls"
  fi

  # bind test A/B to GPUs
  local uuid_a uuid_b
  uuid_a="$(pick_uuid_by_name_substr "$MATCH_GPU_A" || true)"
  uuid_b="$(pick_uuid_by_name_substr "$MATCH_GPU_B" || true)"
  if [ -z "${uuid_a:-}" ] || [ -z "${uuid_b:-}" ] || [ "$uuid_a" = "$uuid_b" ]; then
    warn "GPU name match failed/identical — falling back to index order."
    uuid_a="$(echo "$all" | awk -F',' 'NR==1{print $2}')"
    uuid_b="$(echo "$all" | awk -F',' 'NR==2{print $2}')"
  fi

  write_unit "ollama-test-a.service" "$TEST_PORT_A" "$uuid_a" "Ollama (TEST A :${TEST_PORT_A}, GPU ${uuid_a})"
  write_unit "ollama-test-b.service" "$TEST_PORT_B" "$uuid_b" "Ollama (TEST B :${TEST_PORT_B}, GPU ${uuid_b})"

  systemctl enable --now ollama-test-a.service || true
  systemctl enable --now ollama-test-b.service || true

  info "Waiting for APIs"
  wait_api "127.0.0.1:${TEST_PORT_A}" || warn "API :${TEST_PORT_A} slow to start (will retry per model)"
  wait_api "127.0.0.1:${TEST_PORT_B}" || warn "API :${TEST_PORT_B} slow to start (will retry per model)"

  info "ollama version: $($OLLAMA_BIN --version 2>/dev/null || echo 'unknown')"
}

# Create optimized variant on the persistent endpoint (shared models store)
bake_variant(){ # base newname num_gpu
  local base="$1" newname="$2" ng="$3"
  { echo "FROM ${base}"; echo "PARAMETER num_gpu ${ng}"; } \
    | OLLAMA_HOST="http://${PULL_FROM}" "$OLLAMA_BIN" create -f - "$newname" >>"$CREATE_LOG" 2>&1
}

bench_once(){ # ep model label num_gpu gpu_label notes
  local ep="$1" model="$2" label="$3" ng="${4:-}" gpu_label="$5" notes="$6"
  local sfx unit gname guid gmem opts tokps

  sfx="$(suffix_for_ep "$ep")"
  unit="$(unit_for_ep "$ep")"
  IFS=',' read -r gname guid gmem <<<"$(gpu_info_from_unit "$unit")"

  opts="$(jq -n \
      --argjson ctx "$CTX" \
      --argjson batch "$BATCH" \
      --argjson pred "$PRED" \
      --argjson ng "${ng:-null}" \
      '($ng|type) as $t | {num_ctx:$ctx,batch:$batch,temperature:0,mirostat:0,seed:1,num_predict:$pred} + (if $t=="number" then {num_gpu:$ng} else {} end)')"

  local prompt="Write ok repeatedly for benchmarking."
  local out; out="$(curl_gen "$ep" "$model" "$opts" "$prompt" "$TIMEOUT_GEN" || true)"
  echo "==== bench ${ep} ${model} ====" >>"$BENCH_LOG"; echo "$out" >>"$BENCH_LOG"

  local last; last="$(echo "$out" | json_last_line || true)"
  if [ -z "$last" ]; then
    warn "[bench] ${label} ${model} on ${ep} -> no data (timeout/error)"
    return 1
  fi
  local ec ed; ec="$(echo "$last" | jq -r '.eval_count // 0')"
  ed="$(echo "$last" | jq -r '.eval_duration // 0')"
  tokps="$(calc_tokps "$ec" "$ed")"

  echo "$(date -Iseconds),$STACK,$ep,$unit,$sfx,$gpu_label,$model,$label,${ng:-default},$CTX,$BATCH,$PRED,$tokps,$gname,$guid,$gmem,$notes" >>"$CSV_FILE"
  ok "[bench] [$gpu_label] ${label} ${model} on ${ep}  ->  ${tokps} tok/s (ctx=$CTX, batch=$BATCH, num_gpu=${ng:-default})"
  echo "$tokps"
}

bench_base_as_is(){ # ep baseTag gpu_label
  local ep="$1" base="$2" glabel="$3" unit; unit="$(unit_for_ep "$ep")"
  systemctl restart "$unit" || true
  wait_api "$ep" || { warn "API $ep not up for base-as-is"; return 1; }
  bench_once "$ep" "$base" "base-as-is" "" "$glabel" "base_on_${ep}" >/dev/null || return 1
}

tune_and_bench_one(){ # ep baseTag aliasBase
  local ep="$1" base="$2" alias_base="$3"
  info "----> [${ep}] Tuning ${base} -> ${alias_base}"
  pull_if_missing "$base"

  # GPU label for naming/rows
  local unit gname guid gmem glabel
  unit="$(unit_for_ep "$ep")"
  IFS=',' read -r gname guid gmem <<<"$(gpu_info_from_unit "$unit")"
  glabel="$(gpu_label_from_name "$gname")"

  bench_base_as_is "$ep" "$base" "$glabel" || warn "base-as-is bench skipped for $base on $ep"

  local first_ok=0 best_tokps="0.00" best_name="" best_ng=""
  local notes="built_on_${PULL_FROM}"

  for ng in $NUM_GPU_CANDIDATES; do
    info "     Trying num_gpu=${ng} (build on :${PERSISTENT_PORT}) ..."
    local newname="${alias_base}-${glabel}-ng${ng}"

    if ! bake_variant "$base" "$newname" "$ng"; then
      warn "     x bake failed (see ${CREATE_LOG})"
      continue
    fi

    local tokps; tokps="$(bench_once "$ep" "$newname" "optimized" "$ng" "$glabel" "$notes" || echo "0.00")"
    awk -v a="$tokps" -v b="$best_tokps" 'BEGIN{exit !(a>b)}' && { best_tokps="$tokps"; best_name="$newname"; best_ng="$ng"; }

    if [ "$EXHAUSTIVE" -eq 0 ] && [ "$first_ok" -eq 0 ] && awk -v a="$tokps" 'BEGIN{exit !(a>0)}'; then
      first_ok=1
      local latest="${alias_base}-${glabel}"
      info "     Tagging convenience latest: ${latest}:latest -> ngpu=${ng}"
      bake_variant "$base" "$latest" "$ng" || warn "     re-bake for ${latest} failed"
      break
    fi
  done

  if [ -n "$best_name" ]; then
    ok "Best on ${ep}: [${glabel}] ${best_name} (num_gpu=${best_ng}) at ${best_tokps} tok/s"
    echo "${ep},${alias_base},${best_name},${best_ng},${best_tokps},${glabel}" >>"${SUMMARY_FILE}.raw"
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

# Prepare services (won’t fight an already-running :11434)
{
  ensure_services
} || {
  err "Service setup failed"; exit 1;
}

# Ensure test ports are up (restart quietly)
for ep in "${ENDPOINTS[@]}"; do
  restart_ep "$ep" || true
  wait_api "$ep" || warn "API $ep is not up yet (continuing)"
enddone || true  # shellcheck disable=SC2317

# Run sweep per model on each test endpoint
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
  tail -n +2 "$CSV_FILE" | sort -t',' -k13,13nr | head -n5 \
    | awk -F',' '{printf "  %-2s %-20s %-32s %-12s %7.2f tok/s  (%s %s ngpu=%s)\n",$5,$7,$8,$6,$13,$1,$3,$9}'
} | tee "${SUMMARY_FILE}"

echo "✔ DONE. CSV: ${CSV_FILE}"
echo "✔ DONE. Summary: ${SUMMARY_FILE}"

