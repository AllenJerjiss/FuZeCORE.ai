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

# ------------------------------------------------------------------------------
# Load common GPU service management
# ------------------------------------------------------------------------------
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BAKERY_BIN="${ROOT_DIR}/../../BAKERY/fuze-vanilla-llm.sh"
ANALYZE_BIN="${ROOT_DIR}/stack/common/analyze.sh"
source "${ROOT_DIR}/common/common.sh"
source "${ROOT_DIR}/common/gpu-services.sh"
LOG_DIR="${LOG_DIR:-/FuZe/logs}"
# Ensure writable log dir; fall back to per-user location if repo logs are root-owned
if ! mkdir -p "$LOG_DIR" 2>/dev/null || [ ! -w "$LOG_DIR" ]; then
  LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/fuze-stack/logs"
  mkdir -p "$LOG_DIR" 2>/dev/null || { LOG_DIR="$HOME/.fuze/stack/logs"; mkdir -p "$LOG_DIR"; }
fi

# ------------------------------------------------------------------------------
# Config (override via env)
# ------------------------------------------------------------------------------
PERSISTENT_PORT="${PERSISTENT_PORT:-11434}"  # always-on puller / builder
TEST_PORT_A="${TEST_PORT_A:-11435}"          # test instance A
TEST_PORT_B="${TEST_PORT_B:-11436}"          # test instance B
TEST_PORT_MULTI="${TEST_PORT_MULTI:-11437}"  # multi-GPU instance

# Persistent model store (used by :11434)
OLLAMA_MODELS_DIR="${OLLAMA_MODELS_DIR:-/FuZe/ollama}"
export OLLAMA_MODELS="$OLLAMA_MODELS_DIR"

# num_gpu sweep (high -> low)
NUM_GPU_CANDIDATES="${NUM_GPU_CANDIDATES:-80 72 64 56 48 40 32 24 16}"

# Bench params
PROMPT="${PROMPT:-Tell me a 1-sentence fun fact about GPUs.}"
EXHAUSTIVE="${EXHAUSTIVE:-0}"  # 0 = stop at first working optimized variant per (endpoint,base)
# Fast mode: skip baking variants; just pass options at runtime.
FAST_MODE="${FAST_MODE:-0}"
# Auto-NG selection: derive candidates from observed layers.model in logs.
AUTO_NG="${AUTO_NG:-1}"
# Percent steps (only used if AUTO_NG=1 and FAST_MODE=1)
NG_PERCENT_SET="${NG_PERCENT_SET:-100 90 75 60 50 40 30 20 10}"
# Early stop if improvement < this fraction over best so far (FAST_MODE only)
EARLY_STOP_DELTA="${EARLY_STOP_DELTA:-0.03}"
ZERO_TOKPS_BREAK="${ZERO_TOKPS_BREAK:-3}"
NO_IMPROVE_LIMIT="${NO_IMPROVE_LIMIT:-5}"
BENCH_NUM_PREDICT="${BENCH_NUM_PREDICT:-64}"
BENCH_NUM_CTX="${BENCH_NUM_CTX:-4096}"
TEMPERATURE="${TEMPERATURE:-0.0}"

# Verbose log toggle
VERBOSE="${VERBOSE:-1}"

# Timeouts (seconds) - fallbacks only if dynamic environment doesn't set them
WAIT_API_SECS="${WAIT_API_SECS:-30}"
TIMEOUT_GEN="${TIMEOUT_GEN:-60}"     # fallback for dynamic environment
TIMEOUT_TAGS="${TIMEOUT_TAGS:-30}"

SERVICE_HOME="${SERVICE_HOME:-/root}"   # only used for unit templates (not $HOME)
MATCH_GPU_A="${MATCH_GPU_A:-5090}"
MATCH_GPU_B="${MATCH_GPU_B:-3090 Ti}"

# Variant cleanup delegated to cleanup-variants.sh
GC_AFTER_RUN="${GC_AFTER_RUN:-1}"                  # 1=final pass GC

# Optional base-model filters for discovery
# Example: EXCLUDE_MODELS='^(tiny|sd3:)'   INCLUDE_MODELS='^llama4:'
EXCLUDE_MODELS="${EXCLUDE_MODELS:-}"
INCLUDE_MODELS="${INCLUDE_MODELS:-}"  # if set, only names matching this are kept

# Convert MODEL_PATTERN to INCLUDE_MODELS if provided
if [ -n "${MODEL_PATTERN:-}" ] && [ -z "${INCLUDE_MODELS:-}" ]; then
    # Convert pattern like "gpt-oss-20b" to match "gpt-oss:20b"
    # Replace last dash with colon for ollama tag format
    converted_pattern="${MODEL_PATTERN%-*}:${MODEL_PATTERN##*-}"
    # Also try exact match and partial matches
    INCLUDE_MODELS="(^${MODEL_PATTERN}(:|$)|^${converted_pattern}(:|$)|${MODEL_PATTERN})"
    echo "Filtering models with pattern: ${MODEL_PATTERN} -> regex: ${INCLUDE_MODELS}"
fi

# Optional alias prefix/suffix for variant naming and logs
ALIAS_PREFIX="${ALIAS_PREFIX:-LLM-FuZe-}"
ALIAS_SUFFIX="${ALIAS_SUFFIX:-}"
# Optionally bake the best variant tag at the end (even in FAST_MODE)
PUBLISH_BEST="${PUBLISH_BEST:-0}"
# Optional warm-up before benchmarking published tag
WARMUP_PUBLISH="${WARMUP_PUBLISH:-1}"
WARMUP_NUM_PREDICT="${WARMUP_NUM_PREDICT:-64}"

# Binary
readonly OLLAMA_BIN="${OLLAMA_BIN:-/usr/local/bin/ollama}"

# Derived
readonly HOSTNAME_NOW="$(hostname -s 2>/dev/null || hostname)"
readonly TS="${RUN_TS:-$(date +%Y%m%d_%H%M%S)}"
readonly CSV_FILE="${LOG_DIR}/ollama_bench_${TS}.csv"
readonly SUMMARY_FILE="${LOG_DIR}/${HOSTNAME_NOW}-${TS}.benchmark"
readonly CREATE_LOG="${LOG_DIR}/ollama_create_${TS}.log"
readonly CREATED_LIST="${LOG_DIR}/ollama_created_${TS}.txt"

readonly PULL_FROM="127.0.0.1:${PERSISTENT_PORT}"

# Debug capture (request/response per bench)
DEBUG_BENCH="${DEBUG_BENCH:-0}"
DEBUG_DIR="${LOG_DIR}/debug_${TS}"
[ "$DEBUG_BENCH" -eq 1 ] && mkdir -p "$DEBUG_DIR" || true

IS_ROOT=$([ "$(id -u)" -eq 0 ] && echo 1 || echo 0)
SKIP_TEST_UNITS="${SKIP_TEST_UNITS:-$([ "$IS_ROOT" -eq 1 ] && echo 0 || echo 1)}"

# ------------------------------------------------------------------------------
# GPU Service Management
# ------------------------------------------------------------------------------

# Ollama service template function
create_ollama_service_template() {
    local service_name="$1"
    local port="$2" 
    local gpu_spec="$3"
    
    # Get default ollama user/group from stock service
    local ollama_user="ollama"
    local ollama_group="ollama"
    local models_dir="${OLLAMA_MODELS_DIR:-/FuZe/ollama}"
    
    # Create service file
    cat > "/etc/systemd/system/$service_name" <<EOF
[Unit]
Description=Ollama GPU Test Service ($gpu_spec)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/ollama serve
User=$ollama_user
Group=$ollama_group
SupplementaryGroups=video render
Restart=always
RestartSec=3
Environment="OLLAMA_HOST=0.0.0.0:$port"
Environment="OLLAMA_MODELS=/FuZe/ollama"
Environment="CUDA_VISIBLE_DEVICES=$gpu_spec"
Environment="OLLAMA_SCHED_SPREAD=1"
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"
Environment="LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu"
Environment="HOME=/usr/share/ollama"
WorkingDirectory=/usr/share/ollama

[Install]
WantedBy=default.target
EOF
}


# ------------------------------------------------------------------------------
# UI helpers
# ------------------------------------------------------------------------------
c_bold="\033[1m"; c_red="\033[31m"; c_green="\033[32m"; c_yellow="\033[33m"; c_reset="\033[0m"
log(){ echo -e "$*"; }
info(){ [ "$VERBOSE" -ne 0 ] && echo -e "${c_bold}==${c_reset} $*"; }
ok(){ echo -e "${c_green}✔${c_reset} $*"; }
warn(){ echo -e "${c_yellow}!${c_reset} $*"; }
err(){ echo -e "${c_red}✖${c_reset} $*" >&2; }

need(){ command -v "$1" >/dev/null 2>&1 || { err "Missing dependency: $1"; exit 1; }; }
need curl; need jq; need awk; need sed; need systemctl

# ------------------------------------------------------------------------------
# HTTP helpers
# ------------------------------------------------------------------------------
# Ollama durations are in nanoseconds; convert to seconds for tok/s
calc_tokps(){ awk -v ec="$1" -v ed="$2" 'BEGIN{ if(ed<=0){print "0.00"} else {printf "%.2f", (ec+0.0)/(ed/1000000000.0)} }'; }

curl_tags(){ local ep="$1"; curl -fsS --max-time "$TIMEOUT_TAGS" "http://${ep}/api/tags" || return 1; }

curl_gen(){
  local ep="$1" model="$2" opts_json="$3" prompt="$4" to="$5"
  local payload
  # Force non-streaming responses for simpler parsing; merge any provided options
  payload="$(jq -cn \
    --arg m "$model" \
    --arg p "$prompt" \
    --argjson o "$opts_json" \
    --argjson t "$TEMPERATURE" \
    --argjson nc "$BENCH_NUM_CTX" \
    '{model:$m, prompt:$p, stream:false, temperature:$t, num_ctx:$nc} + $o')" || return 1
  
  echo "DEBUG: curl_gen endpoint: http://${ep}/api/generate" >> /tmp/curl_debug.log
  echo "DEBUG: curl_gen payload: $payload" >> /tmp/curl_debug.log
  
  local response
  response=$(curl -sS --max-time "$to" -H 'Content-Type: application/json' -d "$payload" "http://${ep}/api/generate" || echo "curl_failed")
  
  echo "DEBUG: curl_gen response: $response" >> /tmp/curl_debug.log
  
  echo "$response"
}

# ------------------------------------------------------------------------------
# systemd helpers
# ------------------------------------------------------------------------------
service_env(){
  local unit="$1" key="$2"
  systemctl show "$unit" -p Environment 2>/dev/null | tr '\n' ' ' | sed -nE "s/.*${key}=([^ ]+).*/\1/p"
}

wait_api(){
  local ep="$1" i=0
  while (( i < WAIT_API_SECS )); do
    curl_tags "$ep" >/dev/null 2>&1 && return 0
    sleep 1; i=$((i+1))
  done
  return 1
}

unit_for_ep(){
  local ep="$1"
  local port="${ep##*:}"
  
  case "$port" in
    "${PERSISTENT_PORT}") echo "ollama-persist.service" ;;
    *) 
      # Check for dynamic GPU services
      for service_file in /etc/systemd/system/ollama-test-*.service; do
        if [ -f "$service_file" ]; then
          local service_name="$(basename "$service_file")"
          local service_port="$(systemctl show "$service_name" --property=Environment | grep -o 'OLLAMA_HOST=[^[:space:]]*' | cut -d: -f2 || echo "")"
          if [ "$service_port" = "$port" ]; then
            echo "$service_name"
            return
          fi
        fi
      done
      echo ""
      ;;
  esac
}

# Service management delegated to service-cleanup.sh

# Ensure service user and models dir ownership
ensure_service_user(){ if ! id -u ollama >/dev/null 2>&1; then warn "Creating system user 'ollama'"; groupadd --system ollama 2>/dev/null || true; useradd --system --no-create-home --gid ollama --groups video,render --shell /usr/sbin/nologin ollama 2>/dev/null || true; fi; }
prep_models_dir(){ mkdir -p "$OLLAMA_MODELS_DIR" "$LOG_DIR"; chown -R ollama:ollama "$OLLAMA_MODELS_DIR" 2>/dev/null || true; }

gpu_table(){ nvidia-smi --query-gpu=name,uuid,memory.total --format=csv,noheader 2>/dev/null || true; }

offload_triplet(){ # name,uuid,memmib for an ollama-test-* unit
  local unit="$1" gi
  gi="$(service_env "$unit" CUDA_VISIBLE_DEVICES)"
  if [ -n "${gi:-}" ] && command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name,uuid,memory.total --format=csv,noheader 2>/dev/null \
      | awk -F',' -v id="$gi" 'NR==(id+1){gsub(/^[[:space:]]+|[[:space:]]+$/,"",$1); gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); gsub(/ MiB/,"",$3); print $1","$2","$3; exit}'
  fi
}

# This function is now the single source of truth for GPU labels.
# It is called with a specific GPU index.
get_gpu_model_label() {
  local idx="$1"
  local gpu_info
  gpu_info="$(nvidia-smi --query-gpu=name,serial --format=csv,noheader --id="$idx" 2>/dev/null | head -1)"
  if [ -n "$gpu_info" ]; then
    # Normalize: "NVIDIA GeForce RTX 3090 Ti, 123...45" -> "3090ti45"
    echo "$gpu_info" | awk -F', ' '{
      s = tolower($1);
      gsub(/nvidia|geforce|rtx|[[:space:]]|-/, "", s);
      serial_suffix = substr($2, length($2)-1);
      print s serial_suffix
    }'
  else
    echo "unknown-gpu"
  fi
}

# This is the main loop that iterates over services
main() {
  # Get the list of active endpoints and their associated GPU indices
  endpoints_with_indices=$(get_gpu_service_endpoints "ollama")

  for endpoint_info in $endpoints_with_indices; do
    IFS='|' read -r ep gpu_idx <<< "$endpoint_info"
    
    # Pass the specific gpu_idx to the benchmark function
    bench_on_endpoint "$ep" "$gpu_idx"
  done
}


# The benchmark function now receives the gpu_idx
bench_on_endpoint() {
    local ep="$1"
    local gpu_idx="$2"
    # ... existing code ...
    
    # Use the passed gpu_idx to get the correct label
    local gpu_lbl
    gpu_lbl="$(get_gpu_model_label "$gpu_idx")"

    # ... existing code ...
    # When baking the model, use the correct gpu_lbl
    local baked_variant_name="FuZe-${alias}-${gpu_lbl}-ng${best_ng}"
    # ... existing code ...
}

have_model(){
  local tag="$1"
  OLLAMA_HOST="http://${PULL_FROM}" "$OLLAMA_BIN" list 2>/dev/null \
    | awk '($1!="" && $1!="NAME"){print $1}' | grep -Fxq "$tag"
}

pull_if_missing(){
  local base="$1"
  if ! have_model "$base"; then
    info "Pulling missing: $base (via ${PULL_FROM})"
    OLLAMA_HOST="http://${PULL_FROM}" "$OLLAMA_BIN" pull "$base"
  fi
}

suffix_for_ep(){
  case "$1" in
    *:${TEST_PORT_A}) echo "A" ;;
    *:${TEST_PORT_B}) echo "B" ;;
    *:${TEST_PORT_MULTI:-11437}) echo "MULTI" ;;
    *:*) echo "${1##*:}" ;;
  esac
}

bench_base_as_is(){ # ep baseTag
  local ep="$1" base="$2" gpu_lbl enhanced_base_label; gpu_lbl="$(gpu_label_for_ep "$ep")"
  if ! curl_tags "$ep" >/dev/null 2>&1; then
    warn "Endpoint ${ep} not responding; skipping."
    return 1
  fi
  enhanced_base_label="$(enhanced_alias "$base" "$gpu_lbl" "0")"
  bench_once "$ep" "$base" "$base" "$enhanced_base_label" "" "$gpu_lbl" >/dev/null || return 1
}

# Discover model layer count (layers.model) by scraping recent unit logs
discover_layers_model(){ # ep -> echoes integer or empty
  local ep="$1" unit; unit="$(unit_for_ep "$ep")"
  # pull the last few hundred lines and look for 'layers.model=NN'
  journalctl -u "$unit" -n 400 --no-pager 2>/dev/null \
    | sed -nE 's/.*layers\.model=([0-9]+).*/\1/p' | tail -n1 || true
}

# Build NG candidate list from a layer count and NG_PERCENT_SET
ng_candidates_from_layers(){ # layers -> echo list high->low unique >=1
  local layers="$1"; local out=(); local seen="|" ng
  for pct in $NG_PERCENT_SET; do
    ng=$(( (layers * pct + 99) / 100 ))
    (( ng < 1 )) && ng=1
    case "$seen" in *"|$ng|"*) ;; *) out+=("$ng"); seen+="$ng|" ;; esac
  done
  echo "${out[*]}"
}

# Variant cleanup delegated to cleanup-variants.sh

wait_variant_visible(){ # ep variant secs
  local ep="$1" variant="$2" secs="${3:-12}" i=0
  local unit; unit="$(unit_for_ep "$ep")"
  while (( i < secs )); do
    if curl_tags "$ep" | jq -r '.models[].name' 2>/dev/null | grep -Fxq "$variant"; then
      return 0
    fi
    sleep 1; i=$((i+1))
  done
  warn "Variant $variant not visible on $ep after ${secs}s"
  return 1
}

base_alias(){ # "llama4:16x17b" -> "llama4-16x17b" with compact suffixes
  local s
  s="$(echo "$1" | sed -E 's#[/:]+#-#g')"
  # Strip existing LLM-FuZe- prefix to prevent recursive nesting
  s="${s#LLM-FuZe-}"
  # Compact common tokens: it->i, fp16->f16, bf16->b16
  s="${s//-it-/-i-}"
  s="${s%-it}"; s="${s%-i}"; # no-op cleanup if ends with -it, we transform below
  s="${s//-it/-i}"
  s="${s//-fp16/-f16}"
  s="${s//-bf16/-b16}"
  echo "$s"
}

# Enhanced alias with complete configuration details
enhanced_alias(){ # base_model_tag gpu_label num_gpu -> enhanced alias
  local base_tag="$1" gpu_label="$2" ng="$3"
  local alias stack_name pred_short ctx_short temp_short exhaustive_short
  
  # Base model alias
  alias="$(base_alias "$base_tag")"
  
  # Stack name
  stack_name="${FUZE_STACK_NAME:-ollama}"
  case "$stack_name" in
    llama.cpp) stack_name="llama" ;;
    Triton) stack_name="triton" ;;
  esac
  
  # Parameters
  pred_short="p${BENCH_NUM_PREDICT:-64}"
  ctx_short="c$((${BENCH_NUM_CTX:-4096} / 1000))k"
  temp_short="t$(printf "%02d" "$((${TEMPERATURE%%.*}0 + ${TEMPERATURE#*.}))")"
  exhaustive_short="$( [ "${EXHAUSTIVE:-0}" -eq 1 ] && echo "ex" || echo "std" )"
  
  # Construct enhanced alias
  echo "${alias}-${stack_name}-${gpu_label}-ng${ng}-${pred_short}-${ctx_short}-${temp_short}-${exhaustive_short}"
}

discover_models(){
  info "Discovering base models from persistent daemon (:${PERSISTENT_PORT})"
  local names out=()
  names="$(OLLAMA_HOST="http://${PULL_FROM}" "$OLLAMA_BIN" list 2>/dev/null | awk '($1!="NAME" && $1!="" && $1 !~ /^FuZe-/){print $1}')"
  # Remove optimized variants
  names=$(echo "$names" | grep -Ev -- '-nvidia-[a-z0-9]+(super|ti)?-ng[0-9]+(:|$)')
  # Apply generic filter_models from common.sh
  mapfile -t filtered < <(filter_models $names)
  for tag in "${filtered[@]}"; do
    [ -z "$tag" ] && continue
    local alias alias_full
    alias="$(base_alias "$tag")"
    alias_full="${alias}"
    if [ -n "$ALIAS_SUFFIX" ]; then alias_full="${alias_full}${ALIAS_SUFFIX}"; fi
    out+=("$tag|${alias_full}")
  done

  if [ "${#out[@]}" -eq 0 ]; then
    warn "No base models discovered — you may need to 'ollama pull <model>' on :${PERSISTENT_PORT}."
  else
    info "Models     : $(printf '%s ' "${out[@]}")"
  fi
  MODELS=("${out[@]}")
}

append_csv_row(){ echo "$*" >>"$CSV_FILE"; }

# ------------------------------------------------------------------------------
# CPU/GPU watchdog + record abandoned
# ------------------------------------------------------------------------------
## CPU peg watcher removed — we key off tokens_per_sec==0 instead

# ------------------------------------------------------------------------------
# bench_once (writes a CSV row; echoes tok/s)
# ------------------------------------------------------------------------------
bench_once(){ # ep baseTag modelTag label num_gpu gpu_label
  local ep="$1" base="$2" model="$3" label="$4" ng="${5:-}" gpu_lbl="$6"
  local sfx unit gname guid gmem opts tokps="0.00" ec=0 ed=1 o tmp rc=0
  sfx="$(suffix_for_ep "$ep")"
  unit="$(unit_for_ep "$ep")"
  IFS=',' read -r gname guid gmem <<<"$(offload_triplet "$unit")"

  if [ -n "${ng:-}" ]; then
    opts="$(jq -n \
      --argjson ng "$ng" \
      --argjson np "$BENCH_NUM_PREDICT" \
      --argjson nc "$BENCH_NUM_CTX" \
      --argjson t "$TEMPERATURE" \
      '{num_gpu:$ng, num_predict:$np, num_ctx:$nc, temperature:$t}')" || opts='{"num_gpu":'"${ng}"'}'
  else
    opts="$(jq -n \
      --argjson np "$BENCH_NUM_PREDICT" \
      --argjson nc "$BENCH_NUM_CTX" \
      --argjson t "$TEMPERATURE" \
      '{num_predict:$np, num_ctx:$nc, temperature:$t}')"
  fi

  # Single-path generate: no CPU monitoring; treat tok/s==0 as failure
  if [ "$DEBUG_BENCH" -eq 1 ]; then
    dbg_base="${DEBUG_DIR}/ollama_${sfx}_$(echo "$base" | sed 's#[/:]#-#g')_${label}_ng${ng:-base}"
    dbg_req="$(jq -cn --arg m "$model" --arg p "$PROMPT" --argjson o "$opts" '{model:$m, prompt:$p, stream:false} + $o')"
    echo "$dbg_req" > "${dbg_base}.request.json"
  fi
  o="$(curl_gen "$ep" "$model" "$opts" "$PROMPT" "$TIMEOUT_GEN" || true)"
  if [ -n "$o" ]; then
    ec="$(jq -r -s '.[-1].eval_count // 0' <<<"$o" 2>/dev/null || echo 0)"
    ed="$(jq -r -s '.[-1].eval_duration // 0' <<<"$o" 2>/dev/null || echo 1)"
    tokps="$(calc_tokps "$ec" "$ed")"
    if [ "$DEBUG_BENCH" -eq 1 ]; then
      echo "$o" > "${dbg_base}.response.json"
      printf '{"eval_count":%s,"eval_duration":%s,"tokens_per_sec":%s,"endpoint":"%s","model":"%s"}\n' \
        "$ec" "$ed" "$tokps" "$ep" "$model" > "${dbg_base}.metrics.json" || true
    fi
  fi

  # If tok/s is zero in debug mode, capture a real-time probe and recent journal logs
  if [ "$DEBUG_BENCH" -eq 1 ] && awk -v t="$tokps" 'BEGIN{exit !(t+0==0)}'; then
    # Probe generate with a minimal prompt
    local probe_req probe_out
    probe_req="$(jq -cn --arg m "$model" --arg p "ping" '{model:$m, prompt:$p, stream:false, num_predict:32}')"
    echo "$probe_req" > "${dbg_base}.probe.request.json"
    probe_out="$(curl -sS -H 'Content-Type: application/json' -d "$probe_req" "http://${ep}/api/generate" || true)"
    [ -n "$probe_out" ] && echo "$probe_out" > "${dbg_base}.probe.response.json"
    # Derive probe metrics if present
    if [ -n "$probe_out" ]; then
      local pec ped ptok
      pec="$(jq -r '.eval_count // 0' <<<"$probe_out" 2>/dev/null || echo 0)"
      ped="$(jq -r '.eval_duration // 0' <<<"$probe_out" 2>/dev/null || echo 1)"
      ptok="$(calc_tokps "$pec" "$ped")"
      printf '{"eval_count":%s,"eval_duration":%s,"tokens_per_sec":%s,"endpoint":"%s","model":"%s","probe":true}\n' \
        "$pec" "$ped" "$ptok" "$ep" "$model" > "${dbg_base}.probe.metrics.json" || true
    fi
    # Capture recent journal logs for the service behind this endpoint
    local u
    u="$(unit_for_ep "$ep")"
    if [ -n "$u" ]; then
      journalctl -u "$u" -n 200 --no-pager > "${dbg_base}.journal.txt" 2>/dev/null || true
    fi
  fi
  # No temp file cleanup needed in single-path mode

  # CSV: keep this 16-col schema (tokens_per_sec at column 12)
  # num_gpu (8), then explicitly leave num_ctx (9), batch (10), num_predict (11) empty
  append_csv_row "${TS},${ep},${unit},${sfx},${base},${label},${model},${ng:-},,,,${tokps},${gpu_lbl},${gname},${guid},${gmem}"

  # Variant cleanup delegated to cleanup-variants.sh

  echo "$tokps"
}

tune_and_bench_one(){ # ep_with_gpu baseTag aliasBase
  local ep_with_gpu="$1"
  local ep="${1%|*}"
  local base="$2" 
  local alias_base="$3"
  local gpu_lbl; gpu_lbl="$(gpu_label_for_ep "$ep")"

  pull_if_missing "$base"

  if ! curl_tags "$ep" | jq -r '.models[].name' 2>/dev/null | grep -Fxq "$base"; then
    warn "Base ${base} NOT visible on ${ep}. Build happens on :${PERSISTENT_PORT}; benches will run via ${ep}."
  fi

  # Skip base-as-is bench here - handled separately for vanilla metrics

  local best_tokps="0.00" best_name="" best_ng="" first_ok=0
  local zero_run=0 no_improve_run=0
  local ng_list=""
  if [ "$FAST_MODE" -eq 1 ] && [ "$AUTO_NG" -eq 1 ]; then
    # Try to infer model layers from logs after the base run
    local lm="$(discover_layers_model "$ep" || true)"
    if [[ "$lm" =~ ^[0-9]+$ ]]; then
      ng_list="$(ng_candidates_from_layers "$lm")"
      info " Using AUTO_NG (layers.model=$lm) -> ng: ${ng_list}"
    fi
  fi
  [ -z "$ng_list" ] && ng_list="${NUM_GPU_CANDIDATES}"

  for ng in ${ng_list}; do
    if [ "$FAST_MODE" -eq 1 ]; then
      # No baking; bench base with runtime option
      local enhanced_fast_label
      enhanced_fast_label="$(enhanced_alias "$base" "$gpu_lbl" "$ng")"
      local tokps; tokps="$(bench_once "$ep" "$base" "$base" "$enhanced_fast_label" "$ng" "$gpu_lbl" || echo 0.00)"
      # Count consecutive zero tok/s (avoid CPU thrash)
      if awk -v a="$tokps" 'BEGIN{exit !(a+0==0)}'; then
        zero_run=$((zero_run+1))
      else
        zero_run=0
      fi
      
      # Fail if there are too many consecutive zero tok/s runs
      if [ "${ZERO_TOKPS_BREAK:-0}" -gt 0 ] && [ "$zero_run" -ge "${ZERO_TOKPS_BREAK}" ]; then
        err "Failing after ${zero_run} consecutive zero tok/s trials"
        exit 1
      fi

      # Mark that at least one optimized run succeeded
      if awk -v a="$tokps" 'BEGIN{exit !(a>0)}'; then first_ok=1; fi
      # stop early if improvement < EARLY_STOP_DELTA over current best
      if [ "$EXHAUSTIVE" -eq 0 ]; then
        # since list is descending from high->low, break after first working
        if awk -v a="$tokps" 'BEGIN{exit !(a>0)}'; then ok "     First working: ng=${ng} at ${tokps} tok/s"; first_ok=1; break; fi
      else
        # In EXHAUSTIVE=1, still guard against long flat streaks
        if [ "${NO_IMPROVE_LIMIT:-0}" -gt 0 ] && [ "$no_improve_run" -ge "${NO_IMPROVE_LIMIT}" ] && awk -v b="$best_tokps" 'BEGIN{exit !(b>0)}'; then
          warn "     Breaking after ${no_improve_run} non-improving trials (best=${best_tokps} tok/s)"
          break
        fi
      fi
    else
      # Smart baking: Test all variants first to find optimal, then bake only the best if needed
      info " Testing variants to find optimal num_gpu..."
      local test_best_tokps="0.00" test_best_ng="" test_first_ok=0
      local test_zero_run=0 test_no_improve_run=0
      
      # Phase 1: Test all candidates without baking
      for ng in ${ng_list}; do
        info "  -> Testing ng=${ng}..."
        local enhanced_test_label
        enhanced_test_label="$(enhanced_alias "$base" "$gpu_lbl" "$ng")"
        info "  -> Calling bench_once for ng=${ng}"
        local tokps; tokps="$(bench_once "$ep" "$base" "$base" "$enhanced_test_label" "$ng" "$gpu_lbl" || echo 0.00)"
        info "  <- bench_once for ng=${ng} returned: ${tokps}"
        
        # Track best performer
        if awk -v a="$tokps" -v b="$test_best_tokps" 'BEGIN{exit !(a>b)}'; then
          test_best_ng="$ng"; test_best_tokps="$tokps"; test_no_improve_run=0
        else
          test_no_improve_run=$((test_no_improve_run+1))
        fi
        
        # Count consecutive zero tok/s
        if awk -v a="$tokps" 'BEGIN{exit !(a+0==0)}'; then
          test_zero_run=$((test_zero_run+1))
        else
          test_zero_run=0
        fi

        # Fail if there are too many consecutive zero tok/s runs
        if [ "${ZERO_TOKPS_BREAK:-0}" -gt 0 ] && [ "$test_zero_run" -ge "${ZERO_TOKPS_BREAK}" ]; then
            err "Failing after ${test_zero_run} consecutive zero tok/s trials"
            exit 1
        fi
        
        # Mark if at least one worked
        if awk -v a="$tokps" 'BEGIN{exit !(a>0)}'; then test_first_ok=1; fi
        
        # Early stop logic (same as FAST_MODE)
        if [ "$EXHAUSTIVE" -eq 0 ]; then
          if awk -v a="$tokps" 'BEGIN{exit !(a>0)}'; then 
            ok "     First working: ng=${ng} at ${tokps} tok/s"; test_first_ok=1; break; 
          fi
        else
          if [ "${NO_IMPROVE_LIMIT:-0}" -gt 0 ] && [ "$test_no_improve_run" -ge "${NO_IMPROVE_LIMIT}" ] && awk -v b="$test_best_tokps" 'BEGIN{exit !(b>0)}'; then
            warn "     Breaking after ${test_no_improve_run} non-improving trials (best=${test_best_tokps} tok/s)"
            break
          fi
        fi
      done
      
      # Phase 2: Bake only the optimal variant if it doesn't already exist
      if awk -v b="$test_best_tokps" 'BEGIN{exit !(b>0)}' && [ -n "$test_best_ng" ]; then
  local optimal_name optimal_label
  local stack_prefix="FuZe-${FUZE_STACK_NAME:-ollama}-"
  optimal_name="${stack_prefix}${alias_base}-$(gpu_label_for_ep "$ep")-ng${test_best_ng}"
  optimal_label="$(enhanced_alias "$base" "$gpu_lbl" "$test_best_ng")"
        
        # Check if optimal variant already exists
        if curl_tags "$ep" | jq -r '.models[].name' 2>/dev/null | grep -Fxq "${optimal_name}:latest"; then
          info " Optimal variant already exists: ${optimal_name}:latest (ng=${test_best_ng}, ${test_best_tokps} tok/s)"
          best_tokps="$test_best_tokps"; best_name="$optimal_name"; best_ng="$test_best_ng"; first_ok="$test_first_ok"
        else
          info " Baking optimal variant: ${optimal_name} (ng=${test_best_ng}, ${test_best_tokps} tok/s)"
          if "$BAKERY_BIN" "$optimal_name" "$base" "$test_best_ng" "$PULL_FROM" "$OLLAMA_BIN" "$CREATE_LOG" "$CREATED_LIST"; then
            wait_variant_visible "$ep" "${optimal_name}:latest" 12 || true
            # Re-bench the baked variant to verify performance
            local baked_tokps
            if baked_tokps="$(bench_once "$ep" "$base" "${optimal_name}:latest" "$optimal_label" "$test_best_ng" "$gpu_lbl")"; then
              best_tokps="$baked_tokps"; best_name="$optimal_name"; best_ng="$test_best_ng"; first_ok=1
              ok "     Baked variant performance: ${baked_tokps} tok/s"
            else
              warn "     Baked variant bench failed, using test result: ${test_best_tokps} tok/s"
              best_tokps="$test_best_tokps"; best_name="$optimal_name"; best_ng="$test_best_ng"; first_ok="$test_first_ok"
            fi
          else
            warn "Optimal variant bake failed: ${optimal_name}"
            # Fall back to test results
            best_tokps="$test_best_tokps"; best_name="${alias_base}+ng${test_best_ng}"; best_ng="$test_best_ng"; first_ok="$test_first_ok"
          fi
        fi
      else
        warn " No working variants found during testing"
        best_tokps="0.00"; best_name=""; best_ng=""; first_ok=0
      fi
    fi
  done

  if awk -v b="$best_tokps" 'BEGIN{exit !(b>0)}'; then
    ok " Best so far: ${best_name} (ng=${best_ng}) at ${best_tokps} tok/s"
  else
    warn " No optimized variant worked for ${base} on ${ep}"
  fi

  # Optionally publish the best variant tag (even when FAST_MODE=1)
  if [ "$PUBLISH_BEST" -eq 1 ] && awk -v b="$best_tokps" 'BEGIN{exit !(b>0)}'; then
    local pub_name enhanced_pub_label
  stack_prefix="FuZe-${FUZE_STACK_NAME:-ollama}-"
  pub_name="${stack_prefix}${alias_base}-$(gpu_label_for_ep "$ep")-ng${best_ng}"
    enhanced_pub_label="$(enhanced_alias "$base" "$gpu_lbl" "$best_ng")"
    info " Publishing best variant tag: ${pub_name} (FROM ${base} num_gpu=${best_ng})"
  if "$BAKERY_BIN" "$pub_name" "$base" "$best_ng" "$PULL_FROM" "$OLLAMA_BIN" "$CREATE_LOG" "$CREATED_LIST"; then
      wait_variant_visible "$ep" "${pub_name}:latest" 12 || true
      ok " Published: ${pub_name}:latest"
      # Optional warm-up request to reduce cold-start skew
      if [ "$WARMUP_PUBLISH" -eq 1 ]; then
        local wu_req
        wu_req="$(jq -cn --arg m "${pub_name}:latest" --arg p "warm up" --argjson np "$WARMUP_NUM_PREDICT" '{model:$m, prompt:$p, stream:false, num_predict:$np}')"
        curl -sS -H 'Content-Type: application/json' -d "$wu_req" "http://${ep}/api/generate" >/dev/null 2>&1 || true
        sleep 1
      fi
      # Re-bench the published tag so CSV contains an explicit row for it
      local pub_tokps
      pub_tokps="$(bench_once "$ep" "$base" "${pub_name}:latest" "$enhanced_pub_label" "$best_ng" "$gpu_lbl" || echo 0.00)"
      if awk -v a="$pub_tokps" 'BEGIN{exit !(a>0)}'; then
        ok " Published variant performance: ${pub_tokps} tok/s"
      else
        warn " Published variant returned ${pub_tokps} tok/s"
      fi
    else
      warn " Failed to publish variant: ${pub_name}"
    fi
  fi
}

gc_created_tags(){
  [ "${GC_AFTER_RUN}" -eq 1 ] || return 0
  [ -s "$CREATED_LIST" ] || { info "GC summary: nothing created."; return 0; }
  # Variant cleanup delegated to cleanup-variants.sh
  local total=0
  while IFS= read -r tag; do
    total=$((total+1))
  done < "$CREATED_LIST"
  info "GC created variants: total=${total} (cleanup delegated to cleanup-variants.sh)"
}

# ------------------------------------------------------------------------------
# Header & preamble
# ------------------------------------------------------------------------------
echo "ts,endpoint,unit,suffix,base_model,variant_label,model_tag,num_gpu,num_ctx,batch,num_predict,tokens_per_sec,gpu_label,gpu_name,gpu_uuid,gpu_mem_mib" > "$CSV_FILE"
: > "$CREATE_LOG"
: > "$CREATED_LIST"

log "== One-at-a-time auto-tune + bench (POSIX) =="
log "Persistent : 127.0.0.1:${PERSISTENT_PORT}"
log "CSV        : ${CSV_FILE}"
log "Analyze    : $(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common/analyze.sh --stack ollama"

# ------------------------------------------------------------------------------
# Prepare services (use stock service for :11434; create test A/B here)
# ------------------------------------------------------------------------------
info "Preparing directories and services"
if [ "$IS_ROOT" -eq 1 ]; then
  ensure_service_user || true
  prep_models_dir || true
fi
log "$(gpu_table | sed 's/^/GPU: /')"

# Setup GPU services
if ! setup_gpu_services "ollama" "create_ollama_service_template"; then
    error "Failed to set up GPU services. Aborting."
    exit 1
fi

# Make sure :11434 is up (stock "ollama.service" _or_ our "ollama-persist.service")
if ! curl -fsS "http://127.0.0.1:${PERSISTENT_PORT}/api/tags" >/dev/null 2>&1; then
  # Prefer stock unit if present; else create our persist unit
  if [ "$IS_ROOT" -eq 1 ]; then
    if systemctl list-unit-files | grep -q '^ollama.service'; then
      systemctl enable --now ollama.service || true
    else
      write_unit "ollama-persist.service" "$PERSISTENT_PORT" "" "Ollama (persistent on :${PERSISTENT_PORT})"
      systemctl enable --now ollama-persist.service || true
    fi
  else
    warn "Persistent daemon :${PERSISTENT_PORT} is not up and this run is not root. Start ollama.service or rerun with sudo."
  fi
fi

# Build endpoints array dynamically using GPU services
ENDPOINTS=()
if [ "$SKIP_TEST_UNITS" -eq 1 ]; then
  ENDPOINTS+=("127.0.0.1:${PERSISTENT_PORT}")
else
  # Get GPU service endpoints from common function
  while IFS= read -r endpoint; do
    ENDPOINTS+=("$endpoint")
  done < <(get_gpu_service_endpoints "ollama")
  
  # Always include persistent service for model management
  ENDPOINTS+=("127.0.0.1:${PERSISTENT_PORT}")
fi

info "TEST A OLLAMA_MODELS: $(service_env ollama-test-a.service OLLAMA_MODELS 2>/dev/null || echo "N/A")"
info "TEST B OLLAMA_MODELS: $(service_env ollama-test-b.service OLLAMA_MODELS 2>/dev/null || echo "N/A")"

info "Waiting for APIs"
wait_api "127.0.0.1:${PERSISTENT_PORT}" || warn "API :${PERSISTENT_PORT} not reachable yet"
for ep_with_gpu in "${ENDPOINTS[@]}"; do
    ep="${ep_with_gpu%|*}"
    wait_api "$ep" || warn "API $ep (from $ep_with_gpu) slow to start"
done

info "ollama version: $($OLLAMA_BIN --version || echo 'unknown')"

# ------------------------------------------------------------------------------
# Discover base models & run
# ------------------------------------------------------------------------------
MODELS=()
discover_models
if [ "${#MODELS[@]}" -eq 0 ]; then
  warn "Nothing to do (no base models)."
fi

# Service management delegated to service-cleanup.sh - endpoints should be ready
if [ "$SKIP_TEST_UNITS" -eq 0 ]; then
  for ep_with_gpu in "${ENDPOINTS[@]}"; do
    ep="${ep_with_gpu%|*}"
    wait_api "$ep" || warn "API $ep is not up yet (continuing)"
  done
fi

# Separate vanilla and tuned benchmarking
PERSISTENT_EP="127.0.0.1:${PERSISTENT_PORT}"
GPU_ENDPOINTS=()

# Build GPU endpoints array (exclude persistent service)
# If GPU configuration was provided and services were set up, discover them regardless of SKIP_TEST_UNITS
if [ -n "${GPU_DEVICES:-}${COMBINED_DEVICES:-}" ]; then
  while IFS= read -r endpoint; do
    GPU_ENDPOINTS+=("$endpoint")
  done < <(get_gpu_service_endpoints "ollama")
fi

for m in "${MODELS[@]}"; do
  base="${m%%|*}"; alias_base="${m##*|}"
  
  # Vanilla benchmarking on persistent service (base-as-is only)
  log "=== Vanilla metrics on ${PERSISTENT_EP} — base: ${base} (alias ${alias_base}) ==="
  bench_base_as_is "$PERSISTENT_EP" "$base" || warn "vanilla bench skipped for $base"
  
  # Parameter tuning on GPU services
  for ep_with_gpu in "${GPU_ENDPOINTS[@]}"; do
    ep="${ep_with_gpu%|*}"
    log "=== Tuning on ${ep} — base: ${base} (alias ${alias_base}) ==="
    tune_and_bench_one "$ep_with_gpu" "$base" "$alias_base"
  done
done

gc_created_tags || true

# No inline analysis/summary here. Use common/analyze.sh to summarize results.

ok "Done."
