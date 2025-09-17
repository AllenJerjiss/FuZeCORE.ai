#!/bin/bash
# Test the GPU labeling functions

cd "$(dirname "$0")/LLM/refinery/stack/ollama"
source ollama-benchmark.sh

echo "Testing GPU label for endpoint 127.0.0.1:11435 (should be 3090ti):"
gpu_label_for_ep "127.0.0.1:11435"
echo

echo "Testing GPU label for endpoint 127.0.0.1:11434 (should be persistent):"
gpu_label_for_ep "127.0.0.1:11434"