use std::path::Path;

use super::lock::{find_child_lock, find_matching_child_lock, get_lock_info, is_session_running};
use super::store::StateStore;
use super::types::ClaudeState;

/// Helper: Search all sessions for one matching the given lock by PID and path
/// Allows record.cwd to be exact/child/parent of lock.path (handles cd within session)
fn find_session_for_lock(store: &StateStore, lock_info: &super::types::LockInfo) -> Option<ClaudeState> {
    #[derive(PartialEq, Eq, PartialOrd, Ord, Clone, Copy)]
    enum MatchType {
        Parent = 0,  // record.cwd is parent of lock (cd .. scenario)
        Child = 1,   // record.cwd is child of lock (cd subdir scenario)
        Exact = 2,   // exact match - highest priority
    }

    let mut best: Option<(&super::types::SessionRecord, MatchType)> = None;

    // Normalize paths for matching, special-case root
    let lock_path_normalized = if lock_info.path == "/" {
        "/"
    } else {
        lock_info.path.trim_end_matches('/')
    };

    for record in store.all_sessions() {
        if record.pid == Some(lock_info.pid) {
            let record_cwd_normalized = if record.cwd == "/" {
                "/"
            } else {
                record.cwd.trim_end_matches('/')
            };

            // Check for exact, child, parent, or sibling match
            let match_type = if record_cwd_normalized == lock_path_normalized {
                Some(MatchType::Exact)
            } else if lock_path_normalized == "/" {
                // Special case: root lock matches any absolute path descendant
                if record_cwd_normalized.starts_with("/") && record_cwd_normalized != "/" {
                    Some(MatchType::Child)  // Any absolute path is descendant of /
                } else {
                    None
                }
            } else if record_cwd_normalized == "/" {
                // Special case: record at root matches any absolute path descendant
                if lock_path_normalized.starts_with("/") && lock_path_normalized != "/" {
                    Some(MatchType::Parent)  // / is ancestor of any absolute path
                } else {
                    None
                }
            } else if record_cwd_normalized.starts_with(&format!("{}/", lock_path_normalized)) {
                Some(MatchType::Child)  // cd into subdir
            } else if lock_path_normalized.starts_with(&format!("{}/", record_cwd_normalized)) {
                Some(MatchType::Parent)  // cd .. to parent
            } else {
                // No match - different paths that aren't parent/child
                None
            };

            if let Some(current_match_type) = match_type {
                match best {
                    None => best = Some((record, current_match_type)),
                    Some((current, current_type)) => {
                        // Priority: fresher timestamp first, then match type, then session_id
                        let should_replace =
                            record.updated_at > current.updated_at ||
                            (record.updated_at == current.updated_at && current_match_type > current_type) ||
                            (record.updated_at == current.updated_at && current_match_type == current_type && record.session_id > current.session_id);

                        if should_replace {
                            best = Some((record, current_match_type));
                        }
                    }
                }
            }
        }
    }

    best.map(|(record, _)| record.state)
}

pub fn resolve_state(lock_dir: &Path, store: &StateStore, project_path: &str) -> Option<ClaudeState> {
    let is_running = is_session_running(lock_dir, project_path);
    let record = store.find_by_cwd(project_path);

    match (is_running, record) {
        (true, Some(r)) => {
            // Lock exists and we have a record
            // Try to find lock matching this record's PID (handles multiple child locks and cd scenarios)
            let matching_lock = if let Some(pid) = r.pid {
                // First try exact PID+path match (fast path for no-cd case)
                find_matching_child_lock(lock_dir, project_path, Some(pid), Some(&r.cwd))
                    // Fall back to PID-only match (handles cd scenarios where path changed)
                    .or_else(|| find_matching_child_lock(lock_dir, project_path, Some(pid), None))
                    // Last resort: any lock (if session has no lock matching its PID)
                    .or_else(|| get_lock_info(lock_dir, project_path))
            } else {
                // No PID in record - just get any lock
                get_lock_info(lock_dir, project_path)
            };

            if let Some(lock_info) = matching_lock {
                match r.pid {
                    Some(record_pid) if record_pid == lock_info.pid => {
                        // PIDs match - but there might be multiple sessions with same PID
                        // Use find_session_for_lock to apply tie-breaker logic (timestamp → match type → session_id)
                        Some(find_session_for_lock(store, &lock_info)
                            .unwrap_or(r.state))  // Fallback to current record if search finds nothing
                    }
                    Some(_) => {
                        // PIDs don't match - search all sessions for one matching the lock by PID and path
                        find_session_for_lock(store, &lock_info)
                            .or(Some(ClaudeState::Ready))
                    }
                    None => {
                        // No PID in record - verify path matches before trusting
                        if lock_info.path == r.cwd {
                            Some(r.state)
                        } else {
                            // Path doesn't match - search for correct session
                            find_session_for_lock(store, &lock_info)
                                .or(Some(ClaudeState::Ready))
                        }
                    }
                }
            } else {
                // No lock info (shouldn't happen since is_running==true)
                Some(r.state)
            }
        }
        (true, None) => Some(ClaudeState::Ready),
        (false, Some(r)) => {
            // Session found but no lock for queried path
            // Try to find matching child lock first
            let matching_lock = find_matching_child_lock(lock_dir, project_path, r.pid, Some(&r.cwd));

            if matching_lock.is_some() {
                // Found matching child lock - use record's state
                Some(r.state)
            } else if find_child_lock(lock_dir, project_path).is_some() {
                // Child lock exists but doesn't match - different session
                Some(ClaudeState::Ready)
            } else {
                // Check if record is a parent fallback (normalize trailing slashes)
                let r_cwd_normalized = r.cwd.trim_end_matches('/');
                if project_path.starts_with(&format!("{}/", r_cwd_normalized)) {
                    // Record is a parent fallback - project_path is a child of r.cwd
                    // Don't propagate parent state to child queries (violates lock semantics)
                    return None;
                }


                // Check if r.cwd has a lock, and verify it belongs to this session
                if let Some(lock_info) = get_lock_info(lock_dir, &r.cwd) {
                    if r.pid == Some(lock_info.pid) {
                        // Lock at r.cwd belongs to this session
                        Some(r.state)
                    } else {
                        // Lock at r.cwd belongs to different session
                        None
                    }
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

/// Helper: Search all sessions for one matching the given lock by PID and path (with details)
/// Allows record.cwd to be exact/child/parent of lock.path (handles cd within session)
fn find_session_for_lock_with_details(store: &StateStore, lock_info: &super::types::LockInfo) -> Option<ResolvedState> {
    #[derive(PartialEq, Eq, PartialOrd, Ord, Clone, Copy)]
    enum MatchType {
        Parent = 0,  // record.cwd is parent of lock (cd .. scenario)
        Child = 1,   // record.cwd is child of lock (cd subdir scenario)
        Exact = 2,   // exact match - highest priority
    }

    let mut best: Option<(&super::types::SessionRecord, MatchType)> = None;

    // Normalize paths for matching, special-case root
    let lock_path_normalized = if lock_info.path == "/" {
        "/"
    } else {
        lock_info.path.trim_end_matches('/')
    };

    for record in store.all_sessions() {
        if record.pid == Some(lock_info.pid) {
            let record_cwd_normalized = if record.cwd == "/" {
                "/"
            } else {
                record.cwd.trim_end_matches('/')
            };

            // Check for exact, child, parent, or sibling match
            let match_type = if record_cwd_normalized == lock_path_normalized {
                Some(MatchType::Exact)
            } else if lock_path_normalized == "/" {
                // Special case: root lock matches any absolute path descendant
                if record_cwd_normalized.starts_with("/") && record_cwd_normalized != "/" {
                    Some(MatchType::Child)  // Any absolute path is descendant of /
                } else {
                    None
                }
            } else if record_cwd_normalized == "/" {
                // Special case: record at root matches any absolute path descendant
                if lock_path_normalized.starts_with("/") && lock_path_normalized != "/" {
                    Some(MatchType::Parent)  // / is ancestor of any absolute path
                } else {
                    None
                }
            } else if record_cwd_normalized.starts_with(&format!("{}/", lock_path_normalized)) {
                Some(MatchType::Child)  // cd into subdir
            } else if lock_path_normalized.starts_with(&format!("{}/", record_cwd_normalized)) {
                Some(MatchType::Parent)  // cd .. to parent
            } else {
                // No match - different paths that aren't parent/child
                None
            };

            if let Some(current_match_type) = match_type {
                match best {
                    None => best = Some((record, current_match_type)),
                    Some((current, current_type)) => {
                        // Priority: fresher timestamp first, then match type, then session_id
                        let should_replace =
                            record.updated_at > current.updated_at ||
                            (record.updated_at == current.updated_at && current_match_type > current_type) ||
                            (record.updated_at == current.updated_at && current_match_type == current_type && record.session_id > current.session_id);

                        if should_replace {
                            best = Some((record, current_match_type));
                        }
                    }
                }
            }
        }
    }

    best.map(|(record, _)| ResolvedState {
        state: record.state,
        session_id: Some(record.session_id.clone()),
        cwd: lock_info.path.clone(),
    })
}

pub fn resolve_state_with_details(
    lock_dir: &Path,
    store: &StateStore,
    project_path: &str,
) -> Option<ResolvedState> {
    let is_running = is_session_running(lock_dir, project_path);
    let record = store.find_by_cwd(project_path);

    match (is_running, record) {
        (true, Some(r)) => {
            // Lock exists for project path, and we have a state record
            // Try to find lock matching this record's PID (handles multiple child locks and cd scenarios)
            let matching_lock = if let Some(pid) = r.pid {
                // First try exact PID+path match (fast path for no-cd case)
                find_matching_child_lock(lock_dir, project_path, Some(pid), Some(&r.cwd))
                    // Fall back to PID-only match (handles cd scenarios where path changed)
                    .or_else(|| find_matching_child_lock(lock_dir, project_path, Some(pid), None))
                    // Last resort: any lock (if session has no lock matching its PID)
                    .or_else(|| get_lock_info(lock_dir, project_path))
            } else {
                // No PID in record - just get any lock
                get_lock_info(lock_dir, project_path)
            };

            if let Some(lock_info) = matching_lock {
                match r.pid {
                    Some(record_pid) if record_pid == lock_info.pid => {
                        // PIDs match - but there might be multiple sessions with same PID
                        // Use find_session_for_lock_with_details to apply tie-breaker logic (timestamp → match type → session_id)
                        find_session_for_lock_with_details(store, &lock_info)
                            .or_else(|| {
                                // Fallback to current record if search finds nothing
                                Some(ResolvedState {
                                    state: r.state,
                                    session_id: Some(r.session_id.clone()),
                                    cwd: lock_info.path,
                                })
                            })
                    }
                    Some(_) => {
                        // Different PID - search all sessions for one matching the lock by PID and path
                        find_session_for_lock_with_details(store, &lock_info)
                            .or_else(|| Some(ResolvedState {
                                state: ClaudeState::Ready,
                                session_id: None,
                                cwd: lock_info.path,
                            }))
                    }
                    None => {
                        // No PID in record - verify path matches before trusting
                        if lock_info.path == r.cwd {
                            Some(ResolvedState {
                                state: r.state,
                                session_id: Some(r.session_id.clone()),
                                cwd: lock_info.path,
                            })
                        } else {
                            // Path doesn't match - search for correct session
                            find_session_for_lock_with_details(store, &lock_info)
                                .or_else(|| Some(ResolvedState {
                                    state: ClaudeState::Ready,
                                    session_id: None,
                                    cwd: lock_info.path,
                                }))
                        }
                    }
                }
            } else {
                // No lock found (shouldn't happen since is_running==true)
                Some(ResolvedState {
                    state: r.state,
                    session_id: Some(r.session_id.clone()),
                    cwd: r.cwd.clone(),
                })
            }
        }
        (true, None) => Some(ResolvedState {
            state: ClaudeState::Ready,
            session_id: None,
            cwd: project_path.to_string(),
        }),
        (false, Some(r)) => {
            // Session found but no lock for queried path
            // First try to find a child lock that matches this record's PID or path
            let matching_lock = find_matching_child_lock(lock_dir, project_path, r.pid, Some(&r.cwd));

            if let Some(lock_info) = matching_lock {
                // Found a lock matching this record - use record's state
                Some(ResolvedState {
                    state: r.state,
                    session_id: Some(r.session_id.clone()),
                    cwd: lock_info.path,
                })
            } else if let Some(lock_info) = find_child_lock(lock_dir, project_path) {
                // Found a child lock but it doesn't match this record
                // Use lock only, default to Ready (different session)
                Some(ResolvedState {
                    state: ClaudeState::Ready,
                    session_id: None,
                    cwd: lock_info.path,
                })
            } else {
                // Check if record is a parent fallback (normalize trailing slashes)
                let r_cwd_normalized = r.cwd.trim_end_matches('/');
                if project_path.starts_with(&format!("{}/", r_cwd_normalized)) {
                    // Record is a parent fallback - project_path is a child of r.cwd
                    // Don't propagate parent state to child queries (violates lock semantics)
                    return None;
                }


                // Check if r.cwd has a lock, and verify it belongs to this session
                if let Some(lock_info) = get_lock_info(lock_dir, &r.cwd) {
                    if r.pid == Some(lock_info.pid) {
                        // Lock at r.cwd belongs to this session
                        Some(ResolvedState {
                            state: r.state,
                            session_id: Some(r.session_id.clone()),
                            cwd: r.cwd.clone(),
                        })
                    } else {
                        // Lock at r.cwd belongs to different session
                        None
                    }
                } else {
                    None
                }
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
    use super::super::lock::tests_helper::{create_lock, create_lock_with_timestamp};
    use super::super::lock::get_process_start_time;
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
    fn test_child_does_not_inherit_parent_lock() {
        // Correct semantics: Parent locks do NOT make children active
        // (but child locks DO make parents active - see test_parent_query_finds_child_session_with_lock)
        let temp = tempdir().unwrap();
        create_lock(temp.path(), std::process::id(), "/parent");
        let mut store = StateStore::new_in_memory();
        store.update("s1", ClaudeState::Working, "/parent");
        store.set_pid_for_test("s1", std::process::id());

        // Query for child should return None (parent lock doesn't propagate down)
        assert_eq!(resolve_state(temp.path(), &store, "/parent/child"), None);
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

    #[test]
    fn test_resolver_does_not_mix_lock_and_state_from_different_sessions() {
        let temp = tempdir().unwrap();
        let live_pid = std::process::id();
        let fake_pid = 1234; // Different from lock PID

        // Session 1 with fake PID at /project (stale, no lock)
        let mut store = StateStore::new_in_memory();
        store.update("session-1", ClaudeState::Working, "/project");
        store.set_pid_for_test("session-1", fake_pid);

        use std::thread;
        use std::time::Duration;
        thread::sleep(Duration::from_millis(10));

        // Session 2 with live PID at /project/child (fresh, has lock)
        create_lock(temp.path(), live_pid, "/project/child");
        store.update("session-2", ClaudeState::Compacting, "/project/child");
        store.set_pid_for_test("session-2", live_pid);

        // Query for /project:
        // - find_by_cwd returns session-2 (fresher child)
        // - find_matching_child_lock finds session-2's lock
        // - Should correctly return session-2's state (NOT mix with session-1)
        let resolved = resolve_state_with_details(temp.path(), &store, "/project");

        let res = resolved.expect("Should find resolved state");
        // Should correctly match session-2's lock and state
        assert_eq!(res.state, ClaudeState::Compacting);
        assert_eq!(res.session_id, Some("session-2".to_string()));
        assert_eq!(res.cwd, "/project/child");
    }

    #[test]
    fn test_resolver_prefers_matching_lock_when_multiple_children() {
        let temp = tempdir().unwrap();
        let live_pid = std::process::id();

        // Both locks use live PID (our test process) so they pass is_pid_alive check
        let mut store = StateStore::new_in_memory();

        // Session A at /project/app1 with live PID
        store.update("session-a", ClaudeState::Working, "/project/app1");
        store.set_pid_for_test("session-a", live_pid);
        create_lock(temp.path(), live_pid, "/project/app1");

        // Session B at /project/app2 with live PID (fresher timestamp)
        create_lock(temp.path(), live_pid, "/project/app2");
        store.update("session-b", ClaudeState::Blocked, "/project/app2");
        store.set_pid_for_test("session-b", live_pid);

        // Query for /project - find_by_cwd will return session-b (fresher timestamp)
        // find_matching_child_lock should match by path (/project/app2) not just PID
        let resolved = resolve_state_with_details(temp.path(), &store, "/project");

        let res = resolved.expect("Should find resolved state");
        // Should match session-b's lock by path, use session-b's state
        assert_eq!(res.state, ClaudeState::Blocked);
        assert_eq!(res.session_id, Some("session-b".to_string()));
        assert_eq!(res.cwd, "/project/app2");
    }

    #[test]
    fn test_find_by_cwd_prefers_fresh_child_over_stale_exact() {
        let mut store = StateStore::new_in_memory();
        use std::thread;
        use std::time::Duration;

        // Stale exact match at /project
        store.update("stale-parent", ClaudeState::Ready, "/project");

        thread::sleep(Duration::from_millis(10));

        // Fresh child at /project/child
        store.update("fresh-child", ClaudeState::Working, "/project/child");

        // Query /project should return the fresher child, not stale exact match
        let record = store.find_by_cwd("/project").unwrap();
        assert_eq!(record.session_id, "fresh-child");
        assert_eq!(record.cwd, "/project/child");
    }

    #[test]
    fn test_resolver_returns_locked_child_state_when_stale_exact_is_newer() {
        // Edge case: Stale exact record has newer timestamp than locked child record
        // Resolver should return the child's state (lock wins over timestamp)
        let temp = tempdir().unwrap();
        let live_pid = std::process::id();
        let dead_pid = 99999999;

        use std::thread;
        use std::time::Duration;

        let mut store = StateStore::new_in_memory();

        // Create child session with lock first (older timestamp)
        store.update("child-session", ClaudeState::Working, "/project/child");
        store.set_pid_for_test("child-session", live_pid);
        create_lock(temp.path(), live_pid, "/project/child");

        thread::sleep(Duration::from_millis(10));

        // Create stale exact record with newer timestamp but dead PID (no lock)
        store.update("stale-parent", ClaudeState::Ready, "/project");
        store.set_pid_for_test("stale-parent", dead_pid);

        // Query for /project:
        // - find_by_cwd returns stale-parent (newer timestamp, exact match)
        // - But lock at /project/child belongs to child-session
        // - Resolver should search for child-session and return its state
        let resolved = resolve_state_with_details(temp.path(), &store, "/project");

        let res = resolved.expect("Should find resolved state");
        // Should return child-session's state, not stale-parent's state
        assert_eq!(res.state, ClaudeState::Working);
        assert_eq!(res.session_id, Some("child-session".to_string()));
        assert_eq!(res.cwd, "/project/child");
    }

    #[test]
    fn test_resolver_picks_freshest_when_multiple_records_share_pid_and_path() {
        // When multiple records have same PID+path (due to stale cleanup lag),
        // resolver should pick the freshest one by updated_at
        let temp = tempdir().unwrap();
        let live_pid = std::process::id();

        use std::thread;
        use std::time::Duration;

        let mut store = StateStore::new_in_memory();

        // Create old record at /project with live PID
        store.update("old-session", ClaudeState::Ready, "/project");
        store.set_pid_for_test("old-session", live_pid);

        thread::sleep(Duration::from_millis(10));

        // Create fresh record at /project with same PID (stale cleanup hasn't run)
        store.update("new-session", ClaudeState::Working, "/project");
        store.set_pid_for_test("new-session", live_pid);

        create_lock(temp.path(), live_pid, "/project");

        // Query should return the fresher record's state
        let resolved = resolve_state_with_details(temp.path(), &store, "/project");

        let res = resolved.expect("Should find resolved state");
        // Should return new-session's state (Working), not old-session's (Ready)
        assert_eq!(res.state, ClaudeState::Working);
        assert_eq!(res.session_id, Some("new-session".to_string()));
    }

    #[test]
    fn test_resolver_handles_cd_within_session() {
        // When user runs cd within a Claude session, lock stays at original path
        // but state record updates to new path. Resolver should match them.
        let temp = tempdir().unwrap();
        let live_pid = std::process::id();

        let mut store = StateStore::new_in_memory();

        // Lock created at /project
        create_lock(temp.path(), live_pid, "/project");

        // State record updated to /project/subdir (after cd)
        store.update("session", ClaudeState::Working, "/project/subdir");
        store.set_pid_for_test("session", live_pid);

        // Query for /project should find the lock and match it to the record
        // despite path mismatch (cd scenario)
        let resolved = resolve_state_with_details(temp.path(), &store, "/project");

        let res = resolved.expect("Should find resolved state");
        assert_eq!(res.state, ClaudeState::Working);
        assert_eq!(res.session_id, Some("session".to_string()));
        assert_eq!(res.cwd, "/project"); // Lock's path, not record's cwd
    }

    #[test]
    fn test_resolver_handles_cd_up_to_parent() {
        // When user runs cd .. within session, lock stays at subdir but record moves to parent
        let temp = tempdir().unwrap();
        let live_pid = std::process::id();

        let mut store = StateStore::new_in_memory();

        // Lock created at /project/subdir (where session started)
        create_lock(temp.path(), live_pid, "/project/subdir");

        // State record updated to /project (after cd ..)
        store.update("session", ClaudeState::Working, "/project");
        store.set_pid_for_test("session", live_pid);

        // Query for /project should find the lock and match it to the record
        // (parent match scenario)
        let resolved = resolve_state_with_details(temp.path(), &store, "/project");

        let res = resolved.expect("Should find resolved state");
        assert_eq!(res.state, ClaudeState::Working);
        assert_eq!(res.session_id, Some("session".to_string()));
    }

    #[test]
    fn test_resolver_prioritizes_freshness_over_match_type() {
        // When PID reuse occurs, fresher record should win even if stale has exact match
        let temp = tempdir().unwrap();
        let live_pid = std::process::id();

        use std::thread;
        use std::time::Duration;

        let mut store = StateStore::new_in_memory();

        // Old stale record at exact lock path
        store.update("stale-exact", ClaudeState::Ready, "/project");
        store.set_pid_for_test("stale-exact", live_pid);

        thread::sleep(Duration::from_millis(10));

        // Fresh record at child path (cd scenario)
        store.update("fresh-child", ClaudeState::Working, "/project/subdir");
        store.set_pid_for_test("fresh-child", live_pid);

        create_lock(temp.path(), live_pid, "/project");

        // Resolver should prefer fresh-child despite stale-exact having exact match
        let resolved = resolve_state_with_details(temp.path(), &store, "/project");

        let res = resolved.expect("Should find resolved state");
        // Should return fresh-child's state (Working), not stale-exact's (Ready)
        assert_eq!(res.state, ClaudeState::Working);
        assert_eq!(res.session_id, Some("fresh-child".to_string()));
    }

    #[test]
    fn test_resolver_uses_session_id_as_stable_tiebreaker() {
        // When timestamps are identical, use session_id for deterministic selection
        let temp = tempdir().unwrap();
        let live_pid = std::process::id();

        let mut store = StateStore::new_in_memory();

        // Both records created at same timestamp with same PID
        let now = chrono::Utc::now();

        store.update("session-a", ClaudeState::Ready, "/project");
        store.set_pid_for_test("session-a", live_pid);
        store.set_timestamp_for_test("session-a", now);

        store.update("session-z", ClaudeState::Working, "/project");
        store.set_pid_for_test("session-z", live_pid);
        store.set_timestamp_for_test("session-z", now);

        create_lock(temp.path(), live_pid, "/project");

        // Should pick session-z (alphabetically later) deterministically
        let resolved = resolve_state_with_details(temp.path(), &store, "/project");

        let res = resolved.expect("Should find resolved state");
        assert_eq!(res.session_id, Some("session-z".to_string()));
        assert_eq!(res.state, ClaudeState::Working);
    }

    // Note: Sibling matching (cd ../sibling) was removed due to cross-project contamination risk.
    // Without project-level configuration, depth-based guards cannot reliably prevent
    // PID reuse from pairing sessions across different projects that share a parent directory.

    #[test]
    fn test_resolver_handles_trailing_slashes() {
        // Paths with trailing slashes should be normalized correctly
        let temp = tempdir().unwrap();
        let live_pid = std::process::id();

        let mut store = StateStore::new_in_memory();

        // Lock at path with trailing slash
        create_lock(temp.path(), live_pid, "/project/");

        // Record without trailing slash (should still match)
        store.update("session", ClaudeState::Working, "/project");
        store.set_pid_for_test("session", live_pid);

        let resolved = resolve_state_with_details(temp.path(), &store, "/project");

        let res = resolved.expect("Should find resolved state");
        assert_eq!(res.state, ClaudeState::Working);
        assert_eq!(res.session_id, Some("session".to_string()));
    }

    #[test]
    fn test_resolver_handles_root_path() {
        // Root path (/) should not collapse to empty string
        let temp = tempdir().unwrap();
        let live_pid = std::process::id();

        let mut store = StateStore::new_in_memory();

        // Lock at root
        create_lock(temp.path(), live_pid, "/");

        // Record at root (should match exactly, not as child of empty)
        store.update("session", ClaudeState::Working, "/");
        store.set_pid_for_test("session", live_pid);

        let resolved = resolve_state_with_details(temp.path(), &store, "/");

        let res = resolved.expect("Should find resolved state");
        assert_eq!(res.state, ClaudeState::Working);
        assert_eq!(res.session_id, Some("session".to_string()));
    }


    #[test]
    fn test_root_cd_into_child() {
        // cd from / to /foo should match correctly
        let temp = tempdir().unwrap();
        let live_pid = std::process::id();

        let mut store = StateStore::new_in_memory();

        // Lock at / (root)
        create_lock(temp.path(), live_pid, "/");

        // Record updated to /foo after cd
        store.update("session", ClaudeState::Working, "/foo");
        store.set_pid_for_test("session", live_pid);

        // Query for / should find the session (child makes parent active)
        let resolved = resolve_state_with_details(temp.path(), &store, "/");

        let res = resolved.expect("Should find session");
        assert_eq!(res.state, ClaudeState::Working);
        assert_eq!(res.session_id, Some("session".to_string()));
        // cwd comes from the lock, which is at /
        assert_eq!(res.cwd, "/");
    }

    #[test]
    fn test_root_cd_from_child() {
        // cd from /foo to / should match correctly
        let temp = tempdir().unwrap();
        let live_pid = std::process::id();

        let mut store = StateStore::new_in_memory();

        // Lock at /foo
        create_lock(temp.path(), live_pid, "/foo");

        // Record updated to / after cd ..
        store.update("session", ClaudeState::Working, "/");
        store.set_pid_for_test("session", live_pid);

        // Better test: Query for / (the actual cwd), which has a child lock at /foo
        let resolved = resolve_state_with_details(temp.path(), &store, "/");

        let res = resolved.expect("Should find session");
        assert_eq!(res.state, ClaudeState::Working);
        assert_eq!(res.session_id, Some("session".to_string()));
        assert_eq!(res.cwd, "/foo");  // cwd from the child lock
    }

    #[test]
    fn test_multi_lock_cd_scenario() {
        // Multiple child locks from same session (after cd) + newer lock should be picked
        let temp = tempdir().unwrap();
        let live_pid = std::process::id();

        let mut store = StateStore::new_in_memory();

        // Use actual process start time for verification to work
        // Can't create locks with mismatched timestamps anymore due to PID verification
        // So we create locks with same timestamp and rely on path tie-breaker
        let start_time = get_process_start_time(live_pid).unwrap();
        create_lock_with_timestamp(temp.path(), live_pid, "/project/dir1", start_time);
        create_lock_with_timestamp(temp.path(), live_pid, "/project/dir2", start_time);

        // Session has cd'd to /project/dir3
        store.update("session-1", ClaudeState::Working, "/project/dir3");
        store.set_pid_for_test("session-1", live_pid);

        // Query for /project should find session-1
        let resolved = resolve_state_with_details(temp.path(), &store, "/project");

        let res = resolved.expect("Should find session-1");
        assert_eq!(res.state, ClaudeState::Working);
        assert_eq!(res.session_id, Some("session-1".to_string()));
        // Should use the newer lock (/project/dir2) since both have same PID
        assert_eq!(res.cwd, "/project/dir2");
    }

    #[test]
    fn test_root_cd_to_nested_path() {
        // cd from / to nested path like /foo/bar should match correctly
        let temp = tempdir().unwrap();
        let live_pid = std::process::id();

        let mut store = StateStore::new_in_memory();

        // Lock at / (root)
        create_lock(temp.path(), live_pid, "/");

        // Record updated to nested path /foo/bar after cd
        store.update("session", ClaudeState::Working, "/foo/bar");
        store.set_pid_for_test("session", live_pid);

        // Query for / should find the session (any descendant makes parent active)
        let resolved = resolve_state_with_details(temp.path(), &store, "/");

        let res = resolved.expect("Should find session");
        assert_eq!(res.state, ClaudeState::Working);
        assert_eq!(res.session_id, Some("session".to_string()));
        assert_eq!(res.cwd, "/");  // cwd from the lock at root
    }

    #[test]
    fn test_nested_path_cd_to_root() {
        // cd from /foo/bar to / should match correctly
        let temp = tempdir().unwrap();
        let live_pid = std::process::id();

        let mut store = StateStore::new_in_memory();

        // Lock at /foo/bar
        create_lock(temp.path(), live_pid, "/foo/bar");

        // Record updated to / after cd
        store.update("session", ClaudeState::Working, "/");
        store.set_pid_for_test("session", live_pid);

        // Query for / should find the session (child lock makes parent active)
        let resolved = resolve_state_with_details(temp.path(), &store, "/");

        let res = resolved.expect("Should find session");
        assert_eq!(res.state, ClaudeState::Working);
        assert_eq!(res.session_id, Some("session".to_string()));
        assert_eq!(res.cwd, "/foo/bar");  // cwd from the child lock
    }

}


