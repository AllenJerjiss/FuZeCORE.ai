#!/usr/bin/env bash
# llamacpp-benchmark.sh
# Bench llama.cpp directly, reusing GGUFs found in the Ollama model store.
# - Scans OLLAMA_MODELS_DIR/blobs for GGUF magic and maps tags ~by size
# - Runs per-GPU (bind with CUDA_VISIBLE_DEVICES=UUID) one model at a time
# - Sweeps -ngl (GPU layers) high->low; base-as-is (CPU) optional
# - Writes CSV + a human summary to LOG_DIR
# - Robust timeouts and detailed logs per run

set -euo pipefail

########## CONFIG (override with env) ##########################################
# llama.cpp binary (we’ll auto-detect if unset)
LLAMACPP_BIN="${LLAMACPP_BIN:-}"

# Where Ollama keeps its blobs; we’ll mine GGUFs from here.
OLLAMA_MODELS_DIR="${OLLAMA_MODELS_DIR:-/FuZe/ollama/models}"

# Logs/CSV output
LOG_DIR="${LOG_DIR:-/FuZe/logs}"
STACK="llamacpp"

# Models to test: "ollama-tag|alias"
# (alias is used in file names and summary rows)
MODELS=(
  "llama4:16x17b|llama4-16x17b"
  "deepseek-r1:70b|deepseek-r1-70b"
  "llama4:128x17b|llama4-128x17b"
)

# GPU selection by name substring (used to pick two devices)
MATCH_GPU_A="${MATCH_GPU_A:-5090}"
MATCH_GPU_B="${MATCH_GPU_B:-3090 Ti}"

# Bench params
CTX="${CTX:-1024}"
BATCH="${BATCH:-32}"
PRED="${PRED:-256}"
TEMP="${TEMP:-0}"

# Sweep of GPU layers (-ngl) high -> low
NUM_GPU_CANDIDATES="${NUM_GPU_CANDIDATES:-80 72 64 56 48 40 32 24 16}"

# Also try CPU (ngl=0) as a baseline? 0/1
TRY_CPU_BASELINE="${TRY_CPU_BASELINE:-1}"

# 0 = stop after first working ngl; 1 = try all working values
EXHAUSTIVE="${EXHAUSTIVE:-0}"

# Timeouts
TIMEOUT_GEN="${TIMEOUT_GEN:-90}"       # seconds for a single generation
TIMEOUT_DISCOVER="${TIMEOUT_DISCOVER:-5}"  # per ‘ollama list’ etc.

VERBOSE="${VERBOSE:-1}"
################################################################################

c_bold="\033[1m"; c_red="\033[31m"; c_green="\033[32m"; c_yellow="\033[33m"; c_reset="\033[0m"
log(){ echo -e "$*"; }
info(){ [ "$VERBOSE" -ne 0 ] && echo -e "${c_bold}==${c_reset} $*"; }
ok(){ echo -e "${c_green}✔${c_reset} $*"; }
warn(){ echo -e "${c_yellow}!${c_reset} $*"; }
err(){ echo -e "${c_red}✖${c_reset} $*" >&2; }
need(){ command -v "$1" >/dev/null 2>&1 || { err "Missing dependency: $1"; exit 1; }; }

need nvidia-smi; need awk; need sed; need grep; need stat; need timeout
mkdir -p "$LOG_DIR"

HOSTNAME_NOW="$(hostname -s 2>/dev/null || hostname)"
TS="$(date +%Y%m%d_%H%M%S)"
CSV_FILE="${LOG_DIR}/${STACK}_bench_${TS}.csv"
SUMMARY_FILE="${LOG_DIR}/${HOSTNAME_NOW}-${TS}.benchmark"

echo "ts,gpu_label,alias,tag,ngl,num_ctx,batch,num_predict,tokens_per_sec,gpu_name,gpu_uuid,gpu_mem_mib,model_path" >"$CSV_FILE"

# ---- llama.cpp binary autodetect ------------------------------------------------
if [ -z "$LLAMACPP_BIN" ]; then
  for c in llama-cli main llama; do
    if command -v "$c" >/dev/null 2>&1; then LLAMACPP_BIN="$c"; break; fi
  done
fi
[ -n "$LLAMACPP_BIN" ] || { err "Could not find llama.cpp binary (set LLAMACPP_BIN)"; exit 1; }
info "llama.cpp binary: $LLAMACPP_BIN"

# ---- GPU helpers ----------------------------------------------------------------
gpu_table(){ nvidia-smi --query-gpu=index,uuid,name,memory.total --format=csv,noheader | sed 's/, /,/g'; }
pick_uuid_by_name_substr(){ local needle="$1"; gpu_table | while IFS=',' read -r idx uuid name mem; do echo "$name" | grep -qi "$needle" && { echo "$uuid"; return 0; }; done; }
gpu_row_by_uuid(){ local u="$1"; gpu_table | grep "$u" || true; }

UUID_A="$(pick_uuid_by_name_substr "$MATCH_GPU_A" || true)"
UUID_B="$(pick_uuid_by_name_substr "$MATCH_GPU_B" || true)"
if [ -z "${UUID_A:-}" ] || [ -z "${UUID_B:-}" ] || [ "$UUID_A" = "$UUID_B" ]; then
  warn "GPU name match failed/identical — falling back to index order."
  UUID_A="$(gpu_table | awk -F',' 'NR==1{print $2}')"
  UUID_B="$(gpu_table | awk -F',' 'NR==2{print $2}')"
fi
read -r _ uuA nameA memA <<<"$(gpu_row_by_uuid "$UUID_A")"
read -r _ uuB nameB memB <<<"$(gpu_row_by_uuid "$UUID_B")"
log "GPU-A: ${nameA} (${UUID_A}) ${memA}"
log "GPU-B: ${nameB} (${UUID_B}) ${memB}"

# ---- Ollama helpers (discover tag sizes) ---------------------------------------
OLLAMA="${OLLAMA:-/usr/local/bin/ollama}"
if ! command -v "$OLLAMA" >/dev/null 2>&1; then
  warn "ollama not found; GGUF discovery will rely on size heuristics only."
fi

# Parse size like "67 GB" -> bytes
to_bytes(){
  awk '
    function tolowercase(s){gsub(/[A-Z]/, substr("abcdefghijklmnopqrstuvwxyz", index("ABCDEFGHIJKLMNOPQRSTUVWXYZ", substr(s, RSTART, 1)), 1), s); return s}
    BEGIN{val=ARGV[1]; unit=ARGV[2]; u=tolowercase(unit); bytes=val}
    u ~ /^g/ {bytes=val*1024*1024*1024}
    u ~ /^m/ {bytes=val*1024*1024}
    u ~ /^k/ {bytes=val*1024}
    u ~ /^t/ {bytes=val*1024*1024*1024*1024}
    {printf "%.0f", bytes}
  ' "$@"
}

tag_size_bytes(){
  local tag="$1" size num unit
  if command -v "$OLLAMA" >/dev/null 2>&1; then
    # best-effort parse of `ollama list` rows
    local line
    line="$("$OLLAMA" list 2>/dev/null | awk -v t="$tag" '$1==t{print; exit}')"
    if [ -n "$line" ]; then
      # columns: NAME ID SIZE MODIFIED
      size="$(echo "$line" | awk '{print $(NF-1) " " $NF}' | sed 's/\r//g')" # not perfect if MODIFIED has spaces; fallback below
      # if MODIFIED has spaces, SIZE is actually ($3,$4) — try alt:
      if ! echo "$size" | grep -Eq '^[0-9.]+ [KMGTP]B$'; then
        size="$(echo "$line" | awk '{print $3" "$4}')"
      fi
      num="$(echo "$size" | awk '{print $1}')"
      unit="$(echo "$size" | awk '{print $2}')"
      if echo "$unit" | grep -Eq '^[KMGTP]B$'; then
        to_bytes "$num" "$unit" && return 0
      fi
    fi
  fi
  echo 0
}

# ---- Find GGUFs in the Ollama blob store --------------------------------------
BLOBS_DIR="${OLLAMA_MODELS_DIR%/}/blobs"
is_gguf_blob(){
  # GGUF magic: "GGUF" (0x47 0x47 0x55 0x46) or "gguf" (0x67 0x67 0x75 0x66)
  local f="$1" sig
  sig="$(head -c 4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  [ "$sig" = "47475546" ] || [ "$sig" = "67677566" ]
}
discover_gguf_blobs(){
  [ -d "$BLOBS_DIR" ] || return 0
  find "$BLOBS_DIR" -maxdepth 1 -type f -printf "%p\n" 2>/dev/null | while read -r f; do
    if is_gguf_blob "$f"; then
      # print: "<bytes>,<path>"
      stat -c '%s,%n' "$f" || true
    fi
  done
}

# Map an Ollama tag to a GGUF path by size proximity (+/- 20%)
resolve_gguf_for_tag(){
  local tag="$1" expected size tol chosen chosen_size
  expected="$(tag_size_bytes "$tag")"
  size_list="$(discover_gguf_blobs | sort -nr -t',' -k1,1)"
  if [ -z "$size_list" ]; then
    echo ""
    return 0
  fi

  if [ "$expected" -gt 0 ]; then
    tol=$(( expected / 5 )) # 20%
    while IFS=',' read -r bytes path; do
      local diff=$(( bytes>expected ? bytes-expected : expected-bytes ))
      if [ "$diff" -le "$tol" ]; then chosen="$path"; chosen_size="$bytes"; break; fi
    done <<< "$size_list"
  fi

  # fallback: take the largest GGUF
  if [ -z "${chosen:-}" ]; then
    chosen="$(echo "$size_list" | head -n1 | cut -d',' -f2-)"
    chosen_size="$(echo "$size_list" | head -n1 | cut -d',' -f1)"
  fi

  echo "$chosen"
}

# ---- Bench helpers -------------------------------------------------------------
parse_tokps_from_log(){
  # Prefer the standard llama_print_timings line
  local logf="$1" tokps=""
  tokps="$(grep -i 'tokens per second' "$logf" | tail -n1 | sed -E 's/.*\(([0-9.]+) tokens per second\).*/\1/' || true)"
  if [ -z "$tokps" ]; then
    # fallback: capture "... ##.# t/s" style
    tokps="$(grep -Eo '[0-9]+\.[0-9]+ t/s' "$logf" | tail -n1 | awk '{print $1}' || true)"
  fi
  echo "${tokps:-0.00}"
}

bench_once(){ # gpu_label uuid tag alias gguf_path ngl
  local glabel="$1" uuid="$2" tag="$3" alias="$4" gguf="$5" ngl="$6"
  local ngl_label="ngl${ngl}"
  [ "$ngl" = "default" ] && ngl_label="default"

  local run_id="${alias}-${glabel}-${ngl_label}"
  local logf="${LOG_DIR}/run_${run_id}_${TS}.log"

  local ngl_args=()
  [ "$ngl" != "default" ] && ngl_args=(-ngl "$ngl")

  local prompt="Write ok repeatedly for benchmarking."

  info "Running: ${alias} (${tag}) on ${glabel} ${UUID_A:+} with ${ngl_label}"
  set +e
  CUDA_VISIBLE_DEVICES="$uuid" \
  timeout -k 5 "$TIMEOUT_GEN" \
    "$LLAMACPP_BIN" \
      -m "$gguf" -c "$CTX" -b "$BATCH" -n "$PRED" -s 1 --temp "$TEMP" \
      "${ngl_args[@]}" \
      -p "$prompt" \
      >"$logf" 2>&1
  local rc=$?
  set -e

  if [ $rc -ne 0 ]; then
    warn "  run failed (rc=$rc) — see $logf (tail below)"
    tail -n 20 "$logf" | sed 's/^/  | /'
    echo "0.00"
    return 1
  fi

  local tokps; tokps="$(parse_tokps_from_log "$logf")"
  if ! echo "$tokps" | grep -Eq '^[0-9]+(\.[0-9]+)?$'; then
    warn "  could not parse tokens/s — see $logf"
    tokps="0.00"
  fi

  # GPU info row
  local row; row="$(gpu_row_by_uuid "$uuid")"
  local idx name mem
  IFS=',' read -r idx _ name mem <<<"$row"
  local mem_mib="${mem%% MiB}"

  echo "$(date -Iseconds),${glabel},${alias},${tag},${ngl},${CTX},${BATCH},${PRED},${tokps},${name},${uuid},${mem_mib},${gguf}" >>"$CSV_FILE"
  ok "  ${alias} ${ngl_label} on ${glabel} -> ${tokps} tok/s"
  echo "$tokps"
}

tune_and_bench_model_on_gpu(){ # glabel uuid tag alias gguf
  local glabel="$1" uuid="$2" tag="$3" alias="$4" gguf="$5"

  # Optional CPU baseline
  if [ "$TRY_CPU_BASELINE" -eq 1 ]; then
    bench_once "$glabel" "$uuid" "$tag" "$alias" "$gguf" "default" >/dev/null || true
  fi

  local best_tokps="0.00" best_ngl=""
  for ng in $NUM_GPU_CANDIDATES; do
    info "  Trying -ngl ${ng} ..."
    local t; t="$(bench_once "$glabel" "$uuid" "$tag" "$alias" "$gguf" "$ng" || echo "0.00")"
    awk -v a="$t" -v b="$best_tokps" 'BEGIN{exit !(a>b)}' && { best_tokps="$t"; best_ngl="$ng"; }
    if [ "$EXHAUSTIVE" -eq 0 ] && awk -v a="$t" 'BEGIN{exit !(a>0)}'; then
      break
    fi
  done

  if awk -v b="$best_tokps" 'BEGIN{exit !(b>0)}'; then
    ok "Best on ${glabel} for ${alias}: ngl=${best_ngl} at ${best_tokps} tok/s"
    echo "${glabel},${alias},ngl=${best_ngl},${best_tokps}" >>"${SUMMARY_FILE}.raw"
  else
    warn "No working -ngl for ${alias} on ${glabel}"
  fi
}

##################################### MAIN #####################################
echo -e "${c_bold}== llama.cpp bench (GGUF from Ollama store) ==${c_reset}"
log "Binary     : ${LLAMACPP_BIN}"
log "Blobs dir  : ${BLOBS_DIR}"
log "Models     : $(printf '%s ' "${MODELS[@]}")"
log "CSV        : ${CSV_FILE}"
log "Summary    : ${SUMMARY_FILE}"

# Resolve GGUF per tag
declare -A GGUF_PATHS
for m in "${MODELS[@]}"; do
  tag="${m%%|*}"; alias="${m##*|}"
  gguf="$(resolve_gguf_for_tag "$tag")"
  if [ -z "$gguf" ]; then
    warn "Could not resolve GGUF for ${tag}; skipping."
    continue
  fi
  GGUF_PATHS["$tag"]="$gguf"
  info "Resolved ${tag} -> $(basename "$gguf") ($(stat -c %s "$gguf") bytes)"
done

# Run per GPU (A then B) across models
for m in "${MODELS[@]}"; do
  tag="${m%%|*}"; alias="${m##*|}"
  gguf="${GGUF_PATHS[$tag]:-}"
  [ -n "$gguf" ] || continue

  info "----> ${tag} (${alias}) on GPU-A"
  tune_and_bench_model_on_gpu "A" "$UUID_A" "$tag" "$alias" "$gguf"

  info "----> ${tag} (${alias}) on GPU-B"
  tune_and_bench_model_on_gpu "B" "$UUID_B" "$tag" "$alias" "$gguf"
done

# Final summary
{
  echo "=== Final Summary @ ${HOSTNAME_NOW} ${TS} ==="
  echo "CSV: ${CSV_FILE}"
  echo
  if [ -s "${SUMMARY_FILE}.raw" ]; then
    echo "Best per (GPU, model):"
    column -t -s',' "${SUMMARY_FILE}.raw" 2>/dev/null || cat "${SUMMARY_FILE}.raw"
  else
    echo "No optimized runs succeeded."
  fi
  echo
  echo "Top-5 runs overall (by tokens/sec) from CSV:"
  tail -n +2 "$CSV_FILE" | sort -t',' -k9,9gr | head -n5 \
    | awk -F',' '{printf "  GPU:%-2s  %-18s  %6.2f tok/s  (tag=%-20s ngl=%s)\n",$2,$3,$9,$4,$5}'
} | tee "${SUMMARY_FILE}"

ok "DONE. CSV: ${CSV_FILE}"
ok "DONE. Summary: ${SUMMARY_FILE}"

