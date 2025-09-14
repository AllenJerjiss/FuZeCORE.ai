#!/usr/bin/env bash
# generate-envs.sh — Render per-model .env files from a template
# - Discovers models from an Ollama daemon (default: 127.0.0.1:11434)
# - Renders template placeholders for each model and writes into a dest folder
# - Safe by default: does not overwrite unless --overwrite is passed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Default single-run template/dest (used when --template/--dest provided)
TEMPLATE="${TEMPLATE:-}"            # if empty, we'll choose by --mode
DEST_DIR="${DEST_DIR:-}"            # if empty, we'll choose by --mode
# Predefined templates and dests for modes
TPL_EXP="${SCRIPT_DIR}/templates/FuZeCORE-explore.env.template"
TPL_PRE="${SCRIPT_DIR}/templates/FuZeCORE-preprod.env.template"
DEST_EXP="${SCRIPT_DIR}/explore"
DEST_PRE="${SCRIPT_DIR}/preprod"
INCLUDE_RE="${INCLUDE_RE:-}"   # optional regex to filter models
HOST="${HOST:-127.0.0.1:11434}"
OVERWRITE=0
DRY_RUN=0
MODE="both"   # one of: explore | preprod | both | custom
PROMOTE=0
PROMOTE_ALL=0
PROMOTE_RE=""
OLLAMA_BIN="${OLLAMA_BIN:-/usr/local/bin/ollama}"

usage(){
  cat <<USAGE
Usage: $(basename "$0") [--mode explore|preprod|both] [--template FILE] [--dest DIR] [--include REGEX] [--host HOST:PORT] [--overwrite] [--dry-run] [--promote (--all|--model REGEX)]
Env:
  MODE       (default: both; ignored if TEMPLATE/DEST_DIR provided)
  TEMPLATE   (custom single-run)
  DEST_DIR   (custom single-run)
  INCLUDE_RE (optional regex to filter models when generating)
  HOST       (default: ${HOST})
  OLLAMA_BIN (default: ${OLLAMA_BIN})
  PROMOTE    If set with --promote, copies preprod env(s) to prod (immutable)
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --template) TEMPLATE="$2"; shift 2;;
    --dest)     DEST_DIR="$2"; shift 2;;
    --mode)     MODE="$2"; shift 2;;
    --include)  INCLUDE_RE="$2"; shift 2;;
    --host)     HOST="$2"; shift 2;;
    --overwrite) OVERWRITE=1; shift 1;;
    --dry-run)   DRY_RUN=1; shift 1;;
    --promote)  PROMOTE=1; shift 1;;
    --all)      PROMOTE_ALL=1; shift 1;;
    --model)    PROMOTE_RE="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

gen_one(){ # template dest
  local tpl="$1" dest="$2";
  [ -f "$tpl" ] || { echo "Template not found: $tpl" >&2; return 2; }
  mkdir -p "$dest"
  # Extract ALIAS_PREFIX from the template (fallback FuZeCORE-)
  local prefix
  prefix=$(sed -nE "s/^ALIAS_PREFIX=\"?([^\"]*)\"?.*/\1/p" "$tpl" | tail -n1)
  [ -n "$prefix" ] || prefix="FuZeCORE-"

  local count=0 made=0 skip=0
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    if [ -n "$INCLUDE_RE" ] && ! echo "$tag" | grep -Eq "$INCLUDE_RE"; then continue; fi
    count=$((count+1))
    alias=$(aliasify "$tag")
    out="$dest/${prefix}${alias}.env"
    if [ -f "$out" ] && [ "$OVERWRITE" -ne 1 ]; then
      echo "skip (exists): $(basename "$out")"
      skip=$((skip+1))
      continue
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "plan write : $(basename "$out")  (MODEL_TAG=$tag)"
      continue
    fi
    sed -E "s/__MODEL_TAG__/${tag//\//\\/}/g" "$tpl" > "$out" || { echo "write failed: $out" >&2; return 1; }
    echo "wrote       : $(basename "$out")"
    made=$((made+1))
  done <<< "$models"

  echo "Summary: models=${count} written=${made} skipped=${skip} dest=${dest} template=$(basename "$tpl")"
}

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 2; }; }
need awk; need sed; need tr

# Helper: aliasify a model tag (llama4:16x17b -> llama4-16x17b)
aliasify(){ echo "$1" | sed -E 's#[/:]+#-#g'; }

# Discover models from persistent daemon
if ! command -v "$OLLAMA_BIN" >/dev/null 2>&1; then
  echo "ollama binary not found: $OLLAMA_BIN" >&2
  exit 2
fi

models=$( OLLAMA_HOST="http://${HOST}" "$OLLAMA_BIN" list 2>/dev/null | awk '($1!="" && $1!="NAME"){print $1}' )

# Promotion-only path (copy preprod envs to prod)
if [ "$PROMOTE" -eq 1 ]; then
  SRC_DIR="$DEST_PRE"
  DST_DIR="${SCRIPT_DIR}/prod"
  mkdir -p "$DST_DIR"
  shopt -s nullglob
  copied=0; total=0
  for f in "$SRC_DIR"/*.env; do
    [ -f "$f" ] || continue
    total=$((total+1))
    if [ "$PROMOTE_ALL" -eq 1 ]; then
      cp -f "$f" "$DST_DIR/" && { echo "promoted: $(basename "$f")"; copied=$((copied+1)); }
      continue
    fi
    if [ -n "$PROMOTE_RE" ]; then
      inc_tag=$(awk -F"'" '/^INCLUDE_MODELS=/{print $2; exit}' "$f" 2>/dev/null | sed -E 's/^\^//; s/\$$//')
      bn=$(basename "$f")
      if echo "$bn" | grep -Eq "$PROMOTE_RE" || { [ -n "$inc_tag" ] && echo "$inc_tag" | grep -Eq "$PROMOTE_RE"; }; then
        cp -f "$f" "$DST_DIR/" && { echo "promoted: $(basename "$f")"; copied=$((copied+1)); }
      fi
    fi
  done
  shopt -u nullglob
  echo "Promotion summary: copied=${copied} from=${SRC_DIR} to=${DST_DIR}"
  exit 0
fi

# Decide single-run vs multi-mode
if [ -n "${TEMPLATE}" ] || [ -n "${DEST_DIR}" ]; then
  # custom single-run
  [ -n "$TEMPLATE" ] || { echo "TEMPLATE not specified; use --template or rely on --mode" >&2; exit 2; }
  [ -n "$DEST_DIR" ] || { echo "DEST_DIR not specified; use --dest or rely on --mode" >&2; exit 2; }
  gen_one "$TEMPLATE" "$DEST_DIR"
else
  case "$MODE" in
    explore) gen_one "$TPL_EXP" "$DEST_EXP" ;;
    preprod) gen_one "$TPL_PRE" "$DEST_PRE" ;;
    both|*)  gen_one "$TPL_EXP" "$DEST_EXP"; echo; gen_one "$TPL_PRE" "$DEST_PRE" ;;
  esac
fi
