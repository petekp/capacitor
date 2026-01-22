//! Resolves session state by combining lock liveness with stored records.
//!
//! v3: the state store is the source of truth for the last known state, and Claude Code lock
//! directories indicate liveness. We do **not** rely on PIDs in the state store.

use std::path::Path;

use crate::types::SessionState;

use super::lock::{find_matching_child_lock, is_session_running};
use super::store::StateStore;
use super::types::SessionRecord;

/// A resolved state for a project query.
#[derive(Debug, Clone)]
pub struct ResolvedState {
    pub state: SessionState,
    pub session_id: Option<String>,
    /// Effective cwd for the active session (from lock metadata).
    pub cwd: String,
}

/// Find the best record to associate with a given lock path.
/// Prefers fresher records, then closer path match (exact > child > parent), then session_id.
fn find_record_for_lock_path<'a>(
    store: &'a StateStore,
    lock_path: &str,
) -> Option<&'a SessionRecord> {
    #[derive(PartialEq, Eq, PartialOrd, Ord, Clone, Copy)]
    enum MatchType {
        Parent = 0,
        Child = 1,
        Exact = 2,
    }

    let lock_path_normalized = if lock_path == "/" {
        "/"
    } else {
        lock_path.trim_end_matches('/')
    };

    let mut best: Option<(&SessionRecord, MatchType)> = None;

    for record in store.all_sessions() {
        if record.is_stale() {
            continue;
        }

        // Consider both record.cwd and record.project_dir for matching.
        // Claude Code locks are keyed by a stable project path; some hook events may omit/shift cwd.
        let mut best_match_for_record: Option<MatchType> = None;
        for candidate in [Some(record.cwd.as_str()), record.project_dir.as_deref()]
            .into_iter()
            .flatten()
        {
            let record_path_normalized = if candidate == "/" {
                "/"
            } else {
                candidate.trim_end_matches('/')
            };

            let match_type = if record_path_normalized == lock_path_normalized {
                Some(MatchType::Exact)
            } else if lock_path_normalized == "/" {
                if record_path_normalized.starts_with("/") && record_path_normalized != "/" {
                    Some(MatchType::Child)
                } else {
                    None
                }
            } else if record_path_normalized == "/" {
                if lock_path_normalized.starts_with("/") && lock_path_normalized != "/" {
                    Some(MatchType::Parent)
                } else {
                    None
                }
            } else if record_path_normalized.starts_with(&format!("{}/", lock_path_normalized)) {
                Some(MatchType::Child)
            } else if lock_path_normalized.starts_with(&format!("{}/", record_path_normalized)) {
                Some(MatchType::Parent)
            } else {
                None
            };

            if let Some(mt) = match_type {
                best_match_for_record = Some(best_match_for_record.map_or(mt, |cur| cur.max(mt)));
            }
        }

        if let Some(current_match_type) = best_match_for_record {
            match best {
                None => best = Some((record, current_match_type)),
                Some((current, current_type)) => {
                    let should_replace = record.updated_at > current.updated_at
                        || (record.updated_at == current.updated_at
                            && current_match_type > current_type)
                        || (record.updated_at == current.updated_at
                            && current_match_type == current_type
                            && record.session_id > current.session_id);

                    if should_replace {
                        best = Some((record, current_match_type));
                    }
                }
            }
        }
    }

    best.map(|(r, _)| r)
}

pub fn resolve_state(
    lock_dir: &Path,
    store: &StateStore,
    project_path: &str,
) -> Option<SessionState> {
    resolve_state_with_details(lock_dir, store, project_path).map(|r| r.state)
}

/// Resolve state for a project path.
///
/// Returns `None` when no lock exists (neither exact nor child) for the query path.
pub fn resolve_state_with_details(
    lock_dir: &Path,
    store: &StateStore,
    project_path: &str,
) -> Option<ResolvedState> {
    if !is_session_running(lock_dir, project_path) {
        return None;
    }

    // Pick the newest matching lock among exact + child locks.
    let lock = find_matching_child_lock(lock_dir, project_path, None, None)?;
    let record = find_record_for_lock_path(store, &lock.path);

    Some(ResolvedState {
        state: record.map_or(SessionState::Ready, |r| r.state),
        session_id: record.map(|r| r.session_id.clone()),
        cwd: lock.path,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::lock::tests_helper::create_lock;
    use crate::state::StateStore;
    use crate::types::SessionState;
    use tempfile::tempdir;

    #[test]
    fn resolve_none_when_not_running() {
        let temp = tempdir().unwrap();
        let store = StateStore::new_in_memory();
        assert_eq!(resolve_state(temp.path(), &store, "/project"), None);
    }

    #[test]
    fn resolve_ready_when_running_but_no_record() {
        let temp = tempdir().unwrap();
        create_lock(temp.path(), std::process::id(), "/project");
        let store = StateStore::new_in_memory();
        let resolved = resolve_state_with_details(temp.path(), &store, "/project").unwrap();
        assert_eq!(resolved.state, SessionState::Ready);
        assert!(resolved.session_id.is_none());
        assert_eq!(resolved.cwd, "/project");
    }

    #[test]
    fn resolve_uses_record_state_when_running() {
        let temp = tempdir().unwrap();
        create_lock(temp.path(), std::process::id(), "/project");
        let mut store = StateStore::new_in_memory();
        store.update("s1", SessionState::Working, "/project");
        let resolved = resolve_state_with_details(temp.path(), &store, "/project").unwrap();
        assert_eq!(resolved.state, SessionState::Working);
        assert_eq!(resolved.session_id.as_deref(), Some("s1"));
    }

    #[test]
    fn parent_query_inherits_child_lock_and_child_record() {
        let temp = tempdir().unwrap();
        create_lock(temp.path(), std::process::id(), "/project/apps/swift");
        let mut store = StateStore::new_in_memory();
        store.update("child", SessionState::Working, "/project/apps/swift");
        let resolved = resolve_state_with_details(temp.path(), &store, "/project").unwrap();
        assert_eq!(resolved.state, SessionState::Working);
        assert_eq!(resolved.session_id.as_deref(), Some("child"));
        assert_eq!(resolved.cwd, "/project/apps/swift");
    }

    #[test]
    fn resolve_matches_record_by_project_dir_when_cwd_is_unrelated() {
        let temp = tempdir().unwrap();
        create_lock(temp.path(), std::process::id(), "/project");

        let mut store = StateStore::new_in_memory();
        store.update("s1", SessionState::Working, "/wrong");
        store.set_project_dir_for_test("s1", Some("/project"));

        let resolved = resolve_state_with_details(temp.path(), &store, "/project").unwrap();
        assert_eq!(resolved.state, SessionState::Working);
        assert_eq!(resolved.session_id.as_deref(), Some("s1"));
    }
}
