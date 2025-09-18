#!/usr/bin/env rust-script

/*
 * validate-fix-plan-run.rs - Validation script for surgical fix execution
 * 
 * Validates that surgical fixes were correctly applied by:
 * 1. Running git diff to see what actually changed
 * 2. Checking each intended fix against actual changes
 * 3. Validating file contents match expected state
 * 4. Identifying any missing or incorrect changes
 * 
 * Part of the FuZeCORE.ai forensic analysis pipeline
 */

use std::process::Command;

fn main() {
    println!("=== SURGICAL FIX VALIDATION ===");
    println!("Validating that surgical fixes were correctly applied");
    println!();

    // Get git diff to see what actually changed
    println!("# 1. GIT DIFF ANALYSIS");
    println!("Getting current git diff to analyze actual changes...");
    
    let git_diff_output = Command::new("git")
        .args(&["diff"])
        .output()
        .expect("Failed to execute git diff");

    if git_diff_output.status.success() {
        let diff_content = String::from_utf8_lossy(&git_diff_output.stdout);
        println!("Git diff output:");
        println!("{}", diff_content);
        
        if diff_content.trim().is_empty() {
            println!("WARNING: No git diff found - either no changes made or all changes already committed");
        }
    } else {
        println!("ERROR: Git diff failed");
        let error = String::from_utf8_lossy(&git_diff_output.stderr);
        println!("Error: {}", error);
    }

    println!();
    println!("# 2. INTENDED FIX VALIDATION");
    println!("Checking each intended fix against actual changes...");
    println!();

    // Validate Fix 1: Missing nuke-all.sh nuclear cleanup wrapper
    println!("## FIX 1 VALIDATION: Missing nuke-all.sh nuclear cleanup wrapper");
    let nuke_all_path = "/home/fuze/GitHub/FuZeCORE.ai/factory/LLM/refinery/stack/ollama/nuke-all.sh";
    
    match std::fs::metadata(nuke_all_path) {
        Ok(metadata) => {
            if metadata.is_file() {
                println!("✓ nuke-all.sh exists");
                
                // Check if executable
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    let perms = metadata.permissions();
                    if perms.mode() & 0o111 != 0 {
                        println!("✓ nuke-all.sh is executable");
                    } else {
                        println!("✗ nuke-all.sh is not executable");
                    }
                }
                
                // Validate content contains expected elements
                match std::fs::read_to_string(nuke_all_path) {
                    Ok(content) => {
                        let required_elements = vec![
                            "Nuclear cleanup wrapper for ollama",
                            "systemctl stop ollama.service",
                            "pkill -f ollama",
                            "rm -rf /FuZe/ollama/manifests/*",
                            "rm -rf /FuZe/ollama/blobs/*",
                            "rm -rf /FuZe/baked/ollama/*"
                        ];
                        
                        for element in required_elements {
                            if content.contains(element) {
                                println!("✓ Contains: {}", element);
                            } else {
                                println!("✗ Missing: {}", element);
                            }
                        }
                    }
                    Err(e) => println!("✗ Could not read nuke-all.sh content: {}", e)
                }
            } else {
                println!("✗ nuke-all.sh exists but is not a file");
            }
        }
        Err(_) => println!("✗ nuke-all.sh does not exist")
    }
    
    println!();

    // Validate Fix 2: service-cleanup.sh MODELDIR path configuration
    println!("## FIX 2 VALIDATION: service-cleanup.sh missing MODELDIR path configuration");
    let service_cleanup_path = "/home/fuze/GitHub/FuZeCORE.ai/factory/LLM/refinery/stack/ollama/service-cleanup.sh";
    
    match std::fs::read_to_string(service_cleanup_path) {
        Ok(content) => {
            if content.contains("MODELDIR=\"/FuZe/ollama\"") {
                println!("✓ MODELDIR correctly set to /FuZe/ollama");
            } else if content.contains("MODELDIR=") {
                println!("✗ MODELDIR exists but not set to /FuZe/ollama");
                // Find what it's actually set to
                for line in content.lines() {
                    if line.contains("MODELDIR=") {
                        println!("  Current value: {}", line.trim());
                    }
                }
            } else {
                println!("✗ MODELDIR not found in service-cleanup.sh");
            }
            
            // Check for old path references
            if content.contains("/FuZe/models/ollama") {
                println!("✗ Still contains old path /FuZe/models/ollama");
            } else {
                println!("✓ No old path references found");
            }
        }
        Err(e) => println!("✗ Could not read service-cleanup.sh: {}", e)
    }
    
    println!();

    // Validate Fix 3: store-cleanup.sh CANON/ALT_DEFAULT paths
    println!("## FIX 3 VALIDATION: store-cleanup.sh missing CANON/ALT_DEFAULT paths");
    let store_cleanup_path = "/home/fuze/GitHub/FuZeCORE.ai/factory/LLM/refinery/stack/ollama/store-cleanup.sh";
    
    match std::fs::read_to_string(store_cleanup_path) {
        Ok(content) => {
            let expected_paths = vec![
                ("CANON_DEFAULT", "/FuZe/ollama"),
                ("ALT_DEFAULT", "/FuZe/baked/ollama")
            ];
            
            for (var_name, expected_path) in expected_paths {
                let expected_line = format!("{}=\"{}\"", var_name, expected_path);
                if content.contains(&expected_line) {
                    println!("✓ {} correctly set to {}", var_name, expected_path);
                } else {
                    println!("✗ {} not correctly set", var_name);
                    // Find what it's actually set to
                    for line in content.lines() {
                        if line.contains(&format!("{}=", var_name)) {
                            println!("  Current value: {}", line.trim());
                        }
                    }
                }
            }
            
            // Check for old path references
            if content.contains("/FuZe/models/ollama") {
                println!("✗ Still contains old path /FuZe/models/ollama");
            } else {
                println!("✓ No old path references found");
            }
        }
        Err(e) => println!("✗ Could not read store-cleanup.sh: {}", e)
    }
    
    println!();

    // Validate Fix 4 & 5: cleanup-variants.sh regex patterns
    println!("## FIX 4&5 VALIDATION: cleanup-variants.sh regex patterns for malformed names");
    let cleanup_variants_path = "/home/fuze/GitHub/FuZeCORE.ai/factory/LLM/refinery/stack/ollama/cleanup-variants.sh";
    
    match std::fs::read_to_string(cleanup_variants_path) {
        Ok(content) => {
            let expected_patterns = vec![
                ("MATCH_RE", "^LLM-FuZe-.*"),
                ("MALFORMED_RE", "^LLM-FuZe-LLM-FuZe-.*"),
                ("GPU_PATTERN_RE", "(gpu[0-9]+|[0-9]+ti|[0-9]+|3090ti|5090)")
            ];
            
            for (var_name, expected_pattern) in expected_patterns {
                let expected_line = format!("{}=\"{}\"", var_name, expected_pattern);
                if content.contains(&expected_line) {
                    println!("✓ {} correctly set to {}", var_name, expected_pattern);
                } else {
                    println!("✗ {} not correctly set", var_name);
                    // Find what it's actually set to
                    for line in content.lines() {
                        if line.contains(&format!("{}=", var_name)) {
                            println!("  Current value: {}", line.trim());
                        }
                    }
                }
            }
        }
        Err(e) => println!("✗ Could not read cleanup-variants.sh: {}", e)
    }
    
    println!();

    // Final validation summary
    println!("# 3. FINAL VALIDATION SUMMARY");
    println!("Checking overall git status...");
    
    let git_status_output = Command::new("git")
        .args(&["status", "--porcelain"])
        .output()
        .expect("Failed to execute git status");

    if git_status_output.status.success() {
        let status_content = String::from_utf8_lossy(&git_status_output.stdout);
        println!("Git status output:");
        println!("{}", status_content);
        
        if status_content.trim().is_empty() {
            println!("STATUS: No uncommitted changes detected");
        } else {
            println!("STATUS: Uncommitted changes detected - ready for commit");
        }
    } else {
        println!("ERROR: Git status failed");
    }

    println!();
    println!("=== SURGICAL FIX VALIDATION COMPLETED ===");
}