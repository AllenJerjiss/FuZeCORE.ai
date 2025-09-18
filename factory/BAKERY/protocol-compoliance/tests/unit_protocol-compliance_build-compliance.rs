// Unit tests for build_compliance_tests
use protocol_compoliance_score::build_compliance_tests;
use std::fs::File;
use std::io::Write;

#[test]
fn test_valid_json() {
    let json_path = "test_valid.json";
    let mut file = File::create(json_path).unwrap();
    let json = r#"[{"name":"t1","prompt":"p1","expected_start":"e1","forbidden":[]}]
"#;
    file.write_all(json.as_bytes()).unwrap();
    let tests = build_compliance_tests(json_path).unwrap();
    assert_eq!(tests.len(), 1);
    std::fs::remove_file(json_path).unwrap();
}

#[test]
fn test_invalid_json() {
    let json_path = "test_invalid.json";
    let mut file = File::create(json_path).unwrap();
    file.write_all(b"not a json").unwrap();
    let result = build_compliance_tests(json_path);
    assert!(result.is_err(), "Should return error for invalid JSON");
    std::fs::remove_file(json_path).unwrap();
}

#[test]
fn test_empty_array() {
    let json_path = "test_empty.json";
    let mut file = File::create(json_path).unwrap();
    file.write_all(b"[]").unwrap();
    let tests = build_compliance_tests(json_path).unwrap();
    assert!(tests.is_empty());
    std::fs::remove_file(json_path).unwrap();
}

#[test]
fn test_missing_fields() {
    let json_path = "test_missing.json";
    let mut file = File::create(json_path).unwrap();
    let json = r#"[{"prompt":"p1"}]"#;
    file.write_all(json.as_bytes()).unwrap();
    let tests = build_compliance_tests(json_path).unwrap();
    assert_eq!(tests[0].name, "");
    std::fs::remove_file(json_path).unwrap();
}

#[test]
fn test_forbidden_non_array() {
    let json_path = "test_forbidden_non_array.json";
    let mut file = File::create(json_path).unwrap();
    let json = r#"[{"name":"t1","prompt":"p1","expected_start":"e1","forbidden":null}]"#;
    file.write_all(json.as_bytes()).unwrap();
    let tests = build_compliance_tests(json_path).unwrap();
    assert_eq!(tests[0].forbidden.len(), 0);
    std::fs::remove_file(json_path).unwrap();
}
