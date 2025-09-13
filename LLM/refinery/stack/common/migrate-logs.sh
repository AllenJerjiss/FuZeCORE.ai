#!/usr/bin/env bash
# migrate-logs.sh — Move historical logs into /var/log/fuze-stack and backfill symlinks
# - Consolidates logs from repo paths to a single system path
# - Safe to run multiple times

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root (sudo)." >&2
  exit 1
fi

DEST="${LOG_DIR:-/var/log/fuze-stack}"
mkdir -p "$DEST"

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FUZE_ROOT="$(cd "$STACK_DIR/.." && pwd)"

SRC_DIRS=(
  "$STACK_DIR/logs"
  "$FUZE_ROOT/logs"
)

echo "== Migrating logs to: $DEST =="
total_moved=0
for src in "${SRC_DIRS[@]}"; do
  [ -d "$src" ] || continue
  shopt -s nullglob
  files=("$src"/*)
  shopt -u nullglob
  [ ${#files[@]} -gt 0 ] || { echo "(no files in $src)"; continue; }
  echo "-- From: $src"
  for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    dest="$DEST/$base"
    if [ -e "$dest" ]; then
      # avoid overwrite by prefixing timestamp
      ts="$(date +%Y%m%d_%H%M%S)"
      dest="$DEST/${ts}_$base"
    fi
    mv -f "$f" "$dest"
    echo "   moved: $base -> $(basename "$dest")"
    total_moved=$((total_moved+1))
  done
  # remove dir if empty; then backfill symlink to DEST
  rmdir "$src" 2>/dev/null || true
  if [ ! -e "$src" ]; then
    ln -s "$DEST" "$src"
    echo "   linked: $src -> $DEST"
  fi
done

echo
echo "Summary: moved $total_moved files into $DEST"
echo "Done."

