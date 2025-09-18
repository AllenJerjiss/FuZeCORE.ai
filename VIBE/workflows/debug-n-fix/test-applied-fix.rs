#!/usr/bin/env rust-script

/*
 * test-applied-fix.rs - Test script for applied surgical fixes
 * 
 * Tests that surgical fixes work correctly by:
 * 1. Running refine-and-bake-ollama-gpt-oss-20b-std.sh with updated cleanup scripts
 * 2. Monitoring execution for errors related to cleanup functionality
 * 3. Validating that cleanup scripts execute without path/regex issues
 * 4. Capturing full execution output for analysis
 * 
 * Part of the FuZeCORE.ai forensic analysis pipeline
 */

use std::process::Command;
use std::path::Path;

fn main() {
    println!("=== APPLIED FIX TESTING ===");
    println!("Testing surgical fixes by running refine-and-bake-ollama-gpt-oss-20b-std.sh");
    println!();

    // Verify the script exists in the new location
    let mut script_path = "/home/fuze/GitHub/FuZeCORE.ai/factory/LLM/refinery/refine-and-bake-ollama-gpt-oss-20b-std.sh";
    
    if !Path::new(script_path).exists() {
        println!("ERROR: Script not found at expected location: {}", script_path);
        println!("Checking for script in alternative locations...");
        
        let alternative_paths = vec![
            "/home/fuze/GitHub/FuZeCORE.ai/factory/refine-and-bake-ollama-gpt-oss-20b-std.sh",
            "/home/fuze/GitHub/FuZeCORE.ai/factory/LLM/refine-and-bake-ollama-gpt-oss-20b-std.sh",
            "/home/fuze/GitHub/FuZeCORE.ai/refine-and-bake-ollama-gpt-oss-20b-std.sh"
        ];
        
        let mut found = false;
        for alt_path in alternative_paths {
            if Path::new(alt_path).exists() {
                println!("Found script at: {}", alt_path);
                script_path = alt_path;
                found = true;
                break;
            }
        }
        
        if !found {
            println!("Script not found in any expected location. Exiting.");
            return;
        }
    }

    println!("# 1. PRE-EXECUTION VALIDATION");
    println!("Verifying cleanup scripts are accessible...");
    
    let cleanup_scripts = vec![
        "/home/fuze/GitHub/FuZeCORE.ai/factory/LLM/refinery/stack/ollama/service-cleanup.sh",
        "/home/fuze/GitHub/FuZeCORE.ai/factory/LLM/refinery/stack/ollama/store-cleanup.sh", 
        "/home/fuze/GitHub/FuZeCORE.ai/factory/LLM/refinery/stack/ollama/cleanup-variants.sh",
        "/home/fuze/GitHub/FuZeCORE.ai/factory/LLM/refinery/stack/ollama/nuke-all.sh"
    ];
    
    for script in &cleanup_scripts {
        if Path::new(script).exists() {
            println!("✓ Found: {}", script);
        } else {
            println!("✗ Missing: {}", script);
        }
    }
    
    println!();

    // Check current working directory and change to appropriate location
    println!("# 2. EXECUTION ENVIRONMENT SETUP");
    let target_dir = "/home/fuze/GitHub/FuZeCORE.ai/factory/LLM";
    println!("Changing to target directory: {}", target_dir);
    
    if !Path::new(target_dir).exists() {
        println!("ERROR: Target directory does not exist: {}", target_dir);
        return;
    }
    
    println!("✓ Target directory exists");
    println!();

    // Execute the script and capture output
    println!("# 3. SCRIPT EXECUTION TEST");
    println!("Executing: {}", script_path);
    println!("Working directory: {}", target_dir);
    println!("Starting execution...");
    println!();
    
    let output = Command::new("bash")
        .arg(script_path)
        .current_dir(target_dir)
        .output();

    match output {
        Ok(result) => {
            println!("# 4. EXECUTION RESULTS");
            println!("Exit code: {}", result.status.code().unwrap_or(-1));
            println!();
            
            println!("## STDOUT OUTPUT:");
            let stdout = String::from_utf8_lossy(&result.stdout);
            println!("{}", stdout);
            
            println!();
            println!("## STDERR OUTPUT:");
            let stderr = String::from_utf8_lossy(&result.stderr);
            println!("{}", stderr);
            
            // Analyze output for cleanup-related issues
            println!();
            println!("# 5. CLEANUP ANALYSIS");
            println!("Analyzing output for cleanup script issues...");
            
            let combined_output = format!("{}{}", stdout, stderr);
            
            // Check for path-related errors
            if combined_output.contains("/FuZe/models/ollama") {
                println!("⚠ WARNING: Old path /FuZe/models/ollama still referenced");
            } else {
                println!("✓ No old path references detected");
            }
            
            // Check for regex/pattern errors
            if combined_output.contains("MATCH_RE") || combined_output.contains("MALFORMED_RE") {
                println!("⚠ WARNING: Regex pattern issues detected");
            } else {
                println!("✓ No regex pattern errors detected");
            }
            
            // Check for service errors
            if combined_output.contains("service-cleanup") && combined_output.contains("error") {
                println!("⚠ WARNING: Service cleanup errors detected");
            } else {
                println!("✓ No service cleanup errors detected");
            }
            
            // Check for successful completion indicators
            if combined_output.contains("✔") || combined_output.contains("done") {
                println!("✓ Execution appears to have completed steps successfully");
            } else {
                println!("⚠ WARNING: No clear success indicators found");
            }
            
            // Overall assessment
            println!();
            println!("# 6. OVERALL ASSESSMENT");
            if result.status.success() {
                println!("✓ Script executed without fatal errors");
                println!("STATUS: Applied fixes appear to be working");
            } else {
                println!("✗ Script execution failed");
                println!("STATUS: Applied fixes may have issues requiring attention");
            }
            
        }
        Err(e) => {
            println!("ERROR: Failed to execute script");
            println!("Error: {}", e);
            println!("STATUS: Cannot test applied fixes due to execution failure");
        }
    }
    
    println!();
    println!("=== APPLIED FIX TESTING COMPLETED ===");
}