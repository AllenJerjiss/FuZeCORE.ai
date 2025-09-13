#!/usr/bin/env bash
# summarize-benchmarks.sh — Read fuze-box/benchmarks.csv and print best combos
# Sections:
#  - Top N overall by optimal_tokps
#  - Best per (stack, model)
#  - Best per (stack, model, gpu_label)
# Also writes a machine-friendly CSV of best per (stack, model): fuze-box/benchmarks.best.csv

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"   # fuze-box

CSV="${CSV:-${ROOT_DIR}/benchmarks.csv}"
TOPN="${TOPN:-10}"

usage(){
  cat <<USAGE
Usage: $(basename "$0") [--csv PATH] [--top N]
Env: CSV (default: fuze-box/benchmarks.csv), TOPN (default: 10)
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

echo "Data: $CSV"

# ------------- Top N overall by optimal_tokps -------------------------------
echo
echo "Top ${TOPN} overall (by optimal_tokps):"
awk -F',' 'NR>1 && $7+0>0 {printf "%s,%s,%s,%.2f,%s,%s,%s\n", $3,$4,$2,$7,$10,$11,$1}' "$CSV" \
  | sort -t',' -k4,4gr | head -n "$TOPN" \
  | awk -F',' '{printf "  %-7s %-26s %-21s %8.2f  %-16s %-18s %s\n", $1,$2,$3,$4,$5,$6,$7}'

# ------------- Best per (stack, model) --------------------------------------
echo
echo "Best per (stack, model):"
awk -F',' '
  NR>1 && $7+0>0 {
    k=$3"|"$4
    if ($7+0>best[k]) {best[k]=$7+0; line[k]=$0}
  }
  END{
    for (k in best){print line[k]}
  }
' "$CSV" \
 | awk -F',' '{printf "%s,%s,%s,%.2f,%s,%s,%s\n", $3,$4,$2,$7,$10,$11,$1}' \
 | sort -t',' -k1,1 -k2,2 \
 | awk -F',' '{printf "  %-7s %-26s %-21s %8.2f  %-16s %-18s %s\n", $1,$2,$3,$4,$5,$6,$7}'

# ------------- Best per (stack, model, gpu_label) ---------------------------
echo
echo "Best per (stack, model, gpu_label):"
awk -F',' '
  NR>1 && $7+0>0 {
    k=$3"|"$4"|"$10
    if ($7+0>best[k]) {best[k]=$7+0; line[k]=$0}
  }
  END{
    for (k in best){print line[k]}
  }
' "$CSV" \
 | awk -F',' '{printf "%s,%s,%s,%.2f,%s,%s,%s\n", $3,$4,$10,$7,$2,$11,$1}' \
 | sort -t',' -k1,1 -k2,2 -k3,3 \
 | awk -F',' '{printf "  %-7s %-26s %-14s %8.2f  %-21s %-18s %s\n", $1,$2,$3,$4,$5,$6,$7}'

# ------------- Write best-per-(stack,model) CSV -----------------------------
BEST_CSV="${ROOT_DIR}/benchmarks.best.csv"
{
  echo "stack,model,host,optimal_tokps,baseline_tokps,optimal_variant,gpu_label,gpu_name,num_gpu,run_ts,csv_file"
  awk -F',' 'NR>1 && $7+0>0 {k=$3"|"$4; if ($7+0>best[k]) {best[k]=$7+0; line[k]=$0; base[k]=$5}} END{for (k in best){print line[k]}}' "$CSV" \
  | awk -F',' '{printf "%s,%s,%s,%.2f,%.2f,%s,%s,%s,%s,%s,%s\n", $3,$4,$2,$7,$5,$6,$10,$11,$12,$1,$13}'
} > "$BEST_CSV"
echo
echo "Best-per-(stack,model) CSV: $BEST_CSV"

