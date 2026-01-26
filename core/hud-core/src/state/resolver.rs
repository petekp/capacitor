//! Resolves session state by combining lock liveness with stored records.
//!
//! v3: the state store is the source of truth for the last known state, and Claude Code lock
//! directories indicate liveness. We do **not** rely on PIDs in the state store.

use std::path::Path;

use crate::types::SessionState;

use super::lock::{find_matching_child_lock, is_session_running};
use super::store::StateStore;
use super::types::SessionRecord;

/// Normalizes a path for consistent comparison.
/// Strips trailing slashes except for root "/".
fn normalize_path(path: &str) -> &str {
    if path == "/" {
        "/"
    } else {
        path.trim_end_matches('/')
    }
}

/// A resolved state for a project query.
#[derive(Debug, Clone)]
pub struct ResolvedState {
    pub state: SessionState,
    pub session_id: Option<String>,
    /// Effective cwd for the active session (from lock metadata or state record).
    pub cwd: String,
    /// True if this state was resolved via a lock file (vs fresh record fallback).
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

    let lock_path_normalized = normalize_path(lock_path);

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
            let record_path_normalized = normalize_path(candidate);

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

        if let Some(new_match_type) = best_match_for_record {
            match best {
                None => best = Some((record, new_match_type, record_is_stale)),
                Some((best_record, best_match_type, best_is_stale)) => {
                    // Priority order:
                    // 1. Match type (Exact > Child > Parent) - most important
                    // 2. Staleness (non-stale > stale)
                    // 3. Timestamp (fresher > older)
                    // 4. Session ID (lexicographic tiebreaker)
                    let should_replace = if new_match_type > best_match_type {
                        // New record has better match type (Exact > Child > Parent) - replace
                        true
                    } else if new_match_type < best_match_type {
                        // Existing best has better match type - don't replace
                        false
                    } else if best_is_stale && !record_is_stale {
                        // Same match type, prefer non-stale
                        true
                    } else if !best_is_stale && record_is_stale {
                        false
                    } else {
                        // Same match type and staleness, prefer fresher timestamp
                        record.updated_at > best_record.updated_at
                            || (record.updated_at == best_record.updated_at
                                && record.session_id > best_record.session_id)
                    };

                    if should_replace {
                        best = Some((record, new_match_type, record_is_stale));
                    }
                }
            }
        }
    }

    best.map(|(r, _, _)| r)
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
/// Returns `None` when no lock exists (neither exact nor child) for the query path,
/// unless a fresh state record exists (fallback for edge cases where locks are missing).
///
/// # Staleness Recovery
///
/// Active states (Working, Waiting, Compacting) fall back to Ready when stale.
/// This handles user interruptions (Escape key, cancel) where no hook event fires.
/// See [`super::types::ACTIVE_STATE_STALE_SECS`] for the threshold.
pub fn resolve_state_with_details(
    lock_dir: &Path,
    store: &StateStore,
    project_path: &str,
) -> Option<ResolvedState> {
    if is_session_running(lock_dir, project_path) {
        // Lock exists - use it as primary source
        // The lock proves Claude is running (lock holder monitors PID), so we trust the
        // recorded state even if the timestamp is stale. Active state staleness checks
        // are only for detecting user interrupts when NO lock exists.
        let lock = find_matching_child_lock(lock_dir, project_path, None, None)?;
        let record = find_record_for_lock_path(store, &lock.path);
        let (state, session_id) = match record {
            Some(r) => (r.state, Some(r.session_id.clone())),
            // No record but lock exists - session is active, just no state written yet
            None => (SessionState::Ready, None),
        };

        return Some(ResolvedState {
            state,
            session_id,
            cwd: lock.path,
            is_from_lock: true,
        });
    }

    // No lock - check for fresh state record as fallback (exact or child matches only)
    // This handles edge cases where locks aren't created but state is written
    // We intentionally exclude parent matches to prevent child paths from inheriting parent state
    if let Some(record) = find_fresh_record_for_path(store, project_path) {
        // Active state staleness - likely user interrupted
        let state = if record.is_active_state_stale() {
            SessionState::Ready
        } else {
            record.state
        };
        return Some(ResolvedState {
            state,
            session_id: Some(record.session_id.clone()),
            cwd: record.cwd.clone(),
            is_from_lock: false,
        });
    }

    // Final fallback: check for stale Ready records
    // These are sessions that were Ready but haven't had activity in 5+ minutes.
    // We return them so sessions.rs can apply the 15-min Ready→Idle threshold.
    // Without this, Ready sessions would immediately become Idle after 5 minutes.
    if let Some(record) = find_stale_ready_record_for_path(store, project_path) {
        return Some(ResolvedState {
            state: SessionState::Ready,
            session_id: Some(record.session_id.clone()),
            cwd: record.cwd.clone(),
            is_from_lock: false,
        });
    }

    None
}

/// Find a fresh (non-stale) record that matches the given path.
/// Only considers exact matches and child matches, NOT parent matches.
/// This prevents child paths from incorrectly inheriting parent session state.
fn find_fresh_record_for_path<'a>(
    store: &'a StateStore,
    project_path: &str,
) -> Option<&'a SessionRecord> {
    let path_normalized = normalize_path(project_path);

    let mut best: Option<&SessionRecord> = None;

    for record in store.all_sessions() {
        if record.is_stale() {
            continue;
        }

        // Check both cwd and project_dir for matching
        let is_match = [Some(record.cwd.as_str()), record.project_dir.as_deref()]
            .into_iter()
            .flatten()
            .any(|record_path| {
                let record_normalized = normalize_path(record_path);

                // Exact match
                if record_normalized == path_normalized {
                    return true;
                }

                // Child match: record is in a subdirectory of the query path
                // e.g., query="/project", record.cwd="/project/src"
                if path_normalized == "/" {
                    record_normalized != "/" && record_normalized.starts_with("/")
                } else {
                    record_normalized.starts_with(&format!("{}/", path_normalized))
                }
            });

        if is_match {
            match best {
                None => best = Some(record),
                Some(current) if record.updated_at > current.updated_at => best = Some(record),
                _ => {}
            }
        }
    }

    best
}

/// Find a stale Ready record that matches the given path.
/// This is the final fallback for sessions that were Ready but haven't had activity recently.
/// By returning these, we allow sessions.rs to apply the 15-minute Ready→Idle threshold
/// instead of immediately treating them as Idle after 5 minutes.
fn find_stale_ready_record_for_path<'a>(
    store: &'a StateStore,
    project_path: &str,
) -> Option<&'a SessionRecord> {
    let path_normalized = normalize_path(project_path);

    let mut best: Option<&SessionRecord> = None;

    for record in store.all_sessions() {
        // Only consider stale Ready records
        if !record.is_stale() || record.state != SessionState::Ready {
            continue;
        }

        // Check both cwd and project_dir for matching
        let is_match = [Some(record.cwd.as_str()), record.project_dir.as_deref()]
            .into_iter()
            .flatten()
            .any(|record_path| {
                let record_normalized = normalize_path(record_path);

                // Exact match
                if record_normalized == path_normalized {
                    return true;
                }

                // Child match: record is in a subdirectory of the query path
                if path_normalized == "/" {
                    record_normalized != "/" && record_normalized.starts_with("/")
                } else {
                    record_normalized.starts_with(&format!("{}/", path_normalized))
                }
            });

        if is_match {
            match best {
                None => best = Some(record),
                Some(current) if record.updated_at > current.updated_at => best = Some(record),
                _ => {}
            }
        }
    }

    best
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::lock::tests_helper::create_lock;
    use crate::state::StateStore;
    use crate::types::SessionState;
    use chrono::{Duration, Utc};
    use tempfile::tempdir;

    #[test]
    fn resolve_none_when_not_running_and_no_record() {
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

    #[test]
    fn resolve_fresh_record_without_lock() {
        let temp = tempdir().unwrap();
        let mut store = StateStore::new_in_memory();
        store.update("s1", SessionState::Working, "/project");
        // No lock created - but record is fresh
        let resolved = resolve_state_with_details(temp.path(), &store, "/project").unwrap();
        assert_eq!(resolved.state, SessionState::Working);
        assert_eq!(resolved.session_id.as_deref(), Some("s1"));
    }

    #[test]
    fn resolve_none_for_stale_working_record_without_lock() {
        // Stale Working records without lock are not trusted
        let temp = tempdir().unwrap();
        let mut store = StateStore::new_in_memory();
        store.update("s1", SessionState::Working, "/project");
        // Make record stale
        let stale_time = Utc::now() - Duration::minutes(10);
        store.set_timestamp_for_test("s1", stale_time);
        // No lock and stale Working record = not running
        assert!(resolve_state_with_details(temp.path(), &store, "/project").is_none());
    }

    #[test]
    fn resolve_ready_for_stale_ready_record_without_lock() {
        // Stale Ready records without lock are returned so the 15-min threshold can be applied
        let temp = tempdir().unwrap();
        let mut store = StateStore::new_in_memory();
        store.update("s1", SessionState::Ready, "/project");
        // Make record stale (> 5 min)
        let stale_time = Utc::now() - Duration::minutes(10);
        store.set_timestamp_for_test("s1", stale_time);
        // No lock but stale Ready record = Ready (for 15-min threshold in sessions.rs)
        let resolved = resolve_state_with_details(temp.path(), &store, "/project").unwrap();
        assert_eq!(resolved.state, SessionState::Ready);
        assert_eq!(resolved.session_id.as_deref(), Some("s1"));
        assert!(!resolved.is_from_lock); // Not from lock - allows 15-min threshold
    }

    #[test]
    fn resolve_working_for_stale_record_with_lock() {
        let temp = tempdir().unwrap();
        create_lock(temp.path(), std::process::id(), "/project");
        let mut store = StateStore::new_in_memory();
        store.update("s1", SessionState::Working, "/project");
        // Make record stale (10 minutes old)
        let stale_time = Utc::now() - Duration::minutes(10);
        store.set_timestamp_for_test("s1", stale_time);
        // Lock exists → trust the recorded state even if timestamp is stale
        // The lock proves Claude is running; stale timestamp just means no tools used recently
        let resolved = resolve_state_with_details(temp.path(), &store, "/project").unwrap();
        assert_eq!(resolved.state, SessionState::Working);
        assert_eq!(resolved.session_id.as_deref(), Some("s1"));
        assert!(resolved.is_from_lock);
    }

    #[test]
    fn resolve_working_for_active_state_stale_with_lock() {
        use crate::state::types::ACTIVE_STATE_STALE_SECS;

        let temp = tempdir().unwrap();
        create_lock(temp.path(), std::process::id(), "/project");
        let mut store = StateStore::new_in_memory();
        store.update("s1", SessionState::Working, "/project");
        // Make record stale by active state threshold (35 seconds)
        let stale_time = Utc::now() - Duration::seconds(ACTIVE_STATE_STALE_SECS + 5);
        store.set_timestamp_for_test("s1", stale_time);
        // Lock exists → trust the recorded state
        // During tool-free text generation, no hooks fire to refresh the timestamp,
        // but the lock proves Claude is still actively generating
        let resolved = resolve_state_with_details(temp.path(), &store, "/project").unwrap();
        assert_eq!(resolved.state, SessionState::Working);
        assert_eq!(resolved.session_id.as_deref(), Some("s1"));
        assert!(resolved.is_from_lock);
    }

    #[test]
    fn resolve_working_when_fresh_active_state_with_lock() {
        use crate::state::types::ACTIVE_STATE_STALE_SECS;

        let temp = tempdir().unwrap();
        create_lock(temp.path(), std::process::id(), "/project");
        let mut store = StateStore::new_in_memory();
        store.update("s1", SessionState::Working, "/project");
        // Recent timestamp (within active state threshold)
        let fresh_time = Utc::now() - Duration::seconds(ACTIVE_STATE_STALE_SECS - 5);
        store.set_timestamp_for_test("s1", fresh_time);
        // Lock exists and Working state is fresh = Working
        let resolved = resolve_state_with_details(temp.path(), &store, "/project").unwrap();
        assert_eq!(resolved.state, SessionState::Working);
    }

    #[test]
    fn exact_match_beats_parent_match_regardless_of_timestamp() {
        // Regression test: a fresh parent-path record should NOT beat a stale exact-match record.
        // This bug caused child projects to show "Working" when an unrelated session
        // in a parent directory (e.g., ~/) was active.
        let temp = tempdir().unwrap();

        // Lock exists for child project
        create_lock(temp.path(), std::process::id(), "/Users/pete/Code/project");

        let mut store = StateStore::new_in_memory();

        // Exact match record (stale) - this should win
        store.update(
            "exact-session",
            SessionState::Ready,
            "/Users/pete/Code/project",
        );
        let stale_time = Utc::now() - Duration::minutes(10);
        store.set_timestamp_for_test("exact-session", stale_time);

        // Parent match record (fresh) - this should NOT win despite fresher timestamp
        store.update("parent-session", SessionState::Working, "/Users/pete");
        // parent-session has default "now" timestamp, so it's fresher

        let resolved =
            resolve_state_with_details(temp.path(), &store, "/Users/pete/Code/project").unwrap();

        // The exact match should be selected, not the fresher parent match
        assert_eq!(
            resolved.session_id.as_deref(),
            Some("exact-session"),
            "Exact match should beat parent match regardless of timestamp"
        );
        assert_eq!(
            resolved.state,
            SessionState::Ready,
            "State should be from exact-match record"
        );
    }

    #[test]
    fn child_match_beats_parent_match_regardless_of_timestamp() {
        // Similar to exact_match test but for child matches
        let temp = tempdir().unwrap();

        // Lock exists for parent project (querying from parent)
        create_lock(
            temp.path(),
            std::process::id(),
            "/Users/pete/Code/project/apps",
        );

        let mut store = StateStore::new_in_memory();

        // Child match record (stale) - this should win
        store.update(
            "child-session",
            SessionState::Ready,
            "/Users/pete/Code/project/apps",
        );
        let stale_time = Utc::now() - Duration::minutes(10);
        store.set_timestamp_for_test("child-session", stale_time);

        // Parent match record (fresh) - should NOT win
        store.update("parent-session", SessionState::Working, "/Users/pete");
        // parent-session has default "now" timestamp, so it's fresher

        // Query from parent path
        let resolved =
            resolve_state_with_details(temp.path(), &store, "/Users/pete/Code/project").unwrap();

        // The child match should be selected (child of the query path), not the parent match
        assert_eq!(
            resolved.session_id.as_deref(),
            Some("child-session"),
            "Child match should beat parent match regardless of timestamp"
        );
    }
}
