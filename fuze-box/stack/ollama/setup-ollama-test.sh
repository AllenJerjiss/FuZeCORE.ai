#!/usr/bin/env bash
# setup-ollama-one.sh
# One-at-a-time model tuning + benchmarking with an always-on puller on :11434
# Tested with Bash; avoid /bin/sh. Requires: curl, jq, awk, sed, systemd, lsof (or ss), nvidia-smi

set -euo pipefail

########## CONFIG (override via env) ###########################################
# Persistent downloader (ALWAYS kept running; shared model dir)
PERSISTENT_PORT="${PERSISTENT_PORT:-11434}"

# Two GPU-bound test endpoints (these are the only ones we start/stop/kill)
TEST_PORT_A="${TEST_PORT_A:-11435}"
TEST_PORT_B="${TEST_PORT_B:-11436}"

# Model store shared by all services (so pulls on :11434 are visible to tests)
OLLAMA_MODELS_DIR="${OLLAMA_MODELS_DIR:-/FuZe/ollama/models}"
LOG_DIR="${LOG_DIR:-/FuZe/logs}"

# Models to try: format "baseTag|aliasBase"
MODELS=(
  "llama4:16x17b|llama4-16x17b"
  "deepseek-r1:70b|deepseek-r1-70b"
  "llama4:128x17b|llama4-128x17b"
)

# num_gpu sweep (from high->low)
NUM_GPU_CANDIDATES="${NUM_GPU_CANDIDATES:-80 72 64 56 48 40 32 24 16}"

# Bench params (short and repeatable)
CTX="${CTX:-1024}"
BATCH="${BATCH:-32}"
PRED="${PRED:-256}"

# Behavior toggles
EXHAUSTIVE="${EXHAUSTIVE:-0}"  # 0 = stop at first good num_gpu; 1 = bench all that load
VERBOSE="${VERBOSE:-1}"        # 0 = quieter

# Timeouts (seconds)
WAIT_API_SECS="${WAIT_API_SECS:-60}"
TIMEOUT_GEN="${TIMEOUT_GEN:-40}"
TIMEOUT_TAGS="${TIMEOUT_TAGS:-10}"
TIMEOUT_PULL="${TIMEOUT_PULL:-600}"

# System user HOME for services (fixes "$HOME is not defined")
SERVICE_HOME="${SERVICE_HOME:-/root}"

# Which GPU to bind to :11435 and :11436 (by substring match on name) – best effort
MATCH_GPU_A="${MATCH_GPU_A:-5090}"
MATCH_GPU_B="${MATCH_GPU_B:-3090 Ti}"

###############################################################################

readonly OLLAMA_BIN="/usr/local/bin/ollama"
readonly HOSTNAME_NOW="$(hostname -s 2>/dev/null || hostname)"
readonly TS="$(date +%Y%m%d_%H%M%S)"
readonly CSV_FILE="${LOG_DIR}/ollama_bench_${TS}.csv"
readonly SUMMARY_FILE="${LOG_DIR}/${HOSTNAME_NOW}-${TS}.benchmark"
readonly PULL_FROM="127.0.0.1:${PERSISTENT_PORT}"

# test endpoints array
ENDPOINTS=("127.0.0.1:${TEST_PORT_A}" "127.0.0.1:${TEST_PORT_B}")

# Colors
c_bold="\033[1m"; c_red="\033[31m"; c_green="\033[32m"; c_yellow="\033[33m"; c_reset="\033[0m"

log()   { echo -e "$*"; }
info()  { [ "$VERBOSE" -ne 0 ] && echo -e "${c_bold}==${c_reset} $*"; }
ok()    { echo -e "${c_green}✔${c_reset} $*"; }
warn()  { echo -e "${c_yellow}!${c_reset} $*"; }
err()   { echo -e "${c_red}✖${c_reset} $*" >&2; }

need() {
  command -v "$1" >/dev/null 2>&1 || { err "Missing dependency: $1"; exit 1; }
}

calc_tokps() { # args: eval_count eval_duration_ns
  awk -v ec="$1" -v ed="$2" 'BEGIN { if (ed<=0) {print "0.00"} else {printf("%.2f", ec/(ed/1e9))} }'
}

mkdir -p "$OLLAMA_MODELS_DIR" "$LOG_DIR"

need curl; need jq; need awk; need sed; need systemctl; need nvidia-smi
if ! command -v lsof >/dev/null 2>&1 && ! command -v ss >/dev/null 2>&1; then
  warn "Neither lsof nor ss found — port-based pkill may be limited."
fi

# CSV header
echo "ts,endpoint,unit,suffix,model,variant,num_gpu,num_ctx,batch,num_predict,tokens_per_sec,gpu_name,gpu_uuid,gpu_mem_mib" >"$CSV_FILE"

# Small helpers
json_last_line() { grep -E '"done":\s*true' | tail -n1; }

curl_tags() {
  local ep="$1"
  curl -fsS --max-time "$TIMEOUT_TAGS" "http://${ep}/api/tags" || return 1
}

curl_gen() {
  local ep="$1" model="$2" opts="$3" prompt="$4" to="$5"
  curl -sS --max-time "$to" -H 'Content-Type: application/json' \
    -d "{\"model\":\"${model}\",\"options\":${opts},\"prompt\":\"${prompt}\"}" \
    "http://${ep}/api/generate" || return 1
}

gpu_table() {
  nvidia-smi --query-gpu=index,uuid,name,memory.total --format=csv,noheader | sed 's/, /,/g'
}

# map endpoint -> unit name and suffix
unit_for_ep() {
  local ep="$1" port="${ep##*:}"
  case "$port" in
    "$TEST_PORT_A") echo "ollama-test-a.service";;
    "$TEST_PORT_B") echo "ollama-test-b.service";;
    "$PERSISTENT_PORT") echo "ollama-persist.service";;
    *) echo "ollama-unknown-${port}.service";;
  esac
}
suffix_for_ep() {
  local ep="$1" port="${ep##*:}"
  case "$port" in
    "$TEST_PORT_A") echo "A";;
    "$TEST_PORT_B") echo "B";;
    *) echo "X";;
  esac
}

# kill only process that listens on a given port (not used for :11434)
kill_port_listener() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    local pid
    pid="$(lsof -iTCP -sTCP:LISTEN -P 2>/dev/null | awk -v p=":${port}" '$9 ~ p {print $2}' | head -n1 || true)"
    if [ -n "${pid:-}" ]; then
      warn "Killing listener PID ${pid} on :${port}"
      kill -9 "$pid" || true
    fi
  elif command -v ss >/dev/null 2>&1; then
    local pid
    pid="$(ss -ltnp 2>/dev/null | awk -v p=":${port}" '$4 ~ p {print $7}' | sed -E 's/.*pid=([0-9]+).*/\1/' | head -n1 || true)"
    if [ -n "${pid:-}" ]; then
      warn "Killing listener PID ${pid} on :${port}"
      kill -9 "$pid" || true
    fi
  fi
}

wait_api() {
  local ep="$1" secs="${2:-$WAIT_API_SECS}"
  local t=0
  while [ "$t" -lt "$secs" ]; do
    if curl -fsS --max-time 1 "http://${ep}/api/tags" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1; t=$((t+1))
  done
  return 1
}

offload_summary() { # unit -> "gpu_name,gpu_uuid,gpu_mem_mib"
  # The unit binds CUDA_VISIBLE_DEVICES to single UUID; look up that UUID for pretty line
  local unit="$1"
  local uuid
  uuid="$(systemctl show "$unit" -p Environment 2>/dev/null \
    | tr '\n' ' ' | sed -E 's/.*CUDA_VISIBLE_DEVICES=([^ ]+).*/\1/')"
  if [ -z "${uuid:-}" ]; then
    echo ",,"
    return 0
  fi
  local row
  row="$(gpu_table | grep "$uuid" || true)"
  if [ -z "$row" ]; then
    echo ",,"
  else
    IFS=',' read -r idx u name mem <<<"$row"
    echo "$name,$u,${mem%% MiB}"
  fi
}

have_model() {
  local tag="$1"
  OLLAMA_HOST="http://${PULL_FROM}" "$OLLAMA_BIN" list 2>/dev/null \
    | awk '{print $1}' | grep -Fxq "$tag"
}

pull_if_missing() {
  local base="$1"
  if have_model "$base"; then
    info "Base image ${base} already present (via ${PULL_FROM})"
  else
    info "Pulling ${base} via ${PULL_FROM} (leaves :${PERSISTENT_PORT} up)"
    OLLAMA_HOST="http://${PULL_FROM}" "$OLLAMA_BIN" pull "$base" || warn "pull of $base failed"
  fi
}

append_csv_row() { echo "$*" >>"$CSV_FILE"; }

###############################################################################
# Systemd units
write_unit() {
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
User=root

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

restart_ep() {
  local ep="$1" unit; unit="$(unit_for_ep "$ep")"
  local port="${ep##*:}"
  # never kill the persistent :11434
  if [ "$port" != "$PERSISTENT_PORT" ]; then
    systemctl stop "$unit" >/dev/null 2>&1 || true
    # nuke stray listener on that port if any
    kill_port_listener "$port"
  fi
  systemctl start "$unit"
}

###############################################################################
# GPU binding selection (best-effort match)
pick_uuid_by_name_substr() {
  local needle="$1"
  gpu_table | while IFS=',' read -r idx uuid name mem; do
    if echo "$name" | grep -qi "$needle"; then
      echo "$uuid"
      return 0
    fi
  done
}

# Prepare services
prepare_services() {
  info "Preparing directories and services"
  mkdir -p "$OLLAMA_MODELS_DIR" "$LOG_DIR"

  local all_gpus; all_gpus="$(gpu_table)"; log "$all_gpus" | sed 's/^/GPU: /'

  # persistent downloader on :11434 (no GPU binding)
  write_unit "ollama-persist.service" "$PERSISTENT_PORT" "" "Ollama (persistent downloader on :${PERSISTENT_PORT})"
  systemctl enable --now ollama-persist.service

  # Map test endpoints to specific GPUs by name match, else fallback to first/second
  local uuid_a uuid_b
  uuid_a="$(pick_uuid_by_name_substr "$MATCH_GPU_A" || true)"
  uuid_b="$(pick_uuid_by_name_substr "$MATCH_GPU_B" || true)"
  if [ -z "${uuid_a:-}" ] || [ -z "${uuid_b:-}" ] || [ "$uuid_a" = "$uuid_b" ]; then
    warn "GPU name match failed or identical; falling back to index order."
    # first two UUIDs
    uuid_a="$(echo "$all_gpus" | awk -F',' 'NR==1{print $2}')"
    uuid_b="$(echo "$all_gpus" | awk -F',' 'NR==2{print $2}')"
  fi

  write_unit "ollama-test-a.service" "$TEST_PORT_A" "$uuid_a" "Ollama (TEST A on :${TEST_PORT_A}, GPU ${uuid_a})"
  write_unit "ollama-test-b.service" "$TEST_PORT_B" "$uuid_b" "Ollama (TEST B on :${TEST_PORT_B}, GPU ${uuid_b})"

  systemctl enable --now ollama-test-a.service
  systemctl enable --now ollama-test-b.service

  # wait for all three APIs
  info "Waiting for APIs"
  wait_api "127.0.0.1:${PERSISTENT_PORT}" || { err "API :${PERSISTENT_PORT} did not come up"; exit 1; }
  wait_api "127.0.0.1:${TEST_PORT_A}" || warn "API :${TEST_PORT_A} slow to start (will retry as needed)"
  wait_api "127.0.0.1:${TEST_PORT_B}" || warn "API :${TEST_PORT_B} slow to start (will retry as needed)"
}

###############################################################################
# Baking & benchmarking

bake_variant() { # ep base newname num_gpu
  local ep="$1" base="$2" newname="$3" ng="$4"
  # create from a transient Modelfile (no file left behind)
  {
    echo "FROM ${base}"
    echo "PARAMETER num_gpu ${ng}"
  } | OLLAMA_HOST="http://${ep}" "$OLLAMA_BIN" create -f - "$newname"
}

bench_once() { # ep model label num_gpu
  local ep="$1" model="$2" label="$3" ng="$4"
  local sfx unit opts prompt last ec ed tokps gname guid gmem

  sfx="$(suffix_for_ep "$ep")"
  unit="$(unit_for_ep "$ep")"
  read -r gname guid gmem <<<"$(offload_summary "$unit")"

  # options
  opts="$(jq -n \
    --argjson ctx "$CTX" --argjson batch "$BATCH" --argjson pred "$PRED" \
    --argjson ng "${ng:-null}" \
    '{num_ctx:$ctx, batch:$batch, temperature:0, mirostat:0, seed:1}
     + ( $ng|type=="number" ? {num_gpu:$ng, num_predict:$pred} : {num_predict:$pred} )')"

  prompt="Write ok repeatedly for benchmarking."
  local out; out="$(curl_gen "$ep" "$model" "$opts" "$prompt" "$TIMEOUT_GEN" || true)"
  local last; last="$(echo "$out" | json_last_line || true)"
  if [ -z "$last" ]; then
    warn "[bench] ${label} ${model} on ${ep} -> no data (timeout or error)"
    return 1
  fi
  local ec ed; ec="$(echo "$last" | jq -r '.eval_count // 0')"
  ed="$(echo "$last" | jq -r '.eval_duration // 0')"
  tokps="$(calc_tokps "$ec" "$ed")"

  append_csv_row "$(date -Iseconds),$ep,$unit,$sfx,$model,$label,${ng:-default},$CTX,$BATCH,$PRED,$tokps,$gname,$guid,$gmem"
  ok "[bench] ${label} ${model} on ${ep}  ->  ${tokps} tok/s (ctx=$CTX, batch=$BATCH, num_gpu=${ng:-default})"
  echo "$tokps"
}

bench_base_as_is() { # ep baseTag
  local ep="$1" base="$2"
  local unit; unit="$(unit_for_ep "$ep")"
  systemctl restart "$unit" || true
  wait_api "$ep" || { warn "API $ep not up for base-as-is"; return 1; }
  bench_once "$ep" "$base" "base-as-is" "" >/dev/null || return 1
}

tune_and_bench_one() { # ep baseTag aliasBase
  local ep="$1" base="$2" alias_base="$3"
  info "----> [${ep}] Tuning ${base} -> ${alias_base}"
  # ensure base exists
  pull_if_missing "$base"

  # bench base as-is
  bench_base_as_is "$ep" "$base" || warn "base-as-is bench skipped for $base on $ep"

  # sweep num_gpu
  local first_ok=0
  local best_tokps="0.00"
  local best_name=""
  local best_ng=""

  local unit; unit="$(unit_for_ep "$ep")"
  systemctl restart "$unit" || true
  wait_api "$ep" || { warn "API $ep not up before sweep, attempting anyway"; }

  for ng in $NUM_GPU_CANDIDATES; do
    info "     Trying num_gpu=${ng} ..."
    local newname="${alias_base}-$(suffix_for_ep "$ep")-ng${ng}"

    # bake it
    if ! bake_variant "$ep" "$base" "$newname" "$ng" >/dev/null 2>&1; then
      warn "     x bake failed (likely OOM while composing image)"
      continue
    fi

    # smoke/bench
    local tokps; tokps="$(bench_once "$ep" "$newname" "optimized" "$ng" || echo "0.00")"
    # keep best
    awk -v a="$tokps" -v b="$best_tokps" 'BEGIN{exit !(a>b)}' && {
      best_tokps="$tokps"; best_name="$newname"; best_ng="$ng";
    }

    if [ "$EXHAUSTIVE" -eq 0 ] && [ "$first_ok" -eq 0 ] && [ "$(echo "$tokps > 0.0" | bc -l)" -eq 1 ]; then
      first_ok=1
      # also bake a simple ":latest" tag for convenience (one per GPU suffix)
      local latest="${alias_base}-$(suffix_for_ep "$ep")"
      if ! OLLAMA_HOST="http://${ep}" "$OLLAMA_BIN" list 2>/dev/null | awk '{print $1}' | grep -Fxq "${latest}:latest"; then
        info "     Baking ${latest}:latest using num_gpu=${ng}"
        bake_variant "$ep" "$base" "$latest" "$ng" || warn "     bake of ${latest} failed"
      fi
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

###############################################################################
# Main

echo -e "${c_bold}== One-at-a-time auto-tune + bench (POSIX) ==${c_reset}"
log "Persistent : ${PULL_FROM}"
log "Test EPs   : 127.0.0.1:${TEST_PORT_A}  127.0.0.1:${TEST_PORT_B}"
log "Models     : $(printf '%s ' "${MODELS[@]}")"
log "CSV        : ${CSV_FILE}"
log "Summary    : ${SUMMARY_FILE}"

prepare_services

# sanity: persistent reachable
wait_api "$PULL_FROM" || { err "Persistent API ${PULL_FROM} not reachable"; exit 1; }

# For each endpoint, (re)start its unit and ensure up
for ep in "${ENDPOINTS[@]}"; do
  restart_ep "$ep" || true
  if ! wait_api "$ep"; then
    warn "API $ep is not up yet (continuing; per-model logic will retry)."
  fi
done

# Iterate models × endpoints
for m in "${MODELS[@]}"; do
  base="${m%%|*}"; alias_base="${m##*|}"
  for ep in "${ENDPOINTS[@]}"; do
    # never operate on the persistent :11434 here
    if [ "${ep##*:}" = "$PERSISTENT_PORT" ]; then continue; fi
    # restart bound unit cleanly before every model
    restart_ep "$ep" || true
    if ! wait_api "$ep"; then
      err "ERROR: API ${ep} did not come up — skipping ${base} on ${ep}"
      continue
    fi
    tune_and_bench_one "$ep" "$base" "$alias_base"
  done
done

# Final pretty summary (base-as-is + optimized are already in CSV; pick “best optimized” lines)
{
  echo "=== Final Summary @ ${HOSTNAME_NOW} ${TS} ==="
  echo "CSV: ${CSV_FILE}"
  echo
  if [ -s "${SUMMARY_FILE}.raw" ]; then
    echo "Best optimized per (endpoint, model):"
    # endpoint,alias_base,best_name,ng,tokps
    column -t -s',' "${SUMMARY_FILE}.raw"
  else
    echo "No optimized variants succeeded."
  fi

  echo
  echo "Top-5 runs overall (by tokens/sec) from CSV:"
  # skip header, sort by tokens_per_sec (11th col), take 5
  tail -n +2 "$CSV_FILE" | sort -t',' -k11,11gr | head -n5 \
    | awk -F',' '{printf "  %-21s %-18s %6.2f tok/s  (%s %s ngpu=%s)\n",$4,$5,$11,$1,$2,$7}'
} | tee "${SUMMARY_FILE}"

ok "DONE. CSV: ${CSV_FILE}"
ok "DONE. Summary: ${SUMMARY_FILE}"

# NOTE: we never kill / restart the persistent :11434; only the test units are manipulated.

