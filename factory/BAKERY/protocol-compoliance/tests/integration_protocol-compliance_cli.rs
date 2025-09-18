// Integration test for CLI/main logic in generate_pcs.rs
use std::process::Command;
use std::fs;

#[test]
fn test_cli_missing_files() {
    let output = Command::new("cargo")
        .args(["run", "--bin", "generate_pcs", "--", "--protocol", "missing_cli"])
        .output()
        .expect("Failed to run CLI");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("ERROR: Missing protocol markdown file"));
    assert!(!output.status.success());
}

#[test]
fn test_cli_valid_files() {
    let md_path = "CLI_PROTOCOL.md";
    let json_path = "CLI_PROTOCOL.json";
    fs::write(md_path, "Protocol markdown content").unwrap();
    let json = r#"[{"name":"t1","prompt":"p1","expected_start":"e1","forbidden":[]}]
"#;
    fs::write(json_path, json).unwrap();
    let output = Command::new("cargo")
        .args(["run", "--bin", "generate_pcs", "--", "--protocol", "CLI_PROTOCOL"])
        .output()
        .expect("Failed to run CLI");
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    let combined = format!("{}\n{}", stdout, stderr);
    assert!(combined.contains("Test: t1"), "Output did not contain expected test name.\nstdout: {}\nstderr: {}", stdout, stderr);
    assert!(output.status.success());
    fs::remove_file(md_path).unwrap();
    fs::remove_file(json_path).unwrap();
}
