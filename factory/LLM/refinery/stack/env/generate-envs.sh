#!/usr/bin/env bash
# generate-envs.sh — Render per-model .env files from a template
# - Discovers models from an Ollama daemon (default: 127.0.0.1:11434)
# - Renders template placeholders for each model and writes into a dest folder
# - Safe by default: does not overwrite unless --overwrite is passed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${TEMPLATE:-${SCRIPT_DIR}/templates/FuZeCORE-bench.env.template}"
DEST_DIR="${DEST_DIR:-${SCRIPT_DIR}/explore}"
INCLUDE_RE="${INCLUDE_RE:-}"   # optional regex to filter models
HOST="${HOST:-127.0.0.1:11434}"
OVERWRITE=0
DRY_RUN=0
OLLAMA_BIN="${OLLAMA_BIN:-/usr/local/bin/ollama}"

usage(){
  cat <<USAGE
Usage: $(basename "$0") [--template FILE] [--dest DIR] [--include REGEX] [--host HOST:PORT] [--overwrite] [--dry-run]
Env:
  TEMPLATE   (default: ${TEMPLATE})
  DEST_DIR   (default: ${DEST_DIR})
  INCLUDE_RE (optional regex to filter models)
  HOST       (default: ${HOST})
  OLLAMA_BIN (default: ${OLLAMA_BIN})
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --template) TEMPLATE="$2"; shift 2;;
    --dest)     DEST_DIR="$2"; shift 2;;
    --include)  INCLUDE_RE="$2"; shift 2;;
    --host)     HOST="$2"; shift 2;;
    --overwrite) OVERWRITE=1; shift 1;;
    --dry-run)   DRY_RUN=1; shift 1;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

[ -f "$TEMPLATE" ] || { echo "Template not found: $TEMPLATE" >&2; exit 2; }
mkdir -p "$DEST_DIR"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 2; }; }
need awk; need sed; need tr

# Helper: aliasify a model tag (llama4:16x17b -> llama4-16x17b)
aliasify(){ echo "$1" | sed -E 's#[/:]+#-#g'; }

# Extract ALIAS_PREFIX from the template (fallback FuZeCORE-)
TPL_PREFIX=$(sed -nE "s/^ALIAS_PREFIX=\"?([^\"]*)\"?.*/\1/p" "$TEMPLATE" | tail -n1)
[ -n "$TPL_PREFIX" ] || TPL_PREFIX="FuZeCORE-"

# Discover models from persistent daemon
if ! command -v "$OLLAMA_BIN" >/dev/null 2>&1; then
  echo "ollama binary not found: $OLLAMA_BIN" >&2
  exit 2
fi

models=$(
  OLLAMA_HOST="http://${HOST}" "$OLLAMA_BIN" list 2>/dev/null \
    | awk '($1!="" && $1!="NAME"){print $1}'
)

count=0; made=0; skip=0
while IFS= read -r tag; do
  [ -n "$tag" ] || continue
  if [ -n "$INCLUDE_RE" ] && ! echo "$tag" | grep -Eq "$INCLUDE_RE"; then continue; fi
  count=$((count+1))
  alias=$(aliasify "$tag")
  out="$DEST_DIR/${TPL_PREFIX}${alias}.env"
  if [ -f "$out" ] && [ "$OVERWRITE" -ne 1 ]; then
    echo "skip (exists): $(basename "$out")"
    skip=$((skip+1))
    continue
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "plan write : $(basename "$out")  (MODEL_TAG=$tag)"
    continue
  fi
  # Render template: substitute __MODEL_TAG__ placeholders
  sed -E "s/__MODEL_TAG__/${tag//\//\\/}/g" "$TEMPLATE" > "$out" || { echo "write failed: $out" >&2; exit 1; }
  echo "wrote       : $(basename "$out")"
  made=$((made+1))
done <<< "$models"

echo "Summary: models=${count} written=${made} skipped=${skip} dest=${DEST_DIR}"

