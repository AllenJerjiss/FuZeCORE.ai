#!/usr/bin/env bash
# Patch the CLI parse block in cleanup-variants.sh (fixes esac/structure)
set -euo pipefail

TARGET_FILE="${1:-}"
BACKUP_EXT="${BACKUP_EXT:-.bak}"
REPLACE_BIN="${REPLACE_BIN:-}"

# Optional flags: --target PATH  --replace-bin PATH
while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET_FILE="$2"; shift 2;;
    --replace-bin) REPLACE_BIN="$2"; shift 2;;
    *) [ -z "${TARGET_FILE:-}" ] && TARGET_FILE="$1"; shift;;
  esac
done

# Default target if none provided
: "${TARGET_FILE:=$HOME/GitHub/FuZeCORE.ai/fuze-box/stack/ollama/cleanup-variants.sh}"

# Locate replace-block if not given
if [ -z "${REPLACE_BIN}" ]; then
  if command -v replace-block >/dev/null 2>&1; then
    REPLACE_BIN="$(command -v replace-block)"
  elif [ -x "$HOME/GitHub/FuZeCORE.ai/utils/replace-block" ]; then
    REPLACE_BIN="$HOME/GitHub/FuZeCORE.ai/utils/replace-block"
  else
    REPLACE_BIN=""
  fi
fi

[ -f "$TARGET_FILE" ] || { echo "ERROR: target not found: $TARGET_FILE"; exit 1; }

echo "[1/6] Using:"
echo "       TARGET_FILE = $TARGET_FILE"
echo "       BACKUP_EXT  = $BACKUP_EXT"
echo "       REPLACE_BIN = ${REPLACE_BIN:-<none; will fallback>}"
echo

# Anchors: inclusive replace from start of the while loop to its matching done
START_RE='^[[:space:]]*while[[:space:]]+\[[[:space:]]*\$#[[:space:]]*-gt[[:space:]]*0[[:space:]]*\][[:space:]]*;[[:space:]]*do[[:space:]]*$'
# allow: "done", "done || true", "done || true ;", with optional trailing semicolon/space
END_RE='^[[:space:]]*done([[:space:]]*\|\|[[:space:]]*true)?[[:space:]]*;?[[:space:]]*$'

# Build patch content into a temp file (avoid read -d '')
PATCH_FILE="$(mktemp)"
trap 'rm -f "$PATCH_FILE" "$TMP_SPLICE" "$TMP_OUT" 2>/dev/null || true' EXIT
cat > "$PATCH_FILE" <<'PATCH'
while [ $# -gt 0 ]; do
  case "$1" in
    --hosts)       HOSTS="$2"; shift 2;;
    --match)       MATCH_RE="$2"; shift 2;;
    --keep)        KEEP_RE="$2"; shift 2;;
    --force)       FORCE=1; shift 1;;
    --ollama-bin)  OLLAMA_BIN="$2"; shift 2;;
    -h|--help)     usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2;;
  esac
done
PATCH

# Pre-fix the common typo if present
if grep -q '\bendesac\b' "$TARGET_FILE"; then
  echo "[pre] Found 'endesac' typo; fixing globally before patch…"
  cp -p "$TARGET_FILE" "${TARGET_FILE}${BACKUP_EXT}.pre"
  sed -i 's/\bendesac\b/esac/g' "$TARGET_FILE"
fi

echo "[2/6] Locate anchors…"
start_ln="$(grep -nE "$START_RE" "$TARGET_FILE" | head -n1 | cut -d: -f1 || true)"
if [ -z "$start_ln" ]; then
  echo "    ! start anchor not found. Will still try a sed fallback."
fi
if [ -n "$start_ln" ]; then
  rel_end="$(sed -n "${start_ln},\$p" "$TARGET_FILE" | grep -nE "$END_RE" | head -n1 | cut -d: -f1 || true)"
  if [ -z "$rel_end" ]; then
    echo "    ! end anchor not found after start. Will use sed fallback."
    start_ln=""
  else
    end_ln="$((start_ln + rel_end - 1))"
    echo "    ✓ anchors OK (lines ${start_ln}..${end_ln}). Snippet:"
    nl -ba "$TARGET_FILE" | sed -n "${start_ln},${end_ln}p" | sed 's/^/      | /'
  fi
fi
echo

echo "[3/6] Apply patch…"
if [ -n "$REPLACE_BIN" ] && [ -n "${start_ln:-}" ]; then
  "$REPLACE_BIN" "$TARGET_FILE" "$START_RE" "$END_RE" "$PATCH_FILE" "$BACKUP_EXT"
  echo "    ✓ replace-block applied."
else
  echo "    (fallback) Splicing with sed/head/tail. Backup: ${TARGET_FILE}${BACKUP_EXT}"
  cp -p "$TARGET_FILE" "${TARGET_FILE}${BACKUP_EXT}"
  TMP_OUT="$(mktemp)"
  if [ -n "${start_ln:-}" ]; then
    [ "$start_ln" -gt 1 ] && head -n "$((start_ln-1))" "$TARGET_FILE" > "$TMP_OUT" || : > "$TMP_OUT"
    cat "$PATCH_FILE" >> "$TMP_OUT"
    tail -n "+$((end_ln+1))" "$TARGET_FILE" >> "$TMP_OUT"
    cat "$TMP_OUT" > "$TARGET_FILE"
    echo "    ✓ manual splice applied."
  else
    echo "    ! Anchors not found; only typo fix (if any) applied."
  fi
fi
echo

echo "[4/6] Validate shell syntax…"
if bash -n "$TARGET_FILE"; then
  echo "    ✓ bash -n OK"
else
  echo "    ✖ bash -n failed"; exit 1
fi

echo "[5/6] Ensure executable bit…"
chmod +x "$TARGET_FILE"
echo "    ✓ executable set"

echo "[6/6] Done."

