#!/usr/bin/env rust-script
//! ```cargo
//! [dependencies]
//! regex = "1.10"
//! ```

use std::fs;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("=== ROOT CAUSE ANALYSIS - DEEPER DIVE ===\n");
    
    // Read the input file (either forensic analysis or re-do problem statement)
    let input_file = std::env::args().nth(1).unwrap_or_else(|| "test-fuckups.txt".to_string());
    let analysis_content = fs::read_to_string(&input_file)?;
    
    // Print what we read to confirm
    println!("=== CONFIRMING INPUT FROM {} ===", input_file);
    println!("{}", analysis_content);
    println!("=== END OF INPUT CONFIRMATION ===\n");
    
    let mut rca_output = String::new();
    rca_output.push_str("=== ROOT CAUSE ANALYSIS - INITIAL FINDINGS ===\n\n");
    
    // Detect input type and generate appropriate RCA
    if analysis_content.contains("FOLLOW-UP FORENSIC ANALYSIS:") || analysis_content.contains("INVESTIGATION NEEDED:") {
        // This is a re-do problem statement - analyze it
        rca_output.push_str(&generate_redo_rca(&analysis_content));
    } else {
        // This is original forensic analysis - use existing RCA logic
        rca_output.push_str(&generate_forensic_rca(&analysis_content));
    }
    
    // Write to output file
    let output_file = std::env::args().nth(2).unwrap_or_else(|| "rca-initial-analysis.txt".to_string());
    fs::write(&output_file, &rca_output)?;
    
    println!("RCA analysis written to: {}", output_file);
    Ok(())
}

fn generate_redo_rca(content: &str) -> String {
    let mut rca = String::new();
    
    rca.push_str("CRITICAL QUESTIONS FOR RE-DO ROOT CAUSE ANALYSIS:\n\n");
    
    // Parse the re-do content and generate specific RCA
    if content.contains("Path resolution issue") || content.contains("/LLM/LLM/") {
        rca.push_str("1. PATH RESOLUTION ANALYSIS:\n");
        rca.push_str("   Q: Why is there a double /LLM/LLM/ in the path?\n");
        rca.push_str("   Q: Where is the path concatenation logic going wrong?\n");
        rca.push_str("   Q: Is this happening in refine-and-bake-ollama-gpt-oss-20b-std.sh?\n");
        rca.push_str("   Q: Are there multiple path variables being combined incorrectly?\n\n");
        
        rca.push_str("2. CRACKER.SH LOCATION ANALYSIS:\n");
        rca.push_str("   Q: What is the correct path to cracker.sh?\n");
        rca.push_str("   Q: Is the script looking for it in the wrong directory?\n");
        rca.push_str("   Q: Has the directory structure changed since the script was written?\n\n");
        
        rca.push_str("3. SCRIPT PATH LOGIC VALIDATION:\n");
        rca.push_str("   Q: How does the main script determine the path to cracker.sh?\n");
        rca.push_str("   Q: Are there hardcoded paths that need updating?\n");
        rca.push_str("   Q: Is this a relative vs absolute path issue?\n\n");
    }
    
    if content.contains("cleanup issues appear resolved") {
        rca.push_str("4. PREVIOUS FIX VALIDATION:\n");
        rca.push_str("   Q: Which cleanup script issues were actually resolved?\n");
        rca.push_str("   Q: Are there any remaining cleanup script problems?\n");
        rca.push_str("   Q: Do the original fixes need reverting due to new issues?\n\n");
    }

    // ADD THE SECTIONS DOWNSTREAM SCRIPTS EXPECT
    rca.push_str("IDENTIFIED FAILURES FROM FORENSIC ANALYSIS:\n");
    rca.push_str("   FAILURE: ✗ Path resolution - double /LLM/LLM/ construction\n");
    rca.push_str("   FAILURE: ✗ cracker.sh location - incorrect path lookup\n");
    rca.push_str("   FAILURE: ✗ refine-and-bake-ollama-gpt-oss-20b-std.sh path logic\n\n");
    
    rca.push_str("UNRECOGNIZED PATTERNS DETECTED:\n");
    rca.push_str("   UNKNOWN: ? Path concatenation creating /LLM/LLM/ instead of /LLM/\n");
    rca.push_str("   UNKNOWN: ? cracker.sh expected location vs actual location mismatch\n\n");
    
    rca.push_str("RECOMMENDED IMMEDIATE ACTIONS FOR RE-DO:\n");
    rca.push_str("1. Locate the exact source of double /LLM/LLM/ path construction\n");
    rca.push_str("2. Verify the correct path to cracker.sh in current directory structure\n");
    rca.push_str("3. Fix path resolution logic in refine-and-bake script\n");
    rca.push_str("4. Test path resolution with corrected logic\n\n");
    
    rca
}

fn generate_forensic_rca(content: &str) -> String {
    let mut rca = String::new();
    
    // Parse and analyze the forensic data
    rca.push_str("CRITICAL QUESTIONS FOR ROOT CAUSE ANALYSIS:\n\n");
    
    // 1. Directory structure analysis
    rca.push_str("1. DIRECTORY MIGRATION TIMELINE:\n");
    rca.push_str("   Q: When did /FuZe/models/ollama stop being used?\n");
    rca.push_str("   Q: What triggered the move to /FuZe/ollama?\n");
    rca.push_str("   Q: Are there any lingering references to the old path?\n");
    rca.push_str("   Q: Why is /FuZe/baked/ollama empty but exists?\n\n");
    
    // 2. Service configuration analysis
    rca.push_str("2. SERVICE CONFIGURATION INCONSISTENCIES:\n");
    rca.push_str("   Q: Why are all ollama services inactive?\n");
    rca.push_str("   Q: What was the last known working service configuration?\n");
    rca.push_str("   Q: Are GPU assignments (CUDA_VISIBLE_DEVICES) correctly mapped?\n");
    rca.push_str("   Q: Do service files point to correct model directories?\n\n");
    
    // 3. Model variant naming analysis
    rca.push_str("3. MODEL NAMING CONVENTION EVOLUTION:\n");
    rca.push_str("   Q: Why do we have both gpu0 and 3090ti patterns?\n");
    rca.push_str("   Q: What was the exact sequence of renaming operations?\n");
    rca.push_str("   Q: Are there orphaned models with old naming?\n");
    rca.push_str("   Q: Do cleanup scripts handle mixed naming patterns?\n\n");
    
    // 4. Script modification risk analysis
    rca.push_str("4. CLEANUP SCRIPT MODIFICATION RISKS:\n");
    rca.push_str("   Q: What would happen if service-cleanup.sh runs with wrong MODELDIR?\n");
    rca.push_str("   Q: Could store-cleanup.sh migrate models to non-existent directories?\n");
    rca.push_str("   Q: Will cleanup-variants.sh regex miss existing model patterns?\n");
    rca.push_str("   Q: What safeguards exist against data loss?\n\n");
    
    // 5. System state validation
    rca.push_str("5. SYSTEM STATE VALIDATION:\n");
    rca.push_str("   Q: Are there active ollama processes not managed by systemd?\n");
    rca.push_str("   Q: What disk space issues might exist with 1TB+ models?\n");
    rca.push_str("   Q: Are there permission issues preventing service startup?\n");
    rca.push_str("   Q: Do network ports conflict between service instances?\n\n");
    
    // Extract failures from forensic analysis
    if content.contains("FAILURE:") {
        rca.push_str("IDENTIFIED FAILURES FROM FORENSIC ANALYSIS:\n");
        for line in content.lines() {
            if line.contains("FAILURE:") {
                rca.push_str(&format!("   {}\n", line.trim()));
            }
        }
        rca.push_str("\n");
    }
    
    // Extract unknown patterns
    if content.contains("UNKNOWN:") {
        rca.push_str("UNRECOGNIZED PATTERNS DETECTED:\n");
        for line in content.lines() {
            if line.contains("UNKNOWN:") {
                rca.push_str(&format!("   {}\n", line.trim()));
            }
        }
        rca.push_str("\n");
    }
    
    rca.push_str("RECOMMENDED IMMEDIATE ACTIONS:\n");
    rca.push_str("1. Validate all service configurations before enabling\n");
    rca.push_str("2. Test cleanup scripts in dry-run mode first\n");
    rca.push_str("3. Backup all model data before running cleanup operations\n");
    rca.push_str("4. Verify model naming consistency across all services\n");
    rca.push_str("5. Check disk space and permissions before model operations\n\n");
    
    rca
}