// Unit test for send_to_llm error branch in lib.rs
use protocol_compoliance_score::send_to_llm;
use reqwest::blocking::Client;

#[test]
fn test_send_to_llm_connection_error() {
    // Use a client with an invalid endpoint to trigger error branch
    let client = Client::new();
    let response = send_to_llm(&client, "test prompt");
    // The default endpoint is localhost:8000, which should fail if not running
    assert!(response.contains("ERROR: Could not connect to chat endpoint"));
}
