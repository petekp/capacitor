//! Integration tests for session state resolution.
//!
//! These tests verify the full pipeline: lock detection + state store + resolver.
//! Unlike unit tests that mock dependencies, these test real interactions.
//!
//! # Key Invariants Tested
//!
//! 1. **Match type priority**: Exact > Child > Parent, regardless of timestamp
//! 2. **Lock authority**: Lock presence overrides staleness concerns
//! 3. **Isolation**: Unrelated sessions never bleed into other projects
//! 4. **Monorepo safety**: Sibling projects don't inherit each other's state
//!
//! # Running These Tests
//!
//! These tests require the `test-helpers` feature:
//! ```bash
//! cargo test -p hud-core --test resolver_integration --features test-helpers
//! ```

// Only compile when test-helpers feature is enabled
#![cfg(feature = "test-helpers")]

use chrono::{Duration, Utc};
use hud_core::state::{
    is_session_running, resolve_state_with_details, tests_helper::create_lock, StateStore,
};
use hud_core::types::SessionState;
use tempfile::tempdir;

// =============================================================================
// INVARIANT 1: Match type always beats timestamp
// =============================================================================

/// Exact match must beat a fresher parent match.
/// This is the regression test for the original bug.
#[test]
fn invariant_exact_match_beats_fresher_parent() {
    let temp = tempdir().unwrap();
    let lock_dir = temp.path();

    // Scenario: User has Claude running in ~/Code/capacitor (exact)
    // and another session in ~/ (parent). Parent session is fresher.
    create_lock(lock_dir, std::process::id(), "/Users/pete/Code/capacitor");

    let mut store = StateStore::new_in_memory();

    // Exact match - stale (10 minutes old)
    store.update(
        "capacitor-session",
        SessionState::Ready,
        "/Users/pete/Code/capacitor",
    );
    store.set_timestamp_for_test("capacitor-session", Utc::now() - Duration::minutes(10));

    // Parent match - fresh (just now)
    store.update("home-session", SessionState::Working, "/Users/pete");
    // Default timestamp is now, so this is fresher

    let resolved =
        resolve_state_with_details(lock_dir, &store, "/Users/pete/Code/capacitor").unwrap();

    assert_eq!(
        resolved.session_id.as_deref(),
        Some("capacitor-session"),
        "Exact match MUST win over fresher parent match"
    );
}

/// Child match must beat a fresher parent match.
#[test]
fn invariant_child_match_beats_fresher_parent() {
    let temp = tempdir().unwrap();
    let lock_dir = temp.path();

    // Lock at a child path
    create_lock(
        lock_dir,
        std::process::id(),
        "/Users/pete/Code/capacitor/apps/swift",
    );

    let mut store = StateStore::new_in_memory();

    // Child match - stale
    store.update(
        "swift-session",
        SessionState::Ready,
        "/Users/pete/Code/capacitor/apps/swift",
    );
    store.set_timestamp_for_test("swift-session", Utc::now() - Duration::minutes(10));

    // Parent match - fresh
    store.update("home-session", SessionState::Working, "/Users/pete");

    // Query from parent path
    let resolved =
        resolve_state_with_details(lock_dir, &store, "/Users/pete/Code/capacitor").unwrap();

    assert_eq!(
        resolved.session_id.as_deref(),
        Some("swift-session"),
        "Child match MUST win over fresher parent match"
    );
}

/// Among equal match types, fresher timestamp wins.
#[test]
fn invariant_fresher_timestamp_wins_for_equal_match_types() {
    let temp = tempdir().unwrap();
    let lock_dir = temp.path();

    create_lock(lock_dir, std::process::id(), "/project");

    let mut store = StateStore::new_in_memory();

    // Two exact matches with different timestamps
    store.update("old-session", SessionState::Ready, "/project");
    store.set_timestamp_for_test("old-session", Utc::now() - Duration::minutes(5));

    store.update("new-session", SessionState::Working, "/project");
    // new-session has default "now" timestamp

    let resolved = resolve_state_with_details(lock_dir, &store, "/project").unwrap();

    assert_eq!(
        resolved.session_id.as_deref(),
        Some("new-session"),
        "Fresher timestamp should win when match types are equal"
    );
    assert_eq!(resolved.state, SessionState::Working);
}

// =============================================================================
// INVARIANT 2: Lock presence is authoritative
// =============================================================================

/// When a lock exists, trust the recorded state even if timestamp is stale.
#[test]
fn invariant_lock_overrides_staleness() {
    let temp = tempdir().unwrap();
    let lock_dir = temp.path();

    create_lock(lock_dir, std::process::id(), "/project");

    let mut store = StateStore::new_in_memory();
    store.update("session", SessionState::Working, "/project");
    // Make it very stale (1 hour old)
    store.set_timestamp_for_test("session", Utc::now() - Duration::hours(1));

    let resolved = resolve_state_with_details(lock_dir, &store, "/project").unwrap();

    assert_eq!(
        resolved.state,
        SessionState::Working,
        "Lock presence should override staleness - Claude is proven running"
    );
    assert!(resolved.is_from_lock);
}

/// Without a lock, stale Working state should not be trusted.
#[test]
fn invariant_no_lock_stale_working_is_not_trusted() {
    let temp = tempdir().unwrap();
    let lock_dir = temp.path();
    // No lock created

    let mut store = StateStore::new_in_memory();
    store.update("session", SessionState::Working, "/project");
    store.set_timestamp_for_test("session", Utc::now() - Duration::minutes(10));

    let resolved = resolve_state_with_details(lock_dir, &store, "/project");

    assert!(
        resolved.is_none(),
        "Stale Working state without lock should not be trusted"
    );
}

// =============================================================================
// INVARIANT 3: Session isolation
// =============================================================================

/// A session in the home directory should NOT affect unrelated projects.
#[test]
fn invariant_home_session_does_not_affect_unrelated_project() {
    let temp = tempdir().unwrap();
    let lock_dir = temp.path();

    // Session running in home directory
    create_lock(lock_dir, std::process::id(), "/Users/pete");

    let mut store = StateStore::new_in_memory();
    store.update("home-session", SessionState::Working, "/Users/pete");

    // Query a completely unrelated project (not under /Users/pete)
    let resolved = resolve_state_with_details(lock_dir, &store, "/opt/other-project");

    assert!(
        resolved.is_none(),
        "Home session should not affect unrelated projects"
    );
}

/// A session should not "leak" into sibling directories.
#[test]
fn invariant_sibling_projects_are_isolated() {
    let temp = tempdir().unwrap();
    let lock_dir = temp.path();

    // Session in project-a
    create_lock(lock_dir, std::process::id(), "/workspace/project-a");

    let mut store = StateStore::new_in_memory();
    store.update(
        "project-a-session",
        SessionState::Working,
        "/workspace/project-a",
    );

    // Query sibling project-b
    let resolved = resolve_state_with_details(lock_dir, &store, "/workspace/project-b");

    assert!(
        resolved.is_none(),
        "Sibling projects must be isolated - project-a session should not affect project-b"
    );
}

// =============================================================================
// INVARIANT 4: Monorepo safety
// =============================================================================

/// In a monorepo, querying the root should find a child session.
#[test]
fn invariant_monorepo_root_finds_child_session() {
    let temp = tempdir().unwrap();
    let lock_dir = temp.path();

    // Session in a monorepo package
    create_lock(lock_dir, std::process::id(), "/workspace/packages/lib-a");

    let mut store = StateStore::new_in_memory();
    store.update(
        "lib-a-session",
        SessionState::Working,
        "/workspace/packages/lib-a",
    );

    // Query from monorepo root
    let resolved = resolve_state_with_details(lock_dir, &store, "/workspace").unwrap();

    assert_eq!(
        resolved.session_id.as_deref(),
        Some("lib-a-session"),
        "Querying monorepo root should find child package session"
    );
    assert_eq!(resolved.cwd, "/workspace/packages/lib-a");
}

/// In a monorepo, sibling packages should be isolated.
#[test]
fn invariant_monorepo_sibling_packages_isolated() {
    let temp = tempdir().unwrap();
    let lock_dir = temp.path();

    // Session in lib-a
    create_lock(lock_dir, std::process::id(), "/workspace/packages/lib-a");

    let mut store = StateStore::new_in_memory();
    store.update(
        "lib-a-session",
        SessionState::Working,
        "/workspace/packages/lib-a",
    );

    // Query lib-b (sibling package)
    let resolved = resolve_state_with_details(lock_dir, &store, "/workspace/packages/lib-b");

    assert!(
        resolved.is_none(),
        "Sibling packages in monorepo must be isolated"
    );
}

/// Multiple sessions in different monorepo packages - each resolves correctly.
#[test]
fn invariant_monorepo_multiple_sessions_resolve_correctly() {
    let temp = tempdir().unwrap();
    let lock_dir = temp.path();

    // Sessions in two different packages
    create_lock(lock_dir, std::process::id(), "/workspace/packages/lib-a");
    create_lock(lock_dir, std::process::id(), "/workspace/apps/web");

    let mut store = StateStore::new_in_memory();
    store.update(
        "lib-a-session",
        SessionState::Working,
        "/workspace/packages/lib-a",
    );
    store.update("web-session", SessionState::Ready, "/workspace/apps/web");

    // Query each package - should get correct session
    let lib_a_resolved =
        resolve_state_with_details(lock_dir, &store, "/workspace/packages/lib-a").unwrap();
    let web_resolved = resolve_state_with_details(lock_dir, &store, "/workspace/apps/web").unwrap();

    assert_eq!(lib_a_resolved.session_id.as_deref(), Some("lib-a-session"));
    assert_eq!(lib_a_resolved.state, SessionState::Working);

    assert_eq!(web_resolved.session_id.as_deref(), Some("web-session"));
    assert_eq!(web_resolved.state, SessionState::Ready);
}

// =============================================================================
// EDGE CASES: Path normalization
// =============================================================================

/// Trailing slashes should be normalized.
#[test]
fn edge_case_trailing_slash_normalization() {
    let temp = tempdir().unwrap();
    let lock_dir = temp.path();

    create_lock(lock_dir, std::process::id(), "/project");

    let mut store = StateStore::new_in_memory();
    store.update("session", SessionState::Working, "/project/");

    // Query without trailing slash
    let resolved = resolve_state_with_details(lock_dir, &store, "/project").unwrap();
    assert_eq!(resolved.session_id.as_deref(), Some("session"));

    // Query with trailing slash
    let resolved = resolve_state_with_details(lock_dir, &store, "/project/").unwrap();
    assert_eq!(resolved.session_id.as_deref(), Some("session"));
}

/// Root path handling.
#[test]
fn edge_case_root_path() {
    let temp = tempdir().unwrap();
    let lock_dir = temp.path();

    create_lock(lock_dir, std::process::id(), "/");

    let mut store = StateStore::new_in_memory();
    store.update("root-session", SessionState::Working, "/");

    let resolved = resolve_state_with_details(lock_dir, &store, "/").unwrap();
    assert_eq!(resolved.session_id.as_deref(), Some("root-session"));
}

// =============================================================================
// HELPER: is_session_running quick check
// =============================================================================

#[test]
fn is_session_running_returns_true_for_exact_match() {
    let temp = tempdir().unwrap();
    let lock_dir = temp.path();

    create_lock(lock_dir, std::process::id(), "/project");

    assert!(is_session_running(lock_dir, "/project"));
}

#[test]
fn is_session_running_returns_true_for_child_lock() {
    let temp = tempdir().unwrap();
    let lock_dir = temp.path();

    create_lock(lock_dir, std::process::id(), "/project/src");

    // Parent query should find child lock
    assert!(is_session_running(lock_dir, "/project"));
}

#[test]
fn is_session_running_returns_false_for_parent_lock() {
    let temp = tempdir().unwrap();
    let lock_dir = temp.path();

    create_lock(lock_dir, std::process::id(), "/");

    // Child query should NOT find parent lock
    assert!(!is_session_running(lock_dir, "/project"));
}

#[test]
fn is_session_running_returns_false_for_sibling() {
    let temp = tempdir().unwrap();
    let lock_dir = temp.path();

    create_lock(lock_dir, std::process::id(), "/workspace/project-a");

    assert!(!is_session_running(lock_dir, "/workspace/project-b"));
}
