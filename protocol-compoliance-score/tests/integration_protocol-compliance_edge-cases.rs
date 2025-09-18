// Integration tests for protocol compliance edge cases
use std::fs::File;
use std::io::Write;

#[test]
fn test_malformed_json_file() {
    let md_path = "EDGE_PROTOCOL.md";
    let json_path = "EDGE_PROTOCOL.json";
    let mut md_file = File::create(md_path).unwrap();
    md_file.write_all(b"Protocol markdown content").unwrap();
    let mut json_file = File::create(json_path).unwrap();
    json_file.write_all(b"not a json").unwrap();
    let args = vec!["bin".to_string(), "--protocol".to_string(), "EDGE_PROTOCOL".to_string()];
    let result = protocol_compoliance_score::run_protocol_compliance(&args);
    assert!(result.is_err());
    let err = result.unwrap_err();
    assert!(err.contains("Invalid JSON format") || err.contains("Failed to read protocol JSON file"));
    std::fs::remove_file(md_path).unwrap();
    std::fs::remove_file(json_path).unwrap();
}

#[test]
fn test_json_missing_fields() {
    let md_path = "EDGE_PROTOCOL2.md";
    let json_path = "EDGE_PROTOCOL2.json";
    let mut md_file = File::create(md_path).unwrap();
    md_file.write_all(b"Protocol markdown content").unwrap();
    let mut json_file = File::create(json_path).unwrap();
    let json = r#"[{"prompt":"p1"}]"#;
    json_file.write_all(json.as_bytes()).unwrap();
    let args = vec!["bin".to_string(), "--protocol".to_string(), "EDGE_PROTOCOL2".to_string()];
    let result = protocol_compoliance_score::run_protocol_compliance(&args);
    assert!(result.is_ok());
    std::fs::remove_file(md_path).unwrap();
    std::fs::remove_file(json_path).unwrap();
}
