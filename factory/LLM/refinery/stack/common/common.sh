#!/usr/bin/env bash
# common.sh — Shared functions and configuration for stack/common scripts
# Source this file: source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

set -euo pipefail

# ============================================================================
# CENTRALIZED CONFIGURATION
# ============================================================================

# Default directories and paths
export LOG_DIR_DEFAULT="${LOG_DIR:-/var/log/fuze-stack}"
export ALIAS_PREFIX_DEFAULT="${ALIAS_PREFIX:-LLM-FuZe-}"
export SERVICE_HOME_DEFAULT="${SERVICE_HOME:-/root}"

# Default timeouts and limits
export TIMEOUT_DEFAULT=30
export MAX_RETRIES_DEFAULT=3
export TOPN_DEFAULT=5

# Supported stacks
export SUPPORTED_STACKS="ollama vLLM llama.cpp Triton"

# Required system binaries for different operations
export REQUIRED_GPU_TOOLS="nvidia-smi lspci"
export REQUIRED_ANALYSIS_TOOLS="awk sed jq curl"
export REQUIRED_SYSTEM_TOOLS="systemctl id hostname"

# ============================================================================
# STANDARDIZED LOGGING FUNCTIONS
# ============================================================================

# Color codes
readonly RED='\033[31m'
readonly GREEN='\033[32m'
readonly YELLOW='\033[33m'
readonly BLUE='\033[34m'
readonly MAGENTA='\033[35m'
readonly CYAN='\033[36m'
readonly RESET='\033[0m'

# Logging levels
readonly LOG_ERROR=1
readonly LOG_WARN=2
readonly LOG_INFO=3
readonly LOG_DEBUG=4

# Current log level (can be overridden)
LOG_LEVEL="${LOG_LEVEL:-$LOG_INFO}"

# Core logging function
_log() {
    local level="$1" prefix="$2" color="$3"
    shift 3
    [ "$level" -le "$LOG_LEVEL" ] || return 0
    printf "${color}${prefix}${RESET} %s\n" "$*" >&2
}

# Public logging functions
error() { _log "$LOG_ERROR" "ERROR" "$RED" "$@"; }
warn()  { _log "$LOG_WARN"  "WARN " "$YELLOW" "$@"; }
info()  { _log "$LOG_INFO"  "INFO " "$BLUE" "$@"; }
debug() { _log "$LOG_DEBUG" "DEBUG" "$MAGENTA" "$@"; }

# Legacy aliases for compatibility
err() { error "$@"; }
ok()  { _log "$LOG_INFO" "OK   " "$GREEN" "$@"; }
log() { info "$@"; }

# ============================================================================
# ERROR HANDLING FUNCTIONS
# ============================================================================

# Exit with error message
error_exit() {
    error "$@"
    exit 1
}

# Check if command exists
have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# Require command to exist
require_cmd() {
    local cmd="$1" pkg="${2:-$1}"
    have_cmd "$cmd" || error_exit "Missing required command: $cmd (install: $pkg)"
}

# Require multiple commands
require_cmds() {
    local missing=()
    for cmd in "$@"; do
        have_cmd "$cmd" || missing+=("$cmd")
    done
    [ "${#missing[@]}" -eq 0 ] || error_exit "Missing required commands: ${missing[*]}"
}

# Check if file exists and is readable
require_file() {
    local file="$1"
    [ -f "$file" ] || error_exit "Required file not found: $file"
    [ -r "$file" ] || error_exit "Cannot read required file: $file"
}

# Check if directory exists and is writable
require_dir_writable() {
    local dir="$1"
    [ -d "$dir" ] || error_exit "Directory not found: $dir"
    [ -w "$dir" ] || error_exit "Directory not writable: $dir"
}

# ============================================================================
# TEMP FILE MANAGEMENT
# ============================================================================

# Array to track temp files for cleanup
declare -a TEMP_FILES=()

# Create temp file and register for cleanup
make_temp() {
    local temp
    temp="$(mktemp)"
    TEMP_FILES+=("$temp")
    echo "$temp"
}

# Create temp directory and register for cleanup
make_temp_dir() {
    local temp
    temp="$(mktemp -d)"
    TEMP_FILES+=("$temp")
    echo "$temp"
}

# Cleanup function for temp files
cleanup_temps() {
    local file
    for file in "${TEMP_FILES[@]}"; do
        [ -e "$file" ] && rm -rf "$file" 2>/dev/null || true
    done
    TEMP_FILES=()
}

# Auto-register cleanup on script exit
trap cleanup_temps EXIT

# ============================================================================
# INPUT VALIDATION FUNCTIONS
# ============================================================================

# Validate CSV file format
validate_csv() {
    local csv="$1" min_cols="${2:-10}"
    require_file "$csv"
    
    # Check if it looks like a CSV
    if ! head -n1 "$csv" | grep -q ','; then
        error_exit "File does not appear to be CSV format: $csv"
    fi
    
    # Check minimum column count
    local cols
    cols="$(head -n1 "$csv" | tr ',' '\n' | wc -l)"
    if [ "$cols" -lt "$min_cols" ]; then
        error_exit "CSV has only $cols columns, expected at least $min_cols: $csv"
    fi
    
    debug "CSV validation passed: $csv ($cols columns)"
}

# Validate numeric parameter
validate_number() {
    local value="$1" name="$2" min="${3:-}" max="${4:-}"
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        error_exit "Parameter $name must be a number: $value"
    fi
    if [ -n "$min" ] && [ "$value" -lt "$min" ]; then
        error_exit "Parameter $name must be >= $min: $value"
    fi
    if [ -n "$max" ] && [ "$value" -gt "$max" ]; then
        error_exit "Parameter $name must be <= $max: $value"
    fi
}

# Validate regex pattern
validate_regex() {
    local pattern="$1" name="$2"
    if ! echo "" | grep -E "$pattern" >/dev/null 2>&1; then
        # Try to validate the regex by using it
        if ! echo "test" | grep -E "$pattern" >/dev/null 2>&1 && 
           ! echo "" | grep -E "$pattern" >/dev/null 2>&1; then
            error_exit "Invalid regex pattern for $name: $pattern"
        fi
    fi
}

# ============================================================================
# ROOT OPERATION VALIDATION
# ============================================================================

# Show what root operations will be performed
show_root_plan() {
    local operations=("$@")
    warn "This script requires root privileges for:"
    for op in "${operations[@]}"; do
        warn "  - $op"
    done
    info "Run with --dry-run to see detailed actions without executing"
}

# Require root with validation
require_root() {
    local operations=("$@")
    if [ "$(id -u)" -ne 0 ]; then
        error "This script must be run as root."
        show_root_plan "${operations[@]}"
        error_exit "Please run: sudo $0 $*"
    fi
}

# Check if running as root
is_root() {
    [ "$(id -u)" -eq 0 ]
}

# ============================================================================
# DRY RUN SUPPORT
# ============================================================================

# Global dry run flag
DRY_RUN="${DRY_RUN:-0}"

# Execute command or show what would be executed
dry_run_exec() {
    if [ "$DRY_RUN" -eq 1 ]; then
        info "DRY RUN: $*"
    else
        debug "EXEC: $*"
        "$@"
    fi
}

# Show dry run status
show_dry_run_status() {
    if [ "$DRY_RUN" -eq 1 ]; then
        warn "DRY RUN MODE - No changes will be made"
    fi
}

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# Get current git branch
get_git_branch() {
    if have_cmd git && [ -d .git ]; then
        git branch --show-current 2>/dev/null || echo "unknown"
    else
        echo "no-git"
    fi
}

# Convert branch to environment
branch_to_env() {
    local branch="${1:-$(get_git_branch)}"
    case "$branch" in
        main) echo "explore" ;;
        preprod) echo "preprod" ;;
        prod) echo "prod" ;;
        *) echo "explore" ;;
    esac
}

# Check if NVIDIA GPU is present
has_nvidia_gpu() {
    if have_cmd nvidia-smi && nvidia-smi >/dev/null 2>&1; then
        return 0
    fi
    if have_cmd lspci && lspci | grep -qi 'vga.*nvidia\|3d.*nvidia'; then
        return 0
    fi
    return 1
}

# Get hostname (short form)
get_hostname() {
    hostname -s 2>/dev/null || hostname 2>/dev/null || echo "unknown"
}

# ============================================================================
# INITIALIZATION
# ============================================================================

# Function to initialize common environment
init_common() {
    local script_name="${1:-$(basename "${BASH_SOURCE[1]}")}"
    debug "Initializing common environment for: $script_name"
    
    # Set default log level based on environment
    if [ "${VERBOSE:-0}" -eq 1 ]; then
        LOG_LEVEL="$LOG_DEBUG"
    elif [ "${QUIET:-0}" -eq 1 ]; then
        LOG_LEVEL="$LOG_ERROR"
    fi
    
    debug "Log level: $LOG_LEVEL"
    debug "Dry run: $DRY_RUN"
}

# Auto-initialize if this file is sourced
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    init_common
fi