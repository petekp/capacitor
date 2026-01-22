//! Fixture-driven tests for Claude adapter parsing and resilience.

use hud_core::agents::{AgentAdapter, AgentState, AgentType, ClaudeAdapter};
use hud_core::storage::StorageConfig;
use std::path::PathBuf;

fn fixture_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/agents/claude")
        .join(name)
}

/// Creates a ClaudeAdapter for fixture testing.
/// Fixtures use the same directory for both capacitor and claude roots,
/// with sessions.json as the state file and sessions/ as the lock dir.
fn adapter_for_fixture(name: &str) -> ClaudeAdapter {
    let path = fixture_path(name);
    // Use same dir for both roots (fixtures have both sessions.json and sessions/)
    let storage = StorageConfig::with_roots(path.clone(), path);
    ClaudeAdapter::with_storage(storage)
}

#[test]
fn test_parse_v3_state_file_working() {
    let adapter = adapter_for_fixture("v3-working");
    let sessions = adapter.all_sessions();

    assert_eq!(sessions.len(), 1);
    let session = &sessions[0];
    assert_eq!(session.agent_type, AgentType::Claude);
    assert_eq!(session.state, AgentState::Working);
    assert_eq!(session.session_id, Some("test-session-123".to_string()));
    assert_eq!(session.cwd, "/Users/test/project");
    assert_eq!(
        session.working_on,
        Some("Implementing multi-agent support".to_string())
    );
}

#[test]
fn test_parse_v3_multiple_sessions() {
    let adapter = adapter_for_fixture("v3-multiple-sessions");
    let sessions = adapter.all_sessions();

    assert_eq!(sessions.len(), 3);

    let working: Vec<_> = sessions
        .iter()
        .filter(|s| s.state == AgentState::Working)
        .collect();
    assert_eq!(working.len(), 1);

    let ready: Vec<_> = sessions
        .iter()
        .filter(|s| s.state == AgentState::Ready)
        .collect();
    assert_eq!(ready.len(), 1);

    let waiting: Vec<_> = sessions
        .iter()
        .filter(|s| s.state == AgentState::Waiting)
        .collect();
    assert_eq!(waiting.len(), 1);
}

#[test]
fn test_corrupted_state_file_returns_empty() {
    let adapter = adapter_for_fixture("corrupted");
    let sessions = adapter.all_sessions();

    assert!(sessions.is_empty());
}

#[test]
fn test_empty_state_file_returns_empty() {
    let adapter = adapter_for_fixture("empty");
    let sessions = adapter.all_sessions();

    assert!(sessions.is_empty());
}

#[test]
fn test_nonexistent_fixture_returns_empty() {
    let adapter = adapter_for_fixture("does-not-exist");
    let sessions = adapter.all_sessions();

    assert!(sessions.is_empty());
}

#[test]
fn test_adapter_id_is_lowercase_no_spaces() {
    let adapter = adapter_for_fixture("v3-working");

    let id = adapter.id();
    assert_eq!(id, id.to_lowercase());
    assert!(!id.contains(' '));
}

#[test]
fn test_is_installed_does_not_panic() {
    let adapter = adapter_for_fixture("v3-working");
    let _ = adapter.is_installed();

    let adapter_missing = adapter_for_fixture("does-not-exist");
    let _ = adapter_missing.is_installed();
}

#[test]
fn test_detect_session_with_nonexistent_path_returns_none() {
    let adapter = adapter_for_fixture("v3-working");
    assert!(adapter.detect_session("/nonexistent/path/12345").is_none());
}
