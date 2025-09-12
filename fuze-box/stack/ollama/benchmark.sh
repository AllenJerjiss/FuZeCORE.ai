#!/usr/bin/env bash
set -euo pipefail
TARGET="${1:-$HOME/GitHub/FuZeCORE.ai/fuze-box/stack/ollama/benchmark.sh}"
REPLACE_BIN="${REPLACE_BIN:-$HOME/GitHub/FuZeCORE.ai/utils/replace-block}"
BACKUP_EXT="${BACKUP_EXT:-.bak}"

[ -f "$TARGET" ] || { echo "No target: $TARGET" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

# 1) Ensure watchdog config exists (append if missing)
if ! grep -q 'CPU_PEG_MONITOR' "$TARGET"; then
  cat >>"$TARGET" <<'CFG'

# CPU/GPU watchdog for optimized variants (added)
CPU_PEG_MONITOR="${CPU_PEG_MONITOR:-1}"
CPU_PEG_THRESHOLD="${CPU_PEG_THRESHOLD:-300}"
CPU_PEG_WINDOW="${CPU_PEG_WINDOW:-4}"
GPU_MIN_UTIL="${GPU_MIN_UTIL:-10}"
CPU_ABANDONED_FILE="${SUMMARY_FILE}.cpu_abandoned"
CFG
fi

# 2) Insert record_cpu_abandoned + monitor_cpu_gpu helpers if missing
if ! grep -q 'record_cpu_abandoned' "$TARGET"; then
  cat >>"$TARGET" <<'FUNCS'

record_cpu_abandoned(){ # ep base variant ng gpu_lbl
  local ep="$1" base="$2" variant="$3" ng="$4" gpu_lbl="$5"
  if [ ! -e "$CPU_ABANDONED_FILE" ]; then
    echo "endpoint,base,variant,num_gpu,gpu_label" > "$CPU_ABANDONED_FILE"
  fi
  echo "${ep},${base},${variant},${ng},${gpu_lbl}" >> "$CPU_ABANDONED_FILE"
}

monitor_cpu_gpu(){ # unit uuid secs
  local unit="$1" uuid="$2" secs="${3:-$TIMEOUT_GEN}"
  local pid cpu gpu consec=0 t0 now
  pid="$(systemctl show "$unit" -p MainPID --value 2>/dev/null || true)"
  [ -n "${pid:-}" ] && [ "$pid" -gt 0 ] || return 0
  t0="$(date +%s)"
  while :; do
    now="$(date +%s)"; [ $((now - t0)) -ge "$secs" ] && return 0
    cpu="$(ps -p "$pid" -o %cpu= 2>/dev/null | awk '{printf("%d",$1+0)}')"
    gpu=0
    if command -v nvidia-smi >/dev/null 2>&1 && [ -n "${uuid:-}" ]; then
      gpu="$(nvidia-smi -i "$uuid" --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | awk "NR==1{printf(\"%d\",\$1+0)}")"
    fi
    if [ "${cpu:-0}" -ge "$CPU_PEG_THRESHOLD" ] && [ "${gpu:-0}" -lt "$GPU_MIN_UTIL" ]; then
      consec=$((consec+1))
    else
      consec=0
    fi
    if [ "$consec" -ge "$CPU_PEG_WINDOW" ]; then
      return 10
    fi
    sleep 0.5
  done
}
FUNCS
fi

# 3) Replace bench_once() body
START_RE='^[[:space:]]*bench_once\(\)[[:space:]]*\{[[:space:]]*$'
END_RE='^[[:space:]]*\}[[:space:]]*$'
TMP="$(mktemp)"
cat >"$TMP" <<'NEWFN'
bench_once(){ # ep baseTag modelTag label num_gpu gpu_label
  local ep="$1" base="$2" model="$3" label="$4" ng="${5:-}" gpu_lbl="$6"
  local sfx unit gname guid gmem opts tokps="0.00" ec=0 ed=1 o tmp rc=0
  sfx="$(suffix_for_ep "$ep")"
  unit="$(unit_for_ep "$ep")"
  IFS=',' read -r gname guid gmem <<<"$(offload_triplet "$unit")"

  if [ -n "${ng:-}" ]; then
    opts="$(jq -n --argjson ng "$ng" '{num_gpu:$ng}')" || opts='{"num_gpu":'"${ng}"'}'
  else
    opts='{}'
  fi

  tmp="$(mktemp)"
  if [ "$label" = "optimized" ] && [ "${CPU_PEG_MONITOR}" -eq 1 ]; then
    curl_gen "$ep" "$model" "$opts" "$PROMPT" "$TIMEOUT_GEN" >"$tmp" 2>/dev/null &
    gen_pid=$!
    monitor_cpu_gpu "$unit" "$guid" "$TIMEOUT_GEN" &
    mon_pid=$!
    wait -n "$gen_pid" "$mon_pid" || true
    rc=$?
    if [ "$rc" -eq 10 ]; then
      kill -TERM "$gen_pid" 2>/dev/null || true
      wait "$gen_pid" 2>/dev/null || true
      record_cpu_abandoned "$ep" "$base" "$model" "${ng:-}" "$gpu_lbl"
      [ "${KEEP_FAILED_VARIANTS}" -eq 0 ] && rm_variant_tag "$model" || true
      label="optimized-cpu-bound"
      ec=0; ed=1; tokps="0.00"
    else
      if [ -s "$tmp" ]; then
        ec="$(jq -r '.eval_count // 0' "$tmp" 2>/dev/null || echo 0)"
        ed="$(jq -r '.eval_duration // 0' "$tmp" 2>/dev/null || echo 1)"
        tokps="$(calc_tokps "$ec" "$ed")"
      fi
    fi
  else
    o="$(curl_gen "$ep" "$model" "$opts" "$PROMPT" "$TIMEOUT_GEN" || true)"
    if [ -n "$o" ]; then
      ec="$(jq -r '.eval_count // 0' <<<"$o" 2>/dev/null || echo 0)"
      ed="$(jq -r '.eval_duration // 0' <<<"$o" 2>/dev/null || echo 1)"
      tokps="$(calc_tokps "$ec" "$ed")"
    fi
  fi
  rm -f "$tmp" 2>/dev/null || true

  append_csv_row "${HOSTNAME_NOW},${TS},${ep},${gname},${guid},${label},${model},${ng:-},${sfx},${ec:-0},${ed:-1},${tokps}"

  if [ "$label" = "optimized" ] && awk -v t="$tokps" 'BEGIN{exit !(t+0==0)}'; then
    [ "${KEEP_FAILED_VARIANTS}" -eq 0 ] && rm_variant_tag "$model" || true
  fi

  echo "$tokps"
}
NEWFN
"$REPLACE_BIN" "$TARGET" "$START_RE" "$END_RE" "$TMP" "$BACKUP_EXT"
rm -f "$TMP"

# 4) Add CPU-abandoned section in final summary if not present
if ! grep -q 'Abandoned optimized variants (CPU-bound):' "$TARGET"; then
  # insert right after the "No optimized variants..." / success branch
  sed -i '/No optimized variants succeeded\./a \
  \
  \  # CPU-bound abandoned optimized variants (if any)\n\
  \  if [ -s "${CPU_ABANDONED_FILE}" ]; then\n\
  \    echo\n\
  \    echo "Abandoned optimized variants (CPU-bound):"\n\
  \    column -t -s'\'','\'' "${CPU_ABANDONED_FILE}" 2>/dev/null || cat "${CPU_ABANDONED_FILE}"\n\
  \  fi\n' "$TARGET"
fi

echo "[ok] Patched CPU watchdog & summary into: $TARGET"

