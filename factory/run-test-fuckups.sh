#!/bin/bash

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

# Create unique run directory with timestamp
RUN_DIR=".run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
echo "Created run directory: $RUN_DIR"

# Run the forensic analysis script
rust-script test-fuckups.rs > "$RUN_DIR/test-fuckups.txt"

# Print the file contents before pause
echo "=== FORENSIC ANALYSIS OUTPUT ==="
cat "$RUN_DIR/test-fuckups.txt"
echo "=== END OF FORENSIC ANALYSIS ==="

# Pause and ask for input before proceeding
echo "Forensic analysis complete. Press Enter to continue with RCA analysis..."
read

# Run the deeper RCA analysis
rust-script analyze-my-fuckedup-analysis.rs "$RUN_DIR/test-fuckups.txt" "$RUN_DIR/rca-initial-analysis.txt"

# Pause before debugging plan
echo "RCA analysis complete. Press Enter to continue with debugging plan generation..."
read

# Run the debugging plan generator
rust-script debugging-plan.rs "$RUN_DIR/rca-initial-analysis.txt" "$RUN_DIR/debugging-commands.sh"

# Pause before debugging plan execution
echo "Debugging plan generated. Press Enter to execute debugging commands..."
read

# Run the debugging plan executor  
rust-script run-debugging-plan.rs "$RUN_DIR/debugging-commands.sh" > "$RUN_DIR/debugging-commands.txt"