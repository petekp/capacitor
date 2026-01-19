use std::path::PathBuf;
use std::time::SystemTime;

use crate::config::get_claude_dir;
use crate::state::types::ClaudeState;
use crate::state::{resolve_state_with_details, StateStore};

use super::types::{AdapterError, AgentSession, AgentState, AgentType};
use super::AgentAdapter;

pub struct ClaudeAdapter {
    claude_dir: Option<PathBuf>,
}

impl ClaudeAdapter {
    pub fn new() -> Self {
        Self {
            claude_dir: get_claude_dir(),
        }
    }

    pub fn with_claude_dir(dir: PathBuf) -> Self {
        Self {
            claude_dir: Some(dir),
        }
    }

    fn map_state(claude_state: ClaudeState) -> AgentState {
        match claude_state {
            ClaudeState::Ready => AgentState::Ready,
            ClaudeState::Working => AgentState::Working,
            ClaudeState::Compacting => AgentState::Working,
            ClaudeState::Blocked => AgentState::Waiting,
        }
    }

    fn state_detail(claude_state: ClaudeState) -> Option<String> {
        match claude_state {
            ClaudeState::Compacting => Some("compacting context".to_string()),
            ClaudeState::Blocked => Some("waiting for permission".to_string()),
            _ => None,
        }
    }

    fn state_file_path(&self) -> Option<PathBuf> {
        self.claude_dir
            .as_ref()
            .map(|d| d.join("hud-session-states-v2.json"))
    }

    fn lock_dir_path(&self) -> Option<PathBuf> {
        self.claude_dir.as_ref().map(|d| d.join("sessions"))
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
        self.claude_dir
            .as_ref()
            .and_then(|d| std::fs::metadata(d).ok())
            .map(|m| m.is_dir())
            .unwrap_or(false)
    }

    fn initialize(&self) -> Result<(), AdapterError> {
        if let Some(state_file) = self.state_file_path() {
            if state_file.exists() {
                if let Err(e) = std::fs::read_to_string(&state_file) {
                    eprintln!(
                        "Warning: Claude state file unreadable at {}: {}",
                        state_file.display(),
                        e
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
                eprintln!(
                    "Warning: Failed to load state store for {}: {}",
                    project_path, e
                );
                return None;
            }
        };

        let resolved = resolve_state_with_details(&lock_dir, &store, project_path)?;

        // IMPORTANT: Use the resolved session_id to look up metadata, NOT find_by_cwd.
        // Using find_by_cwd could return a different session in multi-session scenarios,
        // causing state from Session A to be mixed with metadata from Session B.
        let record = resolved
            .session_id
            .as_deref()
            .and_then(|id| store.get_by_session_id(id));

        Some(AgentSession {
            agent_type: AgentType::Claude,
            agent_name: self.display_name().to_string(),
            state: Self::map_state(resolved.state),
            session_id: resolved.session_id,
            cwd: resolved.cwd,
            detail: Self::state_detail(resolved.state),
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
                eprintln!(
                    "Warning: Failed to load state store for all_sessions: {}",
                    e
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
    use tempfile::tempdir;

    #[test]
    fn test_state_mapping_ready() {
        assert_eq!(
            ClaudeAdapter::map_state(ClaudeState::Ready),
            AgentState::Ready
        );
    }

    #[test]
    fn test_state_mapping_working() {
        assert_eq!(
            ClaudeAdapter::map_state(ClaudeState::Working),
            AgentState::Working
        );
    }

    #[test]
    fn test_state_mapping_compacting_is_working_with_detail() {
        assert_eq!(
            ClaudeAdapter::map_state(ClaudeState::Compacting),
            AgentState::Working
        );
        assert_eq!(
            ClaudeAdapter::state_detail(ClaudeState::Compacting),
            Some("compacting context".to_string())
        );
    }

    #[test]
    fn test_state_mapping_blocked_is_waiting_with_detail() {
        assert_eq!(
            ClaudeAdapter::map_state(ClaudeState::Blocked),
            AgentState::Waiting
        );
        assert_eq!(
            ClaudeAdapter::state_detail(ClaudeState::Blocked),
            Some("waiting for permission".to_string())
        );
    }

    #[test]
    fn test_is_installed_returns_false_when_dir_missing() {
        let adapter = ClaudeAdapter { claude_dir: None };
        assert!(!adapter.is_installed());
    }

    #[test]
    fn test_is_installed_returns_true_when_dir_exists() {
        let temp = tempdir().unwrap();
        let adapter = ClaudeAdapter::with_claude_dir(temp.path().to_path_buf());
        assert!(adapter.is_installed());
    }

    #[test]
    fn test_detect_session_returns_none_when_not_installed() {
        let adapter = ClaudeAdapter { claude_dir: None };
        assert!(adapter.detect_session("/some/project").is_none());
    }

    #[test]
    fn test_detect_session_returns_none_when_no_state() {
        let temp = tempdir().unwrap();
        let adapter = ClaudeAdapter::with_claude_dir(temp.path().to_path_buf());
        assert!(adapter.detect_session("/some/project").is_none());
    }

    #[test]
    fn test_detect_session_with_active_session() {
        let temp = tempdir().unwrap();
        let sessions_dir = temp.path().join("sessions");
        std::fs::create_dir_all(&sessions_dir).unwrap();

        create_lock(&sessions_dir, std::process::id(), "/project");

        let mut store = StateStore::new(&temp.path().join("hud-session-states-v2.json"));
        store.update("test-session", ClaudeState::Working, "/project");
        store.save().unwrap();

        let adapter = ClaudeAdapter::with_claude_dir(temp.path().to_path_buf());
        let session = adapter.detect_session("/project").unwrap();

        assert_eq!(session.agent_type, AgentType::Claude);
        assert_eq!(session.state, AgentState::Working);
        assert_eq!(session.cwd, "/project");
    }

    #[test]
    fn test_all_sessions_returns_empty_when_not_installed() {
        let adapter = ClaudeAdapter { claude_dir: None };
        assert!(adapter.all_sessions().is_empty());
    }

    #[test]
    fn test_all_sessions_returns_sessions() {
        let temp = tempdir().unwrap();

        let mut store = StateStore::new(&temp.path().join("hud-session-states-v2.json"));
        store.update("session-1", ClaudeState::Working, "/project1");
        store.update("session-2", ClaudeState::Ready, "/project2");
        store.save().unwrap();

        let adapter = ClaudeAdapter::with_claude_dir(temp.path().to_path_buf());
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
        let adapter = ClaudeAdapter::with_claude_dir(temp.path().to_path_buf());
        assert!(adapter.state_mtime().is_none());
    }

    #[test]
    fn test_state_mtime_returns_some_when_file_exists() {
        let temp = tempdir().unwrap();
        let state_file = temp.path().join("hud-session-states-v2.json");
        std::fs::write(&state_file, r#"{"version": 2, "sessions": {}}"#).unwrap();

        let adapter = ClaudeAdapter::with_claude_dir(temp.path().to_path_buf());
        assert!(adapter.state_mtime().is_some());
    }
}
