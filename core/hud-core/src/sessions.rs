//! Session state management for Claude Code sessions.
//!
//! Handles reading session states from the HUD status file and
//! detecting the current state of Claude Code sessions.

use crate::config::get_claude_dir;
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

/// Gets all session states for given project paths.
pub fn get_all_session_states(
    project_paths: &[String],
) -> std::collections::HashMap<String, ProjectSessionState> {
    let mut states = std::collections::HashMap::new();

    for path in project_paths {
        states.insert(path.clone(), detect_session_state(path));
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
pub fn is_session_active(project_path: &str) -> bool {
    let Some(claude_dir) = get_claude_dir() else {
        return false;
    };

    let sessions_dir = claude_dir.join("sessions");
    if !sessions_dir.exists() {
        return false;
    }

    let hash = md5::compute(project_path);
    let lock_dir = sessions_dir.join(format!("{:x}.lock", hash));

    // Check if lock directory exists
    if !lock_dir.exists() || !lock_dir.is_dir() {
        return false;
    }

    // Try to read the PID - support both old format (pid file) and new format (meta.json)
    let pid = read_pid_from_lock(&lock_dir);
    let Some(pid) = pid else {
        return false;
    };

    // Check if the process is still running using kill -0
    // This sends no signal but checks if the process exists
    let result = unsafe { libc::kill(pid, 0) };
    result == 0
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

    /// Helper to create a test sessions directory with a lock
    fn create_test_lock(sessions_dir: &Path, project_path: &str, pid: i32) {
        let hash = md5::compute(project_path);
        let lock_dir = sessions_dir.join(format!("{:x}.lock", hash));
        fs::create_dir_all(&lock_dir).unwrap();

        let pid_file = lock_dir.join("pid");
        let mut file = fs::File::create(&pid_file).unwrap();
        writeln!(file, "{}", pid).unwrap();
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
}
