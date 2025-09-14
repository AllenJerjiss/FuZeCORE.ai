#!/usr/bin/env bash
# shim: deprecated — call llama.cpp/import-gguf-from-ollama.sh
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../llama.cpp/import-gguf-from-ollama.sh" "$@"
