use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use chrono::Utc;
use serde::{Deserialize, Serialize};

use super::types::{ClaudeState, SessionRecord};

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

        let content = fs::read_to_string(file_path).map_err(|e| format!("Failed to read state file: {}", e))?;

        let store_file: StoreFile =
            serde_json::from_str(&content).map_err(|e| format!("Failed to parse state file: {}", e))?;

        Ok(StateStore {
            sessions: store_file.sessions,
            file_path: Some(file_path.to_path_buf()),
        })
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

        let content = serde_json::to_string_pretty(&store_file).map_err(|e| format!("Failed to serialize: {}", e))?;

        fs::write(file_path, content).map_err(|e| format!("Failed to write state file: {}", e))?;

        Ok(())
    }

    pub fn update(&mut self, session_id: &str, state: ClaudeState, cwd: &str) {
        self.sessions.insert(
            session_id.to_string(),
            SessionRecord {
                session_id: session_id.to_string(),
                state,
                cwd: cwd.to_string(),
                updated_at: Utc::now(),
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

        // 1. Exact match
        for record in self.sessions.values() {
            if record.cwd == cwd {
                match best {
                    None => best = Some(record),
                    Some(current) if record.updated_at > current.updated_at => best = Some(record),
                    _ => {}
                }
            }
        }

        if best.is_some() {
            return best;
        }

        // 2. Session is in a CHILD directory of the query path
        // e.g., query="/project", session.cwd="/project/subdir"
        let cwd_with_slash = if cwd.ends_with('/') {
            cwd.to_string()
        } else {
            format!("{}/", cwd)
        };

        for record in self.sessions.values() {
            if record.cwd.starts_with(&cwd_with_slash) {
                match best {
                    None => best = Some(record),
                    Some(current) if record.updated_at > current.updated_at => best = Some(record),
                    _ => {}
                }
            }
        }

        if best.is_some() {
            return best;
        }

        // 3. Session is in a PARENT directory of the query path
        // e.g., query="/project/subdir", session.cwd="/project"
        let mut current_path = cwd;
        while let Some(parent) = Path::new(current_path).parent() {
            let parent_str = parent.to_string_lossy();
            if parent_str.is_empty() || parent_str == "/" {
                break;
            }

            for record in self.sessions.values() {
                if record.cwd == parent_str {
                    match best {
                        None => best = Some(record),
                        Some(current) if record.updated_at > current.updated_at => best = Some(record),
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
        assert_eq!(store.get_by_session_id("session-1").unwrap().state, ClaudeState::Ready);
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
        assert_eq!(store.get_by_session_id("s1").unwrap().state, ClaudeState::Working);
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
}
