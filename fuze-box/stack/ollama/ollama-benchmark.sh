#!/usr/bin/env bash
# ollama-benchmark.sh
# One-at-a-time model tuning + benchmarking with an always-on puller on :11434
# - Auto-detects persistent store path and aligns test daemons to it
# - Builds variants on :11434; benches on :11435/:11436
# - Writes CSV + human summary in local logs/

set -euo pipefail

########## CONFIG (override with env) ##########################################
PERSISTENT_PORT="${PERSISTENT_PORT:-11434}"   # always-on downloader, never killed
TEST_PORT_A="${TEST_PORT_A:-11435}"           # test instance A (GPU-A)
TEST_PORT_B="${TEST_PORT_B:-11436}"           # test instance B (GPU-B)

# LOGS default: ../logs from this script folder (i.e., stack/logs)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_LOG_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)/logs"
LOG_DIR="${LOG_DIR:-$DEFAULT_LOG_DIR}"

# Model store: auto-detected from :11434; fallback if not detectable
OLLAMA_MODELS_DIR="${OLLAMA_MODELS_DIR:-}"

# Base models to try, plus alias root for optimized variants
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

# Service HOME to silence "$HOME not defined"
SERVICE_HOME="${SERVICE_HOME:-/root}"

# GPU name substrings to bind A/B (fallback to index order)
MATCH_GPU_A="${MATCH_GPU_A:-5090}"
MATCH_GPU_B="${MATCH_GPU_B:-3090 Ti}"

STACK=ollama
################################################################################

# Paths, files, colors
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"
readonly OLLAMA_BIN="${OLLAMA_BIN:-/usr/local/bin/ollama}"
readonly HOSTNAME_NOW="$(hostname -s 2>/dev/null || hostname)"
readonly TS="$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG_DIR"
readonly CSV_FILE="${LOG_DIR}/${STACK}_bench_${TS}.csv"
readonly SUMMARY_FILE="${LOG_DIR}/${HOSTNAME_NOW}-${TS}.benchmark"
readonly CREATE_LOG="${LOG_DIR}/ollama_create_${TS}.log"

ENDPOINTS=("127.0.0.1:${TEST_PORT_A}" "127.0.0.1:${TEST_PORT_B}")

c_bold="\033[1m"; c_red="\033[31m"; c_green="\033[32m"; c_yellow="\033[33m"; c_reset="\033[0m"
log(){ echo -e "$*"; }
info(){ [ "$VERBOSE" -ne 0 ] && echo -e "${c_bold}==${c_reset} $*"; }
ok(){ echo -e "${c_green}✔${c_reset} $*"; }
warn(){ echo -e "${c_yellow}!${c_reset} $*"; }
err(){ echo -e "${c_red}✖${c_reset} $*" >&2; }
need(){ command -v "$1" >/dev/null 2>&1 || { err "Missing dependency: $1"; exit 1; }; }

need curl; need jq; need awk; need sed; need systemctl; need nvidia-smi
command -v lsof >/dev/null 2>&1 || command -v ss >/dev/null 2>&1 || warn "Neither lsof nor ss found — port cleanup limited."

# CSV header
echo "ts,endpoint,unit,suffix,gpu_label,base,variant,num_gpu,num_ctx,batch,num_predict,tokens_per_sec,gpu_name,gpu_uuid,gpu_mem_mib" >"$CSV_FILE"

json_last_line(){ grep -E '"done":\s*true' | tail -n1; }
gpu_table(){ nvidia-smi --query-gpu=index,uuid,name,memory.total --format=csv,noheader | sed 's/, /,/g'; }
calc_tokps(){ awk -v ec="$1" -v ed="$2" 'BEGIN{ if(ed<=0){print "0.00"} else {printf("%.2f", ec/(ed/1e9))} }'; }
curl_tags(){ local ep="$1"; curl -fsS --max-time "$TIMEOUT_TAGS" "http://${ep}/api/tags" || return 1; }

# POST /api/generate with JSON built via jq (safe quoting)
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
  else
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

# Read GPU UUID bound to a unit and map to (name, uuid, mem)
offload_summary(){
  local unit="$1" uuid row
  uuid="$(systemctl show "$unit" -p Environment 2>/dev/null | tr '\n' ' ' | sed -E 's/.*CUDA_VISIBLE_DEVICES=([^ ]+).*/\1/')"
  [ -z "${uuid:-}" ] && { echo ",,"; return 0; }
  row="$(gpu_table | grep "$uuid" || true)"
  [ -z "$row" ] && { echo ",,"; return 0; }
  IFS=',' read -r _idx u name mem <<<"$row"
  echo "$name,$u,${mem%% MiB}"
}

normalize_gpu_label(){
  # "NVIDIA GeForce RTX 5090" -> "nvidia-5090"
  # "NVIDIA GeForce RTX 3090 Ti" -> "nvidia-3090ti"
  local s="$1"
  s="$(echo "$s" | tr '[:upper:]' '[:lower:]')"
  s="${s//nvidia/}"
  s="${s//geforce/}"
  s="${s//rtx/}"
  s="$(echo "$s" | sed -E 's/[[:space:]]+/ /g;s/^ //;s/ $//')"
  s="${s// /-}"
  s="nvidia-${s}"
  s="${s//--/-}"
  echo "$s"
}

have_model(){
  local host="$1" tag="$2"
  OLLAMA_HOST="http://${host}" "$OLLAMA_BIN" list 2>/dev/null | awk '{print $1}' | grep -Fxq "$tag"
}

pull_if_missing(){
  local host="$1" base="$2"
  if have_model "$host" "$base"; then
    info "Base ${base} present on ${host}"
  else
    info "Pulling ${base} via ${host} (timeout ${TIMEOUT_PULL}s)"
    OLLAMA_HOST="http://${host}" "$OLLAMA_BIN" pull "$base" || warn "pull of $base failed on ${host}"
  fi
}

write_unit(){
  local name="$1" listen="$2" uuid_env="$3" desc="$4" models_dir="$5"
  cat >/etc/systemd/system/"$name" <<EOF
[Unit]
Description=${desc}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HOME=${SERVICE_HOME}
Environment=OLLAMA_HOST=127.0.0.1:${listen}
Environment=OLLAMA_MODELS=${models_dir}
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
  gpu_table | while IFS=',' read -r idx uuid name mem; do
    echo "$name" | grep -qi "$needle" && { echo "$uuid"; return 0; }
  done
}

pid_for_port(){
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp 2>/dev/null | awk -v p=":${port}" '$4 ~ p {print $7}' | sed -E 's/.*pid=([0-9]+).*/\1/' | head -n1
  else
    lsof -iTCP -sTCP:LISTEN -P 2>/dev/null | awk -v p=":${port}" '$9 ~ p {print $2}' | head -n1
  fi
}

detect_models_dir_from_pid(){
  local pid="$1" val=""
  # Try env
  if [ -r "/proc/${pid}/environ" ]; then
    val="$(tr '\0' '\n' <"/proc/${pid}/environ" | grep '^OLLAMA_MODELS=' | sed 's/^OLLAMA_MODELS=//')"
    [ -n "$val" ] && { echo "$val"; return 0; }
  fi
  # Try runner --model path -> .../models/...
  if [ -r "/proc/${pid}/cmdline" ]; then
    local cmd; cmd="$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null || true)"
    echo "$cmd" | grep -q -- '--model ' || true
    local mpath; mpath="$(echo "$cmd" | sed -n 's#.*--model \([^ ]\+\).*#\1#p' || true)"
    if [ -n "${mpath:-}" ]; then
      local root; root="$(echo "$mpath" | sed -E 's#/blobs/sha256-.*$##')"
      echo "$root"
      return 0
    fi
  fi
  return 1
}

ensure_models_dir(){
  # If provided via env, trust it
  if [ -n "${OLLAMA_MODELS_DIR:-}" ]; then
    mkdir -p "$OLLAMA_MODELS_DIR"
    echo "$OLLAMA_MODELS_DIR"
    return 0
  fi
  # Else detect from persistent port
  local pid; pid="$(pid_for_port "$PERSISTENT_PORT" || true)"
  if [ -n "$pid" ]; then
    local d; d="$(detect_models_dir_from_pid "$pid" || true)"
    if [ -n "$d" ]; then
      mkdir -p "$d"
      echo "$d"
      return 0
    fi
  fi
  # Fallbacks
  for guess in /FuZe/ollama/models /FuZe/models/ollama; do
    if [ -d "$guess" ]; then
      echo "$guess"; return 0
    fi
  done
  mkdir -p /FuZe/ollama/models
  echo "/FuZe/ollama/models"
}

symlink_compat_if_needed(){
  local primary="$1"
  # create /FuZe/models/ollama -> primary if missing and parent exists
  if [ ! -e /FuZe/models/ollama ]; then
    if mkdir -p /FuZe/models 2>/dev/null; then
      ln -sfn "$primary" /FuZe/models/ollama || true
    fi
  fi
}

prepare_services(){
  info "Preparing directories and services"
  mkdir -p "$LOG_DIR"

  local all; all="$(gpu_table)"
  log "$(echo "$all" | sed 's/^/GPU: /')"

  # Determine + align model store
  local models_dir; models_dir="$(ensure_models_dir)"
  OLLAMA_MODELS_DIR="$models_dir"
  symlink_compat_if_needed "$OLLAMA_MODELS_DIR"

  # Show Ollama version if available
  if "$OLLAMA_BIN" --version >/dev/null 2>&1; then
    info "ollama version: $("$OLLAMA_BIN" --version 2>&1)"
  fi

  # If something is already listening on :11434, we DO NOT touch it (persistent)
  if curl -fsS --max-time 1 "http://127.0.0.1:${PERSISTENT_PORT}/api/tags" >/dev/null 2>&1; then
    info "Using existing Ollama on :${PERSISTENT_PORT}"
  else
    # Optional: create a controlled persistent service (disabled by default)
    warn "No responder on :${PERSISTENT_PORT}. If you want me to manage a persistent daemon, set MANAGE_PERSIST=1"
    if [ "${MANAGE_PERSIST:-0}" = "1" ]; then
      write_unit "ollama-persist.service" "$PERSISTENT_PORT" "" "Ollama (persistent :${PERSISTENT_PORT})" "$OLLAMA_MODELS_DIR"
      systemctl enable --now ollama-persist.service
    fi
  fi

  # GPU UUIDs
  local uuid_a uuid_b
  uuid_a="$(pick_uuid_by_name_substr "$MATCH_GPU_A" || true)"
  uuid_b="$(pick_uuid_by_name_substr "$MATCH_GPU_B" || true)"
  if [ -z "${uuid_a:-}" ] || [ -z "${uuid_b:-}" ] || [ "$uuid_a" = "$uuid_b" ]; then
    warn "GPU match failed/identical — falling back to index order."
    uuid_a="$(echo "$all" | awk -F',' 'NR==1{print $2}')"
    uuid_b="$(echo "$all" | awk -F',' 'NR==2{print $2}')"
  fi

  # Test services (we control these)
  write_unit "ollama-test-a.service" "$TEST_PORT_A" "$uuid_a" "Ollama (TEST A :${TEST_PORT_A})" "$OLLAMA_MODELS_DIR"
  write_unit "ollama-test-b.service" "$TEST_PORT_B" "$uuid_b" "Ollama (TEST B :${TEST_PORT_B})" "$OLLAMA_MODELS_DIR"

  systemctl enable --now ollama-test-a.service || true
  systemctl enable --now ollama-test-b.service || true

  info "Waiting for APIs"
  wait_api "127.0.0.1:${PERSISTENT_PORT}" || warn "API :${PERSISTENT_PORT} not immediately reachable"
  wait_api "127.0.0.1:${TEST_PORT_A}" || warn "API :${TEST_PORT_A} slow to start (will retry per model)"
  wait_api "127.0.0.1:${TEST_PORT_B}" || warn "API :${TEST_PORT_B} slow to start (will retry per model)"

  # Final base presence check (on persistent)
  for m in "${MODELS[@]}"; do
    base="${m%%|*}"
    pull_if_missing "127.0.0.1:${PERSISTENT_PORT}" "$base"
  done
}

append_csv_row(){ echo "$*" >>"$CSV_FILE"; }

bench_once(){ # ep base_or_variant label gpu_label num_gpu
  local ep="$1" model="$2" label="$3" gpu_label="$4" ng="${5:-}"
  local sfx unit gname guid gmem opts tokps

  sfx="$(suffix_for_ep "$ep")"
  unit="$(unit_for_ep "$ep")"
  IFS=',' read -r gname guid gmem <<<"$(offload_summary "$unit")"

  # Build options JSON safely
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
    return 1
  fi
  local ec ed; ec="$(echo "$last" | jq -r '.eval_count // 0')"
  ed="$(echo "$last" | jq -r '.eval_duration // 0')"
  tokps="$(calc_tokps "$ec" "$ed")"

  append_csv_row "$(date -Iseconds),$ep,$unit,$sfx,$gpu_label,$BASE_TAG,$model,${ng:-default},$CTX,$BATCH,$PRED,$tokps,$gname,$guid,$gmem"
  ok "[bench] ${sfx} ${model} (${gpu_label}) on ${ep}  ->  ${tokps} tok/s (ctx=$CTX, batch=$BATCH, num_gpu=${ng:-default})"
  echo "$tokps"
}

bench_base_as_is(){ # ep baseTag gpu_label
  local ep="$1" base="$2" gl="$3" unit; unit="$(unit_for_ep "$ep")"
  systemctl restart "$unit" || true
  wait_api "$ep" || { warn "API $ep not up for base-as-is"; return 1; }
  bench_once "$ep" "$base" "base-as-is" "$gl" "" >/dev/null || return 1
}

# Build optimized variant on :11434 and wait until test endpoint can see it
bake_variant(){ # persistent_host test_ep base alias_root gpu_label ng
  local host="$1" ep="$2" base="$3" alias_root="$4" gl="$5" ng="$6"
  local variant="${alias_root}-${gl}-ng${ng}"

  {
    echo "FROM ${base}"
    echo "PARAMETER num_gpu ${ng}"
  } | OLLAMA_HOST="http://${host}" "$OLLAMA_BIN" create -f - "$variant" >>"$CREATE_LOG" 2>&1 \
    || return 1

  # Wait up to 12s for tag visibility on test endpoint; restart once at 6s
  local seen=0
  for i in $(seq 1 12); do
    if curl -fsS "http://${ep}/api/tags" | jq -r '.models[].name' | grep -Fxq "$variant"; then
      seen=1; break
    fi
    if [ "$i" -eq 6 ]; then
      systemctl restart "$(unit_for_ep "$ep")" || true
      wait_api "$ep" || true
    fi
    sleep 1
  done
  [ "$seen" -eq 1 ] || warn "Variant ${variant} not visible yet on ${ep}"
  echo "$variant"
}

tune_and_bench_one(){ # ep baseTag alias_root
  local ep="$1" base="$2" alias_root="$3"
  local sfx; sfx="$(suffix_for_ep "$ep")"
  info "----> [${ep}] Tuning ${base} -> variants ${alias_root}-<gpu>-ng<NUM>"

  # GPU label from bound GPU
  local unit gname guid gmem glabel
  unit="$(unit_for_ep "$ep")"
  IFS=',' read -r gname guid gmem <<<"$(offload_summary "$unit")"
  glabel="$(normalize_gpu_label "${gname:-nvidia}")"

  BASE_TAG="$base" # exported to bench_once for CSV

  # Base-as-is sanity
  # If base is not listed on test port, warn (store mismatch or service down),
  # but proceed: bench_once will fail fast if truly not usable.
  if ! curl_tags "$ep" | jq -r '.models[].name' 2>/dev/null | grep -Fxq "$base"; then
    warn "Base ${base} NOT visible on ${ep}. Likely model store mismatch or slow startup."
  fi
  bench_base_as_is "$ep" "$base" "$glabel" || warn "base-as-is bench skipped for $base on $ep"

  # Sweep num_gpu
  local first_ok=0 best_tokps="0.00" best_name="" best_ng=""
  for ng in $NUM_GPU_CANDIDATES; do
    info "     Trying num_gpu=${ng} (build on :${PERSISTENT_PORT}) ..."
    local variant; variant="$(bake_variant "127.0.0.1:${PERSISTENT_PORT}" "$ep" "$base" "$alias_root" "$glabel" "$ng" || echo "")"
    if [ -z "$variant" ]; then
      warn "     x bake failed (see ${CREATE_LOG})"
      continue
    fi
    local tokps; tokps="$(bench_once "$ep" "$variant" "optimized" "$glabel" "$ng" || echo "0.00")"
    awk -v a="$tokps" -v b="$best_tokps" 'BEGIN{exit !(a>b)}' && { best_tokps="$tokps"; best_name="$variant"; best_ng="$ng"; }

    if [ "$EXHAUSTIVE" -eq 0 ] && [ "$first_ok" -eq 0 ] && awk -v a="$tokps" 'BEGIN{exit !(a>0)}'; then
      first_ok=1
      # Convenience tag "<alias_root>-<gpu>" pointing to first working ng
      local latest="${alias_root}-${glabel}"
      { echo "FROM ${base}"; echo "PARAMETER num_gpu ${ng}"; } \
        | OLLAMA_HOST="http://127.0.0.1:${PERSISTENT_PORT}" "$OLLAMA_BIN" create -f - "$latest" >>"$CREATE_LOG" 2>&1 || true
      break
    fi
  done

  if [ -n "$best_name" ]; then
    ok "Best on ${ep}: ${best_name} (num_gpu=${best_ng}) at ${best_tokps} tok/s"
    echo "${ep},${alias_root},${best_name},${best_ng},${best_tokps},${glabel}" >>"${SUMMARY_FILE}.raw"
  else
    warn "No working num_gpu for ${base} on ${ep}"
  fi
}

list_tags(){
  local host="$1" title="$2"
  echo "== Tags on ${host} (${title}) =="
  OLLAMA_HOST="http://${host}" "$OLLAMA_BIN" list 2>/dev/null || echo "(list failed)"
  echo
}

##################################### MAIN #####################################
echo -e "${c_bold}== One-at-a-time auto-tune + bench (POSIX) ==${c_reset}"
log "Persistent : 127.0.0.1:${PERSISTENT_PORT}"
log "Test EPs   : 127.0.0.1:${TEST_PORT_A}  127.0.0.1:${TEST_PORT_B}"
log "Models     : $(printf '%s ' "${MODELS[@]}")"
log "CSV        : ${CSV_FILE}"
log "Summary    : ${SUMMARY_FILE}"

prepare_services

# Show which bases are visible where (quick sanity)
for m in "${MODELS[@]}"; do
  base="${m%%|*}"
  info "Base visibility check: ${base}"
  for h in "127.0.0.1:${PERSISTENT_PORT}" "127.0.0.1:${TEST_PORT_A}" "127.0.0.1:${TEST_PORT_B}"; do
    if curl_tags "$h" | jq -r '.models[].name' 2>/dev/null | grep -Fxq "$base"; then
      log "  ${h}: ${base} visible"
    else
      warn "  ${h}: ${base} NOT visible"
    fi
  done
done

# Restart test EPs cleanly and make sure they’re up
for ep in "${ENDPOINTS[@]}"; do
  restart_ep "$ep" || true
  wait_api "$ep" || warn "API $ep is not up yet (continuing)"
done

# Tune/bench
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

# Tag inventory for your records
echo >>"$SUMMARY_FILE"
list_tags "127.0.0.1:${PERSISTENT_PORT}" "persistent"
list_tags "127.0.0.1:${TEST_PORT_A}" "test A"   | tee -a "$SUMMARY_FILE" >/dev/null
list_tags "127.0.0.1:${TEST_PORT_B}" "test B"   | tee -a "$SUMMARY_FILE" >/dev/null

# Final human summary
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
    | awk -F',' '{printf "  %-2s %-20s %-28s %-14s %6.2f tok/s  (%s %s ngpu=%s)\n",$4,$6,$7,$5,$12,$1,$2,$8}'
} | tee -a "${SUMMARY_FILE}"

ok "DONE. CSV: ${CSV_FILE}"
ok "DONE. Summary: ${SUMMARY_FILE}"
# NOTE: :11434 is never stopped; only :11435 and :11436 are started/stopped.

