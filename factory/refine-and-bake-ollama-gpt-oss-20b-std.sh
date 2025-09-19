#!/usr/bin/env bash
# Pre-canned deployment configuration for GPT-OSS-20B with standard mode and baking

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="${SCRIPT_DIR}/REFINERY/stack/orchestrator.sh"

echo "=== GPT-OSS-20B Standard Mode Refinement & Baking ==="
echo "Workflow: Clean → Install → Benchmark with Baking"
echo


# Default model
MODEL="gpt-oss-20b"

# Parse arguments
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        --model)
        MODEL="$2"
        shift # past argument
        shift # past value
        ;;
        *)    # unknown option
        shift # past argument
        ;;
    esac
done

if [ ! -f "$ORCH" ]; then
    echo "ERROR: orchestrator.sh not found at: $ORCH" >&2
    exit 1
fi

echo
echo "Step 1: Clean all artifacts, variants, and services"
sudo -E "$ORCH" ollama cleanup-variants
sudo -E "$ORCH" ollama store-cleanup
sudo -E "$ORCH" ollama service-cleanup


echo
echo "Step 2: Installing Ollama stack..."
sudo -E "$ORCH" ollama install


#echo
echo "Step 3: Running benchmark with baking (standard mode)..."
sudo -E "$ORCH" --gpu 0,1,2 ollama bench --model "$MODEL"

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

