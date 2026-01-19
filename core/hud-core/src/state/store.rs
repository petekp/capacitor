use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use chrono::Utc;
use serde::{Deserialize, Serialize};

use super::lock::is_pid_alive;
use super::types::{ClaudeState, SessionRecord};

/// Normalize a path for consistent comparison.
/// Strips trailing slashes except for root "/".
fn normalize_path(path: &str) -> String {
    if path == "/" {
        "/".to_string()
    } else {
        path.trim_end_matches('/').to_string()
    }
}

#[derive(Debug, Serialize, Deserialize)]
struct StoreFile {
    version: u32,
    sessions: HashMap<String, SessionRecord>,
}

impl Default for StoreFile {
    fn default() -> Self {
        StoreFile {
            version: 2,
            sessions: HashMap::new(),
        }
    }
}

pub struct StateStore {
    sessions: HashMap<String, SessionRecord>,
    file_path: Option<PathBuf>,
}

impl StateStore {
    pub fn new_in_memory() -> Self {
        StateStore {
            sessions: HashMap::new(),
            file_path: None,
        }
    }

    pub fn new(file_path: &Path) -> Self {
        StateStore {
            sessions: HashMap::new(),
            file_path: Some(file_path.to_path_buf()),
        }
    }

    pub fn load(file_path: &Path) -> Result<Self, String> {
        if !file_path.exists() {
            return Ok(StateStore::new(file_path));
        }

        let content = fs::read_to_string(file_path)
            .map_err(|e| format!("Failed to read state file: {}", e))?;

        // Defensive: Handle empty file
        if content.trim().is_empty() {
            eprintln!("Warning: Empty state file, returning empty store");
            return Ok(StateStore::new(file_path));
        }

        // Defensive: Handle JSON parse errors
        match serde_json::from_str::<StoreFile>(&content) {
            Ok(store_file) => {
                // Opportunistic cleanup: Remove sessions with dead PIDs
                let cleaned_sessions: HashMap<String, SessionRecord> = store_file
                    .sessions
                    .into_iter()
                    .filter(|(_, record)| match record.pid {
                        Some(pid) => is_pid_alive(pid),
                        None => true, // Keep sessions without PID (legacy)
                    })
                    .collect();

                Ok(StateStore {
                    sessions: cleaned_sessions,
                    file_path: Some(file_path.to_path_buf()),
                })
            }
            Err(e) => {
                eprintln!(
                    "Warning: Failed to parse state file ({}), returning empty store",
                    e
                );
                // Defensive: Corrupt JSON → empty store (don't crash)
                Ok(StateStore::new(file_path))
            }
        }
    }

    pub fn save(&self) -> Result<(), String> {
        let file_path = self
            .file_path
            .as_ref()
            .ok_or_else(|| "No file path set for in-memory store".to_string())?;

        let store_file = StoreFile {
            version: 2,
            sessions: self.sessions.clone(),
        };

        let content = serde_json::to_string_pretty(&store_file)
            .map_err(|e| format!("Failed to serialize: {}", e))?;

        fs::write(file_path, content).map_err(|e| format!("Failed to write state file: {}", e))?;

        Ok(())
    }

    pub fn update(&mut self, session_id: &str, state: ClaudeState, cwd: &str) {
        let existing = self.sessions.get(session_id);
        let working_on = existing.and_then(|r| r.working_on.clone());
        let pid = existing.and_then(|r| r.pid);

        self.sessions.insert(
            session_id.to_string(),
            SessionRecord {
                session_id: session_id.to_string(),
                state,
                cwd: cwd.to_string(),
                updated_at: Utc::now(),
                working_on,
                pid,
            },
        );
    }

    pub fn remove(&mut self, session_id: &str) {
        self.sessions.remove(session_id);
    }

    pub fn get_by_session_id(&self, session_id: &str) -> Option<&SessionRecord> {
        self.sessions.get(session_id)
    }

    pub fn find_by_cwd(&self, cwd: &str) -> Option<&SessionRecord> {
        let mut best: Option<&SessionRecord> = None;

        // Normalize query path for consistent comparison
        let cwd_normalized = normalize_path(cwd);

        // 1. Exact match - collect all, don't return early
        for record in self.sessions.values() {
            let record_cwd_normalized = normalize_path(&record.cwd);
            if record_cwd_normalized == cwd_normalized {
                match best {
                    None => best = Some(record),
                    Some(current) if record.updated_at > current.updated_at => best = Some(record),
                    _ => {}
                }
            }
        }

        // 2. Session is in a CHILD directory of the query path
        // e.g., query="/project", session.cwd="/project/subdir"
        // Don't return early - child might be fresher than exact match

        // Special case for root: children of "/" are paths starting with "/" (not "//")
        let is_root_query = cwd_normalized == "/";
        let cwd_with_slash = if is_root_query {
            "/".to_string()
        } else {
            format!("{}/", cwd_normalized)
        };

        for record in self.sessions.values() {
            let record_cwd_normalized = normalize_path(&record.cwd);

            let is_child = if is_root_query {
                // For root query, match any path except root itself
                record_cwd_normalized != "/" && record_cwd_normalized.starts_with(&cwd_with_slash)
            } else {
                record_cwd_normalized.starts_with(&cwd_with_slash)
            };

            if is_child {
                match best {
                    None => best = Some(record),
                    Some(current) if record.updated_at > current.updated_at => best = Some(record),
                    _ => {}
                }
            }
        }

        // If we found exact or child match, return it
        // Child sessions take precedence over parent fallbacks
        if best.is_some() {
            return best;
        }

        // 3. Session is in a PARENT directory of the query path
        // e.g., query="/project/subdir", session.cwd="/project"
        // Only use parent as fallback if no exact/child found
        let mut current_path = cwd_normalized.as_str();
        while let Some(parent) = Path::new(current_path).parent() {
            let parent_str = parent.to_string_lossy();
            let parent_normalized = normalize_path(&parent_str);
            if parent_normalized.is_empty() || parent_normalized == "/" {
                break;
            }

            for record in self.sessions.values() {
                let record_cwd_normalized = normalize_path(&record.cwd);
                if record_cwd_normalized == parent_normalized {
                    match best {
                        None => best = Some(record),
                        Some(current) if record.updated_at > current.updated_at => {
                            best = Some(record)
                        }
                        _ => {}
                    }
                }
            }

            if best.is_some() {
                return best;
            }

            current_path = parent.to_str().unwrap_or("");
        }

        None
    }

    pub fn all_sessions(&self) -> impl Iterator<Item = &SessionRecord> {
        self.sessions.values()
    }

    #[cfg(test)]
    pub fn set_pid_for_test(&mut self, session_id: &str, pid: u32) {
        if let Some(record) = self.sessions.get_mut(session_id) {
            record.pid = Some(pid);
        }
    }

    #[cfg(test)]
    pub fn set_timestamp_for_test(
        &mut self,
        session_id: &str,
        timestamp: chrono::DateTime<chrono::Utc>,
    ) {
        if let Some(record) = self.sessions.get_mut(session_id) {
            record.updated_at = timestamp;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;
    use std::time::Duration;
    use tempfile::tempdir;

    #[test]
    fn test_empty_store_has_no_sessions() {
        let store = StateStore::new_in_memory();
        assert!(store.get_by_session_id("abc").is_none());
    }

    #[test]
    fn test_update_creates_session() {
        let mut store = StateStore::new_in_memory();
        store.update("session-1", ClaudeState::Working, "/project");
        let record = store.get_by_session_id("session-1").unwrap();
        assert_eq!(record.state, ClaudeState::Working);
        assert_eq!(record.cwd, "/project");
    }

    #[test]
    fn test_update_overwrites_session() {
        let mut store = StateStore::new_in_memory();
        store.update("session-1", ClaudeState::Working, "/project");
        store.update("session-1", ClaudeState::Ready, "/project");
        assert_eq!(
            store.get_by_session_id("session-1").unwrap().state,
            ClaudeState::Ready
        );
    }

    #[test]
    fn test_remove_deletes_session() {
        let mut store = StateStore::new_in_memory();
        store.update("session-1", ClaudeState::Ready, "/project");
        store.remove("session-1");
        assert!(store.get_by_session_id("session-1").is_none());
    }

    #[test]
    fn test_find_by_cwd_returns_most_recent() {
        let mut store = StateStore::new_in_memory();
        store.update("old", ClaudeState::Ready, "/project");
        thread::sleep(Duration::from_millis(10));
        store.update("new", ClaudeState::Working, "/project");
        let record = store.find_by_cwd("/project").unwrap();
        assert_eq!(record.session_id, "new");
    }

    #[test]
    fn test_find_by_cwd_checks_parent_paths() {
        let mut store = StateStore::new_in_memory();
        store.update("parent-session", ClaudeState::Working, "/parent");
        let record = store.find_by_cwd("/parent/child").unwrap();
        assert_eq!(record.session_id, "parent-session");
    }

    #[test]
    fn test_find_by_cwd_prefers_exact_match_over_parent() {
        let mut store = StateStore::new_in_memory();
        store.update("parent-session", ClaudeState::Working, "/parent");
        store.update("child-session", ClaudeState::Ready, "/parent/child");
        let record = store.find_by_cwd("/parent/child").unwrap();
        assert_eq!(record.session_id, "child-session");
    }

    #[test]
    fn test_find_by_cwd_finds_child_session_from_parent_query() {
        // This is the critical case: pinned project is /project but session runs from /project/subdir
        let mut store = StateStore::new_in_memory();
        store.update("child-session", ClaudeState::Working, "/project/apps/swift");
        let record = store.find_by_cwd("/project").unwrap();
        assert_eq!(record.session_id, "child-session");
        assert_eq!(record.cwd, "/project/apps/swift");
    }

    #[test]
    fn test_persistence_round_trip() {
        let temp = tempdir().unwrap();
        let file = temp.path().join("state.json");

        {
            let mut store = StateStore::new(&file);
            store.update("s1", ClaudeState::Working, "/proj");
            store.save().unwrap();
        }

        let store = StateStore::load(&file).unwrap();
        assert_eq!(
            store.get_by_session_id("s1").unwrap().state,
            ClaudeState::Working
        );
    }

    #[test]
    fn test_load_nonexistent_file_returns_empty_store() {
        let temp = tempdir().unwrap();
        let file = temp.path().join("nonexistent.json");
        let store = StateStore::load(&file).unwrap();
        assert!(store.get_by_session_id("any").is_none());
    }

    #[test]
    fn test_all_sessions_returns_all() {
        let mut store = StateStore::new_in_memory();
        store.update("s1", ClaudeState::Working, "/proj1");
        store.update("s2", ClaudeState::Ready, "/proj2");
        let sessions: Vec<_> = store.all_sessions().collect();
        assert_eq!(sessions.len(), 2);
    }

    #[test]
    fn test_find_by_cwd_returns_most_recent_when_multiple_at_same_path() {
        let mut store = StateStore::new_in_memory();

        // Create session-1 at /project
        store.update("session-1", ClaudeState::Working, "/project");
        store.set_pid_for_test("session-1", 1234);

        thread::sleep(Duration::from_millis(10));

        // Create session-2 at /project (more recent)
        store.update("session-2", ClaudeState::Ready, "/project");
        store.set_pid_for_test("session-2", 5678);

        // Query for /project should return the more recent session (session-2)
        // Timestamp-based selection, no PID tie-breaking
        let record = store.find_by_cwd("/project").unwrap();

        // Should get the fresher one (session-2) since both have same cwd
        assert_eq!(record.session_id, "session-2");
    }

    #[test]
    fn test_load_empty_file_returns_empty_store() {
        let temp = tempdir().unwrap();
        let file = temp.path().join("empty.json");
        fs::write(&file, "").unwrap();

        let store = StateStore::load(&file).unwrap();
        assert!(store.get_by_session_id("any").is_none());
        assert_eq!(store.all_sessions().count(), 0);
    }

    #[test]
    fn test_load_corrupt_json_returns_empty_store() {
        let temp = tempdir().unwrap();
        let file = temp.path().join("corrupt.json");
        fs::write(&file, "{invalid json}").unwrap();

        let store = StateStore::load(&file).unwrap();
        assert!(store.get_by_session_id("any").is_none());
        assert_eq!(store.all_sessions().count(), 0);
    }

    #[test]
    fn test_load_cleans_up_dead_pids() {
        let temp = tempdir().unwrap();
        let file = temp.path().join("with_dead_pid.json");

        // Create a state file with one live PID and one dead PID
        let live_pid = std::process::id();
        let dead_pid = 99999999u32; // Unlikely to be alive

        let content = format!(
            r#"{{
                "version": 2,
                "sessions": {{
                    "live-session": {{
                        "session_id": "live-session",
                        "state": "working",
                        "cwd": "/project1",
                        "updated_at": "2024-01-01T00:00:00Z",
                        "pid": {}
                    }},
                    "dead-session": {{
                        "session_id": "dead-session",
                        "state": "working",
                        "cwd": "/project2",
                        "updated_at": "2024-01-01T00:00:00Z",
                        "pid": {}
                    }}
                }}
            }}"#,
            live_pid, dead_pid
        );
        fs::write(&file, content).unwrap();

        let store = StateStore::load(&file).unwrap();

        // Live session should be kept
        assert!(store.get_by_session_id("live-session").is_some());

        // Dead session should be removed
        assert!(store.get_by_session_id("dead-session").is_none());

        // Should have exactly 1 session
        assert_eq!(store.all_sessions().count(), 1);
    }

    #[test]
    fn test_load_keeps_sessions_without_pid() {
        let temp = tempdir().unwrap();
        let file = temp.path().join("no_pid.json");

        let content = r#"{
            "version": 2,
            "sessions": {
                "legacy-session": {
                    "session_id": "legacy-session",
                    "state": "working",
                    "cwd": "/project",
                    "updated_at": "2024-01-01T00:00:00Z"
                }
            }
        }"#;
        fs::write(&file, content).unwrap();

        let store = StateStore::load(&file).unwrap();

        // Legacy session without PID should be kept
        assert!(store.get_by_session_id("legacy-session").is_some());
        assert_eq!(store.all_sessions().count(), 1);
    }
}
