#!/usr/bin/env bash
# fix_ollama_marker.sh
set -euo pipefail

TARGET_FILE="${1:-/home/fuze/GitHub/FuZeCORE.ai/fuze-box/stack/ollama/benchmark.sh}"
BACKUP_EXT="${BACKUP_EXT:-.bak}"
MARKER_LINE='# Any optimized rows with tokens_per_sec > 0 ?'

usage() {
  echo "Usage: $(basename "$0") [TARGET_FILE]"
  echo "Env: BACKUP_EXT (default: .bak)"
}

[ -f "$TARGET_FILE" ] || { echo "ERROR: target not found: $TARGET_FILE"; exit 1; }

echo "[fix] Target: $TARGET_FILE"
echo "[fix] Backup: ${TARGET_FILE}${BACKUP_EXT}"

cp -p "$TARGET_FILE" "${TARGET_FILE}${BACKUP_EXT}"

# Count before
before_cnt=$(grep -cF "$MARKER_LINE" "$TARGET_FILE" || true)

# Dedupe the exact marker line – keep only the first occurrence
tmp="$(mktemp)"
awk -v m="$MARKER_LINE" '
  { if ($0==m) { if (seen++) next } ; print }
' "$TARGET_FILE" > "$tmp"

mv "$tmp" "$TARGET_FILE"

# Ensure it's executable
chmod +x "$TARGET_FILE" || true

# Validate shell syntax
if bash -n "$TARGET_FILE"; then
  after_cnt=$(grep -cF "$MARKER_LINE" "$TARGET_FILE" || true)
  echo "[fix] Marker count: before=$before_cnt, after=$after_cnt"
  echo "[fix] bash -n: OK"
else
  echo "[fix] bash -n FAILED; restoring backup"
  cp -p "${TARGET_FILE}${BACKUP_EXT}" "$TARGET_FILE"
  exit 2
fi

# Show diff against backup (optional)
if command -v diff >/dev/null 2>&1; then
  echo "[fix] Diff vs backup:"
  diff -u "${TARGET_FILE}${BACKUP_EXT}" "$TARGET_FILE" || true
fi

echo "[fix] Done."

