// Import compliance test logic and types from shared library
use protocol_compoliance_score::{build_compliance_tests, evaluate_response, ComplianceTest};

#[test]
fn test_build_compliance_tests_valid_json() {
    let json_path = "COMMUNICATION_PROTOCOL.json";
    let tests = build_compliance_tests(json_path);
    assert!(!tests.is_empty(), "Should parse at least one test from JSON");
}

#[test]
fn test_evaluate_response_passes_expected_start() {
    let test = ComplianceTest {
        name: "Test Start".to_string(),
        prompt: "Prompt".to_string(),
        forbidden: vec!["forbidden".to_string()],
        expected_start: "Hello".to_string(),
    };
    let response = "Hello, world!";
    let result = evaluate_response(&test, response);
    assert!(result.passed, "Should pass when response starts with expected_start");
    assert!(result.violations.is_empty(), "No violations expected");
}

#[test]
fn test_evaluate_response_fails_forbidden() {
    let test = ComplianceTest {
        name: "Test Forbidden".to_string(),
        prompt: "Prompt".to_string(),
        forbidden: vec!["badword".to_string()],
        expected_start: "Hi".to_string(),
    };
    let response = "Hi, this contains badword!";
    let result = evaluate_response(&test, response);
    assert!(!result.passed, "Should fail when response contains forbidden word");
    assert!(!result.violations.is_empty(), "Violations expected");
}

#[test]
fn test_evaluate_response_fails_missing_start() {
    let test = ComplianceTest {
        name: "Test Missing Start".to_string(),
        prompt: "Prompt".to_string(),
        forbidden: vec![],
        expected_start: "Expected".to_string(),
    };
    let response = "Wrong start";
    let result = evaluate_response(&test, response);
    assert!(!result.passed, "Should fail when response does not start with expected_start");
    assert!(!result.violations.is_empty(), "Violations expected");
}
