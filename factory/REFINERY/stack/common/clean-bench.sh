#!/usr/bin/env bash
# clean-bench.sh — Safely clean benchmark artifacts
# - Dry-run by default; requires --yes to actually delete
# - Can also run stack-level variant cleanup (Ollama) if requested

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
UST="${ROOT_DIR}/stack/ust.sh"

LOG_DIR="${LOG_DIR:-$LOG_DIR_DEFAULT}"
DO_LOGS=1
DO_REPO=1
DO_VARIANTS=0
KEEP_LATEST=0
YES=0
DRY_RUN=1        # Safe default - require explicit --yes

usage(){
  cat <<USAGE
Usage: $(basename "$0") [--no-logs] [--no-repo] [--variants] [--keep-latest N] [--yes]
Defaults:
  - removes bench logs under LOG_DIR and repo aggregates under factory/LLM/refinery (dry-run unless --yes)
Options:
  --no-logs          : skip LOG_DIR cleanup
  --no-repo          : skip repo CSV cleanup
  --variants         : also run Ollama variant cleanup
  --keep-latest N    : keep N most recent files in each category
  --yes              : actually execute (default is dry-run)
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --no-logs) DO_LOGS=0; shift 1;;
    --no-repo) DO_REPO=0; shift 1;;
    --variants) DO_VARIANTS=1; shift 1;;
    --keep-latest) KEEP_LATEST="$2"; shift 2;;
    --yes|-y) YES=1; DRY_RUN=0; shift 1;;
    -h|--help) usage; exit 0;;
    *) error_exit "Unknown argument: $1";;
  esac
done

# Validate parameters
if [ -n "$KEEP_LATEST" ]; then
    validate_number "$KEEP_LATEST" "keep-latest" 0
fi
show_dry_run_status

echo "== Clean plan =="
echo "Logs   : ${LOG_DIR} (clean=${DO_LOGS}, keep-latest=${KEEP_LATEST})"
echo "Repo   : ${ROOT_DIR}/benchmarks*.csv (clean=${DO_REPO})"
echo "Services: Stop all ollama*.service units"
echo "Variants: ${DO_VARIANTS}"
echo "Mode   : $([ "$YES" -eq 1 ] && echo EXECUTE || echo DRY-RUN)"

do_rm(){ # files...
  local files=("$@");
  [ ${#files[@]} -eq 0 ] && return 0
  if [ "$YES" -eq 1 ]; then
    rm -rf "${files[@]}" 2>/dev/null || true
  else
    printf '  rm %s\n' "${files[@]}"
  fi
}

# Clean services
echo "-- Stopping and disabling all ollama services"
if [ "$YES" -eq 1 ]; then
    # Stop the main service first
    if systemctl is-active --quiet ollama.service; then
        info "Stopping main ollama.service"
        systemctl stop ollama.service
    fi

    # Use systemctl to find, stop, and disable all ollama-related services
    systemctl list-units 'ollama*.service' --no-legend | awk '{print $1}' | while read -r service; do
        info "Stopping and disabling $service"
        systemctl stop "$service" >/dev/null 2>&1 || true
        systemctl disable "$service" >/dev/null 2>&1 || true
        systemctl reset-failed "$service" >/dev/null 2>&1 || true
    done
    
    # As a fallback, forcefully kill any lingering ollama serve processes
    if pgrep -f '/usr/local/bin/ollama serve' >/dev/null; then
        info "Forcefully killing lingering 'ollama serve' processes..."
        pkill -f '/usr/local/bin/ollama serve' || true
        sleep 2 # Give time for processes to die
    fi
else
    info "DRY RUN: Would stop main ollama.service"
    info "DRY RUN: Would stop and disable all ollama*.service units"
    info "DRY RUN: Would kill any remaining 'ollama serve' processes"
fi

# Clean logs
if [ "$DO_LOGS" -eq 1 ]; then
  shopt -s nullglob
  bench_csv=("$LOG_DIR"/*_bench_*.csv)
  if [ "$KEEP_LATEST" -gt 0 ] && [ ${#bench_csv[@]} -gt "$KEEP_LATEST" ]; then
    mapfile -t sorted < <(ls -t "$LOG_DIR"/*_bench_*.csv 2>/dev/null || true)
    to_remove=("${sorted[@]:$KEEP_LATEST}")
  else
    to_remove=("${bench_csv[@]}")
  fi
  other=("$LOG_DIR"/wrapper_* "$LOG_DIR"/ollama_export_*.csv "$LOG_DIR"/export_errors_* "$LOG_DIR"/debug_*)
  echo "-- Logs to remove:"
  do_rm "${to_remove[@]}" "${other[@]}"
  shopt -u nullglob
fi

# Clean repo aggregates
if [ "$DO_REPO" -eq 1 ]; then
  echo "-- Repo aggregates to remove:"
  do_rm "${ROOT_DIR}/benchmarks.csv" "${ROOT_DIR}"/benchmarks.best*.csv
fi

# Variants cleanup
if [ "$DO_VARIANTS" -eq 1 ]; then
  echo "-- Running Ollama variant cleanup"
  if [ "$YES" -eq 1 ]; then
    sudo -E "$UST" ollama cleanup-variants --force --yes || true
  else
    echo "  would run: sudo -E $UST ollama cleanup-variants --force --yes"
  fi
fi

echo "Done."

