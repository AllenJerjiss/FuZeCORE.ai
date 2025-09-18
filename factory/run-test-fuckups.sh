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

# Install net-tools on ubuntu for tools such as netstat:
sudo apt install -y net-tools

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

# Print the RCA analysis output
echo "=== RCA ANALYSIS OUTPUT ==="
cat "$RUN_DIR/rca-initial-analysis.txt"
echo "=== END OF RCA ANALYSIS ==="

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

# Print the debugging execution output
echo "=== DEBUGGING EXECUTION OUTPUT ==="
cat "$RUN_DIR/debugging-commands.txt"
echo "=== END OF DEBUGGING EXECUTION ==="

# Pause before fix plan generation
echo "Debugging execution complete. Press Enter to continue with surgical fix plan generation..."
read

# Run the fix plan generator with all context
rust-script fix-plan.rs "$RUN_DIR/rca-initial-analysis.txt" "$RUN_DIR/debugging-commands.txt" "$RUN_DIR/surgical-fix-plan.sh"

# Print the fix plan output
echo "=== SURGICAL FIX PLAN OUTPUT ==="
cat "$RUN_DIR/surgical-fix-plan.sh"
echo "=== END OF SURGICAL FIX PLAN ==="

# Pause before fix execution
echo "Fix plan generation complete. Press Enter to continue with surgical fix execution..."
read

# Run the fix plan executor
echo "=== SURGICAL FIX EXECUTION ==="
rust-script run-fix-plan.rs "$RUN_DIR/surgical-fix-plan.sh" > "$RUN_DIR/fix-execution.txt"

# Print the fix execution output
echo "=== SURGICAL FIX EXECUTION OUTPUT ==="
cat "$RUN_DIR/fix-execution.txt"
echo "=== END OF SURGICAL FIX EXECUTION ==="