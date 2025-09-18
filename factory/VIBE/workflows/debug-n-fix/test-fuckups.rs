#!/usr/bin/env rust-script
//! ```cargo
//! [dependencies]
//! serde_json = "1.0"
//! walkdir = "2.0"
//! regex = "1.0"
//! ```

use std::fs;
use std::path::Path;
use std::process::Command;
use walkdir::WalkDir;
use regex::Regex;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("=== FORENSIC ANALYSIS OF MY FUCKUPS ===\n");

    // 1. Analyze directory structure
    println!("1. ANALYZING /FuZe DIRECTORY STRUCTURE:");
    analyze_fuze_directory_structure();
    println!();

    // 2. Analyze systemd services  
    println!("2. ANALYZING SYSTEMD SERVICES:");
    analyze_systemd_services();
    println!();

    // 3. Analyze existing model variants
    println!("3. ANALYZING EXISTING MODEL VARIANTS:");
    analyze_existing_variants();
    println!();

    // 4. Validate assumptions
    println!("4. VALIDATING MY ASSUMPTIONS:");
    validate_my_assumptions();
    println!();

    // 5. Analyze script modifications
    println!("5. ANALYZING MY SCRIPT MODIFICATIONS:");
    analyze_script_modifications();
    println!();

    println!("=== CONCLUSION ===");
    println!("This analysis shows what state the system is actually in");
    println!("vs what I assumed when making changes.");

    Ok(())
}

fn analyze_fuze_directory_structure() {
    println!("1. ANALYZING /FuZe DIRECTORY STRUCTURE:");
    
    let paths_to_check = vec![
        "/FuZe",
        "/FuZe/ollama", 
        "/FuZe/models",
        "/FuZe/models/ollama",
        "/FuZe/ollama/models",
        "/FuZe/baked",
        "/FuZe/baked/ollama"
    ];
    
    for path in paths_to_check {
        if Path::new(path).exists() {
            match fs::metadata(path) {
                Ok(metadata) => {
                    if metadata.is_dir() {
                        let size = get_dir_size(path);
                        println!("   ✓ {} (dir, ~{})", path, format_size(size));
                        
                        // Show key files in ollama dirs
                        if path.contains("ollama") {
                            show_ollama_structure(path);
                        }
                    } else {
                        println!("   ✓ {} (file)", path);
                    }
                }
                Err(e) => println!("   ✗ {} (error: {})", path, e),
            }
        } else {
            println!("   ✗ {} (missing)", path);
        }
    }
    println!();
}

fn show_ollama_structure(base_path: &str) {
    let important_subdirs = vec!["manifests", "blobs", "models"];
    for subdir in important_subdirs {
        let full_path = format!("{}/{}", base_path, subdir);
        if Path::new(&full_path).exists() {
            let size = get_dir_size(&full_path);
            let file_count = count_files(&full_path);
            println!("     - {}: {} files, ~{}", subdir, file_count, format_size(size));
        }
    }
}

fn get_dir_size(path: &str) -> u64 {
    WalkDir::new(path)
        .into_iter()
        .filter_map(|entry| entry.ok())
        .filter_map(|entry| entry.metadata().ok())
        .filter(|metadata| metadata.is_file())
        .fold(0, |acc, metadata| acc + metadata.len())
}

fn count_files(path: &str) -> usize {
    WalkDir::new(path)
        .into_iter()
        .filter_map(|entry| entry.ok())
        .filter(|entry| entry.file_type().is_file())
        .count()
}

fn format_size(bytes: u64) -> String {
    if bytes < 1024 { format!("{}B", bytes) }
    else if bytes < 1024 * 1024 { format!("{:.1}KB", bytes as f64 / 1024.0) }
    else if bytes < 1024 * 1024 * 1024 { format!("{:.1}MB", bytes as f64 / (1024.0 * 1024.0)) }
    else { format!("{:.1}GB", bytes as f64 / (1024.0 * 1024.0 * 1024.0)) }
}

fn analyze_systemd_services() {
    println!("2. ANALYZING SYSTEMD SERVICES:");
    
    let services = vec![
        "ollama.service",
        "ollama-persist.service", 
        "ollama-test-a.service",
        "ollama-test-b.service",
        "ollama-test-multi.service"
    ];
    
    for service in services {
        let status = Command::new("systemctl")
            .args(&["is-active", service])
            .output();
            
        let env_check = Command::new("systemctl")
            .args(&["show", service, "--property=Environment"])
            .output();
            
        match status {
            Ok(output) => {
                let status_str = String::from_utf8_lossy(&output.stdout).trim().to_string();
                print!("   {} -> {}", service, status_str);
                
                if let Ok(env_output) = env_check {
                    let env_str = String::from_utf8_lossy(&env_output.stdout);
                    if env_str.contains("OLLAMA_MODELS") {
                        if let Some(models_path) = extract_ollama_models_path(&env_str) {
                            print!(" (models: {})", models_path);
                        }
                    }
                    if env_str.contains("CUDA_VISIBLE_DEVICES") {
                        if let Some(cuda_devices) = extract_cuda_devices(&env_str) {
                            print!(" (GPU: {})", cuda_devices);
                        }
                    }
                }
                println!();
            }
            Err(e) => println!("   {} -> error: {}", service, e),
        }
    }
    println!();
}

fn extract_ollama_models_path(env_str: &str) -> Option<String> {
    let re = Regex::new(r"OLLAMA_MODELS=([^\s]+)").ok()?;
    re.captures(env_str)?.get(1).map(|m| m.as_str().to_string())
}

fn extract_cuda_devices(env_str: &str) -> Option<String> {
    let re = Regex::new(r"CUDA_VISIBLE_DEVICES=([^\s]+)").ok()?;
    re.captures(env_str)?.get(1).map(|m| m.as_str().to_string())
}

fn analyze_existing_variants() {
    println!("3. ANALYZING EXISTING MODEL VARIANTS:");
    
    // Check for LLM-FuZe variants in common locations
    let search_paths = vec![
        "/FuZe/ollama/manifests",
        "/FuZe/models/ollama/manifests",
        "/FuZe/baked/ollama"
    ];
    
    let mut total_variants = 0;
    let mut nvidia_pattern_variants = 0;
    let mut model_pattern_variants = 0;
    
    // Regex patterns I'm testing
    let nvidia_regex = Regex::new(r"^LLM-FuZe-.*-nvidia-[^-]+(\+[^-]+)*-ng[0-9]+").unwrap();
    let model_regex = Regex::new(r"^LLM-FuZe-.*-[0-9]+[a-z]*(\+[0-9]+[a-z]*)*-ng[0-9]+").unwrap();
    
    for search_path in search_paths {
        if !Path::new(search_path).exists() {
            println!("   {} (missing)", search_path);
            continue;
        }
        
        println!("   Searching {}:", search_path);
        let mut found_any = false;
        
        for entry in WalkDir::new(search_path).into_iter().filter_map(|e| e.ok()) {
            if let Some(name) = entry.file_name().to_str() {
                if name.starts_with("LLM-FuZe-") {
                    found_any = true;
                    total_variants += 1;
                    
                    if nvidia_regex.is_match(name) {
                        nvidia_pattern_variants += 1;
                        println!("     ✓ nvidia pattern: {}", name);
                    } else if model_regex.is_match(name) {
                        model_pattern_variants += 1;
                        println!("     ✓ model pattern: {}", name);
                    } else {
                        println!("     ? unknown pattern: {}", name);
                    }
                }
            }
        }
        
        if !found_any {
            println!("     (no LLM-FuZe variants found)");
        }
    }
    
    println!("   SUMMARY: {} total variants", total_variants);
    println!("            {} match nvidia-* pattern", nvidia_pattern_variants);
    println!("            {} match model pattern (3090ti, etc)", model_pattern_variants);
    println!();
}

fn validate_my_assumptions() {
    println!("4. VALIDATING MY ASSUMPTIONS:");
    
    // Assumption 1: Current model dir is /FuZe/ollama
    let assumption1 = Path::new("/FuZe/ollama").exists() && 
                     get_dir_size("/FuZe/ollama") > get_dir_size("/FuZe/models/ollama");
    println!("   Assumption 1 (current model dir is /FuZe/ollama): {}", 
             if assumption1 { "✓ LIKELY CORRECT" } else { "✗ LIKELY WRONG" });
    
    // Assumption 2: GPU naming uses model names not nvidia-*
    let model_variants = count_variants_matching(r"^LLM-FuZe-.*-[0-9]+[a-z]*-ng[0-9]+");
    let nvidia_variants = count_variants_matching(r"^LLM-FuZe-.*-nvidia-[^-]+-ng[0-9]+");
    
    let assumption2 = model_variants > nvidia_variants;
    println!("   Assumption 2 (GPU names are 3090ti not nvidia-3090ti): {}", 
             if assumption2 { "✓ LIKELY CORRECT" } else { "✗ LIKELY WRONG" });
    
    // Assumption 3: /FuZe/models/ollama is old location
    let assumption3 = !Path::new("/FuZe/models/ollama").exists() || 
                     get_dir_size("/FuZe/models/ollama") < get_dir_size("/FuZe/ollama");
    println!("   Assumption 3 (/FuZe/models/ollama is old location): {}", 
             if assumption3 { "✓ LIKELY CORRECT" } else { "✗ LIKELY WRONG" });
    
    println!();
}

fn count_variants_matching(pattern: &str) -> usize {
    let regex = Regex::new(pattern).unwrap();
    let search_paths = vec!["/FuZe/ollama", "/FuZe/models/ollama", "/FuZe/baked"];
    
    let mut count = 0;
    for search_path in search_paths {
        if Path::new(search_path).exists() {
            for entry in WalkDir::new(search_path).into_iter().filter_map(|e| e.ok()) {
                if let Some(name) = entry.file_name().to_str() {
                    if regex.is_match(name) {
                        count += 1;
                    }
                }
            }
        }
    }
    count
}

fn analyze_script_modifications() {
    println!("5. ANALYZING MY SCRIPT MODIFICATIONS:");
    
    let scripts = vec![
        ("service-cleanup.sh", "MODELDIR path"),
        ("store-cleanup.sh", "CANON/ALT_DEFAULT paths"), 
        ("cleanup-variants.sh", "MATCH_RE regex pattern"),
        ("nuke-all.sh", "NEW FILE - nuclear cleanup wrapper")
    ];
    
    for (script, change) in scripts {
        let script_path = format!("factory/LLM/refinery/stack/ollama/{}", script);
        if Path::new(&script_path).exists() {
            println!("   ✓ {} -> {}", script, change);
        } else {
            println!("   ✗ {} -> {} (MISSING!)", script, change);
        }
    }
    
    println!();
    println!("   RISK ASSESSMENT:");
    println!("   - service-cleanup.sh: Could point to wrong model directory");
    println!("   - store-cleanup.sh: Could migrate models in wrong direction");
    println!("   - cleanup-variants.sh: Regex might not match existing variants");
    println!("   - nuke-all.sh: Untested nuclear option - could destroy everything");
}