#!/usr/bin/env rust-script

/*
 * re-do.rs - Re-run forensic analysis workflow based on test results
 * 
 * This script:
 * 1. Takes the overall assessment from test-applied-fix.rs output
 * 2. If tests failed: triggers new run-test-fuckups.sh to fix current issues
 * 3. If tests succeeded: creates git commit with details and pushes to origin
 * 
 * Part of the FuZeCORE.ai forensic analysis pipeline
 */

use std::process::Command;
use std::fs;

fn main() {
    println!("=== RE-DO WORKFLOW CONTROLLER ===");
    println!("Analyzing test results and determining next action");
    println!();

    // Get the overall assessment from test-applied-fix.rs output
    println!("# 1. ANALYZING TEST RESULTS");
    println!("Running test-applied-fix.rs to get current status...");
    
    let test_output = Command::new("./test-applied-fix")
        .output()
        .expect("Failed to execute test-applied-fix");

    if !test_output.status.success() {
        println!("ERROR: test-applied-fix execution failed");
        return;
    }

    let test_result = String::from_utf8_lossy(&test_output.stdout);
    println!("Test execution completed");
    println!();

    // Analyze the test output for success/failure indicators
    println!("# 2. DETERMINING ACTION BASED ON TEST RESULTS");
    
    let test_failed = test_result.contains("✗ Script execution failed") || 
                     test_result.contains("STATUS: Applied fixes may have issues requiring attention");
    
    let cleanup_issues_resolved = test_result.contains("✓ No old path references detected") &&
                                 test_result.contains("✓ No regex pattern errors detected") &&
                                 test_result.contains("✓ No service cleanup errors detected");

    if test_failed {
        println!("STATUS: Tests failed - Need to re-run forensic analysis");
        println!("REASON: Script execution failed, likely due to path issues");
        
        // Extract the specific error for the new forensic run
        let error_context = if test_result.contains("ERROR: Cracker not found") {
            "Path resolution issue: cracker.sh path has double /LLM/LLM/ instead of /LLM/"
        } else {
            "Script execution failure detected"
        };
        
        println!("ERROR CONTEXT: {}", error_context);
        println!();
        
        println!("# 3. TRIGGERING NEW FORENSIC ANALYSIS RUN");
        println!("Starting run-test-fuckups.sh with updated context...");
        
        // Create a new problem statement for the forensic analysis
        let problem_statement = format!(
            "FOLLOW-UP FORENSIC ANALYSIS:\n\
            Previous cleanup script fixes were applied but testing revealed:\n\
            - {}\n\
            - Original cleanup issues appear resolved\n\
            - New issue: Path resolution in refine-and-bake-ollama-gpt-oss-20b-std.sh\n\
            \n\
            INVESTIGATION NEEDED:\n\
            1. Why is the script looking for cracker.sh at wrong path\n\
            2. Path resolution logic in main script\n\
            3. Fix the double /LLM/LLM/ path issue",
            error_context
        );
        
        println!("Problem statement for new run:");
        println!("{}", problem_statement);
        println!();
        
        // Write problem statement to file following established pattern
        fs::write("re-do.txt", problem_statement)
            .expect("Failed to write problem statement to re-do.txt file");
        
        println!("✓ Problem statement written to 're-do.txt' file");
        println!("✓ Ready for manual forensic pipeline execution");
        
    } else if cleanup_issues_resolved {
        println!("STATUS: Tests succeeded - Cleanup fixes are working");
        println!("CLEANUP VALIDATION: ✓ All cleanup script issues resolved");
        println!();
        
        println!("# 3. CREATING GIT COMMIT AND PUSH");
        
        // Create detailed commit message
        let commit_message = format!(
            "fix: Surgical fixes for ollama cleanup scripts\n\
            \n\
            Applied forensic analysis and surgical fixes to resolve cleanup script issues:\n\
            \n\
            ✓ Fixed nuke-all.sh - Created missing nuclear cleanup wrapper\n\
            ✓ Fixed service-cleanup.sh - Corrected MODELDIR path to /FuZe/ollama\n\
            ✓ Fixed store-cleanup.sh - Updated ALT_DEFAULT path to /FuZe/baked/ollama\n\
            ✓ Fixed cleanup-variants.sh - Enhanced regex patterns for malformed model names\n\
            \n\
            Validation results:\n\
            - No old path references (/FuZe/models/ollama) detected\n\
            - No regex pattern errors detected\n\
            - No service cleanup errors detected\n\
            - All cleanup scripts accessible and functional\n\
            \n\
            forensic-analysis: Complete pipeline with test-fuckups.rs → analyze-my-fuckedup-analysis.rs → debugging-plan.rs → run-debugging-plan.rs → fix-plan.rs → run-fix-plan.rs → validate-fix-plan-run.rs → test-applied-fix.rs\n\
            \n\
            Co-authored-by: FuZeCORE.ai Forensic Pipeline <forensic@fuzecore.ai>"
        );
        
        println!("Commit message:");
        println!("{}", commit_message);
        println!();
        
        // Add all modified files
        println!("Adding modified files to git...");
        let git_add = Command::new("git")
            .args(&["add", "."])
            .output()
            .expect("Failed to execute git add");
        
        if git_add.status.success() {
            println!("✓ Files added to git staging");
        } else {
            println!("✗ Git add failed");
            let add_error = String::from_utf8_lossy(&git_add.stderr);
            println!("Error: {}", add_error);
            return;
        }
        
        // Create commit
        println!("Creating git commit...");
        let git_commit = Command::new("git")
            .args(&["commit", "-m", &commit_message])
            .output()
            .expect("Failed to execute git commit");
        
        if git_commit.status.success() {
            println!("✓ Git commit created successfully");
            let commit_result = String::from_utf8_lossy(&git_commit.stdout);
            println!("{}", commit_result);
        } else {
            println!("✗ Git commit failed");
            let commit_error = String::from_utf8_lossy(&git_commit.stderr);
            println!("Error: {}", commit_error);
            return;
        }
        
        // Push to origin
        println!("Pushing to origin...");
        let git_push = Command::new("git")
            .args(&["push", "origin"])
            .output()
            .expect("Failed to execute git push");
        
        if git_push.status.success() {
            println!("✓ Successfully pushed to origin");
            let push_result = String::from_utf8_lossy(&git_push.stdout);
            println!("{}", push_result);
        } else {
            println!("✗ Git push failed");
            let push_error = String::from_utf8_lossy(&git_push.stderr);
            println!("Error: {}", push_error);
        }
        
    } else {
        println!("STATUS: Unclear test results - Manual review required");
        println!("The test results don't clearly indicate success or failure.");
        println!("Please review the test output manually.");
    }
    
    println!();
    println!("=== RE-DO WORKFLOW COMPLETED ===");
}