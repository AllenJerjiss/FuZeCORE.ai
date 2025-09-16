#!/usr/bin/env bash
# install.sh - Installation script for FuZe stack/common utilities
# This script sets up the common utilities and validates the environment

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
CONFIG_DIR="${CONFIG_DIR:-/etc/fuze-stack}"
LOG_DIR="${LOG_DIR:-/var/log/fuze-stack}"
DRY_RUN=0
FORCE=0
USER_INSTALL=0

usage() {
    cat <<USAGE
Usage: $(basename "$0") [--dry-run] [--force] [--user] [--install-dir DIR] [--help]

Options:
  --dry-run         Show what would be done without making changes
  --force           Overwrite existing installations
  --user            Install to user directory (~/.local/bin) instead of system
  --install-dir DIR Install binaries to DIR (default: $INSTALL_DIR)
  --help            Show this help message

This script installs the FuZe stack common utilities system-wide.
For user installation, use --user (no root required).
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --force) FORCE=1; shift ;;
        --user) USER_INSTALL=1; shift ;;
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done

# Adjust paths for user installation
if [ "$USER_INSTALL" -eq 1 ]; then
    INSTALL_DIR="$HOME/.local/bin"
    CONFIG_DIR="$HOME/.config/fuze-stack"
    LOG_DIR="$HOME/.local/share/fuze-stack/logs"
fi

# Colors for output
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
RESET='\033[0m'

info() { printf "${BLUE}INFO${RESET} %s\n" "$*"; }
warn() { printf "${YELLOW}WARN${RESET} %s\n" "$*"; }
error() { printf "${RED}ERROR${RESET} %s\n" "$*" >&2; }
ok() { printf "${GREEN}OK${RESET} %s\n" "$*"; }

show_plan() {
    info "Installation plan:"
    info "  Install type: $([ "$USER_INSTALL" -eq 1 ] && echo "User" || echo "System")"
    info "  Install directory: $INSTALL_DIR"
    info "  Config directory: $CONFIG_DIR"
    info "  Log directory: $LOG_DIR"
    info "  Mode: $([ "$DRY_RUN" -eq 1 ] && echo "DRY RUN" || echo "EXECUTE")"
    echo
}

check_requirements() {
    info "Checking requirements..."
    
    local missing=()
    for cmd in awk sed jq curl git; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    
    if [ "${#missing[@]}" -gt 0 ]; then
        error "Missing required commands: ${missing[*]}"
        error "Please install them first. On Ubuntu/Debian:"
        error "  sudo apt-get install ${missing[*]}"
        exit 1
    fi
    
    ok "All required commands available"
}

check_permissions() {
    info "Checking permissions..."
    
    if [ "$USER_INSTALL" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
        error "System installation requires root privileges"
        error "Run with sudo or use --user for user installation"
        exit 1
    fi
    
    # Check if we can create directories (check parent paths exist or can be created)
    local test_dirs=("$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR")
    for dir in "${test_dirs[@]}"; do
        local check_dir="$dir"
        
        # Walk up the directory tree to find the first existing parent
        while [ ! -d "$check_dir" ] && [ "$check_dir" != "/" ]; do
            check_dir="$(dirname "$check_dir")"
        done
        
        if [ ! -w "$check_dir" ]; then
            error "Cannot write to directory tree: $check_dir (needed for $dir)"
            exit 1
        fi
    done
    
    ok "Permissions check passed"
}

create_directories() {
    info "Creating directories..."
    
    for dir in "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR"; do
        if [ "$DRY_RUN" -eq 1 ]; then
            info "DRY RUN: Would create directory: $dir"
        else
            mkdir -p "$dir" || { error "Failed to create directory: $dir"; exit 1; }
            info "Created: $dir"
        fi
    done
}

install_scripts() {
    info "Installing scripts..."
    
    # List of scripts to install
    local scripts=(
        "analyze.sh"
        "clean-bench.sh" 
        "collect-results.sh"
        "gpu-setup.sh"
        "migrate-logs.sh"
        "preflight.sh"
        "summarize-benchmarks.sh"
    )
    
    for script in "${scripts[@]}"; do
        local src="$SCRIPT_DIR/$script"
        local dst="$INSTALL_DIR/fuze-$(basename "$script" .sh)"
        
        if [ ! -f "$src" ]; then
            warn "Script not found, skipping: $src"
            continue
        fi
        
        if [ -f "$dst" ] && [ "$FORCE" -eq 0 ]; then
            warn "Script exists, skipping (use --force to overwrite): $dst"
            continue
        fi
        
        if [ "$DRY_RUN" -eq 1 ]; then
            info "DRY RUN: Would install $script -> $dst"
        else
            cp "$src" "$dst" || { error "Failed to copy $src -> $dst"; exit 1; }
            chmod +x "$dst" || { error "Failed to make executable: $dst"; exit 1; }
            ok "Installed: $dst"
        fi
    done
}

install_awk_files() {
    info "Installing AWK library files..."
    
    local awk_files=(
        "variant_analysis.awk"
        "baseline_map.awk"
        "top_analysis.awk"
    )
    
    local awk_dir="$CONFIG_DIR/awk"
    if [ "$DRY_RUN" -eq 1 ]; then
        info "DRY RUN: Would create AWK directory: $awk_dir"
    else
        mkdir -p "$awk_dir"
    fi
    
    for awk_file in "${awk_files[@]}"; do
        local src="$SCRIPT_DIR/$awk_file"
        local dst="$awk_dir/$awk_file"
        
        if [ ! -f "$src" ]; then
            warn "AWK file not found, skipping: $src"
            continue
        fi
        
        if [ "$DRY_RUN" -eq 1 ]; then
            info "DRY RUN: Would install $awk_file -> $dst"
        else
            cp "$src" "$dst" || { error "Failed to copy $src -> $dst"; exit 1; }
            ok "Installed AWK: $dst"
        fi
    done
}

install_common_lib() {
    info "Installing common library..."
    
    local src="$SCRIPT_DIR/common.sh"
    local dst="$CONFIG_DIR/common.sh"
    
    if [ ! -f "$src" ]; then
        error "Common library not found: $src"
        exit 1
    fi
    
    if [ "$DRY_RUN" -eq 1 ]; then
        info "DRY RUN: Would install common.sh -> $dst"
    else
        cp "$src" "$dst" || { error "Failed to copy $src -> $dst"; exit 1; }
        ok "Installed common library: $dst"
    fi
}

create_config() {
    info "Creating configuration..."
    
    local config_file="$CONFIG_DIR/config.env"
    
    if [ -f "$config_file" ] && [ "$FORCE" -eq 0 ]; then
        info "Config file exists, skipping: $config_file"
        return
    fi
    
    if [ "$DRY_RUN" -eq 1 ]; then
        info "DRY RUN: Would create config file: $config_file"
        return
    fi
    
    cat > "$config_file" <<EOF
# FuZe Stack Configuration
# Source this file to set environment variables

# Directories
export LOG_DIR="$LOG_DIR"
export CONFIG_DIR="$CONFIG_DIR"

# Default settings
export ALIAS_PREFIX="LLM-FuZe-"
export TOPN_DEFAULT=5
export TIMEOUT_DEFAULT=30

# AWK library path
export AWKPATH="$CONFIG_DIR/awk:\$AWKPATH"

# Add install directory to PATH if not already there
if [[ ":\$PATH:" != *":$INSTALL_DIR:"* ]]; then
    export PATH="$INSTALL_DIR:\$PATH"
fi
EOF
    
    ok "Created config: $config_file"
}

show_usage_info() {
    info ""
    info "Installation completed successfully!"
    info ""
    info "To use the FuZe stack utilities:"
    if [ "$USER_INSTALL" -eq 1 ]; then
        info "  1. Add to your shell profile (~/.bashrc or ~/.zshrc):"
        info "     source $CONFIG_DIR/config.env"
    else
        info "  1. Source the config (or add to /etc/environment):"
        info "     source $CONFIG_DIR/config.env"
    fi
    info "  2. Run commands like:"
    info "     fuze-analyze --help"
    info "     fuze-preflight"
    info "     fuze-gpu-setup --dry-run"
    info ""
    info "Available commands:"
    local scripts=(
        "fuze-analyze:Analyze benchmark results"
        "fuze-clean-bench:Clean benchmark artifacts"
        "fuze-collect-results:Collect results from all stacks"
        "fuze-gpu-setup:Setup NVIDIA GPU drivers"
        "fuze-migrate-logs:Migrate logs to system location"
        "fuze-preflight:System health checks"
        "fuze-summarize-benchmarks:Generate performance reports"
    )
    
    for entry in "${scripts[@]}"; do
        local cmd="${entry%%:*}"
        local desc="${entry##*:}"
        printf "  %-25s %s\n" "$cmd" "$desc"
    done
}

run_tests() {
    info "Running tests..."
    
    if [ -f "$SCRIPT_DIR/test_common.sh" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            info "DRY RUN: Would run test suite"
        else
            if bash "$SCRIPT_DIR/test_common.sh"; then
                ok "All tests passed"
            else
                warn "Some tests failed, but installation continues"
            fi
        fi
    else
        warn "Test suite not found, skipping tests"
    fi
}

main() {
    show_plan
    check_requirements
    check_permissions
    create_directories
    install_common_lib
    install_awk_files
    install_scripts
    create_config
    run_tests
    show_usage_info
}

# Run main function
main "$@"