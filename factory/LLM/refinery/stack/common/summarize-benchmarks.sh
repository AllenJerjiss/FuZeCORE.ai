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
ALIAS_PREFIX="${ALIAS_PREFIX:-LLM-FuZe-}"
NO_PATHS=0
ONLY_GLOBAL=0
QUIET=0
ONLY_TOP=0

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
    --no-paths) NO_PATHS=1; shift 1;;
    --only-global) ONLY_GLOBAL=1; shift 1;;
    --only-top) ONLY_TOP=1; shift 1;;
    --quiet) QUIET=1; shift 1;;
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

if [ "$QUIET" -eq 0 ]; then echo "Data: $CSV"; fi

# ----------------------------------------------------------------------
# Dynamically size the variant column based on the widest variant emitted.
# This scans the input CSV using the same alias/variant logic as below
# to compute the maximum variant string length.  If no records are found,
# a fallback of 40 characters is used.  The resulting width is used to
# build table borders and header rows, and passed into awk via VAW.
VAR_WIDTH=$(awk -F',' -v AP="$ALIAS_PREFIX" '
function aliasify(s, t) {
  t = s;
  gsub(/[\/:]+/, "-", t);
  gsub(/-it-/, "-i-", t); sub(/-it$/, "-i", t);
  gsub(/-fp16/, "-f16", t); gsub(/-bf16/, "-b16", t);
  return t;
}
function trim_lead_dash(s){ gsub(/^-+/, "", s); return s }
function variant(base, ng, gl, st,  ab, sfx, sfx2, va) {
  ab = aliasify(base);
  sfx = ENVIRON["ALIAS_SUFFIX"];
  sfx2 = trim_lead_dash(sfx);
  if (sfx2 != "") va = sprintf("%s%s-%s--%s-%s", AP, st, gl, sfx2, ab);
  else            va = sprintf("%s%s-%s-%s", AP, st, gl, ab);
  if (ng + 0 > 0) va = va "+ng" ng;
  return va;
}
NR > 1 {
  st = $3;
  gl = $10;
  va = variant($4, $12 + 0, gl, st);
  if (length(va) > max_len) max_len = length(va);
}
END {
  print max_len;
}' "$CSV")
# Ensure a sensible minimum width
[ -z "$VAR_WIDTH" ] && VAR_WIDTH=40
if [ "$VAR_WIDTH" -lt 40 ]; then VAR_WIDTH=40; fi

# Construct table border and header strings with dynamic variant width.
# The timestamp column is always 19 chars wide plus 2 spaces (21 dashes).
timestamp_border='---------------------'
# The variant border is sized to the variant width plus two spaces.
variant_border=$(printf '%*s' "$((VAR_WIDTH + 2))" '' | tr ' ' '-')
host_border='----------------------'
endpoint_border='----------------------'
tok_border='---------'
base_border='----------'
gain_border='------------------'

# Border without right-alignment colons (used for Top N section)
TABLE_BORDER="|${timestamp_border}|${variant_border}|${host_border}|${endpoint_border}|${tok_border}|${base_border}|${gain_border}|"
# Border with right-alignment colons (used for the grouped sections)
TABLE_BORDER_RALIGN="|${timestamp_border}|${variant_border}|${host_border}|${endpoint_border}|${tok_border}:|${base_border}:|${gain_border}:|"

# Header row with dynamic variant width. Numeric headers use default widths.
HEADER_ROW=$(printf "| %-19s | %-${VAR_WIDTH}s | %-20s | %-20s | %8s | %8s | %17s |\n" \
  "timestamp" "variant" "host" "endpoint" "tok/s" "base_t/s" "FuZe-refinery gain factor")

# ------------- Top N overall by optimal_tokps -------------------------------
echo
if [ "$ONLY_GLOBAL" -eq 0 ]; then
  echo "Top ${TOPN} overall:"
  # Pretty table header (stack folded into variant) with dynamic widths
  echo "$TABLE_BORDER"
  echo "$HEADER_ROW"
  echo "$TABLE_BORDER"
  awk -F',' -v ST="$STACK_RE" -v MR="$MODEL_RE" -v GR="$GPU_RE" -v HR="$HOST_RE" 'NR>1 {
      if (ST!="" && $3 !~ ST) next;
      if (MR!="" && $4 !~ MR) next;
      if (HR!="" && $2 !~ HR) next;
      if (GR!="" && ($10 !~ GR && $11 !~ GR)) next;
      if ($7+0>0) print $0;
    }' "$CSV" \
    | sort -t',' -k7,7gr \
    | awk '!seen[$0]++' \
    | head -n "$TOPN" \
    | awk -F',' -v AP="$ALIAS_PREFIX" -v VAW="$VAR_WIDTH" '
        function aliasify(s,  t){
          t=s; gsub(/[\/:]+/,"-",t);
          gsub(/-it-/,"-i-",t); sub(/-it$/,"-i",t);
          gsub(/-fp16/,"-f16",t); gsub(/-bf16/,"-b16",t);
          return t
        }
        function trim_lead_dash(s){ gsub(/^-+/,"",s); return s }
        function variant(base, ng, gl, st,  ab, sfx, sfx2, va){
          ab=aliasify(base); sfx=ENVIRON["ALIAS_SUFFIX"]; sfx2=trim_lead_dash(sfx);
          # embed stack into variant
          if (sfx2!="") va=sprintf("%s%s-%s--%s-%s", AP, st, gl, sfx2, ab);
          else           va=sprintf("%s%s-%s-%s", AP, st, gl, ab);
          if (ng+0>0) va=va "+ng" ng;
          return va
        }
        function htime(ts){ return (length(ts)>=15)? sprintf("%s-%s-%s %s:%s:%s", substr(ts,1,4),substr(ts,5,2),substr(ts,7,2),substr(ts,10,2),substr(ts,12,2),substr(ts,14,2)) : ts }
        {
          st=$3; ep=($9!=""?$9:"n/a"); ng=($12+0); gl=$10; va=variant($4, ng, gl, st);
          base=$5+0; opt=$7+0; x=(base>0? opt/base : 0);
          printf "| %-19s | %-" VAW "s | %-20s | %-20s | %8.2f | %8.2f | %17.2fx |\n",
            htime($1), va, $2, ep, opt, base, x
        }'
fi

# ------------- Best per (stack, model) --------------------------------------
echo
if [ "$ONLY_GLOBAL" -eq 0 ] && [ "$ONLY_TOP" -eq 0 ]; then
  echo "Best per (stack, model):"
  echo "$TABLE_BORDER_RALIGN"
  echo "$HEADER_ROW"
  echo "$TABLE_BORDER_RALIGN"
  awk -F',' -v ST="$STACK_RE" -v MR="$MODEL_RE" -v GR="$GPU_RE" -v HR="$HOST_RE" -v AP="$ALIAS_PREFIX" '
    function aliasify(s,  t){
      t=s; gsub(/[\/:]+/,"-",t);
      gsub(/-it-/,"-i-",t); sub(/-it$/,"-i",t);
      gsub(/-fp16/,"-f16",t); gsub(/-bf16/,"-b16",t);
      return t
    }
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
   | awk -F',' -v AP="$ALIAS_PREFIX" -v VAW="$VAR_WIDTH" '
       function aliasify(s,  t){ t=s; gsub(/[\/:]+/,"-",t); gsub(/-it-/,"-i-",t); sub(/-it$/,"-i",t); gsub(/-fp16/,"-f16",t); gsub(/-bf16/,"-b16",t); return t }
       function trim_lead_dash(s){ gsub(/^-+/,"",s); return s }
       function variant(base, ng, gl, st,  ab, sfx, sfx2, va){ ab=aliasify(base); sfx=ENVIRON["ALIAS_SUFFIX"]; sfx2=trim_lead_dash(sfx); if(sfx2!="") va=sprintf("%s%s-%s--%s-%s", AP, st, gl, sfx2, ab); else va=sprintf("%s%s-%s-%s", AP, st, gl, ab); if(ng+0>0) va=va "+ng" ng; return va }
       function htime(ts){ return (length(ts)>=15)? sprintf("%s-%s-%s %s:%s:%s", substr(ts,1,4),substr(ts,5,2),substr(ts,7,2),substr(ts,10,2),substr(ts,12,2),substr(ts,14,2)) : ts }
       {
         ts=$1; st=$3; host=$2; ep=($9!=""?$9:$8); ng=($12+0); gl=$10; base=$5+0; opt=$7+0; x=(base>0 ? opt/base : 0);
         va=variant($4, ng, gl, st);
         printf "| %-19s | %-" VAW "s | %-20s | %-20s | %8.2f | %8.2f | %17.2fx |\n", htime(ts), va, host, ep, opt, base, x
       }'
fi

# ------------- Best per (stack, model, gpu_label) ---------------------------
echo
if [ "$ONLY_GLOBAL" -eq 0 ] && [ "$ONLY_TOP" -eq 0 ]; then
  echo "Best per (stack, model, gpu_label):"
  echo "$TABLE_BORDER_RALIGN"
  echo "$HEADER_ROW"
  echo "$TABLE_BORDER_RALIGN"
  awk -F',' -v ST="$STACK_RE" -v MR="$MODEL_RE" -v GR="$GPU_RE" -v HR="$HOST_RE" -v AP="$ALIAS_PREFIX" '
    function aliasify(s,  t){ t=s; gsub(/[\/:]+/,"-",t); gsub(/-it-/,"-i-",t); sub(/-it$/,"-i",t); gsub(/-fp16/,"-f16",t); gsub(/-bf16/,"-b16",t); return t }
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
   | awk -F',' -v AP="$ALIAS_PREFIX" -v VAW="$VAR_WIDTH" '
       function aliasify(s,  t){ t=s; gsub(/[\/:]+/,"-",t); gsub(/-it-/,"-i-",t); sub(/-it$/,"-i",t); gsub(/-fp16/,"-f16",t); gsub(/-bf16/,"-b16",t); return t }
       function trim_lead_dash(s){ gsub(/^-+/,"",s); return s }
       function variant(base, ng, gl, st,  ab, sfx, sfx2, va){ ab=aliasify(base); sfx=ENVIRON["ALIAS_SUFFIX"]; sfx2=trim_lead_dash(sfx); if(sfx2!="") va=sprintf("%s%s-%s--%s-%s", AP, st, gl, sfx2, ab); else va=sprintf("%s%s-%s-%s", AP, st, gl, ab); if(ng+0>0) va=va "+ng" ng; return va }
       function htime(ts){ return (length(ts)>=15)? sprintf("%s-%s-%s %s:%s:%s", substr(ts,1,4),substr(ts,5,2),substr(ts,7,2),substr(ts,10,2),substr(ts,12,2),substr(ts,14,2)) : ts }
       {
         ts=$1; st=$3; host=$2; ep=($9!=""?$9:$8); ng=($12+0); gl=$10; base=$5+0; opt=$7+0; x=(base>0 ? $7/$5 : 0);
         va=variant($4, ng, gl, st);
         printf "| %-19s | %-" VAW "s | %-20s | %-20s | %8.2f | %8.2f | %17.2fx |\n", htime(ts), va, host, ep, opt, base, x
       }'
fi

# ------------- Best per (host, model) across stacks -------------------------
echo
if [ "$ONLY_GLOBAL" -eq 0 ] && [ "$ONLY_TOP" -eq 0 ]; then
  echo "Best per (host, model) across stacks:"
  echo "$TABLE_BORDER_RALIGN"
  echo "$HEADER_ROW"
  echo "$TABLE_BORDER_RALIGN"
  awk -F',' -v ST="$STACK_RE" -v MR="$MODEL_RE" -v GR="$GPU_RE" -v HR="$HOST_RE" -v AP="$ALIAS_PREFIX" '
    function aliasify(s,  t){ t=s; gsub(/[\/:]+/,"-",t); gsub(/-it-/,"-i-",t); sub(/-it$/,"-i",t); gsub(/-fp16/,"-f16",t); gsub(/-bf16/,"-b16",t); return t }
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
   | awk -F',' -v AP="$ALIAS_PREFIX" -v VAW="$VAR_WIDTH" '
       function aliasify(s,  t){ t=s; gsub(/[\/:]+/,"-",t); gsub(/-it-/,"-i-",t); sub(/-it$/,"-i",t); gsub(/-fp16/,"-f16",t); gsub(/-bf16/,"-b16",t); return t }
       function trim_lead_dash(s){ gsub(/^-+/,"",s); return s }
       function variant(base, ng, gl, st,  ab, sfx, sfx2, va){ ab=aliasify(base); sfx=ENVIRON["ALIAS_SUFFIX"]; sfx2=trim_lead_dash(sfx); va=sprintf("%s%s-%s-%s", AP, st, gl, ab); if(sfx2!="") va=sprintf("%s%s--%s-%s", AP, st, gl, ab); if(ng+0>0) va=va "+ng" ng; return va }
       function htime(ts){ return (length(ts)>=15)? sprintf("%s-%s-%s %s:%s:%s", substr(ts,1,4),substr(ts,5,2),substr(ts,7,2),substr(ts,10,2),substr(ts,12,2),substr(ts,14,2)) : ts }
       {
         ts=$1; host=$2; st=$3; ep=($9!=""?$9:$8); ng=($12+0); gl=$10; base=$5+0; opt=$7+0; x=(base>0 ? $7/$5 : 0);
         va=variant($4, ng, gl, st);
         printf "| %-19s | %-" VAW "s | %-20s | %-20s | %8.2f | %8.2f | %17.2fx |\n", htime(ts), va, host, ep, opt, base, x
       }'
fi

# ------------- Global best per model (across hosts & stacks) ----------------
if [ "$ONLY_TOP" -eq 0 ]; then
  echo
  echo "Global best per model (across hosts & stacks):"
  echo "$TABLE_BORDER_RALIGN"
  echo "$HEADER_ROW"
  echo "$TABLE_BORDER_RALIGN"
  awk -F',' -v MR="$MODEL_RE" -v GR="$GPU_RE" -v AP="$ALIAS_PREFIX" '
    NR>1 {
      if (MR!="" && $4 !~ MR) next;
      if (GR!="" && ($10 !~ GR && $11 !~ GR)) next;
      if (!($7+0>0)) next;
      k=$4; if ($7+0>best[k]) {best[k]=$7+0; line[k]=$0}
    }
    END{for (k in best){print line[k]}}
  ' "$CSV" \
   | awk -F',' -v AP="$ALIAS_PREFIX" -v VAW="$VAR_WIDTH" '
       function aliasify(s,  t){ t=s; gsub(/[\/:]+/,"-",t); gsub(/-it-/,"-i-",t); sub(/-it$/,"-i",t); gsub(/-fp16/,"-f16",t); gsub(/-bf16/,"-b16",t); return t }
       function trim_lead_dash(s){ gsub(/^-+/,"",s); return s }
       function variant(base, ng, gl, st,  ab, sfx, sfx2, va){ ab=aliasify(base); sfx=ENVIRON["ALIAS_SUFFIX"]; sfx2=trim_lead_dash(sfx); if(sfx2!="") va=sprintf("%s%s-%s--%s-%s", AP, st, gl, sfx2, ab); else va=sprintf("%s%s-%s-%s", AP, st, gl, ab); if(ng+0>0) va=va "+ng" ng; return va }
       function htime(ts){ return (length(ts)>=15)? sprintf("%s-%s-%s %s:%s:%s", substr(ts,1,4),substr(ts,5,2),substr(ts,7,2),substr(ts,10,2),substr(ts,12,2),substr(ts,14,2)) : ts }
       {
         ts=$1; st=$3; host=$2; ep=($9!=""?$9:$8); ng=($12+0); gl=$10; base=$5+0; opt=$7+0; x=(base>0?opt/base:0);
         va=variant($4, ng, gl, st);
         printf "| %-19s | %-" VAW "s | %-20s | %-20s | %8.2f | %8.2f | %17.2fx |\n", htime(ts), va, host, ep, opt, base, x
       }'
fi

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
if [ "$NO_PATHS" -eq 0 ]; then echo "Best-per-(stack,model) CSV: $BEST_CSV"; fi

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
if [ "$NO_PATHS" -eq 0 ]; then echo "Best-by-(host,model) CSV: $BEST_BY_HOST_MODEL_CSV"; fi

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
if [ "$NO_PATHS" -eq 0 ]; then echo "Best-global-by-model CSV: $BEST_GLOBAL_BY_MODEL_CSV"; fi
