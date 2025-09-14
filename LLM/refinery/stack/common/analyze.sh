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
# Alias prefix (should match benchmark scripts); can be blank
ALIAS_PREFIX="${ALIAS_PREFIX:-FuZeCORE-}"
STACK=""
CSV=""
MODEL_RE=""
TOPN=5
WITH_DEBUG=1

usage(){
  cat <<USAGE
Usage: $0 [--stack STACK] [--csv PATH] [--model REGEX] [--top N] [--no-debug]
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
    --no-debug) WITH_DEBUG=0; shift 1;;
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
echo "Top ${TOPN} by tokens/sec (alias names):"
tail -n +2 "$TMP_CSV" | sort -t',' -k12,12gr | head -n "$TOPN" \
  | awk -F',' -v AP="$ALIAS_PREFIX" '
    function aliasify(s,  t){ t=s; gsub(/[\/:]+/,"-",t); return (AP t) }
    {
      ab=aliasify($5);
      # Variant alias: prefer +ng when optimized; else aliasified tag
      if($6=="optimized" && ($8+0)>0){ va=ab "+ng" $8 } else { va=aliasify($7) }
      printf "  %-21s %-32s %-12s %-36s %8.2f  (%s %s)\n", $2,ab,$6,va,$12,$13,$14
    }'

echo
echo "Best optimized per (endpoint, model):"
awk -F',' -v AP="$ALIAS_PREFIX" '
  function aliasify(s,  t){ t=s; gsub(/[\/:]+/,"-",t); return (AP t) }
  NR>1 && $6=="optimized" && $12+0>0 {
    k=$2"|"$5
    if ($12+0>best[k]) {best[k]=$12+0; tag[k]=$7; ng[k]=$8}
  }
  END{
    if (length(best)==0){print "  (none)"; exit}
    for (k in best){
      split(k,a,"|"); ab=aliasify(a[2]); va=(ng[k]>0?ab "+ng" ng[k]:aliasify(tag[k]));
      printf "  %-21s %-32s ng=%-4s %8.2f  %s\n", a[1],ab,ng[k],best[k],va
    }
  }
' "$TMP_CSV"

echo
echo "Base vs Optimized (per endpoint & model):"
awk -F',' -v AP="$ALIAS_PREFIX" '
  function aliasify(s,  t){ t=s; gsub(/[\/:]+/,"-",t); return (AP t) }
  NR==1{next}
  {
    key=$2"|"$5
    if ($6=="base-as-is"){base[key]=$12+0}
    else if ($6=="optimized"){ if ($12+0>opt[key]){opt[key]=$12+0; optname[key]=($8+0>0?aliasify($5) "+ng" $8:aliasify($7))} }
  }
  END{
    printf "  %-21s %-32s %10s %10s %8s %s\n","endpoint","model","base_t/s","opt_t/s","x","best_variant"
    for (k in base){
      be=base[k]+0; op=opt[k]+0; split(k,a,"|"); mult=(be>0? op/be : 0)
      printf "  %-21s %-32s %10.2f %10.2f %8.2fx %s\n", a[1],aliasify(a[2]),be,op,(be>0?mult:0),(optname[k] ? optname[k] : "-")
    }
  }
' "$TMP_CSV"

# New: Best across endpoints per model (baseline vs optimized)
echo
echo "Best across endpoints (per model): baseline vs optimized"
awk -F',' -v AP="$ALIAS_PREFIX" '
  function aliasify(s,  t){ t=s; gsub(/[\/:]+/,"-",t); return (AP t) }
  NR>1 {
    k=$5
    if($6=="base-as-is" && $12+0>bb[k]){ bb[k]=$12+0 }
    if(($6=="optimized"||$6=="published") && $12+0>oo[k]){ oo[k]=$12+0; ng[k]=$8 }
  }
  END{
    # header
    printf "  %-32s %10s %10s %8s %s\n","model","base_t/s","opt_t/s","x","variant"
    for (m in bb){
      be=bb[m]+0; op=oo[m]+0; mult=(be>0? op/be : 0); ab=aliasify(m);
      v=(ng[m]>0?ab "+ng" ng[m]: (op>0?ab:"-"));
      printf "  %-32s %10.2f %10.2f %8.2fx %s\n", ab, be, op, (be>0?mult:0), v
    }
  }
' "$TMP_CSV"

# Optional: correlate with debug metrics from the same run timestamp
if [ "$WITH_DEBUG" -eq 1 ]; then
  # Extract run timestamp from CSV filename (last _YYYYMMDD_HHMMSS before .csv)
  TS_FROM_CSV=$(basename "$CSV" | grep -Eo '[0-9]{8}_[0-9]{6}' | tail -n1 || true)
  if [ -n "$TS_FROM_CSV" ]; then
    DDIR="${LOG_DIR_DEFAULT}/debug_${TS_FROM_CSV}"
    if [ -d "$DDIR" ]; then
      echo
      echo "Debug metrics (from ${DDIR}):"
      METS=("$DDIR"/*metrics.json)
      if [ -e "${METS[0]}" ]; then
        # Summary counts
        nz=$(jq -r '.tokens_per_sec // 0' "$DDIR"/*metrics.json 2>/dev/null | awk '{if($1+0>0) c++} END{print c+0}')
        z=$(jq -r '.tokens_per_sec // 0' "$DDIR"/*metrics.json 2>/dev/null | awk '{if(!($1+0>0)) c++} END{print c+0}')
        echo "  calls: $((nz+z))   nonzero: $nz   zero: $z"
        echo
        echo "  Top by tokens/sec:"
        jq -r '[(.tokens_per_sec // 0), (.endpoint // ""), (.model // "")] | @tsv' "$DDIR"/*metrics.json 2>/dev/null \
          | sort -k1,1gr | head -n "$TOPN" \
          | awk -F'\t' '{printf "    %-21s %-30s %8.2f\n", $2, $3, $1+0}'
        if [ "$nz" = "0" ]; then
          echo
          echo "  First few zero t/s calls:"
          for f in "$DDIR"/*metrics.json; do
            jq -r 'select((.tokens_per_sec//0)==0) | "    "+(.endpoint//"-")+"  "+(.model//"-")' "$f" 2>/dev/null || true
          done | head -n 5
        fi
      else
        echo "  (no debug metrics files found)"
      fi
    fi
  fi
fi

[ "$TMP_CSV" != "$CSV" ] && rm -f "$TMP_CSV" || true

ok "Analysis complete."
