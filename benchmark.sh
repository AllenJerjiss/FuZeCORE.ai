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
UST="${ROOT_DIR}/LLM/refinery/stack/ust.sh"

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
Usage: $(basename "$0") [--stack "ollama llama.cpp vLLM Triton"] [--model REGEX]...
Runs all stacks on all model env files by default.
USAGE
}

STACKS=()
MODEL_RES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --stack) shift; IFS=', ' read -r -a arr <<<"${1:-}"; for x in "${arr[@]}"; do [ -n "$x" ] && STACKS+=("$x"); done; shift||true;;
    --model) MODEL_RES+=("$2"); shift 2;;
    -h|--help) usage; exit 0;;
    *) warn "Unknown arg: $1"; shift;;
  esac
done

[ -x "$UST" ] || { err "ust.sh not found: $UST"; exit 2; }
export VERBOSE=1 DEBUG_BENCH=1

info "Wrapper start @ ${TS} (logs: ${LOG_DIR})"

# Discover stacks if none provided
if [ ${#STACKS[@]} -eq 0 ]; then
  for s in ollama llama.cpp vLLM Triton; do [ -d "${ROOT_DIR}/LLM/refinery/stack/${s}" ] && STACKS+=("$s"); done
fi

# Discover env files if no model filter provided
ALL_ENVS=("${ROOT_DIR}/LLM/refinery/stack"/*.env)
ENV_FILES=()
if [ ${#MODEL_RES[@]} -eq 0 ]; then
  for e in "${ALL_ENVS[@]}"; do [ -f "$e" ] && ENV_FILES+=("$e"); done
else
  for e in "${ALL_ENVS[@]}"; do
    [ -f "$e" ] || continue
    bn="$(basename "$e")"
    keep=0
    for re in "${MODEL_RES[@]}"; do echo "$bn" | grep -Eq "$re" && { keep=1; break; }; done
    [ "$keep" -eq 1 ] && ENV_FILES+=("$e")
  done
fi
if [ ${#ENV_FILES[@]} -eq 0 ]; then err "No env files matched. Add .env under LLM/refinery/stack or adjust --model"; exit 2; fi

preflight(){ step_begin "preflight"; rc=0; "$UST" preflight >/dev/null 2>&1 || rc=$?; step_end $rc; }
preflight

run_stack_env(){ # stack env_file
  local S="$1" ENVF="$2" envbase; envbase="$(basename "$ENVF")"
  local EA=("@${ENVF}")
  case "$S" in
    ollama|Ollama)
      step_begin "${S}:${envbase}:install"; rc=0; "$UST" "${EA[@]}" ollama install || rc=$?; step_end $rc
      step_begin "${S}:${envbase}:service-cleanup"; rc=0; "$UST" "${EA[@]}" ollama service-cleanup || rc=$?; step_end $rc
      step_begin "${S}:${envbase}:cleanup-variants"; rc=0; "$UST" "${EA[@]}" ollama cleanup-variants --force --yes || rc=$?; step_end $rc
      step_begin "${S}:${envbase}:benchmark"; rc=0; "$UST" "${EA[@]}" ollama benchmark || rc=$?; step_end $rc
      step_begin "${S}:${envbase}:export-gguf"; rc=0; "$UST" "${EA[@]}" ollama export-gguf || rc=$?; step_end $rc
      step_begin "${S}:${envbase}:analyze"; rc=0; "$UST" "${EA[@]}" analyze --stack ollama || rc=$?; step_end $rc;;
    llama.cpp|llamacpp|llama-cpp)
      step_begin "${S}:${envbase}:install"; rc=0; "$UST" "${EA[@]}" llama.cpp install || rc=$?; step_end $rc
      step_begin "${S}:${envbase}:benchmark"; rc=0; "$UST" "${EA[@]}" llama.cpp benchmark || rc=$?; step_end $rc
      step_begin "${S}:${envbase}:analyze"; rc=0; "$UST" "${EA[@]}" analyze --stack llama.cpp || rc=$?; step_end $rc;;
    vllm|vLLM|VLLM)
      step_begin "${S}:${envbase}:install"; rc=0; "$UST" "${EA[@]}" vLLM install || rc=$?; step_end $rc
      step_begin "${S}:${envbase}:benchmark"; rc=0; "$UST" "${EA[@]}" vLLM benchmark || rc=$?; step_end $rc
      step_begin "${S}:${envbase}:analyze"; rc=0; "$UST" "${EA[@]}" analyze --stack vLLM || rc=$?; step_end $rc;;
    Triton|triton)
      step_begin "${S}:${envbase}:install"; rc=0; "$UST" "${EA[@]}" Triton install || rc=$?; step_end $rc
      step_begin "${S}:${envbase}:benchmark"; rc=0; "$UST" "${EA[@]}" Triton benchmark || rc=$?; step_end $rc
      step_begin "${S}:${envbase}:analyze"; rc=0; "$UST" "${EA[@]}" analyze --stack Triton || rc=$?; step_end $rc;;
    *) warn "Unknown stack: $S" ;;
  esac
}

for ENVF in "${ENV_FILES[@]}"; do
  info "ENV: $(basename "$ENVF")"
  for S in "${STACKS[@]}"; do run_stack_env "$S" "$ENVF"; done
done

# Collect + summarize
step_begin "collect"; rc=0; "${ROOT_DIR}/LLM/refinery/stack/common/collect-results.sh" --log-dir "$LOG_DIR" --stacks "${STACKS[*]}" || rc=$?; step_end $rc
step_begin "summary"; rc=0; "${ROOT_DIR}/LLM/refinery/stack/common/summarize-benchmarks.sh" --csv "${ROOT_DIR}/LLM/refinery/benchmarks.csv" --top 15 | tee -a "${LOG_DIR}/wrapper_best_${TS}.txt" || rc=$?; step_end $rc

ok "Wrapper complete. Summary: $SUMMARY"
log "  CSVs    : $(ls -t ${LOG_DIR}/*_bench_*.csv 2>/dev/null | head -n1 || echo none)"
log "  Bests   : $(ls -t ${ROOT_DIR}/LLM/refinery/benchmarks.best*.csv 2>/dev/null | head -n2 | paste -sd' ' - || echo none)"
