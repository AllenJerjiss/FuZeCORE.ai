#!/usr/bin/env bash
# refine-and-bake-ollama-gpt-oss-20b-std.sh
# Pre-canned deployment configuration for GPT-OSS-20B with standard mode and baking

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRACKER="${SCRIPT_DIR}/LLM/refinery/cracker.sh"

echo "=== GPT-OSS-20B Standard Mode Refinement & Baking ==="
echo "Workflow: Clean → Install → Benchmark with Baking"
echo

# Verify cracker exists
if [ ! -f "$CRACKER" ]; then
    echo "ERROR: Cracker not found at: $CRACKER" >&2
    exit 1
fi

# Step 1: Clean everything
echo "Step 1: Cleaning all artifacts..."
"$CRACKER" --clean-all --stack ollama

# Clean baked models directory
echo "Cleaning baked models..."
rm -rf /FuZe/baked/llm/*

# Step 2: Install Ollama stack
echo
echo "Step 2: Installing Ollama stack..."
"$CRACKER" --stack ollama --install

# Step 3: Run benchmark with standard mode (baking enabled, GPU 0)
echo
echo "Step 3: Running benchmark with baking (standard mode, GPU 0)..."
"$CRACKER" --stack ollama --gpu 0 --model gpt-oss-20b

echo
echo "=== Workflow Complete ==="
echo "Results available in:"
echo "  Logs/CSVs: /var/log/fuze-stack/"
echo "  Baked models: /FuZe/baked/llm/"
echo

# Run analysis on the latest CSV
echo "=== Analysis Results ==="
LATEST_CSV=$(ls -t /var/log/fuze-stack/ollama_bench_*.csv 2>/dev/null | head -1)
if [ -n "$LATEST_CSV" ]; then
    "$SCRIPT_DIR/LLM/refinery/stack/common/analyze.sh" --stack ollama --csv "$LATEST_CSV"
else
    echo "No CSV files found for analysis"
fi