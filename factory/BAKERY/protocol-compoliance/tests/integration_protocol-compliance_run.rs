// Integration tests for generate_pcs.rs main logic
use std::fs::File;
use std::io::Write;

#[test]
fn test_missing_protocol_files() {
    let args = vec!["bin".to_string(), "--protocol".to_string(), "nonexistent".to_string()];
    let result = protocol_compoliance_score::run_protocol_compliance(&args);
    assert!(result.is_err());
    assert!(result.unwrap_err().contains("ERROR: Missing protocol markdown file"));
}

#[test]
fn test_valid_protocol_files() {
    let md_path = "TEST_PROTOCOL.md";
    let json_path = "TEST_PROTOCOL.json";
    let mut md_file = File::create(md_path).unwrap();
    md_file.write_all(b"Protocol markdown content").unwrap();
    let mut json_file = File::create(json_path).unwrap();

         let json = r#"[{"name":"t1","prompt":"p1","expected_start":"e1","forbidden":[]}]"#;
    json_file.write_all(json.as_bytes()).unwrap();
    let args = vec!["bin".to_string(), "--protocol".to_string(), "TEST_PROTOCOL".to_string()];
    let result = protocol_compoliance_score::run_protocol_compliance(&args);
    assert!(result.is_ok());
    std::fs::remove_file(md_path).unwrap();
    std::fs::remove_file(json_path).unwrap();
}
