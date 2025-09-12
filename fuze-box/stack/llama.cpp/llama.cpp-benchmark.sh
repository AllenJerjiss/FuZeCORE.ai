#!/usr/bin/env bash
# llamacpp-benchmark.sh — apples-to-apples runner for llama.cpp (GGUF)
set -euo pipefail

########## CONFIG (override with env) ##########################################
OLLAMA_MODELS_DIR="${OLLAMA_MODELS_DIR:-/FuZe/ollama/models}"   # scan for *.gguf first
EXTRA_GGUF_DIR="${EXTRA_GGUF_DIR:-}"                            # optional extra GGUF path
LOG_DIR="${LOG_DIR:-/FuZe/logs}"

# Sweep knobs
NGL_CANDIDATES="${NGL_CANDIDATES:-60 48 40 32 24 16 0}"         # layers offloaded to GPU
THREADS_CANDIDATES="${THREADS_CANDIDATES:-$(nproc)}"            # try CPU threads (single value by default)

# Inference shape
CTX="${CTX:-1024}"
BATCH="${BATCH:-32}"
PRED="${PRED:-256}"

# Control
EXHAUSTIVE="${EXHAUSTIVE:-0}"         # 0 = stop at first successful ngl; 1 = test all
TIMEOUT_GEN="${TIMEOUT_GEN:-120}"     # sec for each generation run
VERBOSE="${VERBOSE:-1}"

# llama.cpp binary detection (override with LLAMACPP_BIN)
LLAMACPP_BIN="${LLAMACPP_BIN:-}"
################################################################################

c_bold="\033[1m"; c_red="\033[31m"; c_green="\033[32m"; c_yellow="\033[33m"; c_reset="\033[0m"
log(){ echo -e "$*"; }
info(){ [ "${VERBOSE}" -ne 0 ] && echo -e "${c_bold}==${c_reset} $*"; }
ok(){ echo -e "${c_green}✔${c_reset} $*"; }
warn(){ echo -e "${c_yellow}!${c_reset} $*"; }
err(){ echo -e "${c_red}✖${c_reset} $*" >&2; }

need(){ command -v "$1" >/dev/null 2>&1 || { err "Missing dependency: $1"; exit 1; }; }
need nvidia-smi; need awk; need sed; need grep; need find; need timeout; need date

HOST="$(hostname -s 2>/dev/null || hostname)"
TS="$(date +%Y%m%d_%H%M%S)"

# Logs / CSV
mkdir -p "${LOG_DIR}" 2>/dev/null || true
if [ ! -w "${LOG_DIR}" ]; then
  warn "LOG_DIR ${LOG_DIR} not writable; falling back to ./logs"
  LOG_DIR="./logs"; mkdir -p "${LOG_DIR}"
fi
CSV_FILE="${LOG_DIR}/llamacpp_bench_${TS}.csv"
SUMMARY_FILE="${LOG_DIR}/${HOST}-llamacpp-${TS}.benchmark"

echo "ts,framework,endpoint_or_pid,model_id,tag_or_variant,gpu_label,device_ids,num_ctx,batch,num_predict,extra_params,tokens_per_sec,gpu_name,gpu_uuid,gpu_mem_mib" > "${CSV_FILE}"

gpu_table(){ nvidia-smi --query-gpu=index,uuid,name,memory.total --format=csv,noheader | sed 's/, /,/g'; }
pick_label(){ # name -> short label
  local n="$(echo "$1" | tr 'A-Z' 'a-z')"
  echo "$n" | grep -q "5090" && { echo "5090"; return; }
  echo "$n" | grep -q "3090" && { echo "3090ti"; return; }
  echo "$n" | sed -E 's/[^a-z0-9]+/-/g'
}
find_llamacpp_bin(){
  [ -n "${LLAMACPP_BIN}" ] && { command -v "${LLAMACPP_BIN}" >/dev/null 2>&1 && echo "${LLAMACPP_BIN}" && return 0; }
  for c in /usr/local/bin/llama-cli /usr/local/bin/main /usr/bin/llama-cli /opt/llama.cpp/build/bin/llama-cli ./main; do
    command -v "$c" >/dev/null 2>&1 && { echo "$c"; return 0; }
  done
  return 1
}
LLAMA_BIN="$(find_llamacpp_bin || true)"
[ -z "${LLAMA_BIN}" ] && { err "llama.cpp binary not found. Set LLAMACPP_BIN=/path/to/main"; exit 1; }

discover_ggufs(){
  local roots=()
  [ -d "${OLLAMA_MODELS_DIR}" ] && roots+=("${OLLAMA_MODELS_DIR}")
  [ -n "${EXTRA_GGUF_DIR}" ] && [ -d "${EXTRA_GGUF_DIR}" ] && roots+=("${EXTRA_GGUF_DIR}")
  [ ${#roots[@]} -eq 0 ] && { warn "No GGUF roots found"; return 0; }
  for r in "${roots[@]}"; do
    find "$r" -type f -name '*.gguf' -printf '%p\n'
  done | sort -u
}

calc_tokps(){ # tokens / seconds
  awk -v t="$1" -v s="$2" 'BEGIN{ if(s<=0){print "0.00"} else {printf("%.2f", t/s)} }'
}

append_csv(){ echo "$*" >> "${CSV_FILE}"; }

bench_one(){ # gpu_idx gguf ngl threads
  local gpu="$1" gguf="$2" ngl="$3" th="$4"
  local row idx uuid name mem label
  row="$(gpu_table | awk -F',' -v I="$gpu" '$1==I{print;exit}')"
  [ -z "$row" ] && { warn "GPU idx $gpu not found"; return 1; }
  IFS=',' read -r idx uuid name mem <<<"$row"
  label="$(pick_label "$name")"
  local devs="$gpu"
  local prompt="Write ok repeatedly for benchmarking."
  local start_ns end_ns dt_s tokps
  local pid

  info "GPU:$gpu (${name}) | ngl=${ngl} | t=${th} | model=$(basename "$gguf")"
  set +e
  start_ns="$(date +%s%N)"
  CUDA_VISIBLE_DEVICES="$gpu" timeout "${TIMEOUT_GEN}"s "${LLAMA_BIN}" \
    -m "$gguf" -p "$prompt" -n "${PRED}" -c "${CTX}" --batch "${BATCH}" -ngl "${ngl}" -t "${th}" --temp 0 --top_k 1 --top_p 0 \
    2>"/tmp/llama.err.$$" 1>"/tmp/llama.out.$$"
  rc=$?
  end_ns="$(date +%s%N)"
  set -e
  dt_s="$(awk -v a="$start_ns" -v b="$end_ns" 'BEGIN{printf("%.3f",(b-a)/1e9)}')"

  # Prefer llama.cpp reported tokens/s if present
  tokps="$(grep -aoE '[0-9]+(\.[0-9]+)? tokens/s' "/tmp/llama.err.$$" "/tmp/llama.out.$$" 2>/dev/null | tail -n1 | awk '{print $1}')"
  [ -z "${tokps:-}" ] && tokps="$(calc_tokps "${PRED}" "${dt_s}")"

  local tag="ngl=${ngl},t=${th}"
  local extra="{\"threads\":${th}}"
  append_csv "$(date -Iseconds),llamacpp,$$,${gguf},${tag},${label},${devs},${CTX},${BATCH},${PRED},${extra},${tokps},${name},${uuid},${mem%% MiB}"

  if [ "$rc" -ne 0 ]; then
    warn "llama.cpp run RC=$rc (timeout or error). Recorded tok/s=${tokps} from walltime."
  else
    ok "tok/s=${tokps}"
  fi

  rm -f "/tmp/llama.err.$$" "/tmp/llama.out.$$" || true
  echo "$tokps"
}

main(){
  echo -e "${c_bold}== llama.cpp apples-to-apples benchmark ==${c_reset}"
  echo "llama.cpp: ${LLAMA_BIN}"
  echo "GGUF roots: ${OLLAMA_MODELS_DIR}${EXTRA_GGUF_DIR:+, ${EXTRA_GGUF_DIR}}"
  echo "CSV: ${CSV_FILE}"

  mapfile -t ggufs < <(discover_ggufs)
  if [ ${#ggufs[@]} -eq 0 ]; then
    err "No GGUF files found under ${OLLAMA_MODELS_DIR} ${EXTRA_GGUF_DIR}"
    exit 1
  fi
  echo "Found ${#ggufs[@]} GGUF(s)."

  # GPUs
  mapfile -t gpus < <(gpu_table | awk -F',' '{print $1}')
  if [ ${#gpus[@]} -eq 0 ]; then err "No NVIDIA GPUs detected"; exit 1; fi

  for gg in "${ggufs[@]}"; do
    for gpu in "${gpus[@]}"; do
      best="0.00"
      for th in ${THREADS_CANDIDATES}; do
        for ngl in ${NGL_CANDIDATES}; do
          tokps="$(bench_one "$gpu" "$gg" "$ngl" "$th" || echo "0.00")"
          awk -v a="$tokps" -v b="$best" 'BEGIN{exit !(a>b)}' && best="$tokps"
          if [ "$EXHAUSTIVE" -eq 0 ] && awk -v a="$tokps" 'BEGIN{exit !(a>0)}'; then
            break
          fi
        done
        [ "$EXHAUSTIVE" -eq 0 ] && break
      done
      info "Best for GPU${gpu} on $(basename "$gg"): ${best} tok/s"
      echo "${HOST},llamacpp,${gg},GPU${gpu},best=${best}" >> "${SUMMARY_FILE}.raw"
    done
  done

  {
    echo "=== Final Summary @ ${HOST} ${TS} (llama.cpp) ==="
    echo "CSV: ${CSV_FILE}"
    echo
    if [ -s "${SUMMARY_FILE}.raw" ]; then
      echo "Best per (model,GPU):"
      column -t -s',' "${SUMMARY_FILE}.raw" 2>/dev/null || cat "${SUMMARY_FILE}.raw"
    else
      echo "No successful runs recorded."
    fi
    echo
    echo "Top-5 overall:"
    tail -n +2 "${CSV_FILE}" | sort -t',' -k12,12gr | head -n5 \
      | awk -F',' '{printf "  %-9s %-24s %-8s %6.2f tok/s  (ctx=%s batch=%s pred=%s %s)\n",$2,$4,$6,$12,$8,$9,$10,$11}'
  } | tee "${SUMMARY_FILE}"

  ok "DONE. CSV: ${CSV_FILE}"
  ok "DONE. Summary: ${SUMMARY_FILE}"
}
main "$@"

