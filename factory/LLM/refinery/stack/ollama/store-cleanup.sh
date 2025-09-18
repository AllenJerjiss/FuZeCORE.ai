#!/usr/bin/env bash
# store-cleanup.sh — normalize Ollama model store to /FuZe/models/ollama
# Same-FS: rename/merge with dedupe, progress, USR1 status.
# Diff-FS: rsync missing files with --remove-source-files, then prune.
# Idempotent & safe to re-run.
# 
# Multi-GPU support: Stops ollama-test-multi.service along with single-GPU services

set -euo pipefail

CANON="${CANON:-/FuZe/ollama}"
ALT_DEFAULT="/FuZe/models/ollama"
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

# Safety check: detect if benchmark processes are running
if pgrep -f "benchmark\.sh" >/dev/null 2>&1; then
  echo "WARNING: Benchmark processes detected running. Store cleanup during benchmarks"
  echo "         can cause model corruption or inconsistent results."
  echo "         Consider stopping benchmarks first or use --no-stop to skip service shutdown."
  echo ""
fi

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
  for svc in ollama ollama-persist ollama-test-a ollama-test-b ollama-test-multi; do
    systemctl stop "$svc" 2>/dev/null || true
  done
fi

mkdir -p "$CANON/blobs" "$CANON/manifests"

dev_can=$(df -P "$CANON" | tail -1 | awk '{print $1}')
dev_alt=$(df -P "$ALT"   | tail -1 | awk '{print $1}')

# ---- Progress plumbing -------------------------------------------------------
SECTION=""
TOTAL=0
DONE=0
MOVED=0
REMOVED=0
KEPT=0
COMPARED=0
LAST_PRINT=0

print_progress() {
  # Print a single status line (no trailing newline, caller decides)
  pct="0"
  if [ "$TOTAL" -gt 0 ]; then
    pct=$(( DONE * 100 / TOTAL ))
  fi
  printf "\r   [%s] %d/%d (%s%%) moved=%d dupes_removed=%d kept_conflicts=%d compared=%d" \
    "$SECTION" "$DONE" "$TOTAL" "$pct" "$MOVED" "$REMOVED" "$KEPT" "$COMPARED"
}

force_progress() {
  print_progress
  printf "\n"
}
trap force_progress USR1

# ---- Same-FS merge with dedupe & progress -----------------------------------
same_fs_merge_dir() {
  local SRC="$1" DST="$2" label="$3"
  [ -d "$SRC" ] || { echo "   [$label] nothing to merge (missing)"; return 0; }
  mkdir -p "$DST"

  SECTION="$label"
  TOTAL=$(find "$SRC" -type f | wc -l | tr -d ' ')
  DONE=0; MOVED=0; REMOVED=0; KEPT=0; COMPARED=0; LAST_PRINT=0

  while IFS= read -r -d '' f; do
    rel="${f#$SRC/}"
    t="$DST/$rel"
    mkdir -p "$(dirname "$t")"

    if [ -e "$t" ]; then
      if [ "$label" = "blobs" ]; then
        # blobs are content-addressed; identical filename => identical content
        rm -f -- "$f" || true
        REMOVED=$((REMOVED+1))
      else
        if cmp -s -- "$f" "$t"; then
          rm -f -- "$f" || true
          REMOVED=$((REMOVED+1))
        else
          echo "\n!! differs, keeping ALT copy: $label/$rel" >&2
          KEPT=$((KEPT+1))
        fi
        COMPARED=$((COMPARED+1))
      fi
    else
      mv -- "$f" "$t"
      MOVED=$((MOVED+1))
    fi

    DONE=$((DONE+1))
    now=$(date +%s)
    if [ $((DONE % 200)) -eq 0 ] || [ "$now" -ne "$LAST_PRINT" ]; then
      LAST_PRINT="$now"; printf "\r"; print_progress
    fi
  done < <(find "$SRC" -type f -print0 | sort -z)

  force_progress
  find "$SRC" -depth -type d -empty -delete || true
}

# ---- Diff-FS rsync path ------------------------------------------------------
diff_fs_rsync_dir() {
  local SRC="$1" DST="$2" label="$3"
  [ -d "$SRC" ] || { echo "   [$label] nothing to sync (missing)"; return 0; }
  mkdir -p "$DST"
  echo "   rsync $label -> $DST"
  rsync -aHAX --ignore-existing --remove-source-files --info=stats1,progress2 \
    "$SRC/" "$DST/" || true
  find "$SRC" -depth -type d -empty -delete || true
}

# ---- Strategy selection ------------------------------------------------------
if [ "$dev_can" = "$dev_alt" ]; then
  echo "-- same filesystem -> recursive merge (rename, no extra space)"
  same_fs_merge_dir "$ALT/blobs"     "$CANON/blobs"     "blobs"
  same_fs_merge_dir "$ALT/manifests" "$CANON/manifests" "manifests"

  # If ALT subtree is empty now, remove it
  if [ -z "$(find "$ALT" -mindepth 1 -print -quit 2>/dev/null)" ]; then
    rmdir -p "$ALT" 2>/dev/null || true
  else
    echo "   NOTE: $ALT not empty (likely conflicts or unexpected files kept)."
    echo "         Inspect with: find \"$ALT\" -type f | head"
  fi
else
  echo "-- different filesystems -> rsync missing, remove source files"
  diff_fs_rsync_dir "$ALT/blobs"     "$CANON/blobs"     "blobs"
  diff_fs_rsync_dir "$ALT/manifests" "$CANON/manifests" "manifests"
fi

# Final perms (best effort)
chmod 755 /FuZe /FuZe/models "$CANON" 2>/dev/null || true

echo
echo "✔ Store cleanup done."
echo "   Canonical: $CANON"
echo "   Tip:  du -sh \"$CANON\" \"$ALT\" ; find \"$ALT\" -type f | wc -l"
echo "   USR1 progress ping:  kill -USR1 $$   (while running)"
echo "   Restart Ollama if needed:  sudo systemctl restart ollama || true"

