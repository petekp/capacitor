//! Claude Code adapter backed by lock liveness and the v3 state store.

use std::path::PathBuf;
use std::time::SystemTime;

use crate::sessions::READY_STALE_THRESHOLD_SECS;
use crate::state::{resolve_state_with_details, StateStore};
use crate::storage::StorageConfig;
use crate::types::SessionState;
use chrono::Utc;

use super::types::{AdapterError, AgentSession, AgentState, AgentType};
use super::AgentAdapter;

/// Adapter for Claude Code CLI sessions.
///
/// All session data lives in `~/.capacitor/` (sidecar purity):
/// - State file: `~/.capacitor/sessions.json`
/// - Lock directories: `~/.capacitor/sessions/`
///
/// We never write to `~/.claude/`.
pub struct ClaudeAdapter {
    storage: StorageConfig,
}

impl ClaudeAdapter {
    pub fn new() -> Self {
        Self {
            storage: StorageConfig::default(),
        }
    }

    /// Creates an adapter with custom storage configuration.
    /// Used for testing with isolated directories.
    pub fn with_storage(storage: StorageConfig) -> Self {
        Self { storage }
    }

    fn map_state(state: SessionState) -> AgentState {
        match state {
            SessionState::Ready => AgentState::Ready,
            SessionState::Working => AgentState::Working,
            SessionState::Compacting => AgentState::Working,
            SessionState::Waiting => AgentState::Waiting,
            SessionState::Idle => AgentState::Idle,
        }
    }

    fn state_detail(state: SessionState) -> Option<String> {
        match state {
            SessionState::Compacting => Some("compacting context".to_string()),
            SessionState::Waiting => Some("waiting for permission".to_string()),
            _ => None,
        }
    }

    /// Returns path to the sessions state file.
    /// Located in Capacitor namespace: `~/.capacitor/sessions.json`
    fn state_file_path(&self) -> Option<PathBuf> {
        Some(self.storage.sessions_file())
    }

    /// Returns path to the lock directory.
    /// Located in Capacitor namespace: `~/.capacitor/sessions/`
    /// (We own these - sidecar purity)
    fn lock_dir_path(&self) -> Option<PathBuf> {
        Some(self.storage.sessions_dir())
    }
}

impl Default for ClaudeAdapter {
    fn default() -> Self {
        Self::new()
    }
}

impl AgentAdapter for ClaudeAdapter {
    fn id(&self) -> &'static str {
        "claude"
    }

    fn display_name(&self) -> &'static str {
        "Claude Code"
    }

    fn is_installed(&self) -> bool {
        // Check if Claude directory exists (where lock files are)
        self.storage.claude_root().is_dir()
    }

    fn initialize(&self) -> Result<(), AdapterError> {
        if let Some(state_file) = self.state_file_path() {
            if state_file.exists() {
                if let Err(e) = std::fs::read_to_string(&state_file) {
                    tracing::warn!(
                        path = %state_file.display(),
                        error = %e,
                        "Claude state file unreadable"
                    );
                }
            }
        }
        Ok(())
    }

    fn detect_session(&self, project_path: &str) -> Option<AgentSession> {
        let state_file = self.state_file_path()?;
        let lock_dir = self.lock_dir_path()?;

        let store = match StateStore::load(&state_file) {
            Ok(s) => s,
            Err(e) => {
                tracing::warn!(
                    project_path = %project_path,
                    error = %e,
                    "Failed to load state store"
                );
                return None;
            }
        };

        // v3 resolver handles both lock-based detection and fresh record fallback
        let details = resolve_state_with_details(&lock_dir, &store, project_path)?;

        // Use the resolved session_id to look up metadata, NOT find_by_cwd.
        // Using find_by_cwd could return a different session in multi-session scenarios.
        let record = details
            .session_id
            .as_deref()
            .and_then(|id| store.get_by_session_id(id));

        // Apply Ready→Idle threshold: stale Ready without lock should be treated as Idle
        // This mirrors the logic in sessions.rs detect_session_state_with_storage
        if details.state == SessionState::Ready && !details.is_from_lock {
            if let Some(rec) = record.as_ref() {
                let age = Utc::now()
                    .signed_duration_since(rec.state_changed_at)
                    .num_seconds();
                if age > READY_STALE_THRESHOLD_SECS {
                    // Idle sessions are not returned by detect_session
                    return None;
                }
            }
        }

        Some(AgentSession {
            agent_type: AgentType::Claude,
            agent_name: self.display_name().to_string(),
            state: Self::map_state(details.state),
            session_id: details.session_id,
            cwd: details.cwd,
            detail: Self::state_detail(details.state),
            working_on: record.and_then(|r| r.working_on.clone()),
            updated_at: record.map(|r| r.updated_at.to_rfc3339()),
        })
    }

    fn all_sessions(&self) -> Vec<AgentSession> {
        let state_file = match self.state_file_path() {
            Some(p) => p,
            None => return vec![],
        };

        let store = match StateStore::load(&state_file) {
            Ok(s) => s,
            Err(e) => {
                tracing::warn!(
                    error = %e,
                    "Failed to load state store for all_sessions"
                );
                return vec![];
            }
        };

        store
            .all_sessions()
            .map(|r| AgentSession {
                agent_type: AgentType::Claude,
                agent_name: self.display_name().to_string(),
                state: Self::map_state(r.state),
                session_id: Some(r.session_id.clone()),
                cwd: r.cwd.clone(),
                detail: Self::state_detail(r.state),
                working_on: r.working_on.clone(),
                updated_at: Some(r.updated_at.to_rfc3339()),
            })
            .collect()
    }

    fn state_mtime(&self) -> Option<SystemTime> {
        let state_file = self.state_file_path()?;
        std::fs::metadata(&state_file).ok()?.modified().ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::lock::tests_helper::create_lock;
    use crate::storage::StorageConfig;
    use chrono::{Duration as ChronoDuration, Utc};
    use tempfile::tempdir;

    // ─────────────────────────────────────────────────────────────────────────────
    // TDD: Path Configuration Tests (these should fail until we fix the adapter)
    // ─────────────────────────────────────────────────────────────────────────────

    #[test]
    fn test_state_file_uses_capacitor_namespace() {
        // State file should be in ~/.capacitor/sessions.json, NOT ~/.claude/
        let temp = tempdir().unwrap();
        let capacitor_root = temp.path().join("capacitor");
        let claude_root = temp.path().join("claude");
        std::fs::create_dir_all(&capacitor_root).unwrap();
        std::fs::create_dir_all(&claude_root).unwrap();

        let storage = StorageConfig::with_roots(capacitor_root.clone(), claude_root.clone());
        let adapter = ClaudeAdapter::with_storage(storage);

        // State file should be in Capacitor namespace
        let state_path = adapter.state_file_path().unwrap();
        assert!(
            state_path.starts_with(&capacitor_root),
            "State file should be in capacitor dir, got: {}",
            state_path.display()
        );
        assert_eq!(state_path, capacitor_root.join("sessions.json"));
    }

    #[test]
    fn test_lock_dir_uses_capacitor_namespace() {
        // Lock dir should be in ~/.capacitor/sessions/ (sidecar purity)
        let temp = tempdir().unwrap();
        let capacitor_root = temp.path().join("capacitor");
        let claude_root = temp.path().join("claude");
        std::fs::create_dir_all(&capacitor_root).unwrap();
        std::fs::create_dir_all(&claude_root).unwrap();

        let storage = StorageConfig::with_roots(capacitor_root.clone(), claude_root.clone());
        let adapter = ClaudeAdapter::with_storage(storage);

        // Lock dir should be in Capacitor namespace (we own these)
        let lock_path = adapter.lock_dir_path().unwrap();
        assert!(
            lock_path.starts_with(&capacitor_root),
            "Lock dir should be in capacitor dir, got: {}",
            lock_path.display()
        );
        assert_eq!(lock_path, capacitor_root.join("sessions"));
    }

    #[test]
    fn test_detect_session_with_capacitor_namespace() {
        // Both locks and state file in capacitor namespace (sidecar purity)
        let temp = tempdir().unwrap();
        let capacitor_root = temp.path().join("capacitor");
        let claude_root = temp.path().join("claude");
        let sessions_dir = capacitor_root.join("sessions");
        std::fs::create_dir_all(&sessions_dir).unwrap();
        std::fs::create_dir_all(&claude_root).unwrap();

        // Create lock in Capacitor namespace
        create_lock(&sessions_dir, std::process::id(), "/project");

        // Create state file in Capacitor namespace
        let state_file = capacitor_root.join("sessions.json");
        let mut store = StateStore::new(&state_file);
        store.update("test-session", SessionState::Working, "/project");
        store.save().unwrap();

        let storage = StorageConfig::with_roots(capacitor_root, claude_root);
        let adapter = ClaudeAdapter::with_storage(storage);
        let session = adapter.detect_session("/project").unwrap();

        assert_eq!(session.state, AgentState::Working);
        assert_eq!(session.cwd, "/project");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Existing Tests (updated to use new constructor where needed)
    // ─────────────────────────────────────────────────────────────────────────────

    #[test]
    fn test_state_mapping_ready() {
        assert_eq!(
            ClaudeAdapter::map_state(SessionState::Ready),
            AgentState::Ready
        );
    }

    #[test]
    fn test_state_mapping_working() {
        assert_eq!(
            ClaudeAdapter::map_state(SessionState::Working),
            AgentState::Working
        );
    }

    #[test]
    fn test_state_mapping_compacting_is_working_with_detail() {
        assert_eq!(
            ClaudeAdapter::map_state(SessionState::Compacting),
            AgentState::Working
        );
        assert_eq!(
            ClaudeAdapter::state_detail(SessionState::Compacting),
            Some("compacting context".to_string())
        );
    }

    #[test]
    fn test_state_mapping_waiting_with_detail() {
        assert_eq!(
            ClaudeAdapter::map_state(SessionState::Waiting),
            AgentState::Waiting
        );
        assert_eq!(
            ClaudeAdapter::state_detail(SessionState::Waiting),
            Some("waiting for permission".to_string())
        );
    }

    /// Helper to create an adapter with nonexistent directories
    fn adapter_with_nonexistent_dirs() -> ClaudeAdapter {
        let storage = StorageConfig::with_roots(
            PathBuf::from("/nonexistent/capacitor"),
            PathBuf::from("/nonexistent/claude"),
        );
        ClaudeAdapter::with_storage(storage)
    }

    #[test]
    fn test_is_installed_returns_false_when_dir_missing() {
        let adapter = adapter_with_nonexistent_dirs();
        assert!(!adapter.is_installed());
    }

    #[test]
    fn test_is_installed_returns_true_when_dir_exists() {
        let temp = tempdir().unwrap();
        let claude_root = temp.path().join("claude");
        std::fs::create_dir_all(&claude_root).unwrap();

        let storage = StorageConfig::with_roots(temp.path().to_path_buf(), claude_root);
        let adapter = ClaudeAdapter::with_storage(storage);
        assert!(adapter.is_installed());
    }

    #[test]
    fn test_detect_session_returns_none_when_not_installed() {
        let adapter = adapter_with_nonexistent_dirs();
        assert!(adapter.detect_session("/some/project").is_none());
    }

    #[test]
    fn test_detect_session_returns_none_when_no_state() {
        let temp = tempdir().unwrap();
        let capacitor_root = temp.path().join("capacitor");
        let claude_root = temp.path().join("claude");
        std::fs::create_dir_all(&capacitor_root).unwrap();
        std::fs::create_dir_all(&claude_root).unwrap();

        let storage = StorageConfig::with_roots(capacitor_root, claude_root);
        let adapter = ClaudeAdapter::with_storage(storage);
        assert!(adapter.detect_session("/some/project").is_none());
    }

    #[test]
    fn test_detect_session_with_active_session() {
        let temp = tempdir().unwrap();
        let capacitor_root = temp.path().join("capacitor");
        let claude_root = temp.path().join("claude");
        let sessions_dir = capacitor_root.join("sessions"); // Capacitor namespace
        std::fs::create_dir_all(&sessions_dir).unwrap();
        std::fs::create_dir_all(&claude_root).unwrap();

        // Lock in Capacitor namespace (sidecar purity)
        create_lock(&sessions_dir, std::process::id(), "/project");

        // State file in Capacitor namespace
        let mut store = StateStore::new(&capacitor_root.join("sessions.json"));
        store.update("test-session", SessionState::Working, "/project");
        store.save().unwrap();

        let storage = StorageConfig::with_roots(capacitor_root, claude_root);
        let adapter = ClaudeAdapter::with_storage(storage);
        let session = adapter.detect_session("/project").unwrap();

        assert_eq!(session.agent_type, AgentType::Claude);
        assert_eq!(session.state, AgentState::Working);
        assert_eq!(session.cwd, "/project");
    }

    #[test]
    fn test_detect_session_returns_recent_state_without_lock() {
        let temp = tempdir().unwrap();
        let capacitor_root = temp.path().join("capacitor");
        let claude_root = temp.path().join("claude");
        std::fs::create_dir_all(&capacitor_root).unwrap();
        std::fs::create_dir_all(&claude_root).unwrap();

        let mut store = StateStore::new(&capacitor_root.join("sessions.json"));
        store.update("session-1", SessionState::Ready, "/project");
        store.save().unwrap();

        let storage = StorageConfig::with_roots(capacitor_root, claude_root);
        let adapter = ClaudeAdapter::with_storage(storage);
        let session = adapter.detect_session("/project").unwrap();

        assert_eq!(session.state, AgentState::Ready);
        assert_eq!(session.cwd, "/project");
        assert_eq!(session.session_id.as_deref(), Some("session-1"));
    }

    #[test]
    fn test_detect_session_stale_ready_without_lock_returns_none() {
        // v4: Stale Ready records without a lock should return None (session has ended)
        // With session-based locks, if there's no lock, the session has been released.
        let temp = tempdir().unwrap();
        let capacitor_root = temp.path().join("capacitor");
        let claude_root = temp.path().join("claude");
        std::fs::create_dir_all(&capacitor_root).unwrap();
        std::fs::create_dir_all(&claude_root).unwrap();

        let mut store = StateStore::new(&capacitor_root.join("sessions.json"));
        store.update("session-1", SessionState::Ready, "/project");
        // 10 minutes: stale (> 5 min threshold)
        let ten_mins_ago = Utc::now() - ChronoDuration::minutes(10);
        store.set_timestamp_for_test("session-1", ten_mins_ago);
        store.set_state_changed_at_for_test("session-1", ten_mins_ago);
        store.save().unwrap();

        let storage = StorageConfig::with_roots(capacitor_root, claude_root);
        let adapter = ClaudeAdapter::with_storage(storage);
        let session = adapter.detect_session("/project");

        // v4: Without a lock, stale records indicate the session has ended
        assert!(session.is_none());
    }

    #[test]
    fn test_detect_session_very_stale_ready_returns_none() {
        // Ready records older than 15 min without a lock should return None
        let temp = tempdir().unwrap();
        let capacitor_root = temp.path().join("capacitor");
        let claude_root = temp.path().join("claude");
        std::fs::create_dir_all(&capacitor_root).unwrap();
        std::fs::create_dir_all(&claude_root).unwrap();

        let mut store = StateStore::new(&capacitor_root.join("sessions.json"));
        store.update("session-1", SessionState::Ready, "/project");
        // 20 minutes: beyond Ready→Idle threshold
        let twenty_mins_ago = Utc::now() - ChronoDuration::minutes(20);
        store.set_timestamp_for_test("session-1", twenty_mins_ago);
        store.set_state_changed_at_for_test("session-1", twenty_mins_ago);
        store.save().unwrap();

        let storage = StorageConfig::with_roots(capacitor_root, claude_root);
        let adapter = ClaudeAdapter::with_storage(storage);
        let session = adapter.detect_session("/project");

        // Should return None (Idle sessions are not returned by detect_session)
        assert!(session.is_none());
    }

    #[test]
    fn test_all_sessions_returns_empty_when_not_installed() {
        let adapter = adapter_with_nonexistent_dirs();
        assert!(adapter.all_sessions().is_empty());
    }

    #[test]
    fn test_all_sessions_returns_sessions() {
        let temp = tempdir().unwrap();
        let capacitor_root = temp.path().join("capacitor");
        let claude_root = temp.path().join("claude");
        std::fs::create_dir_all(&capacitor_root).unwrap();
        std::fs::create_dir_all(&claude_root).unwrap();

        // State file in Capacitor namespace
        let mut store = StateStore::new(&capacitor_root.join("sessions.json"));
        store.update("session-1", SessionState::Working, "/project1");
        store.update("session-2", SessionState::Ready, "/project2");
        store.save().unwrap();

        let storage = StorageConfig::with_roots(capacitor_root, claude_root);
        let adapter = ClaudeAdapter::with_storage(storage);
        let sessions = adapter.all_sessions();

        assert_eq!(sessions.len(), 2);
    }

    #[test]
    fn test_id_and_display_name() {
        let adapter = ClaudeAdapter::new();
        assert_eq!(adapter.id(), "claude");
        assert_eq!(adapter.display_name(), "Claude Code");
    }

    #[test]
    fn test_state_mtime_returns_none_when_no_file() {
        let temp = tempdir().unwrap();
        let capacitor_root = temp.path().join("capacitor");
        let claude_root = temp.path().join("claude");
        std::fs::create_dir_all(&capacitor_root).unwrap();
        std::fs::create_dir_all(&claude_root).unwrap();

        let storage = StorageConfig::with_roots(capacitor_root, claude_root);
        let adapter = ClaudeAdapter::with_storage(storage);
        assert!(adapter.state_mtime().is_none());
    }

    #[test]
    fn test_state_mtime_returns_some_when_file_exists() {
        let temp = tempdir().unwrap();
        let capacitor_root = temp.path().join("capacitor");
        let claude_root = temp.path().join("claude");
        std::fs::create_dir_all(&capacitor_root).unwrap();
        std::fs::create_dir_all(&claude_root).unwrap();

        // Create state file in Capacitor namespace
        let state_file = capacitor_root.join("sessions.json");
        std::fs::write(&state_file, r#"{"version": 2, "sessions": {}}"#).unwrap();

        let storage = StorageConfig::with_roots(capacitor_root, claude_root);
        let adapter = ClaudeAdapter::with_storage(storage);
        assert!(adapter.state_mtime().is_some());
    }
}
