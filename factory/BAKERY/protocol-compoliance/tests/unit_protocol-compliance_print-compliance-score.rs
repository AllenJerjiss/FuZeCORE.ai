// Unit tests for print_compliance_score
use protocol_compoliance_score::{print_compliance_score, TestResult};

#[test]
fn test_all_passed() {
    let results = vec![TestResult { passed: true, violations: vec![], response: "r".to_string() }; 3];
    print_compliance_score(&results);
}

#[test]
fn test_all_failed() {
    let results = vec![TestResult { passed: false, violations: vec!["v".to_string()], response: "r".to_string() }; 3];
    print_compliance_score(&results);
}

#[test]
fn test_mixed_results() {
    let results = vec![
        TestResult { passed: true, violations: vec![], response: "r".to_string() },
        TestResult { passed: false, violations: vec!["v".to_string()], response: "r".to_string() },
    ];
    print_compliance_score(&results);
}

#[test]
fn test_empty_results() {
    let results: Vec<TestResult> = vec![];
    print_compliance_score(&results);
}
