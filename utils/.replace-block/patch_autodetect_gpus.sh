#!/usr/bin/env bash
# patch_autodetect_gpus.sh — replace the GPU binding block with auto-detect by VRAM
set -euo pipefail

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

: "${TARGET_FILE:=$HOME/GitHub/FuZeCORE.ai/fuze-box/stack/ollama/benchmark.sh}"

# Locate replace-block if not specified
if [ -z "${REPLACE_BIN}" ]; then
  if command -v replace-block >/dev/null 2>&1; then
    REPLACE_BIN="$(command -v replace-block)"
  elif [ -x "$HOME/GitHub/FuZeCORE.ai/utils/replace-block" ]; then
    REPLACE_BIN="$HOME/GitHub/FuZeCORE.ai/utils/replace-block"
  fi
fi

[ -f "$TARGET_FILE" ] || { echo "ERROR: target not found: $TARGET_FILE" >&2; exit 1; }
[ -n "${REPLACE_BIN:-}" ] && [ -x "$REPLACE_BIN" ] || { echo "ERROR: replace-block not found/executable" >&2; exit 2; }

echo "[1/6] Using:"
echo "       TARGET_FILE = $TARGET_FILE"
echo "       BACKUP_EXT  = $BACKUP_EXT"
echo "       REPLACE_BIN = $REPLACE_BIN"
echo

# Idempotence: skip if already patched
if grep -qF "Auto-detect two GPUs by total memory" "$TARGET_FILE"; then
  echo "[skip] Marker already present; no changes made."
  exit 0
fi

# Anchors:
#   START = the line that introduces GPU binding
#   END   = the 'info "Waiting for APIs"' line (we replace it too, and add it back)
START_RE='^[[:space:]]*# Bind A/B to GPUs.*$'
END_RE='^[[:space:]]*info[[:space:]]*"Waiting for APIs"[[:space:]]*$'

echo "[2/6] Locate anchors…"
start_ln="$(grep -nE "$START_RE" "$TARGET_FILE" | head -n1 | cut -d: -f1 || true)"
if [ -z "$start_ln" ]; then
  echo "✖ start anchor not found in $TARGET_FILE" >&2
  exit 3
fi
rel_end="$(sed -n "${start_ln},\$p" "$TARGET_FILE" | grep -nE "$END_RE" | head -n1 | cut -d: -f1 || true)"
if [ -z "$rel_end" ]; then
  echo "✖ end anchor not found after start" >&2
  exit 3
fi
end_ln="$((start_ln + rel_end - 1))"
echo "    ✓ anchors OK (lines ${start_ln}..${end_ln}). Snippet:"
nl -ba "$TARGET_FILE" | sed -n "${start_ln},${end_ln}p" | sed 's/^/      | /'
echo

# Replacement block (includes the final "Waiting for APIs" info line)
PATCH_TMP="$(mktemp)"
cat >"$PATCH_TMP" <<'PATCH'
# Auto-detect two GPUs by total memory (descending). Fallback to index order.
mapfile -t _GPU_ROWS < <(gpu_table | sort -t',' -k4,4nr)
uuid_a="$(printf '%s\n' "${_GPU_ROWS[0]-}" | awk -F',' '{print $2}')"
uuid_b="$(printf '%s\n' "${_GPU_ROWS[1]-}" | awk -F',' '{print $2}')"

if [ -z "${uuid_a:-}" ]; then
  all="$(gpu_table)"
  uuid_a="$(echo "$all" | awk -F',' 'NR==1{print $2}')"
  uuid_b="$(echo "$all" | awk -F',' 'NR==2{print $2}')"
fi
if [ -z "${uuid_b:-}" ] || [ "$uuid_b" = "$uuid_a" ]; then
  # if second GPU missing/identical, mirror A
  uuid_b="$uuid_a"
fi

write_unit "ollama-test-a.service" "$TEST_PORT_A" "$uuid_a" "Ollama (TEST A on :${TEST_PORT_A}, GPU ${uuid_a})"
write_unit "ollama-test-b.service" "$TEST_PORT_B" "$uuid_b" "Ollama (TEST B on :${TEST_PORT_B}, GPU ${uuid_b})"

systemctl enable --now ollama-test-a.service || true
systemctl enable --now ollama-test-b.service || true

info "TEST A OLLAMA_MODELS: $(service_env ollama-test-a.service OLLAMA_MODELS)"
info "TEST B OLLAMA_MODELS: $(service_env ollama-test-b.service OLLAMA_MODELS)"
info "Waiting for APIs"
PATCH
trap 'rm -f "$PATCH_TMP"' EXIT

echo "[3/6] Apply replace-block…"
RB_PRINT=1 VALIDATE_CMD="bash -n" "$REPLACE_BIN" \
  "$TARGET_FILE" "$START_RE" "$END_RE" "$PATCH_TMP" "$BACKUP_EXT"
echo "    ✓ applied"
echo

echo "[4/6] Verify marker…"
grep -qF "Auto-detect two GPUs by total memory" "$TARGET_FILE" \
  && echo "    ✓ marker found" \
  || { echo "✖ marker missing after patch" >&2; exit 4; }
echo

echo "[5/6] Diff vs backup:"
if command -v diff >/dev/null 2>&1; then
  diff -u "${TARGET_FILE}${BACKUP_EXT}" "$TARGET_FILE" | sed 's/^/    /' || true
else
  echo "    (diff not available)"
fi
echo

echo "[6/6] Done."

