#!/usr/bin/env bash
# gpu_monitor.sh - Start or stop GPU statistics logging.
# Usage: ./gpu_monitor.sh [start|stop]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

LOG_DIR="${LOG_DIR:-$LOG_DIR_DEFAULT}"
MONITOR_PID_FILE="${LOG_DIR}/gpu_monitor.pid"

usage() {
    cat <<USAGE
Usage: $(basename "$0") <start|stop>

Commands:
  start    Start logging GPU stats in the background.
  stop     Stop the background logging process.
USAGE
}

start_monitor() {
    local log_file="${LOG_DIR}/gpu_monitor.log"
    info "Starting GPU monitor. Logging to: ${log_file}"
    mkdir -p "$(dirname "$log_file")"
    
    # Start nvidia-smi in the background and save its PID
    nohup nvidia-smi --query-gpu=timestamp,index,name,temperature.gpu,utilization.gpu,power.draw,pstate --format=csv -l 1 > "$log_file" 2>/dev/null &
    echo $! > "$MONITOR_PID_FILE"
    
    sleep 1 # Give it a moment to start
    if [ -f "$MONITOR_PID_FILE" ] && ps -p "$(cat "$MONITOR_PID_FILE")" > /dev/null; then
        info "GPU monitor started with PID $(cat "$MONITOR_PID_FILE")."
    else
        error_exit "Failed to start GPU monitor."
    fi
}

stop_monitor() {
    if [ ! -f "$MONITOR_PID_FILE" ]; then
        info "No active GPU monitor found (no PID file)."
        return
    fi

    local pid
    pid=$(cat "$MONITOR_PID_FILE")
    if ps -p "$pid" > /dev/null; then
        info "Stopping GPU monitor (PID: $pid)..."
        kill "$pid"
        # Wait for the process to terminate
        for i in {1..5}; do
            if ! ps -p "$pid" > /dev/null; then
                break
            fi
            sleep 0.5
        done
        # Force kill if it's still running
        if ps -p "$pid" > /dev/null; then
            warn "Monitor process $pid did not stop gracefully. Forcing kill..."
            kill -9 "$pid"
        fi
        info "GPU monitor stopped."
    else
        info "GPU monitor process (PID: $pid) not found. Already stopped?"
    fi
    rm -f "$MONITOR_PID_FILE"
}

# Main command dispatcher
if [ $# -eq 0 ]; then
    usage
    exit 1
fi

case "$1" in
    start) start_monitor ;;
    stop) stop_monitor ;;
    *) error_exit "Unknown command: $1" ;;
esac
