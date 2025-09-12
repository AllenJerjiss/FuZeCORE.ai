#!/usr/bin/env bash
# ollama/benchmark.sh
# One-at-a-time model tuning + benchmarking with an always-on puller on :11434
# Variants are named: <alias>-<normalized-gpu>-ng<NUM>
#
# Key features:
# - Discovers base models automatically from `ollama list` on the persistent daemon.
# - Builds and benches per-GPU test services (:11435 and :11436).
# - Records CSV with eval token/s and prints a clean summary.

set -euo pipefail

########## PATH ROOTS ##########################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${LOG_DIR:-${ROOT_DIR}/logs}"
mkdir -p "$LOG_DIR"

########## CONFIG (override with env) ##########################################
PERSISTENT_PORT="${PERSISTENT_PORT:-11434}"  # always-on puller / builder
TEST_PORT_A="${TEST_PORT_A:-11435}"          # test instance A
TEST_PORT_B="${TEST_PORT_B:-11436}"          # test instance B

# Your persistent Ollama store (what :11434 uses)
OLLAMA_MODELS_DIR="${OLLAMA_MODELS_DIR:-/FuZe/models/ollama}"

# num_gpu sweep (high -> low)
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

SERVICE_HOME="${SERVICE_HOME:-/root}"

# GPU name substrings we try to bind to A/B:
MATCH_GPU_A="${MATCH_GPU_A:-5090}"
MATCH_GPU_B="${MATCH_GPU_B:-3090 Ti}"

# Cleanup controls
KEEP_FAILED_VARIANTS="${KEEP_FAILED_VARIANTS:-0}"  # 0=rm failed/invisible variants
GC_AFTER_RUN="${GC_AFTER_RUN:-1}"                  # 1=final pass GC

# Optional filters for discovered models
# RegEx (ERE) to exclude or include models by name (e.g. EXCLUDE_MODELS='^(tiny|sd3:).*')
EXCLUDE_MODELS="${EXCLUDE_MODELS:-}"
INCLUDE_MODELS="${INCLUDE_MODELS:-}"  # if set, only names matching this are kept

################################################################################

readonly OLLAMA_BIN="${OLLAMA_BIN:-/usr/local/bin/ollama}"
readonly HOSTNAME_NOW="$(hostname -s 2>/dev/null || hostname)"
readonly TS="$(date +%Y%m%d_%H%M%S)"
readonly CSV_FILE="${LOG_DIR}/ollama_bench_${TS}.csv"
readonly SUMMARY_FILE="${LOG_DIR}/${HOSTNAME_NOW}-${TS}.benchmark"
readonly CREATE_LOG="${LOG_DIR}/ollama_create_${TS}.log"
readonly CREATED_LIST="${LOG_DIR}/ollama_created_${TS}.txt"
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

curl_gen(){
  local ep="$1" model="$2" opts_json="$3" prompt="$4" to="$5"
  local payload
  payload="$(jq -n --arg m "$model" --arg p "$prompt" --argjson o "$opts_json" '{model:$m, options:$o, prompt:$p}')"
  curl -sS --max-time "$to" -H 'Content-Type: application/json' -d "$payload" "http://${ep}/api/generate" || return 1
}

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
  # "NVIDIA GeForce RTX 5090" -> nvidia-5090 ; "NVIDIA GeForce RTX 3090 Ti" -> nvidia-3090ti
  local raw="$1"
  local s
  s="$(echo "$raw" | tr '[:upper:]' '[:lower:]')"
  s="$(echo "$s" | sed -E 's/(nvidia|geforce|rtx)//g')"
  s="$(echo "$s" | tr -cd '[:alnum:] \n' | tr -s ' ')"
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
  OLLAMA_HOST="http://${PULL_FROM}" "$OLLAMA_BIN" list 2>/dev/null \
    | awk '($1!="" && $1!="NAME"){print $1}' | grep -Fxq "$tag"
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

base_alias(){
  # Turn name[:tag] into a stable slug for variant prefix
  # e.g. "llama4:16x17b" -> "llama4-16x17b", "deepseek-r1:70b" -> "deepseek-r1-70b"
  local s="$1"
  echo "$s" | sed -E 's#[/:]+#-#g'
}

discover_models(){
  info "Discovering base models from persistent daemon (:${PERSISTENT_PORT})"
  local names
  names="$(OLLAMA_HOST="http://${PULL_FROM}" "$OLLAMA_BIN" list 2>/dev/null | awk '($1!="NAME" && $1!="") {print $1}')"
  local out=()
  while IFS= read -r tag; do
    [ -z "$tag" ] && continue
    # Skip our optimized variants: anything with -nvidia-...-ngNN in the NAME portion
    if echo "$tag" | grep -Eq -- '-nvidia-[a-z0-9]+(super|ti)?-ng[0-9]+(:|$)'; then
      continue
    fi
    # Optional include/exclude filters
    if [ -n "$EXCLUDE_MODELS" ] && echo "$tag" | grep -Eq "$EXCLUDE_MODELS"; then
      continue
    fi
    if [ -n "$INCLUDE_MODELS" ] && ! echo "$tag" | grep -Eq "$INCLUDE_MODELS"; then
      continue
    fi
    out+=("$tag|$(base_alias "$tag")")
  done <<<"$names"
  if [ "${#out[@]}" -eq 0 ]; then
    warn "No base models discovered — you may need to 'ollama pull <model>' on :${PERSISTENT_PORT}."
  else
    info "Models     : $(printf '%s ' "${out[@]}")"
  fi
  MODELS=("${out[@]}")
}

append_csv_row(){ echo "$*" >>"$CSV_FILE"; }

bench_once(){ # ep baseTag modelTag label num_gpu gpu_label
  local ep="$1" base="$2" model="$3" label="$4" ng="${5:-}" gpu_lbl="$6"
  local sfx unit gname guid gmem opts tokps

  sfx="$(suffix_for_ep "$ep")"
  unit="$(unit_for_ep "$ep")"
  IFS=',' read -r gname guid gmem <<<"$(offload_triplet "$unit")"

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
  if ! curl_tags "$ep" | jq -r '.models[].name' 2>/dev/null | grep -Fxq "$base"; then
    warn "Base ${base} NOT visible on ${ep}; restarting test service once..."
    systemctl restart "$unit" || true
    wait_api "$ep" || true
    sleep 2
  fi
  bench_once "$ep" "$base" "$base" "base-as-is" "" "$gpu_lbl" >/dev/null || return 1
}

bake_variant(){ # newname base num_gpu
  local newname="$1" base="$2" ng="$3"
  local tf
  tf="$(mktemp)" || return 1
  {
    echo "FROM ${base}"
    echo "PARAMETER num_gpu ${ng}"
  } >"$tf"
  OLLAMA_HOST="http://${PULL_FROM}" \
    "$OLLAMA_BIN" create "$newname" -f "$tf" >>"$CREATE_LOG" 2>&1 || {
      rm -f "$tf"; return 1; }
  rm -f "$tf"
  echo "$newname" >> "$CREATED_LIST"
  return 0
}

rm_variant_tag(){ # name[:tag]
  local ref="$1"
  [ "${KEEP_FAILED_VARIANTS}" -eq 1 ] && return 0
  OLLAMA_HOST="http://${PULL_FROM}" "$OLLAMA_BIN" rm "$ref" >/dev/null 2>&1 || true
}

tune_and_bench_one(){ # ep baseTag aliasBase
  local ep="$1" base="$2" alias_base="$3"
  local gpu_lbl; gpu_lbl="$(gpu_label_for_ep "$ep")"
  info "----> [${ep}] Tuning ${base} -> variants ${alias_base}-${gpu_lbl}-ng<NUM>"
  pull_if_missing "$base"

  if ! curl_tags "$ep" | jq -r '.models[].name' 2>/dev/null | grep -Fxq "$base"; then
    warn "Base ${base} NOT visible on ${ep}. Build happens on :${PERSISTENT_PORT}; benches will run via ${ep}."
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
      { echo "        └─ last create log lines:"; tail -n 8 "$CREATE_LOG" | sed 's/^/           /'; } || true
      continue
    fi

    if ! wait_variant_visible "$ep" "${newname}:latest"; then
      warn "     variant ${newname}:latest not visible on ${ep} after wait; restarting test service"
      systemctl restart "$(unit_for_ep "$ep")" || true
      wait_api "$ep" || true
      if ! wait_variant_visible "$ep" "${newname}:latest" 6; then
        warn "     still not visible; removing ${newname}"
        rm_variant_tag "${newname}:latest"
        continue
      fi
    fi

    local tokps
    if tokps="$(bench_once "$ep" "$base" "${newname}:latest" "optimized" "$ng" "$gpu_lbl")"; then
      :
    else
      tokps="0.00"
    fi

    if [ "${tokps}" = "0.00" ]; then
      rm_variant_tag "${newname}:latest"
    fi

    awk -v a="$tokps" -v b="$best_tokps" 'BEGIN{exit !(a>b)}' && { best_tokps="$tokps"; best_name="$newname"; best_ng="$ng"; }

    if [ "$EXHAUSTIVE" -eq 0 ] && awk -v a="$tokps" 'BEGIN{exit !(a>0)}'; then
      ok "     First working: ${newname} at ${tokps} tok/s"
      first_ok=1
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

gc_created_tags(){
  [ "${GC_AFTER_RUN}" -eq 1 ] || return 0
  [ -s "$CREATED_LIST" ] || { info "GC summary: nothing created."; return 0; }
  local removed=0 kept=0
  while IFS= read -r tag; do
    # if tag never produced a CSV row with tokens_per_sec>0, purge it
    if ! awk -F',' -v t="${tag}:latest" 'NR>1 && $7==t && $12+0>0 {found=1} END{exit !found}' "$CSV_FILE"; then
      rm_variant_tag "${tag}:latest"
      removed=$((removed+1))
    else
      kept=$((kept+1))
    fi
  done < "$CREATED_LIST"
  info "GC summary: removed ${removed} stale variant(s), kept ${kept} used variant(s)."
}

##################################### MAIN #####################################
echo -e "${c_bold}== One-at-a-time auto-tune + bench (POSIX) ==${c_reset}"
log "Persistent : ${PULL_FROM}"
log "Test EPs   : 127.0.0.1:${TEST_PORT_A}  127.0.0.1:${TEST_PORT_B}"
log "CSV        : ${CSV_FILE}"
log "Summary    : ${SUMMARY_FILE}"

# GPU table print
info "Preparing directories and services"
mkdir -p "$OLLAMA_MODELS_DIR" "$LOG_DIR"
log "$(gpu_table | sed 's/^/GPU: /')"

# Persistent daemon
if curl -fsS "http://127.0.0.1:${PERSISTENT_PORT}/api/tags" >/dev/null 2>&1; then
  info "Using existing Ollama on :${PERSISTENT_PORT}"
else
  write_unit "ollama-persist.service" "$PERSISTENT_PORT" "" "Ollama (persistent on :${PERSISTENT_PORT})"
  systemctl enable --now ollama-persist.service || true
fi

# Auto-detect two GPUs by total memory (descending). Fallback to index order.
mapfile -t _GPU_ROWS < <(gpu_table | sort -t',' -k4,4nr)
uuid_a="$(printf '%s\n' "${_GPU_ROWS[0]-}" | awk -F',' '{print $2}')"
uuid_b="$(printf '%s\n' "${_GPU_ROWS[1]-}" | awk -F',' '{print $2}')"

if [ -z "${uuid_a:-}" ]; then
  all="$(gpu_table)"
  uuid_a="$(echo "$all" | awk -F',' 'NR==1{print $2}')"
  uuid_b="$(echo "$all" | awk -F',' 'NR==2{print $2}')"
fi
if [ -z "${uuid_b:-}" ] || [ "$uuid_b" = "$uuid_a" ]; then
  # if second GPU missing/identical, mirror A
  uuid_b="$uuid_a"
fi

write_unit "ollama-test-a.service" "$TEST_PORT_A" "$uuid_a" "Ollama (TEST A on :${TEST_PORT_A}, GPU ${uuid_a})"
write_unit "ollama-test-b.service" "$TEST_PORT_B" "$uuid_b" "Ollama (TEST B on :${TEST_PORT_B}, GPU ${uuid_b})"

systemctl enable --now ollama-test-a.service || true
systemctl enable --now ollama-test-b.service || true

info "TEST A OLLAMA_MODELS: $(service_env ollama-test-a.service OLLAMA_MODELS)"
info "TEST B OLLAMA_MODELS: $(service_env ollama-test-b.service OLLAMA_MODELS)"
info "Waiting for APIs"
wait_api "127.0.0.1:${PERSISTENT_PORT}" || warn "API :${PERSISTENT_PORT} not reachable yet"
wait_api "127.0.0.1:${TEST_PORT_A}" || warn "API :${TEST_PORT_A} slow to start"
wait_api "127.0.0.1:${TEST_PORT_B}" || warn "API :${TEST_PORT_B} slow to start"

info "ollama version: $($OLLAMA_BIN --version || echo 'unknown')"

# Discover base models dynamically
MODELS=()
discover_models

# Restart test endpoints and go
for ep in "${ENDPOINTS[@]}"; do
  restart_ep "$ep" || true
  wait_api "$ep" || warn "API $ep is not up yet (continuing)"
done

# Bench loop
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

gc_created_tags || true

# ========= Clean, canonical final summary (no duplicates) =====================
{
  echo "=== Final Summary @ ${HOSTNAME_NOW} ${TS} ==="
  echo "CSV: ${CSV_FILE}"
  echo
  # Any optimized rows with tokens_per_sec > 0 ?
  if awk -F',' 'NR>1 && $6 ~ /^optimized$/ && $12+0>0 {exit 0} END{exit 1}' "$CSV_FILE"; then
    # Show best per (endpoint, model) if we computed any in SUMMARY_FILE.raw
    if [ -s "${SUMMARY_FILE}.raw" ]; then
      echo "Best optimized per (endpoint, model):"
      column -t -s',' "${SUMMARY_FILE}.raw" 2>/dev/null || cat "${SUMMARY_FILE}.raw"
    else
      echo "Optimized variants ran (see CSV), but per-(endpoint,model) best list is empty."
    fi
  else
    echo "No optimized variants succeeded."
  fi
  echo
  echo "=== Base vs Optimized (per endpoint & model) ==="
  awk -F',' '
    NR==1 { next }
    {
      key=$2 "|" $5
      keys[key]=1
      if ($6=="base-as-is") {
        if ($12+0 > baseTok[key]+0) baseTok[key]=$12+0
      } else if ($6=="optimized") {
        if ($12+0 > optTok[key]+0) { optTok[key]=$12+0; optTag[key]=$7; optNg[key]=$8 }
      }
    }
    END {
      printf "%-18s %-20s %12s %16s  %-30s %s\n", "Endpoint", "Model", "Base tok/s", "Best opt tok/s", "Best tag", "ng"
      for (k in keys) {
        split(k, a, "|"); ep=a[1]; model=a[2]
        bt = (k in baseTok) ? baseTok[k] : 0
        ot = (k in optTok) ? optTok[k] : 0
        mt = (k in optTag) ? optTag[k] : "-"
        ng = (k in optNg)  ? optNg[k]  : "-"
        printf "%-18s %-20s %12.2f %16.2f  %-30s %s\n", ep, model, bt, ot, mt, ng
      }
    }
  ' "$CSV_FILE"
  echo
  echo "Top-5 runs overall (by tokens/sec) from CSV:"
  tail -n +2 "$CSV_FILE" | sort -t',' -k12,12gr | head -n5 \
    | awk -F',' '{printf "  %-2s %-18s %-28s %-14s %6.2f tok/s  (%s %s ngpu=%s)\n",$4,$5,$6,$13,$12,$1,$2,$8}'
} | tee "${SUMMARY_FILE}"

ok "DONE. CSV: ${CSV_FILE}"
ok "DONE. Summary: ${SUMMARY_FILE}"
# NOTE: :11434 is never killed by this script; only :11435 and :11436 are started/stopped.

