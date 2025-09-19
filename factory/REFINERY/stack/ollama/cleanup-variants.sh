echo "[cleanup-variants.sh] No variant cleanup implemented yet."
#!/usr/bin/env bash
# cleanup-variants.sh — Remove benchmark-created variants from Ollama store
set -euo pipefail

if ! command -v ollama &>/dev/null; then
	echo "ERROR: ollama CLI not found. Please install Ollama and ensure it is in your PATH." >&2
	exit 1
fi

VARIANTS_TO_REMOVE=$(ollama list | grep "FuZe" | awk '{print $1}')
if [ -z "$VARIANTS_TO_REMOVE" ]; then
	echo "No variants containing 'FuZe' found in Ollama store."
	exit 0
fi
for variant in $VARIANTS_TO_REMOVE; do
	ollama rm "$variant" && echo "Removed variant: $variant"
done
