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

 # Always create baked output directory
baked_dir="/FuZe/baked/ollama"
mkdir -p "$baked_dir"
if [ ! -w "$baked_dir" ]; then
    echo "ERROR: Cannot write to baked directory: $baked_dir" >&2
    exit 1
fi

# Ensure directory is accessible
if [ ! -w "$baked_dir" ]; then
    echo "ERROR: Cannot write to baked directory: $baked_dir" >&2
    exit 1
fi

# Create Modelfile content in a temp file
temp_modelfile="/tmp/modelfile.$$"
cat > "$temp_modelfile" <<EOF
FROM ${base}
PARAMETER num_gpu ${ng}
EOF

# Create the variant
if OLLAMA_HOST="http://${pull_from}" "$ollama_bin" create "$newname" -f "$temp_modelfile" >>"$create_log" 2>&1; then
    rm -f "$temp_modelfile"
    echo "$newname" >> "$created_list"
    exit 0
else
    rm -f "$temp_modelfile"
    exit 1
fi