#!/usr/bin/env bash
# llm.sh - Standalone LLM model baking script
# Extracts baking functionality from refinery

set -euo pipefail

# Parameters
newname="$1"
base="$2"
ng="$3"
pull_from="$4"
ollama_bin="$5"
create_log="$6"
created_list="$7"

# Create baked output directory if it doesn't exist
baked_dir="/FuZe/baked/llm"
mkdir -p "$baked_dir"

# Create Modelfile content directly (no temp file)
modelfile_content="FROM ${base}
PARAMETER num_gpu ${ng}"

# Create the variant
if echo "$modelfile_content" | OLLAMA_HOST="http://${pull_from}" "$ollama_bin" create "$newname" -f - >>"$create_log" 2>&1; then
    echo "$newname" >> "$created_list"
    exit 0
else
    exit 1
fi