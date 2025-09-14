#!/usr/bin/env bash
# summarize-benchmarks.sh — Read LLM/refinery/benchmarks.csv and print best combos
# Sections:
#  - Top N overall by optimal_tokps
#  - Best per (stack, model)
#  - Best per (stack, model, gpu_label)
# Also writes a machine-friendly CSV of best per (stack, model): LLM/refinery/benchmarks.best.csv

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CSV="${CSV:-${ROOT_DIR}/benchmarks.csv}"
TOPN="${TOPN:-10}"
STACK_RE="${STACK_RE:-}"
MODEL_RE="${MODEL_RE:-}"
GPU_RE="${GPU_RE:-}"
HOST_RE="${HOST_RE:-}"
MD_OUT="${MD_OUT:-}"
ALIAS_PREFIX="${ALIAS_PREFIX:-FuZeCORE-}"

usage(){
  cat <<USAGE
Usage: $(basename "$0") [--csv PATH] [--top N] [--stack REGEX] [--model REGEX] [--gpu REGEX] [--host REGEX] [--md-out FILE]
Env:
  CSV (default: LLM/refinery/benchmarks.csv)
  TOPN (default: 10)
  STACK_RE, MODEL_RE, GPU_RE, HOST_RE (regex filters)
  MD_OUT (optional path to write Markdown copy)
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --csv) CSV="$2"; shift 2;;
    --top) TOPN="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

if [ ! -f "$CSV" ]; then
  echo "No data: $CSV not found" >&2
  exit 1
fi

if [ -n "$MD_OUT" ]; then
  mkdir -p "$(dirname "$MD_OUT")" 2>/dev/null || true
  : > "$MD_OUT"
  exec > >(tee "$MD_OUT")
fi

echo "Data: $CSV"

# ------------- Top N overall by optimal_tokps -------------------------------
echo
echo "Top ${TOPN} overall (by optimal_tokps, alias names):"
awk -F',' -v ST="$STACK_RE" -v MR="$MODEL_RE" -v GR="$GPU_RE" -v HR="$HOST_RE" -v AP="$ALIAS_PREFIX" '
  function aliasify(s,  t){ t=s; gsub(/[\/:]+/,"-",t); return (AP t) }
  NR>1 {
    if (ST!="" && $3 !~ ST) next;
    if (MR!="" && $4 !~ MR) next;
    if (HR!="" && $2 !~ HR) next;
    if (GR!="" && ($10 !~ GR && $11 !~ GR)) next;
    if ($7+0>0) printf "%s,%s,%s,%.2f,%.2f,%.2f,%s,%s,%s\n", $3,aliasify($4),$2,$7,$5,($5+0>0?$7/$5:0),$10,$11,$1;
  }
' "$CSV" \
  | sort -t',' -k4,4gr | head -n "$TOPN" \
  | awk -F',' '{
      ts=$9; ht=(length(ts)>=15)? sprintf("%s-%s-%s %s:%s:%s", substr(ts,1,4),substr(ts,5,2),substr(ts,7,2),substr(ts,10,2),substr(ts,12,2),substr(ts,14,2)) : ts;
      printf "  %-19s %-32s %-7s %-21s %8.2f  base=%-8.2f  x=%-6.2f  %-16s\n", ht,$2,$1,$3,$4,$5,$6,$7
    }'

# ------------- Best per (stack, model) --------------------------------------
echo
echo "Best per (stack, model) with baseline (alias names):"
awk -F',' -v ST="$STACK_RE" -v MR="$MODEL_RE" -v GR="$GPU_RE" -v HR="$HOST_RE" -v AP="$ALIAS_PREFIX" '
  function aliasify(s,  t){ t=s; gsub(/[\/:]+/,"-",t); return (AP t) }
  NR>1 {
    if (ST!="" && $3 !~ ST) next;
    if (MR!="" && $4 !~ MR) next;
    if (HR!="" && $2 !~ HR) next;
    if (GR!="" && ($10 !~ GR && $11 !~ GR)) next;
    if (!($7+0>0)) next;
    k=$3"|"$4
    if ($7+0>best[k]) {best[k]=$7+0; line[k]=$0}
  }
  END{
    for (k in best){print line[k]}
  }
' "$CSV" \
 | awk -F',' -v AP="$ALIAS_PREFIX" '
     function aliasify(s,  t){ t=s; gsub(/[\/:]+/,"-",t); return (AP t) }
     {printf "%s,%s,%s,%.2f,%.2f,%.2f,%s,%s,%s\n", $3,aliasify($4),$2,$7,$5,($5+0>0?$7/$5:0),$10,$11,$1}
   ' \
 | sort -t',' -k1,1 -k2,2 \
 | awk -F',' '{
      ts=$9; ht=(length(ts)>=15)? sprintf("%s-%s-%s %s:%s:%s", substr(ts,1,4),substr(ts,5,2),substr(ts,7,2),substr(ts,10,2),substr(ts,12,2),substr(ts,14,2)) : ts;
      printf "  %-19s %-32s %-7s %-21s %8.2f  base=%-8.2f  x=%-6.2f  %-16s\n", ht,$2,$1,$3,$4,$5,$6,$7
    }'

# ------------- Best per (stack, model, gpu_label) ---------------------------
echo
echo "Best per (stack, model, gpu_label) with baseline (alias names):"
awk -F',' -v ST="$STACK_RE" -v MR="$MODEL_RE" -v GR="$GPU_RE" -v HR="$HOST_RE" -v AP="$ALIAS_PREFIX" '
  function aliasify(s,  t){ t=s; gsub(/[\/:]+/,"-",t); return (AP t) }
  NR>1 {
    if (ST!="" && $3 !~ ST) next;
    if (MR!="" && $4 !~ MR) next;
    if (HR!="" && $2 !~ HR) next;
    if (GR!="" && ($10 !~ GR && $11 !~ GR)) next;
    if (!($7+0>0)) next;
    k=$3"|"$4"|"$10
    if ($7+0>best[k]) {best[k]=$7+0; line[k]=$0}
  }
  END{
    for (k in best){print line[k]}
  }
' "$CSV" \
 | awk -F',' -v AP="$ALIAS_PREFIX" '
     function aliasify(s,  t){ t=s; gsub(/[\/:]+/,"-",t); return (AP t) }
     {printf "%s,%s,%s,%.2f,%.2f,%.2f,%s,%s,%s\n", $3,aliasify($4),$10,$7,$5,($5+0>0?$7/$5:0),$2,$11,$1}
   ' \
 | sort -t',' -k1,1 -k2,2 -k3,3 \
 | awk -F',' '{
      ts=$9; ht=(length(ts)>=15)? sprintf("%s-%s-%s %s:%s:%s", substr(ts,1,4),substr(ts,5,2),substr(ts,7,2),substr(ts,10,2),substr(ts,12,2),substr(ts,14,2)) : ts;
      printf "  %-19s %-32s %-7s %-14s %8.2f  base=%-8.2f  x=%-6.2f  %-21s\n", ht,$2,$1,$3,$4,$5,$6,$7
    }'

# ------------- Best per (host, model) across stacks -------------------------
echo
echo "Best per (host, model) across stacks (with baseline, alias names):"
awk -F',' -v ST="$STACK_RE" -v MR="$MODEL_RE" -v GR="$GPU_RE" -v HR="$HOST_RE" -v AP="$ALIAS_PREFIX" '
  function aliasify(s,  t){ t=s; gsub(/[\/:]+/,"-",t); return (AP t) }
  NR>1 {
    if (ST!="" && $3 !~ ST) next;
    if (MR!="" && $4 !~ MR) next;
    if (HR!="" && $2 !~ HR) next;
    if (GR!="" && ($10 !~ GR && $11 !~ GR)) next;
    if (!($7+0>0)) next;
    k=$2"|"$4; if ($7+0>best[k]) {best[k]=$7+0; line[k]=$0}
  }
  END{for (k in best){print line[k]}}
' "$CSV" \
 | awk -F',' -v AP="$ALIAS_PREFIX" '
     function aliasify(s,  t){ t=s; gsub(/[\/:]+/,"-",t); return (AP t) }
     {printf "%s,%s,%s,%.2f,%.2f,%.2f,%s,%s,%s\n", $2,aliasify($4),$3,$7,$5,($5+0>0?$7/$5:0),$10,$11,$1}
   ' \
 | sort -t',' -k1,1 -k2,2 -k4,4gr \
 | awk -F',' '{
      ts=$9; ht=(length(ts)>=15)? sprintf("%s-%s-%s %s:%s:%s", substr(ts,1,4),substr(ts,5,2),substr(ts,7,2),substr(ts,10,2),substr(ts,12,2),substr(ts,14,2)) : ts;
      printf "  %-19s %-32s %-21s %-7s %8.2f  base=%-8.2f  x=%-6.2f  %-16s\n", ht,$2,$1,$3,$4,$5,$6,$7
    }'

# ------------- Global best per model (across hosts & stacks) ----------------
echo
echo "Global best per model (across hosts & stacks, alias names):"
awk -F',' -v MR="$MODEL_RE" -v GR="$GPU_RE" -v AP="$ALIAS_PREFIX" '
  function aliasify(s,  t){ t=s; gsub(/[\/:]+/,"-",t); return (AP t) }
  NR>1 {
    if (MR!="" && $4 !~ MR) next;
    if (GR!="" && ($10 !~ GR && $11 !~ GR)) next;
    if (!($7+0>0)) next;
    k=$4; if ($7+0>best[k]) {best[k]=$7+0; line[k]=$0}
  }
  END{for (k in best){print line[k]}}
' "$CSV" \
 | awk -F',' -v AP="$ALIAS_PREFIX" '
     function aliasify(s,  t){ t=s; gsub(/[\/:]+/,"-",t); return (AP t) }
     {printf "%s,%s,%s,%.2f,%.2f,%.2f,%s,%s,%s\n", aliasify($4),$3,$2,$7,$5,($5+0>0?$7/$5:0),$10,$11,$1}
   ' \
 | sort -t',' -k1,1 -k4,4gr \
 | awk -F',' '{
      ts=$9; ht=(length(ts)>=15)? sprintf("%s-%s-%s %s:%s:%s", substr(ts,1,4),substr(ts,5,2),substr(ts,7,2),substr(ts,10,2),substr(ts,12,2),substr(ts,14,2)) : ts;
      printf "  %-19s %-32s %-7s %-21s %8.2f  base=%-8.2f  x=%-6.2f  %-16s\n", ht,$1,$2,$3,$4,$5,$6,$7
    }'

# ------------- Write best-per-(stack,model) CSV -----------------------------
BEST_CSV="${ROOT_DIR}/benchmarks.best.csv"
{
  echo "stack,model,host,optimal_tokps,baseline_tokps,optimal_variant,gpu_label,gpu_name,num_gpu,run_ts,csv_file"
  awk -F',' -v ST="$STACK_RE" -v MR="$MODEL_RE" -v GR="$GPU_RE" -v HR="$HOST_RE" '
    NR>1 {
      if (ST!="" && $3 !~ ST) next;
      if (MR!="" && $4 !~ MR) next;
      if (HR!="" && $2 !~ HR) next;
      if (GR!="" && ($10 !~ GR && $11 !~ GR)) next;
      if (!($7+0>0)) next;
      k=$3"|"$4; if ($7+0>best[k]) {best[k]=$7+0; line[k]=$0; base[k]=$5}
    }
    END{for (k in best){print line[k]}}
  ' "$CSV" \
  | awk -F',' '{printf "%s,%s,%s,%.2f,%.2f,%s,%s,%s,%s,%s,%s\n", $3,$4,$2,$7,$5,$6,$10,$11,$12,$1,$13}'
} > "$BEST_CSV"
echo
echo "Best-per-(stack,model) CSV: $BEST_CSV"

# ------------- Also write best-by-(host,model) and global-best-by-model -----
BEST_BY_HOST_MODEL_CSV="${ROOT_DIR}/benchmarks.best.by_host_model.csv"
{
  echo "host,model,stack,optimal_tokps,baseline_tokps,optimal_variant,gpu_label,gpu_name,num_gpu,run_ts,csv_file"
  awk -F',' -v ST="$STACK_RE" -v MR="$MODEL_RE" -v GR="$GPU_RE" -v HR="$HOST_RE" '
    NR>1 {
      if (ST!="" && $3 !~ ST) next;
      if (MR!="" && $4 !~ MR) next;
      if (HR!="" && $2 !~ HR) next;
      if (GR!="" && ($10 !~ GR && $11 !~ GR)) next;
      if (!($7+0>0)) next;
      k=$2"|"$4; if ($7+0>best[k]) {best[k]=$7+0; line[k]=$0}
    }
    END{for (k in best){print line[k]}}
  ' "$CSV" \
  | awk -F',' '{printf "%s,%s,%s,%.2f,%.2f,%s,%s,%s,%s,%s,%s\n", $2,$4,$3,$7,$5,$6,$10,$11,$12,$1,$13}'
} > "$BEST_BY_HOST_MODEL_CSV"
echo "Best-by-(host,model) CSV: $BEST_BY_HOST_MODEL_CSV"

BEST_GLOBAL_BY_MODEL_CSV="${ROOT_DIR}/benchmarks.best.by_model.csv"
{
  echo "model,stack,host,optimal_tokps,baseline_tokps,optimal_variant,gpu_label,gpu_name,num_gpu,run_ts,csv_file"
  awk -F',' -v MR="$MODEL_RE" -v GR="$GPU_RE" '
    NR>1 {
      if (MR!="" && $4 !~ MR) next;
      if (GR!="" && ($10 !~ GR && $11 !~ GR)) next;
      if (!($7+0>0)) next;
      k=$4; if ($7+0>best[k]) {best[k]=$7+0; line[k]=$0}
    }
    END{for (k in best){print line[k]}}
  ' "$CSV" \
  | awk -F',' '{printf "%s,%s,%s,%.2f,%.2f,%s,%s,%s,%s,%s,%s\n", $4,$3,$2,$7,$5,$6,$10,$11,$12,$1,$13}'
} > "$BEST_GLOBAL_BY_MODEL_CSV"
echo "Best-global-by-model CSV: $BEST_GLOBAL_BY_MODEL_CSV"
