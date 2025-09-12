#!/usr/bin/env bash
# ollama-benchmark.sh
# One-at-a-time model tuning + benchmarking with an always-on puller/builder on :11434

set -euo pipefail

########## CONFIG (override with env) ##########################################
PERSISTENT_PORT="${PERSISTENT_PORT:-11434}"  # ALWAYS ON (pull + build here)
TEST_PORT_A="${TEST_PORT_A:-11435}"          # test instance A (binds to GPU-A)
TEST_PORT_B="${TEST_PORT_B:-11436}"          # test instance B (binds to GPU-B)

OLLAMA_MODELS_DIR="${OLLAMA_MODELS_DIR:-/FuZe/ollama/models}"
LOG_DIR_DEFAULT="${LOG_DIR:-/FuZe/logs}"     # we’ll fallback to ./logs if unwritable

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
TIMEOUT_GEN="${TIMEOUT_GEN:-120}"
TIMEOUT_TAGS="${TIMEOUT_TAGS:-10}"
TIMEOUT_PULL="${TIMEOUT_PULL:-600}"

SERVICE_HOME="${SERVICE_HOME:-/root}"

# GPU name substrings we try to bind to A/B:
MATCH_GPU_A="${MATCH_GPU_A:-5090}"
MATCH_GPU_B="${MATCH_GPU_B:-3090 Ti}"
################################################################################

readonly OLLAMA_BIN="/usr/local/bin/ollama"
readonly HOSTNAME_NOW="$(hostname -s 2>/dev/null || hostname)"
readonly TS="$(date +%Y%m%d_%H%M%S)"

# Logs dir (fallback if not writable)
LOG_DIR="$LOG_DIR_DEFAULT"
mkdir -p "$LOG_DIR" 2>/dev/null || true
if [ ! -w "$LOG_DIR" ]; then
  LOG_DIR="$(pwd)/logs"
  mkdir -p "$LOG_DIR"
fi

readonly CSV_FILE="${LOG_DIR}/ollama_bench_${TS}.csv"
readonly SUMMARY_FILE="${LOG_DIR}/${HOSTNAME_NOW}-${TS}.benchmark"
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

echo "ts,endpoint,unit,suffix,model_base,tag_used,variant_label,gpu_label,num_gpu,num_ctx,batch,num_predict,tokens_per_sec,gpu_name,gpu_uuid,gpu_mem_mib" >"$CSV_FILE"

json_last_line(){ grep -E '"done":\s*true' | tail -n1; }
gpu_table(){ nvidia-smi --query-gpu=index,uuid,name,memory.total --format=csv,noheader | sed 's/, /,/g'; }

calc_tokps(){ awk -v ec="$1" -v ed="$2" 'BEGIN{ if(ed<=0){print "0.00"} else {printf("%.2f", ec/(ed/1e9))} }'; }

curl_tags(){ local ep="$1"; curl -fsS --max-time "$TIMEOUT_TAGS" "http://${ep}/api/tags" || return 1; }

curl_gen(){
  # Build payload with jq (safe quoting), then POST
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

offload_summary(){
  local unit="$1" uuid row
  uuid="$(systemctl show "$unit" -p Environment 2>/dev/null | tr '\n' ' ' | sed -E 's/.*CUDA_VISIBLE_DEVICES=([^ ]+).*/\1/')"
  [ -z "${uuid:-}" ] && { echo ",,,"; return 0; }
  row="$(gpu_table | grep "$uuid" || true)"
  [ -z "$row" ] && { echo ",,,"; return 0; }
  IFS=',' read -r idx u name mem <<<"$row"
  echo "$name,$u,${mem%% MiB}"
}

label_from_name(){
  # normalize a readable short label for tags/CSV (“5090”, “3090ti”, etc.)
  local name="$1"
  name="$(echo "$name" | tr '[:upper:]' '[:lower:]')"
  if echo "$name" | grep -q '5090'; then echo "5090"; return; fi
  if echo "$name" | grep -q '3090'; then echo "3090ti"; return; fi
  # fallback: strip vendor and spaces
  echo "$name" | sed -E 's/nvidia[[:space:]]+geforce[[:space:]]+//g; s/[[:space:]]+//g'
}

have_model(){
  local tag="$1"
  OLLAMA_HOST="http://${PULL_FROM}" "$OLLAMA_BIN" list 2>/dev/null | awk '{print $1}' | grep -Fxq "$tag"
}
pull_if_missing(){
  local base="$1"
  if have_model "$base"; then
    info "Base ${base} present (via ${PULL_FROM})"
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
Environment=PATH=/usr/local/bin:/usr/bin:/bin
Environment=OLLAMA_KEEP_ALIVE=4h
Environment=OLLAMA_LOG_LEVEL=debug
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
  if ! systemctl start "$unit"; then
    warn "Failed to start $unit"
    systemctl --no-pager -l status "$unit" || true
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
  log "$(echo "$all" | sed 's/^/GPU: /')"

  info "ollama version: $("$OLLAMA_BIN" --version || true)"

  # persistent downloader/builder on :11434
  write_unit "ollama-persist.service" "$PERSISTENT_PORT" "" "Ollama (persistent on :${PERSISTENT_PORT})"
  systemctl enable --now ollama-persist.service

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

# ==== BUILD OPT VARIANTS ON PERSISTENT ENDPOINT ONLY =========================
bake_variant_on_persist(){ # base alias gpu_label num_gpu -> newtag
  local base="$1" alias_base="$2" gpu_label="$3" ng="$4"
  local newtag="${alias_base}-${gpu_label}-ng${ng}"
  # Use a transient Modelfile; build on 11434 so tag is globally visible
  { echo "FROM ${base}"; echo "PARAMETER num_gpu ${ng}"; } \
    | OLLAMA_HOST="http://${PULL_FROM}" "$OLLAMA_BIN" create -f - "$newtag"
  echo "$newtag"
}

append_csv_row(){ echo "$*" >>"$CSV_FILE"; }

bench_once(){ # ep base_tag tag_used label gpu_label num_gpu
  local ep="$1" base="$2" tag="$3" label="$4" gpu_label="$5" ng="${6:-}"
  local sfx unit gname guid gmem opts tokps

  sfx="$(suffix_for_ep "$ep")"
  unit="$(unit_for_ep "$ep")"
  read -r gname guid gmem <<<"$(offload_summary "$unit")"

  # options JSON
  opts="$(jq -n \
      --argjson ctx "$CTX" \
      --argjson batch "$BATCH" \
      --argjson pred "$PRED" \
      --argjson ng "${ng:-null}" \
      '($ng|type) as $t | {num_ctx:$ctx,batch:$batch,temperature:0,mirostat:0,seed:1,num_predict:$pred} + (if $t=="number" then {num_gpu:$ng} else {} end)')"

  local prompt="Write ok repeatedly for benchmarking."
  local out; out="$(curl_gen "$ep" "$tag" "$opts" "$prompt" "$TIMEOUT_GEN" || true)"
  local last; last="$(echo "$out" | json_last_line || true)"
  if [ -z "$last" ]; then
    warn "[bench] ${label} ${tag} on ${ep} -> no data (timeout/error)"
    return 1
  fi
  local ec ed; ec="$(echo "$last" | jq -r '.eval_count // 0')"
  ed="$(echo "$last" | jq -r '.eval_duration // 0')"
  tokps="$(calc_tokps "$ec" "$ed")"

  append_csv_row "$(date -Iseconds),$ep,$unit,$sfx,$base,$tag,$label,$gpu_label,${ng:-default},$CTX,$BATCH,$PRED,$tokps,$gname,$guid,$gmem"
  ok "[bench] ${label} ${tag} on ${ep}  ->  ${tokps} tok/s (ctx=$CTX, batch=$BATCH, num_gpu=${ng:-default})"
  echo "$tokps"
}

bench_base_as_is(){ # ep baseTag gpu_label
  local ep="$1" base="$2" gpu_label="$3" unit; unit="$(unit_for_ep "$ep")"
  systemctl restart "$unit" || true
  if ! wait_api "$ep"; then
    warn "API $ep not up for base-as-is"
    systemctl --no-pager -l status "$unit" || true
    journalctl -n 50 -u "$unit" --no-pager || true
    return 1
  fi
  bench_once "$ep" "$base" "$base" "base" "$gpu_label" "" >/dev/null || return 1
}

tune_and_bench_one(){ # ep baseTag aliasBase
  local ep="$1" base="$2" alias_base="$3"
  info "----> [${ep}] Tuning ${base} -> ${alias_base}"
  pull_if_missing "$base"

  # determine GPU label from the bound device name
  local unit gname guid gmem; unit="$(unit_for_ep "$ep")"
  read -r gname guid gmem <<<"$(offload_summary "$unit")"
  local gpu_label; gpu_label="$(label_from_name "$gname")"

  bench_base_as_is "$ep" "$base" "$gpu_label" || warn "base bench skipped for $base on $ep"

  local first_ok=0 best_tokps="0.00" best_tag="" best_ng=""

  # sweep: build on :11434, then run on test endpoint
  for ng in $NUM_GPU_CANDIDATES; do
    info "     Trying num_gpu=${ng} (build on :${PERSISTENT_PORT}) ..."
    local newtag
    if ! newtag="$(bake_variant_on_persist "$base" "$alias_base" "$gpu_label" "$ng" 2>/dev/null)"; then
      warn "     x bake failed (likely OOM or build error)"
      continue
    fi

    # ensure test endpoint is reachable
    systemctl restart "$unit" || true
    if ! wait_api "$ep"; then
      warn "     test API $ep not up; skipping bench of ${newtag}"
      systemctl --no-pager -l status "$unit" || true
      journalctl -n 50 -u "$unit" --no-pager || true
      continue
    fi

    local tokps; tokps="$(bench_once "$ep" "$base" "$newtag" "optimized" "$gpu_label" "$ng" || echo "0.00")"
    awk -v a="$tokps" -v b="$best_tokps" 'BEGIN{exit !(a>b)}' && { best_tokps="$tokps"; best_tag="$newtag"; best_ng="$ng"; }

    if [ "$EXHAUSTIVE" -eq 0 ] && [ "$first_ok" -eq 0 ] && awk -v a="$tokps" 'BEGIN{exit !(a>0)}'; then
      first_ok=1
      # Convenience alias latest for this GPU family (optional)
      local latest="${alias_base}-${gpu_label}"
      if ! OLLAMA_HOST="http://${PULL_FROM}" "$OLLAMA_BIN" list 2>/dev/null | awk '{print $1}' | grep -Fxq "${latest}:latest"; then
        info "     Tagging convenience latest: ${latest}:latest -> num_gpu=${ng}"
        # re-bake as the simple latest name for quick use
        bake_variant_on_persist "$base" "$alias_base" "$gpu_label" "$ng" >/dev/null 2>&1 || true
      fi
      break
    fi
  done

  if [ -n "$best_tag" ]; then
    ok "Best on ${ep}: ${best_tag} (num_gpu=${best_ng}) at ${best_tokps} tok/s"
    echo "${ep},${alias_base},${best_tag},${best_ng},${best_tokps}" >>"${SUMMARY_FILE}.raw"
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

# Prepare services and wait
prepare_services
wait_api "$PULL_FROM" || { err "Persistent API ${PULL_FROM} not reachable"; exit 1; }
for ep in "${ENDPOINTS[@]}"; do
  restart_ep "$ep" || true
  wait_api "$ep" || warn "API $ep is not up yet (continuing)"
done

# Per model, per endpoint
for m in "${MODELS[@]}"; do
  base="${m%%|*}"; alias_base="${m##*|}"
  for ep in "${ENDPOINTS[@]}"; do
    [ "${ep##*:}" = "$PERSISTENT_PORT" ] && continue
    restart_ep "$ep" || true
    if ! wait_api "$ep"; then
      err "ERROR: API ${ep} did not come up — skipping ${base} on ${ep}"
      systemctl --no-pager -l status "$(unit_for_ep "$ep")" || true
      journalctl -n 50 -u "$(unit_for_ep "$ep")" --no-pager || true
      continue
    fi
    tune_and_bench_one "$ep" "$base" "$alias_base"
  done
done

# ===== Final summary =====
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
    | awk -F',' '{printf "  %-1s  %-22s %-30s  %-7s  %6.2f tok/s  (%s %s ngpu=%s)\n",$4,$5,$6,$8,$13,$1,$2,$9}'
} | tee "${SUMMARY_FILE}"

ok "DONE. CSV: ${CSV_FILE}"
ok "DONE. Summary: ${SUMMARY_FILE}"
# NOTE: :11434 is never killed; only :11435 and :11436 are started/stopped.

