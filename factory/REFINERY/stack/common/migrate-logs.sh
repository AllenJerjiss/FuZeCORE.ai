#!/usr/bin/env bash
# migrate-logs.sh — Move historical logs into /var/log/fuze-stack and backfill symlinks
# - Consolidates logs from repo paths to a single system path
# - Safe to run multiple times

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Configuration
DEST="${LOG_DIR:-/var/log/fuze-stack}"
DRY_RUN=0
BACKUP=1
FORCE=0

# Source directories to migrate from
STACK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FUZE_ROOT="$(cd "$STACK_DIR/.." && pwd)"

SRC_DIRS=(
    "$STACK_DIR/logs"
    "$FUZE_ROOT/logs"
)

usage() {
    cat <<USAGE
Usage: $(basename "$0") [--dry-run] [--no-backup] [--force] [--dest DIR] [--help]

Options:
  --dry-run     Show what would be done without making changes
  --no-backup   Don't create backup copies before moving files
  --force       Overwrite existing files in destination
  --dest DIR    Destination directory (default: $DEST)
  --help        Show this help message

This script requires root privileges to write to system log directories.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --no-backup) BACKUP=0; shift ;;
        --force) FORCE=1; shift ;;
        --dest) DEST="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) error_exit "Unknown argument: $1" ;;
    esac
done

show_dry_run_status

# Define root operations for validation
ROOT_OPERATIONS=(
    "Create system log directory: $DEST"
    "Move log files from repository paths to system location"
    "Create symlinks from old paths to new location"
    "Set appropriate ownership and permissions"
)

# Require root with operation preview
if [ "$DRY_RUN" -eq 0 ]; then
    require_root "${ROOT_OPERATIONS[@]}"
fi

# Main migration logic
main() {
    info "Starting log migration to: $DEST"
    
    # Create destination directory
    if [ "$DRY_RUN" -eq 1 ]; then
        info "DRY RUN: Would create directory: $DEST"
    else
        mkdir -p "$DEST" || error_exit "Failed to create destination directory: $DEST"
    fi
    
    local total_moved=0
    
    for src in "${SRC_DIRS[@]}"; do
        total_moved=$((total_moved + $(migrate_from_dir "$src")))
    done
    
    info ""
    info "Migration complete: moved $total_moved files to $DEST"
}

migrate_from_dir() {
    local src="$1"
    [ -d "$src" ] || { debug "Source directory does not exist: $src"; echo 0; return; }
    
    info "Processing source: $src"
    
    shopt -s nullglob
    local files=("$src"/*)
    shopt -u nullglob
    
    if [ ${#files[@]} -eq 0 ]; then
        info "  (no files found)"
        echo 0
        return
    fi
    
    local moved=0
    for file in "${files[@]}"; do
        [ -f "$file" ] || continue
        
        local base dest
        base="$(basename "$file")"
        dest="$DEST/$base"
        
        # Handle existing files
        if [ -e "$dest" ]; then
            if [ "$FORCE" -eq 1 ]; then
                warn "  Overwriting existing file: $base"
            else
                # Avoid overwrite by prefixing timestamp
                local ts
                ts="$(date +%Y%m%d_%H%M%S)"
                dest="$DEST/${ts}_$base"
                info "  File exists, using timestamped name: $(basename "$dest")"
            fi
        fi
        
        # Create backup if requested
        if [ "$BACKUP" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
            local backup="$file.backup.$(date +%s)"
            cp "$file" "$backup" || warn "Failed to create backup: $backup"
            debug "  Created backup: $(basename "$backup")"
        fi
        
        # Move the file
        if [ "$DRY_RUN" -eq 1 ]; then
            info "  DRY RUN: Would move $base -> $(basename "$dest")"
        else
            mv "$file" "$dest" || error_exit "Failed to move file: $file -> $dest"
            info "  Moved: $base -> $(basename "$dest")"
        fi
        
        moved=$((moved + 1))
    done
    
    # Remove source directory if empty and create symlink
    if [ "$DRY_RUN" -eq 1 ]; then
        info "  DRY RUN: Would remove empty directory and create symlink: $src -> $DEST"
    else
        rmdir "$src" 2>/dev/null || debug "Directory not empty or removal failed: $src"
        if [ ! -e "$src" ]; then
            ln -sf "$DEST" "$src" || warn "Failed to create symlink: $src -> $DEST"
            info "  Created symlink: $src -> $DEST"
        fi
    fi
    
    echo "$moved"
}

# Run main function if script is executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi

