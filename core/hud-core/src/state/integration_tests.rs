use super::lock::tests_helper::create_lock;
use super::resolver::resolve_state;
use super::store::StateStore;
use super::transition::next_state;
use super::types::{ClaudeState, HookEvent};
use tempfile::tempdir;

fn apply_event(store: &mut StateStore, session_id: &str, cwd: &str, event: HookEvent) {
    let current = store.get_by_session_id(session_id).map(|r| r.state);
    match next_state(current, event) {
        Some(new_state) => store.update(session_id, new_state, cwd),
        None => store.remove(session_id),
    }
}

#[test]
fn test_full_session_lifecycle() {
    let temp = tempdir().unwrap();
    let mut store = StateStore::new_in_memory();
    let session_id = "test-session-1";
    let cwd = "/project";

    create_lock(temp.path(), std::process::id(), cwd);

    apply_event(&mut store, session_id, cwd, HookEvent::SessionStart);
    assert_eq!(resolve_state(temp.path(), &store, cwd), Some(ClaudeState::Ready));

    apply_event(&mut store, session_id, cwd, HookEvent::UserPromptSubmit);
    assert_eq!(resolve_state(temp.path(), &store, cwd), Some(ClaudeState::Working));

    apply_event(&mut store, session_id, cwd, HookEvent::PostToolUse);
    assert_eq!(resolve_state(temp.path(), &store, cwd), Some(ClaudeState::Working));

    apply_event(&mut store, session_id, cwd, HookEvent::PostToolUse);
    assert_eq!(resolve_state(temp.path(), &store, cwd), Some(ClaudeState::Working));

    apply_event(&mut store, session_id, cwd, HookEvent::Stop);
    assert_eq!(resolve_state(temp.path(), &store, cwd), Some(ClaudeState::Ready));

    apply_event(&mut store, session_id, cwd, HookEvent::SessionEnd);
    assert_eq!(store.get_by_session_id(session_id), None);
}

#[test]
fn test_permission_blocked_flow() {
    let temp = tempdir().unwrap();
    let mut store = StateStore::new_in_memory();
    let session_id = "test-session-2";
    let cwd = "/project";

    create_lock(temp.path(), std::process::id(), cwd);

    apply_event(&mut store, session_id, cwd, HookEvent::SessionStart);
    apply_event(&mut store, session_id, cwd, HookEvent::UserPromptSubmit);
    assert_eq!(resolve_state(temp.path(), &store, cwd), Some(ClaudeState::Working));

    apply_event(&mut store, session_id, cwd, HookEvent::PermissionRequest);
    assert_eq!(resolve_state(temp.path(), &store, cwd), Some(ClaudeState::Blocked));

    apply_event(&mut store, session_id, cwd, HookEvent::PostToolUse);
    assert_eq!(resolve_state(temp.path(), &store, cwd), Some(ClaudeState::Working));
}

#[test]
fn test_auto_compaction_flow() {
    let temp = tempdir().unwrap();
    let mut store = StateStore::new_in_memory();
    let session_id = "test-session-3";
    let cwd = "/project";

    create_lock(temp.path(), std::process::id(), cwd);

    apply_event(&mut store, session_id, cwd, HookEvent::SessionStart);
    apply_event(&mut store, session_id, cwd, HookEvent::UserPromptSubmit);
    assert_eq!(resolve_state(temp.path(), &store, cwd), Some(ClaudeState::Working));

    apply_event(
        &mut store,
        session_id,
        cwd,
        HookEvent::PreCompact {
            trigger: "auto".to_string(),
        },
    );
    assert_eq!(resolve_state(temp.path(), &store, cwd), Some(ClaudeState::Compacting));

    apply_event(&mut store, session_id, cwd, HookEvent::PostToolUse);
    assert_eq!(resolve_state(temp.path(), &store, cwd), Some(ClaudeState::Working));
}

#[test]
fn test_interrupt_with_idle_prompt() {
    let temp = tempdir().unwrap();
    let mut store = StateStore::new_in_memory();
    let session_id = "test-session-4";
    let cwd = "/project";

    create_lock(temp.path(), std::process::id(), cwd);

    apply_event(&mut store, session_id, cwd, HookEvent::SessionStart);
    apply_event(&mut store, session_id, cwd, HookEvent::UserPromptSubmit);
    assert_eq!(resolve_state(temp.path(), &store, cwd), Some(ClaudeState::Working));

    apply_event(
        &mut store,
        session_id,
        cwd,
        HookEvent::Notification {
            notification_type: "idle_prompt".to_string(),
        },
    );
    assert_eq!(resolve_state(temp.path(), &store, cwd), Some(ClaudeState::Ready));
}

#[test]
fn test_crash_recovery_no_lock() {
    let temp = tempdir().unwrap();
    let mut store = StateStore::new_in_memory();
    let session_id = "crashed-session";
    let cwd = "/project";

    store.update(session_id, ClaudeState::Working, cwd);

    assert_eq!(resolve_state(temp.path(), &store, cwd), None);
}

#[test]
fn test_multiple_sessions_same_project() {
    let temp = tempdir().unwrap();
    let mut store = StateStore::new_in_memory();
    let cwd = "/project";

    store.update("old-session", ClaudeState::Ready, cwd);

    std::thread::sleep(std::time::Duration::from_millis(10));

    store.update("new-session", ClaudeState::Working, cwd);

    create_lock(temp.path(), std::process::id(), cwd);
    assert_eq!(resolve_state(temp.path(), &store, cwd), Some(ClaudeState::Working));
}

#[test]
fn test_cd_scenario_child_does_not_inherit_parent() {
    // Correct semantics: Parent locks do NOT make children active
    let temp = tempdir().unwrap();
    let mut store = StateStore::new_in_memory();
    let parent_cwd = "/parent";
    let child_cwd = "/parent/child";
    let session_id = "cd-session";

    create_lock(temp.path(), std::process::id(), parent_cwd);

    apply_event(&mut store, session_id, parent_cwd, HookEvent::SessionStart);
    apply_event(&mut store, session_id, parent_cwd, HookEvent::UserPromptSubmit);

    assert_eq!(resolve_state(temp.path(), &store, parent_cwd), Some(ClaudeState::Working));
    // Child query should return None (parent lock doesn't propagate down)
    assert_eq!(resolve_state(temp.path(), &store, child_cwd), None);
}

#[test]
fn test_sibling_projects_independent() {
    let temp = tempdir().unwrap();
    let mut store = StateStore::new_in_memory();

    create_lock(temp.path(), std::process::id(), "/projects/foo");

    store.update("session-foo", ClaudeState::Working, "/projects/foo");
    store.update("session-bar", ClaudeState::Ready, "/projects/bar");

    assert_eq!(
        resolve_state(temp.path(), &store, "/projects/foo"),
        Some(ClaudeState::Working)
    );
    assert_eq!(resolve_state(temp.path(), &store, "/projects/bar"), None);
}

#[test]
fn test_rapid_state_transitions() {
    let temp = tempdir().unwrap();
    let mut store = StateStore::new_in_memory();
    let session_id = "rapid-session";
    let cwd = "/project";

    create_lock(temp.path(), std::process::id(), cwd);

    apply_event(&mut store, session_id, cwd, HookEvent::SessionStart);
    apply_event(&mut store, session_id, cwd, HookEvent::UserPromptSubmit);

    for _ in 0..100 {
        apply_event(&mut store, session_id, cwd, HookEvent::PostToolUse);
    }

    assert_eq!(resolve_state(temp.path(), &store, cwd), Some(ClaudeState::Working));
}
