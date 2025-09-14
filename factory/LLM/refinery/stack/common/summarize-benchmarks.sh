#!/usr/bin/env bash
# summarize-benchmarks.sh — Read LLM/refinery/benchmarks.csv and print best combos
# Also: prints latest-run sections and (if available) per-stack raw bench CSVs.

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

[ -f "$CSV" ] || { echo "No data: $CSV not found" >&2; exit 1; }

if [ -n "$MD_OUT" ]; then
  mkdir -p "$(dirname "$MD_OUT")" 2>/dev/null || true
  : > "$MD_OUT"
  exec > >(tee "$MD_OUT")
fi

[ "$QUIET" -eq 0 ] && echo "Data: $CSV"

# ---------- width helpers (variant, host:endpoint, numeric headers) ----------
aliasify() { :; } # placeholder for readability in awk blocks

# Dynamic variant width from the aggregate CSV
VAR_WIDTH=$(
  awk -F',' -v AP="$ALIAS_PREFIX" '
  function aliasify(s, t){ t=s; gsub(/[\/:]+/,"-",t); gsub(/-it-/,"-i-",t); sub(/-it$/,"-i",t); gsub(/-fp16/,"-f16",t); gsub(/-bf16/,"-b16",t); return t }
  function trim_lead_dash(s){ gsub(/^-+/,"",s); return s }
  function variant(base, ng, gl, st,  ab, sfx, sfx2, va){
    ab=aliasify(base); sfx=ENVIRON["ALIAS_SUFFIX"]; sfx2=trim_lead_dash(sfx);
    if (sfx2!="") va=sprintf("%s%s-%s--%s-%s", AP, st, gl, sfx2, ab);
    else          va=sprintf("%s%s-%s-%s", AP, st, gl, ab);
    if (ng+0>0) va=va "+ng" ng;
    return va
  }
  NR>1 { st=$3; gl=$10; va=variant($4, $12+0, gl, st); if (length(va)>mx) mx=length(va) }
  END { print (mx>0?mx:40) }
' "$CSV")
[ "$VAR_WIDTH" -lt 40 ] && VAR_WIDTH=40

# Dynamic host:endpoint width
HOSTEP_WIDTH=$(
  awk -F',' '
  NR>1 { ep=($9!=""?$9:$8); hep=$2 ((ep!="")? ":" ep : ""); if (length(hep)>mx) mx=length(hep) }
  END { print (mx>0?mx:22) }
' "$CSV")
[ "$HOSTEP_WIDTH" -lt 22 ] && HOSTEP_WIDTH=22

# Numeric headers and borders
GAIN_HEADER="FuZe-refinery gain factor"
BASE_HEADER="base_tok/s"
TOK_HEADER="tok/s"

# Floor widths
GAIN_WIDTH_DEFAULT=17
BASE_WIDTH_DEFAULT=8

# choose widths so header fits exactly; rows are right-aligned within same width
GAIN_WIDTH="${GAIN_WIDTH_DEFAULT}"
[ "${#GAIN_HEADER}" -gt "$GAIN_WIDTH" ] && GAIN_WIDTH="${#GAIN_HEADER}"

BASE_WIDTH="${BASE_WIDTH_DEFAULT}"
[ "${#BASE_HEADER}" -gt "$BASE_WIDTH" ] && BASE_WIDTH="${#BASE_HEADER}"

# Borders (dash count = column width + 2 spaces)
dashpad(){ printf '%*s' "$1" '' | tr ' ' '-'; }
timestamp_border='---------------------'                  # 19 + 2
variant_border="$(dashpad $((VAR_WIDTH+2)))"
hostep_border="$(dashpad $((HOSTEP_WIDTH+2)))"
tok_border="$(dashpad $((8+2)))"
base_border="$(dashpad $((BASE_WIDTH+2)))"
gain_border="$(dashpad $((GAIN_WIDTH+2)))"

TABLE_BORDER="|${timestamp_border}|${variant_border}|${hostep_border}|${tok_border}|${base_border}|${gain_border}|"
TABLE_BORDER_RALIGN="$TABLE_BORDER"  # use uniform dashed border everywhere

HEADER_ROW=$(printf \
  "| %-19s | %-${VAR_WIDTH}s | %-${HOSTEP_WIDTH}s | %8s | %${BASE_WIDTH}s | %${GAIN_WIDTH}s |\n" \
  "timestamp" "variant" "host:endpoint" "$TOK_HEADER" "$BASE_HEADER" "$GAIN_HEADER")

# Latest run id from aggregate
LATEST_RUN=$(
  awk -F',' 'NR>1 { if ($1>mx) mx=$1 } END { print mx }' "$CSV"
)

# ---------- Reusable awk printer (same formatting everywhere) ----------
print_rows_awktable(){ # usage: print_rows_awktable <stdin rows CSV schema>
  awk -F',' -v AP="$ALIAS_PREFIX" -v VAW="$VAR_WIDTH" -v HEW="$HOSTEP_WIDTH" -v BAW="$BASE_WIDTH" -v GAINW="$GAIN_WIDTH" '
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
      ts=$1; host=$2; st=$3; model=$4;
      base=$5+0; opt=$7+0; ep=($9!=""?$9:$8); gl=$10; ng=$12+0;
      gain=(base>0? opt/base : 0);
      va=variant(model, ng, gl, st);
      hep=host ((ep!="")? ":" ep : "");
      printf "| %-19s | %-*s | %-*s | %8.2f | %*.2f | %*.2fx |\n",
        htime(ts), VAW, va, HEW, hep, opt, BAW, base, GAINW, gain
    }'
}

# ================= Top N overall =================
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

emit_best_block(){ # title, key AWK, filter args...
  local title="$1"; shift
  echo
  if [ "$ONLY_GLOBAL" -eq 0 ] && [ "$ONLY_TOP" -eq 0 ]; then
    echo "$title"
    echo "$TABLE_BORDER_RALIGN"
    awk -F',' "$@" "$CSV" | print_rows_awktable
  fi
}

# =============== Best per (stack, model) ===============
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

# =============== Best per (stack, model, gpu_label) ===============
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

# =============== Best per (host, model) across stacks ===============
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

# =============== Global best per model ===============
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

# =============== Latest run section (from aggregate) ===============
if [ -n "${LATEST_RUN:-}" ] && [ "$QUIET" -eq 0 ]; then
  echo
  echo "Latest run summary (run_ts=$LATEST_RUN):"
  echo "$TABLE_BORDER_RALIGN"
  awk -F',' -v RUN="$LATEST_RUN" 'NR>1 && $1==RUN && ($7+0>0)' "$CSV" \
    | sort -t',' -k7,7gr \
    | head -n "$TOPN" \
    | print_rows_awktable
fi

# =============== Per-stack latest run (raw bench CSVs) ===============
# Find per-run bench CSVs for LATEST_RUN in LOG_DIR (if exported) or known defaults.
find_bench_csvs(){
  local run="$1"; shift
  local dirs=()
  [ -n "${LOG_DIR:-}" ] && dirs+=("$LOG_DIR")
  dirs+=("/var/log/fuze-stack" "${XDG_STATE_HOME:-$HOME/.local/state}/fuze-stack" "$HOME/.fuze/stack/logs")
  local f; for d in "${dirs[@]}"; do
    [ -d "$d" ] || continue
    # prefer exact run match, else newest files
    while IFS= read -r -d '' f; do echo "$f"; done < <(find "$d" -maxdepth 1 -type f -name "*_bench_${run}.csv" -print0 2>/dev/null)
  done
}

if [ -n "${LATEST_RUN:-}" ]; then
  mapfile -t LATEST_BENCH_CSVS < <(find_bench_csvs "$LATEST_RUN")
  if [ "${#LATEST_BENCH_CSVS[@]}" -eq 0 ]; then
    # fallback: take newest bench CSV in any known dir
    mapfile -t LATEST_BENCH_CSVS < <(
      for d in "${LOG_DIR:-/var/log/fuze-stack}" "${XDG_STATE_HOME:-$HOME/.local/state}/fuze-stack" "$HOME/.fuze/stack/logs"; do
        [ -d "$d" ] || continue
        ls -t "$d"/*_bench_*.csv 2>/dev/null || true
      done | awk 'NR==1,NR==3'  # up to 3 recent CSVs
    )
  fi

  if [ "${#LATEST_BENCH_CSVS[@]}" -gt 0 ]; then
    echo
    echo "Per-stack latest run (raw bench CSVs):"
    echo "$TABLE_BORDER_RALIGN"
    # Each per-stack CSV is expected to share the same schema columns as aggregate
    for f in "${LATEST_BENCH_CSVS[@]}"; do
      [ -f "$f" ] || continue
      # Filter to LATEST_RUN rows if the file is multi-run, else just take top by optimal tok/s
      awk -F',' -v RUN="$LATEST_RUN" 'NR==1{hdr=$0;next} {if ($1==RUN) print $0}' "$f" \
        | ( [ -s /dev/stdin ] && cat || awk 'NR>1{print $0}' "$f" ) \
        | sort -t',' -k7,7gr \
        | head -n "$TOPN" \
        | print_rows_awktable
    done
  fi
fi

# ======================= CSV exports (unchanged) ============================
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

