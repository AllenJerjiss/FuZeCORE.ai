#!/usr/bin/env bash
# import-gguf-from-ollama.sh — Import GGUFs from Ollama models and build a mapping for llama.cpp
# - Enumerates models from an Ollama daemon and runs `ollama export` for those
#   that can be exported to GGUF
# - Writes GGUF files into a destination directory (default: /FuZe/models/gguf)
# - Optionally generates an env file with LLAMACPP_PATH_<alias>=<gguf_path>
# - Skips known benchmark variants (name pattern: -nvidia-...-ngNN) by default

set -euo pipefail

DEST_DIR="${DEST_DIR:-/FuZe/models/gguf}"
HOST="${HOST:-127.0.0.1:11434}"
INCLUDE_RE="${INCLUDE_RE:-}"
EXCLUDE_RE="${EXCLUDE_RE:-}"
SKIP_VARIANTS="${SKIP_VARIANTS:-1}"
OVERWRITE="${OVERWRITE:-0}"
DRY_RUN="${DRY_RUN:-0}"
ENV_OUT="${ENV_OUT:-}"
LOG_DIR="${LOG_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/logs}"
OLLAMA_BIN="${OLLAMA_BIN:-$(command -v ollama || true)}"
# Filter out models very unlikely to be exportable to GGUF
AUTO_FILTER_NON_GGUF="${AUTO_FILTER_NON_GGUF:-1}"

usage(){
  cat <<USAGE
Usage: $(basename "$0") [--dest DIR] [--host HOST:PORT] [--include REGEX] [--exclude REGEX]
                        [--no-skip-variants] [--overwrite] [--dry-run] [--env-out FILE]

Options:
  --dest DIR            Destination directory for GGUFs (default: $DEST_DIR)
  --host HOST:PORT      Ollama host:port to query/export from (default: $HOST)
  --include REGEX       Only export models matching this regex (optional)
  --exclude REGEX       Exclude models matching this regex (optional)
  --no-skip-variants    Include bench variants (default skips -nvidia-...-ngNN)
  --overwrite           Overwrite existing GGUF files (default: skip if exists)
  --dry-run             Print planned actions without exporting
  --env-out FILE        Write LLAMACPP_PATH_<alias>=<path> lines to FILE
                        (default: LLM/refinery/stack/llama.cpp/models.env)
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dest) DEST_DIR="$2"; shift 2;;
    --host) HOST="$2"; shift 2;;
    --include) INCLUDE_RE="$2"; shift 2;;
    --exclude) EXCLUDE_RE="$2"; shift 2;;
    --no-skip-variants) SKIP_VARIANTS=0; shift;;
    --overwrite) OVERWRITE=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    --env-out) ENV_OUT="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

if [ -z "${OLLAMA_BIN:-}" ] || [ ! -x "$OLLAMA_BIN" ]; then
  echo "✖ 'ollama' not found. Set OLLAMA_BIN or install Ollama." >&2
  exit 1
fi

# Verify that this Ollama build supports the 'export' subcommand
EXPORT_SUPPORTED=0
if "$OLLAMA_BIN" help 2>&1 | grep -Eq '(^|[[:space:]])export([[:space:]]|$)'; then
  EXPORT_SUPPORTED=1
fi

mkdir -p "$DEST_DIR" "$LOG_DIR"
TS="$(date +%Y%m%d_%H%M%S)"
CSV_OUT="${LOG_DIR}/ollama_export_${TS}.csv"
echo "model_tag,gguf_path,size_bytes,host,status" > "$CSV_OUT"
ERR_DIR="${ERR_DIR:-${LOG_DIR}/export_errors_${TS}}"
mkdir -p "$ERR_DIR"

base_alias(){ echo "$1" | sed -E 's#[/:]+#-#g'; }
env_key(){ echo "$1" | tr -c '[:alnum:]' '_' ; }

list_models(){
  OLLAMA_HOST="http://${HOST}" "$OLLAMA_BIN" list 2>/dev/null | awk 'NR>1 && $1!=""{print $1}'
}

should_keep(){
  local name="$1"
  if [ -n "$INCLUDE_RE" ] && ! echo "$name" | grep -Eq "$INCLUDE_RE"; then return 1; fi
  if [ -n "$EXCLUDE_RE" ] && echo "$name" | grep -Eq "$EXCLUDE_RE"; then return 1; fi
  if [ "$SKIP_VARIANTS" -eq 1 ] && echo "$name" | grep -Eq -- '-nvidia-[a-z0-9]+(super|ti)?-ng[0-9]+(:|$)'; then return 1; fi
  if [ "$AUTO_FILTER_NON_GGUF" -eq 1 ]; then
    # Skip obvious non-GGUF exportables: llama4 MoE families, DeepSeek R1, large MoE forms, embeddings
    if echo "$name" | grep -Eq '^(llama4:|deepseek-r1:)' ; then return 1; fi
    if echo "$name" | grep -Eq ':[0-9]+x[0-9]+b(:|$)'; then return 1; fi
    if echo "$name" | grep -Eiq '(embed|embedding)'; then return 1; fi
  fi
  return 0
}

export_one(){ # model_tag -> status
  local tag="$1" alias out tmp dest rc size
  alias="$(base_alias "$tag")"
  dest="${DEST_DIR}/${alias}.gguf"
  if [ -e "$dest" ] && [ "$OVERWRITE" -ne 1 ]; then
    echo "SKIP existing: $dest"
    size="$(stat -c '%s' "$dest" 2>/dev/null || echo 0)"
    echo "$tag,$dest,$size,$HOST,exists" >> "$CSV_OUT"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY export: $tag -> $dest"
    echo "$tag,$dest,0,$HOST,dry-run" >> "$CSV_OUT"
    return 0
  fi
  tmp="${dest}.tmp"
  local errf
  errf="${ERR_DIR}/$(echo "$alias" | tr -c '[:alnum:].-_' '_').stderr.log"
  if [ "$EXPORT_SUPPORTED" -eq 1 ]; then
    if OLLAMA_HOST="http://${HOST}" "$OLLAMA_BIN" export "$tag" > "$tmp" 2>"$errf"; then
      mv -f "$tmp" "$dest"
      size="$(stat -c '%s' "$dest" 2>/dev/null || echo 0)"
      echo "OK  export: $tag -> $dest (${size} bytes)"
      echo "$tag,$dest,$size,$HOST,exported" >> "$CSV_OUT"
      return 0
    else
      rc=$?
      rm -f "$tmp" 2>/dev/null || true
      # capture a short reason snippet
      local reason
      reason="$(head -c 200 "$errf" | tr '\n' ' ' | sed 's/,/;/g')"
      echo "NO  export: $tag (ollama export failed, rc=$rc) ${reason:+— $reason}"
      echo "$tag,$dest,0,$HOST,failed${reason:+:$reason}" >> "$CSV_OUT"
      # try fallback below
    fi
  fi

  # Fallback: manifest-based blob copy if GGUF
  local base ns name_tag name ver mfroot mfpath digest blob
  base="$tag"
  ns="${base%%/*}"
  name_tag="${base#*/}"
  if [ "$ns" = "$base" ]; then ns="library"; name_tag="$base"; fi
  name="${name_tag%%:*}"
  ver="${name_tag#*:}"
  mfroot="/FuZe/models/ollama/manifests/registry.ollama.ai"
  if [ "$ver" = "$name_tag" ]; then
    mfpath="${mfroot}/${ns}/${name}"
  else
    mfpath="${mfroot}/${ns}/${name}/${ver}"
  fi
  if [ -f "$mfpath" ]; then
    # Extract model-layer digest from manifest (prefer jq)
    if command -v jq >/dev/null 2>&1; then
      digest="$(jq -r '.layers[] | select(.mediaType=="application/vnd.ollama.image.model") | .digest' "$mfpath" 2>/dev/null | sed 's/^sha256://;q')"
    fi
    if [ -z "${digest:-}" ]; then
      digest="$(grep -o '"mediaType":"application/vnd.ollama.image.model"[^}]*"digest":"sha256:[0-9a-f]\{64\}"' "$mfpath" 2>/dev/null \
                 | sed -n 's/.*"digest":"sha256:\([0-9a-f]\{64\}\)".*/\1/p' | head -n1)"
    fi
    if [ -n "$digest" ]; then
      blob="/FuZe/models/ollama/blobs/sha256-${digest}"
      if [ -f "$blob" ]; then
        if head -c 4 "$blob" 2>/dev/null | grep -q '^GGUF'; then
          if [ "$DRY_RUN" -eq 1 ]; then
            echo "DRY export(manifest): $tag -> $dest (blob=$blob)"
            echo "$tag,$dest,0,$HOST,dry-run(manifest)" >> "$CSV_OUT"
            return 0
          fi
          cp -f "$blob" "$tmp" && mv -f "$tmp" "$dest"
          size="$(stat -c '%s' "$dest" 2>/dev/null || echo 0)"
          echo "OK  export(manifest): $tag -> $dest (${size} bytes)"
          echo "$tag,$dest,$size,$HOST,exported(manifest)" >> "$CSV_OUT"
          return 0
        else
          echo "NO  export: $tag (blob not GGUF)" | tee -a "$errf" >/dev/null
        fi
      else
        echo "NO  export: $tag (blob missing: $blob)" | tee -a "$errf" >/dev/null
      fi
    else
      echo "NO  export: $tag (model layer digest not found in manifest)" | tee -a "$errf" >/dev/null
    fi
  else
    echo "NO  export: $tag (manifest not found: $mfpath)" | tee -a "$errf" >/dev/null
  fi

  echo "$tag,$dest,0,$HOST,failed:fallback" >> "$CSV_OUT"
  return 1
}

ENV_OUT_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/llama.cpp/models.env"
[ -z "$ENV_OUT" ] && ENV_OUT="$ENV_OUT_DEFAULT"
echo "# Autogenerated $(date -Iseconds) from $(basename "$0")" > "$ENV_OUT"

count=0; kept=0; exp_ok=0; exp_fail=0
while IFS= read -r tag; do
  [ -n "$tag" ] || continue
  count=$((count+1))
  if should_keep "$tag"; then
    kept=$((kept+1))
    if export_one "$tag"; then
      alias="$(base_alias "$tag")"
      key="LLAMACPP_PATH_$(env_key "$alias")"
      echo "export ${key}=${DEST_DIR}/${alias}.gguf" >> "$ENV_OUT"
      exp_ok=$((exp_ok+1))
    else
      exp_fail=$((exp_fail+1))
    fi
  fi
done < <(list_models)

echo
echo "Summary: found=$count kept=$kept exported=$exp_ok failed=$exp_fail"
echo "CSV: $CSV_OUT"
echo "llama.cpp env mappings: $ENV_OUT"
echo "Errors (if any): $ERR_DIR"
