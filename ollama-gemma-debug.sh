#!/usr/bin/env bash
# Orchestrator: install → cleanup → benchmark → export → analyze
# Profile: Gemma debug (fuze-box/stack/FuZe-CORE-gemma-debug.env)
# Usage:
#   ./ollama-gemma-debug.sh [--no-install] [--no-cleanup] [--no-bench] [--no-export] [--no-analyze]
#   Env toggles: SKIP_INSTALL, SKIP_CLEANUP, SKIP_BENCH, SKIP_EXPORT, SKIP_ANALYZE, DRY_RUN=1

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UST="${ROOT_DIR}/fuze-box/stack/ust.sh"
ENV_FILE="${ROOT_DIR}/fuze-box/stack/FuZe-CORE-gemma-debug.env"
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

step_begin(){ STEP_NAME="$1"; STEP_TS=$(date +%s); info "[$STEP_NAME]"; }
step_end(){ local rc=$1; local dur=$(( $(date +%s) - STEP_TS ));
  if [ "$rc" -eq 0 ]; then ok "[$STEP_NAME] done (${dur}s)"; else err "[$STEP_NAME] rc=$rc (${dur}s)"; fi
  printf "%s,%s,%s,%s\n" "${TS}" "${STEP_NAME}" "$rc" "$dur" >> "$SUMMARY" || true
}

mkdir -p "$LOG_DIR" || true
echo "ts,step,rc,seconds" > "$SUMMARY" 2>/dev/null || true

usage(){
  cat <<USAGE
Usage: $(basename "$0") [--no-install] [--no-cleanup] [--no-bench] [--no-export] [--no-analyze]
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

while [ $# -gt 0 ]; do
  case "$1" in
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
if [ ! -f "$ENV_FILE" ]; then err "Gemma debug env not found: $ENV_FILE"; exit 2; fi

# Re-exec as root preserving env
if [ "$(id -u)" -ne 0 ]; then exec sudo -E "$0" "$@"; fi

info "Wrapper start @ ${TS} (logs: ${LOG_DIR})"

# Preflight (advisory)
if [ "$DRY_RUN" -eq 0 ]; then
  step_begin "preflight"; "$UST" "@${ENV_FILE}" preflight >/dev/null 2>&1 || true; step_end $?; fi

# 0) Install / Upgrade Ollama
if [ "$SKIP_INSTALL" -eq 0 ]; then
  if [ "$DRY_RUN" -eq 0 ]; then step_begin "install"; "$UST" "@${ENV_FILE}" ollama install; step_end $?; else info "[install] DRY_RUN"; fi
else
  info "[install] skipped"
fi

# 1) Cleanup
if [ "$SKIP_CLEANUP" -eq 0 ]; then
  if [ "$DRY_RUN" -eq 0 ]; then step_begin "service-cleanup"; "$UST" "@${ENV_FILE}" ollama service-cleanup || true; step_end $?; else info "[service-cleanup] DRY_RUN"; fi
  if [ "$DRY_RUN" -eq 0 ]; then step_begin "cleanup-variants"; "$UST" "@${ENV_FILE}" ollama cleanup-variants || true; step_end $?; else info "[cleanup-variants] DRY_RUN"; fi
else
  info "[cleanup] skipped"
fi

# 2) Benchmark
if [ "$SKIP_BENCH" -eq 0 ]; then
  if [ "$DRY_RUN" -eq 0 ]; then step_begin "benchmark"; "$UST" "@${ENV_FILE}" ollama benchmark; step_end $?; else info "[benchmark] DRY_RUN"; fi
else
  info "[benchmark] skipped"
fi

# 3) Export GGUFs
if [ "$SKIP_EXPORT" -eq 0 ]; then
  if [ "$DRY_RUN" -eq 0 ]; then step_begin "export-gguf"; "$UST" "@${ENV_FILE}" ollama export-gguf; step_end $?; else info "[export-gguf] DRY_RUN"; fi
else
  info "[export] skipped"
fi

# 4) Analyze results
if [ "$SKIP_ANALYZE" -eq 0 ]; then
  if [ "$DRY_RUN" -eq 0 ]; then step_begin "analyze"; "$UST" "@${ENV_FILE}" analyze --stack ollama; step_end $?; else info "[analyze] DRY_RUN"; fi
else
  info "[analyze] skipped"
fi

echo
ok "Wrapper complete. Summary: $SUMMARY"
log "  CSVs    : $(ls -t ${LOG_DIR}/ollama_bench_*.csv 2>/dev/null | head -n1 || echo none)"
log "  Summary : $(ls -t ${LOG_DIR}/*benchmark.txt 2>/dev/null | head -n1 || echo none)"
log "  Export  : $(ls -t ${ROOT_DIR}/fuze-box/stack/logs/ollama_export_*.csv 2>/dev/null | head -n1 || echo none)"
