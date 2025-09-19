#!/usr/bin/env bash
# install.sh - Installation script for FuZe stack/common utilities
# This script sets up the common utilities and validates the environment

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/fuze-stack"
LOG_DIR="/var/log/fuze-stack"
CACHE_DIR="/FuZe/installer-cache"
DRY_RUN=0
TRY_CACHE=0
UPGRADE=0
STACKS=()

usage() {
    cat <<USAGE
Usage: $(basename "$0") [--dry-run] [--try-cache] [--upgrade] [--help] [stack...]

Options:
  --dry-run         Show what would be done without making changes
  --try-cache       Try to use cached binaries from $CACHE_DIR first, fall back to download if not found
  --upgrade         Force fresh downloads, ignoring cache
  --help            Show this help message

Arguments:
  stack...          Stack names to install (ollama, vllm, llama.cpp, triton)
                    Default: ollama (if no stacks specified)

This script installs the FuZe stack common utilities and specified stacks.
Binary cache location: $CACHE_DIR

Examples:
  $(basename "$0")                    # Install utilities + Ollama (download fresh)
  $(basename "$0") --try-cache        # Install utilities + Ollama (use cache if available)
  $(basename "$0") --try-cache ollama # Install utilities + Ollama (use cache if available)
  $(basename "$0") ollama vllm        # Install utilities + Ollama + vLLM (when supported)
  $(basename "$0") --upgrade ollama   # Force fresh downloads and upgrade Ollama
  $(basename "$0") --dry-run          # Show what would be done
  
Requires root privileges for system installation.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --try-cache) TRY_CACHE=1; shift ;;
        --upgrade) UPGRADE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; STACKS+=("$@"); break ;;
        -*) echo "Unknown option: $1" >&2; usage; exit 2 ;;
        *) STACKS+=("$1"); shift ;;
    esac
done

# Adjust paths for user installation - REMOVED (system only now)

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
    info "  Install type: System (requires root)"
    info "  Install directory: $INSTALL_DIR"
    info "  Config directory: $CONFIG_DIR"
    info "  Log directory: $LOG_DIR"
    info "  Cache directory: $CACHE_DIR"
    info "  Try cache first: $([ "$TRY_CACHE" -eq 1 ] && echo "Yes" || echo "No")"
    info "  Force upgrade: $([ "$UPGRADE" -eq 1 ] && echo "Yes" || echo "No")"
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
    
    if [ "$(id -u)" -ne 0 ]; then
        error "System installation requires root privileges"
        error "Run with sudo"
        exit 1
    fi
    
    # Check if we can create directories (check parent paths exist or can be created)
    local test_dirs=("$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR" "$CACHE_DIR")
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
    
    for dir in "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR" "$CACHE_DIR"; do
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
        
        if [ -f "$dst" ]; then
            warn "Script exists, skipping: $dst"
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
    
    if [ -f "$config_file" ]; then
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
    info "  1. Source the config (or add to /etc/environment):"
    info "     source $CONFIG_DIR/config.env"
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

install_ollama() {
    local try_cache_flag=$TRY_CACHE
    local ollama_installer_url="https://ollama.com/install.sh"
    local installer_cache_dir="/FuZe/installer-cache"
    local ollama_installer_path="$installer_cache_dir/ollama_install.sh"
    local ollama_binary_cache_path="$installer_cache_dir/ollama"
    local ollama_system_binary_path="/usr/local/bin/ollama"

    # Ensure the cache directory exists
    if [ ! -d "$installer_cache_dir" ]; then
        info "Creating installer cache directory at $installer_cache_dir"
        sudo mkdir -p "$installer_cache_dir"
        sudo chown -R "$(whoami)":"$(whoami)" "$installer_cache_dir"
    fi

    # --- New Caching Logic ---
    if [ "$try_cache_flag" -eq 1 ] && [ -f "$ollama_binary_cache_path" ]; then
        info "Found cached Ollama binary. Bypassing official installer's download."
        
        info "Placing cached binary..."
        sudo cp "$ollama_binary_cache_path" "$ollama_system_binary_path"
        sudo chmod +x "$ollama_system_binary_path"

        info "Manually configuring systemd and user..."
        if ! id fuze >/dev/null 2>&1; then
            info "Creating fuze user..."
            sudo useradd -r -s /bin/false -U -m -d /usr/share/ollama fuze
        fi
        if getent group render >/dev/null 2>&1; then
            info "Adding fuze user to render group..."
            sudo usermod -a -G render fuze
        fi
        if getent group video >/dev/null 2>&1; then
            info "Adding fuze user to video group..."
            sudo usermod -a -G video fuze
        fi

        info "Adding current user to fuze group..."
        sudo usermod -a -G fuze $(whoami)

        info "Creating ollama systemd service..."
        local bindir="/usr/local/bin"
        cat <<EOF | sudo tee /etc/systemd/system/ollama.service >/dev/null
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
ExecStart=$bindir/ollama serve
User=fuze
Group=fuze
Restart=always
RestartSec=3
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_MODELS=/FuZe/ollama"
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"
Environment="LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu"
Environment="HOME=/home/fuze"

[Install]
WantedBy=default.target
EOF
        info "Enabling and starting ollama service..."
        sudo systemctl daemon-reload
        sudo systemctl enable ollama.service
        sudo systemctl restart ollama.service
        
        info "Manual installation from cache complete."
        return 0
    fi

    # --- Original Logic with Caching Post-Download ---
    info "Proceeding with official installer."
    if [ ! -f "$ollama_installer_path" ]; then
        info "Ollama installer script not found in cache. Downloading..."
        curl -fsSL "$ollama_installer_url" -o "$ollama_installer_path"
        chmod +x "$ollama_installer_path"
    else
        info "Using cached Ollama installer script from $ollama_installer_path"
    fi

    info "Executing Ollama installer script..."
    if ! sudo sh "$ollama_installer_path"; then
        error "Ollama installation failed."
        return 1
    fi

    if [ "$try_cache_flag" -eq 1 ]; then
        info "Caching new Ollama binary..."
        sudo cp "$ollama_system_binary_path" "$ollama_binary_cache_path"
    fi

    info "Ollama installation complete."
}

ok "Installation script finished"

# Test function is separate and not called by default
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
    
    # Install specified stacks (default to ollama if none specified)
    if [ ${#STACKS[@]} -eq 0 ]; then
        STACKS=(ollama)
    fi
    
    for stack in "${STACKS[@]}"; do
        case "$stack" in
            ollama)
                install_ollama "$@"
                ;;
            vllm)
                info "vLLM stack installation not yet implemented"
                ;;
            llama.cpp)
                info "llama.cpp stack installation not yet implemented"
                ;;
            triton)
                info "Triton stack installation not yet implemented"
                ;;
            *)
                error "Unknown stack: $stack"
                ;;
        esac
    done
    
    ok "Installation script finished"
}

# Run main function
main "$@"