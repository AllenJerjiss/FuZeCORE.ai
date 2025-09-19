#!/usr/bin/env bash
# analyze.sh — Summarize a benchmark CSV (any stack) with clear results
# Usage:
#   ./analyze.sh [--stack STACK] [--csv PATH] [--model REGEX] [--top N]
# Defaults:
#   --stack autodetect latest among {ollama,vLLM,llamacpp,Triton}
#   --csv   pick latest CSV in LOG_DIR
#   --model no filter
#   --top   5

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Configuration
LOG_DIR="${LOG_DIR:-$LOG_DIR_DEFAULT}"
ALIAS_PREFIX="${ALIAS_PREFIX:-$ALIAS_PREFIX_DEFAULT}"
STACK=""
CSV=""
MODEL_RE=""
TOPN="$TOPN_DEFAULT"
WITH_DEBUG=1
NO_TOP=0

usage(){
  cat <<USAGE
Usage: $0 [--stack STACK] [--csv PATH] [--model REGEX] [--top N] [--no-debug] [--no-top]
  STACK: one of {$SUPPORTED_STACKS}
  CSV  : path to a benchmark CSV (overrides autodiscovery)
  MODEL: regex to filter base_model (e.g., '^gemma3:4b')
  TOP  : number of top rows to show (default: ${TOPN})
Env:
  LOG_DIR: logs directory (default: ${LOG_DIR})
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --stack) STACK="$2"; shift 2;;
    --csv)   CSV="$2"; shift 2;;
    --model) MODEL_RE="$2"; shift 2;;
    --top)   TOPN="$2"; shift 2;;
    --no-debug) WITH_DEBUG=0; shift 1;;
    --no-top)   NO_TOP=1; shift 1;;
    -h|--help) usage; exit 0;;
    *) error_exit "Unknown argument: $1";;
  esac
done

# Validate parameters
validate_number "$TOPN" "top" 1 100
[ -n "$MODEL_RE" ] && validate_regex "$MODEL_RE" "model"

# Check required tools
require_cmds awk sed find

# Find CSV if not specified
if [ -z "$CSV" ]; then
  if [ -n "$STACK" ]; then
    # Look for latest CSV for specific stack
    CSV="$(find "$LOG_DIR" -name "${STACK}_benchmark_*.csv" -type f 2>/dev/null | sort | tail -n1)"
  else
    # Auto-detect latest CSV from any stack  
    local latest_csv=""
    local latest_time=0
    for stack in $SUPPORTED_STACKS; do
      local stack_csv
      stack_csv="$(find "$LOG_DIR" -name "${stack}_benchmark_*.csv" -type f 2>/dev/null | sort | tail -n1)"
      if [ -n "$stack_csv" ] && [ -f "$stack_csv" ]; then
        local file_time
        file_time="$(stat -c %Y "$stack_csv" 2>/dev/null || echo 0)"
        if [ "$file_time" -gt "$latest_time" ]; then
          latest_time="$file_time"
          latest_csv="$stack_csv"
          STACK="$(basename "$stack_csv" | cut -d'_' -f1)"
        fi
      fi
    done
    CSV="$latest_csv"
  fi
fi

# Validate CSV file
if [ -z "$CSV" ] || [ ! -f "$CSV" ]; then
  error_exit "No benchmark CSV found. Use --csv PATH or run a benchmark first."
fi

validate_csv "$CSV" 10

HOST_SHORT="$(get_hostname)"

process_gpu_log() {
    local gpu_log="${LOG_DIR}/gpu_monitor.log"
    if [ ! -f "$gpu_log" ]; then
        echo "" # Return empty if log not found
        return
    fi

    # Process the GPU log to get avg/max temp and power for each GPU index
    # We skip the header (NR>1), remove " W" from power, and calculate stats.
    awk -F, '
        NR > 1 && NF >= 6 {
            # Field 2 is index, 4 is temp, 6 is power
            idx = $2;
            temp = $4;
            power = $6;
            gsub(/^[ \t]+|[ \t]+$/, "", idx);
            gsub(/^[ \t]+|[ \t]+$/, "", temp);
            gsub(/^[ \t]+|[ \t]+$/, "", power);
            gsub(/ W/, "", power);

            sum_temp[idx] += temp;
            sum_power[idx] += power;
            count[idx]++;
            if (temp > max_temp[idx]) max_temp[idx] = temp;
            if (power > max_power[idx]) max_power[idx] = power;
        }
        END {
            # Print stats for each GPU found
            for (i in count) {
                printf "GPU%d_AvgTemp:%.1f,GPU%d_MaxTemp:%.1f,GPU%d_AvgPower:%.1f,GPU%d_MaxPower:%.1f\n", \
                       i, sum_temp[i]/count[i], \
                       i, max_temp[i], \
                       i, sum_power[i]/count[i], \
                       i, max_power[i];
            }
        }' "$gpu_log"
}

pick_latest_csv(){
  local dir="$1" stack="$2"; local pat
  case "$stack" in
    ollama)   pat='ollama_bench_*.csv' ;;
    vLLM)     pat='vllm_bench_*.csv' ;;
    llama.cpp|llamacpp|llama-cpp) pat='llamacpp_bench_*.csv' ;;
    Triton|triton) pat='triton_bench_*.csv' ;;
    *) pat='*_bench_*.csv' ;;
  esac
  [ -z "$pat" ] && error_exit "Unknown stack for CSV search: $stack"
  find "$dir" -name "$pat" -type f 2>/dev/null | sort | tail -n1
}

# Process GPU log and store results in a variable
GPU_STATS=$(process_gpu_log)

# Main analysis logic
main(){
  info "CSV     : $CSV"
  info "Host    : $HOST_SHORT"
  info "Stack   : $STACK"

  # Get header and prepare for awk
  local header; header=$(head -n1 "$CSV")
  local awk_script; awk_script="${SCRIPT_DIR}/../common/variant_analysis.awk"
  local gpu_header="AvgTemp,MaxTemp,AvgPower,MaxPower"

  # This awk command will be used to join GPU stats with benchmark results
  local join_awk_cmd="
    BEGIN {
        OFS=\",\";
        # Create a dictionary from the GPU stats
        split(\"$GPU_STATS\", lines, \"\n\");
        for (l in lines) {
            if (lines[l] == \"\") continue;
            split(lines[l], pairs, \",\");
            for (p in pairs) {
                split(pairs[p], kv, \":\");
                stats_dict[kv[1]] = kv[2];
            }
        }
    }
    # For every line of benchmark data...
    NR > 1 {
        # Extract GPU index from 'host' column (e.g., ...:11435 -> 0)
        split(\$3, host_parts, \"/\");
        split(host_parts[2], port_parts, \":\");
        gpu_idx = port_parts[2] - 11435;

        # Look up stats from our dictionary
        avg_temp = stats_dict[\"GPU\" gpu_idx \"_AvgTemp\"];
        max_temp = stats_dict[\"GPU\" gpu_idx \"_MaxTemp\"];
        avg_power = stats_dict[\"GPU\" gpu_idx \"_AvgPower\"];
        max_power = stats_dict[\"GPU\" gpu_idx \"_MaxPower\"];

        # Print original line plus new stats
        print \$0, (avg_temp ? avg_temp : \"N/A\"), \
                   (max_temp ? max_temp : \"N/A\"), \
                   (avg_power ? avg_power : \"N/A\"), \
                   (max_power ? max_power : \"N/A\");
    }
    # Print the header line
    NR == 1 {
        print \$0, \"$gpu_header\";
    }
  "

  # Top N table
  if [ "$NO_TOP" -eq 0 ]; then
    echo
    echo "Top ${TOPN} by tokens/sec (with GPU stats if available):"
    (
      echo "$header,fuze_gain_factor"
      tail -n+2 "$CSV" | \
        grep -E -- "$MODEL_RE" | \
        awk -F, -v base_ts="$base_ts" -f "$awk_script"
    ) | \
    sort -t, -k10,10nr | head -n $((TOPN + 1)) | \
    awk -F, "$join_awk_cmd" | \
    format_table
  fi

  # Best optimized per endpoint
  echo
  echo "Best optimized per (endpoint, model):"
  (
    echo "$header,fuze_gain_factor"
    (
      tail -n+2 "$CSV" | \
        awk -F, -v base_ts="$base_ts" -f "$awk_script" | \
        grep -E -- "$MODEL_RE" | \
        grep -v "persistent"
    ) | \
    sort -t, -k3,3 -k10,10nr | sort -t, -u -k3,3
  ) | awk -F, "$join_awk_cmd" | format_table

  # Baseline vs best optimized
  echo
  echo "Base vs Optimized (per endpoint & model):"
  (
    echo "$header,fuze_gain_factor"
    tail -n+2 "$CSV" | \
      grep -E -- "$MODEL_RE" | \
      awk -F, -v base_ts="$base_ts" -f "$awk_script" | \
      grep "persistent"
  ) | \
  awk -F, 'BEGIN{OFS=","} NR==1{print $0,"AvgTemp,MaxTemp,AvgPower,MaxPower"} NR>1{print $0,"N/A,N/A,N/A,N/A"}' | \
  format_table

  # Best across all endpoints
  echo
  echo "Best across endpoints (per model): baseline vs optimized"
  (
    echo "$header,fuze_gain_factor"
    (
      tail -n+2 "$CSV" | \
        awk -F, -v base_ts="$base_ts" -f "$awk_script" | \
        grep -E -- "$MODEL_RE" | \
        grep -v "persistent" | \
        sort -t, -k10,10nr | head -n1
    )
  ) | awk -F, "$join_awk_cmd" | format_table

  echo "OK    Analysis complete."
}

# Check if being sourced or run directly
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    # Argument parsing
    while [ $# -gt 0 ]; do
        case "$1" in
            --stack) STACK="$2"; shift 2;;
            --csv)   CSV="$2"; shift 2;;
            --model) MODEL_RE="$2"; shift 2;;
            --top)   TOPN="$2"; shift 2;;
            *) error_exit "Unknown argument: $1";;
        esac
    done
    main
fi
