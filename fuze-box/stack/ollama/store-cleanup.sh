#!/usr/bin/env bash
# store-cleanup.sh — normalize Ollama model store to /FuZe/models/ollama
# - SAME FS: recursively merge contents (rename) and remove duplicates.
# - DIFF FS: rsync missing files with --remove-source-files, then prune.
# Safe to re-run; idempotent. Stops services by default (use --no-stop to skip).

set -euo pipefail

CANON="${CANON:-/FuZe/models/ollama}"
ALT_DEFAULT="/FuZe/ollama/models"
STOP_SERVICES=1

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--canon PATH] [--alt PATH] [--no-stop]
  --canon PATH    Canonical store (default: $CANON)
  --alt PATH      Alternate store to migrate (default: $ALT_DEFAULT)
  --no-stop       Do NOT stop ollama services before merging
USAGE
}

ALT="$ALT_DEFAULT"
while [ $# -gt 0 ]; do
  case "$1" in
    --canon) CANON="$2"; shift 2;;
    --alt) ALT="$2"; shift 2;;
    --no-stop) STOP_SERVICES=0; shift 1;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

echo "== ollama-store-cleanup =="
echo "Canonical store : $CANON"
echo "Alt candidate   : $ALT"

mkdir -p "$CANON"
if [ ! -d "$ALT" ]; then
  echo "No ALT store at $ALT — nothing to do."
  exit 0
fi
if [ "$ALT" = "$CANON" ]; then
  echo "ALT equals CANON — nothing to do."
  exit 0
fi

# Optionally stop services to avoid churn
if [ "$STOP_SERVICES" -eq 1 ]; then
  echo "-- stopping Ollama services (will not fail if missing)"
  for svc in ollama ollama-persist ollama-test-a ollama-test-b; do
    systemctl stop "$svc" 2>/dev/null || true
  done
fi

mkdir -p "$CANON/blobs" "$CANON/manifests"

dev_can=$(df -P "$CANON" | tail -1 | awk '{print $1}')
dev_alt=$(df -P "$ALT"   | tail -1 | awk '{print $1}')

same_fs_merge_dir() {
  # Recursively merge SRC into DST, renaming or removing duplicates.
  # Assumes both exist.
  local SRC="$1" DST="$2"
  [ -d "$SRC" ] || return 0

  local moved=0 removed=0 kept=0 compared=0
  # Files first
  while IFS= read -r -d '' f; do
    rel="${f#$SRC/}"
    t="$DST/$rel"
    mkdir -p "$(dirname "$t")"
    if [ -e "$t" ]; then
      # Compare before removing (cheap for blobs; manifests are small)
      if cmp -s -- "$f" "$t"; then
        rm -f -- "$f" || true
        removed=$((removed+1))
      else
        echo "!! differs, keeping ALT copy: $rel" >&2
        kept=$((kept+1))
      fi
      compared=$((compared+1))
    else
      mv -- "$f" "$t"
      moved=$((moved+1))
    fi
  done < <(find "$SRC" -type f -print0)

  # Then empty dirs
  find "$SRC" -depth -type d -empty -delete || true

  echo "   merged $SRC -> $DST   moved=$moved removed_dupes=$removed kept_conflicts=$kept compared=$compared"
}

if [ "$dev_can" = "$dev_alt" ]; then
  echo "-- same filesystem -> recursive merge (rename, no extra space)"
  same_fs_merge_dir "$ALT/blobs"     "$CANON/blobs"
  same_fs_merge_dir "$ALT/manifests" "$CANON/manifests"

  # If ALT subtree is empty now, remove it
  if [ -z "$(find "$ALT" -mindepth 1 -print -quit 2>/dev/null)" ]; then
    rmdir -p "$ALT" 2>/dev/null || true
  else
    echo "   NOTE: $ALT not empty (likely kept conflicts or unexpected files)."
  fi
else
  echo "-- different filesystems -> rsync missing, remove source files"
  echo "   rsync blobs -> $CANON/blobs"
  rsync -aHAX --ignore-existing --remove-source-files --info=stats1,progress2 \
    "$ALT/blobs/" "$CANON/blobs/" || true

  echo "   rsync manifests -> $CANON/manifests"
  rsync -aHAX --ignore-existing --remove-source-files --info=stats1,progress2 \
    "$ALT/manifests/" "$CANON/manifests/" || true

  # Clean up any now-empty dirs
  find "$ALT" -depth -type d -empty -delete || true
fi

# Final perms (best effort)
chmod 755 /FuZe /FuZe/models "$CANON" 2>/dev/null || true

echo
echo "✔ Store cleanup done."
echo "   Canonical: $CANON"
echo "   Tip: check counts ->  du -sh \"$CANON\" \"$ALT\" ; find \"$ALT\" -type f | wc -l"
echo "   If Ollama was running, restart it:  sudo systemctl restart ollama || true"

