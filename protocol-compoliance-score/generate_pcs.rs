// Standard library for environment and file handling
use std::env;

// Import all protocol compliance logic from shared library
use protocol_compoliance_score::*;

fn main() {
    let args: Vec<String> = env::args().collect();
    if let Err(e) = protocol_compoliance_score::run_protocol_compliance(&args) {
        eprintln!("{}", e);
        std::process::exit(1);
    }
}

pub fn run_protocol_compliance(args: &[String]) {
    println!("=== PROTOCOL COMPLIANCE LIVE TESTER ===");
    let mut protocol_base = "COMMUNICATION_PROTOCOL".to_string();
    if args.len() > 2 && args[1] == "--protocol" {
        protocol_base = args[2].clone();
    }

    let md_path = format!("{}.md", protocol_base);
    let json_path = format!("{}.json", protocol_base);

    // Validate both files exist
    if std::fs::metadata(&md_path).is_err() {
        eprintln!("ERROR: Missing protocol markdown file: {}", md_path);
        std::process::exit(1);
    }
    if std::fs::metadata(&json_path).is_err() {
        eprintln!("ERROR: Missing protocol JSON file: {}", json_path);
        std::process::exit(1);
    }

    let protocol_content = std::fs::read_to_string(&md_path)
        .expect("Failed to read protocol markdown file");

    // Create HTTP client for LLM communication
    let client = reqwest::blocking::Client::new();

    // Step 1: Send protocol to LLM and instruct enforcement
    println!("Initializing protocol enforcement...");
    let init_prompt = format!("You must enforce the following protocol:\n{}", protocol_content);
    let _ = send_to_llm(&client, &init_prompt);
    println!("Protocol sent. Beginning compliance tests...\n");

    // Step 2: Run compliance tests
    let tests = build_compliance_tests(&json_path);
    let mut results = Vec::new();
    for test in &tests {
        println!("Test: {}", test.name);
        let response = send_to_llm(&client, &test.prompt);
        let result = evaluate_response(test, &response);
        println!("Result: {}", if result.passed { "PASS" } else { "FAIL" });
        if !result.violations.is_empty() {
            println!("Violations:");
            for v in &result.violations {
                println!("  - {}", v);
            }
        }
        println!("AI Response: {}\n", result.response);
        results.push(result);
    }
    print_compliance_score(&results);
}

