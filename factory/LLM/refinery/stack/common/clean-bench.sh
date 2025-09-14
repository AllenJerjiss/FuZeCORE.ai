#!/usr/bin/env bash
# clean-bench.sh — Safely clean benchmark artifacts by env/branch
# - Defaults env based on current git branch: main=explore, preprod=preprod, prod=prod
# - Dry-run by default; requires --yes to actually delete
# - Can also run stack-level variant cleanup (Ollama) if requested

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
UST="${ROOT_DIR}/stack/ust.sh"

LOG_DIR="${LOG_DIR:-/var/log/fuze-stack}"
ENV_MODE=""
DO_LOGS=1
DO_REPO=1
DO_ENVS=0        # only true for explore mode unless forced
DO_VARIANTS=0
KEEP_LATEST=0
YES=0

usage(){
  cat <<USAGE
Usage: $(basename "$0") [--env explore|preprod|prod] [--no-logs] [--no-repo] [--envs] [--variants] [--keep-latest N] [--yes]
Defaults:
  - env inferred from branch: main=explore, preprod=preprod, prod=prod
  - removes bench logs under LOG_DIR and repo aggregates under factory/LLM/refinery (dry-run unless --yes)
  - does NOT remove env files unless --envs (and only for explore by default)
Options:
  --env MODE         : explore | preprod | prod (override branch mapping)
  --no-logs          : skip cleaning LOG_DIR artifacts
  --no-repo          : skip cleaning repo aggregates
  --envs             : also remove env files (only explore by default)
  --variants         : run Ollama cleanup-variants (requires sudo)
  --keep-latest N    : keep latest N bench CSVs in LOG_DIR
  --yes              : perform deletions; without this it's a dry-run
Env:
  LOG_DIR            : default /var/log/fuze-stack
USAGE
}

branch(){ git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown; }

while [ $# -gt 0 ]; do
  case "$1" in
    --env) ENV_MODE="$2"; shift 2;;
    --no-logs) DO_LOGS=0; shift 1;;
    --no-repo) DO_REPO=0; shift 1;;
    --envs) DO_ENVS=1; shift 1;;
    --variants) DO_VARIANTS=1; shift 1;;
    --keep-latest) KEEP_LATEST="$2"; shift 2;;
    --yes|-y) YES=1; shift 1;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

if [ -z "${ENV_MODE}" ]; then
  case "$(branch)" in
    main) ENV_MODE="explore";;
    preprod) ENV_MODE="preprod";;
    prod) ENV_MODE="prod";;
    *) ENV_MODE="explore";;
  esac
fi

echo "== Clean plan =="
echo "Branch : $(branch)"
echo "Env    : ${ENV_MODE}"
echo "Logs   : ${LOG_DIR} (clean=${DO_LOGS}, keep-latest=${KEEP_LATEST})"
echo "Repo   : ${ROOT_DIR}/benchmarks*.csv (clean=${DO_REPO})"
echo "Envs   : ${ROOT_DIR}/stack/env (clean=${DO_ENVS})"
echo "Variants: ${DO_VARIANTS}"
echo "Mode   : $([ "$YES" -eq 1 ] && echo EXECUTE || echo DRY-RUN)"

do_rm(){ # files...
  local files=("$@");
  [ ${#files[@]} -eq 0 ] && return 0
  if [ "$YES" -eq 1 ]; then
    rm -rf "${files[@]}" 2>/dev/null || true
  else
    printf '  rm %s\n' "${files[@]}"
  fi
}

# Clean logs
if [ "$DO_LOGS" -eq 1 ]; then
  shopt -s nullglob
  bench_csv=("$LOG_DIR"/*_bench_*.csv)
  if [ "$KEEP_LATEST" -gt 0 ] && [ ${#bench_csv[@]} -gt "$KEEP_LATEST" ]; then
    mapfile -t sorted < <(ls -t "$LOG_DIR"/*_bench_*.csv 2>/dev/null || true)
    to_remove=("${sorted[@]:$KEEP_LATEST}")
  else
    to_remove=("${bench_csv[@]}")
  fi
  other=("$LOG_DIR"/wrapper_* "$LOG_DIR"/ollama_export_*.csv "$LOG_DIR"/export_errors_* "$LOG_DIR"/debug_*)
  echo "-- Logs to remove:"
  do_rm "${to_remove[@]}" "${other[@]}"
  shopt -u nullglob
fi

# Clean repo aggregates
if [ "$DO_REPO" -eq 1 ]; then
  echo "-- Repo aggregates to remove:"
  do_rm "${ROOT_DIR}/benchmarks.csv" "${ROOT_DIR}"/benchmarks.best*.csv
fi

# Clean envs
if [ "$DO_ENVS" -eq 1 ]; then
  case "$ENV_MODE" in
    explore)
      echo "-- Env files (explore) to remove:"
      do_rm "${ROOT_DIR}/stack/env/explore"/*.env ;;
    preprod)
      echo "-- Env files (preprod) requested, skipping by default (safer). Use FORCE_PREPROD_ENVS=1 to allow."
      [ "${FORCE_PREPROD_ENVS:-0}" -eq 1 ] && do_rm "${ROOT_DIR}/stack/env/preprod"/*.env || true ;;
    prod)
      echo "-- Env files (prod) requested, skipping by default (safer). Use FORCE_PROD_ENVS=1 to allow."
      [ "${FORCE_PROD_ENVS:-0}" -eq 1 ] && do_rm "${ROOT_DIR}/stack/env/prod"/*.env || true ;;
  esac
fi

# Variants cleanup
if [ "$DO_VARIANTS" -eq 1 ]; then
  echo "-- Running Ollama variant cleanup"
  if [ "$YES" -eq 1 ]; then
    sudo -E "$UST" ollama cleanup-variants --force --yes || true
  else
    echo "  would run: sudo -E $UST ollama cleanup-variants --force --yes"
  fi
fi

echo "Done."

