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
# Paths & logging
# ------------------------------------------------------------------------------
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${LOG_DIR:-/var/log/fuze-stack}"
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

# Persistent model store (used by :11434)
OLLAMA_MODELS_DIR="${OLLAMA_MODELS_DIR:-/FuZe/models/ollama}"

# num_gpu sweep (high -> low)
NUM_GPU_CANDIDATES="${NUM_GPU_CANDIDATES:-80 72 64 56 48 40 32 24 16}"

# Bench params
PROMPT="${PROMPT:-Tell me a 1-sentence fun fact about GPUs.}"
EXHAUSTIVE="${EXHAUSTIVE:-0}"  # 0 = stop at first working optimized variant per (endpoint,base)
# Fast mode: skip baking variants; just pass options at runtime.
FAST_MODE="${FAST_MODE:-1}"
# Auto-NG selection: derive candidates from observed layers.model in logs.
AUTO_NG="${AUTO_NG:-1}"
# Percent steps (only used if AUTO_NG=1 and FAST_MODE=1)
NG_PERCENT_SET="${NG_PERCENT_SET:-100 90 75 60 50 40 30 20 10}"
# Early stop if improvement < this fraction over best so far (FAST_MODE only)
EARLY_STOP_DELTA="${EARLY_STOP_DELTA:-0.03}"
BENCH_NUM_PREDICT="${BENCH_NUM_PREDICT:-64}"
BENCH_NUM_CTX="${BENCH_NUM_CTX:-4096}"
TEMPERATURE="${TEMPERATURE:-0.0}"

# Verbose log toggle
VERBOSE="${VERBOSE:-1}"

# Timeouts (seconds)
WAIT_API_SECS="${WAIT_API_SECS:-60}"
TIMEOUT_GEN="${TIMEOUT_GEN:-90}"
TIMEOUT_TAGS="${TIMEOUT_TAGS:-10}"

SERVICE_HOME="${SERVICE_HOME:-/root}"   # only used for unit templates (not $HOME)
MATCH_GPU_A="${MATCH_GPU_A:-5090}"
MATCH_GPU_B="${MATCH_GPU_B:-3090 Ti}"

KEEP_FAILED_VARIANTS="${KEEP_FAILED_VARIANTS:-0}"  # 0=rm failed/invisible variants
GC_AFTER_RUN="${GC_AFTER_RUN:-1}"                  # 1=final pass GC

# Optional base-model filters for discovery
# Example: EXCLUDE_MODELS='^(tiny|sd3:)'   INCLUDE_MODELS='^llama4:'
EXCLUDE_MODELS="${EXCLUDE_MODELS:-}"
INCLUDE_MODELS="${INCLUDE_MODELS:-}"  # if set, only names matching this are kept

# Optional alias prefix for variant naming and logs
ALIAS_PREFIX="${ALIAS_PREFIX:-FuZeCORE-}"
# Optionally bake the best variant tag at the end (even in FAST_MODE)
PUBLISH_BEST="${PUBLISH_BEST:-0}"

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
  curl -sS --max-time "$to" -H 'Content-Type: application/json' -d "$payload" "http://${ep}/api/generate" || return 1
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
  case "$1" in
    *:${TEST_PORT_A}) echo "ollama-test-a.service" ;;
    *:${TEST_PORT_B}) echo "ollama-test-b.service" ;;
    *:${PERSISTENT_PORT}) echo "ollama-persist.service" ;;
    *) echo "" ;;
  esac
}

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
Environment=OLLAMA_HOST=127.0.0.1:${port}
ExecStart=${OLLAMA_BIN} serve
Restart=always
RestartSec=2
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
UNIT
}

# Optional clean start of test units
CLEAN_START_TESTS="${CLEAN_START_TESTS:-1}"
stop_unit(){ local u="$1"; systemctl stop "$u" 2>/dev/null || true; systemctl disable "$u" 2>/dev/null || true; systemctl reset-failed "$u" 2>/dev/null || true; }

# Ensure service user and models dir ownership
ensure_service_user(){ if ! id -u ollama >/dev/null 2>&1; then warn "Creating system user 'ollama'"; groupadd --system ollama 2>/dev/null || true; useradd --system --no-create-home --gid ollama --groups video,render --shell /usr/sbin/nologin ollama 2>/dev/null || true; fi; }
prep_models_dir(){ mkdir -p "$OLLAMA_MODELS_DIR" "$LOG_DIR"; chown -R ollama:ollama "$OLLAMA_MODELS_DIR" 2>/dev/null || true; }

restart_ep(){
  local ep="$1" u; u="$(unit_for_ep "$ep")"
  [ -n "$u" ] || return 0
  systemctl daemon-reload || true
  systemctl enable --now "$u" || true
  systemctl restart "$u" || true
}

gpu_table(){ nvidia-smi --query-gpu=name,uuid,memory.total --format=csv,noheader 2>/dev/null || true; }

offload_triplet(){ # name,uuid,memmib for an ollama-test-* unit
  local unit="$1" gi
  gi="$(service_env "$unit" CUDA_VISIBLE_DEVICES)"
  if [ -n "${gi:-}" ] && command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name,uuid,memory.total --format=csv,noheader 2>/dev/null \
      | awk -F',' -v id="$gi" 'index($2,id){gsub(/^[[:space:]]+|[[:space:]]+$/,"",$1); gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); gsub(/ MiB/,"",$3); print $1","$2","$3; exit}'
  fi
}

normalize_gpu_label(){
  # "NVIDIA GeForce RTX 5090" -> nvidia-5090 ; "NVIDIA GeForce RTX 3090 Ti" -> nvidia-3090ti
  local raw="$1" s
  s="$(echo "$raw" | tr '[:upper:]' '[:lower:]')"
  s="${s//nvidia /}"
  s="${s//geforce /}"
  s="${s//rtx /}"
  s="${s// /}"
  s="${s//ti/ti}"
  echo "nvidia-${s//super/super}"
}

gpu_label_for_ep(){
  local ep="$1" unit lbl name uuid mem
  unit="$(unit_for_ep "$ep")"
  IFS=',' read -r name uuid mem <<<"$(offload_triplet "$unit")"
  if [ -z "${name:-}" ]; then
    echo "nvidia-unknown"
  else
    echo "$(normalize_gpu_label "$name")"
  fi
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
    *:*) echo "${1##*:}" ;;
  esac
}

bench_base_as_is(){ # ep baseTag
  local ep="$1" base="$2" gpu_lbl; gpu_lbl="$(gpu_label_for_ep "$ep")"
  if ! curl_tags "$ep" >/dev/null 2>&1; then
    warn "Endpoint ${ep} not responding; restarting unit."
    restart_ep "$ep" || true
    wait_api "$ep" || true
    sleep 2
  fi
  bench_once "$ep" "$base" "$base" "base-as-is" "" "$gpu_lbl" >/dev/null || return 1
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

bake_variant(){ # newname base num_gpu
  local newname="$1" base="$2" ng="$3" tf
  tf="$(mktemp)"
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
  local full="$1"
  info "Removing variant tag: $full"
  OLLAMA_HOST="http://${PULL_FROM}" "$OLLAMA_BIN" rm "$full" 2>/dev/null || true
}

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

base_alias(){ # "llama4:16x17b" -> "llama4-16x17b"
  echo "$1" | sed -E 's#[/:]+#-#g'
}

discover_models(){
  info "Discovering base models from persistent daemon (:${PERSISTENT_PORT})"
  local names out=()
  names="$(OLLAMA_HOST="http://${PULL_FROM}" "$OLLAMA_BIN" list 2>/dev/null | awk '($1!="NAME" && $1!=""){print $1}')"
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
    # Build alias and apply optional prefix
    local alias alias_pref
    alias="$(base_alias "$tag")"
    if [ -n "$ALIAS_PREFIX" ]; then alias_pref="${ALIAS_PREFIX}${alias}"; else alias_pref="$alias"; fi
    out+=("$tag|${alias_pref}")
  done <<<"$names"

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

  if [ "$label" = "optimized" ] && [ "$model" != "$base" ] && awk -v t="$tokps" 'BEGIN{exit !(t+0==0)}'; then
    [ "${KEEP_FAILED_VARIANTS}" -eq 0 ] && rm_variant_tag "$model" || true
  fi

  echo "$tokps"
}

tune_and_bench_one(){ # ep baseTag aliasBase
  local ep="$1" base="$2" alias_base="$3"
  local gpu_lbl; gpu_lbl="$(gpu_label_for_ep "$ep")"

  pull_if_missing "$base"

  if ! curl_tags "$ep" | jq -r '.models[].name' 2>/dev/null | grep -Fxq "$base"; then
    warn "Base ${base} NOT visible on ${ep}. Build happens on :${PERSISTENT_PORT}; benches will run via ${ep}."
  fi

  bench_base_as_is "$ep" "$base" || warn "base-as-is bench skipped for $base on $ep"

  local best_tokps="0.00" best_name="" best_ng="" first_ok=0
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
      local tokps; tokps="$(bench_once "$ep" "$base" "$base" "optimized" "$ng" "$gpu_lbl" || echo 0.00)"
      # Track best and optional early-stop on marginal gain
      if awk -v a="$tokps" -v b="$best_tokps" 'BEGIN{exit !(a>b)}'; then
        best_ng="$ng"; best_tokps="$tokps"; best_name="${alias_base}+ng${ng}"
      fi
      # Mark that at least one optimized run succeeded
      if awk -v a="$tokps" 'BEGIN{exit !(a>0)}'; then first_ok=1; fi
      # stop early if improvement < EARLY_STOP_DELTA over current best
      if [ "$EXHAUSTIVE" -eq 0 ]; then
        # since list is descending from high->low, break after first working
        if awk -v a="$tokps" 'BEGIN{exit !(a>0)}'; then ok "     First working: ng=${ng} at ${tokps} tok/s"; first_ok=1; break; fi
      fi
    else
      local newname="${alias_base}-$(gpu_label_for_ep "$ep")-ng${ng}"
      info " Bake variant ${newname} (FROM ${base} num_gpu=${ng})"
      if ! bake_variant "$newname" "$base" "$ng"; then
        warn "Variant bake failed: ${newname}"
        [ "${KEEP_FAILED_VARIANTS}" -eq 0 ] && rm_variant_tag "${newname}:latest" || true
        continue
      fi
      wait_variant_visible "$ep" "${newname}:latest" 12 || true
      local tokps
      if tokps="$(bench_once "$ep" "$base" "${newname}:latest" "optimized" "$ng" "$gpu_lbl")"; then :; else tokps="0.00"; fi
      if awk -v t="$tokps" 'BEGIN{exit !(t+0==0)}'; then
        [ "${KEEP_FAILED_VARIANTS}" -eq 0 ] && rm_variant_tag "${newname}:latest" || true
      fi
      awk -v a="$tokps" -v b="$best_tokps" 'BEGIN{exit !(a>b)}' && { best_tokps="$tokps"; best_name="$newname"; best_ng="$ng"; }
      # Mark that at least one optimized run succeeded
      if awk -v a="$tokps" 'BEGIN{exit !(a>0)}'; then first_ok=1; fi
      if [ "$EXHAUSTIVE" -eq 0 ] && awk -v a="$tokps" 'BEGIN{exit !(a>0)}'; then
        ok "     First working: ${newname} at ${tokps} tok/s"; first_ok=1; break; fi
    fi
  done

  if awk -v b="$best_tokps" 'BEGIN{exit !(b>0)}'; then
    ok " Best so far: ${best_name} (ng=${best_ng}) at ${best_tokps} tok/s"
  else
    warn " No optimized variant worked for ${base} on ${ep}"
  fi

  # Optionally publish the best variant tag (even when FAST_MODE=1)
  if [ "$PUBLISH_BEST" -eq 1 ] && awk -v b="$best_tokps" 'BEGIN{exit !(b>0)}'; then
    local pub_name
    pub_name="${alias_base}-$(gpu_label_for_ep "$ep")-ng${best_ng}"
    info " Publishing best variant tag: ${pub_name} (FROM ${base} num_gpu=${best_ng})"
    if bake_variant "$pub_name" "$base" "$best_ng"; then
      wait_variant_visible "$ep" "${pub_name}:latest" 12 || true
      ok " Published: ${pub_name}:latest"
      # Re-bench the published tag so CSV contains an explicit row for it
      local pub_tokps
      pub_tokps="$(bench_once "$ep" "$base" "${pub_name}:latest" "published" "$best_ng" "$gpu_lbl" || echo 0.00)"
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
  info "GC created variants: removed=${removed} kept=${kept}"
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
log "Summary    : ${SUMMARY_FILE}"

# ------------------------------------------------------------------------------
# Prepare services (use stock service for :11434; create test A/B here)
# ------------------------------------------------------------------------------
info "Preparing directories and services"
if [ "$IS_ROOT" -eq 1 ]; then
  ensure_service_user || true
  prep_models_dir || true
fi
log "$(gpu_table | sed 's/^/GPU: /')"

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

# Bind A/B to GPUs by name (or index fallback / single-GPU graceful)
all_gpus="$(gpu_table || true)"
uuid_a="$(echo "$all_gpus" | awk -F',' -v s="$MATCH_GPU_A" 'tolower($1) ~ tolower(s){gsub(/[[:space:]]/,"",$2); print $2; exit}')"
uuid_b="$(echo "$all_gpus" | awk -F',' -v s="$MATCH_GPU_B" 'tolower($1) ~ tolower(s){gsub(/[[:space:]]/,"",$2); print $2; exit}')"

if [ -z "${uuid_a:-}" ]; then uuid_a="$(echo "$all_gpus" | awk -F',' 'NR==1{gsub(/[[:space:]]/,"",$2); print $2}')"; fi
if [ -z "${uuid_b:-}" ] || [ "$uuid_a" = "$uuid_b" ]; then
  # try second GPU; if none, we will only run A
  uuid_b="$(echo "$all_gpus" | awk -F',' 'NR==2{gsub(/[[:space:]]/,"",$2); print $2}')"
fi

# Build endpoints array dynamically (single-GPU friendly)
ENDPOINTS=()
if [ "$SKIP_TEST_UNITS" -eq 1 ]; then
  ENDPOINTS+=("127.0.0.1:${PERSISTENT_PORT}")
else
  if [ -n "${uuid_a:-}" ]; then
    if [ "${CLEAN_START_TESTS}" -eq 1 ]; then stop_unit ollama-test-a.service; fi
    write_unit "ollama-test-a.service" "$TEST_PORT_A" "$uuid_a" "Ollama (TEST A on :${TEST_PORT_A})"
    systemctl daemon-reload || true
    systemctl enable --now ollama-test-a.service || true
    ENDPOINTS+=("127.0.0.1:${TEST_PORT_A}")
  fi
  if [ -n "${uuid_b:-}" ]; then
    if [ "${CLEAN_START_TESTS}" -eq 1 ]; then stop_unit ollama-test-b.service; fi
    write_unit "ollama-test-b.service" "$TEST_PORT_B" "$uuid_b" "Ollama (TEST B on :${TEST_PORT_B})"
    systemctl daemon-reload || true
    systemctl enable --now ollama-test-b.service || true
    ENDPOINTS+=("127.0.0.1:${TEST_PORT_B}")
  fi
fi

info "TEST A OLLAMA_MODELS: $(service_env ollama-test-a.service OLLAMA_MODELS || true)"
info "TEST B OLLAMA_MODELS: $(service_env ollama-test-b.service OLLAMA_MODELS || true)"

info "Waiting for APIs"
wait_api "127.0.0.1:${PERSISTENT_PORT}" || warn "API :${PERSISTENT_PORT} not reachable yet"
for ep in "${ENDPOINTS[@]}"; do wait_api "$ep" || warn "API $ep slow to start"; done

info "ollama version: $($OLLAMA_BIN --version || echo 'unknown')"

# ------------------------------------------------------------------------------
# Discover base models & run
# ------------------------------------------------------------------------------
MODELS=()
discover_models
if [ "${#MODELS[@]}" -eq 0 ]; then
  warn "Nothing to do (no base models)."
fi

# Make sure test endpoints are freshly restarted (skip if using persistent only)
if [ "$SKIP_TEST_UNITS" -eq 0 ]; then
  for ep in "${ENDPOINTS[@]}"; do
    restart_ep "$ep" || true
    wait_api "$ep" || warn "API $ep is not up yet (continuing)"
  done
fi

for m in "${MODELS[@]}"; do
  base="${m%%|*}"; alias_base="${m##*|}"
  for ep in "${ENDPOINTS[@]}"; do
    log "=== Tuning on ${ep} — base: ${base} (alias ${alias_base}) ==="
    tune_and_bench_one "$ep" "$base" "$alias_base"
  done
done

gc_created_tags || true

# ------------------------------------------------------------------------------
# Build per-(endpoint,base_model) best optimized list (tokens_per_sec > 0)
# ------------------------------------------------------------------------------
awk -F',' '
  NR>1 && $6=="optimized" && $12+0>0 {
    k=$2"|" $5
    if ($12+0>best[k]) {best[k]=$12+0; n[k]=$7; ng[k]=$8}
  }
  END{
    f=ENVIRON["SUMMARY_FILE"] ".raw"
    print "endpoint,base_model,best_variant,num_gpu,tokens_per_sec" > f
    for (k in best){
      split(k,a,"|")
      printf "%s,%s,%s,%s,%.2f\n",a[1],a[2],n[k],ng[k],best[k] >> f
    }
  }
' SUMMARY_FILE="$SUMMARY_FILE" "$CSV_FILE"

# ------------------------------------------------------------------------------
# Final summary
# ------------------------------------------------------------------------------
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

  # CPU-bound abandon logic removed; failures are handled via tok/s==0

  echo
  echo "=== Base vs Optimized (per endpoint & model) ==="
  awk -F',' '
    NR==1{next}
    {
      key=$2"|" $5
      if ($6=="base-as-is"){base[key]=$12+0}
      else if ($6=="optimized"){ if ($12+0>opt[key]){opt[key]=$12+0; optname[key]=$7} }
    }
    END{
      printf "%-21s %-28s %10s %10s %8s %s\n","endpoint","model","base_t/s","opt_t/s","x","best_variant"
      for (k in base){
        be=base[k]+0; op=opt[k]+0
        split(k,a,"|")
        mult=(be>0? op/be : 0)
        printf "%-21s %-28s %10.2f %10.2f %8.2fx %s\n", a[1],a[2],be,op,(be>0?mult:0),optname[k]
      }
    }
  ' "$CSV_FILE"
} | tee "${SUMMARY_FILE}.txt" >/dev/null

ok "Done."
