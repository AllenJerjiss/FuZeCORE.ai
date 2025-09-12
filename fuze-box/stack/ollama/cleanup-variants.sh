#!/usr/bin/env bash
# Robust patcher for cleanup-variants.sh CLI parse block
set -euo pipefail

# -------------------- config & args --------------------
TARGET_FILE="${1:-}"
BACKUP_EXT="${BACKUP_EXT:-.bak}"
REPLACE_BIN="${REPLACE_BIN:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET_FILE="$2"; shift 2;;
    --replace-bin) REPLACE_BIN="$2"; shift 2;;
    *) [ -z "${TARGET_FILE:-}" ] && TARGET_FILE="$1"; shift;;
  esac
done

: "${TARGET_FILE:=$HOME/GitHub/FuZeCORE.ai/fuze-box/stack/ollama/cleanup-variants.sh}"

# Find replace-block if not given
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

# -------------------- anchors --------------------
# Start at the 'while [ $# -gt 0 ]; do' line
START_RE='^[[:space:]]*while[[:space:]]+\[[[:space:]]*\$#[[:space:]]*-gt[[:space:]]*0[[:space:]]*\][[:space:]]*;[[:space:]]*do[[:space:]]*$'
# End at 'done' (optionally followed by '|| true' and an optional trailing ';')
END_RE='^[[:space:]]*done([[:space:]]*\|\|[[:space:]]*true)?[[:space:]]*;?[[:space:]]*$'

# -------------------- patch content (with markers for idempotency) --------------------
PATCH_FILE="$(mktemp)"
TMP_OUT="$(mktemp)"
trap 'rm -f "$PATCH_FILE" "$TMP_OUT" 2>/dev/null || true' EXIT

cat > "$PATCH_FILE" <<'PATCH'
# >>> RB_PATCH: cleanup-variants arg-parse (BEGIN)
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
# <<< RB_PATCH: cleanup-variants arg-parse (END)
PATCH

# If marker already present, skip
if grep -qF '>>> RB_PATCH: cleanup-variants arg-parse (BEGIN)' "$TARGET_FILE"; then
  echo "[skip] Marker already present; no changes made."
  exit 0
fi

# Pre-fix the 'endesac' typo if present
if grep -q '\bendesac\b' "$TARGET_FILE"; then
  echo "[pre] Found 'endesac' typo; fixing globally before patch…"
  cp -p "$TARGET_FILE" "${TARGET_FILE}${BACKUP_EXT}.pre"
  sed -i 's/\bendesac\b/esac/g' "$TARGET_FILE"
fi

echo "[2/6] Locate anchors…"
start_ln="$(grep -nE "$START_RE" "$TARGET_FILE" | head -n1 | cut -d: -f1 || true)"
if [ -z "$start_ln" ]; then
  echo "    ! start anchor not found. Aborting for safety."
  exit 1
fi
rel_end="$(sed -n "${start_ln},\$p" "$TARGET_FILE" | grep -nE "$END_RE" | head -n1 | cut -d: -f1 || true)"
if [ -z "$rel_end" ]; then
  echo "    ! end anchor not found after start. Aborting for safety."
  exit 1
fi
end_ln="$((start_ln + rel_end - 1))"
echo "    ✓ anchors OK (lines ${start_ln}..${end_ln}). Snippet:"
nl -ba "$TARGET_FILE" | sed -n "${start_ln},${end_ln}p" | sed 's/^/      | /'
echo

echo "[3/6] Apply patch…"
# Try replace-block first
APPLIED=0
if [ -n "$REPLACE_BIN" ]; then
  if "$REPLACE_BIN" "$TARGET_FILE" "$START_RE" "$END_RE" "$PATCH_FILE" "$BACKUP_EXT"; then
    echo "    ✓ replace-block applied."
    APPLIED=1
  else
    echo "    ! replace-block failed; falling back to manual splice."
  fi
fi

# Manual splice fallback (and also path to post-fix double 'done')
if [ "$APPLIED" -eq 0 ]; then
  cp -p "$TARGET_FILE" "${TARGET_FILE}${BACKUP_EXT}"
  # pre, patch, post
  [ "$start_ln" -gt 1 ] && head -n "$((start_ln-1))" "$TARGET_FILE" > "$TMP_OUT" || : > "$TMP_OUT"
  cat "$PATCH_FILE" >> "$TMP_OUT"
  tail -n "+$((end_ln+1))" "$TARGET_FILE" >> "$TMP_OUT"
  cat "$TMP_OUT" > "$TARGET_FILE"
  echo "    ✓ manual splice applied."
fi

# -------------------- post-fix: duplicate 'done' right after block --------------------
# If the very next non-empty line after the patched block is another 'done…', remove it.
# Recompute end of our new block using the END marker we placed.
blk_start="$(grep -nF '>>> RB_PATCH: cleanup-variants arg-parse (BEGIN)' "$TARGET_FILE" | head -n1 | cut -d: -f1)"
blk_end="$(sed -n "${blk_start},\$p" "$TARGET_FILE" | grep -nF '# <<< RB_PATCH: cleanup-variants arg-parse (END)' | head -n1 | cut -d: -f1)"
if [ -n "$blk_start" ] && [ -n "$blk_end" ]; then
  blk_end_abs="$((blk_start + blk_end - 1))"
  # find next non-empty line index after our block
  next_nonempty="$(awk -v s="$blk_end_abs" 'NR>s && $0 !~ /^[[:space:]]*$/ {print NR; exit}' "$TARGET_FILE" || true)"
  if [ -n "$next_nonempty" ]; then
    if sed -n "${next_nonempty}p" "$TARGET_FILE" | grep -Eq "$END_RE"; then
      echo "    • Removing duplicate 'done' at line $next_nonempty"
      cp -p "$TARGET_FILE" "${TARGET_FILE}${BACKUP_EXT}.dedup"
      # delete that single line
      awk -v del="$next_nonempty" 'NR!=del{print $0}' "$TARGET_FILE" > "$TMP_OUT"
      cat "$TMP_OUT" > "$TARGET_FILE"
    fi
  fi
fi
echo

echo "[4/6] Validate shell syntax…"
if bash -n "$TARGET_FILE"; then
  echo "    ✓ bash -n OK"
else
  echo "    ✖ bash -n failed — restoring backup and showing context."
  # restore main backup (created by replace-block or our manual splice)
  if [ -f "${TARGET_FILE}${BACKUP_EXT}" ]; then
    cp -p "${TARGET_FILE}${BACKUP_EXT}" "$TARGET_FILE"
    echo "    • restored ${TARGET_FILE}${BACKUP_EXT} -> ${TARGET_FILE}"
  fi
  # print 20 lines around the first 'syntax error near unexpected token'
  # shellcheck disable=SC2001
  err_line="$(bash -n "$TARGET_FILE" 2>&1 | sed -n 's/.*line \([0-9]\+\).*/\1/p' | head -n1 || true)"
  if [ -n "$err_line" ]; then
    lo=$(( err_line>10 ? err_line-10 : 1 ))
    hi=$(( err_line+10 ))
    echo "    • context lines ${lo}-${hi}:"
    nl -ba "$TARGET_FILE" | sed -n "${lo},${hi}p" | sed 's/^/      | /'
  fi
  exit 1
fi

echo "[5/6] Ensure executable bit…"
chmod +x "$TARGET_FILE"
echo "    ✓ executable set"

echo "[6/6] Done."

