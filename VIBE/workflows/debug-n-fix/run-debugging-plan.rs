#!/usr/bin/env rust-script
//! ```cargo
//! [dependencies]
//! ```

use std::process::Command;
use std::fs;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("=== DEBUGGING PLAN EXECUTOR ===\n");
    
    let script_path = std::env::args().nth(1).unwrap_or_else(|| "debugging-commands.sh".to_string());
    
    // Check if the script file exists
    if !fs::metadata(&script_path).is_ok() {
        eprintln!("Error: {} not found!", script_path);
        eprintln!("Run the debugging-plan.rs script first to generate the debugging commands.");
        return Ok(());
    }
    
    // Check if the file is executable
    let metadata = fs::metadata(&script_path)?;
    let permissions = metadata.permissions();
    
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if permissions.mode() & 0o111 == 0 {
            eprintln!("Warning: {} is not executable!", script_path);
            eprintln!("Making it executable...");
            Command::new("chmod")
                .arg("+x")
                .arg(&script_path)
                .output()?;
        }
    }
    
    println!("Executing {}...\n", script_path);
    
    // Execute the debugging script
    let output = Command::new(format!("./{}", script_path))
        .output()?;
    
    // Print stdout
    if !output.stdout.is_empty() {
        print!("{}", String::from_utf8_lossy(&output.stdout));
    }
    
    // Print stderr if there are errors
    if !output.stderr.is_empty() {
        eprintln!("STDERR:\n{}", String::from_utf8_lossy(&output.stderr));
    }
    
    // Check exit status
    if output.status.success() {
        println!("\n=== DEBUGGING PLAN EXECUTION COMPLETED ===");
    } else {
        eprintln!("\n=== DEBUGGING PLAN EXECUTION FAILED ===");
        eprintln!("Exit code: {:?}", output.status.code());
    }
    
    Ok(())
}