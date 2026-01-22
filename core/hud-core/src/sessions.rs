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
use crate::boundaries::normalize_path;
use crate::state::{resolve_state_with_details, StateStore};
use crate::storage::StorageConfig;
use crate::types::{ProjectSessionState, SessionState};
use std::fs;
use std::path::Path;

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
            let is_working = details.state == SessionState::Working;
            let record = details
                .session_id
                .as_ref()
                .and_then(|sid| store.get_by_session_id(sid));
            let working_on = record.and_then(|r| r.working_on.clone());
            let state_changed_at = record.map(|r| r.state_changed_at.to_rfc3339());

            ProjectSessionState {
                state: details.state,
                state_changed_at,
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

/// Gets all session states using v2 state resolution.
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

/// Checks if a Claude session is actively running for the given project path.
///
/// This uses directory-based locking (mkdir is atomic) to reliably detect running sessions.
/// A background process spawned by the hooks (SessionStart/UserPromptSubmit) holds the lock directory
/// while Claude is running, and removes it when Claude exits.
///
/// IMPORTANT: The lock is created for the cwd where Claude runs, which may be a
/// subdirectory of the pinned project. This function checks both:
/// 1. Exact path match (lock created at project root)
/// 2. Subdirectory match (lock created in a subdirectory of the project)
///
/// Lock directories are in `~/.capacitor/sessions/` (our namespace, sidecar purity).
pub fn is_session_active(project_path: &str) -> bool {
    let storage = StorageConfig::default();
    is_session_active_with_storage(&storage, project_path)
}

pub fn is_session_active_with_storage(storage: &StorageConfig, project_path: &str) -> bool {
    let sessions_dir = storage.sessions_dir();
    is_session_active_with_lock_dir(&sessions_dir, project_path)
}

fn is_session_active_with_lock_dir(sessions_dir: &Path, project_path: &str) -> bool {
    if !sessions_dir.exists() {
        return false;
    }

    let normalized_project = normalize_path(project_path);

    // First, try exact path match (most common case)
    let hash = md5::compute(&normalized_project);
    let lock_dir = sessions_dir.join(format!("{:x}.lock", hash));

    if lock_dir.exists() && lock_dir.is_dir() {
        if let Some(pid) = read_pid_from_lock(&lock_dir) {
            if crate::state::lock::is_pid_alive(pid) {
                return true;
            }
        }
    }

    // Second, scan all locks to find child paths
    // If Claude runs from a subdirectory (e.g., apps/swift), the parent project (claude-hud) is locked.
    // But NOT the reverse: a lock in a parent directory does NOT lock child projects.
    if let Ok(entries) = fs::read_dir(sessions_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if !path.is_dir() || !path.extension().map(|e| e == "lock").unwrap_or(false) {
                continue;
            }

            // Read the lock's path from meta.json
            let meta_file = path.join("meta.json");
            if let Ok(meta_str) = fs::read_to_string(&meta_file) {
                if let Ok(meta) = serde_json::from_str::<serde_json::Value>(&meta_str) {
                    if let Some(lock_path) = meta.get("path").and_then(|v| v.as_str()) {
                        let normalized_lock = normalize_path(lock_path);
                        let is_child_lock = if normalized_project == "/" {
                            normalized_lock != "/" && normalized_lock.starts_with('/')
                        } else {
                            let prefix = format!("{}/", normalized_project);
                            normalized_lock.starts_with(&prefix)
                        };

                        if is_child_lock {
                            // Found a child lock - check if PID is alive
                            if let Some(pid) = read_pid_from_lock(&path) {
                                if crate::state::lock::is_pid_alive(pid) {
                                    return true;
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    false
}

/// Reads PID from lock directory, supporting both old (pid file) and new (meta.json) formats
fn read_pid_from_lock(lock_dir: &Path) -> Option<u32> {
    // Try old format: direct pid file
    let pid_file = lock_dir.join("pid");
    if let Ok(pid_str) = fs::read_to_string(&pid_file) {
        if let Ok(pid) = pid_str.trim().parse::<u32>() {
            return Some(pid);
        }
    }

    // Try new format: meta.json with {"pid": N, ...}
    let meta_file = lock_dir.join("meta.json");
    if let Ok(meta_str) = fs::read_to_string(&meta_file) {
        if let Ok(meta) = serde_json::from_str::<serde_json::Value>(&meta_str) {
            if let Some(pid) = meta.get("pid").and_then(|v| v.as_u64()) {
                return Some(pid as u32);
            }
        }
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{Duration as ChronoDuration, Utc};
    use std::io::Write;
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
        let (_temp, storage) = setup_storage();
        let sessions_dir = storage.sessions_dir(); // ~/.capacitor/sessions/
        fs::create_dir_all(&sessions_dir).unwrap();
        (temp, storage, sessions_dir)
    }

    /// Sets up storage with sessions dir in CLAUDE namespace (for testing we ignore it).
    fn setup_storage_with_claude_sessions() -> (TempDir, StorageConfig, PathBuf) {
        let (_temp, storage) = setup_storage();
        let sessions_dir = storage.claude_root().join("sessions");
        fs::create_dir_all(&sessions_dir).unwrap();
        (temp, storage, sessions_dir)
    }

    /// Helper to create a test sessions directory with a lock (old format: pid file)
    fn create_test_lock(sessions_dir: &Path, project_path: &str, pid: u32) {
        let normalized = normalize_path(project_path);
        let hash = md5::compute(normalized.as_bytes());
        let lock_dir = sessions_dir.join(format!("{:x}.lock", hash));
        fs::create_dir_all(&lock_dir).unwrap();

        let pid_file = lock_dir.join("pid");
        let mut file = fs::File::create(&pid_file).unwrap();
        writeln!(file, "{}", pid).unwrap();
    }

    /// Helper to create a lock with meta.json (new format, includes path for relationship checks)
    fn create_test_lock_with_meta(sessions_dir: &Path, project_path: &str, pid: u32) {
        let normalized = normalize_path(project_path);
        let hash = md5::compute(normalized.as_bytes());
        let lock_dir = sessions_dir.join(format!("{:x}.lock", hash));
        fs::create_dir_all(&lock_dir).unwrap();

        let meta = format!(
            r#"{{"pid": {}, "started": "2024-01-01T00:00:00Z", "path": "{}"}}"#,
            pid, project_path
        );
        fs::write(lock_dir.join("meta.json"), meta).unwrap();
    }

    /// Helper to clean up a test lock
    fn cleanup_test_lock(sessions_dir: &Path, project_path: &str) {
        let normalized = normalize_path(project_path);
        let hash = md5::compute(normalized.as_bytes());
        let lock_dir = sessions_dir.join(format!("{:x}.lock", hash));
        let _ = fs::remove_dir_all(&lock_dir);
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
    fn test_is_session_active_no_sessions_dir() {
        let (_temp, storage) = setup_storage();
        let result =
            is_session_active_with_storage(&storage, "/nonexistent/path/that/surely/doesnt/exist");
        assert!(!result, "Missing sessions dir should be inactive");
    }

    #[test]
    fn test_is_session_active_with_dead_pid() {
        let (_temp, storage, sessions_dir) = setup_storage_with_sessions();

        // Use a test path that won't conflict with real projects
        let test_path = "/tmp/hud-core-test-dead-pid-project";

        // Create lock with definitely-dead PID
        create_test_lock(&sessions_dir, test_path, 999999999);

        let result = is_session_active_with_storage(&storage, test_path);

        // Clean up
        cleanup_test_lock(&sessions_dir, test_path);

        assert!(!result, "Dead PID should not be considered active");
    }

    #[test]
    fn test_is_session_active_with_current_pid() {
        let (_temp, storage, sessions_dir) = setup_storage_with_sessions();

        let test_path = "/tmp/hud-core-test-current-pid-project";

        // Create lock with our own PID (definitely alive)
        let current_pid = std::process::id();
        create_test_lock(&sessions_dir, test_path, current_pid);

        let result = is_session_active_with_storage(&storage, test_path);

        // Clean up
        cleanup_test_lock(&sessions_dir, test_path);

        assert!(result, "Current process PID should be considered active");
    }

    #[test]
    fn test_is_session_active_no_lock_dir() {
        let (_temp, storage, sessions_dir) = setup_storage_with_sessions();

        // Use a path that definitely won't have a lock
        let test_path = "/tmp/hud-core-test-no-lock-dir-unique-12345";

        // Ensure no lock exists
        cleanup_test_lock(&sessions_dir, test_path);

        let result = is_session_active_with_storage(&storage, test_path);
        assert!(!result, "Missing lock dir should not be considered active");
    }

    #[test]
    fn test_is_session_active_empty_pid_file() {
        let (_temp, storage, sessions_dir) = setup_storage_with_sessions();

        let test_path = "/tmp/hud-core-test-empty-pid-file";
        let normalized = normalize_path(test_path);
        let hash = md5::compute(normalized.as_bytes());
        let lock_dir = sessions_dir.join(format!("{:x}.lock", hash));

        // Create lock dir with empty pid file
        fs::create_dir_all(&lock_dir).unwrap();
        fs::write(lock_dir.join("pid"), "").unwrap();

        let result = is_session_active_with_storage(&storage, test_path);

        // Clean up
        let _ = fs::remove_dir_all(&lock_dir);

        assert!(!result, "Empty PID file should not be considered active");
    }

    #[test]
    fn test_is_session_active_invalid_pid() {
        let (_temp, storage, sessions_dir) = setup_storage_with_sessions();

        let test_path = "/tmp/hud-core-test-invalid-pid";
        let normalized = normalize_path(test_path);
        let hash = md5::compute(normalized.as_bytes());
        let lock_dir = sessions_dir.join(format!("{:x}.lock", hash));

        // Create lock dir with invalid pid
        fs::create_dir_all(&lock_dir).unwrap();
        fs::write(lock_dir.join("pid"), "not-a-number").unwrap();

        let result = is_session_active_with_storage(&storage, test_path);

        // Clean up
        let _ = fs::remove_dir_all(&lock_dir);

        assert!(!result, "Invalid PID should not be considered active");
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
    fn test_detect_session_state_ignores_stale_record_without_lock() {
        let (_temp, storage) = setup_storage();
        let project_path = "/tmp/hud-core-test-stale-ready";

        let mut store = StateStore::new(&storage.sessions_file());
        store.update("session-1", SessionState::Ready, project_path);
        store.set_timestamp_for_test("session-1", Utc::now() - ChronoDuration::minutes(10));
        store.save().unwrap();

        let state = detect_session_state_with_storage(&storage, project_path);

        assert_eq!(state.state, SessionState::Idle);
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
        let expected = Utc::now() - ChronoDuration::minutes(2);
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

    // ============================================================
    // CRITICAL EDGE CASE TESTS
    // These test the specific bugs we discovered and fixed
    // ============================================================

    /// Test: Lock in child directory makes parent project active
    /// Scenario: Claude runs from /project/apps/swift, pinned project is /project
    /// Expected: is_session_active("/project") returns true
    #[test]
    fn test_child_lock_makes_parent_active() {
        let (_temp, storage, sessions_dir) = setup_storage_with_sessions();

        let parent_path = "/tmp/hud-test-parent-project";
        let child_path = "/tmp/hud-test-parent-project/apps/swift";
        let current_pid = std::process::id();

        // Create lock for CHILD path (simulating Claude running from subdirectory)
        create_test_lock_with_meta(&sessions_dir, child_path, current_pid);

        // Check if PARENT is considered active
        let result = is_session_active_with_storage(&storage, parent_path);

        // Clean up
        cleanup_test_lock(&sessions_dir, child_path);

        assert!(
            result,
            "Parent project should be active when child has a lock"
        );
    }

    /// Test: Lock in parent directory does NOT make child project active
    /// Scenario: Claude runs from /project, child project is /project/packages/foo
    /// Expected: is_session_active("/project/packages/foo") returns false
    /// This was a bug we fixed - locks should NOT propagate downward
    #[test]
    fn test_parent_lock_does_not_make_child_active() {
        let (_temp, storage, sessions_dir) = setup_storage_with_sessions();

        let parent_path = "/tmp/hud-test-parent-only";
        let child_path = "/tmp/hud-test-parent-only/packages/child";
        let current_pid = std::process::id();

        // Create lock for PARENT path only
        create_test_lock_with_meta(&sessions_dir, parent_path, current_pid);

        // Check if CHILD is considered active (should be FALSE)
        let result = is_session_active_with_storage(&storage, child_path);

        // Clean up
        cleanup_test_lock(&sessions_dir, parent_path);

        assert!(
            !result,
            "Child project should NOT be active when only parent has a lock"
        );
    }

    /// Test: Exact path match works correctly
    #[test]
    fn test_exact_path_lock_is_active() {
        let (_temp, storage, sessions_dir) = setup_storage_with_sessions();

        let project_path = "/tmp/hud-test-exact-match";
        let query_path = format!("{}/", project_path);
        let current_pid = std::process::id();

        create_test_lock_with_meta(&sessions_dir, project_path, current_pid);

        let result = is_session_active_with_storage(&storage, &query_path);

        cleanup_test_lock(&sessions_dir, project_path);

        assert!(result, "Exact path match should be active");
    }

    /// Test: Unrelated paths don't affect each other
    #[test]
    fn test_unrelated_paths_independent() {
        let (_temp, storage, sessions_dir) = setup_storage_with_sessions();

        let path_a = "/tmp/hud-test-project-a";
        let path_b = "/tmp/hud-test-project-b";
        let current_pid = std::process::id();

        // Create lock for path A only
        create_test_lock_with_meta(&sessions_dir, path_a, current_pid);

        // Check path B (should NOT be active)
        let result = is_session_active_with_storage(&storage, path_b);

        cleanup_test_lock(&sessions_dir, path_a);

        assert!(
            !result,
            "Unrelated path should not be affected by other locks"
        );
    }

    /// Test: Similar path prefixes don't false-match
    /// e.g., /project-foo should not match /project
    #[test]
    fn test_similar_prefix_no_false_match() {
        let (_temp, storage, sessions_dir) = setup_storage_with_sessions();

        let path_short = "/tmp/hud-test-prefix-short";
        let path_long = "/tmp/hud-test-prefix-shorter"; // Different project, similar prefix
        let current_pid = std::process::id();

        // Clean up any leftover state first
        cleanup_test_lock(&sessions_dir, path_short);
        cleanup_test_lock(&sessions_dir, path_long);

        // Create lock for long path only
        create_test_lock_with_meta(&sessions_dir, path_long, current_pid);

        // Short path should NOT be active (it's not a parent, just similar name)
        let result = is_session_active_with_storage(&storage, path_short);

        // Clean up
        cleanup_test_lock(&sessions_dir, path_short);
        cleanup_test_lock(&sessions_dir, path_long);

        assert!(
            !result,
            "Similar prefix should not cause false match (must be actual subdirectory)"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Phase 1: Lock Namespace Tests
    // These tests verify locks are in ~/.capacitor/sessions/ (our namespace),
    // NOT in ~/.claude/sessions/ (Claude's namespace - sidecar violation!)
    // ─────────────────────────────────────────────────────────────────────────────

    /// Helper to create a lock in the CAPACITOR namespace (correct location)
    fn create_capacitor_lock(storage: &StorageConfig, project_path: &str, pid: u32) {
        let sessions_dir = storage.sessions_dir(); // ~/.capacitor/sessions/
        fs::create_dir_all(&sessions_dir).unwrap();

        let normalized = normalize_path(project_path);
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
    fn test_locks_should_be_in_capacitor_namespace() {
        // This test verifies that session detection looks for locks in
        // ~/.capacitor/sessions/, NOT ~/.claude/sessions/
        let (_temp, storage) = setup_storage();
        let test_path = "/test/capacitor/namespace";
        let current_pid = std::process::id();

        // Create lock in CAPACITOR namespace (the correct location)
        create_capacitor_lock(&storage, test_path, current_pid);

        // Session should be detected as active
        let result = is_session_active_with_storage(&storage, test_path);

        assert!(
            result,
            "Locks in ~/.capacitor/sessions/ should be detected (sidecar purity)"
        );
    }

    #[test]
    fn test_locks_in_claude_namespace_should_be_ignored() {
        // This test verifies we DON'T look for locks in ~/.claude/sessions/
        // (that would pollute Claude's namespace - sidecar violation!)
        let (_temp, storage, claude_sessions_dir) = setup_storage_with_claude_sessions();
        let test_path = "/test/claude/namespace";
        let current_pid = std::process::id();

        // Create lock in CLAUDE namespace (the WRONG location)
        create_test_lock_with_meta(&claude_sessions_dir, test_path, current_pid);

        // Session should NOT be detected (we shouldn't look there)
        let result = is_session_active_with_storage(&storage, test_path);

        // Clean up
        cleanup_test_lock(&claude_sessions_dir, test_path);

        assert!(
            !result,
            "Locks in ~/.claude/sessions/ should be ignored (sidecar purity)"
        );
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
}
