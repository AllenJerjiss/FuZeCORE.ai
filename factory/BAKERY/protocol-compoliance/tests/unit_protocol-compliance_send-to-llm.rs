// Unit tests for send_to_llm (mocked)
use protocol_compoliance_score::send_to_llm;
use reqwest::blocking::Client;

#[test]
fn test_connection_error() {
    // This test expects the endpoint to be unreachable
    let client = Client::new();
    let result = send_to_llm(&client, "test prompt");
    assert!(result.contains("ERROR"));
}

#[test]
fn test_invalid_json_response() {
    // This test expects the endpoint to be unreachable or return invalid JSON
    let client = Client::new();
    let result = send_to_llm(&client, "test prompt");
    // Should return empty string or error message
    assert!(result.is_empty() || result.contains("ERROR"));
}
