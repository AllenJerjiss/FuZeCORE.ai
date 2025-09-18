#!/usr/bin/env bash
# cleanup-variants.sh
# Remove benchmark-created Ollama variants named like: LLM-FuZe-model-env-nvidia-gpu-ng<NUM>[:tag]
# Updated for multi-GPU support: handles gpu labels like nvidia-3090ti+nvidia-5090+nvidia-3090ti
# Safe by default (dry-run). Use --force to actually delete.

set -euo pipefail

###############################################################################
# Defaults (override via flags)
###############################################################################
HOSTS="127.0.0.1:11434 127.0.0.1:11435 127.0.0.1:11436 127.0.0.1:11437"  # space-separated list
MATCH_RE="^LLM-FuZe-.*"
MALFORMED_RE="^LLM-FuZe-LLM-FuZe-.*"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
MALFORMED_RE="^LLM-FuZe-LLM-FuZe-.*"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
MALFORMED_RE="^LLM-FuZe-LLM-FuZe-.*"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
MALFORMED_RE="^LLM-FuZe-LLM-FuZe-.*"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
MALFORMED_RE="^LLM-FuZe-LLM-FuZe-.*"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
MALFORMED_RE="^LLM-FuZe-LLM-FuZe-.*"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
KEEP_RE=''                                     # exclude anything matching this
CREATED_LIST=''                                # optional file: only delete names listed here
FORCE=0                                        # 0=dry-run, 1=delete
YES=0                                          # suppress prompt if FORCE=1
NUKEALL=0                                      # 0=normal, 1=remove ALL LLM-FuZe variants regardless of pattern
OLLAMA_BIN="${OLLAMA_BIN:-$(command -v ollama || true)}"

###############################################################################
usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --hosts "h1:port h2:port"   Hosts to clean (default: "$HOSTS")
  --match REGEX               Regex of names to remove (default: $MATCH_RE)
  --keep  REGEX               Regex of names to keep (exclude)
  --from-created FILE         Only remove names present in this file
                              (lines like: my-variant-name OR my-variant-name:latest)
  --force                     Actually delete (otherwise dry-run)
  --yes                       Don't prompt when --force is set
  --nukeall                   Remove ALL LLM-FuZe- variants (ignores --match regex)
  --ollama-bin PATH           Path to ollama binary (default: auto-detect)
  -h|--help                   This help

Examples:
  Dry run (show what would be removed on all test endpoints):
    $(basename "$0")

  Actually delete on local + another host, but keep any "golden" variants:
    $(basename "$0") --hosts "127.0.0.1:11434 10.0.0.12:11434" \\
      --keep 'golden|pinned' --force --yes

  Remove only variants previously created by the benchmark:
    $(basename "$0") --from-created /path/to/ollama_created_*.txt --force --yes

  Remove only from main endpoint (skip test services):
    $(basename "$0") --hosts "127.0.0.1:11434" --force --yes
USAGE
}

###############################################################################
# Parse CLI
###############################################################################
while [ $# -gt 0 ]; do
  case "$1" in
    --hosts)        HOSTS="$2"; shift 2;;
MATCH_RE="^LLM-FuZe-.*"
MALFORMED_RE="^LLM-FuZe-LLM-FuZe-.*"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
MALFORMED_RE="^LLM-FuZe-LLM-FuZe-.*"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
MALFORMED_RE="^LLM-FuZe-LLM-FuZe-.*"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
MALFORMED_RE="^LLM-FuZe-LLM-FuZe-.*"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
MALFORMED_RE="^LLM-FuZe-LLM-FuZe-.*"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
MALFORMED_RE="^LLM-FuZe-LLM-FuZe-.*"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
GPU_PATTERN_RE="(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)"
    --keep)         KEEP_RE="$2"; shift 2;;
    --from-created) CREATED_LIST="$2"; shift 2;;
    --force)        FORCE=1; shift;;
    --yes)          YES=1; shift;;
    --nukeall)      NUKEALL=1; shift;;
    --ollama-bin)   OLLAMA_BIN="$2"; shift 2;;
    -h|--help)      usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

if [ -z "${OLLAMA_BIN:-}" ] || [ ! -x "$OLLAMA_BIN" ]; then
  echo "ERROR: 'ollama' not found. Set --ollama-bin PATH or put it in \$PATH." >&2
  exit 1
fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need curl
need jq
need awk
need sed

###############################################################################
# Helpers
###############################################################################
_strip_latest() { sed -E 's/:latest$//'; }

fetch_names() { # host -> prints model names (with tag if present) or nothing on error
  local host="$1"
  curl -fsS --max-time 5 "http://${host}/api/tags" \
    | jq -r '.models[]?.name' 2>/dev/null || true
}

# Normalize a list against CREATED_LIST (if provided):
filter_by_created_list() {
  if [ -z "${CREATED_LIST:-}" ]; then cat; return 0; fi
  [ -f "$CREATED_LIST" ] || { echo "WARN: created-list not found: $CREATED_LIST (ignored)" >&2; cat; return 0; }
  # Build a normalized set from created-list (strip any :latest)
  awk 'NF{print $0}' "$CREATED_LIST" | _strip_latest | sort -u > /tmp/created.$$.lst
  # Keep only names whose base matches one of created list lines
  awk 'NF{print $0}' \
    | awk -F':' '{print $1}' \
    | grep -Fxf /tmp/created.$$.lst || true
  rm -f /tmp/created.$$.lst
}

apply_match_keep() { # stdin list -> stdout filtered
  if [ "$NUKEALL" -eq 1 ]; then
    # NUKEALL: remove ALL LLM-FuZe- variants, ignore match/keep patterns
    grep -E '^LLM-FuZe-' || true
  else
    # Normal mode: apply match and keep patterns
    if [ -n "$MATCH_RE" ]; then
      grep -E "$MATCH_RE" || true
    else
      cat
    fi | if [ -n "$KEEP_RE" ]; then
          grep -Ev "$KEEP_RE" || true
        else
          cat
        fi
  fi
}

confirm_or_die() {
  local count="$1" host="$2"
  if [ "$FORCE" -eq 0 ]; then
    echo "[dry-run] Would remove $count models on ${host}."
    return 1
  fi
  if [ "$YES" -eq 1 ]; then
    return 0
  fi
  read -r -p "Delete $count models on ${host}? Type 'yes' to proceed: " ans
  [ "$ans" = "yes" ]
}

delete_one() { # host name
  local host="$1" name="$2"
  OLLAMA_HOST="http://${host}" "$OLLAMA_BIN" rm "$name" >/dev/null 2>&1 || \
  { case "$name" in *:*) return 1;; *) OLLAMA_HOST="http://${host}" "$OLLAMA_BIN" rm "${name}:latest" >/dev/null 2>&1 || return 1;; esac; }
  return 0
}

###############################################################################
# Main
###############################################################################
total_removed=0
total_candidates=0

for host in $HOSTS; do
  echo "== Host ${host} =="
  names="$(fetch_names "$host")"
  if [ -z "$names" ]; then
    echo "  (no models or host unreachable)"
    continue
  fi

  # Build candidate list:
  # 1) if created-list provided, restrict to those
  # 2) apply match regex
  # 3) exclude keep regex
  candidates="$(printf "%s\n" "$names" \
      | filter_by_created_list \
      | apply_match_keep \
      | sort -u)"
  if [ -z "$candidates" ]; then
    echo "  Nothing matched."
    continue
  fi

  n_candidates="$(printf "%s\n" "$candidates" | awk 'NF' | wc -l | awk '{print $1}')"
  total_candidates=$((total_candidates + n_candidates))

  echo "  Candidates to remove (${n_candidates}):"
  printf "    %s\n" $candidates

  if ! confirm_or_die "$n_candidates" "$host"; then
    echo "  Skipped (dry-run)."
    continue
  fi

  removed=0
  # Delete both with and without :latest where applicable
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if delete_one "$host" "$name"; then
      echo "  - removed: $name"
      removed=$((removed+1))
    else
      echo "  - failed : $name"
    fi
  done <<< "$candidates"

  echo "  Removed on ${host}: ${removed}/${n_candidates}"
  total_removed=$((total_removed + removed))
done

echo
echo "Summary: candidates=${total_candidates}, removed=${total_removed} (FORCE=${FORCE})"
if [ "$FORCE" -eq 0 ]; then
  echo "Nothing was deleted. Re-run with --force (and optionally --yes) to remove."
fi

