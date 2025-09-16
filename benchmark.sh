#!/usr/bin/env bash
# benchmark.sh — Orchestrate install → cleanup → benchmark → export → analyze across stacks and models
# - Discovers model env files in LLM/refinery/stack/*.env by default
# - Runs all stacks by default: ollama, llama.cpp, vLLM, Triton (if present)
# - Flags:
#     --stack "ollama llama.cpp ..."    limit to these stacks (space/comma separated)
#     --model REGEX                     select env files whose name matches REGEX (repeatable)
#     -h|--help                         usage

set -euo pipefail

# Elevate to root early; preserve env
if [ "$(id -u)" -ne 0 ]; then exec sudo -E "$0" "$@"; fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UST="${ROOT_DIR}/factory/LLM/refinery/stack/ust.sh"

# Pick a writable LOG_DIR
TS="$(date +%Y%m%d_%H%M%S)"
LOG_DIR_CANDIDATE="${LOG_DIR:-/var/log/fuze-stack}"
choose_log_dir(){
  local candidates=("$LOG_DIR_CANDIDATE" "${XDG_STATE_HOME:-$HOME/.local/state}/fuze-stack" "$HOME/.fuze/stack/logs")
  for d in "${candidates[@]}"; do
    mkdir -p "$d" 2>/dev/null || continue
    touch "$d/.wtest" 2>/dev/null && rm -f "$d/.wtest" && LOG_DIR="$d" && return 0
  done
  LOG_DIR="$ROOT_DIR"
}
choose_log_dir

# Structured logs
RUN_LOG="${LOG_DIR}/wrapper_${TS}.log"
TRACE_LOG="${LOG_DIR}/wrapper_${TS}.trace"
SUMMARY="${LOG_DIR}/wrapper_${TS}.summary"

# UI helpers
c_bold="\033[1m"; c_red="\033[31m"; c_green="\033[32m"; c_yellow="\033[33m"; c_reset="\033[0m"
log(){ echo -e "$*"; }
info(){ echo -e "${c_bold}==${c_reset} $*"; }
ok(){ echo -e "${c_green}✔${c_reset} $*"; }
warn(){ echo -e "${c_yellow}!${c_reset} $*"; }
err(){ echo -e "${c_red}✖${c_reset} $*" >&2; }

step_begin(){ STEP_NAME="$1"; STEP_TS=$(date +%s); info "[${STEP_NAME}]"; }
step_end(){ local rc=$1; local dur=$(( $(date +%s) - STEP_TS ));
  if [ "$rc" -eq 0 ]; then ok "[$STEP_NAME] done (${dur}s)"; else err "[$STEP_NAME] rc=$rc (${dur}s)"; fi
  printf "%s,%s,%s,%s\n" "${TS}" "${STEP_NAME}" "$rc" "$dur" >> "$SUMMARY" || true
}

mkdir -p "$LOG_DIR" || true
echo "ts,step,rc,seconds" > "$SUMMARY" 2>/dev/null || true

# Tee stdout/stderr to logfile
exec > >(stdbuf -oL tee -a "$RUN_LOG") 2>&1
# Xtrace to separate file
PS4='+ [$EPOCHREALTIME] ${BASH_SOURCE##*/}:${LINENO}:${FUNCNAME[0]:-main}() '
exec 9>>"$TRACE_LOG"; BASH_XTRACEFD=9; set -x
set -E -o functrace; trap 'rc=$?; echo "ERR rc=$rc at ${BASH_SOURCE##*/}:${LINENO}"' ERR

usage(){
  cat <<USAGE
Usage: $(basename "$0") [--stack "ollama llama.cpp vLLM Triton"] [--model REGEX]... [--env explore|preprod|prod] [--combined gpu0,gpu1] [--debug] [stacks...]
Runs all stacks on all model env files by default.
You may also pass stack names positionally at the end (e.g., 'ollama').
--combined: Run models across multiple GPUs in parallel (e.g., gpu0,gpu2 or gpu1) - enables multi-GPU model splitting
USAGE
}

STACKS=()
MODEL_RES=()
ENV_MODE=""
DEBUG_RUN=0
COMBINED_GPUS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --stack) shift; IFS=', ' read -r -a arr <<<"${1:-}"; for x in "${arr[@]}"; do [ -n "$x" ] && STACKS+=("$x"); done; shift||true;;
    --model) MODEL_RES+=("$2"); shift 2;;
    --env) ENV_MODE="$2"; shift 2;;
    --combined) COMBINED_GPUS="$2"; shift 2;;
    --debug) DEBUG_RUN=1; shift 1;;
    -h|--help) usage; exit 0;;
    *)
      case "$1" in
        ollama|Ollama|llama.cpp|llamacpp|llama-cpp|vLLM|VLLM|Triton|triton)
          STACKS+=("$1"); shift;;
        *) warn "Unknown arg: $1"; shift;;
      esac
      ;;
  esac
done

# Process --combined GPUs
if [ -n "$COMBINED_GPUS" ]; then
  CUDA_GPUS=$(echo "$COMBINED_GPUS" | sed 's/gpu//g')
  export CUDA_VISIBLE_DEVICES="$CUDA_GPUS"
  # Enable Ollama multi-GPU spreading across all specified GPUs
  export OLLAMA_SCHED_SPREAD=1
  info "Multi-GPU mode enabled: GPUs $CUDA_GPUS (CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES, OLLAMA_SCHED_SPREAD=1)"
fi

[ -x "$UST" ] || { err "ust.sh not found: $UST"; exit 2; }
# Default to quiet, only enable verbose+debug when --debug is provided
if [ "$DEBUG_RUN" -eq 1 ]; then
  export VERBOSE=1 DEBUG_BENCH=1
else
  export VERBOSE=0 DEBUG_BENCH=0
fi

info "Wrapper start @ ${TS} (logs: ${LOG_DIR})"

# Print locations of best CSVs and where run CSVs will be written
log "Best-per-(stack,model) CSV: ${ROOT_DIR}/factory/LLM/refinery/benchmarks.best.csv"
log "Best-by-(host,model) CSV: ${ROOT_DIR}/factory/LLM/refinery/benchmarks.best.by_host_model.csv"
log "Best-global-by-model CSV: ${ROOT_DIR}/factory/LLM/refinery/benchmarks.best.by_model.csv"
log "CSVs in : ${LOG_DIR}"

# Discover stacks if none provided
if [ ${#STACKS[@]} -eq 0 ]; then
  for s in ollama llama.cpp vLLM Triton; do [ -d "${ROOT_DIR}/factory/LLM/refinery/stack/${s}" ] && STACKS+=("$s"); done
fi

# Dynamic environment file generation for --combined mode
generate_dynamic_env(){
  local model_pattern="$1" gpu_config="$2" env_mode="${3:-explore}"
  local timestamp="$(date +%Y%m%d_%H%M%S)"
  local gpu_suffix="$(echo "$gpu_config" | sed 's/gpu//g')"
  
  # Create dynamic env filename
  local env_name="LLM-FuZe-${model_pattern}-multi-gpu${gpu_suffix}-${timestamp}.env"
  local env_path="${LOG_DIR}/${env_name}"
  
  # Generate environment file content
  cat > "$env_path" <<EOF
# Dynamic multi-GPU environment file generated $(date)
# GPU Configuration: $gpu_config
# CUDA_VISIBLE_DEVICES: $CUDA_VISIBLE_DEVICES
# OLLAMA_SCHED_SPREAD: $OLLAMA_SCHED_SPREAD

# Logs
LOG_DIR=$LOG_DIR

# Naming
ALIAS_PREFIX=LLM-FuZe-
ALIAS_SUFFIX=-${env_mode}

# Scope to one model tag
INCLUDE_MODELS='^${model_pattern//[-]/[-]}$'

# Multi-GPU specific configuration
CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES
OLLAMA_SCHED_SPREAD=1

# Bench behavior (aggressive for multi-GPU)
FAST_MODE=1            # no tag baking during search; pass options at runtime
EXHAUSTIVE=1           # try all candidates for broader coverage
BENCH_NUM_PREDICT=128
BENCH_NUM_CTX=4096
TEMPERATURE=0.0
TIMEOUT_GEN=300        # allow extra time for first gen
VERBOSE=${VERBOSE:-1}

# Debugging / publishing (aggressive)
DEBUG_BENCH=${DEBUG_BENCH:-1}      # capture request/response/metrics, probe, journal on 0 t/s
PUBLISH_BEST=1         # bake the best variant tag after the run

# Ollama service handling
CLEAN_START_TESTS=1
SKIP_TEST_UNITS=0
KEEP_FAILED_VARIANTS=1 # keep any baked tags for inspection (not used in FAST_MODE)
GC_AFTER_RUN=0         # do not GC created tags automatically

# Candidate sweep control (aggressive for multi-GPU)
NG_PERCENT_SET="100 95 90 85 80 75 70 65 60 55 50 45 40 35 30 25 20 15 10"
EOF

  echo "$env_path"
}

# Prepare env files per requested environment and discover .env files
ENV_BASE="${ROOT_DIR}/factory/LLM/refinery/stack/env"
EXPL_DIR="${ENV_BASE}/explore"; PRE_DIR="${ENV_BASE}/preprod"; PROD_DIR="${ENV_BASE}/prod"
mkdir -p "$EXPL_DIR" "$PRE_DIR" "$PROD_DIR"

case "${ENV_MODE:-}" in
  preprod)
    step_begin "env-prepare:preprod"; rc=0;
    GEN_ARGS=("--dest" "$PRE_DIR" "--template" "${ENV_BASE}/templates/LLM-FuZe-preprod.env.template")
    [ ${#MODEL_RES[@]} -gt 0 ] && GEN_ARGS+=("--include" "$(IFS='|'; echo "${MODEL_RES[*]}")") || true
    "${ENV_BASE}/generate-envs.sh" "${GEN_ARGS[@]}" || rc=$?
    [ -n "${SUDO_USER:-}" ] && chown -R "$SUDO_USER":"$SUDO_USER" "$PRE_DIR" 2>/dev/null || true
    step_end $rc
    ENV_ROOT="$PRE_DIR"
    ;;
  explore)
    step_begin "env-prepare:explore"; rc=0;
    GEN_ARGS=("--dest" "$EXPL_DIR" "--template" "${ENV_BASE}/templates/LLM-FuZe-explore.env.template")
    [ ${#MODEL_RES[@]} -gt 0 ] && GEN_ARGS+=("--include" "$(IFS='|'; echo "${MODEL_RES[*]}")") || true
    "${ENV_BASE}/generate-envs.sh" "${GEN_ARGS[@]}" || rc=$?
    [ -n "${SUDO_USER:-}" ] && chown -R "$SUDO_USER":"$SUDO_USER" "$EXPL_DIR" 2>/dev/null || true
    step_end $rc
    ENV_ROOT="$EXPL_DIR"
    ;;
  prod)
    step_begin "env-prepare:prod"; rc=0;
    shopt -s nullglob
    for f in "$PRE_DIR"/*.env; do cp -f "$f" "$PROD_DIR/" || rc=$?; done
    shopt -u nullglob
    [ -n "${SUDO_USER:-}" ] && chown -R "$SUDO_USER":"$SUDO_USER" "$PROD_DIR" 2>/dev/null || true
    step_end $rc
    ENV_ROOT="$PROD_DIR"
    ;;
  *)
    ENV_ROOT="$ENV_BASE"
    ;;
esac

ENV_FILES=()

# Handle --combined mode with dynamic environment generation
if [ -n "$COMBINED_GPUS" ]; then
  # For combined mode, generate dynamic environment files for each model pattern
  if [ ${#MODEL_RES[@]} -eq 0 ]; then
    err "Combined mode requires --model pattern to specify which models to run"; exit 2
  fi
  
  for model_pattern in "${MODEL_RES[@]}"; do
    env_file="$(generate_dynamic_env "$model_pattern" "$COMBINED_GPUS" "${ENV_MODE:-explore}")"
    ENV_FILES+=("$env_file")
  done
  
  info "Generated ${#ENV_FILES[@]} dynamic environment files for combined GPU mode"
else
  # Original static environment file discovery
  if [ -d "$ENV_ROOT" ]; then
    while IFS= read -r -d '' f; do ENV_FILES+=("$f"); done < <(find "$ENV_ROOT" -type f -name "*.env" -print0 2>/dev/null)
  else
    shopt -s nullglob
    for f in "${ROOT_DIR}/factory/LLM/refinery/stack"/*.env; do ENV_FILES+=("$f"); done
    shopt -u nullglob
  fi
  
  if [ ${#MODEL_RES[@]} -eq 0 ]; then
    : # Already discovered via find; nothing to do
  else
    FILTERED=()
    for e in "${ENV_FILES[@]}"; do
      [ -f "$e" ] || continue
      bn="$(basename "$e")"
      keep=0
      for re in "${MODEL_RES[@]}"; do
        # Match by filename OR by the embedded INCLUDE_MODELS tag in the env file
        if echo "$bn" | grep -Eq "$re"; then keep=1; break; fi
        inc_tag="$(awk -F"'" '/^INCLUDE_MODELS=/{print $2; exit}' "$e" 2>/dev/null | sed -E 's/^\^//; s/\$$//')"
        if [ -n "$inc_tag" ] && echo "$inc_tag" | grep -Eq "$re"; then keep=1; break; fi
      done
      [ "$keep" -eq 1 ] && FILTERED+=("$e")
    done
    if [ ${#FILTERED[@]} -gt 0 ]; then
      ENV_FILES=("${FILTERED[@]}")
    else
      ENV_FILES=()
    fi
  fi
fi

if [ ${#ENV_FILES[@]} -eq 0 ]; then err "No env files matched. Use --env explore|preprod|prod or add .env files under factory/LLM/refinery/stack/env/*"; exit 2; fi

preflight(){ step_begin "preflight"; rc=0; "$UST" preflight >/dev/null 2>&1 || rc=$?; step_end $rc; }
preflight

run_stack_env(){ # stack env_file
  local S="$1" ENVF="$2" envbase; envbase="$(basename "$ENVF")"
  local EA=("@${ENVF}")
  case "$S" in
    ollama|Ollama)
      # Skip install if ollama is already present unless forced
      if [ "${FORCE_OLLAMA_INSTALL:-0}" -eq 1 ] || ! command -v ollama >/dev/null 2>&1; then
        step_begin "${S}:${envbase}:install"; rc=0; "$UST" "${EA[@]}" ollama install || rc=$?; step_end $rc
      else
        info "${S}:${envbase}:install — skipped (ollama present). Set FORCE_OLLAMA_INSTALL=1 to force."
      fi
      step_begin "${S}:${envbase}:service-cleanup"; rc=0; "$UST" "${EA[@]}" ollama service-cleanup || rc=$?; step_end $rc
      # Do NOT remove previously generated variants during the wrapper flow.
      # If explicit cleanup is desired, set VARIANT_CLEANUP=1.
      if [ "${VARIANT_CLEANUP:-0}" -eq 1 ]; then
        step_begin "${S}:${envbase}:cleanup-variants"; rc=0; "$UST" "${EA[@]}" ollama cleanup-variants --force --yes || rc=$?; step_end $rc
      else
        info "${S}:${envbase}:cleanup-variants — skipped (preserving existing variants). Set VARIANT_CLEANUP=1 to allow."
      fi
      step_begin "${S}:${envbase}:benchmark"; rc=0; "$UST" "${EA[@]}" ollama benchmark || rc=$?; step_end $rc
      # Optional GGUF cleanup to avoid stale artifacts (set GGUF_CLEAN=1)
      if [ "${GGUF_CLEAN:-0}" -eq 1 ]; then
        dest_dir="${GGUF_DEST_DIR:-/FuZe/models/gguf}"
        info "${S}:${envbase}:gguf-clean — removing old *.gguf in ${dest_dir}"
        rm -f "${dest_dir}"/*.gguf 2>/dev/null || true
      fi
      step_begin "${S}:${envbase}:export-gguf"; rc=0;
      EXP_ARGS=( )
      [ "${EXPORT_OVERWRITE:-0}" -eq 1 ] && EXP_ARGS+=("--overwrite") || true
      "$UST" "${EA[@]}" ollama export-gguf ${EXP_ARGS[@]} || rc=$?
      step_end $rc
      if [ "${SKIP_INLINE_ANALYZE:-1}" -eq 0 ]; then
        step_begin "${S}:${envbase}:analyze"; rc=0; "$UST" "${EA[@]}" analyze --stack ollama || rc=$?; step_end $rc
      else
        info "${S}:${envbase}:analyze — skipped (shown in final wrapper step)"
      fi;;
    llama.cpp|llamacpp|llama-cpp)
      step_begin "${S}:${envbase}:install"; rc=0; "$UST" "${EA[@]}" llama.cpp install || rc=$?; step_end $rc
      step_begin "${S}:${envbase}:benchmark"; rc=0; "$UST" "${EA[@]}" llama.cpp benchmark || rc=$?; step_end $rc
      if [ "${SKIP_INLINE_ANALYZE:-1}" -eq 0 ]; then
        step_begin "${S}:${envbase}:analyze"; rc=0; "$UST" "${EA[@]}" analyze --stack llama.cpp || rc=$?; step_end $rc
      else
        info "${S}:${envbase}:analyze — skipped (shown in final wrapper step)"
      fi;;
    vllm|vLLM|VLLM)
      step_begin "${S}:${envbase}:install"; rc=0; "$UST" "${EA[@]}" vLLM install || rc=$?; step_end $rc
      step_begin "${S}:${envbase}:benchmark"; rc=0; "$UST" "${EA[@]}" vLLM benchmark || rc=$?; step_end $rc
      if [ "${SKIP_INLINE_ANALYZE:-1}" -eq 0 ]; then
        step_begin "${S}:${envbase}:analyze"; rc=0; "$UST" "${EA[@]}" analyze --stack vLLM || rc=$?; step_end $rc
      else
        info "${S}:${envbase}:analyze — skipped (shown in final wrapper step)"
      fi;;
    Triton|triton)
      step_begin "${S}:${envbase}:install"; rc=0; "$UST" "${EA[@]}" Triton install || rc=$?; step_end $rc
      step_begin "${S}:${envbase}:benchmark"; rc=0; "$UST" "${EA[@]}" Triton benchmark || rc=$?; step_end $rc
      if [ "${SKIP_INLINE_ANALYZE:-1}" -eq 0 ]; then
        step_begin "${S}:${envbase}:analyze"; rc=0; "$UST" "${EA[@]}" analyze --stack Triton || rc=$?; step_end $rc
      else
        info "${S}:${envbase}:analyze — skipped (shown in final wrapper step)"
      fi;;
    *) warn "Unknown stack: $S" ;;
  esac
}

for ENVF in "${ENV_FILES[@]}"; do
  info "ENV: $(basename "$ENVF")"
  for S in "${STACKS[@]}"; do run_stack_env "$S" "$ENVF"; done
done

# One-time migration: backfill aggregate CSV from all historical logs if missing/empty
AGG_CSV="${ROOT_DIR}/factory/LLM/refinery/benchmarks.csv"
if [ ! -s "$AGG_CSV" ] || [ "$(wc -l < "$AGG_CSV" 2>/dev/null || echo 0)" -le 1 ]; then
  step_begin "migrate-aggregate"; rc=0; "${ROOT_DIR}/factory/LLM/refinery/stack/common/collect-results.sh" --log-dir "$LOG_DIR" --stacks "${STACKS[*]}" --all || rc=$?; step_end $rc
fi

# Collect latest + summarize
step_begin "collect"; rc=0; "${ROOT_DIR}/factory/LLM/refinery/stack/common/collect-results.sh" --log-dir "$LOG_DIR" --stacks "${STACKS[*]}" >/dev/null || rc=$?; step_end $rc

## Reflect env mode in alias suffix for final summaries
case "${ENV_MODE:-}" in
  explore) SUMMARY_ALIAS_SUFFIX="-explore" ;;
  preprod) SUMMARY_ALIAS_SUFFIX="-preprod" ;;
  prod)    SUMMARY_ALIAS_SUFFIX="-prod" ;;
  *)       SUMMARY_ALIAS_SUFFIX="${ALIAS_SUFFIX:-}" ;;
esac

# Print: Top overall (quiet, no path footers). Pass suffix to embed in variants
ALIAS_SUFFIX="${SUMMARY_ALIAS_SUFFIX}" \
"${ROOT_DIR}/factory/LLM/refinery/stack/common/summarize-benchmarks.sh" \
  --csv "${ROOT_DIR}/factory/LLM/refinery/benchmarks.csv" \
  | tee -a "${LOG_DIR}/wrapper_best_${TS}.txt"

# Final: unified results combining historical and current run data
LATEST_CSV="$(ls -t ${LOG_DIR}/*_bench_*.csv 2>/dev/null | head -n1 || true)"
if [ -n "$LATEST_CSV" ]; then
  log "Including current run results from: $(basename "$LATEST_CSV")"
  "${ROOT_DIR}/factory/LLM/refinery/stack/common/summarize-benchmarks.sh" \
    --csv "${ROOT_DIR}/factory/LLM/refinery/benchmarks.csv" \
    --current-csv "$LATEST_CSV" \
    --top 10 \
    | tee -a "${LOG_DIR}/wrapper_unified_${TS}.txt"
else
  log "No current run CSV found, showing historical results only"
  "${ROOT_DIR}/factory/LLM/refinery/stack/common/summarize-benchmarks.sh" \
    --csv "${ROOT_DIR}/factory/LLM/refinery/benchmarks.csv" \
    --top 10 \
    | tee -a "${LOG_DIR}/wrapper_unified_${TS}.txt"
fi

# Mark wrapper completion after printing unified analysis
ok "Wrapper complete. Summary: $SUMMARY"
