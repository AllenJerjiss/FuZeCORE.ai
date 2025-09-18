#!/usr/bin/env bash
# refine-and-bake-ollama-gpt-oss-20b-std.sh
# Pre-canned deployment configuration for GPT-OSS-20B with standard mode and baking

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRACKER="${SCRIPT_DIR}/REFINERY/cracker.sh"

echo "=== GPT-OSS-20B Standard Mode Refinement & Baking ==="
echo "Workflow: Clean → Install → Benchmark with Baking"
echo

# Step 1:Verify cracker exists
if [ ! -f "$CRACKER" ]; then
    echo "ERROR: Cracker not found at: $CRACKER" >&2
    exit 1
fi

# Step 2: Install Ollama stack
echo
echo "Step 2: Installing Ollama stack..."
sudo "$CRACKER" --stack ollama --install

# Step 3: Run benchmark with standard mode (baking enabled, GPU 0)
echo
echo "Step 3: Running benchmark with baking (standard mode, GPU 0)..."
"$CRACKER" --stack ollama --gpu 1 --model gpt-oss-20b

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
    # Source ANALYZE_BIN from ollama-benchmark.sh
    OLLAMA_BENCHMARK_SH="$SCRIPT_DIR/REFINERY/stack/ollama/ollama-benchmark.sh"
    ANALYZE_BIN="$(grep -E '^ANALYZE_BIN=' "$OLLAMA_BENCHMARK_SH" | cut -d'=' -f2 | tr -d '"')"
    if [ -z "$ANALYZE_BIN" ]; then
        ANALYZE_BIN="$SCRIPT_DIR/REFINERY/stack/common/analyze.sh"
    fi
    "$ANALYZE_BIN" --stack ollama --csv "$LATEST_CSV"
else
    echo "No CSV files found for analysis"
fi