#!/usr/bin/env bash
## Step 1: Clean all artifacts, variants, and services
"$ORCH" ollama service-cleanup
"$ORCH" ollama store-cleanup
"$ORCH" ollama cleanup-variantsine-and-bake-ollama-gpt-oss-20b-std.sh
# Pre-canned deployment configuration for GPT-OSS-20B with standard mode and baking

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="${SCRIPT_DIR}/REFINERY/stack/orchestrator.sh"

echo "=== GPT-OSS-20B Standard Mode Refinement & Baking ==="
echo "Workflow: Clean → Install → Benchmark with Baking"
echo


if [ ! -f "$ORCH" ]; then
    echo "ERROR: orchestrator.sh not found at: $ORCH" >&2
    exit 1
fi

echo
echo Step 1: Clean all artifacts, variants, and services
"$ORCH" ollama cleanup-variants
"$ORCH" ollama store-cleanup
"$ORCH" ollama service-cleanup


echo
echo "Step 2: Installing Ollama stack..."
sudo "$ORCH" ollama install


#echo
echo "Step 3: Running benchmark with baking (standard mode, GPU 0)..."
"$ORCH" --gpu 0,1,2 ollama benchmark --model gpt-oss-20b

echo
echo "=== Workflow Complete ==="
echo "Results available in:"
echo "  Logs/CSVs: /var/log/fuze-stack/"
echo "  Baked models: /FuZe/baked/ollama/"
echo

# Run analysis on the latest CSV
echo "=== Analysis Results ==="
LATEST_CSV=$(ls -t /var/log/fuze-stack/ollama_bench_*.csv 2>/dev/null | head -1)
if [ -n "$LATEST_CSV" ]; then
    "$ORCH" analyze --stack ollama --csv "$LATEST_CSV"
else
    echo "No CSV files found for analysis"
fi