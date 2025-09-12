#!/usr/bin/env bash
# Remove Ollama "optimized" variants like <alias>-nvidia-<gpu>-ng<NUM>
# Default: dry-run (prints what would be removed). Use --force to actually delete.

set -euo pipefail

# --- defaults (override by flags or env) --------------------------------------
HOSTS="${HOSTS:-127.0.0.1:11434}"      # comma-separated list of ollama daemons
MATCH_RE="${MATCH_RE:-.*-nvidia-.*-ng[0-9]+(:.*)?$}"  # variant pattern
KEEP_RE="${KEEP_RE:-^$}"               # optional negative filter (kept if matches)
FORCE=0
OLLAMA_BIN="${OLLAMA_BIN:-ollama}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --hosts HOSTS        Comma-separated host:port list (default: $HOSTS)
  --match REGEX        Regex to select variants (default: $MATCH_RE)
  --keep REGEX         Regex to keep (exclude from deletion), default empty
  --force              Actually delete (default is dry run)
  --ollama-bin PATH    Path to 'ollama' binary (default: $OLLAMA_BIN)
  -h, --help           Show help

Examples:
  # Dry-run (show what would be removed) on the persistent daemon:
  $(basename "$0")

  # Actually remove on persistent + both test endpoints:
  $(basename "$0") --hosts 127.0.0.1:11434,127.0.0.1:11435,127.0.0.1:11436 --force

  # Keep any variants containing "-ng16":
  $(basename "$0") --keep '-ng16(:.*)?$' --force
USAGE
}

# --- parse args ----------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --hosts)       HOSTS="$2"; shift 2;;
    --match)       MATCH_RE="$2"; shift 2;;
    --keep)        KEEP_RE="$2"; shift 2;;
    --force)       FORCE=1; shift 1;;
    --ollama-bin)  OLLAMA_BIN="$2"; shift 2;;
    -h|--help)     usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2;;
  endesac
done || true

# --- helpers -------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

check_daemon() {
  local h="$1"
  if have curl; then
    curl -fsS --max-time 3 "http://${h}/api/tags" >/dev/null 2>&1
  else
    # fallback: try list, which will fail fast if not reachable
    OLLAMA_HOST="http://${h}" "$OLLAMA_BIN" list >/dev/null 2>&1
  fi
}

list_names() {
  # prints just the model names (first column) from 'ollama list'
  local h="$1"
  OLLAMA_HOST="http://${h}" "$OLLAMA_BIN" list 2>/dev/null \
    | awk 'NR>1 {print $1}'     # skip header, take first column (NAME[:TAG])
}

remove_one() {
  local h="$1" ref="$2"
  OLLAMA_HOST="http://${h}" "$OLLAMA_BIN" rm "$ref"
}

# --- main ----------------------------------------------------------------------
IFS=',' read -r -a HOST_ARR <<<"$HOSTS"

echo "== Ollama variant cleanup =="
echo "Hosts     : ${HOSTS}"
echo "Match     : ${MATCH_RE}"
echo "Keep      : ${KEEP_RE:-<none>}"
echo "Mode      : $( [ $FORCE -eq 1 ] && echo DELETE || echo DRY-RUN )"
echo

for h in "${HOST_ARR[@]}"; do
  echo "--> Host ${h}"
  if ! check_daemon "$h"; then
    echo "   ! ${h} not reachable; skipping"
    echo
    continue
  fi

  # Gather candidates
  mapfile -t all_names < <(list_names "$h" || true)
  if [ ${#all_names[@]} -eq 0 ]; then
    echo "   (no models)"
    echo
    continue
  fi

  # Select by MATCH_RE, exclude by KEEP_RE
  mapfile -t to_remove < <(
    printf '%s\n' "${all_names[@]}" \
      | grep -E "${MATCH_RE}" \
      | grep -Ev "${KEEP_RE}"
  ) || true

  if [ ${#to_remove[@]} -eq 0 ]; then
    echo "   Nothing to remove."
    echo
    continue
  fi

  echo "   Candidates (${#to_remove[@]}):"
  printf '     - %s\n' "${to_remove[@]}"

  if [ $FORCE -eq 0 ]; then
    echo "   [dry-run] nothing deleted. Use --force to remove."
    echo
    continue
  fi

  echo "   Deleting…"
  ok=0; fail=0
  for ref in "${to_remove[@]}"; do
    if remove_one "$h" "$ref"; then
      echo "     ✔ removed ${ref}"
      ok=$((ok+1))
    else
      echo "     ✖ FAILED ${ref}"
      fail=$((fail+1))
    fi
  done
  echo "   Summary: removed=${ok} failed=${fail}"
  echo
done

echo "Done."

