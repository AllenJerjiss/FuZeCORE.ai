#!/usr/bin/env bash
# Orchestrator: install → cleanup → benchmark → export → analyze (multi-stack)
# Default profile uses Gemma debug env; supply additional envs via --env
# Usage:
#   ./ollama-gemma-debug.sh [--stacks "ollama llama.cpp vLLM"] \
#     [--env PATH]... [--no-install] [--no-cleanup] [--no-bench] [--no-export] [--no-analyze]
#   Env toggles: SKIP_INSTALL, SKIP_CLEANUP, SKIP_BENCH, SKIP_EXPORT, SKIP_ANALYZE, DRY_RUN=1

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UST="${ROOT_DIR}/fuze-box/stack/ust.sh"
DEFAULT_ENV="${ROOT_DIR}/fuze-box/stack/FuZe-CORE-gemma-debug.env"
LOG_DIR="${LOG_DIR:-/var/log/fuze-stack}"
TS="$(date +%Y%m%d_%H%M%S)"
SUMMARY="${LOG_DIR}/wrapper_ollama_gemma_${TS}.summary"

# UI helpers (align with stack scripts)
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

usage(){
  cat <<USAGE
Usage: $(basename "$0") [--stacks "ollama llama.cpp vLLM Triton"] [--env PATH]... \\
       [--no-install] [--no-cleanup] [--no-bench] [--no-export] [--no-analyze]
Env:
  SKIP_INSTALL, SKIP_CLEANUP, SKIP_BENCH, SKIP_EXPORT, SKIP_ANALYZE, DRY_RUN=1
USAGE
}

SKIP_INSTALL=${SKIP_INSTALL:-0}
SKIP_CLEANUP=${SKIP_CLEANUP:-0}
SKIP_BENCH=${SKIP_BENCH:-0}
SKIP_EXPORT=${SKIP_EXPORT:-0}
SKIP_ANALYZE=${SKIP_ANALYZE:-0}
DRY_RUN=${DRY_RUN:-0}
STACKS="${STACKS:-ollama}"
ENV_FILES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --stacks) STACKS="$2"; shift 2;;
    --env) ENV_FILES+=("$2"); shift 2;;
    --no-install) SKIP_INSTALL=1; shift;;
    --no-cleanup) SKIP_CLEANUP=1; shift;;
    --no-bench)   SKIP_BENCH=1; shift;;
    --no-export)  SKIP_EXPORT=1; shift;;
    --no-analyze) SKIP_ANALYZE=1; shift;;
    -h|--help) usage; exit 0;;
    *) warn "Unknown arg: $1"; shift;;
  esac
done

if [ ! -x "$UST" ]; then err "ust.sh not found or not executable: $UST"; exit 2; fi
# Default env if none provided
if [ ${#ENV_FILES[@]} -eq 0 ]; then ENV_FILES=("$DEFAULT_ENV"); fi
for e in "${ENV_FILES[@]}"; do
  [ -f "$e" ] || { err "Env file not found: $e"; exit 2; }
done

# Re-exec as root preserving env
if [ "$(id -u)" -ne 0 ]; then exec sudo -E "$0" "$@"; fi

# Be verbose by default for all subcommands
export VERBOSE=1
export DEBUG_BENCH=1
set -x

info "Wrapper start @ ${TS} (logs: ${LOG_DIR})"

# Compose env arg list for ust
UST_ENV_ARGS=()
for e in "${ENV_FILES[@]}"; do UST_ENV_ARGS+=("@${e}"); done

# Preflight once (advisory)
if [ "$DRY_RUN" -eq 0 ]; then step_begin "preflight"; "$UST" "${UST_ENV_ARGS[@]}" preflight >/dev/null 2>&1 || true; step_end $?; fi

# Iterate stacks
for S in $STACKS; do
  case "$S" in
    ollama|Ollama)
      # 0) install
      if [ "$SKIP_INSTALL" -eq 0 ]; then
        if [ "$DRY_RUN" -eq 0 ]; then step_begin "${S}:install"; set +e; "$UST" "${UST_ENV_ARGS[@]}" ollama install; rc=$?; set -e; step_end $rc; else info "[${S}:install] DRY_RUN"; fi
      fi
      # 1) cleanup
      if [ "$SKIP_CLEANUP" -eq 0 ]; then
        if [ "$DRY_RUN" -eq 0 ]; then step_begin "${S}:service-cleanup"; set +e; "$UST" "${UST_ENV_ARGS[@]}" ollama service-cleanup; rc=$?; set -e; step_end $rc; else info "[${S}:service-cleanup] DRY_RUN"; fi
        if [ "$DRY_RUN" -eq 0 ]; then step_begin "${S}:cleanup-variants"; set +e; "$UST" "${UST_ENV_ARGS[@]}" ollama cleanup-variants --force --yes; rc=$?; set -e; step_end $rc; else info "[${S}:cleanup-variants] DRY_RUN"; fi
      fi
      # 2) benchmark
      if [ "$SKIP_BENCH" -eq 0 ]; then
        if [ "$DRY_RUN" -eq 0 ]; then step_begin "${S}:benchmark"; set +e; "$UST" "${UST_ENV_ARGS[@]}" ollama benchmark; rc=$?; set -e; step_end $rc; else info "[${S}:benchmark] DRY_RUN"; fi
      fi
      # 3) export
      if [ "$SKIP_EXPORT" -eq 0 ]; then
        if [ "$DRY_RUN" -eq 0 ]; then step_begin "${S}:export-gguf"; set +e; "$UST" "${UST_ENV_ARGS[@]}" ollama export-gguf; rc=$?; set -e; step_end $rc; else info "[${S}:export-gguf] DRY_RUN"; fi
      fi
      # 4) analyze
      if [ "$SKIP_ANALYZE" -eq 0 ]; then
        if [ "$DRY_RUN" -eq 0 ]; then step_begin "${S}:analyze"; set +e; "$UST" "${UST_ENV_ARGS[@]}" analyze --stack ollama; rc=$?; set -e; step_end $rc; else info "[${S}:analyze] DRY_RUN"; fi
      fi
      ;;
    llama.cpp|llamacpp|llama-cpp)
      if [ "$SKIP_INSTALL" -eq 0 ]; then
        if [ "$DRY_RUN" -eq 0 ]; then step_begin "${S}:install"; set +e; "$UST" "${UST_ENV_ARGS[@]}" llama.cpp install; rc=$?; set -e; step_end $rc; else info "[${S}:install] DRY_RUN"; fi
      fi
      if [ "$SKIP_BENCH" -eq 0 ]; then
        if [ "$DRY_RUN" -eq 0 ]; then step_begin "${S}:benchmark"; set +e; "$UST" "${UST_ENV_ARGS[@]}" llama.cpp benchmark; rc=$?; set -e; step_end $rc; else info "[${S}:benchmark] DRY_RUN"; fi
      fi
      if [ "$SKIP_ANALYZE" -eq 0 ]; then
        if [ "$DRY_RUN" -eq 0 ]; then step_begin "${S}:analyze"; set +e; "$UST" "${UST_ENV_ARGS[@]}" analyze --stack llama.cpp; rc=$?; set -e; step_end $rc; else info "[${S}:analyze] DRY_RUN"; fi
      fi
      ;;
    vllm|vLLM|VLLM)
      if [ "$SKIP_INSTALL" -eq 0 ]; then
        if [ "$DRY_RUN" -eq 0 ]; then step_begin "${S}:install"; set +e; "$UST" "${UST_ENV_ARGS[@]}" vLLM install; rc=$?; set -e; step_end $rc; else info "[${S}:install] DRY_RUN"; fi
      fi
      if [ "$SKIP_BENCH" -eq 0 ]; then
        if [ "$DRY_RUN" -eq 0 ]; then step_begin "${S}:benchmark"; set +e; "$UST" "${UST_ENV_ARGS[@]}" vLLM benchmark; rc=$?; set -e; step_end $rc; else info "[${S}:benchmark] DRY_RUN"; fi
      fi
      if [ "$SKIP_ANALYZE" -eq 0 ]; then
        if [ "$DRY_RUN" -eq 0 ]; then step_begin "${S}:analyze"; set +e; "$UST" "${UST_ENV_ARGS[@]}" analyze --stack vLLM; rc=$?; set -e; step_end $rc; else info "[${S}:analyze] DRY_RUN"; fi
      fi
      ;;
    Triton|triton)
      if [ "$SKIP_INSTALL" -eq 0 ]; then
        if [ "$DRY_RUN" -eq 0 ]; then step_begin "${S}:install"; set +e; "$UST" "${UST_ENV_ARGS[@]}" Triton install; rc=$?; set -e; step_end $rc; else info "[${S}:install] DRY_RUN"; fi
      fi
      if [ "$SKIP_BENCH" -eq 0 ]; then
        if [ "$DRY_RUN" -eq 0 ]; then step_begin "${S}:benchmark"; set +e; "$UST" "${UST_ENV_ARGS[@]}" Triton benchmark; rc=$?; set -e; step_end $rc; else info "[${S}:benchmark] DRY_RUN"; fi
      fi
      if [ "$SKIP_ANALYZE" -eq 0 ]; then
        if [ "$DRY_RUN" -eq 0 ]; then step_begin "${S}:analyze"; set +e; "$UST" "${UST_ENV_ARGS[@]}" analyze --stack Triton; rc=$?; set -e; step_end $rc; else info "[${S}:analyze] DRY_RUN"; fi
      fi
      ;;
    *) warn "Unknown stack: $S" ;;
  esac
done

echo
ok "Wrapper complete. Summary: $SUMMARY"
log "  CSVs    : $(ls -t ${LOG_DIR}/*_bench_*.csv 2>/dev/null | head -n1 || echo none)"
log "  Summary : $(ls -t ${LOG_DIR}/*benchmark.txt 2>/dev/null | head -n1 || echo none)"
log "  Export  : $(ls -t ${ROOT_DIR}/fuze-box/stack/logs/ollama_export_*.csv 2>/dev/null | head -n1 || echo none)"
