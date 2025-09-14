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
NO_PATHS=1
ONLY_GLOBAL=0
QUIET=1
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

# ------------- Top N overall by optimal_tokps -------------------------------
#
if [ "$ONLY_GLOBAL" -eq 0 ]; then
  echo "Top ${TOPN} overall:"
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
    | awk -F',' -v AP="$ALIAS_PREFIX" '
        function aliasify(s,  t){ t=s; gsub(/[\/:]+/,"-",t); gsub(/-it-/,"-i-",t); sub(/-it$/,"-i",t); gsub(/-fp16/,"-f16",t); gsub(/-bf16/,"-b16",t); return t }
        function trim_lead_dash(s){ gsub(/^-+/,"",s); return s }
        function variant(base, ng, gl, st,  ab, sfx, sfx2, va){
          ab=aliasify(base); sfx=ENVIRON["ALIAS_SUFFIX"]; sfx2=trim_lead_dash(sfx);
          if (sfx2!="") va=sprintf("%s%s-%s--%s-%s", AP, st, gl, sfx2, ab); else va=sprintf("%s%s-%s-%s", AP, st, gl, ab);
          if (ng+0>0) va=va "+ng" ng; return va }
        function htime(ts){ return (length(ts)>=15)? sprintf("%s-%s-%s %s:%s:%s", substr(ts,1,4),substr(ts,5,2),substr(ts,7,2),substr(ts,10,2),substr(ts,12,2),substr(ts,14,2)) : ts }
        function rep(n, c,  s){ s=""; for(i=0;i<n;i++) s=s c; return s }
        function dline(w, r){ return rep(w, "-") }
        {
          st=$3; ep=($9!=""?$9:$8); ng=($12+0); gl=$10; va=variant($4, ng, gl, st);
          ts=htime($1); he=$2 "/" ep;
          tok=sprintf("%.2f", $7+0); base=sprintf("%.2f", $5+0); gain=sprintf("%.2fx", ($5+0>0?($7+0)/($5+0):0));
          n++; TS[n]=ts; VA[n]=va; HE[n]=he; TK[n]=tok; BA[n]=base; GA[n]=gain;
          if(length(ts)>TW) TW=length(ts); if(length(va)>VW) VW=length(va); if(length(he)>HW) HW=length(he);
          if(length(tok)>KW) KW=length(tok); if(length(base)>BW) BW=length(base); if(length(gain)>GW) GW=length(gain);
        }
        END{
          # header labels
          h1="timestamp"; h2="variant"; h3="host"; h4="tok/s"; h5="base_t/s"; h6="FuZe gain factor";
          if(length(h1)>TW) TW=length(h1); if(length(h2)>VW) VW=length(h2); if(length(h3)>HW) HW=length(h3);
          if(length(h4)>KW) KW=length(h4); if(length(h5)>BW) BW=length(h5); if(length(h6)>GW) GW=length(h6);
          # top border
          printf("|%s|%s|%s|%s|%s|%s|\n", dline(TW+2,0), dline(VW+2,0), dline(HW+2,0), dline(KW+2,0), dline(BW+2,0), dline(GW+2,0));
          # header row
          printf("| %-*s | %-*s | %-*s | %*s | %*s | %*s |\n", TW,h1, VW,h2, HW,h3, KW,h4, BW,h5, GW,h6);
          # underline row (no alignment markers)
          printf("|%s|%s|%s|%s|%s|%s|\n", dline(TW+2,0), dline(VW+2,0), dline(HW+2,0), dline(KW+2,0), dline(BW+2,0), dline(GW+2,0));
          for(i=1;i<=n;i++){
            printf("| %-*s | %-*s | %-*s | %*s | %*s | %*s |\n", TW,TS[i], VW,VA[i], HW,HE[i], KW,TK[i], BW,BA[i], GW,GA[i]);
          }
        }'
fi

# ------------- Best per (stack, model) --------------------------------------
if [ "$ONLY_GLOBAL" -eq 0 ] && [ "$ONLY_TOP" -eq 0 ]; then
  echo "Best per (stack, model):"
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
   | awk -F',' -v AP="$ALIAS_PREFIX" '
       function aliasify(s,  t){ t=s; gsub(/[\/:]+/,"-",t); gsub(/-it-/,"-i-",t); sub(/-it$/,"-i",t); gsub(/-fp16/,"-f16",t); gsub(/-bf16/,"-b16",t); return t }
       function trim_lead_dash(s){ gsub(/^-+/,"",s); return s }
       function variant(base, ng, gl, st,  ab, sfx, sfx2, va){ ab=aliasify(base); sfx=ENVIRON["ALIAS_SUFFIX"]; sfx2=trim_lead_dash(sfx); if(sfx2!="") va=sprintf("%s%s-%s--%s-%s", AP, st, gl, sfx2, ab); else va=sprintf("%s%s-%s-%s", AP, st, gl, ab); if(ng+0>0) va=va "+ng" ng; return va }
       function htime(ts){ return (length(ts)>=15)? sprintf("%s-%s-%s %s:%s:%s", substr(ts,1,4),substr(ts,5,2),substr(ts,7,2),substr(ts,10,2),substr(ts,12,2),substr(ts,14,2)) : ts }
       function rep(n, c,  s){ s=""; for(i=0;i<n;i++) s=s c; return s }
       function dline(w, r){ return rep(w, "-") }
       {
         ts=htime($1); st=$3; host=$2; ep=($9!=""?$9:$8); ng=($12+0); gl=$10;
         va=variant($4, ng, gl, st); he=host "/" ep;
         tok=sprintf("%.2f", $7+0); base=sprintf("%.2f", $5+0); gain=sprintf("%.2fx", ($5+0>0?($7+0)/($5+0):0));
         n++; TS[n]=ts; VA[n]=va; HE[n]=he; TK[n]=tok; BA[n]=base; GA[n]=gain;
         if(length(ts)>TW) TW=length(ts); if(length(va)>VW) VW=length(va); if(length(he)>HW) HW=length(he);
         if(length(tok)>KW) KW=length(tok); if(length(base)>BW) BW=length(base); if(length(gain)>GW) GW=length(gain);
       }
       END{
         h1="timestamp"; h2="variant"; h3="host"; h4="tok/s"; h5="base_t/s"; h6="FuZe gain factor";
         if(length(h1)>TW) TW=length(h1); if(length(h2)>VW) VW=length(h2); if(length(h3)>HW) HW=length(h3);
         if(length(h4)>KW) KW=length(h4); if(length(h5)>BW) BW=length(h5); if(length(h6)>GW) GW=length(h6);
         printf("|%s|%s|%s|%s|%s|%s|\n", dline(TW+2,0), dline(VW+2,0), dline(HW+2,0), dline(KW+2,0), dline(BW+2,0), dline(GW+2,0));
         printf("| %-*s | %-*s | %-*s | %*s | %*s | %*s |\n", TW,h1, VW,h2, HW,h3, KW,h4, BW,h5, GW,h6);
         printf("|%s|%s|%s|%s|%s|%s|\n", dline(TW+2,0), dline(VW+2,0), dline(HW+2,0), dline(KW+2,0), dline(BW+2,0), dline(GW+2,0));
         for(i=1;i<=n;i++){
           printf("| %-*s | %-*s | %-*s | %*s | %*s | %*s |\n", TW,TS[i], VW,VA[i], HW,HE[i], KW,TK[i], BW,BA[i], GW,GA[i]);
         }
       }'
fi

# ------------- Best per (stack, model, gpu_label) ---------------------------
if [ "$ONLY_GLOBAL" -eq 0 ] && [ "$ONLY_TOP" -eq 0 ]; then
  echo "Best per (stack, model, gpu_label):"
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
   | awk -F',' -v AP="$ALIAS_PREFIX" '
       function aliasify(s,  t){ t=s; gsub(/[\/:]+/,"-",t); gsub(/-it-/,"-i-",t); sub(/-it$/,"-i",t); gsub(/-fp16/,"-f16",t); gsub(/-bf16/,"-b16",t); return t }
       function trim_lead_dash(s){ gsub(/^-+/,"",s); return s }
       function variant(base, ng, gl, st,  ab, sfx, sfx2, va){ ab=aliasify(base); sfx=ENVIRON["ALIAS_SUFFIX"]; sfx2=trim_lead_dash(sfx); if(sfx2!="") va=sprintf("%s%s-%s--%s-%s", AP, st, gl, sfx2, ab); else va=sprintf("%s%s-%s-%s", AP, st, gl, ab); if(ng+0>0) va=va "+ng" ng; return va }
       function htime(ts){ return (length(ts)>=15)? sprintf("%s-%s-%s %s:%s:%s", substr(ts,1,4),substr(ts,5,2),substr(ts,7,2),substr(ts,10,2),substr(ts,12,2),substr(ts,14,2)) : ts }
       function rep(n, c,  s){ s=""; for(i=0;i<n;i++) s=s c; return s }
       function dline(w, r){ return rep(w, "-") }
       {
         ts=htime($1); st=$3; host=$2; ep=($9!=""?$9:$8); ng=($12+0); gl=$10;
         va=variant($4, ng, gl, st); he=host "/" ep;
         tok=sprintf("%.2f", $7+0); base=sprintf("%.2f", $5+0); gain=sprintf("%.2fx", ($5+0>0?($7+0)/($5+0):0));
         n++; TS[n]=ts; VA[n]=va; HE[n]=he; TK[n]=tok; BA[n]=base; GA[n]=gain;
         if(length(ts)>TW) TW=length(ts); if(length(va)>VW) VW=length(va); if(length(he)>HW) HW=length(he);
         if(length(tok)>KW) KW=length(tok); if(length(base)>BW) BW=length(base); if(length(gain)>GW) GW=length(gain);
       }
       END{
         h1="timestamp"; h2="variant"; h3="host"; h4="tok/s"; h5="base_t/s"; h6="FuZe gain factor";
         if(length(h1)>TW) TW=length(h1); if(length(h2)>VW) VW=length(h2); if(length(h3)>HW) HW=length(h3);
         if(length(h4)>KW) KW=length(h4); if(length(h5)>BW) BW=length(h5); if(length(h6)>GW) GW=length(h6);
         printf("|%s|%s|%s|%s|%s|%s|\n", dline(TW+2,0), dline(VW+2,0), dline(HW+2,0), dline(KW+2,0), dline(BW+2,0), dline(GW+2,0));
         printf("| %-*s | %-*s | %-*s | %*s | %*s | %*s |\n", TW,h1, VW,h2, HW,h3, KW,h4, BW,h5, GW,h6);
         printf("|%s|%s|%s|%s|%s|%s|\n", dline(TW+2,0), dline(VW+2,0), dline(HW+2,0), dline(KW+2,0), dline(BW+2,0), dline(GW+2,0));
         for(i=1;i<=n;i++){
           printf("| %-*s | %-*s | %-*s | %*s | %*s | %*s |\n", TW,TS[i], VW,VA[i], HW,HE[i], KW,TK[i], BW,BA[i], GW,GA[i]);
         }
       }'
fi

# ------------- Best per (host, model) across stacks -------------------------
if [ "$ONLY_GLOBAL" -eq 0 ] && [ "$ONLY_TOP" -eq 0 ]; then
  echo "Best per (host, model) across stacks:"
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
   | awk -F',' -v AP="$ALIAS_PREFIX" '
       function aliasify(s,  t){ t=s; gsub(/[\/:]+/,"-",t); gsub(/-it-/,"-i-",t); sub(/-it$/,"-i",t); gsub(/-fp16/,"-f16",t); gsub(/-bf16/,"-b16",t); return t }
       function trim_lead_dash(s){ gsub(/^-+/,"",s); return s }
       function variant(base, ng, gl, st,  ab, sfx, sfx2, va){ ab=aliasify(base); sfx=ENVIRON["ALIAS_SUFFIX"]; sfx2=trim_lead_dash(sfx); va=sprintf("%s%s-%s-%s", AP, st, gl, ab); if(sfx2!="") va=sprintf("%s%s--%s-%s", AP, st, gl, ab); if(ng+0>0) va=va "+ng" ng; return va }
       function htime(ts){ return (length(ts)>=15)? sprintf("%s-%s-%s %s:%s:%s", substr(ts,1,4),substr(ts,5,2),substr(ts,7,2),substr(ts,10,2),substr(ts,12,2),substr(ts,14,2)) : ts }
       function rep(n, c,  s){ s=""; for(i=0;i<n;i++) s=s c; return s }
       function dline(w, r){ return rep(w, "-") (r? ":":"") }
       {
         ts=htime($1); st=$3; host=$2; ep=($9!=""?$9:$8); ng=($12+0); gl=$10;
         va=variant($4, ng, gl, st); he=host "/" ep;
         tok=sprintf("%.2f", $7+0); base=sprintf("%.2f", $5+0); gain=sprintf("%.2fx", ($5+0>0?($7+0)/($5+0):0));
         n++; TS[n]=ts; VA[n]=va; HE[n]=he; TK[n]=tok; BA[n]=base; GA[n]=gain;
         if(length(ts)>TW) TW=length(ts); if(length(va)>VW) VW=length(va); if(length(he)>HW) HW=length(he);
         if(length(tok)>KW) KW=length(tok); if(length(base)>BW) BW=length(base); if(length(gain)>GW) GW=length(gain);
       }
       END{
         h1="timestamp"; h2="variant"; h3="host"; h4="tok/s"; h5="base_t/s"; h6="FuZe gain factor";
         if(length(h1)>TW) TW=length(h1); if(length(h2)>VW) VW=length(h2); if(length(h3)>HW) HW=length(h3);
         if(length(h4)>KW) KW=length(h4); if(length(h5)>BW) BW=length(h5); if(length(h6)>GW) GW=length(h6);
         printf("|%s|%s|%s|%s|%s|%s|\n", dline(TW+2,0), dline(VW+2,0), dline(HW+2,0), dline(KW+2,0), dline(BW+2,0), dline(GW+2,0));
         printf("| %-*s | %-*s | %-*s | %*s | %*s | %*s |\n", TW,h1, VW,h2, HW,h3, KW,h4, BW,h5, GW,h6);
         printf("|%s|%s|%s|%s|%s|%s|\n", dline(TW+2,0), dline(VW+2,0), dline(HW+2,0), dline(KW+2,0), dline(BW+2,0), dline(GW+2,0));
         for(i=1;i<=n;i++){
           printf("| %-*s | %-*s | %-*s | %*s | %*s | %*s |\n", TW,TS[i], VW,VA[i], HW,HE[i], KW,TK[i], BW,BA[i], GW,GA[i]);
         }
       }'
fi

# ------------- Global best per model (across hosts & stacks) ----------------
if [ "$ONLY_TOP" -eq 0 ]; then
  echo
  echo "Global best per model (across hosts & stacks):"
  awk -F',' -v MR="$MODEL_RE" -v GR="$GPU_RE" -v AP="$ALIAS_PREFIX" '
    NR>1 {
      if (MR!="" && $4 !~ MR) next;
      if (GR!="" && ($10 !~ GR && $11 !~ GR)) next;
      if (!($7+0>0)) next;
      k=$4; if ($7+0>best[k]) {best[k]=$7+0; line[k]=$0}
    }
    END{for (k in best){print line[k]}}
  ' "$CSV" \
   | awk -F',' -v AP="$ALIAS_PREFIX" '
       function aliasify(s,  t){ t=s; gsub(/[\/:]+/,"-",t); gsub(/-it-/,"-i-",t); sub(/-it$/,"-i",t); gsub(/-fp16/,"-f16",t); gsub(/-bf16/,"-b16",t); return t }
       function trim_lead_dash(s){ gsub(/^-+/,"",s); return s }
       function variant(base, ng, gl, st,  ab, sfx, sfx2, va){ ab=aliasify(base); sfx=ENVIRON["ALIAS_SUFFIX"]; sfx2=trim_lead_dash(sfx); if(sfx2!="") va=sprintf("%s%s-%s--%s-%s", AP, st, gl, sfx2, ab); else va=sprintf("%s%s-%s-%s", AP, st, gl, ab); if(ng+0>0) va=va "+ng" ng; return va }
       function htime(ts){ return (length(ts)>=15)? sprintf("%s-%s-%s %s:%s:%s", substr(ts,1,4),substr(ts,5,2),substr(ts,7,2),substr(ts,10,2),substr(ts,12,2),substr(ts,14,2)) : ts }
       function rep(n, c,  s){ s=""; for(i=0;i<n;i++) s=s c; return s }
       function dline(w, r){ return rep(w, "-") (r? ":":"") }
       {
         ts=htime($1); st=$3; host=$2; ep=($9!=""?$9:$8); ng=($12+0); gl=$10;
         va=variant($4, ng, gl, st); he=host "/" ep;
         tok=sprintf("%.2f", $7+0); base=sprintf("%.2f", $5+0); gain=sprintf("%.2fx", ($5+0>0?($7+0)/($5+0):0));
         n++; TS[n]=ts; VA[n]=va; HE[n]=he; TK[n]=tok; BA[n]=base; GA[n]=gain;
         if(length(ts)>TW) TW=length(ts); if(length(va)>VW) VW=length(va); if(length(he)>HW) HW=length(he);
         if(length(tok)>KW) KW=length(tok); if(length(base)>BW) BW=length(base); if(length(gain)>GW) GW=length(gain);
       }
       END{
         h1="timestamp"; h2="variant"; h3="host"; h4="tok/s"; h5="base_t/s"; h6="FuZe gain factor";
         if(length(h1)>TW) TW=length(h1); if(length(h2)>VW) VW=length(h2); if(length(h3)>HW) HW=length(h3);
         if(length(h4)>KW) KW=length(h4); if(length(h5)>BW) BW=length(h5); if(length(h6)>GW) GW=length(h6);
         printf("|%s|%s|%s|%s|%s|%s|\n", dline(TW+2,0), dline(VW+2,0), dline(HW+2,0), dline(KW+2,0), dline(BW+2,0), dline(GW+2,0));
         printf("| %-*s | %-*s | %-*s | %*s | %*s | %*s |\n", TW,h1, VW,h2, HW,h3, KW,h4, BW,h5, GW,h6);
         printf("|%s|%s|%s|%s|%s|%s|\n", dline(TW+2,0), dline(VW+2,0), dline(HW+2,0), dline(KW+2,0), dline(BW+2,0), dline(GW+2,0));
         for(i=1;i<=n;i++){
           printf("| %-*s | %-*s | %-*s | %*s | %*s | %*s |\n", TW,TS[i], VW,VA[i], HW,HE[i], KW,TK[i], BW,BA[i], GW,GA[i]);
         }
       }'
fi

# ------------- Write best-per-(stack,model) CSV -----------------------------
if [ "$ONLY_TOP" -eq 0 ]; then
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
fi
