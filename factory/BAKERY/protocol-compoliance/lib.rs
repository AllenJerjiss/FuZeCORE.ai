// Main protocol compliance runner, refactored from generate_pcs.rs
pub fn run_protocol_compliance(args: &[String]) -> Result<(), String> {
    println!("=== PROTOCOL COMPLIANCE LIVE TESTER ===");
    let mut protocol_base = "COMMUNICATION_PROTOCOL".to_string();
    if args.len() > 2 && args[1] == "--protocol" {
        protocol_base = args[2].clone();
    }

    let md_path = format!("{}.md", protocol_base);
    let json_path = format!("{}.json", protocol_base);

    // Validate both files exist
    if std::fs::metadata(&md_path).is_err() {
        return Err(format!("ERROR: Missing protocol markdown file: {}", md_path));
    }
    if std::fs::metadata(&json_path).is_err() {
        return Err(format!("ERROR: Missing protocol JSON file: {}", json_path));
    }

    let protocol_content = std::fs::read_to_string(&md_path)
        .map_err(|e| format!("Failed to read protocol markdown file: {}", e))?;

    // Create HTTP client for LLM communication
    let client = reqwest::blocking::Client::new();

    // Step 1: Send protocol to LLM and instruct enforcement
    println!("Initializing protocol enforcement...");
    let init_prompt = format!("You must enforce the following protocol:\n{}", protocol_content);
    let _ = send_to_llm(&client, &init_prompt);
    println!("Protocol sent. Beginning compliance tests...\n");

    // Step 2: Run compliance tests
    let tests = build_compliance_tests(&json_path)?;
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
    Ok(())
}
// Standard library for file operations
use std::fs;
// Reqwest for HTTP client to communicate with LLM
use reqwest::blocking::Client;
// Serde for JSON parsing and serialization
use serde_json::Value;

pub const CHAT_ENDPOINT: &str = "http://localhost:8000/chat";

#[derive(Debug)]
pub struct ComplianceTest {
    pub name: String,
    pub prompt: String,
    pub forbidden: Vec<String>,
    pub expected_start: String,
}

#[derive(Debug, Clone)]
pub struct TestResult {
    pub passed: bool,
    pub violations: Vec<String>,
    pub response: String,
}

pub fn send_to_llm(client: &Client, prompt: &str) -> String {
    let payload = serde_json::json!({"prompt": prompt});
    let resp = client.post(CHAT_ENDPOINT)
        .json(&payload)
        .send();
    match resp {
        Ok(r) => {
            let v: Value = r.json().unwrap_or(Value::Null);
            v["response"].as_str().unwrap_or("").to_string()
        },
        Err(_) => "ERROR: Could not connect to chat endpoint".to_string(),
    }
}

pub fn build_compliance_tests(json_path: &str) -> Result<Vec<ComplianceTest>, String> {
    let json_content = fs::read_to_string(json_path)
        .map_err(|e| format!("Failed to read protocol JSON file: {}", e))?;
    let test_vec: serde_json::Value = serde_json::from_str(&json_content)
        .map_err(|e| format!("Invalid JSON format: {}", e))?;
    let mut tests = Vec::new();
    if let Some(arr) = test_vec.as_array() {
        for item in arr {
            let name = item["name"].as_str().unwrap_or("").to_string();
            let prompt = item["prompt"].as_str().unwrap_or("").to_string();
            let expected_start = item["expected_start"].as_str().unwrap_or("").to_string();
            let forbidden = item["forbidden"].as_array()
                .map(|fa| fa.iter().filter_map(|v| v.as_str().map(|s| s.to_string())).collect())
                .unwrap_or_else(Vec::new);
            tests.push(ComplianceTest {
                name,
                prompt,
                expected_start,
                forbidden,
            });
        }
    }
    Ok(tests)
}

pub fn evaluate_response(test: &ComplianceTest, response: &str) -> TestResult {
    let mut violations = Vec::new();
    let mut passed = true;
    if !response.starts_with(&test.expected_start) {
        violations.push("Missing mandatory response format".to_string());
        passed = false;
    }
    let response_lower = response.to_lowercase();
    for forbidden in &test.forbidden {
        if response_lower.contains(&forbidden.to_lowercase()) {
            violations.push(format!("Contains forbidden behavior: '{}'", forbidden));
            passed = false;
        }
    }
    TestResult {
        passed,
        violations,
        response: response.to_string(),
    }
}

pub fn print_compliance_score(results: &[TestResult]) {
    let total = results.len();
    let passed = results.iter().filter(|r| r.passed).count();
    let percent = (passed as f64 / total as f64) * 100.0;
    println!("=== PROTOCOL COMPLIANCE REPORT ===");
    println!("Total Tests: {}", total);
    println!("Passed: {}", passed);
    println!("Failed: {}", total - passed);
    println!("COMPLIANCE SCORE: {:.1}%", percent);
}
