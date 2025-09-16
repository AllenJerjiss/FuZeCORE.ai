#!/usr/bin/env bash
# collect-results.sh — Append summarized benchmarks to a central CSV
# - Scans latest bench CSV for each stack in LOG_DIR
# - For each base_model, computes best baseline and best optimized (if any)
# - Appends rows to an aggregate CSV (default: <repo>/LLM/refinery/benchmarks.csv)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Repo refinery root (this script lives in LLM/refinery/stack/common)
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

LOG_DIR="${LOG_DIR:-$LOG_DIR_DEFAULT}"
OUT_CSV="${OUT_CSV:-${ROOT_DIR}/benchmarks.csv}"
STACKS="${STACKS:-$SUPPORTED_STACKS}"
SCAN_ALL=0

usage(){
  cat <<USAGE
Usage: $(basename "$0") [--log-dir DIR] [--out PATH] [--stacks "STACK LIST"] [--all] [--help]

Options:
  --log-dir DIR    Log directory to scan (default: $LOG_DIR)
  --out PATH       Output CSV file (default: $OUT_CSV) 
  --stacks "LIST"  Space-separated stack names (default: $STACKS)
  --all            Scan all CSV files, not just latest per stack
  --help           Show this help

Environment:
  LOG_DIR, OUT_CSV, STACKS can also be set via environment variables
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --log-dir) LOG_DIR="$2"; shift 2;;
    --out)     OUT_CSV="$2"; shift 2;;
    --stacks)  STACKS="$2"; shift 2;;
    --all)     SCAN_ALL=1; shift 1;;
    -h|--help) usage; exit 0;;
    *) error_exit "Unknown argument: $1";;
  esac
done

# Validate inputs
require_dir_writable "$(dirname "$OUT_CSV")"
[ -d "$LOG_DIR" ] || error_exit "Log directory not found: $LOG_DIR"

# Check required tools
require_cmds awk sort find

info "Collecting benchmark results..."
info "Log directory: $LOG_DIR"
info "Output CSV: $OUT_CSV"
info "Stacks: $STACKS"

host="$(get_hostname)"

# Ensure output exists with header
if [ ! -f "$OUT_CSV" ]; then
  echo "run_ts,host,stack,model,baseline_tokps,optimal_variant,optimal_tokps,baseline_endpoint,optimal_endpoint,gpu_label,gpu_name,num_gpu,csv_file" > "$OUT_CSV"
fi

pick_latest(){ # pattern -> path or empty
  ls -t "$LOG_DIR"/$1 2>/dev/null | head -n1 || true
}

pick_all(){ # pattern -> list (newline) or empty
  ls -t "$LOG_DIR"/$1 2>/dev/null || true
}

summarize_csv(){ # stack csv_path
  local stack="$1" csv="$2"
  [ -f "$csv" ] || return 0
  local run_ts base_models
  run_ts="$(basename "$csv" | grep -Eo '[0-9]{8}_[0-9]{6}' | tail -n1)"
  # list unique base_model values
  base_models="$(awk -F',' 'NR>1{print $5}' "$csv" | sort -u)"
  [ -n "$base_models" ] || return 0
  while IFS= read -r model; do
    [ -n "$model" ] || continue
    # best baseline row for model
    local base_row opt_row
    base_row="$(awk -F',' -v m="$model" 'NR>1 && $5==m && $6=="base-as-is" {
        if(($12+0)>mx){mx=$12+0; line=$0}
      } END{if(mx>0) print line}' "$csv" || true)"
    # best optimized/published row if present
    opt_row="$(awk -F',' -v m="$model" 'NR>1 && $5==m && ($6=="optimized" || $6=="published") {
        if(($12+0)>mx){mx=$12+0; line=$0}
      } END{if(mx>0) print line}' "$csv" || true)"

    # parse common fields
    IFS=',' read -r _ts _ep _unit _sfx _bm _label _tag _ng _nc _batch _np _tokps _glabel _gname _guid _gmem <<<"${base_row:-,,,,,,,,,,,,,,,}"
    local baseline_tokps baseline_ep glabel gname
    baseline_tokps="${_tokps:-0}"
    baseline_ep="${_ep:-}"
    glabel="${_glabel:-}"
    gname="${_gname:-}"
    local optimal_tag optimal_tokps optimal_ep optimal_ng
    if [ -n "${opt_row:-}" ]; then
      IFS=',' read -r _ts2 _ep2 _unit2 _sfx2 _bm2 _label2 _tag2 _ng2 _nc2 _batch2 _np2 _tokps2 _glabel2 _gname2 _guid2 _gmem2 <<<"$opt_row"
      optimal_tag="${_tag2:-}"
      optimal_tokps="${_tokps2:-0}"
      optimal_ep="${_ep2:-}"
      optimal_ng="${_ng2:-}"
    else
      optimal_tag=""
      optimal_tokps="$baseline_tokps"
      optimal_ep="$baseline_ep"
      optimal_ng=""
    fi
    printf "%s,%s,%s,%s,%.2f,%s,%.2f,%s,%s,%s,%s,%s,%s\n" \
      "${run_ts}" "${host}" "${stack}" "${model}" \
      "${baseline_tokps:-0}" "${optimal_tag}" "${optimal_tokps:-0}" \
      "${baseline_ep}" "${optimal_ep}" "${glabel}" "${gname}" "${optimal_ng}" "$csv" \
      >> "$OUT_CSV"
  done <<< "$base_models"
}

for s in $STACKS; do
  case "$s" in
    ollama|Ollama)
      if [ "$SCAN_ALL" -eq 1 ]; then
        while IFS= read -r csv; do [ -n "$csv" ] && summarize_csv "ollama" "$csv"; done < <(pick_all 'ollama_bench_*.csv')
      else
        csv="$(pick_latest 'ollama_bench_*.csv')" ; [ -n "$csv" ] && summarize_csv "ollama" "$csv"
      fi ;;
    vllm|vLLM|VLLM)
      if [ "$SCAN_ALL" -eq 1 ]; then
        while IFS= read -r csv; do [ -n "$csv" ] && summarize_csv "vLLM" "$csv"; done < <(pick_all 'vllm_bench_*.csv')
      else
        csv="$(pick_latest 'vllm_bench_*.csv')" ; [ -n "$csv" ] && summarize_csv "vLLM" "$csv"
      fi ;;
    llama.cpp|llamacpp|llama-cpp)
      if [ "$SCAN_ALL" -eq 1 ]; then
        while IFS= read -r csv; do [ -n "$csv" ] && summarize_csv "llama.cpp" "$csv"; done < <(pick_all 'llamacpp_bench_*.csv')
      else
        csv="$(pick_latest 'llamacpp_bench_*.csv')" ; [ -n "$csv" ] && summarize_csv "llama.cpp" "$csv"
      fi ;;
    triton|Triton)
      if [ "$SCAN_ALL" -eq 1 ]; then
        while IFS= read -r csv; do [ -n "$csv" ] && summarize_csv "Triton" "$csv"; done < <(pick_all 'triton_bench_*.csv')
      else
        csv="$(pick_latest 'triton_bench_*.csv')" ; [ -n "$csv" ] && summarize_csv "Triton" "$csv"
      fi ;;
  esac
done

echo "Appended summaries to: $OUT_CSV"

# Ensure ownership if running under sudo
if [ -n "${SUDO_USER:-}" ] && [ -f "$OUT_CSV" ]; then
  chown -f "$SUDO_USER":"$SUDO_USER" "$OUT_CSV" 2>/dev/null || true
fi
