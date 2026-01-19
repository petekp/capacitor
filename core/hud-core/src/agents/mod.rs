mod claude;
mod registry;
mod stubs;
mod types;

pub use claude::ClaudeAdapter;
pub use registry::AgentRegistry;
pub use stubs::{AiderAdapter, AmpAdapter, CodexAdapter, DroidAdapter, OpenCodeAdapter};
pub use types::{AdapterError, AgentConfig, AgentSession, AgentState, AgentType};

/// Trait for CLI agent integrations
///
/// Implementors should:
/// - Return errors via `tracing::warn!` for diagnostic visibility
/// - Cache expensive operations internally when possible
/// - Gracefully degrade (return None/empty) on transient errors
pub trait AgentAdapter: Send + Sync {
    /// Unique identifier (e.g., "claude", "codex")
    fn id(&self) -> &'static str;

    /// Human-readable name (e.g., "Claude Code", "OpenAI Codex")
    fn display_name(&self) -> &'static str;

    /// Check if this agent's CLI is available on the system
    /// Should NOT panic - return false on any error
    fn is_installed(&self) -> bool;

    /// Detect session state for a specific project path
    /// Returns None if no session found (not an error)
    fn detect_session(&self, project_path: &str) -> Option<AgentSession>;

    /// Called once at registry startup for any needed initialization
    fn initialize(&self) -> Result<(), AdapterError> {
        Ok(())
    }

    /// Return all known sessions across all projects
    fn all_sessions(&self) -> Vec<AgentSession> {
        vec![]
    }

    /// Return the mtime of the state source for cache invalidation
    fn state_mtime(&self) -> Option<std::time::SystemTime> {
        None
    }
}

#[cfg(test)]
pub mod test_utils {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};

    /// Test adapter for unit testing the registry
    pub struct TestAdapter {
        pub id: &'static str,
        pub name: &'static str,
        pub installed: AtomicBool,
        pub sessions: std::sync::Mutex<Vec<AgentSession>>,
    }

    impl TestAdapter {
        pub fn new(id: &'static str, name: &'static str, installed: bool) -> Self {
            Self {
                id,
                name,
                installed: AtomicBool::new(installed),
                sessions: std::sync::Mutex::new(vec![]),
            }
        }

        pub fn set_installed(&self, installed: bool) {
            self.installed.store(installed, Ordering::SeqCst);
        }

        pub fn add_session(&self, session: AgentSession) {
            self.sessions.lock().unwrap().push(session);
        }

        pub fn clear_sessions(&self) {
            self.sessions.lock().unwrap().clear();
        }
    }

    impl AgentAdapter for TestAdapter {
        fn id(&self) -> &'static str {
            self.id
        }

        fn display_name(&self) -> &'static str {
            self.name
        }

        fn is_installed(&self) -> bool {
            self.installed.load(Ordering::SeqCst)
        }

        fn detect_session(&self, project_path: &str) -> Option<AgentSession> {
            self.sessions
                .lock()
                .unwrap()
                .iter()
                .find(|s| s.cwd == project_path)
                .cloned()
        }

        fn all_sessions(&self) -> Vec<AgentSession> {
            self.sessions.lock().unwrap().clone()
        }
    }
}
