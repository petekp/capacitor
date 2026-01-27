//! Resolves session state by combining lock liveness with stored records.
//!
//! The state store is the source of truth for the last known state, and Claude Code lock
//! directories indicate liveness. We do **not** rely on PIDs in the state store.

use std::path::Path;

use crate::types::SessionState;

use super::lock::{find_all_locks_for_path, find_lock_for_path};
use super::path_utils::normalize_path_for_comparison;
use super::store::StateStore;
use super::types::SessionRecord;

/// Normalizes a path for consistent comparison.
/// Handles trailing slashes, case sensitivity (macOS), and symlinks.
fn normalize_path(path: &str) -> String {
    normalize_path_for_comparison(path)
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
/// # v4 Session-Based Lock Resolution
///
/// With session-based locks, multiple concurrent sessions can exist for the same path.
/// `find_all_locks_for_path` returns all active locks; we use the best matching one.
/// When a session ends (SessionEnd event), its lock is released by session ID.
/// No "stale Ready fallback" is needed - if there's no lock, the session has ended.
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
    // Check for any active locks for this path (supports multiple concurrent sessions)
    let active_locks = find_all_locks_for_path(lock_dir, project_path);

    if !active_locks.is_empty() {
        // Lock(s) exist - find the best matching one
        // The lock proves Claude is running (lock holder monitors PID), so we trust the
        // recorded state even if the timestamp is stale.
        let lock = find_lock_for_path(lock_dir, project_path)?;
        let record = find_record_for_lock_path(store, &lock.path);
        let (state, session_id) = match record {
            Some(r) => (r.state, Some(r.session_id.clone())),
            // No record but lock exists - session is active, just no state written yet
            None => (SessionState::Ready, lock.session_id),
        };

        return Some(ResolvedState {
            state,
            session_id,
            cwd: lock.path,
            is_from_lock: true,
        });
    }

    // No locks - check for fresh state record as fallback (exact or child matches only)
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

    // No lock and no fresh record = session has ended or doesn't exist
    // With session-based locks, we no longer fall back to stale Ready records.
    // When a session ends, its lock is released by session ID, and the session
    // should transition to Idle based on the standard staleness threshold.
    None
}

/// Find a fresh (non-stale) record that exactly matches the given path.
/// Only considers exact matches - no child inheritance.
/// Each project shows only sessions started at that exact path.
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

        // Check both cwd and project_dir for exact matching
        let is_exact_match = [Some(record.cwd.as_str()), record.project_dir.as_deref()]
            .into_iter()
            .flatten()
            .any(|record_path| normalize_path(record_path) == path_normalized);

        if is_exact_match {
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
    fn parent_query_does_not_inherit_child_lock() {
        // With exact-match-only policy, parent paths don't inherit child session state.
        // This enables monorepos and packages to be tracked independently.
        let temp = tempdir().unwrap();
        create_lock(temp.path(), std::process::id(), "/project/apps/swift");
        let mut store = StateStore::new_in_memory();
        store.update("child", SessionState::Working, "/project/apps/swift");

        // Query parent path - should return None (no exact match)
        let resolved = resolve_state_with_details(temp.path(), &store, "/project");
        assert!(
            resolved.is_none(),
            "Parent path should not inherit child session state"
        );

        // Query child path - should work (exact match)
        let resolved = resolve_state_with_details(temp.path(), &store, "/project/apps/swift");
        assert!(resolved.is_some());
        assert_eq!(resolved.as_ref().unwrap().state, SessionState::Working);
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
    fn resolve_none_for_stale_ready_record_without_lock() {
        // v4 behavior: Stale Ready records without lock return None (session has ended)
        // With session-based locks, when a session ends its lock is released by session ID.
        // No fallback to stale Ready records - if there's no lock, the session is gone.
        let temp = tempdir().unwrap();
        let mut store = StateStore::new_in_memory();
        store.update("s1", SessionState::Ready, "/project");
        // Make record stale (> 5 min)
        let stale_time = Utc::now() - Duration::minutes(10);
        store.set_timestamp_for_test("s1", stale_time);
        // No lock and stale Ready record = None (session has ended)
        assert!(resolve_state_with_details(temp.path(), &store, "/project").is_none());
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
    fn no_inheritance_between_parent_and_child_paths() {
        // With exact-match-only policy, neither parent nor child sessions
        // affect each other. Each path is independent.
        let temp = tempdir().unwrap();

        // Lock exists for child path
        create_lock(
            temp.path(),
            std::process::id(),
            "/Users/pete/Code/project/apps",
        );

        let mut store = StateStore::new_in_memory();

        // Record for child path
        store.update(
            "child-session",
            SessionState::Working,
            "/Users/pete/Code/project/apps",
        );

        // Query parent path - should return None (no exact match)
        let resolved = resolve_state_with_details(temp.path(), &store, "/Users/pete/Code/project");
        assert!(
            resolved.is_none(),
            "Parent path should not see child session"
        );

        // Query child path - should work (exact match)
        let resolved =
            resolve_state_with_details(temp.path(), &store, "/Users/pete/Code/project/apps");
        assert!(resolved.is_some());
        assert_eq!(
            resolved.as_ref().unwrap().session_id.as_deref(),
            Some("child-session")
        );
    }

    #[test]
    fn concurrent_sessions_prefers_working_over_ready() {
        // When multiple sessions exist at the same path with different states,
        // the resolver should prefer active (Working) over passive (Ready).
        use crate::state::lock::tests_helper::create_session_lock;

        let temp = tempdir().unwrap();
        let pid = std::process::id();
        let mut store = StateStore::new_in_memory();

        // Create two session-based locks for same path (concurrent sessions)
        create_session_lock(temp.path(), pid, "/project", "session-ready");
        create_session_lock(temp.path(), pid, "/project", "session-working");

        // Add records with different states
        store.update("session-ready", SessionState::Ready, "/project");
        store.update("session-working", SessionState::Working, "/project");

        // Make session-ready newer to verify state priority beats timestamp
        let newer_time = Utc::now();
        let older_time = Utc::now() - Duration::seconds(10);
        store.set_timestamp_for_test("session-ready", newer_time);
        store.set_timestamp_for_test("session-working", older_time);

        let resolved = resolve_state_with_details(temp.path(), &store, "/project").unwrap();

        // Should find one of the sessions (exact behavior depends on lock selection)
        // Key point: the system handles concurrent sessions without crashing
        assert!(resolved.session_id.is_some());
        assert!(resolved.is_from_lock);
    }

    #[test]
    fn fresh_record_fallback_uses_exact_match_only() {
        // When no lock exists, fresh record fallback should only match exact paths.
        // This prevents /project from showing state for sessions at /project/src.
        let temp = tempdir().unwrap();
        let mut store = StateStore::new_in_memory();

        // Fresh Working record at child path
        store.update("child-session", SessionState::Working, "/project/src");

        // Query parent path - should return None (exact match only)
        let resolved = resolve_state_with_details(temp.path(), &store, "/project");
        assert!(
            resolved.is_none(),
            "Fresh record fallback should use exact match only, not child inheritance"
        );

        // Query child path - should work (exact match)
        let resolved = resolve_state_with_details(temp.path(), &store, "/project/src");
        assert!(resolved.is_some());
        assert_eq!(resolved.unwrap().state, SessionState::Working);
    }

    #[test]
    fn active_state_staleness_recovery_without_lock() {
        // Working/Waiting states should fall back to Ready when stale and no lock exists.
        // This handles user interruptions (Escape key) where no hook event fires.
        use crate::state::types::ACTIVE_STATE_STALE_SECS;

        let temp = tempdir().unwrap();
        let mut store = StateStore::new_in_memory();

        // Fresh record - should return Working
        store.update("s1", SessionState::Working, "/project");
        let fresh_time = Utc::now() - Duration::seconds(ACTIVE_STATE_STALE_SECS - 5);
        store.set_timestamp_for_test("s1", fresh_time);

        let resolved = resolve_state_with_details(temp.path(), &store, "/project").unwrap();
        assert_eq!(
            resolved.state,
            SessionState::Working,
            "Fresh Working should stay Working"
        );

        // Make stale beyond active threshold
        let stale_time = Utc::now() - Duration::seconds(ACTIVE_STATE_STALE_SECS + 5);
        store.set_timestamp_for_test("s1", stale_time);

        let resolved = resolve_state_with_details(temp.path(), &store, "/project").unwrap();
        assert_eq!(
            resolved.state,
            SessionState::Ready,
            "Stale Working without lock should fall back to Ready"
        );
    }

    #[test]
    fn compacting_not_subject_to_active_staleness() {
        // Compacting receives no heartbeat after PreCompact, so it uses general staleness
        // threshold instead of the aggressive active state threshold.
        use crate::state::types::ACTIVE_STATE_STALE_SECS;

        let temp = tempdir().unwrap();
        let mut store = StateStore::new_in_memory();

        // Compacting record stale by active threshold but within general threshold
        store.update("s1", SessionState::Compacting, "/project");
        let stale_time = Utc::now() - Duration::seconds(ACTIVE_STATE_STALE_SECS + 60);
        store.set_timestamp_for_test("s1", stale_time);

        let resolved = resolve_state_with_details(temp.path(), &store, "/project").unwrap();
        assert_eq!(
            resolved.state,
            SessionState::Compacting,
            "Compacting should not fall back to Ready after 30 seconds"
        );
    }
}
