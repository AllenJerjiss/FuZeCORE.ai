#!/usr/bin/env bash
# ollama/benchmark.sh
# One-at-a-time model tuning + benchmarking with an always-on puller on :11434
# Variants are named: <alias>-<normalized-gpu>-ng<NUM>
#
# Key features:
# - Discovers base models automatically from `ollama list` on the persistent daemon.
# - Builds and benches per-GPU test services (:11435 and :11436).
# - Abandons CPU-bound "optimized" runs quickly (and records them).
# - Records CSV with eval token/s and prints a clean summary.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${LOG_DIR:-${ROOT_DIR}/logs}"
mkdir -p "$LOG_DIR"

PERSISTENT_PORT="${PERSISTENT_PORT:-11434}"
TEST_PORT_A="${TEST_PORT_A:-11435}"
TEST_PORT_B="${TEST_PORT_B:-11436}"
OLLAMA_MODELS_DIR="${OLLAMA_MODELS_DIR:-/FuZe/models/ollama}"
NUM_GPU_CANDIDATES="${NUM_GPU_CANDIDATES:-80 72 64 56 48 40 32 24 16}"
PROMPT="${PROMPT:-Tell me a 1-sentence fun fact about GPUs.}"
EXHAUSTIVE="${EXHAUSTIVE:-0}"
VERBOSE="${VERBOSE:-1}"
WAIT_API_SECS="${WAIT_API_SECS:-60}"
TIMEOUT_GEN="${TIMEOUT_GEN:-90}"
TIMEOUT_TAGS="${TIMEOUT_TAGS:-10}"
SERVICE_HOME="${SERVICE_HOME:-/root}"
MATCH_GPU_A="${MATCH_GPU_A:-5090}"
MATCH_GPU_B="${MATCH_GPU_B:-3090 Ti}"
KEEP_FAILED_VARIANTS="${KEEP_FAILED_VARIANTS:-0}"
GC_AFTER_RUN="${GC_AFTER_RUN:-1}"
EXCLUDE_MODELS="${EXCLUDE_MODELS:-}"
INCLUDE_MODELS="${INCLUDE_MODELS:-}"
# If 1, stop/disable any existing test services before recreating them.
CLEAN_START_TESTS="${CLEAN_START_TESTS:-1}"
readonly OLLAMA_BIN="${OLLAMA_BIN:-/usr/local/bin/ollama}"

readonly HOSTNAME_NOW="$(hostname -s 2>/dev/null || hostname)"
readonly TS="${RUN_TS:-$(date +%Y%m%d_%H%M%S)}"
readonly CSV_FILE="${LOG_DIR}/ollama_bench_${TS}.csv"
readonly SUMMARY_FILE="${LOG_DIR}/${HOSTNAME_NOW}-${TS}.benchmark"
readonly CREATE_LOG="${LOG_DIR}/ollama_create_${TS}.log"
readonly CREATED_LIST="${LOG_DIR}/ollama_created_${TS}.txt"
readonly PULL_FROM="127.0.0.1:${PERSISTENT_PORT}"

CPU_PEG_MONITOR="${CPU_PEG_MONITOR:-1}"
CPU_PEG_THRESHOLD="${CPU_PEG_THRESHOLD:-300}"
CPU_PEG_WINDOW="${CPU_PEG_WINDOW:-4}"
GPU_MIN_UTIL="${GPU_MIN_UTIL:-10}"
CPU_ABANDONED_FILE="${SUMMARY_FILE}.cpu_abandoned"

# NEW: explicit arrays (avoid dash complaints if ever mis-invoked)
declare -a MODELS
declare -a ENDPOINTS

c_bold="\033[1m"; c_red="\033[31m"; c_green="\033[32m"; c_yellow="\033[33m"; c_reset="\033[0m"
log(){ echo -e "$*"; }
info(){ [ "$VERBOSE" -ne 0 ] && echo -e "${c_bold}==${c_reset} $*"; }
ok(){ echo -e "${c_green}✔${c_reset} $*"; }
warn(){ echo -e "${c_yellow}!${c_reset} $*"; }
err(){ echo -e "${c_red}✖${c_reset} $*" >&2; }

need(){ command -v "$1" >/dev/null 2>&1 || { err "Missing dependency: $1"; exit 1; }; }
need curl; need jq; need awk; need sed; need systemctl

calc_tokps(){ awk -v ec="$1" -v ed="$2" 'BEGIN{ if(ed<=0){print "0.00"} else {printf "%.2f", (ec+0.0)/(ed/1000.0)} }'; }
curl_tags(){ local ep="$1"; curl -fsS --max-time "$TIMEOUT_TAGS" "http://${ep}/api/tags" || return 1; }
curl_gen(){ local ep="$1" model="$2" opts_json="$3" prompt="$4" to="$5"; local payload
  # Force non-streaming responses and merge any provided options.
  payload="$(jq -cn --arg m "$model" --arg p "$prompt" --argjson o "$opts_json" '{model:$m, prompt:$p, stream:false} + $o')" || return 1
  curl -sS --max-time "$to" -H 'Content-Type: application/json' -d "$payload" "http://${ep}/api/generate" || return 1; }

service_env(){ local unit="$1" key="$2"
  systemctl show "$unit" -p Environment 2>/dev/null | tr '\n' ' ' | sed -nE "s/.*${key}=([^ ]+).*/\1/p"; }

wait_api(){ local ep="$1" i=0; while (( i < WAIT_API_SECS )); do curl_tags "$ep" >/dev/null 2>&1 && return 0; sleep 1; i=$((i+1)); done; return 1; }

unit_for_ep(){ case "$1" in
  *:${TEST_PORT_A}) echo "ollama-test-a.service" ;;
  *:${TEST_PORT_B}) echo "ollama-test-b.service" ;;
  *:${PERSISTENT_PORT}) echo "ollama-persist.service" ;;
  *) echo "" ;; esac; }

write_unit(){ # name port gpu_uuid title
  local name="$1" port="$2" uuid="$3" title="$4"
  cat >/etc/systemd/system/"$name" <<UNIT
[Unit]
Description=${title}
After=network-online.target
Wants=network-online.target
[Service]
User=ollama
Group=ollama
SupplementaryGroups=video render
Environment=OLLAMA_MODELS=${OLLAMA_MODELS_DIR}
Environment=CUDA_VISIBLE_DEVICES=${uuid}
ExecStart=${OLLAMA_BIN} serve -p ${port}
Restart=always
RestartSec=2
NoNewPrivileges=false
[Install]
WantedBy=multi-user.target
UNIT
}

# Stop/disable a unit cleanly if present.
stop_unit(){ local u="$1"; systemctl stop "$u" 2>/dev/null || true; systemctl disable "$u" 2>/dev/null || true; systemctl reset-failed "$u" 2>/dev/null || true; }

# Ensure the 'ollama' service account exists and owns the models directory.
ensure_service_user(){ if ! id -u ollama >/dev/null 2>&1; then warn "Creating system user 'ollama' (missing)"; groupadd --system ollama 2>/dev/null || true; useradd --system --no-create-home --gid ollama --groups video,render --shell /usr/sbin/nologin ollama 2>/dev/null || true; fi; }
prep_models_dir(){ mkdir -p "$OLLAMA_MODELS_DIR" "$LOG_DIR"; chown -R ollama:ollama "$OLLAMA_MODELS_DIR" 2>/dev/null || true; }

restart_ep(){ local ep="$1" u; u="$(unit_for_ep "$ep")"; [ -n "$u" ] || return 0; systemctl daemon-reload || true; systemctl enable --now "$u" || true; systemctl restart "$u" || true; }

gpu_table(){ nvidia-smi --query-gpu=name,uuid,memory.total --format=csv,noheader 2>/dev/null || true; }

offload_triplet(){ local unit="$1" gi; gi="$(service_env "$unit" CUDA_VISIBLE_DEVICES)"
  if [ -n "${gi:-}" ] && command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name,uuid,memory.total --format=csv,noheader 2>/dev/null \
      | awk -F',' -v id="$gi" 'index($2,id){gsub(/^[[:space:]]+|[[:space:]]+$/,"",$1); gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); gsub(/ MiB/,"",$3); print $1","$2","$3; exit}'
  fi; }

normalize_gpu_label(){ local raw="$1" s
  s="$(echo "$raw" | tr '[:upper:]' '[:lower:]')"; s="${s//nvidia /}"; s="${s//geforce /}"; s="${s//rtx /}"; s="${s// /}"; echo "nvidia-${s}"; }

gpu_label_for_ep(){ local ep="$1" unit lbl name uuid mem; unit="$(unit_for_ep "$ep")"; IFS=',' read -r name uuid mem <<<"$(offload_triplet "$unit")"
  [ -z "${name:-}" ] && echo "nvidia-unknown" || echo "$(normalize_gpu_label "$name")"; }

have_model(){ local tag="$1"
  OLLAMA_HOST="http://${PULL_FROM}" "$OLLAMA_BIN" list 2>/dev/null | awk '($1!="" && $1!="NAME"){print $1}' | grep -Fxq "$tag"; }

pull_if_missing(){ local base="$1"; if ! have_model "$base"; then info "Pulling missing: $base (via ${PULL_FROM})"; OLLAMA_HOST="http://${PULL_FROM}" "$OLLAMA_BIN" pull "$base"; fi; }

suffix_for_ep(){ case "$1" in *:${TEST_PORT_A}) echo "A" ;; *:${TEST_PORT_B}) echo "B" ;; *:*) echo "${1##*:}" ;; esac; }

bench_base_as_is(){ local ep="$1" base="$2" gpu_lbl; gpu_lbl="$(gpu_label_for_ep "$ep")"
  if ! curl_tags "$ep" >/dev/null 2>&1; then warn "Endpoint ${ep} not responding; restarting unit."; restart_ep "$ep" || true; wait_api "$ep" || true; sleep 2; fi
  bench_once "$ep" "$base" "$base" "base-as-is" "" "$gpu_lbl" >/dev/null || return 1; }

bake_variant(){ local newname="$1" base="$2" ng="$3" tf; tf="$(mktemp)"
  { echo "FROM ${base}"; echo "PARAMETER num_gpu ${ng}"; } >"$tf"
  OLLAMA_HOST="http://${PULL_FROM}" "$OLLAMA_BIN" create "$newname" -f "$tf" >>"$CREATE_LOG" 2>&1 || { rm -f "$tf"; return 1; }
  rm -f "$tf"; echo "$newname" >> "$CREATED_LIST"; }

rm_variant_tag(){ local full="$1"; info "Removing variant tag: $full"; OLLAMA_HOST="http://${PULL_FROM}" "$OLLAMA_BIN" rm "$full" 2>/dev/null || true; }

wait_variant_visible(){ local ep="$1" variant="$2" secs="${3:-12}" i=0 unit; unit="$(unit_for_ep "$ep")"
  while (( i < secs )); do curl_tags "$ep" | jq -r '.models[].name' 2>/dev/null | grep -Fxq "$variant" && return 0; sleep 1; i=$((i+1)); done
  warn "Variant $variant not visible on $ep after ${secs}s"; return 1; }

base_alias(){ echo "$1" | sed -E 's#[/:]+#-#g'; }

discover_models(){ info "Discovering base models from persistent daemon (:${PERSISTENT_PORT})"
  local names out=(); names="$(OLLAMA_HOST="http://${PULL_FROM}" "$OLLAMA_BIN" list 2>/dev/null | awk '($1!="NAME" && $1!=""){print $1}')"
  while IFS= read -r tag; do
    [ -z "$tag" ] && continue
    echo "$tag" | grep -Eq -- '-nvidia-[a-z0-9]+(super|ti)?-ng[0-9]+(:|$)' && continue
    [ -n "$EXCLUDE_MODELS" ] && echo "$tag" | grep -Eq "$EXCLUDE_MODELS" && continue
    [ -n "$INCLUDE_MODELS" ] && ! echo "$tag" | grep -Eq "$INCLUDE_MODELS" && continue
    out+=("$tag|$(base_alias "$tag")")
  done <<<"$names"
  if [ "${#out[@]}" -eq 0 ]; then warn "No base models discovered — you may need to 'ollama pull <model>' on :${PERSISTENT_PORT}."; else info "Models     : $(printf '%s ' "${out[@]}")"; fi
  MODELS=("${out[@]}"); }

append_csv_row(){ echo "$*" >>"$CSV_FILE"; }

record_cpu_abandoned(){ local ep="$1" base="$2" variant="$3" ng="$4" gpu_lbl="$5"
  [ -e "$CPU_ABANDONED_FILE" ] || echo "endpoint,base,variant,num_gpu,gpu_label" > "$CPU_ABANDONED_FILE"
  echo "${ep},${base},${variant},${ng},${gpu_lbl}" >> "$CPU_ABANDONED_FILE"; }

monitor_cpu_gpu(){ local unit="$1" uuid="$2" secs="${3:-$TIMEOUT_GEN}" pid cpu gpu consec=0 t0 now
  pid="$(systemctl show "$unit" -p MainPID --value 2>/dev/null || true)"; [ -n "${pid:-}" ] && [ "$pid" -gt 0 ] || return 0
  t0="$(date +%s)"; while :; do
    now="$(date +%s)"; [ $((now - t0)) -ge "$secs" ] && return 0
    cpu="$(ps -p "$pid" -o %cpu= 2>/dev/null | awk '{printf("%d",$1+0)}')"; gpu=0
    if command -v nvidia-smi >/dev/null 2>&1 && [ -n "${uuid:-}" ]; then
      gpu="$(nvidia-smi -i "$uuid" --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | awk 'NR==1{printf("%d",$1+0)}')"
    fi
    if [ "${cpu:-0}" -ge "$CPU_PEG_THRESHOLD" ] && [ "${gpu:-0}" -lt "$GPU_MIN_UTIL" ]; then consec=$((consec+1)); else consec=0; fi
    [ "$consec" -ge "$CPU_PEG_WINDOW" ] && return 10
    sleep 0.5
  done; }

bench_once(){ # ep baseTag modelTag label num_gpu gpu_label
  local ep="$1" base="$2" model="$3" label="$4" ng="${5:-}" gpu_lbl="$6"
  local sfx unit gname guid gmem opts tokps="0.00" ec=0 ed=1 o tmp rc=0
  sfx="$(suffix_for_ep "$ep")"; unit="$(unit_for_ep "$ep")"; IFS=',' read -r gname guid gmem <<<"$(offload_triplet "$unit")"
  if [ -n "${ng:-}" ]; then opts="$(jq -n --argjson ng "$ng" '{num_gpu:$ng}')" || opts='{"num_gpu":'"${ng}"'}'; else opts='{}'; fi
  tmp="$(mktemp)"
  if [ "$label" = "optimized" ] && [ "${CPU_PEG_MONITOR}" -eq 1 ]; then
    curl_gen "$ep" "$model" "$opts" "$PROMPT" "$TIMEOUT_GEN" >"$tmp" 2>/dev/null & gen_pid=$!
    monitor_cpu_gpu "$unit" "$guid" "$TIMEOUT_GEN" & mon_pid=$!
    wait -n "$gen_pid" "$mon_pid" || true; rc=$?
    if [ "$rc" -eq 10 ]; then
      kill -TERM "$gen_pid" 2>/dev/null || true; wait "$gen_pid" 2>/dev/null || true
      record_cpu_abandoned "$ep" "$base" "$model" "${ng:-}" "$gpu_lbl"
      [ "${KEEP_FAILED_VARIANTS}" -eq 0 ] && rm_variant_tag "$model" || true
      label="optimized-cpu-bound"; ec=0; ed=1; tokps="0.00"
    else
      if [ -s "$tmp" ]; then
        # Be robust to streaming-style logs by slurping and taking the last object.
        ec="$(jq -r -s '.[-1].eval_count // 0' "$tmp" 2>/dev/null || echo 0)"
        ed="$(jq -r -s '.[-1].eval_duration // 0' "$tmp" 2>/dev/null || echo 1)"
        tokps="$(calc_tokps "$ec" "$ed")"
      fi
    fi
  else
    o="$(curl_gen "$ep" "$model" "$opts" "$PROMPT" "$TIMEOUT_GEN" || true)"
    if [ -n "$o" ]; then
      # Handle either streaming or non-streaming output by slurping.
      ec="$(jq -r -s '.[-1].eval_count // 0' <<<"$o" 2>/dev/null || echo 0)"
      ed="$(jq -r -s '.[-1].eval_duration // 0' <<<"$o" 2>/dev/null || echo 1)"
      tokps="$(calc_tokps "$ec" "$ed")"
    fi
  fi
  rm -f "$tmp" 2>/dev/null || true
  # EXACTLY 16 columns, no stray spaces:
  append_csv_row "${TS},${ep},${unit},${sfx},${base},${label},${model},${ng:-},,,${tokps},$(gpu_label_for_ep "$ep"),${gname},${guid},${gmem}"
  if [ "$label" = "optimized" ] && awk -v t="$tokps" 'BEGIN{exit !(t+0==0)}'; then [ "${KEEP_FAILED_VARIANTS}" -eq 0 ] && rm_variant_tag "$model" || true; fi
  echo "$tokps"
}

tune_and_bench_one(){ local ep="$1" base="$2" alias_base="$3" gpu_lbl; gpu_lbl="$(gpu_label_for_ep "$ep")"
  pull_if_missing "$base"
  if ! curl_tags "$ep" | jq -r '.models[].name' 2>/dev/null | grep -Fxq "$base"; then
    warn "Base ${base} NOT visible on ${ep}. Build happens on :${PERSISTENT_PORT}; benches will run via ${ep}."
  fi
  bench_base_as_is "$ep" "$base" || warn "base-as-is bench skipped for $base on $ep"
  local best_tokps="0.00" best_name="" best_ng="" first_ok=0
  for ng in ${NUM_GPU_CANDIDATES}; do
    local newname="${alias_base}-$(gpu_label_for_ep "$ep")-ng${ng}"
    info " Bake variant ${newname} (FROM ${base} num_gpu=${ng})"
    if ! bake_variant "$newname" "$base" "$ng"; then
      warn "Variant bake failed: ${newname}"
      [ "${KEEP_FAILED_VARIANTS}" -eq 0 ] && rm_variant_tag "${newname}:latest" || true
      continue
    fi
    wait_variant_visible "$ep" "${newname}:latest" 12 || true
    local tokps; if tokps="$(bench_once "$ep" "$base" "${newname}:latest" "optimized" "$ng" "$gpu_lbl")"; then :; else tokps="0.00"; fi
    if awk -v t="$tokps" 'BEGIN{exit !(t+0==0)}'; then [ "${KEEP_FAILED_VARIANTS}" -eq 0 ] && rm_variant_tag "${newname}:latest" || true; fi
    awk -v a="$tokps" -v b="$best_tokps" 'BEGIN{exit !(a>b)}' && { best_tokps="$tokps"; best_name="$newname"; best_ng="$ng"; }
    if [ "$EXHAUSTIVE" -eq 0 ] && awk -v a="$tokps" 'BEGIN{exit !(a>0)}'; then ok "     First working: ${newname} at ${tokps} tok/s"; first_ok=1; break; fi
  done
  if [ "$first_ok" -eq 1 ]; then ok " Best so far: ${best_name} (ng=${best_ng}) at ${best_tokps} tok/s"; else warn " No optimized variant worked for ${base} on ${ep}"; fi
}

gc_created_tags(){ [ "${GC_AFTER_RUN}" -eq 1 ] || return 0; [ -s "$CREATED_LIST" ] || { info "GC summary: nothing created."; return 0; }
  local removed=0 kept=0
  while IFS= read -r tag; do
    if ! awk -F',' -v t="${tag}:latest" 'NR>1 && $7==t && $12+0>0 {found=1} END{exit !found}' "$CSV_FILE"; then
      rm_variant_tag "${tag}:latest"; removed=$((removed+1))
    else kept=$((kept+1)); fi
  done < "$CREATED_LIST"
  info "GC created variants: removed=${removed} kept=${kept}"; }

echo "ts,endpoint,unit,suffix,base_model,variant_label,model_tag,num_gpu,num_ctx,batch,num_predict,tokens_per_sec,gpu_label,gpu_name,gpu_uuid,gpu_mem_mib" > "$CSV_FILE"
: > "$CREATE_LOG"; : > "$CREATED_LIST"

log "== One-at-a-time auto-tune + bench (POSIX) =="
log "Persistent : 127.0.0.1:${PERSISTENT_PORT}"
log "CSV        : ${CSV_FILE}"
log "Summary    : ${SUMMARY_FILE}"

info "Preparing directories and services"
ensure_service_user || true
prep_models_dir || true
log "$(gpu_table | sed 's/^/GPU: /')"

# Ensure :11434 is up
if ! curl -fsS "http://127.0.0.1:${PERSISTENT_PORT}/api/tags" >/dev/null 2>&1; then
  if systemctl list-unit-files | grep -q '^ollama.service'; then systemctl enable --now ollama.service || true
  else write_unit "ollama-persist.service" "$PERSISTENT_PORT" "" "Ollama (persistent on :${PERSISTENT_PORT})"; systemctl enable --now ollama-persist.service || true; fi
fi

all_gpus="$(gpu_table || true)"
uuid_a="$(echo "$all_gpus" | awk -F',' -v s="$MATCH_GPU_A" 'tolower($1) ~ tolower(s){gsub(/[[:space:]]/,"",$2); print $2; exit}')"
uuid_b="$(echo "$all_gpus" | awk -F',' -v s="$MATCH_GPU_B" 'tolower($1) ~ tolower(s){gsub(/[[:space:]]/,"",$2); print $2; exit}')"
[ -z "${uuid_a:-}" ] && uuid_a="$(echo "$all_gpus" | awk -F',' 'NR==1{gsub(/[[:space:]]/,"",$2); print $2}')"
if [ -z "${uuid_b:-}" ] || [ "$uuid_a" = "$uuid_b" ]; then uuid_b="$(echo "$all_gpus" | awk -F',' 'NR==2{gsub(/[[:space:]]/,"",$2); print $2}')"; fi

ENDPOINTS=()
# Optional clean start: stop/disable any existing test services before recreating.
if [ "${CLEAN_START_TESTS}" -eq 1 ]; then stop_unit ollama-test-a.service; stop_unit ollama-test-b.service; systemctl daemon-reload || true; fi
if [ -n "${uuid_a:-}" ]; then write_unit "ollama-test-a.service" "$TEST_PORT_A" "$uuid_a" "Ollama (TEST A on :${TEST_PORT_A})"; systemctl daemon-reload || true; systemctl enable --now ollama-test-a.service || true; ENDPOINTS+=("127.0.0.1:${TEST_PORT_A}"); fi
if [ -n "${uuid_b:-}" ]; then write_unit "ollama-test-b.service" "$TEST_PORT_B" "$uuid_b" "Ollama (TEST B on :${TEST_PORT_B})"; systemctl daemon-reload || true; systemctl enable --now ollama-test-b.service || true; ENDPOINTS+=("127.0.0.1:${TEST_PORT_B}"); fi

info "TEST A OLLAMA_MODELS: $(service_env ollama-test-a.service OLLAMA_MODELS || true)"
info "TEST B OLLAMA_MODELS: $(service_env ollama-test-b.service OLLAMA_MODELS || true)"

info "Waiting for APIs"
wait_api "127.0.0.1:${PERSISTENT_PORT}" || warn "API :${PERSISTENT_PORT} not reachable yet"
for ep in "${ENDPOINTS[@]}"; do wait_api "$ep" || warn "API $ep slow to start"; done
info "ollama version: $($OLLAMA_BIN --version || echo 'unknown')"

MODELS=(); discover_models
for ep in "${ENDPOINTS[@]}"; do restart_ep "$ep" || true; wait_api "$ep" || warn "API $ep is not up yet (continuing)"; done
for m in "${MODELS[@]}"; do base="${m%%|*}"; alias_base="${m##*|}"; for ep in "${ENDPOINTS[@]}"; do log "=== Tuning on ${ep} — base: ${base} (alias ${alias_base}) ==="; tune_and_bench_one "$ep" "$base" "$alias_base"; done; done
gc_created_tags || true

awk -F',' '
  NR>1 && $6=="optimized" && $12+0>0 { k=$2"|" $5; if ($12+0>best[k]) {best[k]=$12+0; n[k]=$7; ng[k]=$8} }
  END{
    f=ENVIRON["SUMMARY_FILE"] ".raw"
    print "endpoint,base_model,best_variant,num_gpu,tokens_per_sec" > f
    for (k in best){ split(k,a,"|"); printf "%s,%s,%s,%s,%.2f\n",a[1],a[2],n[k],ng[k],best[k] >> f }
  }' SUMMARY_FILE="$SUMMARY_FILE" "$CSV_FILE"

{
  echo "=== Final Summary @ ${HOSTNAME_NOW} ${TS} ==="
  echo "CSV: ${CSV_FILE}"
  echo
  if awk -F',' 'NR>1 && $6 ~ /^optimized$/ && $12+0>0 {exit 0} END{exit 1}' "$CSV_FILE"; then
    if [ -s "${SUMMARY_FILE}.raw" ]; then
      echo "Best optimized per (endpoint, model):"
      column -t -s',' "${SUMMARY_FILE}.raw" 2>/dev/null || cat "${SUMMARY_FILE}.raw"
    else
      echo "Optimized variants ran (see CSV), but per-(endpoint,model) best list is empty."
    fi
  else
    echo "No optimized variants succeeded."
  fi
  if [ -s "${CPU_ABANDONED_FILE}" ]; then
    echo
    echo "Abandoned optimized variants (CPU-bound):"
    column -t -s',' "${CPU_ABANDONED_FILE}" 2>/dev/null || cat "${CPU_ABANDONED_FILE}"
  fi
  echo
  echo "=== Base vs Optimized (per endpoint & model) ==="
  awk -F',' '
    NR==1{next}
    { key=$2"|" $5; if ($6=="base-as-is"){base[key]=$12+0} else if ($6=="optimized"){ if ($12+0>opt[key]){opt[key]=$12+0; optname[key]=$7} } }
    END{
      printf "%-21s %-28s %10s %10s %8s %s\n","endpoint","model","base_t/s","opt_t/s","x","best_variant"
      for (k in base){
        be=base[k]+0; op=opt[k]+0; split(k,a,"|"); mult=(be>0? op/be : 0)
        printf "%-21s %-28s %10.2f %10.2f %8.2fx %s\n", a[1],a[2],be,op,(be>0?mult:0),optname[k]
      }
    }' "$CSV_FILE"
} | tee "${SUMMARY_FILE}.txt" >/dev/null

ok "Done."
