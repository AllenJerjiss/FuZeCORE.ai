#!/usr/bin/env bash
# cleanup-variants.sh — Remove benchmark-created variants from Ollama store
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/common.sh"
init_common "cleanup-variants"

info "Checking for benchmark-created variants to remove..."

# Find all models with 'FuZe' in their name, get the first column (the name)
# We use `grep ... || true` to prevent the script from exiting if no matches are found
variants_to_remove=$(ollama ls | grep 'FuZe' || true | awk '{print $1}')

if [ -z "$variants_to_remove" ]; then
  info "No benchmark-created variants found to remove."
  exit 0
fi

# Loop over each found variant and remove it
while IFS= read -r variant; do
  info "Removing variant: $variant"
  if ! ollama rm "$variant"; then
    warn "Failed to remove variant: $variant"
  fi
done <<< "$variants_to_remove"

info "Variant cleanup complete."

