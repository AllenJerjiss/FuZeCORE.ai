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

# Main execution entry point

install_ollama() {
    info "Installing Ollama stack..."
    
    # Check if root is needed for Ollama installation
    if [ "$(id -u)" -ne 0 ]; then
        error "Ollama installation requires root privileges (use sudo)"
        exit 1
    fi
    
    # Smart detection: skip if already installed and no upgrade requested
    if command -v ollama >/dev/null 2>&1 && [ "$UPGRADE" -eq 0 ]; then
        ok "Ollama already installed (use --upgrade to force update)"
        info "Current version: $(ollama --version 2>/dev/null || echo 'unknown')"
        return 0
    fi
    
    # Install required packages first (if not dry run)
    if [ "$DRY_RUN" -eq 1 ]; then
        info "DRY RUN: Would install packages: curl jq lsof gawk sed procps coreutils rsync"
    else
        apt-get update -y
        apt-get install -y curl jq lsof gawk sed procps coreutils rsync
    fi
    
    # Determine how to get the Ollama binary
    local cached_binary="$CACHE_DIR/ollama"
    local use_cached=0
    
    if [ "$TRY_CACHE" -eq 1 ] && [ "$UPGRADE" -eq 0 ] && [ -f "$cached_binary" ] && [ -x "$cached_binary" ]; then
        info "Found cached Ollama binary: $cached_binary"
        use_cached=1
    else
        if [ "$TRY_CACHE" -eq 1 ] && [ "$UPGRADE" -eq 0 ]; then
            info "No cached Ollama binary found, falling back to download"
        elif [ "$UPGRADE" -eq 1 ]; then
            info "Upgrade requested, downloading fresh Ollama binary"
        else
            info "Downloading Ollama binary"
        fi
        use_cached=0
    fi
    
    # Download and cache binary if needed
    if [ "$use_cached" -eq 0 ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            info "DRY RUN: Would download Ollama binary to cache: $cached_binary"
        else
            # Create cache directory
            mkdir -p "$CACHE_DIR"
            
            # Download binary (detect architecture)
            local arch
            case "$(uname -m)" in
                x86_64) arch="amd64" ;;
                aarch64) arch="arm64" ;;
                armv7l) arch="arm" ;;
                *) error "Unsupported architecture: $(uname -m)"; exit 1 ;;
            esac
            
            local os="$(uname -s | tr '[:upper:]' '[:lower:]')"
            local download_url="https://ollama.com/download/ollama-${os}-${arch}"
            
            info "Downloading Ollama binary from: $download_url"
            if curl -fsSL "$download_url" -o "$cached_binary"; then
                chmod +x "$cached_binary"
                ok "Downloaded and cached Ollama binary: $cached_binary"
            else
                error "Failed to download Ollama binary"
                exit 1
            fi
        fi
    fi
    
    # Install binary from cache
    if [ "$DRY_RUN" -eq 1 ]; then
        if [ "$use_cached" -eq 1 ]; then
            info "DRY RUN: Would install from cached binary: $cached_binary -> /usr/local/bin/ollama"
        else
            info "DRY RUN: Would install from downloaded binary: $cached_binary -> /usr/local/bin/ollama"
        fi
    else
        cp "$cached_binary" /usr/local/bin/ollama
        chmod +x /usr/local/bin/ollama
        ok "Installed Ollama binary to /usr/local/bin/ollama"
    fi
    
    # Rest of Ollama-specific setup (from original ollama/install.sh)
    if [ "$DRY_RUN" -eq 1 ]; then
        info "DRY RUN: Would setup ollama user and groups"
        info "DRY RUN: Would create /FuZe/models/ollama directory"
        info "DRY RUN: Would stop all ollama services"
        info "DRY RUN: Would remove custom ollama units"
        info "DRY RUN: Would configure stock ollama.service"
        info "DRY RUN: Would start ollama.service"
    else
        # Ensure ollama user exists
        if ! id -u ollama >/dev/null 2>&1; then
            useradd -r -s /usr/sbin/nologin -m ollama
        fi
        for g in video render; do
            getent group "$g" >/dev/null 2>&1 && usermod -aG "$g" ollama || true
        done
        
        # Setup FuZe model directory
        local canon="/FuZe/models/ollama"
        mkdir -p /FuZe /FuZe/models "$canon"
        chmod 755 /FuZe /FuZe/models "$canon"
        chown -R ollama:ollama "$canon"
        [ -e /FuZe/ollama ] || ln -s "$canon" /FuZe/ollama || true
        
        # Stop ALL ollama* services (stock & custom)
        info "Stopping ALL ollama* services"
        systemctl list-unit-files | awk '/^ollama.*\.service/ {print $1}' | while read -r u; do
            systemctl unmask "$u" 2>/dev/null || true
            systemctl stop "$u" 2>/dev/null || true
            systemctl disable "$u" 2>/dev/null || true
            systemctl reset-failed "$u" 2>/dev/null || true
        done
        
        # Remove custom/legacy units (keep ONLY stock ollama.service)
        info "Removing custom/legacy ollama units"
        local units_to_remove
        units_to_remove="$(systemctl list-unit-files --type=service | \
          awk '/^ollama.*\.service/ && $1!="ollama.service" {print $1}' || true)"
          
        local unit_dirs="/etc/systemd/system /lib/systemd/system /usr/lib/systemd/system"
        for u in $units_to_remove; do
            for d in $unit_dirs; do
                rm -f "$d/$u" 2>/dev/null || true
                rm -rf "$d/${u}.d" 2>/dev/null || true
            done
            find /etc/systemd/system -type l -lname "*$u" -print -delete 2>/dev/null || true
        done
        
        # Remove common custom units
        rm -f /etc/systemd/system/ollama-persist.service \
              /etc/systemd/system/ollama-test-*.service 2>/dev/null || true
        rm -rf /etc/systemd/system/ollama-persist.service.d \
               /etc/systemd/system/ollama-test-*.service.d 2>/dev/null || true
        find /etc/systemd/system -maxdepth 1 -type f -name 'ollama-*.service' -print -delete 2>/dev/null || true
        find /etc/systemd/system -maxdepth 1 -type d -name 'ollama-*.service.d' -print -exec rm -rf {} + 2>/dev/null || true
        
        # Kill stray ollama daemons
        info "Killing stray ollama daemons"
        local main_pid
        main_pid="$(systemctl show -p MainPID --value ollama.service 2>/dev/null || true)"
        pgrep -f "/usr/local/bin/ollama serve" >/dev/null 2>&1 && \
          pgrep -f "/usr/local/bin/ollama serve" | while read -r pid; do
            if [ -n "${main_pid:-}" ] && [ "$pid" = "$main_pid" ]; then
                continue
            fi
            kill -TERM "$pid" 2>/dev/null || true
          done
        sleep 1
        pgrep -f "/usr/local/bin/ollama serve" >/dev/null 2>&1 && \
          pgrep -f "/usr/local/bin/ollama serve" | while read -r pid; do
            if [ -n "${main_pid:-}" ] && [ "$pid" = "$main_pid" ]; then
                continue
            fi
            kill -KILL "$pid" 2>/dev/null || true
          done
          
        # Configure stock ollama.service
        info "Configuring stock ollama.service"
        mkdir -p /etc/systemd/system/ollama.service.d
        cat >/etc/systemd/system/ollama.service.d/override.conf <<'DROPIN'
[Service]
User=ollama
Group=ollama
SupplementaryGroups=video render
Environment=OLLAMA_MODELS=/FuZe/models/ollama
# ExecStart provided by package; defaults to port 11434
DROPIN
        
        # Start ollama service
        systemctl daemon-reload
        systemctl unmask ollama.service 2>/dev/null || true
        systemctl enable --now ollama.service
        
        # Final cleanup of stray listeners
        for p in 11435 11436; do
            local pid
            pid="$(lsof -nP -iTCP:$p -sTCP:LISTEN -t 2>/dev/null || true)"
            [ -n "${pid:-}" ] && kill -TERM "$pid" 2>/dev/null || true
        done
    fi
    
    ok "Ollama installation completed"
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
                install_ollama
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
    
    run_tests
    show_usage_info
}

# Run main function
main "$@"