#!/usr/bin/env rust-script
//! ```cargo
//! [dependencies]
//! ```

use std::fs;
use std::process::Command;
use std::path::Path;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("=== DEBUGGING PLAN GENERATOR ===\n");
    
    // Get input and output file paths
    let rca_file = std::env::args().nth(1).unwrap_or_else(|| {
        eprintln!("ERROR: Missing RCA analysis file argument");
        eprintln!("Usage: debugging-plan.rs <rca-file> [output-file]");
        std::process::exit(1);
    });
    
    // Check if input file exists
    if !Path::new(&rca_file).exists() {
        eprintln!("ERROR: RCA analysis file not found: {}", rca_file);
        std::process::exit(1);
    }
    
    // Read the RCA analysis content
    let rca_content = fs::read_to_string(&rca_file)?;
    
    // Print what we read to confirm
    println!("=== CONFIRMING INPUT FROM {} ===", rca_file);
    println!("{}", rca_content);
    println!("=== END OF INPUT CONFIRMATION ===\n");
    
    let mut commands = String::new();
    commands.push_str("#!/bin/bash\n");
    commands.push_str("# Auto-generated debugging commands from RCA analysis\n\n");
    commands.push_str("echo \"=== DEBUGGING COMMANDS TO GATHER EVIDENCE ===\"\n\n");
    
    // 1. Directory migration timeline commands
    commands.push_str("echo \"# 1. DIRECTORY MIGRATION TIMELINE EVIDENCE:\"\n");
    commands.push_str("echo \"# Check filesystem timestamps and modification dates\"\n");
    commands.push_str("stat /FuZe/ollama\n");
    commands.push_str("stat /FuZe/baked/ollama\n");
    commands.push_str("ls -la /FuZe/ | grep ollama\n");
    commands.push_str("find /FuZe -name \"*ollama*\" -type d -exec stat {} \\;\n");
    commands.push_str("echo \"# Check for old path references in configs\"\n");
    commands.push_str("grep -r \"/FuZe/models/ollama\" /etc/systemd/system/ 2>/dev/null || echo \"No old path refs in systemd\"\n");
    commands.push_str("grep -r \"/FuZe/models/ollama\" /home/fuze/ 2>/dev/null | head -10 || echo \"No old path refs in home\"\n");
    commands.push_str("echo\n");
    
    // 2. Service configuration investigation
    commands.push_str("echo \"# 2. SERVICE CONFIGURATION INVESTIGATION:\"\n");
    commands.push_str("echo \"# Check service files and their current state\"\n");
    commands.push_str("systemctl cat ollama.service\n");
    commands.push_str("systemctl cat ollama-test-a.service\n");
    commands.push_str("systemctl cat ollama-test-b.service\n");
    commands.push_str("systemctl cat ollama-test-multi.service\n");
    commands.push_str("systemctl cat ollama-persist.service\n");
    commands.push_str("echo \"# Check service logs for errors\"\n");
    commands.push_str("journalctl -u ollama.service --since \"1 hour ago\" --no-pager | tail -20\n");
    commands.push_str("journalctl -u ollama-test-a.service --since \"1 hour ago\" --no-pager | tail -20\n");
    commands.push_str("echo \"# Check what's preventing service startup\"\n");
    commands.push_str("systemctl status ollama.service\n");
    commands.push_str("systemctl status ollama-test-a.service\n");
    commands.push_str("echo\n");
    
    // 3. GPU and hardware validation
    commands.push_str("# 3. GPU AND HARDWARE VALIDATION:\n");
    commands.push_str("# Verify actual GPU hardware vs service configs\n");
    commands.push_str("nvidia-smi --list-gpus\n");
    commands.push_str("nvidia-smi --query-gpu=index,name,uuid --format=csv,noheader\n");
    commands.push_str("# Check current CUDA_VISIBLE_DEVICES settings\n");
    commands.push_str("env | grep CUDA\n");
    commands.push_str("# Verify GPU accessibility\n");
    commands.push_str("nvidia-smi\n");
    commands.push_str("\n");
    
    // 4. Model variant analysis
    commands.push_str("# 4. MODEL VARIANT DETAILED ANALYSIS:\n");
    commands.push_str("# List all model manifests with timestamps\n");
    commands.push_str("ls -la /FuZe/ollama/manifests/\n");
    commands.push_str("# Check model sizes and disk usage\n");
    commands.push_str("du -sh /FuZe/ollama/blobs/*\n");
    commands.push_str("# Analyze model naming patterns in detail\n");
    commands.push_str("find /FuZe/ollama/manifests -name \"*LLM-FuZe*\" -exec basename {} \\; | sort\n");
    commands.push_str("find /FuZe/ollama/manifests -name \"*gpu0*\" -exec basename {} \\;\n");
    commands.push_str("find /FuZe/ollama/manifests -name \"*3090ti*\" -exec basename {} \\;\n");
    commands.push_str("\n");
    
    // 5. Process and network analysis
    commands.push_str("# 5. PROCESS AND NETWORK ANALYSIS:\n");
    commands.push_str("# Check for running ollama processes\n");
    commands.push_str("ps aux | grep ollama\n");
    commands.push_str("pgrep -f ollama\n");
    commands.push_str("# Check network port usage\n");
    commands.push_str("netstat -tlnp | grep :11434\n");
    commands.push_str("ss -tlnp | grep ollama\n");
    commands.push_str("lsof -i :11434 2>/dev/null || echo \"Port 11434 not in use\"\n");
    commands.push_str("\n");
    
    // 6. Disk space and permissions
    commands.push_str("# 6. DISK SPACE AND PERMISSIONS ANALYSIS:\n");
    commands.push_str("# Check disk space issues\n");
    commands.push_str("df -h /FuZe\n");
    commands.push_str("du -sh /FuZe/ollama\n");
    commands.push_str("# Check permissions on critical paths\n");
    commands.push_str("ls -ld /FuZe/ollama\n");
    commands.push_str("ls -ld /FuZe/ollama/manifests\n");
    commands.push_str("ls -ld /FuZe/ollama/blobs\n");
    commands.push_str("# Check who owns the ollama directories\n");
    commands.push_str("stat -c '%U:%G %n' /FuZe/ollama\n");
    commands.push_str("stat -c '%U:%G %n' /FuZe/ollama/manifests\n");
    commands.push_str("\n");
    
    // 7. Configuration file analysis
    commands.push_str("# 7. CONFIGURATION FILE ANALYSIS:\n");
    commands.push_str("# Look for ollama config files\n");
    commands.push_str("find /etc -name \"*ollama*\" 2>/dev/null\n");
    commands.push_str("find /home/fuze -name \"*ollama*\" 2>/dev/null | head -10\n");
    commands.push_str("# Check environment files\n");
    commands.push_str("ls -la /home/fuze/GitHub/FuZeCORE.ai/factory/LLM/refinery/stack/env/\n");
    commands.push_str("find /home/fuze/GitHub/FuZeCORE.ai -name \"*.env*\" | head -10\n");
    commands.push_str("\n");
    
    commands.push_str("echo \"=== END OF DEBUGGING COMMANDS ===\"\n");
    commands.push_str("echo \"# Run this script to execute all debugging commands\"\n");
    commands.push_str("echo \"# Each command provides evidence to answer the RCA questions\"\n");
    
    // Write the commands to .sh file
    let output_file = std::env::args().nth(2).unwrap_or_else(|| "debugging-commands.sh".to_string());
    fs::write(&output_file, &commands)?;
    
    // Make the file executable
    Command::new("chmod")
        .arg("+x")
        .arg(&output_file)
        .output()?;
    
    println!("Debugging commands written to {} (executable)", output_file);
    print!("{}", commands);
    
    Ok(())
}