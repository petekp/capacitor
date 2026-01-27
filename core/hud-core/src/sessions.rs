//! Session state management for Claude Code sessions.
//!
//! Handles reading session states from the v3 state store and
//! detecting the current state of Claude Code sessions.
//!
//! All session data lives in `~/.capacitor/` (our namespace):
//! - Lock directories: `~/.capacitor/sessions/{hash}.lock/`
//! - State file: `~/.capacitor/sessions.json`
//!
//! We never write to `~/.claude/` (sidecar purity).

use crate::activity::ActivityStore;
use crate::state::{resolve_state_with_details, StateStore};
use crate::storage::StorageConfig;
use crate::types::{ProjectSessionState, SessionState};
use chrono::Utc;
use fs_err as fs;
use std::path::Path;

/// Ready state becomes Idle after this many seconds without a lock.
/// This handles abandoned sessions where Claude finished but the user never returned.
/// 15 minutes matches the Swift threshold that was previously applied client-side.
pub const READY_STALE_THRESHOLD_SECS: i64 = 900;

/// Detects session state using the v3 state module.
/// Uses session-ID keyed state file and lock detection for reliable state.
/// The resolver handles both lock-based detection and fresh record fallback.
pub fn detect_session_state(project_path: &str) -> ProjectSessionState {
    detect_session_state_with_storage(&StorageConfig::default(), project_path)
}

pub fn detect_session_state_with_storage(
    storage: &StorageConfig,
    project_path: &str,
) -> ProjectSessionState {
    // Both locks and state file are in ~/.capacitor/ (our namespace, sidecar purity)
    let lock_dir = storage.sessions_dir();
    let state_file = storage.sessions_file();

    let store = StateStore::load(&state_file).unwrap_or_else(|_| StateStore::new(&state_file));

    // v3 resolver handles both lock-based detection and fresh record fallback
    let resolved = resolve_state_with_details(&lock_dir, &store, project_path);

    match resolved {
        Some(details) => {
            let record = details
                .session_id
                .as_ref()
                .and_then(|sid| store.get_by_session_id(sid));

            // Check if Ready state should become Idle (stale Ready without lock)
            let final_state = if details.state == SessionState::Ready && !details.is_from_lock {
                if let Some(rec) = record.as_ref() {
                    let age = Utc::now()
                        .signed_duration_since(rec.state_changed_at)
                        .num_seconds();
                    if age > READY_STALE_THRESHOLD_SECS {
                        SessionState::Idle
                    } else {
                        details.state
                    }
                } else {
                    details.state
                }
            } else {
                details.state
            };

            let is_working = final_state == SessionState::Working;
            let working_on = record.as_ref().and_then(|r| r.working_on.clone());
            let state_changed_at = record.as_ref().map(|r| r.state_changed_at.to_rfc3339());
            let updated_at = record.map(|r| r.updated_at.to_rfc3339());

            ProjectSessionState {
                state: final_state,
                state_changed_at,
                updated_at,
                session_id: details.session_id,
                working_on,
                context: None,
                thinking: Some(is_working),
                is_locked: details.is_from_lock,
            }
        }
        None => {
            // No session found via lock or fresh record - check for file activity
            // This enables monorepo package tracking where cwd != project_path
            let activity_file = storage.file_activity_file();
            let activity_store = ActivityStore::load(&activity_file);

            if activity_store
                .has_recent_activity_in_path(project_path, crate::activity::ACTIVITY_THRESHOLD)
            {
                // Recent file edits in this project from a session elsewhere
                ProjectSessionState {
                    state: SessionState::Working,
                    state_changed_at: None,
                    updated_at: None,
                    session_id: None, // We don't know which session (could track in activity)
                    working_on: None,
                    context: None,
                    thinking: Some(true),
                    is_locked: false, // No lock at this path, but still working
                }
            } else {
                ProjectSessionState {
                    state: SessionState::Idle,
                    state_changed_at: None,
                    updated_at: None,
                    session_id: None,
                    working_on: None,
                    context: None,
                    thinking: None,
                    is_locked: false,
                }
            }
        }
    }
}

/// Gets all session states using v3 state resolution.
/// Uses session-ID keyed state file and lock detection for reliable state.
/// Parent/child inheritance is handled by the resolver.
pub fn get_all_session_states(
    project_paths: &[String],
) -> std::collections::HashMap<String, ProjectSessionState> {
    get_all_session_states_with_storage(&StorageConfig::default(), project_paths)
}

pub fn get_all_session_states_with_storage(
    storage: &StorageConfig,
    project_paths: &[String],
) -> std::collections::HashMap<String, ProjectSessionState> {
    let mut states = std::collections::HashMap::new();

    for path in project_paths {
        states.insert(
            path.clone(),
            detect_session_state_with_storage(storage, path),
        );
    }

    states
}

/// Project status as stored in .claude/hud-status.json within each project.
#[derive(Debug, serde::Serialize, serde::Deserialize, Clone, Default, uniffi::Record)]
pub struct ProjectStatus {
    pub working_on: Option<String>,
    pub next_step: Option<String>,
    pub status: Option<String>,
    pub blocker: Option<String>,
    pub updated_at: Option<String>,
}

/// Reads project status from a project's .claude/hud-status.json file.
pub fn read_project_status(project_path: &str) -> Option<ProjectStatus> {
    let status_path = Path::new(project_path)
        .join(".claude")
        .join("hud-status.json");

    if status_path.exists() {
        fs::read_to_string(&status_path)
            .ok()
            .and_then(|content| serde_json::from_str(&content).ok())
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::normalize_path_for_hashing;
    use chrono::{Duration as ChronoDuration, Utc};
    use std::path::PathBuf;
    use tempfile::TempDir;

    fn setup_storage() -> (TempDir, StorageConfig) {
        let temp = TempDir::new().unwrap();
        let capacitor_root = temp.path().join("capacitor");
        let claude_root = temp.path().join("claude");
        fs::create_dir_all(&capacitor_root).unwrap();
        fs::create_dir_all(&claude_root).unwrap();
        let storage = StorageConfig::with_roots(capacitor_root, claude_root);
        (temp, storage)
    }

    /// Sets up storage with sessions dir in CAPACITOR namespace (correct location).
    fn setup_storage_with_sessions() -> (TempDir, StorageConfig, PathBuf) {
        let (temp, storage) = setup_storage();
        let sessions_dir = storage.sessions_dir(); // ~/.capacitor/sessions/
        fs::create_dir_all(&sessions_dir).unwrap();
        (temp, storage, sessions_dir)
    }

    #[test]
    fn test_md5_hash_consistency() {
        let path = "/Users/test/project";
        let hash1 = format!("{:x}", md5::compute(path));
        let hash2 = format!("{:x}", md5::compute(path));
        assert_eq!(hash1, hash2, "MD5 hash should be consistent for same input");
    }

    #[test]
    fn test_md5_hash_uniqueness() {
        let hash1 = format!("{:x}", md5::compute("/path/one"));
        let hash2 = format!("{:x}", md5::compute("/path/two"));
        assert_ne!(hash1, hash2, "Different paths should have different hashes");
    }

    #[test]
    fn test_detect_session_state_returns_idle_for_unknown() {
        let (_temp, storage) = setup_storage();
        let state = detect_session_state_with_storage(
            &storage,
            "/definitely/not/a/real/project/path/xyz123",
        );
        assert_eq!(state.state, SessionState::Idle);
        assert!(state.session_id.is_none());
        assert!(state.working_on.is_none());
    }

    #[test]
    fn test_detect_session_state_ready_without_lock_when_recent() {
        let (_temp, storage) = setup_storage();
        let project_path = "/tmp/hud-core-test-recent-ready";

        let mut store = StateStore::new(&storage.sessions_file());
        store.update("session-1", SessionState::Ready, project_path);
        store.save().unwrap();

        let state = detect_session_state_with_storage(&storage, project_path);

        assert_eq!(state.state, SessionState::Ready);
        assert!(!state.is_locked);
        assert_eq!(state.session_id.as_deref(), Some("session-1"));
        assert!(state.state_changed_at.is_some());
    }

    #[test]
    fn test_detect_session_state_stale_ready_without_lock_returns_idle() {
        // v4: Stale Ready records without a lock should return Idle (session has ended)
        // With session-based locks, if there's no lock, the session has been released.
        let (_temp, storage) = setup_storage();
        let project_path = "/tmp/hud-core-test-stale-ready";

        let mut store = StateStore::new(&storage.sessions_file());
        store.update("session-1", SessionState::Ready, project_path);
        // 10 minutes: stale (> 5 min threshold)
        let ten_mins_ago = Utc::now() - ChronoDuration::minutes(10);
        store.set_timestamp_for_test("session-1", ten_mins_ago);
        store.set_state_changed_at_for_test("session-1", ten_mins_ago);
        store.save().unwrap();

        let state = detect_session_state_with_storage(&storage, project_path);

        // v4: Without a lock, stale records indicate the session has ended → Idle
        assert_eq!(state.state, SessionState::Idle);
        // No session_id when resolver returns None
        assert!(state.session_id.is_none());
    }

    #[test]
    fn test_detect_session_state_very_stale_ready_returns_idle() {
        // Very stale Ready records (> 5 min) without a lock should return Idle
        let (_temp, storage) = setup_storage();
        let project_path = "/tmp/hud-core-test-very-stale-ready";

        let mut store = StateStore::new(&storage.sessions_file());
        store.update("session-1", SessionState::Ready, project_path);
        // 20 minutes: very stale
        let twenty_mins_ago = Utc::now() - ChronoDuration::minutes(20);
        store.set_timestamp_for_test("session-1", twenty_mins_ago);
        store.set_state_changed_at_for_test("session-1", twenty_mins_ago);
        store.save().unwrap();

        let state = detect_session_state_with_storage(&storage, project_path);

        assert_eq!(state.state, SessionState::Idle);
        // v4: No session_id when resolver returns None (session has ended)
        assert!(state.session_id.is_none());
    }

    #[test]
    fn test_detect_session_state_ignores_parent_state_without_lock() {
        let (_temp, storage) = setup_storage();
        let parent_path = "/tmp/hud-core-test-parent";
        let child_path = "/tmp/hud-core-test-parent/child";

        let mut store = StateStore::new(&storage.sessions_file());
        store.update("session-1", SessionState::Ready, parent_path);
        store.save().unwrap();

        let state = detect_session_state_with_storage(&storage, child_path);

        assert_eq!(state.state, SessionState::Idle);
        assert!(state.session_id.is_none());
    }

    #[test]
    fn test_detect_session_state_sets_state_changed_at_for_lock() {
        use crate::state::lock::tests_helper::create_lock;

        let (_temp, storage, sessions_dir) = setup_storage_with_sessions();
        let project_path = "/tmp/hud-core-test-locked-ready";
        create_lock(&sessions_dir, std::process::id(), project_path);

        let mut store = StateStore::new(&storage.sessions_file());
        store.update("session-1", SessionState::Working, project_path);
        // Use a recent timestamp (within 15-sec active state threshold)
        let expected = Utc::now() - ChronoDuration::seconds(5);
        // Set both updated_at and state_changed_at for the test
        store.set_timestamp_for_test("session-1", expected);
        store.set_state_changed_at_for_test("session-1", expected);
        store.save().unwrap();

        let state = detect_session_state_with_storage(&storage, project_path);

        assert_eq!(state.state, SessionState::Working);
        assert!(state.is_locked);
        assert_eq!(state.state_changed_at, Some(expected.to_rfc3339()));
    }

    #[test]
    fn test_get_all_session_states_empty_input() {
        let (_temp, storage) = setup_storage();
        let paths: Vec<String> = vec![];
        let states = get_all_session_states_with_storage(&storage, &paths);
        assert!(states.is_empty());
    }

    #[test]
    fn test_get_all_session_states_multiple_paths() {
        let (_temp, storage) = setup_storage();
        let paths = vec![
            "/fake/path/one".to_string(),
            "/fake/path/two".to_string(),
            "/fake/path/three".to_string(),
        ];
        let states = get_all_session_states_with_storage(&storage, &paths);

        assert_eq!(states.len(), 3);
        assert!(states.contains_key("/fake/path/one"));
        assert!(states.contains_key("/fake/path/two"));
        assert!(states.contains_key("/fake/path/three"));
    }

    #[test]
    fn test_project_status_default() {
        let status = ProjectStatus::default();
        assert!(status.working_on.is_none());
        assert!(status.next_step.is_none());
        assert!(status.status.is_none());
        assert!(status.blocker.is_none());
        assert!(status.updated_at.is_none());
    }

    #[test]
    fn test_project_status_serialization() {
        let status = ProjectStatus {
            working_on: Some("Building feature X".to_string()),
            next_step: Some("Write tests".to_string()),
            status: Some("in_progress".to_string()),
            blocker: None,
            updated_at: Some("2024-01-01T00:00:00Z".to_string()),
        };

        let json = serde_json::to_string(&status).unwrap();
        let deserialized: ProjectStatus = serde_json::from_str(&json).unwrap();

        assert_eq!(
            deserialized.working_on,
            Some("Building feature X".to_string())
        );
        assert_eq!(deserialized.next_step, Some("Write tests".to_string()));
        assert!(deserialized.blocker.is_none());
    }

    #[test]
    fn test_read_project_status_missing_file() {
        let result = read_project_status("/definitely/not/a/real/path/xyz");
        assert!(result.is_none());
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Lock Namespace Tests
    // These tests verify locks are in ~/.capacitor/sessions/ (our namespace),
    // NOT in ~/.claude/sessions/ (Claude's namespace - sidecar violation!)
    // ─────────────────────────────────────────────────────────────────────────────

    /// Helper to create a lock in the CAPACITOR namespace (correct location)
    fn create_capacitor_lock(storage: &StorageConfig, project_path: &str, pid: u32) {
        let sessions_dir = storage.sessions_dir(); // ~/.capacitor/sessions/
        fs::create_dir_all(&sessions_dir).unwrap();

        let normalized = normalize_path_for_hashing(project_path);
        let hash = md5::compute(normalized.as_bytes());
        let lock_dir = sessions_dir.join(format!("{:x}.lock", hash));
        fs::create_dir_all(&lock_dir).unwrap();

        // Write pid file
        fs::write(lock_dir.join("pid"), pid.to_string()).unwrap();

        // Write meta.json with proc_started for PID verification
        let proc_started = crate::state::lock::get_process_start_time(pid).unwrap_or(0);
        let created = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let meta = format!(
            r#"{{"pid": {}, "path": "{}", "proc_started": {}, "created": {}}}"#,
            pid, project_path, proc_started, created
        );
        fs::write(lock_dir.join("meta.json"), meta).unwrap();
    }

    #[test]
    fn test_detect_session_state_uses_capacitor_locks() {
        // Verify that detect_session_state uses capacitor namespace for locks
        let (_temp, storage) = setup_storage();
        let test_path = "/test/session/state";
        let current_pid = std::process::id();

        // Create lock in capacitor namespace
        create_capacitor_lock(&storage, test_path, current_pid);

        // Create a state record with proper v3 format and recent timestamp
        let state_file = storage.sessions_file();
        let now = chrono::Utc::now().to_rfc3339();
        let state_content = format!(
            r#"{{
                "version": 3,
                "sessions": {{
                    "test-session-123": {{
                        "session_id": "test-session-123",
                        "state": "working",
                        "cwd": "{}",
                        "project_dir": "{}",
                        "updated_at": "{}",
                        "state_changed_at": "{}"
                    }}
                }}
            }}"#,
            test_path, test_path, now, now
        );
        fs::create_dir_all(state_file.parent().unwrap()).unwrap();
        fs::write(&state_file, state_content).unwrap();

        let state = detect_session_state_with_storage(&storage, test_path);

        // With a lock present and matching state record, should return the recorded state
        assert_eq!(
            state.state,
            SessionState::Working,
            "Session with lock in capacitor namespace should be detected"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Ready→Idle Staleness Tests (15 minute threshold)
    // These tests verify that Ready state becomes Idle after 15 minutes without lock
    // Previously handled in Swift, now moved to Rust for "dumb client" architecture
    // ─────────────────────────────────────────────────────────────────────────────

    /// Test: Fresh Ready state (< 15 min) without lock stays Ready
    #[test]
    fn test_ready_state_fresh_stays_ready() {
        let (_temp, storage) = setup_storage();
        let project_path = "/tmp/hud-core-test-ready-fresh";

        let mut store = StateStore::new(&storage.sessions_file());
        store.update("session-1", SessionState::Ready, project_path);
        // Default timestamp is now, which is fresh
        store.save().unwrap();

        let state = detect_session_state_with_storage(&storage, project_path);

        assert_eq!(state.state, SessionState::Ready);
        assert!(!state.is_locked);
    }

    /// Test: Stale Ready state (> 15 min) without lock becomes Idle
    #[test]
    fn test_ready_state_stale_becomes_idle() {
        let (_temp, storage) = setup_storage();
        let project_path = "/tmp/hud-core-test-ready-stale";

        let mut store = StateStore::new(&storage.sessions_file());
        store.update("session-1", SessionState::Ready, project_path);
        // Set state_changed_at to 16 minutes ago (beyond 15 min threshold)
        let stale_time = Utc::now() - ChronoDuration::minutes(16);
        store.set_state_changed_at_for_test("session-1", stale_time);
        // Keep updated_at fresh so the record isn't filtered out by general staleness
        store.set_timestamp_for_test("session-1", Utc::now() - ChronoDuration::seconds(30));
        store.save().unwrap();

        let state = detect_session_state_with_storage(&storage, project_path);

        assert_eq!(
            state.state,
            SessionState::Idle,
            "Ready state older than 15 minutes without lock should become Idle"
        );
    }

    /// Test: Stale Ready state (> 15 min) WITH lock stays Ready (lock is authoritative)
    #[test]
    fn test_ready_state_stale_with_lock_stays_ready() {
        use crate::state::lock::tests_helper::create_lock;

        let (_temp, storage, sessions_dir) = setup_storage_with_sessions();
        let project_path = "/tmp/hud-core-test-ready-stale-locked";
        create_lock(&sessions_dir, std::process::id(), project_path);

        let mut store = StateStore::new(&storage.sessions_file());
        store.update("session-1", SessionState::Ready, project_path);
        // Set state_changed_at to 16 minutes ago
        let stale_time = Utc::now() - ChronoDuration::minutes(16);
        store.set_state_changed_at_for_test("session-1", stale_time);
        store.set_timestamp_for_test("session-1", Utc::now());
        store.save().unwrap();

        let state = detect_session_state_with_storage(&storage, project_path);

        assert_eq!(
            state.state,
            SessionState::Ready,
            "Ready state with active lock should stay Ready regardless of staleness"
        );
        assert!(state.is_locked);
    }

    /// Test: Ready state at exactly 15 min boundary stays Ready
    #[test]
    fn test_ready_state_at_boundary_stays_ready() {
        let (_temp, storage) = setup_storage();
        let project_path = "/tmp/hud-core-test-ready-boundary";

        let mut store = StateStore::new(&storage.sessions_file());
        store.update("session-1", SessionState::Ready, project_path);
        // Set state_changed_at to exactly 15 minutes ago (at boundary, not past it)
        let boundary_time = Utc::now() - ChronoDuration::seconds(900);
        store.set_state_changed_at_for_test("session-1", boundary_time);
        store.set_timestamp_for_test("session-1", Utc::now() - ChronoDuration::seconds(30));
        store.save().unwrap();

        let state = detect_session_state_with_storage(&storage, project_path);

        assert_eq!(
            state.state,
            SessionState::Ready,
            "Ready state at exactly 15 minutes should stay Ready (threshold is >15 min)"
        );
    }
}
