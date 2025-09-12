#!/usr/bin/env bash
# patch_autodetect_gpus.sh — replace GPU binding in benchmark.sh with autodetect by VRAM
set -euo pipefail

TARGET_FILE="${1:-}"
BACKUP_EXT="${BACKUP_EXT:-.bak}"
REPLACE_BIN="${REPLACE_BIN:-}"

# Flags: --target PATH  --replace-bin PATH
while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET_FILE="$2"; shift 2;;
    --replace-bin) REPLACE_BIN="$2"; shift 2;;
    *) [ -z "${TARGET_FILE:-}" ] && TARGET_FILE="$1"; shift;;
  esac
done

: "${TARGET_FILE:=$HOME/GitHub/FuZeCORE.ai/fuze-box/stack/ollama/benchmark.sh}"

# Locate replace-block if not provided
if [ -z "${REPLACE_BIN}" ]; then
  if command -v replace-block >/dev/null 2>&1; then
    REPLACE_BIN="$(command -v replace-block)"
  elif [ -x "$HOME/GitHub/FuZeCORE.ai/utils/replace-block" ]; then
    REPLACE_BIN="$HOME/GitHub/FuZeCORE.ai/utils/replace-block"
  else
    REPLACE_BIN=""
  fi
fi

[ -f "$TARGET_FILE" ] || { echo "ERROR: target not found: $TARGET_FILE" >&2; exit 1; }

echo "[1/6] Using:"
echo "       TARGET_FILE = $TARGET_FILE"
echo "       BACKUP_EXT  = $BACKUP_EXT"
echo "       REPLACE_BIN = ${REPLACE_BIN:-<fallback manual splice>}"
echo

# Inclusive anchors: from the comment through the two write_unit lines
START_RE='^[[:space:]]*# Bind A/B to GPUs by name.*$'
END_RE='^[[:space:]]*write_unit[[:space:]]+"ollama-test-b\.service".*$'

# New autodetect block (keeps write_unit lines; chooses GPUs by VRAM)
read -r -d '' PATCH <<'PATCH'
# Auto-select test GPUs by VRAM (descending). No hardcoded names.
select_test_gpus(){
  # gpu_table -> "index,uuid,name,memory.total"
  local rows
  rows="$(gpu_table | awk -F',' '{gsub(/ MiB/,"",$4); print $0}' | sort -t',' -k4,4nr)"
  local uuid_a uuid_b
  uuid_a="$(echo "$rows" | awk -F',' 'NR==1{print $2}')"
  uuid_b="$(echo "$rows" | awk -F',' 'NR==2{print $2}')"
  echo "${uuid_a},${uuid_b}"
}

uuids="$(select_test_gpus)"
uuid_a="${uuids%%,*}"
uuid_b="${uuids##*,}"

if [ -z "${uuid_a:-}" ]; then
  err "No GPUs detected via nvidia-smi/gpu_table."
  exit 1
fi
if [ -z "${uuid_b:-}" ] || [ "$uuid_a" = "$uuid_b" ]; then
  warn "Only one distinct GPU detected — both test services will use the same GPU (${uuid_a})."
  uuid_b="$uuid_a"
fi

write_unit "ollama-test-a.service" "$TEST_PORT_A" "$uuid_a" "Ollama (TEST A on :${TEST_PORT_A}, GPU ${uuid_a})"
write_unit "ollama-test-b.service" "$TEST_PORT_B" "$uuid_b" "Ollama (TEST B on :${TEST_PORT_B}, GPU ${uuid_b})"
PATCH

echo "[2/6] Locate anchors…"
start_ln="$(grep -nE "$START_RE" "$TARGET_FILE" | head -n1 | cut -d: -f1 || true)"
end_ln=""
if [ -n "$start_ln" ]; then
  rel_end="$(sed -n "${start_ln},\$p" "$TARGET_FILE" | grep -nE "$END_RE" | head -n1 | cut -d: -f1 || true)"
  [ -n "$rel_end" ] && end_ln="$((start_ln + rel_end - 1))"
fi

if [ -z "$start_ln" ] || [ -z "$end_ln" ]; then
  echo "    ! Anchors not found; showing nearby context for debugging:"
  grep -nE 'Bind A/B to GPUs|ollama-test-[ab]\.service' "$TARGET_FILE" || true
  echo "    Aborting without changes."
  exit 2
fi

echo "    ✓ anchors OK (lines ${start_ln}..${end_ln})."
echo "    Current block:"
nl -ba "$TARGET_FILE" | sed -n "${start_ln},${end_ln}p" | sed 's/^/      | /'
echo

echo "[3/6] Apply patch…"
tmp="$(mktemp)"; printf "%s\n" "$PATCH" > "$tmp"
if [ -n "$REPLACE_BIN" ] && [ -x "$REPLACE_BIN" ]; then
  "$REPLACE_BIN" "$TARGET_FILE" "$START_RE" "$END_RE" "$tmp" "$BACKUP_EXT"
  echo "    ✓ replace-block applied."
else
  echo "    (fallback) Manual splice."
  cp -p "$TARGET_FILE" "${TARGET_FILE}${BACKUP_EXT}"
  tmpout="$(mktemp)"
  [ "$start_ln" -gt 1 ] && head -n "$((start_ln-1))" "$TARGET_FILE" > "$tmpout" || : > "$tmpout"
  printf "%s\n" "$PATCH" >> "$tmpout"
  tail -n "+$((end_ln+1))" "$TARGET_FILE" >> "$tmpout"
  cat "$tmpout" > "$TARGET_FILE"
  rm -f "$tmpout"
  echo "    ✓ manual splice done."
fi
rm -f "$tmp"

echo
echo "[4/6] Validate shell syntax…"
bash -n "$TARGET_FILE" && echo "    ✓ bash -n OK"

echo "[5/6] Show diff vs backup:"
if [ -f "${TARGET_FILE}${BACKUP_EXT}" ]; then
  diff -u "${TARGET_FILE}${BACKUP_EXT}" "$TARGET_FILE" | sed 's/^/    /' || true
else
  echo "    (no backup found)"
fi

echo "[6/6] Done."

