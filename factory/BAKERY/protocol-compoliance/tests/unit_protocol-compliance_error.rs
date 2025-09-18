// Unit tests for error branches in lib.rs
use protocol_compoliance_score::run_protocol_compliance;
use std::fs;

#[test]
fn test_missing_markdown_file() {
    let args = vec!["bin".to_string(), "--protocol".to_string(), "missing_md".to_string()];
    let result = run_protocol_compliance(&args);
    assert!(result.is_err());
    assert!(result.unwrap_err().contains("ERROR: Missing protocol markdown file"));
}

#[test]
fn test_missing_json_file() {
    let md_path = "MISSING_JSON.md";
    fs::write(md_path, "Protocol markdown content").unwrap();
    let args = vec!["bin".to_string(), "--protocol".to_string(), "MISSING_JSON".to_string()];
    let result = run_protocol_compliance(&args);
    assert!(result.is_err());
    assert!(result.unwrap_err().contains("ERROR: Missing protocol JSON file"));
    fs::remove_file(md_path).unwrap();
}

#[test]
fn test_failed_read_protocol_markdown() {
    // Create a directory instead of a file to trigger read error
    let md_path = "BAD_READ.md";
    let json_path = "BAD_READ.json";
    fs::create_dir(md_path).unwrap();
    fs::write(json_path, "[]").unwrap();
    let args = vec!["bin".to_string(), "--protocol".to_string(), "BAD_READ".to_string()];
    let result = run_protocol_compliance(&args);
    assert!(result.is_err());
    assert!(result.unwrap_err().contains("Failed to read protocol markdown file"));
    fs::remove_dir(md_path).unwrap();
    fs::remove_file(json_path).unwrap();
}
