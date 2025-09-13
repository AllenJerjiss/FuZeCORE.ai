#!/usr/bin/env bash
# analyze.sh — Summarize a benchmark CSV (any stack) with clear results
# Usage:
#   ./analyze.sh [--stack STACK] [--csv PATH] [--model REGEX] [--top N]
# Defaults:
#   --stack autodetect latest among {ollama,vLLM,llamacpp,Triton}
#   --csv   pick latest CSV in LOG_DIR
#   --model no filter
#   --top   5

set -euo pipefail

LOG_DIR_DEFAULT="${LOG_DIR:-/var/log/fuze-stack}"
STACK=""
CSV=""
MODEL_RE=""
TOPN=5

usage(){
  cat <<USAGE
Usage: $0 [--stack STACK] [--csv PATH] [--model REGEX] [--top N]
  STACK: one of {ollama, vLLM, llama.cpp, Triton}
  CSV  : path to a benchmark CSV (overrides autodiscovery)
  MODEL: regex to filter base_model (e.g., '^gemma3:4b')
  TOP  : number of top rows to show (default: ${TOPN})
Env:
  LOG_DIR: logs directory (default: ${LOG_DIR_DEFAULT})
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --stack) STACK="$2"; shift 2;;
    --csv)   CSV="$2"; shift 2;;
    --model) MODEL_RE="$2"; shift 2;;
    --top)   TOPN="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

log(){ echo -e "$*"; }
err(){ echo -e "\033[31m✖\033[0m $*" >&2; }
ok(){ echo -e "\033[32m✔\033[0m $*"; }

pick_latest_csv(){
  local dir="$1" stack="$2"; local pat
  case "$stack" in
    ollama)   pat='ollama_bench_*.csv' ;;
    vLLM)     pat='vllm_bench_*.csv' ;;
    llama.cpp|llamacpp|llama-cpp) pat='llamacpp_bench_*.csv' ;;
    Triton|triton) pat='triton_bench_*.csv' ;;
    *) pat='*_bench_*.csv' ;;
  esac
  ls -t "$dir"/$pat 2>/dev/null | head -n1 || true
}

if [ -z "$CSV" ]; then
  # Try default log dir
  CSV="$(pick_latest_csv "$LOG_DIR_DEFAULT" "$STACK" || true)"
  # If not found and no stack constraint, try common prefixes
  if [ -z "$CSV" ]; then
    for s in ollama vLLM llama.cpp Triton; do
      CSV="$(pick_latest_csv "$LOG_DIR_DEFAULT" "$s" || true)"
      [ -n "$CSV" ] && break
    done
  fi
fi

if [ -z "$CSV" ] || [ ! -f "$CSV" ]; then
  err "CSV not found. Use --csv PATH or run a benchmark first."
  exit 1
fi

log "CSV     : $CSV"

if [ -n "$MODEL_RE" ]; then
  log "Model RE: $MODEL_RE"
fi

# Count rows and unique base models
awk -F',' 'NR>1{n++; m[$5]=1} END{printf "Rows   : %d\nModels : %d\n", n, length(m)}' "$CSV"

# If model filter provided, create a temp filtered view
TMP_CSV="$CSV"
if [ -n "$MODEL_RE" ]; then
  TMP_CSV="$(mktemp)"
  awk -F',' -v re="$MODEL_RE" 'NR==1|| $5 ~ re' "$CSV" >"$TMP_CSV"
fi

echo
echo "Top ${TOPN} by tokens/sec:"
tail -n +2 "$TMP_CSV" | sort -t',' -k12,12gr | head -n "$TOPN" \
  | awk -F',' '{printf "  %-21s %-26s %-12s %-36s %8.2f  (%s %s)\n", $2,$5,$6,$7,$12,$13,$14}'

echo
echo "Best optimized per (endpoint, base_model):"
awk -F',' '
  NR>1 && $6=="optimized" && $12+0>0 {
    k=$2"|"$5
    if ($12+0>best[k]) {best[k]=$12+0; tag[k]=$7; ng[k]=$8}
  }
  END{
    if (length(best)==0){print "  (none)"; exit}
    for (k in best){
      split(k,a,"|")
      printf "  %-21s %-26s ng=%-4s %8.2f  %s\n", a[1],a[2],ng[k],best[k],tag[k]
    }
  }
' "$TMP_CSV"

echo
echo "Base vs Optimized (per endpoint & model):"
awk -F',' '
  NR==1{next}
  {
    key=$2"|"$5
    if ($6=="base-as-is"){base[key]=$12+0}
    else if ($6=="optimized"){ if ($12+0>opt[key]){opt[key]=$12+0; optname[key]=$7} }
  }
  END{
    printf "  %-21s %-26s %10s %10s %8s %s\n","endpoint","model","base_t/s","opt_t/s","x","best_variant"
    for (k in base){
      be=base[k]+0; op=opt[k]+0; split(k,a,"|"); mult=(be>0? op/be : 0)
      printf "  %-21s %-26s %10.2f %10.2f %8.2fx %s\n", a[1],a[2],be,op,(be>0?mult:0),optname[k]
    }
  }
' "$TMP_CSV"

[ "$TMP_CSV" != "$CSV" ] && rm -f "$TMP_CSV" || true

ok "Analysis complete."

