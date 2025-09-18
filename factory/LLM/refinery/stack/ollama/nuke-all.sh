#!/usr/bin/env bash
# nuke-all.sh - Nuclear cleanup of ALL Ollama variants, services, and stores
# USE WITH EXTREME CAUTION - This will remove EVERYTHING

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORCE=0
YES=0

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--force] [--yes]

NUCLEAR CLEANUP - Removes EVERYTHING:
  - ALL LLM-FuZe- variants from all endpoints
  - ALL test services (ollama-test-*)
  - Migrates/cleans model stores
  - Resets to clean persistent service

Options:
  --force     Actually execute (otherwise dry-run)
  --yes       Don't prompt for confirmation
  -h|--help   This help

WARNING: This will remove ALL benchmark variants and reset services!
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift;;
    --yes) YES=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

echo "=== NUCLEAR OLLAMA CLEANUP ==="
echo "This will:"
echo "  1. Remove ALL LLM-FuZe- variants from all endpoints"
echo "  2. Stop and remove all test services"
echo "  3. Clean/migrate model stores"
echo "  4. Reset to clean persistent service"
echo

if [ "$FORCE" -eq 0 ]; then
  echo "[DRY RUN MODE] Add --force to actually execute"
  echo
fi

if [ "$FORCE" -eq 1 ] && [ "$YES" -eq 0 ]; then
  read -r -p "Are you ABSOLUTELY SURE? This will nuke everything! Type 'NUKE' to proceed: " confirm
  if [ "$confirm" != "NUKE" ]; then
    echo "Aborted."
    exit 1
  fi
fi

ARGS=""
if [ "$FORCE" -eq 1 ]; then ARGS="$ARGS --force"; fi
if [ "$YES" -eq 1 ]; then ARGS="$ARGS --yes"; fi

echo "Step 1: Nuclear variant cleanup..."
"$SCRIPT_DIR/cleanup-variants.sh" --nukeall $ARGS

echo
echo "Step 2: Store cleanup/migration..."
if [ "$FORCE" -eq 1 ]; then
  "$SCRIPT_DIR/store-cleanup.sh"
else
  echo "[DRY RUN] Would run: $SCRIPT_DIR/store-cleanup.sh"
fi

echo
echo "Step 3: Service cleanup and reset..."
if [ "$FORCE" -eq 1 ]; then
  "$SCRIPT_DIR/service-cleanup.sh"
else
  echo "[DRY RUN] Would run: $SCRIPT_DIR/service-cleanup.sh"
fi

echo
echo "=== NUCLEAR CLEANUP COMPLETE ==="
if [ "$FORCE" -eq 0 ]; then
  echo "This was a dry run. Add --force to actually execute."
else
  echo "System has been reset to clean state."
  echo "Ready for fresh benchmarking."
fi