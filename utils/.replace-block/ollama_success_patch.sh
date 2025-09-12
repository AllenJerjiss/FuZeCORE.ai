cat > ~/.replace-block/patch_ollama_success.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
TMP_OUT=""   # ensure bound even when replace-block path succeeds

# ---- Config (override with flags or env) -------------------------------------
TARGET_FILE="${TARGET_FILE:-/home/fuze/GitHub/FuZeCORE.ai/fuze-box/stack/ollama/benchmark.sh}"
BACKUP_EXT="${BACKUP_EXT:-.bak}"
# POSIX ERE (works in awk/sed/grep -E)
START_RE='^[[:space:]]*if[[:space:]]+\[[[:space:]]+-s[[:space:]]+"\$\{SUMMARY_FILE\}\.raw"[[:space:]]+\][[:space:]]*;[[:space:]]*then[[:space:]]*$'
END_RE='^[[:space:]]*fi[[:space:]]*$'
REPLACE_BIN="${REPLACE_BIN:-}"

usage() {
  cat <<USAGE
Usage: $0 [--target FILE] [--backup-ext .ext] [--replace-bin /path/to/replace-block]
Env overrides: TARGET_FILE, BACKUP_EXT, REPLACE_BIN
USAGE
}

# Parse flags
while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET_FILE="$2"; shift 2;;
    --backup-ext) BACKUP_EXT="$2"; shift 2;;
    --replace-bin) REPLACE_BIN="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac
done

# ---- Locate replace-block ----------------------------------------------------
if [ -z "${REPLACE_BIN}" ]; then
  if command -v replace-block >/dev/null 2>&1; then
    REPLACE_BIN="$(command -v replace-block)"
  elif [ -x "$HOME/.replace-block/replace-block" ]; then
    REPLACE_BIN="$HOME/.replace-block/replace-block"
  else
    REPLACE_BIN=""
  fi
fi
[ -f "$TARGET_FILE" ] || { echo "ERROR: target not found: $TARGET_FILE" >&2; exit 1; }

echo "[1/7] Using:"
echo "       TARGET_FILE = $TARGET_FILE"
echo "       BACKUP_EXT  = $BACKUP_EXT"
echo "       REPLACE_BIN = ${REPLACE_BIN:-<not used; will fallback if needed>}"
echo

# ---- Pre-validate anchors (and capture exact start..end lines) ---------------
echo "[2/7] Pre-validate anchors…"
mapfile -t START_MATCHES < <(grep -nE "$START_RE" "$TARGET_FILE" || true)
if [ "${#START_MATCHES[@]}" -ne 1 ]; then
  echo "ERROR: start anchor matched ${#START_MATCHES[@]} times; expected 1." >&2
  printf 'Matches:\n%s\n' "${START_MATCHES[@]}" >&2
  exit 1
fi
START_LN="${START_MATCHES[0]%%:*}"

REL_END="$(sed -n "${START_LN},\$p" "$TARGET_FILE" | grep -nE "$END_RE" | head -n1 | cut -d: -f1 || true)"
if [ -z "$REL_END" ]; then
  echo "ERROR: end anchor not found after start (line $START_LN)." >&2; exit 1
fi
END_LN="$((START_LN + REL_END - 1))"

echo "    ✓ anchors OK (lines ${START_LN}..${END_LN})."
echo "    Current block to be replaced:"
nl -ba "$TARGET_FILE" | sed -n "${START_LN},${END_LN}p" | sed 's/^/      | /'
echo

# ---- Build patch content (inline) -------------------------------------------
PATCH_TMP="$(mktemp)"
cat > "$PATCH_TMP" <<'PATCH'
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
PATCH

cleanup() { rm -f "$PATCH_TMP" "${TMP_OUT:-}" 2>/dev/null || true; }
trap cleanup EXIT

# ---- Try replace-block first -------------------------------------------------
APPLIED=0
if [ -n "$REPLACE_BIN" ] && [ -x "$REPLACE_BIN" ]; then
  echo "[3/7] Applying via replace-block (backup ${BACKUP_EXT})…"
  if "$REPLACE_BIN" "$TARGET_FILE" "$START_RE" "$END_RE" "$PATCH_TMP" "$BACKUP_EXT"; then
    echo "    ✓ replace-block replacement done."
    APPLIED=1
  else
    echo "    ! replace-block reported failure; will attempt manual splice…" >&2
  fi
else
  echo "[3/7] replace-block not available; will attempt manual splice."
fi

# ---- Fallback: manual splice by line numbers --------------------------------
if [ "$APPLIED" -eq 0 ]; then
  echo "[4/7] Manual splice fallback (backup ${BACKUP_EXT})…"
  cp -p "$TARGET_FILE" "${TARGET_FILE}${BACKUP_EXT}"
  TMP_OUT="$(mktemp)"
  # pre, patch, post
  if [ "$START_LN" -gt 1 ]; then
    head -n "$((START_LN-1))" "$TARGET_FILE" > "$TMP_OUT"
  else
    : > "$TMP_OUT"
  fi
  cat "$PATCH_TMP" >> "$TMP_OUT"
  tail -n "+$((END_LN+1))" "$TARGET_FILE" >> "$TMP_OUT"
  cat "$TMP_OUT" > "$TARGET_FILE"
  echo "    ✓ manual splice done."
fi
echo

# ---- Post-validate syntax ----------------------------------------------------
echo "[5/7] Post-validate with bash -n…"
if bash -n "$TARGET_FILE"; then
  echo "    ✓ bash -n OK."
else
  echo "ERROR: bash -n failed." >&2
  exit 1
fi
echo

# ---- Sanity: new block marker present ---------------------------------------
echo "[6/7] Sanity check for new block presence…"
grep -nF "Any optimized rows with tokens_per_sec > 0 ?" "$TARGET_FILE" >/dev/null \
  && echo "    ✓ new block found." \
  || { echo "ERROR: new block marker not found"; exit 1; }
echo

# ---- Diff summary (optional) ------------------------------------------------
echo "[7/7] Diff against backup (context 3):"
if command -v diff >/dev/null 2>&1; then
  diff -u "${TARGET_FILE}${BACKUP_EXT}" "$TARGET_FILE" | sed 's/^/    /' || true
else
  echo "    (diff not available)"
fi

echo "Done."
BASH
chmod +x ~/.replace-block/patch_ollama_success.sh

