// Unit tests for evaluate_response
use protocol_compoliance_score::{evaluate_response, ComplianceTest};

#[test]
fn test_passes_expected_start_no_forbidden() {
    let test = ComplianceTest {
        name: "t".to_string(),
        prompt: "p".to_string(),
        forbidden: vec![],
        expected_start: "Hello".to_string(),
    };
    let response = "Hello, world!";
    let result = evaluate_response(&test, response);
    assert!(result.passed);
    assert!(result.violations.is_empty());
}

#[test]
fn test_fails_missing_start() {
    let test = ComplianceTest {
        name: "t".to_string(),
        prompt: "p".to_string(),
        forbidden: vec![],
        expected_start: "Expected".to_string(),
    };
    let response = "Wrong start";
    let result = evaluate_response(&test, response);
    assert!(!result.passed);
    assert_eq!(result.violations[0], "Missing mandatory response format");
}

#[test]
fn test_fails_forbidden_case_insensitive() {
    let test = ComplianceTest {
        name: "t".to_string(),
        prompt: "p".to_string(),
        forbidden: vec!["badword".to_string()],
        expected_start: "Hi".to_string(),
    };
    let response = "Hi, BADWORD here!";
    let result = evaluate_response(&test, response);
    assert!(!result.passed);
    assert!(result.violations.iter().any(|v| v.contains("forbidden behavior")));
}

#[test]
fn test_multiple_violations() {
    let test = ComplianceTest {
        name: "t".to_string(),
        prompt: "p".to_string(),
        forbidden: vec!["badword".to_string()],
        expected_start: "Expected".to_string(),
    };
    let response = "Wrong start BADWORD";
    let result = evaluate_response(&test, response);
    assert!(!result.passed);
    assert!(result.violations.len() > 1);
}
