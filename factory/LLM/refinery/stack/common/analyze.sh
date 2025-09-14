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
ALIAS_PREFIX="${ALIAS_PREFIX:-LLM-FuZe-}"
STACK=""
CSV=""
MODEL_RE=""
TOPN=5
WITH_DEBUG=1
NO_TOP=0

usage(){
  cat <<USAGE
Usage: $0 [--stack STACK] [--csv PATH] [--model REGEX] [--top N] [--no-debug] [--no-top]
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
    --no-top)   NO_TOP=1; shift 1;;
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

HOST_SHORT="$(hostname -s 2>/dev/null || hostname)"

# Header details only in debug mode
if [ "$WITH_DEBUG" -eq 1 ]; then
  log "CSV     : $CSV"
  if [ -n "$MODEL_RE" ]; then
    log "Model RE: $MODEL_RE"
  fi
  # Count rows and unique base models
  awk -F',' 'NR>1{n++; m[$5]=1} END{printf "Rows   : %d\nModels : %d\n", n, length(m)}' "$CSV"
fi

# If model filter provided, create a temp filtered view
TMP_CSV="$CSV"
if [ -n "$MODEL_RE" ]; then
  TMP_CSV="$(mktemp)"
  awk -F',' -v re="$MODEL_RE" 'NR==1|| $5 ~ re' "$CSV" >"$TMP_CSV"
fi

# Baseline map per (endpoint|model)
BASEMAP="$(mktemp)"
awk -F',' 'NR>1 && $6=="base-as-is" {k=$2"|"$5; if(($12+0)>b[k]) b[k]=$12+0} END{for(k in b) print k","b[k]}' "$TMP_CSV" >"$BASEMAP"

if [ "$NO_TOP" -eq 0 ]; then
  echo
  echo "Top ${TOPN} by tokens/sec:"
  echo "|---------------------|------------------------------------------|-------------------------------------------|----------|----------|-------------------|"
  echo "| timestamp           | variant                                  | host                                      |   tok/s | base_t/s | FuZe gain factor |"
  echo "|---------------------|------------------------------------------|-------------------------------------------|----------|----------|-------------------|"
  TOPSEL="$(mktemp)"; tail -n +2 "$TMP_CSV" | sort -t',' -k12,12gr | head -n "$TOPN" >"$TOPSEL"
  awk -F',' -v AP="$ALIAS_PREFIX" -v STK="${STACK:-n/a}" -v HST="$HOST_SHORT" -v BM_FILE="$BASEMAP" '
    function aliasify(s,  t){
      t=s; gsub(/[\/:]+/,"-",t);
      gsub(/-it-/,"-i-",t); sub(/-it$/,"-i",t);
      gsub(/-fp16/,"-f16",t); gsub(/-bf16/,"-b16",t);
      return t
    }
    function trim_lead_dash(s){ gsub(/^-+/,"",s); return s }
    function variant(base, ng, gl, st,  ab, sfx, sfx2, va){
      ab=aliasify(base); sfx=ENVIRON["ALIAS_SUFFIX"]; sfx2=trim_lead_dash(sfx);
      if (sfx2!="") va=sprintf("%s%s-%s--%s-%s", AP, st, gl, sfx2, ab);
      else           va=sprintf("%s%s-%s-%s", AP, st, gl, ab);
      if (ng+0>0) va=va "+ng" ng;
      return va
    }
    function htime(ts){ return (length(ts)>=15)? sprintf("%s-%s-%s %s:%s:%s", substr(ts,1,4),substr(ts,5,2),substr(ts,7,2),substr(ts,10,2),substr(ts,12,2),substr(ts,14,2)) : ts }
    BEGIN{ while((getline l < BM_FILE)>0){ split(l,a,","); bm[a[1]]=a[2]+0 } }
  {
    key=$2"|"$5; be=bm[key]+0; tok=$12+0;
    gl=$13; va=variant($5, $8, gl, STK);
    he=sprintf("%s/%s", HST, $2);
    printf "| %-19s | %-40s | %-41s | %8.2f | %8.2f | %19s |\n",
      htime($1), va, he, tok, be, sprintf("%.2fx", (be>0?tok/be:0))
  }' "$TOPSEL"
fi

echo
echo "Best optimized per (endpoint, model):"
echo "|---------------------|------------------------------------------|-------------------------------------------|----------|----------|-------------------|"
echo "| timestamp           | variant                                  | host                                      |   tok/s | base_t/s | FuZe gain factor |"
echo "|---------------------|------------------------------------------|-------------------------------------------|----------|----------|-------------------|"
awk -F',' -v AP="$ALIAS_PREFIX" -v STK="${STACK:-n/a}" -v HST="$HOST_SHORT" '
  function aliasify(s,  t){
    t=s; gsub(/[\/:]+/,"-",t);
    gsub(/-it-/,"-i-",t); sub(/-it$/,"-i",t);
    gsub(/-fp16/,"-f16",t); gsub(/-bf16/,"-b16",t);
    return t
  }
  function trim_lead_dash(s){ gsub(/^-+/,"",s); return s }
  function variant(base, ng, gl, st,  ab, sfx, sfx2, va){
    ab=aliasify(base); sfx=ENVIRON["ALIAS_SUFFIX"]; sfx2=trim_lead_dash(sfx);
    if (sfx2!="") va=sprintf("%s%s-%s--%s-%s", AP, st, gl, sfx2, ab);
    else           va=sprintf("%s%s-%s-%s", AP, st, gl, ab);
    if (ng+0>0) va=va "+ng" ng;
    return va
  }
  function htime(ts){ return (length(ts)>=15)? sprintf("%s-%s-%s %s:%s:%s", substr(ts,1,4),substr(ts,5,2),substr(ts,7,2),substr(ts,10,2),substr(ts,12,2),substr(ts,14,2)) : ts }
  NR>1 {
    k=$2"|"$5
    if ($6=="base-as-is"){base[k]=$12+0}
    else if ($6=="optimized" && $12+0>0){ if ($12+0>best[k]) {best[k]=$12+0; tag[k]=$7; ng[k]=$8; ts[k]=$1; gl_map[k]=$13; ep[k]=$2} }
  }
  END{
    if (length(best)==0){print "| (none)            |"; exit}
    for (k in best){
      split(k,a,"|"); glv=gl_map[k]; va=variant(a[2], (ng[k]?ng[k]:0), glv, STK);
      be=base[k]+0; mult=(be>0? best[k]/be : 0)
      he=sprintf("%s/%s", HST, ep[k]);
      printf "| %-19s | %-40s | %-41s | %8.2f | %8.2f | %19s |\n",
        htime(ts[k]), va, he, best[k], be, sprintf("%.2fx", (be>0?mult:0))
    }
  }
' "$TMP_CSV"

echo
echo "Base vs Optimized (per endpoint & model):"
echo "|---------------------|------------------------------------------|-------------------------------------------|----------|----------|-------------------|"
echo "| timestamp           | variant                                  | host                                      |   tok/s | base_t/s | FuZe gain factor |"
echo "|---------------------|------------------------------------------|-------------------------------------------|----------|----------|-------------------|"
awk -F',' -v AP="$ALIAS_PREFIX" -v STK="${STACK:-n/a}" -v HST="$HOST_SHORT" '
  function aliasify(s,  t){
    t=s; gsub(/[\/:]+/,"-",t);
    gsub(/-it-/,"-i-",t); sub(/-it$/,"-i",t);
    gsub(/-fp16/,"-f16",t); gsub(/-bf16/,"-b16",t);
    return t
  }
  function trim_lead_dash(s){ gsub(/^-+/,"",s); return s }
  function variant(base, ng, gl, st,  ab, sfx, sfx2, va){
    ab=aliasify(base); sfx=ENVIRON["ALIAS_SUFFIX"]; sfx2=trim_lead_dash(sfx);
    if (sfx2!="") va=sprintf("%s%s-%s--%s-%s", AP, st, gl, sfx2, ab);
    else           va=sprintf("%s%s-%s-%s", AP, st, gl, ab);
    if (ng+0>0) va=va "+ng" ng;
    return va
  }
  function htime(ts){ return (length(ts)>=15)? sprintf("%s-%s-%s %s:%s:%s", substr(ts,1,4),substr(ts,5,2),substr(ts,7,2),substr(ts,10,2),substr(ts,12,2),substr(ts,14,2)) : ts }
  NR==1{next}
  {
    key=$2"|"$5
    if ($6=="base-as-is"){base[key]=$12+0; tsb[key]=$1; gl[key]=$13}
    else if ($6=="optimized"){ if ($12+0>opt[key]){opt[key]=$12+0; optname[key]=($8+0>0?aliasify($5) "+ng" $8:aliasify($7)); ng[key]=$8; tso[key]=$1; gl[key]=$13} }
  }
  END{
    for (k in base){
      be=base[k]+0; op=opt[k]+0; split(k,a,"|"); mult=(be>0? op/be : 0)
      ts=(tso[k] ? tso[k] : tsb[k]);
      glv=gl[k]; va=variant(a[2], (ng[k]?ng[k]:0), glv, STK)
      ep=a[1]; he=sprintf("%s/%s", HST, ep);
      printf "| %-19s | %-40s | %-41s | %8.2f | %8.2f | %19s |\n",
        htime(ts), va, he, (op>0?op:0), be, sprintf("%.2fx", (be>0?mult:0))
    }
  }
' "$TMP_CSV"

# New: Best across endpoints per model (baseline vs optimized)
echo
echo "Best across endpoints (per model): baseline vs optimized"
echo "|---------------------|------------------------------------------|-------------------------------------------|----------|----------|-------------------|"
echo "| timestamp           | variant                                  | host                                      |   tok/s | base_t/s | FuZe gain factor |"
echo "|---------------------|------------------------------------------|-------------------------------------------|----------|----------|-------------------|"
awk -F',' -v AP="$ALIAS_PREFIX" -v STK="${STACK:-n/a}" -v HST="$HOST_SHORT" '
  function aliasify(s,  t){
    t=s; gsub(/[\/:]+/,"-",t);
    gsub(/-it-/,"-i-",t); sub(/-it$/,"-i",t);
    gsub(/-fp16/,"-f16",t); gsub(/-bf16/,"-b16",t);
    return t
  }
  function trim_lead_dash(s){ gsub(/^-+/,"",s); return s }
  function variant(base, ng, gl, st,  ab, sfx, sfx2, va){
    ab=aliasify(base); sfx=ENVIRON["ALIAS_SUFFIX"]; sfx2=trim_lead_dash(sfx);
    if (sfx2!="") va=sprintf("%s%s-%s--%s-%s", AP, st, gl, sfx2, ab);
    else           va=sprintf("%s%s-%s-%s", AP, st, gl, ab);
    if (ng+0>0) va=va "+ng" ng;
    return va
  }
  function htime(ts){ return (length(ts)>=15)? sprintf("%s-%s-%s %s:%s:%s", substr(ts,1,4),substr(ts,5,2),substr(ts,7,2),substr(ts,10,2),substr(ts,12,2),substr(ts,14,2)) : ts }
  NR>1 {
    k=$5
    if($6=="base-as-is" && $12+0>bb[k]){ bb[k]=$12+0; tsb[k]=$1 }
    if(($6=="optimized"||$6=="published") && $12+0>oo[k]){ oo[k]=$12+0; ng[k]=$8; tso[k]=$1; ep[k]=$2; gl[k]=$13 }
  }
  END{
    for (m in bb){
      be=bb[m]+0; op=oo[m]+0; mult=(be>0? op/be : 0); ab=aliasify(m);
      ts=(tso[m]?tso[m]:tsb[m]); glv=(gl[m]?gl[m]:"n/a"); va=variant(m, (ng[m]?ng[m]:0), glv, STK)
      he=sprintf("%s/%s", HST, (ep[m]?ep[m]:"n/a"));
      printf "| %-19s | %-40s | %-41s | %8.2f | %8.2f | %19s |\n",
        htime(ts), va, he, (op>0?op:0), be, sprintf("%.2fx", (be>0?mult:0))
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
      echo "    |---------------------|------------------------------------------|-------------------------------------------|----------|----------|-------------------|"
      echo "    | timestamp           | variant                                  | host                                      |   tok/s | base_t/s | FuZe gain factor |"
      echo "    |---------------------|------------------------------------------|-------------------------------------------|----------|----------|-------------------|"
      jq -r '[(.tokens_per_sec // 0), (.endpoint // ""), (.model // "")] | @tsv' "$DDIR"/*metrics.json 2>/dev/null \
        | sort -k1,1gr | head -n "$TOPN" \
        | awk -F'\t' -v AP="$ALIAS_PREFIX" -v STK="${STACK:-n/a}" -v HST="$(hostname -s 2>/dev/null || hostname)" '
            function aliasify(s,  t){ t=s; gsub(/[\/:]+/,"-",t); return t }
            {
              tok=$1+0; ep=$2; mt=$3; ma=aliasify(mt);
              printf "    | %-19s | %-40s | %-41s | %8.2f | %8s | %19s |\n",
                "n/a", (AP STK "-" ma), (HST "/" ep), tok, "n/a", "n/a"
            }'
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
rm -f "$BASEMAP" "${TOPSEL:-}" 2>/dev/null || true

ok "Analysis complete."
