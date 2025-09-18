#!/bin/bash

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
    rust-script test-fuckups.rs > "$RUN_DIR/test-fuckups.txt"
    
    # Print the file contents before pause
    echo "=== FORENSIC ANALYSIS OUTPUT ==="
    cat "$RUN_DIR/test-fuckups.txt"
    echo "=== END OF FORENSIC ANALYSIS ==="
fi

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

# Pause before validation
echo "Surgical fix execution complete. Press Enter to continue with validation..."
read

# Run the validation script
echo "=== VALIDATION ==="
rust-script validate-fix-plan-run.rs > "$RUN_DIR/validate-fix-plan-run"
chmod +x "$RUN_DIR/validate-fix-plan-run"

# Pause before testing
echo "Validation complete. Press Enter to continue with testing..."
read

# Run the testing script
echo "=== TESTING APPLIED FIXES ==="
rust-script test-applied-fix.rs > "$RUN_DIR/test-applied-fix"
chmod +x "$RUN_DIR/test-applied-fix"

# Run re-do workflow controller to determine next action
echo "=== RE-DO WORKFLOW ANALYSIS ==="
rust-script re-do.rs > "$RUN_DIR/re-do-analysis.txt"

# Check if re-do.txt was generated (indicating test failure)
if [[ -f "re-do.txt" ]]; then
    mv "re-do.txt" "$RUN_DIR/re-do.txt"
    echo ""
    echo "=========================================="
    echo "❌ FIX VALIDATION FAILED"
    echo "=========================================="
    echo "The applied fixes did not resolve all issues."
    echo "A new problem statement has been generated."
    echo ""
    echo "To continue with automated forensic analysis:"
    echo "  ./run-test-fuckups.sh --re-do"
    echo ""
    echo "Problem statement saved to: $RUN_DIR/re-do.txt"
    echo "=========================================="
else
    echo ""
    echo "=========================================="
    echo "✅ WORKFLOW COMPLETED SUCCESSFULLY"
    echo "=========================================="
    echo "All fixes have been validated and applied."
    echo "Changes have been committed and pushed."
    echo "=========================================="
fi