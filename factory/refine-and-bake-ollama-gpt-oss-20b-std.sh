#!/usr/bin/env bash
# Pre-canned deployment configuration for GPT-OSS-20B with standard mode and baking

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="${SCRIPT_DIR}/REFINERY/stack/orchestrator.sh"
CLEAN_BENCH_SCRIPT="${SCRIPT_DIR}/REFINERY/stack/common/clean-bench.sh"

# --- Cleanup Function and Trap ---
# This ensures that no matter how the script exits, services are stopped.
cleanup() {
    echo
    echo "--- Running cleanup ---"
    # The --yes flag is critical here to ensure cleanup actually runs.
    sudo -E "$CLEAN_BENCH_SCRIPT" --yes
    echo "--- Cleanup complete ---"
}
trap cleanup EXIT SIGINT SIGTERM
# --------------------------------

echo "=== GPT-OSS-20B Standard Mode Refinement & Baking ==="
echo "Workflow: Clean → Install → Benchmark with Baking"
echo

# Step 1: Initial cleanup to ensure a clean slate
echo "Step 1: Clean all artifacts, variants, and services"
sudo -E "$CLEAN_BENCH_SCRIPT" --yes
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
# The trap will handle the cleanup, so we can remove the explicit calls here
# to avoid redundancy and rely on the robust trap mechanism.
# sudo -E "$ORCH" ollama cleanup-variants
# sudo -E "$ORCH" ollama service-cleanup


echo
echo "Step 2: Installing Ollama stack..."
# The --try-cache flag is added to ensure we use the local binary if available
sudo -E "$ORCH" ollama install --try-cache


echo
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

