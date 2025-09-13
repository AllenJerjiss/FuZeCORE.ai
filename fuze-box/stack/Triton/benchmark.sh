#!/usr/bin/env bash
# triton-benchmark.sh
# Baseline Triton perf using perf_analyzer if available.
# - Assumes a running tritonserver on HTTP :8000 (A) and :8001 (B) (override via env)
# - Uses perf_analyzer to get throughput (infer/sec); we record it as tokens/sec baseline
# - Same CSV header/summary format as other stacks
#
# Env knobs for cross-stack parity (used for CSV only):
#   BENCH_NUM_CTX       -> CSV num_ctx column (no effect on perf_analyzer)
#   BENCH_NUM_PREDICT   -> CSV num_predict column (no effect on perf_analyzer)
#   TEMPERATURE         -> accepted for parity; not reflected in CSV

set -euo pipefail

########## PATH ROOTS ##########################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${LOG_DIR:-/var/log/fuze-stack}"
# Ensure writable log dir; fall back to per-user location if repo logs are not writable
if ! mkdir -p "$LOG_DIR" 2>/dev/null || [ ! -w "$LOG_DIR" ]; then
  LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/fuze-stack/logs"
  mkdir -p "$LOG_DIR" 2>/dev/null || { LOG_DIR="$HOME/.fuze/stack/logs"; mkdir -p "$LOG_DIR"; }
fi

## Debug capture setup moved below to reuse the same TS as CSV

########## CONFIG (override with env) ##########################################
TRITON_HTTP_A="${TRITON_HTTP_A:-127.0.0.1:8000}"
TRITON_HTTP_B="${TRITON_HTTP_B:-127.0.0.1:8001}"

# Models to test (Triton model repository names)
# Override or export TRITON_MODELS=(name1|alias1 name2|alias2 ...)
TRITON_MODELS=(${TRITON_MODELS:-"llama|llama4-16x17b" "deepseek|deepseek-r1-70b" "llama-128|llama4-128x17b"})

# perf_analyzer params
CONCURRENCY="${CONCURRENCY:-1}"
BATCH="${BATCH:-1}"
REQUEST_COUNT="${REQUEST_COUNT:-200}"   # perf window in requests; increase for stability
TIMEOUT_SECS="${TIMEOUT_SECS:-60}"

VERBOSE="${VERBOSE:-1}"
# Cross-stack parity knobs (CSV only; Triton perf_analyzer not affected)
BENCH_NUM_CTX="${BENCH_NUM_CTX:-}"
BENCH_NUM_PREDICT="${BENCH_NUM_PREDICT:-}"
TEMPERATURE="${TEMPERATURE:-}"

########## OUTPUT ##############################################################
HOSTNAME_NOW="$(hostname -s 2>/dev/null || hostname)"
TS="$(date +%Y%m%d_%H%M%S)"
CSV_FILE="${LOG_DIR}/triton_bench_${TS}.csv"
SUMMARY_FILE="${LOG_DIR}/${HOSTNAME_NOW}-${TS}.benchmark"

# Debug capture (reuse CSV TS for correlation)
DEBUG_BENCH="${DEBUG_BENCH:-0}"
DEBUG_DIR="${LOG_DIR}/debug_${TS}"
[ "$DEBUG_BENCH" -eq 1 ] && mkdir -p "$DEBUG_DIR" || true

########## UTILS ###############################################################
c_bold="\033[1m"; c_red="\033[31m"; c_green="\033[32m"; c_yellow="\033[33m"; c_reset="\033[0m"
log(){ echo -e "$*"; }
info(){ [ "${VERBOSE}" -ne 0 ] && echo -e "${c_bold}==${c_reset} $*"; }
ok(){ echo -e "${c_green}✔${c_reset} $*"; }
warn(){ echo -e "${c_yellow}!${c_reset} $*"; }
err(){ echo -e "${c_red}✖${c_reset} $*" >&2; }

need(){ command -v "$1" >/dev/null 2>&1 || { err "Missing dependency: $1"; exit 1; }; }
need curl; need awk; need sed

perf_bin="$(command -v perf_analyzer || true)"
if [ -z "$perf_bin" ]; then
  warn "perf_analyzer not found. Please install Triton SDK tools; will still write CSV with 0.00 results."
fi

wait_ready(){ # host:port
  local hp="$1" t=0
  while [ "$t" -lt 30 ]; do
    curl -fsS "http://${hp}/v2/health/ready" >/dev/null 2>&1 && return 0
    sleep 1; t=$((t+1))
  done
  return 1
}

bench_once(){ # endpoint alias base_tag model_name
  local ep="$1" alias="$2" base="$3" model="$4"
  local sfx="X"; [ "${ep##*:}" = "${TRITON_HTTP_A##*:}" ] && sfx="A"; [ "${ep##*:}" = "${TRITON_HTTP_B##*:}" ] && sfx="B"

  local tokps="0.00"
  local dbg_base
  if [ "$DEBUG_BENCH" -eq 1 ]; then
    dbg_base="${DEBUG_DIR}/triton_${sfx}_$(echo "$base" | sed 's#[/:]#-#g')_${model}"
  fi
  if [ -n "$perf_bin" ]; then
    # Use perf_analyzer throughput (infer/sec) as a proxy for tokens/sec baseline
    # Note: For LLMs you might feed proper JSON/shape configs; this is a generic baseline.
    local out
    out="$("$perf_bin" -m "$model" -u "$ep" -i HTTP \
            --concurrency-range "$CONCURRENCY" \
            -b "$BATCH" --request-interval-us 0 \
            -p "$REQUEST_COUNT" -v 0 2>/dev/null || true)"
    local tput
    tput="$(echo "$out" | awk '/Throughput:/ {print $2}' | tail -n1)"
    if [[ "$tput" =~ ^[0-9.]+$ ]]; then
      tokps="$(awk -v x="$tput" 'BEGIN{printf "%.2f", x}')"
    fi
    if [ "$DEBUG_BENCH" -eq 1 ]; then
      echo "$out" > "${dbg_base}.perf.txt"
      printf '{"throughput":%s,"tokens_per_sec":%s,"endpoint":"%s","model":"%s"}\n' \
        "${tput:-0}" "$tokps" "$ep" "$model" > "${dbg_base}.metrics.json" || true
    fi
  fi

  # We don’t have GPU binding info here; leave gpu_label empty and num_gpu as 'default'
  # Map parity knobs into CSV columns where applicable
  local csv_num_ctx="${BENCH_NUM_CTX:-NA}"
  local csv_num_pred="${BENCH_NUM_PREDICT:-NA}"
  echo "$(date -Iseconds),$ep,proc,$sfx,$base,base-as-is,$model,default,${csv_num_ctx},$BATCH,${csv_num_pred},$tokps,,,,," >>"$CSV_FILE"
  ok "[bench] ${sfx}  ${model}  ->  ${tokps} (perf_analyzer throughput)"
}

##################################### MAIN #####################################
echo "ts,endpoint,unit,suffix,base_model,variant_label,model_tag,num_gpu,num_ctx,batch,num_predict,tokens_per_sec,gpu_label,gpu_name,gpu_uuid,gpu_mem_mib" >"$CSV_FILE"

echo -e "${c_bold}== Triton perf ==${c_reset}"
echo "Endpoints  : A=${TRITON_HTTP_A}  B=${TRITON_HTTP_B}"
echo "CSV        : $CSV_FILE"
echo

for pair in "${TRITON_MODELS[@]}"; do
  name="${pair%%|*}"
  alias_base="${pair#*|}"

  if wait_ready "$TRITON_HTTP_A"; then
    bench_once "$TRITON_HTTP_A" "$alias_base" "$alias_base" "$name" || true
  else
    warn "A not ready: $TRITON_HTTP_A"
  fi
  if wait_ready "$TRITON_HTTP_B"; then
    bench_once "$TRITON_HTTP_B" "$alias_base" "$alias_base" "$name" || true
  else
    warn "B not ready: $TRITON_HTTP_B"
  fi
done

echo "Analyze    : ./fuze-box/stack/common/analyze.sh --stack Triton"

ok "DONE. CSV: ${CSV_FILE}"
