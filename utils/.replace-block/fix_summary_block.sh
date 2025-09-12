#!/usr/bin/env bash
# fix_summary_block.sh — surgically repair the final-summary condition block
set -euo pipefail

TARGET="${1:-$HOME/GitHub/FuZeCORE.ai/fuze-box/stack/ollama/benchmark.sh}"
BACKUP_EXT="${BACKUP_EXT:-.bak}"

[ -f "$TARGET" ] || { echo "ERROR: target not found: $TARGET" >&2; exit 1; }

# Find anchors
csv_ln="$(grep -nE '^[[:space:]]*echo[[:space:]]*"CSV:[[:space:]]*\$\{CSV_FILE\}"[[:space:]]*$' "$TARGET" | head -n1 | cut -d: -f1 || true)"
basevs_ln="$(grep -nE '^[[:space:]]*echo[[:space:]]*"=== Base vs Optimized \(per endpoint & model\) ==="[[:space:]]*$' "$TARGET" | head -n1 | cut -d: -f1 || true)"

if [ -z "$csv_ln" ] || [ -z "$basevs_ln" ] || [ "$basevs_ln" -le "$csv_ln" ]; then
  echo "ERROR: could not locate summary anchors in $TARGET" >&2
  exit 2
fi

start="$((csv_ln + 1))"         # replace AFTER the CSV echo line
end="$((basevs_ln - 1))"        # up to the line BEFORE the Base vs header

# Replacement block (balanced if/fi + a trailing echo)
read -r -d '' PATCH <<'PATCH'
echo
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
echo
PATCH

# Splice it in
cp -p "$TARGET" "${TARGET}${BACKUP_EXT}"
tmp_out="$(mktemp)"
trap 'rm -f "$tmp_out"' EXIT

# head: through the line BEFORE our start
if [ "$start" -gt 1 ]; then
  head -n "$((start-1))" "$TARGET" > "$tmp_out"
else
  : > "$tmp_out"
fi

# patched block
printf "%s\n" "$PATCH" >> "$tmp_out"

# tail: from the line AFTER our end, to EOF
tail -n "+$((end+1))" "$TARGET" >> "$tmp_out"

# write back
cat "$tmp_out" > "$TARGET"

# Validate & keep mode

