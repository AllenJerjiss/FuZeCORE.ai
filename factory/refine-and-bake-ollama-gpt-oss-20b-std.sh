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

# Step 2: Install Ollama stack
echo
echo "Step 2: Installing Ollama stack..."
"$CRACKER" --stack ollama --install

# Step 3: Run benchmark with standard mode (baking enabled)
echo
echo "Step 3: Running benchmark with baking (standard mode)..."
"$CRACKER" --stack ollama --model gpt-oss-20b

echo
echo "=== Workflow Complete ==="
echo "Results available in: /var/log/fuze-stack/"
echo "Analysis: $SCRIPT_DIR/LLM/refinery/stack/common/analyze.sh --stack ollama"