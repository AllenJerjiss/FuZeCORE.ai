#!/usr/bin/env bash
# summarize-benchmarks.sh — Read LLM/refinery/benchmarks.csv and print best combos
# Sections:
#  - Top N overall by optimal_tokps
#  - Best per (stack, model)
#  - Best per (stack, model, gpu_label)
#  - Best per (host, model) across stacks
#  - Global best per model (across hosts & stacks)
#  - Latest run summary (from aggregate CSV)
#  - Per-stack latest run (raw bench CSVs; header-aware parsing)
#
# Also writes machine-friendly CSVs:
#   factory/LLM/refinery/benchmarks.best.csv
#   factory/LLM/refinery/benchmarks.best.by_host_model.csv
#   factory/LLM/refinery/benchmarks.best.by_model.csv

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
ONLY_TOP=0
QUIET=0

usage(){
  cat <<USAGE
Usage: $(basename "$0") [--csv PATH] [--top N] [--stack REGEX] [--model REGEX] [--gpu REGEX] [--host REGEX] [--md-out FILE] [--no-paths] [--only-global] [--only-top] [--quiet]
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --csv) CSV="$2"; shift 2;;
    --top) TOPN="$2"; shift 2;;
    --stack) STACK_RE="$2"; shift 2;;
    --model) MODEL_RE="$2"; shift 2;;
    --gpu) GPU_RE="$2"; shift 2;;
    --host) HOST_RE="$2"; shift 2;;
    --md-out) MD_OUT="$2"; shift 2;;
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

[ "$QUIET" -eq 0 ] && echo "Data: $CSV"

# ---------- Column width computation (aggregate CSV) ----------
VAR_WIDTH=$(
  awk -F',' -v AP="$ALIAS_PREFIX" '
    function aliasify(s, t){ t=s; gsub(/[\/:]+/,"-",t); gsub(/-it-/,"-i-",t); sub(/-it$/,"-i",t); gsub(/-fp16/,"-f16",t); gsub(/-bf16/,"-b16",t); return t }
    function trim_lead_dash(s){ gsub(/^-+/,"",s); return s }
    function variant(base, ng, gl, st,  ab, sfx, sfx2, va){
      ab=aliasify(base); sfx=ENVIRON["ALIAS_SUFFIX"]; sfx2=trim_lead_dash(sfx);
      if (sfx2!="") va=sprintf("%s%s-%s--%s-%s", AP, st, gl, sfx2, ab);
      else          va=sprintf("%s%s-%s-%s", AP, st, gl, ab);
      if (ng+0>0) va=va "+ng" ng; return va
    }
    NR>1 {
      st=$3; gl=$10; va=variant($4, $12+0, gl, st);
      if (length(va)>mx) mx=length(va)
    }
    END { print (mx>0?mx:40) }
  ' "$CSV"
)
[ -z "$VAR_WIDTH" ] && VAR_WIDTH=40
[ "$VAR_WIDTH" -lt 40 ] && VAR_WIDTH=40

HOSTEP_WIDTH=$(
  awk -F',' '
    NR>1 {
      ep=($9!=""?$9:$8);
      hep=$2;
      if (ep!="") {
        if (ep ~ /:/) hep=hep ":" ep; else hep=hep ":" ep
      }
      if (length(hep)>mx) mx=length(hep)
    }
    END { print (mx>0?mx:22) }
  ' "$CSV"
)
[ -z "$HOSTEP_WIDTH" ] && HOSTEP_WIDTH=22
[ "$HOSTEP_WIDTH" -lt 22 ] && HOSTEP_WIDTH=22

TOK_WIDTH=8                   # numeric column; header "tok/s" fits
BASE_HEADER="base_tok/s"      # your requested header (with extra underscore)
BASE_WIDTH=${#BASE_HEADER}; [ "$BASE_WIDTH" -lt 8 ] && BASE_WIDTH=8

GAIN_HEADER="FuZe-refinery gain factor"
GAIN_WIDTH=${#GAIN_HEADER}    # make header define the width exactly (fix off-by-1)

dashpad(){ printf '%*s' "$1" '' | tr ' ' '-'; }

timestamp_border='---------------------'                  # 19+2
variant_border="$(dashpad $((VAR_WIDTH+2)))"
hostep_border="$(dashpad $((HOSTEP_WIDTH+2)))"
tok_border="$(dashpad $((TOK_WIDTH+2)))"
base_border="$(dashpad $((BASE_WIDTH+2)))"
gain_border="$(dashpad $((GAIN_WIDTH+2)))"

TABLE_BORDER="|${timestamp_border}|${variant_border}|${hostep_border}|${tok_border}|${base_border}|${gain_border}|"
TABLE_BORDER_RALIGN="$TABLE_BORDER"

HEADER_ROW=$(printf \
  "| %-19s | %-${VAR_WIDTH}s | %-${HOSTEP_WIDTH}s | %${TOK_WIDTH}s | %${BASE_WIDTH}s | %${GAIN_WIDTH}s |\n" \
  "timestamp" "variant" "host:endpoint" "tok/s" "$BASE_HEADER" "$GAIN_HEADER")

# Latest run_ts (aggregate CSV)
LATEST_RUN=$(
  awk -F',' 'NR>1 { if ($1>mx) mx=$1 } END { print mx }' "$CSV"
)

# ---------- Row printer for aggregate CSV ----------
print_rows_awktable(){
  awk -F',' \
    -v AP="$ALIAS_PREFIX" \
    -v VAW="$VAR_WIDTH" -v HEW="$HOSTEP_WIDTH" \
    -v TKW="$TOK_WIDTH" -v BAW="$BASE_WIDTH" -v GAINW="$GAIN_WIDTH" '
    function aliasify(s,  t){ t=s; gsub(/[\/:]+/,"-",t); gsub(/-it-/,"-i-",t); sub(/-it$/,"-i",t); gsub(/-fp16/,"-f16",t); gsub(/-bf16/,"-b16",t); return t }
    function trim_lead_dash(s){ gsub(/^-+/,"",s); return s }
    function variant(base, ng, gl, st,  ab, sfx, sfx2, va){
      ab=aliasify(base); sfx=ENVIRON["ALIAS_SUFFIX"]; sfx2=trim_lead_dash(sfx);
      if (sfx2!="") va=sprintf("%s%s-%s--%s-%s", AP, st, gl, sfx2, ab);
      else          va=sprintf("%s%s-%s-%s", AP, st, gl, ab);
      if (ng+0>0) va=va "+ng" ng; return va
    }
    function htime(ts){ return (length(ts)>=15)? sprintf("%s-%s-%s %s:%s:%s", substr(ts,1,4),substr(ts,5,2),substr(ts,7,2),substr(ts,10,2),substr(ts,12,2),substr(ts,14,2)) : ts }
    {
      ts=$1; host=$2; st=$3; model=$4; base=$5+0; opt=$7+0; ep=($9!=""?$9:$8); gl=$10; ng=$12+0;
      va=variant(model, ng, gl, st);
      hep=host; if (ep!="") { if (ep ~ /:/) hep=hep ":" ep; else hep=hep ":" ep }
      gain=(base>0? opt/base : 0);
      printf "| %-19s | %-*s | %-*s | %**.2f | %*.*f | %*.*fx |\n",
        htime(ts), VAW, va, HEW, hep, TKW, 2, opt, BAW, 2, base, GAINW, 2, gain
    }'
}

# ---------- Helper: emit a best-of block with a single border line ----------
emit_best_block(){ # title, awk-filter (produces aggregate-schema lines)
  local title="$1"; shift
  echo
  if [ "$ONLY_GLOBAL" -eq 0 ] && [ "$ONLY_TOP" -eq 0 ]; then
    echo "$title"
    echo "$TABLE_BORDER_RALIGN"
    awk -F',' "$@" "$CSV" | print_rows_awktable
  fi
}

# ---------- Output ----------
echo
if [ "$ONLY_GLOBAL" -eq 0 ]; then
  echo "Top ${TOPN} overall:"
  echo "$TABLE_BORDER"
  echo "$HEADER_ROW"
  echo "$TABLE_BORDER"
  awk -F',' -v ST="$STACK_RE" -v MR="$MODEL_RE" -v GR="$GPU_RE" -v HR="$HOST_RE" '
    NR>1 {
      if (ST!="" && $3 !~ ST) next;
      if (MR!="" && $4 !~ MR) next;
      if (HR!="" && $2 !~ HR) next;
      if (GR!="" && ($10 !~ GR && $11 !~ GR)) next;
      if ($7+0>0) print $0;
    }' "$CSV" \
    | sort -t',' -k7,7gr \
    | awk '!seen[$0]++' \
    | head -n "$TOPN" \
    | print_rows_awktable
fi

emit_best_block "Best per (stack, model):" \
  -v ST="$STACK_RE" -v MR="$MODEL_RE" -v GR="$GPU_RE" -v HR="$HOST_RE" '
  function bestout(){ for (k in best) print line[k] }
  NR>1 {
    if (ST!="" && $3 !~ ST) next;
    if (MR!="" && $4 !~ MR) next;
    if (HR!="" && $2 !~ HR) next;
    if (GR!="" && ($10 !~ GR && $11 !~ GR)) next;
    if (!($7+0>0)) next;
    k=$3"|"$4; if ($7+0>best[k]) {best[k]=$7+0; line[k]=$0}
  } END{ bestout() }'

emit_best_block "Best per (stack, model, gpu_label):" \
  -v ST="$STACK_RE" -v MR="$MODEL_RE" -v GR="$GPU_RE" -v HR="$HOST_RE" '
  function bestout(){ for (k in best) print line[k] }
  NR>1 {
    if (ST!="" && $3 !~ ST) next;
    if (MR!="" && $4 !~ MR) next;
    if (HR!="" && $2 !~ HR) next;
    if (GR!="" && ($10 !~ GR && $11 !~ GR)) next;
    if (!($7+0>0)) next;
    k=$3"|"$4"|"$10; if ($7+0>best[k]) {best[k]=$7+0; line[k]=$0}
  } END{ bestout() }'

emit_best_block "Best per (host, model) across stacks:" \
  -v ST="$STACK_RE" -v MR="$MODEL_RE" -v GR="$GPU_RE" -v HR="$HOST_RE" '
  function bestout(){ for (k in best) print line[k] }
  NR>1 {
    if (ST!="" && $3 !~ ST) next;
    if (MR!="" && $4 !~ MR) next;
    if (HR!="" && $2 !~ HR) next;
    if (GR!="" && ($10 !~ GR && $11 !~ GR)) next;
    if (!($7+0>0)) next;
    k=$2"|"$4; if ($7+0>best[k]) {best[k]=$7+0; line[k]=$0}
  } END{ bestout() }'

if [ "$ONLY_TOP" -eq 0 ]; then
  echo
  echo "Global best per model (across hosts & stacks):"
  echo "$TABLE_BORDER_RALIGN"
  awk -F',' -v MR="$MODEL_RE" -v GR="$GPU_RE" '
    NR>1 {
      if (MR!="" && $4 !~ MR) next;
      if (GR!="" && ($10 !~ GR && $11 !~ GR)) next;
      if (!($7+0>0)) next;
      k=$4; if ($7+0>best[k]) {best[k]=$7+0; line[k]=$0}
    } END{ for (k in best) print line[k] }
  ' "$CSV" | print_rows_awktable
fi

if [ -n "${LATEST_RUN:-}" ] && [ "$QUIET" -eq 0 ]; then
  echo
  echo "Latest run summary (run_ts=$LATEST_RUN):"
  echo "$TABLE_BORDER_RALIGN"
  awk -F',' -v RUN="$LATEST_RUN" 'NR>1 && $1==RUN && ($7+0>0)' "$CSV" \
    | sort -t',' -k7,7gr \
    | head -n "$TOPN" \
    | print_rows_awktable
fi

# ---------- Per-stack latest run (raw bench CSVs; header-aware parsing) ----------
find_bench_csvs(){
  local run="$1"; shift || true
  local dirs=()
  [ -n "${LOG_DIR:-}" ] && dirs+=("$LOG_DIR")
  dirs+=("/var/log/fuze-stack" "${XDG_STATE_HOME:-$HOME/.local/state}/fuze-stack" "$HOME/.fuze/stack/logs")
  local d f
  for d in "${dirs[@]}"; do
    [ -d "$d" ] || continue
    while IFS= read -r -d '' f; do echo "$f"; done < <(find "$d" -maxdepth 1 -type f -name "*_bench_${run}.csv" -print0 2>/dev/null)
  done
}

# Reads a headered CSV and prints aligned rows.
# If called with no argument, reads from stdin (works in pipelines).
print_rows_from_headered_csv(){ # [file]
  local src="${1:-/dev/stdin}"
  awk -F',' -v AP="$ALIAS_PREFIX" \
      -v VAW="$VAR_WIDTH" -v HEW="$HOSTEP_WIDTH" -v TKW="$TOK_WIDTH" -v BAW="$BASE_WIDTH" -v GAINW="$GAIN_WIDTH" '
    function aliasify(s,  t){ t=s; gsub(/[\/:]+/,"-",t); gsub(/-it-/,"-i-",t); sub(/-it$/,"-i",t); gsub(/-fp16/,"-f16",t); gsub(/-bf16/,"-b16",t); return t }
    function trim_lead_dash(s){ gsub(/^-+/,"",s); return s }
    function variant_build(model, ng, gl, st,  ab, sfx, sfx2, va){
      ab=aliasify(model); sfx=ENVIRON["ALIAS_SUFFIX"]; sfx2=trim_lead_dash(sfx);
      if (sfx2!="") va=sprintf("%s%s-%s--%s-%s", AP, st, gl, sfx2, ab);
      else          va=sprintf("%s%s-%s-%s", AP, st, gl, ab);
      if (ng+0>0) va=va "+ng" ng; return va
    }
    function htime(ts){ return (length(ts)>=15)? sprintf("%s-%s-%s %s:%s:%s", substr(ts,1,4),substr(ts,5,2),substr(ts,7,2),substr(ts,10,2),substr(ts,12,2),substr(ts,14,2)) : ts }

    NR==1{
      # map headers
      for(i=1;i<=NF;i++){
        h=$i; gsub(/^[ \t]+|[ \t]+$/,"",h); h=tolower(h)
        if(h~/(^|_)run(_)?ts|timestamp$/)                          IDX_TS=i
        else if(h~/^host(name)?$/)                                 IDX_HOST=i
        else if(h~/^(endpoint|addr(ess)?|address|port)$/)          IDX_EP=i
        else if(h~/^stack$/)                                       IDX_STACK=i
        else if(h~/^model$/)                                       IDX_MODEL=i
        else if(h~/(^|_)optimal(_)?tokps$|^tokps(_opt)?$/)         IDX_OPT=i
        else if(h~/(^|_)baseline(_)?tokps$|^base(_)?tokps$|^tokps_base$/) IDX_BASE=i
        else if(h~/^gpu(_)?label$|^gpu$/)                          IDX_GL=i
        else if(h~/^(num_)?gpu(s)?$|^ng$/)                         IDX_NG=i
        else if(h~/^(optimal_)?variant$/)                          IDX_VAR=i
      }
      next
    }
    {
      ts    = (IDX_TS?   $IDX_TS   : $1)
      host  = (IDX_HOST? $IDX_HOST : $2)
      ep    = (IDX_EP?   $IDX_EP   : "")
      st    = (IDX_STACK?$IDX_STACK: ($3!=""?$3:""))
      model = (IDX_MODEL?$IDX_MODEL: ($4!=""?$4:""))
      opt   = (IDX_OPT?  $IDX_OPT+0: ($7+0))
      base  = (IDX_BASE? $IDX_BASE+0: ($5+0))
      gl    = (IDX_GL?   $IDX_GL   : ($10!=""?$10:""))
      ng    = (IDX_NG?   $IDX_NG+0 : ($12+0))
      var   = (IDX_VAR?  $IDX_VAR  : variant_build(model, ng, gl, st))

      hep = host
      if (ep!="") {
        if (ep ~ /:/) hep = host ":" ep; else hep = host ":" ep
      }

      gain=(base>0? opt/base : 0);
      printf "| %-19s | %-*s | %-*s | %*.*f | %*.*f | %*.*fx |\n",
        htime(ts), VAW, var, HEW, hep, TKW, 2, opt, BAW, 2, base, GAINW, 2, gain
    }' "$src"
}

if [ -n "${LATEST_RUN:-}" ]; then
  mapfile -t LATEST_BENCH_CSVS < <(find_bench_csvs "$LATEST_RUN")
  if [ "${#LATEST_BENCH_CSVS[@]}" -gt 0 ]; then
    echo
    echo "Per-stack latest run (raw bench CSVs):"
    echo "$TABLE_BORDER_RALIGN"
    for f in "${LATEST_BENCH_CSVS[@]}"; do
      [ -f "$f" ] || continue
      # Prefer rows for LATEST_RUN if present
      if awk -F',' -v RUN="$LATEST_RUN" 'NR>1 && $1==RUN{found=1; exit} END{exit(!found)}' "$f"; then
        awk -F',' -v RUN="$LATEST_RUN" 'NR==1{print;next} $1==RUN{print}' "$f" \
          | sort -t',' -k7,7gr 2>/dev/null | head -n "$TOPN" | print_rows_from_headered_csv
      else
        # Fallback: just take top rows by column 7 (best-effort)
        awk 'NR==1 || NR>1' "$f" | sort -t',' -k7,7gr 2>/dev/null | head -n "$TOPN" | print_rows_from_headered_csv
      fi
    done
  fi
fi

# ---------- CSV exports (unchanged schema) ----------
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
      k=$3"|"$4; if ($7+0>best[k]) {best[k]=$7+0; line[k]=$0}
    }
    END{for (k in best){print line[k]}}
  ' "$CSV" \
  | awk -F',' '{printf "%s,%s,%s,%.2f,%.2f,%s,%s,%s,%s,%s,%s\n", $3,$4,$2,$7,$5,$6,$10,$11,$12,$1,$13}'
} > "$BEST_CSV"
echo
[ "$NO_PATHS" -eq 0 ] && echo "Best-per-(stack,model) CSV: $BEST_CSV"

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
[ "$NO_PATHS" -eq 0 ] && echo "Best-by-(host,model) CSV: $BEST_BY_HOST_MODEL_CSV"

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
[ "$NO_PATHS" -eq 0 ] && echo "Best-global-by-model CSV: $BEST_GLOBAL_BY_MODEL_CSV"

