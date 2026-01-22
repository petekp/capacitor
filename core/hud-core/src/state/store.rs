//! File-backed session store with defensive parsing and atomic writes.

use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use chrono::Utc;
use serde::{Deserialize, Serialize};
use tempfile::NamedTempFile;

use crate::types::SessionState;

use super::types::SessionRecord;

/// Normalize a path for consistent comparison.
/// Strips trailing slashes except for root "/".
fn normalize_path(path: &str) -> String {
    if path == "/" {
        "/".to_string()
    } else {
        path.trim_end_matches('/').to_string()
    }
}

fn record_match_paths<'a>(record: &'a SessionRecord) -> impl Iterator<Item = &'a str> {
    [Some(record.cwd.as_str()), record.project_dir.as_deref()]
        .into_iter()
        .flatten()
}

#[derive(Debug, Serialize, Deserialize)]
struct StoreFile {
    version: u32,
    sessions: HashMap<String, SessionRecord>,
}

impl Default for StoreFile {
    fn default() -> Self {
        StoreFile {
            version: 3,
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
            Ok(store_file) if store_file.version == 3 => Ok(StateStore {
                sessions: store_file.sessions,
                file_path: Some(file_path.to_path_buf()),
            }),
            Ok(store_file) => {
                eprintln!(
                    "Warning: Unsupported state file version {} (expected 3), returning empty store",
                    store_file.version
                );
                Ok(StateStore::new(file_path))
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
            version: 3,
            sessions: self.sessions.clone(),
        };

        let content = serde_json::to_string_pretty(&store_file)
            .map_err(|e| format!("Failed to serialize: {}", e))?;

        let parent_dir = file_path
            .parent()
            .ok_or_else(|| "State file path has no parent directory".to_string())?;
        let mut temp_file =
            NamedTempFile::new_in(parent_dir).map_err(|e| format!("Temp file error: {}", e))?;
        temp_file
            .write_all(content.as_bytes())
            .map_err(|e| format!("Failed to write temp state file: {}", e))?;
        temp_file
            .flush()
            .map_err(|e| format!("Failed to flush temp state file: {}", e))?;
        temp_file
            .persist(file_path)
            .map_err(|e| format!("Failed to write state file: {}", e.error))?;

        Ok(())
    }

    pub fn update(&mut self, session_id: &str, state: SessionState, cwd: &str) {
        let now = Utc::now();

        let existing = self.sessions.get(session_id);

        let state_changed_at = match existing {
            Some(r) if r.state == state => r.state_changed_at,
            _ => now,
        };

        self.sessions.insert(
            session_id.to_string(),
            SessionRecord {
                session_id: session_id.to_string(),
                state,
                cwd: cwd.to_string(),
                updated_at: now,
                state_changed_at,
                working_on: existing.and_then(|r| r.working_on.clone()),
                transcript_path: existing.and_then(|r| r.transcript_path.clone()),
                permission_mode: existing.and_then(|r| r.permission_mode.clone()),
                project_dir: existing.and_then(|r| r.project_dir.clone()),
                last_event: existing.and_then(|r| r.last_event.clone()),
                active_subagent_count: existing.map_or(0, |r| r.active_subagent_count),
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
            let is_exact = record_match_paths(record).any(|p| normalize_path(p) == cwd_normalized);
            if !is_exact {
                continue;
            }
            match best {
                None => best = Some(record),
                Some(current) if record.updated_at > current.updated_at => best = Some(record),
                _ => {}
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
            let is_child = record_match_paths(record).any(|p| {
                let record_path_normalized = normalize_path(p);
                if is_root_query {
                    // For root query, match any path except root itself
                    record_path_normalized != "/"
                        && record_path_normalized.starts_with(&cwd_with_slash)
                } else {
                    record_path_normalized.starts_with(&cwd_with_slash)
                }
            });

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
                let is_exact_parent =
                    record_match_paths(record).any(|p| normalize_path(p) == parent_normalized);
                if !is_exact_parent {
                    continue;
                }
                match best {
                    None => best = Some(record),
                    Some(current) if record.updated_at > current.updated_at => best = Some(record),
                    _ => {}
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
    pub fn set_timestamp_for_test(
        &mut self,
        session_id: &str,
        timestamp: chrono::DateTime<chrono::Utc>,
    ) {
        if let Some(record) = self.sessions.get_mut(session_id) {
            record.updated_at = timestamp;
        }
    }

    #[cfg(test)]
    pub fn set_state_changed_at_for_test(
        &mut self,
        session_id: &str,
        timestamp: chrono::DateTime<chrono::Utc>,
    ) {
        if let Some(record) = self.sessions.get_mut(session_id) {
            record.state_changed_at = timestamp;
        }
    }

    #[cfg(test)]
    pub fn set_project_dir_for_test(&mut self, session_id: &str, project_dir: Option<&str>) {
        if let Some(record) = self.sessions.get_mut(session_id) {
            record.project_dir = project_dir.map(|s| s.to_string());
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
        store.update("session-1", SessionState::Working, "/project");
        let record = store.get_by_session_id("session-1").unwrap();
        assert_eq!(record.state, SessionState::Working);
        assert_eq!(record.cwd, "/project");
    }

    #[test]
    fn test_update_overwrites_session() {
        let mut store = StateStore::new_in_memory();
        store.update("session-1", SessionState::Working, "/project");
        store.update("session-1", SessionState::Ready, "/project");
        assert_eq!(
            store.get_by_session_id("session-1").unwrap().state,
            SessionState::Ready
        );
    }

    #[test]
    fn test_remove_deletes_session() {
        let mut store = StateStore::new_in_memory();
        store.update("session-1", SessionState::Ready, "/project");
        store.remove("session-1");
        assert!(store.get_by_session_id("session-1").is_none());
    }

    #[test]
    fn test_find_by_cwd_returns_most_recent() {
        let mut store = StateStore::new_in_memory();
        store.update("old", SessionState::Ready, "/project");
        thread::sleep(Duration::from_millis(10));
        store.update("new", SessionState::Working, "/project");
        let record = store.find_by_cwd("/project").unwrap();
        assert_eq!(record.session_id, "new");
    }

    #[test]
    fn test_find_by_cwd_checks_parent_paths() {
        let mut store = StateStore::new_in_memory();
        store.update("parent-session", SessionState::Working, "/parent");
        let record = store.find_by_cwd("/parent/child").unwrap();
        assert_eq!(record.session_id, "parent-session");
    }

    #[test]
    fn test_find_by_cwd_prefers_exact_match_over_parent() {
        let mut store = StateStore::new_in_memory();
        store.update("parent-session", SessionState::Working, "/parent");
        store.update("child-session", SessionState::Ready, "/parent/child");
        let record = store.find_by_cwd("/parent/child").unwrap();
        assert_eq!(record.session_id, "child-session");
    }

    #[test]
    fn test_find_by_cwd_finds_child_session_from_parent_query() {
        // This is the critical case: pinned project is /project but session runs from /project/subdir
        let mut store = StateStore::new_in_memory();
        store.update(
            "child-session",
            SessionState::Working,
            "/project/apps/swift",
        );
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
            store.update("s1", SessionState::Working, "/proj");
            store.save().unwrap();
        }

        let store = StateStore::load(&file).unwrap();
        assert_eq!(
            store.get_by_session_id("s1").unwrap().state,
            SessionState::Working
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
        store.update("s1", SessionState::Working, "/proj1");
        store.update("s2", SessionState::Ready, "/proj2");
        let sessions: Vec<_> = store.all_sessions().collect();
        assert_eq!(sessions.len(), 2);
    }

    #[test]
    fn test_find_by_cwd_returns_most_recent_when_multiple_at_same_path() {
        let mut store = StateStore::new_in_memory();

        // Create session-1 at /project
        store.update("session-1", SessionState::Working, "/project");

        thread::sleep(Duration::from_millis(10));

        // Create session-2 at /project (more recent)
        store.update("session-2", SessionState::Ready, "/project");

        // Query for /project should return the more recent session (session-2)
        // Timestamp-based selection, no PID tie-breaking
        let record = store.find_by_cwd("/project").unwrap();

        // Should get the fresher one (session-2) since both have same cwd
        assert_eq!(record.session_id, "session-2");
    }

    #[test]
    fn test_find_by_cwd_matches_project_dir_when_cwd_is_unrelated() {
        let mut store = StateStore::new_in_memory();
        store.update("s1", SessionState::Working, "/wrong");
        store.set_project_dir_for_test("s1", Some("/project"));

        let record = store.find_by_cwd("/project").unwrap();
        assert_eq!(record.session_id, "s1");
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
    fn test_load_unsupported_version_returns_empty_store() {
        let temp = tempdir().unwrap();
        let file = temp.path().join("v2.json");
        fs::write(&file, r#"{"version":2,"sessions":{}}"#).unwrap();

        let store = StateStore::load(&file).unwrap();
        assert_eq!(store.all_sessions().count(), 0);
    }
}
