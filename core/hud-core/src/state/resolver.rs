use std::path::Path;

use super::lock::{find_child_lock, is_session_running};
use super::store::StateStore;
use super::types::ClaudeState;

pub fn resolve_state(lock_dir: &Path, store: &StateStore, project_path: &str) -> Option<ClaudeState> {
    let is_running = is_session_running(lock_dir, project_path);
    let record = store.find_by_cwd(project_path);

    match (is_running, record) {
        (true, Some(r)) => Some(r.state),
        (true, None) => Some(ClaudeState::Ready),
        (false, Some(r)) => {
            // Session found but no lock for queried path
            // Check if the session's actual cwd has a lock
            if is_session_running(lock_dir, &r.cwd) {
                Some(r.state)
            } else {
                // The session's cwd might have moved (PostToolUse updates cwd)
                // Check if any child path has a lock
                if find_child_lock(lock_dir, project_path).is_some() {
                    // There's a session running in a subdirectory
                    Some(r.state)
                } else {
                    None
                }
            }
        }
        (false, None) => {
            // No record found - but check if any child path has a lock
            if find_child_lock(lock_dir, project_path).is_some() {
                // There's a session in a subdirectory, default to Ready
                Some(ClaudeState::Ready)
            } else {
                None
            }
        }
    }
}

#[derive(Debug, Clone)]
pub struct ResolvedState {
    pub state: ClaudeState,
    pub session_id: Option<String>,
    pub cwd: String,
}

pub fn resolve_state_with_details(
    lock_dir: &Path,
    store: &StateStore,
    project_path: &str,
) -> Option<ResolvedState> {
    let is_running = is_session_running(lock_dir, project_path);
    let record = store.find_by_cwd(project_path);

    match (is_running, record) {
        (true, Some(r)) => Some(ResolvedState {
            state: r.state,
            session_id: Some(r.session_id.clone()),
            cwd: r.cwd.clone(),
        }),
        (true, None) => Some(ResolvedState {
            state: ClaudeState::Ready,
            session_id: None,
            cwd: project_path.to_string(),
        }),
        (false, Some(r)) => {
            // Session found but no lock for queried path
            // Check if the session's actual cwd has a lock
            if is_session_running(lock_dir, &r.cwd) {
                Some(ResolvedState {
                    state: r.state,
                    session_id: Some(r.session_id.clone()),
                    cwd: r.cwd.clone(),
                })
            } else if let Some(lock_info) = find_child_lock(lock_dir, project_path) {
                // There's a session running in a subdirectory
                Some(ResolvedState {
                    state: r.state,
                    session_id: Some(r.session_id.clone()),
                    cwd: lock_info.path,
                })
            } else {
                None
            }
        }
        (false, None) => {
            // No record found - but check if any child path has a lock
            if let Some(lock_info) = find_child_lock(lock_dir, project_path) {
                Some(ResolvedState {
                    state: ClaudeState::Ready,
                    session_id: None,
                    cwd: lock_info.path,
                })
            } else {
                None
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::super::lock::tests_helper::create_lock;
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn test_no_state_no_lock_returns_none() {
        let temp = tempdir().unwrap();
        let store = StateStore::new_in_memory();
        assert!(resolve_state(temp.path(), &store, "/project").is_none());
    }

    #[test]
    fn test_has_state_has_lock_returns_state() {
        let temp = tempdir().unwrap();
        create_lock(temp.path(), std::process::id(), "/project");
        let mut store = StateStore::new_in_memory();
        store.update("s1", ClaudeState::Working, "/project");
        assert_eq!(resolve_state(temp.path(), &store, "/project"), Some(ClaudeState::Working));
    }

    #[test]
    fn test_has_state_no_lock_returns_none() {
        let temp = tempdir().unwrap();
        let mut store = StateStore::new_in_memory();
        store.update("s1", ClaudeState::Working, "/project");
        assert!(resolve_state(temp.path(), &store, "/project").is_none());
    }

    #[test]
    fn test_has_lock_no_state_returns_ready() {
        let temp = tempdir().unwrap();
        create_lock(temp.path(), std::process::id(), "/project");
        let store = StateStore::new_in_memory();
        assert_eq!(resolve_state(temp.path(), &store, "/project"), Some(ClaudeState::Ready));
    }

    #[test]
    fn test_state_ready_no_lock_returns_none() {
        let temp = tempdir().unwrap();
        let mut store = StateStore::new_in_memory();
        store.update("s1", ClaudeState::Ready, "/project");
        assert!(resolve_state(temp.path(), &store, "/project").is_none());
    }

    #[test]
    fn test_child_inherits_parent_lock_and_state() {
        let temp = tempdir().unwrap();
        create_lock(temp.path(), std::process::id(), "/parent");
        let mut store = StateStore::new_in_memory();
        store.update("s1", ClaudeState::Working, "/parent");
        assert_eq!(resolve_state(temp.path(), &store, "/parent/child"), Some(ClaudeState::Working));
    }

    #[test]
    fn test_resolve_with_details_returns_session_id() {
        let temp = tempdir().unwrap();
        create_lock(temp.path(), std::process::id(), "/project");
        let mut store = StateStore::new_in_memory();
        store.update("my-session", ClaudeState::Blocked, "/project");
        let resolved = resolve_state_with_details(temp.path(), &store, "/project").unwrap();
        assert_eq!(resolved.state, ClaudeState::Blocked);
        assert_eq!(resolved.session_id, Some("my-session".to_string()));
        assert_eq!(resolved.cwd, "/project");
    }

    #[test]
    fn test_parent_query_finds_child_session_with_lock() {
        // Critical case: session running in /project/apps/swift, query for /project
        let temp = tempdir().unwrap();
        create_lock(temp.path(), std::process::id(), "/project/apps/swift");
        let mut store = StateStore::new_in_memory();
        store.update("child-session", ClaudeState::Working, "/project/apps/swift");

        // Query for parent should find the child session
        let resolved = resolve_state(temp.path(), &store, "/project");
        assert_eq!(resolved, Some(ClaudeState::Working));
    }

    #[test]
    fn test_parent_query_finds_child_session_with_details() {
        let temp = tempdir().unwrap();
        create_lock(temp.path(), std::process::id(), "/project/apps/swift");
        let mut store = StateStore::new_in_memory();
        store.update("child-session", ClaudeState::Working, "/project/apps/swift");

        let resolved = resolve_state_with_details(temp.path(), &store, "/project").unwrap();
        assert_eq!(resolved.state, ClaudeState::Working);
        assert_eq!(resolved.session_id, Some("child-session".to_string()));
        assert_eq!(resolved.cwd, "/project/apps/swift");
    }
}
