#!/usr/bin/env bash
# triton-benchmark.sh
set -euo pipefail

STACK="triton"
LOG_DIR="${LOG_DIR:-/FuZe/logs}"
RUN_TS="${RUN_TS:-$(date +%Y%m%d_%H%M%S)}"
CSV_FILE="${LOG_DIR}/${STACK}_bench_${RUN_TS}.csv"
echo "ts,stack,endpoint,unit,suffix,gpu_label,model,variant,num_gpu,num_ctx,batch,num_predict,tokens_per_sec,gpu_name,gpu_uuid,gpu_mem_mib,notes" >"$CSV_FILE"

TRITON_MODEL_REPO="${TRITON_MODEL_REPO:-}"   # e.g. /opt/triton-model-repo
TRITON_IMAGE="${TRITON_IMAGE:-nvcr.io/nvidia/tritonserver:24.05-py3}"
MODEL_NAME="${MODEL_NAME:-tllm_llama}"       # directory name in model repo
CTX="${CTX:-1024}"
BATCH="${BATCH:-32}"
PRED="${PRED:-256}"

if [ -z "$TRITON_MODEL_REPO" ] || [ ! -d "$TRITON_MODEL_REPO" ]; then
  echo "! TRITON_MODEL_REPO not set or missing. Skipping Triton."
  exit 0
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "! docker not found. Skipping Triton."
  exit 0
fi

gpu_table(){ nvidia-smi --query-gpu=index,uuid,name,memory.total --format=csv,noheader | sed 's/, /,/g'; }
gpu_label(){
  local name="$(echo "$1" | tr 'A-Z' 'a-z')"
  local suffix="$(echo "$name" | sed -E 's/.*rtx[[:space:]]*([0-9]{4}([[:space:]]*ti)?).*/\1/' | tr -d ' ')"
  [ -z "$suffix" ] && suffix="$(echo "$name" | grep -oE '[0-9]{4}(ti)?' | head -n1)"
  suffix="$(echo "$suffix" | tr -d ' ')"
  [ -z "$suffix" ] && { echo "nvidia"; return; }
  echo "nvidia-${suffix}"
}

# Start Triton (ephemeral)
CONTAINER_NAME="triton-${RUN_TS}"
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker run -d --gpus all --name "$CONTAINER_NAME" \
  -p8000:8000 -p8001:8001 -p8002:8002 \
  -v "${TRITON_MODEL_REPO}:/models" \
  "$TRITON_IMAGE" tritonserver --model-repository=/models >/dev/null

# Wait a bit for readiness
for i in {1..30}; do
  curl -fsS http://127.0.0.1:8000/v2/health/ready >/dev/null 2>&1 && break
  sleep 1
done

if ! curl -fsS http://127.0.0.1:8000/v2/health/ready >/dev/null 2>&1; then
  echo "! Triton server failed to get ready; skipping."
  docker logs --tail 100 "$CONTAINER_NAME" || true
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  exit 0
fi

# perf_analyzer must be available (in PATH or use container exec)
if command -v perf_analyzer >/dev/null 2>&1; then
  PERF="perf_analyzer"
else
  PERF="docker exec $CONTAINER_NAME perf_analyzer"
fi

# We treat each GPU separately by constraining visible devices for the container run above;
# For simplicity here, we just run once and record system-wide throughput (requests/s -> approx tok/s is model/input dependent).
# If your model repo provides an output tokens metric, adapt parsing here.

# Try a generic perf_analyzer call:
OUT="$($PERF -m "$MODEL_NAME" -u 127.0.0.1:8001 -i grpc -p 2000 --concurrency-range $BATCH:$BATCH 2>&1 || true)"
THROUGHPUT="$(echo "$OUT" | grep -i 'Inferences/Second' | tail -n1 | awk '{print $NF}' )"
[ -z "$THROUGHPUT" ] && THROUGHPUT="0.00"

# Record one line with “notes=triton_inferences_per_second”
# GPU info (first GPU for label)
read -r idx uuid name mem <<<"$(gpu_table | head -n1 | awk -F',' '{print $1" "$2" "$3" "$4}')"
gpul="$(gpu_label "$name")"
echo "$(date -Iseconds),$STACK,127.0.0.1:8001,triton,NA,$gpul,$MODEL_NAME,$MODEL_NAME,default,$CTX,$BATCH,$PRED,$THROUGHPUT,$name,$uuid,${mem%% MiB},triton_inferences_per_second" >>"$CSV_FILE"

docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
echo "✔ DONE. CSV: ${CSV_FILE}"

