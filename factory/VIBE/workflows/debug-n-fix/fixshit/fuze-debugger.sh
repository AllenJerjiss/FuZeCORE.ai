#!/bin/bash
set -e

# Parse command line arguments
RE_DO_MODE=false
if [[ "$1" == "--re-do" ]]; then
    RE_DO_MODE=true
    echo "RE-DO MODE: Looking for re-do.txt in latest .run folder"
fi

# Install cargo if not already installed
sudo apt update && sudo apt install -y cargo

# Install rust-script
cargo install rust-script

# Check if /home/fuze/.cargo/bin is in PATH
if echo "$PATH" | grep -q "/home/fuze/.cargo/bin"; then
    echo "/home/fuze/.cargo/bin is in PATH"
else
    echo "/home/fuze/.cargo/bin is NOT in PATH - adding permanently"
    # Add to .bashrc if not already there
    if ! grep -q "/home/fuze/.cargo/bin" ~/.bashrc; then
        echo 'export PATH="$PATH:/home/fuze/.cargo/bin"' >> ~/.bashrc
        echo "Added PATH export to ~/.bashrc"
    fi
    # Source .bashrc and export for current session
    source ~/.bashrc
    export PATH="$PATH:/home/fuze/.cargo/bin"
    echo "PATH updated for current session"
fi

# Install net-tools on ubuntu for tools such as netstat:
sudo apt install -y net-tools

# Handle --re-do mode: find and move re-do.txt from latest .run folder
if [[ "$RE_DO_MODE" == "true" ]]; then
    LATEST_RUN=$(ls -1d .run-* 2>/dev/null | sort | tail -1)
    if [[ -z "$LATEST_RUN" ]]; then
        echo "ERROR: No .run folders found for --re-do mode"
        exit 1
    fi
    
    REDO_FILE="$LATEST_RUN/re-do.txt"
    if [[ ! -f "$REDO_FILE" ]]; then
        echo "ERROR: re-do.txt not found in latest run folder: $LATEST_RUN"
        exit 1
    fi
    
    echo "Found re-do.txt in: $LATEST_RUN"
fi

# Create unique run directory with timestamp
RUN_DIR=".run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
echo "Created run directory: $RUN_DIR"

# Move re-do.txt to new run directory if in --re-do mode
if [[ "$RE_DO_MODE" == "true" ]]; then
    mv "$REDO_FILE" "$RUN_DIR/re-do.txt"
    echo "Moved re-do.txt to: $RUN_DIR/re-do.txt"
    echo "Starting forensic analysis with re-do context..."
    # Use the re-do.txt content as the problem statement
    echo "=== RE-DO PROBLEM STATEMENT ==="
    cat "$RUN_DIR/re-do.txt"
    echo "=== END OF RE-DO PROBLEM STATEMENT ==="
else
    # Run the forensic analysis script
    rust-script start_debugging.rs > "$RUN_DIR/test-fuckups.txt"
    
    # Print the file contents before pause
    echo "=== FORENSIC ANALYSIS OUTPUT ==="
    cat "$RUN_DIR/test-fuckups.txt"
    echo "=== END OF FORENSIC ANALYSIS ==="
fi