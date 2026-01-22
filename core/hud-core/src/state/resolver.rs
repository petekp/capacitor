//! Resolves session state by combining lock liveness with stored records.
//!
//! v3: the state store is the source of truth for the last known state, and Claude Code lock
//! directories indicate liveness. We do **not** rely on PIDs in the state store.
//!
//! Fresh record fallback: If no lock exists but a record is very recent (< 30s),
//! trust the record. This handles edge cases where locks don't exist but records are fresh.

use std::path::Path;
use std::time::Duration;

use chrono::Utc;

use crate::types::SessionState;

use super::lock::{find_matching_child_lock, is_session_running};
use super::store::StateStore;
use super::types::SessionRecord;

/// How long to trust a record without a lock (handles transient lock absence)
const FRESH_RECORD_TTL: Duration = Duration::from_secs(30);

/// A resolved state for a project query.
#[derive(Debug, Clone)]
pub struct ResolvedState {
    pub state: SessionState,
    pub session_id: Option<String>,
    /// Effective cwd for the active session (from lock metadata or record cwd).
    pub cwd: String,
    /// Whether this resolution came from a lock (true) or fresh record fallback (false).
    pub is_from_lock: bool,
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

    let mut best: Option<(&SessionRecord, MatchType, bool)> = None;

    for record in store.all_sessions() {
        let record_is_stale = record.is_stale();

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
                None => best = Some((record, current_match_type, record_is_stale)),
                Some((current, current_type, current_is_stale)) => {
                    let should_replace = if current_is_stale && !record_is_stale {
                        true
                    } else if !current_is_stale && record_is_stale {
                        false
                    } else {
                        record.updated_at > current.updated_at
                            || (record.updated_at == current.updated_at
                                && current_match_type > current_type)
                            || (record.updated_at == current.updated_at
                                && current_match_type == current_type
                                && record.session_id > current.session_id)
                    };

                    if should_replace {
                        best = Some((record, current_match_type, record_is_stale));
                    }
                }
            }
        }
    }

    best.map(|(r, _, _)| r)
}

/// Find an exact or child record (NOT parent) for the fresh record fallback.
/// This is more restrictive than `store.find_by_cwd()` which allows parent matching.
fn find_exact_or_child_record<'a>(
    store: &'a StateStore,
    project_path: &str,
) -> Option<&'a SessionRecord> {
    let project_normalized = if project_path == "/" {
        "/"
    } else {
        project_path.trim_end_matches('/')
    };

    let mut best: Option<&SessionRecord> = None;

    for record in store.all_sessions() {
        let record_cwd_normalized = if record.cwd == "/" {
            "/"
        } else {
            record.cwd.trim_end_matches('/')
        };

        // Exact match
        if record_cwd_normalized == project_normalized {
            match best {
                None => best = Some(record),
                Some(current) if record.updated_at > current.updated_at => best = Some(record),
                _ => {}
            }
            continue;
        }

        // Child match (record.cwd is under project_path)
        let is_child = if project_normalized == "/" {
            record_cwd_normalized != "/" && record_cwd_normalized.starts_with('/')
        } else {
            record_cwd_normalized.starts_with(&format!("{}/", project_normalized))
        };

        if is_child {
            match best {
                None => best = Some(record),
                Some(current) if record.updated_at > current.updated_at => best = Some(record),
                _ => {}
            }
        }

        // Explicitly NOT checking parent matches
    }

    best
}

/// Check if a record is fresh enough to trust without a lock
fn is_record_fresh(record: &SessionRecord) -> bool {
    let age_secs = Utc::now()
        .signed_duration_since(record.updated_at)
        .num_seconds();
    if age_secs < 0 {
        return true; // Future timestamp - trust it
    }
    (age_secs as u64) <= FRESH_RECORD_TTL.as_secs()
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
/// Returns `None` when no lock exists (neither exact nor child) for the query path
/// AND no fresh record exists as a fallback.
pub fn resolve_state_with_details(
    lock_dir: &Path,
    store: &StateStore,
    project_path: &str,
) -> Option<ResolvedState> {
    // Primary path: check for active lock
    if is_session_running(lock_dir, project_path) {
        // Pick the newest matching lock among exact + child locks.
        let lock = find_matching_child_lock(lock_dir, project_path, None, None)?;
        let record = find_record_for_lock_path(store, &lock.path);
        let (state, session_id) = match record {
            Some(r) if r.is_stale() => (SessionState::Ready, Some(r.session_id.clone())),
            Some(r) => (r.state, Some(r.session_id.clone())),
            None => (SessionState::Ready, None),
        };

        return Some(ResolvedState {
            state,
            session_id,
            cwd: lock.path,
            is_from_lock: true,
        });
    }

    // Fallback: trust fresh records even without locks
    // This handles edge cases where:
    // - Lock creation is in progress (race condition)
    // - Lock was cleaned up but session is still active
    // - Hook fired but lock holder hasn't spawned yet
    //
    // IMPORTANT: Only use exact/child matches for fresh record fallback.
    // Parent matches (session at /parent, query for /parent/child) should NOT apply
    // without a lock - this preserves the original behavior.
    let record = find_exact_or_child_record(store, project_path)?;
    if is_record_fresh(record) && record.state != SessionState::Idle {
        return Some(ResolvedState {
            state: record.state,
            session_id: Some(record.session_id.clone()),
            cwd: record.cwd.clone(),
            is_from_lock: false,
        });
    }

    None
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
        assert!(resolved.is_from_lock);
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

    #[test]
    fn fresh_record_fallback_when_no_lock() {
        let temp = tempdir().unwrap();
        // No lock created
        let mut store = StateStore::new_in_memory();
        store.update("s1", SessionState::Working, "/project");
        // Record is fresh (just created), so fallback should work
        let resolved = resolve_state_with_details(temp.path(), &store, "/project").unwrap();
        assert_eq!(resolved.state, SessionState::Working);
        assert_eq!(resolved.session_id.as_deref(), Some("s1"));
        assert!(!resolved.is_from_lock); // Fresh record fallback, not from lock
    }

    #[test]
    fn stale_record_no_fallback_when_no_lock() {
        let temp = tempdir().unwrap();
        // No lock created
        let mut store = StateStore::new_in_memory();
        store.update("s1", SessionState::Working, "/project");
        // Make the record stale (older than FRESH_RECORD_TTL)
        let old_time = Utc::now() - chrono::Duration::seconds(60);
        store.set_timestamp_for_test("s1", old_time);
        // Should return None since record is stale and no lock exists
        let resolved = resolve_state_with_details(temp.path(), &store, "/project");
        assert!(resolved.is_none());
    }
}
