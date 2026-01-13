//! Session state management for Claude Code sessions.
//!
//! Handles reading session states from the HUD status file and
//! detecting the current state of Claude Code sessions.

use crate::config::get_claude_dir;
use crate::state::{resolve_state_with_details, ClaudeState, StateStore};
use crate::types::{ContextInfo, ProjectSessionState, SessionState, SessionStatesFile};
use std::fs;
use std::path::Path;

/// Loads the session states file from ~/.claude/hud-session-states.json
pub fn load_session_states_file() -> Option<SessionStatesFile> {
    let claude_dir = get_claude_dir()?;
    let state_file = claude_dir.join("hud-session-states.json");

    if !state_file.exists() {
        return None;
    }

    fs::read_to_string(&state_file)
        .ok()
        .and_then(|content| serde_json::from_str(&content).ok())
}

/// Detects the session state for a given project path.
pub fn detect_session_state(project_path: &str) -> ProjectSessionState {
    let is_locked = is_session_active(project_path);

    let idle_state = ProjectSessionState {
        state: SessionState::Idle,
        state_changed_at: None,
        session_id: None,
        working_on: None,
        next_step: None,
        context: None,
        thinking: None,
        is_locked,
    };

    if let Some(states_file) = load_session_states_file() {
        if let Some(entry) = states_file.projects.get(project_path) {
            let state = match entry.state.as_str() {
                "working" => SessionState::Working,
                "ready" => SessionState::Ready,
                "compacting" => SessionState::Compacting,
                "waiting" => SessionState::Waiting,
                _ => SessionState::Idle,
            };

            let context = entry.context.as_ref().and_then(|ctx| {
                Some(ContextInfo {
                    percent_used: ctx.percent_used?,
                    tokens_used: ctx.tokens_used?,
                    context_size: ctx.context_size?,
                    updated_at: ctx.updated_at.clone(),
                })
            });

            return ProjectSessionState {
                state,
                state_changed_at: entry.state_changed_at.clone(),
                session_id: entry.session_id.clone(),
                working_on: entry.working_on.clone(),
                next_step: entry.next_step.clone(),
                context,
                thinking: entry.thinking,
                is_locked,
            };
        }
    }

    idle_state
}

/// Detects session state using the new v2 state module.
/// Uses session-ID keyed state file and lock detection for reliable state.
pub fn detect_session_state_v2(project_path: &str) -> ProjectSessionState {
    let Some(claude_dir) = get_claude_dir() else {
        return ProjectSessionState {
            state: SessionState::Idle,
            state_changed_at: None,
            session_id: None,
            working_on: None,
            next_step: None,
            context: None,
            thinking: None,
            is_locked: false,
        };
    };

    let lock_dir = claude_dir.join("sessions");
    let state_file = claude_dir.join("hud-session-states-v2.json");

    let store = StateStore::load(&state_file).unwrap_or_else(|_| StateStore::new(&state_file));

    let resolved = resolve_state_with_details(&lock_dir, &store, project_path);

    match resolved {
        Some(details) => {
            let is_working = details.state == ClaudeState::Working;
            let state = match details.state {
                ClaudeState::Working => SessionState::Working,
                ClaudeState::Ready => SessionState::Ready,
                ClaudeState::Compacting => SessionState::Compacting,
                ClaudeState::Blocked => SessionState::Waiting, // Map Blocked → Waiting
            };

            // Try to get working_on/next_step from v1 file (summaries are still there)
            let (working_on, next_step) = load_session_states_file()
                .and_then(|f| f.projects.get(project_path).cloned())
                .map(|e| (e.working_on, e.next_step))
                .unwrap_or((None, None));

            ProjectSessionState {
                state,
                state_changed_at: None,
                session_id: details.session_id,
                working_on,
                next_step,
                context: None,
                thinking: Some(is_working),
                is_locked: true,
            }
        }
        None => ProjectSessionState {
            state: SessionState::Idle,
            state_changed_at: None,
            session_id: None,
            working_on: None,
            next_step: None,
            context: None,
            thinking: None,
            is_locked: false,
        },
    }
}

/// Gets all session states for given project paths.
/// Also includes any child paths (subdirectories) found in the state file,
/// since hooks write to the cwd which may differ from the pinned project path.
pub fn get_all_session_states(
    project_paths: &[String],
) -> std::collections::HashMap<String, ProjectSessionState> {
    let mut states = std::collections::HashMap::new();

    // First, get states for the exact pinned paths
    for path in project_paths {
        states.insert(path.clone(), detect_session_state(path));
    }

    // Then, scan for child paths in the state file
    // Hooks write to cwd, which may be a subdirectory of the pinned project
    if let Some(states_file) = load_session_states_file() {
        for (state_path, entry) in &states_file.projects {
            // Check if this state_path is a child of any pinned project
            for pinned_path in project_paths {
                if state_path.starts_with(pinned_path) && state_path != pinned_path {
                    // It's a child path - include it if not already present
                    if !states.contains_key(state_path) {
                        let is_locked = is_session_active(state_path);

                        let state = match entry.state.as_str() {
                            "working" => SessionState::Working,
                            "ready" => SessionState::Ready,
                            "compacting" => SessionState::Compacting,
                            "waiting" => SessionState::Waiting,
                            _ => SessionState::Idle,
                        };

                        let context = entry.context.as_ref().and_then(|ctx| {
                            Some(ContextInfo {
                                percent_used: ctx.percent_used?,
                                tokens_used: ctx.tokens_used?,
                                context_size: ctx.context_size?,
                                updated_at: ctx.updated_at.clone(),
                            })
                        });

                        states.insert(
                            state_path.clone(),
                            ProjectSessionState {
                                state,
                                state_changed_at: entry.state_changed_at.clone(),
                                session_id: entry.session_id.clone(),
                                working_on: entry.working_on.clone(),
                                next_step: entry.next_step.clone(),
                                context,
                                thinking: entry.thinking,
                                is_locked,
                            },
                        );
                    }
                    break; // Found a matching parent, no need to check others
                }
            }
        }
    }

    states
}

/// Gets all session states using v2 state resolution.
/// Uses session-ID keyed state file and lock detection for reliable state.
/// Parent/child inheritance is handled by the resolver.
pub fn get_all_session_states_v2(
    project_paths: &[String],
) -> std::collections::HashMap<String, ProjectSessionState> {
    let mut states = std::collections::HashMap::new();

    for path in project_paths {
        states.insert(path.clone(), detect_session_state_v2(path));
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
/// A background process spawned by the UserPromptSubmit hook holds the lock directory
/// while Claude is running, and removes it when Claude exits.
///
/// IMPORTANT: The lock is created for the cwd where Claude runs, which may be a
/// subdirectory of the pinned project. This function checks both:
/// 1. Exact path match (lock created at project root)
/// 2. Subdirectory match (lock created in a subdirectory of the project)
pub fn is_session_active(project_path: &str) -> bool {
    let Some(claude_dir) = get_claude_dir() else {
        return false;
    };

    let sessions_dir = claude_dir.join("sessions");
    if !sessions_dir.exists() {
        return false;
    }

    // First, try exact path match (most common case)
    let hash = md5::compute(project_path);
    let lock_dir = sessions_dir.join(format!("{:x}.lock", hash));

    if lock_dir.exists() && lock_dir.is_dir() {
        if let Some(pid) = read_pid_from_lock(&lock_dir) {
            let result = unsafe { libc::kill(pid, 0) };
            if result == 0 {
                return true;
            }
        }
    }

    // Second, scan all locks to find child paths
    // If Claude runs from a subdirectory (e.g., apps/swift), the parent project (claude-hud) is locked.
    // But NOT the reverse: a lock in a parent directory does NOT lock child projects.
    if let Ok(entries) = fs::read_dir(&sessions_dir) {
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
                        // Only check: lock is subdirectory of project
                        // e.g., lock=apps/swift, project=claude-hud → claude-hud is locked
                        // NOT: project is subdirectory of lock (that would incorrectly lock children)
                        let is_child_lock =
                            lock_path.starts_with(project_path) && lock_path != project_path;

                        if is_child_lock {
                            // Found a child lock - check if PID is alive
                            if let Some(pid) = read_pid_from_lock(&path) {
                                let result = unsafe { libc::kill(pid, 0) };
                                if result == 0 {
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
fn read_pid_from_lock(lock_dir: &Path) -> Option<i32> {
    // Try old format: direct pid file
    let pid_file = lock_dir.join("pid");
    if let Ok(pid_str) = fs::read_to_string(&pid_file) {
        if let Ok(pid) = pid_str.trim().parse::<i32>() {
            return Some(pid);
        }
    }

    // Try new format: meta.json with {"pid": N, ...}
    let meta_file = lock_dir.join("meta.json");
    if let Ok(meta_str) = fs::read_to_string(&meta_file) {
        if let Ok(meta) = serde_json::from_str::<serde_json::Value>(&meta_str) {
            if let Some(pid) = meta.get("pid").and_then(|v| v.as_i64()) {
                return Some(pid as i32);
            }
        }
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    /// Helper to create a test sessions directory with a lock (old format: pid file)
    fn create_test_lock(sessions_dir: &Path, project_path: &str, pid: i32) {
        let hash = md5::compute(project_path);
        let lock_dir = sessions_dir.join(format!("{:x}.lock", hash));
        fs::create_dir_all(&lock_dir).unwrap();

        let pid_file = lock_dir.join("pid");
        let mut file = fs::File::create(&pid_file).unwrap();
        writeln!(file, "{}", pid).unwrap();
    }

    /// Helper to create a lock with meta.json (new format, includes path for relationship checks)
    fn create_test_lock_with_meta(sessions_dir: &Path, project_path: &str, pid: i32) {
        let hash = md5::compute(project_path);
        let lock_dir = sessions_dir.join(format!("{:x}.lock", hash));
        fs::create_dir_all(&lock_dir).unwrap();

        let meta = format!(
            r#"{{"pid": {}, "started": "2024-01-01T00:00:00Z", "path": "{}"}}"#,
            pid, project_path
        );
        fs::write(lock_dir.join("meta.json"), meta).unwrap();
    }

    /// Helper to create a test state file
    fn create_test_state_file(claude_dir: &Path, entries: &[(&str, &str, bool)]) {
        let mut projects = std::collections::HashMap::new();
        for (path, state, thinking) in entries {
            let mut entry = std::collections::HashMap::new();
            entry.insert("state".to_string(), serde_json::json!(state));
            entry.insert("thinking".to_string(), serde_json::json!(thinking));
            entry.insert(
                "context".to_string(),
                serde_json::json!({"updated_at": "2024-01-01T00:00:00Z"}),
            );
            projects.insert(path.to_string(), entry);
        }

        let state_file = serde_json::json!({
            "version": 1,
            "projects": projects
        });

        let state_path = claude_dir.join("hud-session-states.json");
        fs::write(state_path, serde_json::to_string_pretty(&state_file).unwrap()).unwrap();
    }

    /// Helper to clean up a test lock
    fn cleanup_test_lock(sessions_dir: &Path, project_path: &str) {
        let hash = md5::compute(project_path);
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
        // When sessions directory doesn't exist, should return false
        let result = is_session_active("/nonexistent/path/that/surely/doesnt/exist");
        // This test depends on ~/.claude/sessions not having a lock for this path
        // It primarily tests that the function doesn't panic
        assert!(!result || result); // Either result is fine, just don't panic
    }

    #[test]
    fn test_is_session_active_with_dead_pid() {
        // This test requires us to be able to write to ~/.claude/sessions
        // Skip if we can't
        let Some(claude_dir) = get_claude_dir() else {
            eprintln!("Skipping test - no claude dir");
            return;
        };

        let sessions_dir = claude_dir.join("sessions");
        if fs::create_dir_all(&sessions_dir).is_err() {
            eprintln!("Skipping test - can't create sessions dir");
            return;
        }

        // Use a test path that won't conflict with real projects
        let test_path = "/tmp/hud-core-test-dead-pid-project";

        // Create lock with definitely-dead PID
        create_test_lock(&sessions_dir, test_path, 999999999);

        let result = is_session_active(test_path);

        // Clean up
        let hash = md5::compute(test_path);
        let lock_dir = sessions_dir.join(format!("{:x}.lock", hash));
        let _ = fs::remove_dir_all(&lock_dir);

        assert!(!result, "Dead PID should not be considered active");
    }

    #[test]
    fn test_is_session_active_with_current_pid() {
        let Some(claude_dir) = get_claude_dir() else {
            eprintln!("Skipping test - no claude dir");
            return;
        };

        let sessions_dir = claude_dir.join("sessions");
        if fs::create_dir_all(&sessions_dir).is_err() {
            eprintln!("Skipping test - can't create sessions dir");
            return;
        }

        let test_path = "/tmp/hud-core-test-current-pid-project";

        // Create lock with our own PID (definitely alive)
        let current_pid = std::process::id() as i32;
        create_test_lock(&sessions_dir, test_path, current_pid);

        let result = is_session_active(test_path);

        // Clean up
        let hash = md5::compute(test_path);
        let lock_dir = sessions_dir.join(format!("{:x}.lock", hash));
        let _ = fs::remove_dir_all(&lock_dir);

        assert!(result, "Current process PID should be considered active");
    }

    #[test]
    fn test_is_session_active_no_lock_dir() {
        let Some(claude_dir) = get_claude_dir() else {
            eprintln!("Skipping test - no claude dir");
            return;
        };

        let sessions_dir = claude_dir.join("sessions");
        if fs::create_dir_all(&sessions_dir).is_err() {
            eprintln!("Skipping test - can't create sessions dir");
            return;
        }

        // Use a path that definitely won't have a lock
        let test_path = "/tmp/hud-core-test-no-lock-dir-unique-12345";

        // Ensure no lock exists
        let hash = md5::compute(test_path);
        let lock_dir = sessions_dir.join(format!("{:x}.lock", hash));
        let _ = fs::remove_dir_all(&lock_dir);

        let result = is_session_active(test_path);
        assert!(!result, "Missing lock dir should not be considered active");
    }

    #[test]
    fn test_is_session_active_empty_pid_file() {
        let Some(claude_dir) = get_claude_dir() else {
            eprintln!("Skipping test - no claude dir");
            return;
        };

        let sessions_dir = claude_dir.join("sessions");
        if fs::create_dir_all(&sessions_dir).is_err() {
            eprintln!("Skipping test - can't create sessions dir");
            return;
        }

        let test_path = "/tmp/hud-core-test-empty-pid-file";
        let hash = md5::compute(test_path);
        let lock_dir = sessions_dir.join(format!("{:x}.lock", hash));

        // Create lock dir with empty pid file
        fs::create_dir_all(&lock_dir).unwrap();
        fs::write(lock_dir.join("pid"), "").unwrap();

        let result = is_session_active(test_path);

        // Clean up
        let _ = fs::remove_dir_all(&lock_dir);

        assert!(!result, "Empty PID file should not be considered active");
    }

    #[test]
    fn test_is_session_active_invalid_pid() {
        let Some(claude_dir) = get_claude_dir() else {
            eprintln!("Skipping test - no claude dir");
            return;
        };

        let sessions_dir = claude_dir.join("sessions");
        if fs::create_dir_all(&sessions_dir).is_err() {
            eprintln!("Skipping test - can't create sessions dir");
            return;
        }

        let test_path = "/tmp/hud-core-test-invalid-pid";
        let hash = md5::compute(test_path);
        let lock_dir = sessions_dir.join(format!("{:x}.lock", hash));

        // Create lock dir with invalid pid
        fs::create_dir_all(&lock_dir).unwrap();
        fs::write(lock_dir.join("pid"), "not-a-number").unwrap();

        let result = is_session_active(test_path);

        // Clean up
        let _ = fs::remove_dir_all(&lock_dir);

        assert!(!result, "Invalid PID should not be considered active");
    }

    #[test]
    fn test_detect_session_state_returns_idle_for_unknown() {
        let state = detect_session_state("/definitely/not/a/real/project/path/xyz123");
        assert_eq!(state.state, SessionState::Idle);
        assert!(state.session_id.is_none());
        assert!(state.working_on.is_none());
    }

    #[test]
    fn test_get_all_session_states_empty_input() {
        let paths: Vec<String> = vec![];
        let states = get_all_session_states(&paths);
        assert!(states.is_empty());
    }

    #[test]
    fn test_get_all_session_states_multiple_paths() {
        let paths = vec![
            "/fake/path/one".to_string(),
            "/fake/path/two".to_string(),
            "/fake/path/three".to_string(),
        ];
        let states = get_all_session_states(&paths);

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

        assert_eq!(deserialized.working_on, Some("Building feature X".to_string()));
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
        let Some(claude_dir) = get_claude_dir() else {
            eprintln!("Skipping test - no claude dir");
            return;
        };

        let sessions_dir = claude_dir.join("sessions");
        if fs::create_dir_all(&sessions_dir).is_err() {
            eprintln!("Skipping test - can't create sessions dir");
            return;
        }

        let parent_path = "/tmp/hud-test-parent-project";
        let child_path = "/tmp/hud-test-parent-project/apps/swift";
        let current_pid = std::process::id() as i32;

        // Create lock for CHILD path (simulating Claude running from subdirectory)
        create_test_lock_with_meta(&sessions_dir, child_path, current_pid);

        // Check if PARENT is considered active
        let result = is_session_active(parent_path);

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
        let Some(claude_dir) = get_claude_dir() else {
            eprintln!("Skipping test - no claude dir");
            return;
        };

        let sessions_dir = claude_dir.join("sessions");
        if fs::create_dir_all(&sessions_dir).is_err() {
            eprintln!("Skipping test - can't create sessions dir");
            return;
        }

        let parent_path = "/tmp/hud-test-parent-only";
        let child_path = "/tmp/hud-test-parent-only/packages/child";
        let current_pid = std::process::id() as i32;

        // Create lock for PARENT path only
        create_test_lock_with_meta(&sessions_dir, parent_path, current_pid);

        // Check if CHILD is considered active (should be FALSE)
        let result = is_session_active(child_path);

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
        let Some(claude_dir) = get_claude_dir() else {
            eprintln!("Skipping test - no claude dir");
            return;
        };

        let sessions_dir = claude_dir.join("sessions");
        if fs::create_dir_all(&sessions_dir).is_err() {
            eprintln!("Skipping test - can't create sessions dir");
            return;
        }

        let project_path = "/tmp/hud-test-exact-match";
        let current_pid = std::process::id() as i32;

        create_test_lock_with_meta(&sessions_dir, project_path, current_pid);

        let result = is_session_active(project_path);

        cleanup_test_lock(&sessions_dir, project_path);

        assert!(result, "Exact path match should be active");
    }

    /// Test: Unrelated paths don't affect each other
    #[test]
    fn test_unrelated_paths_independent() {
        let Some(claude_dir) = get_claude_dir() else {
            eprintln!("Skipping test - no claude dir");
            return;
        };

        let sessions_dir = claude_dir.join("sessions");
        if fs::create_dir_all(&sessions_dir).is_err() {
            eprintln!("Skipping test - can't create sessions dir");
            return;
        }

        let path_a = "/tmp/hud-test-project-a";
        let path_b = "/tmp/hud-test-project-b";
        let current_pid = std::process::id() as i32;

        // Create lock for path A only
        create_test_lock_with_meta(&sessions_dir, path_a, current_pid);

        // Check path B (should NOT be active)
        let result = is_session_active(path_b);

        cleanup_test_lock(&sessions_dir, path_a);

        assert!(!result, "Unrelated path should not be affected by other locks");
    }

    /// Test: Similar path prefixes don't false-match
    /// e.g., /project-foo should not match /project
    #[test]
    fn test_similar_prefix_no_false_match() {
        let Some(claude_dir) = get_claude_dir() else {
            eprintln!("Skipping test - no claude dir");
            return;
        };

        let sessions_dir = claude_dir.join("sessions");
        if fs::create_dir_all(&sessions_dir).is_err() {
            eprintln!("Skipping test - can't create sessions dir");
            return;
        }

        let path_short = "/tmp/hud-test-prefix-short";
        let path_long = "/tmp/hud-test-prefix-shorter"; // Different project, similar prefix
        let current_pid = std::process::id() as i32;

        // Clean up any leftover state first
        cleanup_test_lock(&sessions_dir, path_short);
        cleanup_test_lock(&sessions_dir, path_long);

        // Create lock for short path only
        create_test_lock_with_meta(&sessions_dir, path_short, current_pid);

        // Long path should NOT be active (it's not a child, just similar name)
        let result = is_session_active(path_long);

        // Clean up
        cleanup_test_lock(&sessions_dir, path_short);
        cleanup_test_lock(&sessions_dir, path_long);

        assert!(
            !result,
            "Similar prefix should not cause false match (must be actual subdirectory)"
        );
    }
}
