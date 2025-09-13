#!/usr/bin/env bash
# collect-results.sh — Append summarized benchmarks to a central CSV
# - Scans latest bench CSV for each stack in LOG_DIR
# - For each base_model, computes best baseline and best optimized (if any)
# - Appends rows to an aggregate CSV (default: <repo>/fuze-box/benchmarks.csv)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"   # fuze-box

LOG_DIR="${LOG_DIR:-/var/log/fuze-stack}"
OUT_CSV="${OUT_CSV:-${ROOT_DIR}/benchmarks.csv}"
STACKS="${STACKS:-ollama vLLM llama.cpp Triton}"

usage(){
  cat <<USAGE
Usage: $(basename "$0") [--log-dir DIR] [--out PATH] [--stacks "ollama vLLM llama.cpp Triton"]
Env:
  LOG_DIR, OUT_CSV, STACKS
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --log-dir) LOG_DIR="$2"; shift 2;;
    --out)     OUT_CSV="$2"; shift 2;;
    --stacks)  STACKS="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

host="$(hostname -s 2>/dev/null || hostname)"

# Ensure output exists with header
if [ ! -f "$OUT_CSV" ]; then
  echo "run_ts,host,stack,model,baseline_tokps,optimal_variant,optimal_tokps,baseline_endpoint,optimal_endpoint,gpu_label,gpu_name,num_gpu,csv_file" > "$OUT_CSV"
fi

pick_latest(){ # pattern -> path or empty
  ls -t "$LOG_DIR"/$1 2>/dev/null | head -n1 || true
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
      csv="$(pick_latest 'ollama_bench_*.csv')" ; [ -n "$csv" ] && summarize_csv "ollama" "$csv" ;;
    vllm|vLLM|VLLM)
      csv="$(pick_latest 'vllm_bench_*.csv')" ; [ -n "$csv" ] && summarize_csv "vLLM" "$csv" ;;
    llama.cpp|llamacpp|llama-cpp)
      csv="$(pick_latest 'llamacpp_bench_*.csv')" ; [ -n "$csv" ] && summarize_csv "llama.cpp" "$csv" ;;
    triton|Triton)
      csv="$(pick_latest 'triton_bench_*.csv')" ; [ -n "$csv" ] && summarize_csv "Triton" "$csv" ;;
  esac
done

echo "Appended summaries to: $OUT_CSV"

