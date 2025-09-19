#!/usr/bin/env bash
# store-cleanup.sh — Normalize Ollama model storage
set -euo pipefail

if ! command -v ollama &>/dev/null; then
	echo "ERROR: ollama CLI not found. Please install Ollama and ensure it is in your PATH." >&2
	exit 1
fi

# Remove incomplete models
for model in $(ollama list | grep 'incomplete' | awk '{print $1}'); do
	ollama rm "$model" && echo "Removed incomplete model: $model"
done
# Remove broken models (if any are marked as broken)
for model in $(ollama list | grep 'broken' | awk '{print $1}'); do
	ollama rm "$model" && echo "Removed broken model: $model"
done
# Remove all FuZe-related models
for model in $(ollama list | grep 'FuZe-' | awk '{print $1}'); do
	ollama rm "$model" && echo "Removed FuZe model: $model"
done
echo "Ollama store cleanup complete."
