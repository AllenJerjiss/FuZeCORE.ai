#!/bin/bash
# Nuclear cleanup wrapper for ollama - removes ALL models and data
# WARNING: This script will destroy all ollama data

set -euo pipefail

echo "WARNING: This will delete ALL ollama models and data"
echo "Current ollama data size: $(du -sh /FuZe/ollama 2>/dev/null || echo 'N/A')"
echo "Press Ctrl+C to abort, or wait 10 seconds to continue..."
sleep 10

# Stop all ollama services
systemctl stop ollama.service ollama-test-a.service ollama-test-b.service 2>/dev/null || true

# Kill any remaining ollama processes
pkill -f ollama || true
sleep 2

# Remove all model data
rm -rf /FuZe/ollama/manifests/*
rm -rf /FuZe/ollama/blobs/*
rm -rf /FuZe/baked/ollama/*

echo "Nuclear cleanup completed - all ollama data removed"
