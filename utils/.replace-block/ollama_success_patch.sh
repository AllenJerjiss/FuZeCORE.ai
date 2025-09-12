#!/usr/bin/env bash
# patch_ollama_success.sh
# One-shot driver that (a) builds the patch block (inline / stdin / file),
# (b) calls robust replace-block, and (c) validates before/after.

set -euo pipefail

# --- Defaults (override via flags/env) ---------------------------------------
BASE="${BASE:-$HOME/GitHub/FuZeCORE.ai}"
TARGET="${TARGET:-$BASE/fuze-box/stack/ollama/benchmark.sh}"
REPLACE_BIN="${REPLACE_BIN:-$HOME/.replace-block/replace-block}"
BAK_SUFFIX="${BAK_SUFFIX:-.bak}"

# Anchor regexes (inclusive replace)
START_RE="${START_RE:-^\\s*if\\s+\\[\\s+-s\\s+\"\\$\\{SUMMARY_FILE\\}\\.raw\"\\s+\\]\\s*;\\s*then\\s*$}"
END_RE="${END_RE:-^\\s*fi\\s*$}"

# Show before/after and syntax-validate with bash -n
export RB_PRINT="${RB_PRINT:-1}"
export VALIDATE_CMD="${VALIDATE_CMD:-bash -n}"

# --- CLI ---------------------------------------------------------------------
usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --target PATH         Target file to patch (default: $TARGET)
  --start-re REGEX      Start anchor regex (default set)
  --end-re REGEX        End anchor regex (default set)
  --block-file PATH     Read replacement block from this file
  --block-stdin         Read replacement block from STDIN (use with <<'EOF' ... EOF)
  --backup-suffix S     Backup suffix (default: $BAK_SUFFIX)
  --replace-bin PATH    Path to replace-block (default: $REPLACE_BIN)
  -h, --help            Show this help

If no block-file/STDIN is provided, a sensible default block is embedded.
USAGE
}

BLOCK_MODE="embedded"
BLOCK_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)        TARGET="$2"; shift 2;;
    --start-re)      START_RE="$2"; shift 2;;
    --end-re)        END_RE="$2"; shift 2;;
    --block-file)    BLOCK_MODE="file"; BLOCK_FILE="$2"; shift 2;;
    --block-stdin)   BLOCK_MODE="stdin"; shift 1;;
    --backup-suffix) BAK_SUFFIX="$2"; shift 2;;
    --replace-bin)   REPLACE_BIN="$2"; shift 2;;
    -h|--help)       usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage; exit 2;;
  esac
done

# --- Checks ------------------------------------------------------------------
[[ -x "$REPLACE_BIN" ]] || { echo "replace-block not executable: $REPLACE_BIN" >&2; exit 2; }
[[ -f "$TARGET" ]]      || { echo "Target not found: $TARGET" >&2; exit 2; }

# Pre-validate anchors exist once and form a block
mapfile -t START_MATCHES < <(grep -nE -- "$START_RE" "$TARGET" || true)
if (( ${#START_MATCHES[@]} != 1 )); then
  echo "Start anchor count = ${#START_MATCHES[@]} (expected 1). Lines:" >&2
  printf '  %s\n' "${START_MATCHES[@]}" >&2
  exit 3
fi
START_LN="${START_MATCHES[0]%%:*}"
END_LN="$(awk -v s="$START_LN" -v re="$END_RE" 'NR>s && $0 ~ re {print NR; exit}' "$TARGET")"
if [[ -z "$END_LN" ]]; then
  echo "End anchor not found after start (start line $START_LN)" >&2
  exit 3
fi

echo "[*] Patching: $TARGET"
echo "    Anchors: start@$START_LN .. end@$END_LN"

# --- Build the block file (temp) ---------------------------------------------
TMP_BLOCK="$(mktemp)"
trap 'rm -f "$TMP_BLOCK"' EXIT

if [[ "$BLOCK_MODE" == "file" ]]; then
  [[ -f "$BLOCK_FILE" ]] || { echo "Block file not found: $BLOCK_FILE" >&2; exit 2; }
  cat "$BLOCK_FILE" > "$TMP_BLOCK"
elif [[ "$BLOCK_MODE" == "stdin" ]]; then
  cat > "$TMP_BLOCK"
else
  # Embedded default block:
  cat >"$TMP_BLOCK" <<'BLOCK'
# Any optimized rows with tokens_per_sec > 0 ?
if awk -F',' 'NR>1 && $6 ~ /^optimized$/ && $12+0>0 {exit 0} END{exit 1}' "$CSV_FILE"; then
  # Show best per endpoint/model if we computed any in SUMMARY_FILE.raw
  if [ -s "${SUMMARY_FILE}.raw" ]; then
    echo "Best optimized per (endpoint, model):"
    column -t -s',' "${SUMMARY_FILE}.raw" 2>/dev/null || cat "${SUMMARY_FILE}.raw"
  else
    echo "Optimized variants ran (see CSV), but per-(endpoint,model) best list is empty."
  fi
else
  echo "No optimized variants succeeded."
fi
BLOCK
fi

# Quick sanity: block not empty
if ! [[ -s "$TMP_BLOCK" ]]; then
  echo "Replacement block is empty." >&2
  exit 2
fi

# Show current block (for context)
echo
echo "[*] Existing block (from start to matching 'fi'):"
nl -ba "$TARGET" | sed -n "${START_LN},${END_LN}p"

# --- Apply patch via replace-block -------------------------------------------
echo
echo "[*] Applying patch (backup suffix: $BAK_SUFFIX)…"
"$REPLACE_BIN" \
  "$TARGET" \
  "$START_RE" \
  "$END_RE" \
  "$TMP_BLOCK" \
  "$BAK_SUFFIX"

RC=$?
if (( RC != 0 )); then
  echo "replace-block failed with code $RC" >&2
  exit $RC
fi

# --- Post-check: ensure block present & file valid ---------------------------
if ! bash -n "$TARGET"; then
  echo "Post-validate: bash -n failed (should have been rolled back by replace-block)." >&2
  exit 4
fi

# Re-locate new block after replace for preview (may have shifted)
NEW_START="$(grep -nE -- "$START_RE" "$TARGET" | cut -d: -f1 | head -n1 || true)"
if [[ -n "$NEW_START" ]]; then
  NEW_END="$(awk -v s="$NEW_START" -v re="$END_RE" 'NR>s && $0 ~ re {print NR; exit}' "$TARGET")"
  if [[ -n "$NEW_END" ]]; then
    echo
    echo "[*] New block (lines ${NEW_START}..${NEW_END}):"
    nl -ba "$TARGET" | sed -n "${NEW_START},${NEW_END}p"
  fi
fi

echo
echo "[✓] Patch applied cleanly to $TARGET"

