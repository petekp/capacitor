//! File-backed session state persistence.
//!
//! Stores session records in `~/.capacitor/sessions.json`. Both the hook script
//! and the engine can read and write this file.
//!
//! # File Format
//!
//! ```json
//! {
//!   "version": 3,
//!   "sessions": {
//!     "session-abc": { ... SessionRecord fields ... }
//!   }
//! }
//! ```
//!
//! # Session Lookup
//!
//! Sessions are looked up by exact session ID only. Use `get_by_session_id()`.
//!
//! # Defensive Design
//!
//! Since the hook script writes this file asynchronously, we handle:
//! - Empty files (return empty store)
//! - Corrupt JSON (return empty store, log warning)
//! - Version mismatches (return empty store for incompatible versions)
//! - Missing fields (serde defaults)
//!
//! # Atomic Writes
//!
//! Uses temp file + rename to prevent partial writes from crashing the app.

use fs_err as fs;
use std::collections::HashMap;
use std::io::Write;
use std::path::{Path, PathBuf};

use chrono::Utc;
use serde::{Deserialize, Serialize};
use tempfile::NamedTempFile;

use crate::types::SessionState;

use super::types::SessionRecord;

/// The on-disk JSON structure for the state file.
#[derive(Debug, Serialize, Deserialize)]
struct StoreFile {
    /// Schema version. We only load files with version == 3.
    version: u32,
    /// Session ID → record map.
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

/// In-memory cache of session records, optionally backed by a file.
///
/// Create with [`StateStore::load`] to read from the state file,
/// or [`StateStore::new_in_memory`] for tests.
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
            tracing::warn!("Empty state file, returning empty store");
            return Ok(StateStore::new(file_path));
        }

        // Defensive: Handle JSON parse errors
        match serde_json::from_str::<StoreFile>(&content) {
            Ok(store_file) if store_file.version == 3 => Ok(StateStore {
                sessions: store_file.sessions,
                file_path: Some(file_path.to_path_buf()),
            }),
            Ok(store_file) => {
                tracing::warn!(
                    version = store_file.version,
                    "Unsupported state file version (expected 3), returning empty store"
                );
                Ok(StateStore::new(file_path))
            }
            Err(e) => {
                tracing::warn!(
                    error = %e,
                    "Failed to parse state file, returning empty store"
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

    /// Returns an iterator over all session records.
    pub fn sessions(&self) -> impl Iterator<Item = &SessionRecord> {
        self.sessions.values()
    }

    pub fn all_sessions(&self) -> impl Iterator<Item = &SessionRecord> {
        self.sessions.values()
    }

    /// Test helper: Set timestamp for a session record.
    /// Only available with the `test-helpers` feature or in tests.
    #[cfg(any(test, feature = "test-helpers"))]
    pub fn set_timestamp_for_test(
        &mut self,
        session_id: &str,
        timestamp: chrono::DateTime<chrono::Utc>,
    ) {
        if let Some(record) = self.sessions.get_mut(session_id) {
            record.updated_at = timestamp;
        }
    }

    /// Test helper: Set state_changed_at for a session record.
    /// Only available with the `test-helpers` feature or in tests.
    #[cfg(any(test, feature = "test-helpers"))]
    pub fn set_state_changed_at_for_test(
        &mut self,
        session_id: &str,
        timestamp: chrono::DateTime<chrono::Utc>,
    ) {
        if let Some(record) = self.sessions.get_mut(session_id) {
            record.state_changed_at = timestamp;
        }
    }

    /// Test helper: Set project_dir for a session record.
    /// Only available with the `test-helpers` feature or in tests.
    #[cfg(any(test, feature = "test-helpers"))]
    pub fn set_project_dir_for_test(&mut self, session_id: &str, project_dir: Option<&str>) {
        if let Some(record) = self.sessions.get_mut(session_id) {
            record.project_dir = project_dir.map(|s| s.to_string());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
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
