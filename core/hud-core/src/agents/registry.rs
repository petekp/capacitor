//! Coordinates agent adapters, user preferences, and session caching.

use std::collections::HashMap;
use std::sync::{Arc, RwLock};
use std::time::SystemTime;

use super::claude::ClaudeAdapter;
use super::stubs::{AiderAdapter, AmpAdapter, CodexAdapter, DroidAdapter, OpenCodeAdapter};
use super::types::{AgentConfig, AgentSession};
use super::AgentAdapter;

struct SessionCache {
    sessions: HashMap<String, Vec<AgentSession>>,
    mtimes: HashMap<String, SystemTime>,
}

pub struct AgentRegistry {
    adapters: Vec<Arc<dyn AgentAdapter>>,
    config: AgentConfig,
    session_cache: RwLock<SessionCache>,
}

impl AgentRegistry {
    pub fn new(config: AgentConfig) -> Self {
        Self {
            adapters: Self::create_adapters(),
            config,
            session_cache: RwLock::new(SessionCache {
                sessions: HashMap::new(),
                mtimes: HashMap::new(),
            }),
        }
    }

    #[cfg(test)]
    pub fn with_adapters(adapters: Vec<Arc<dyn AgentAdapter>>, config: AgentConfig) -> Self {
        Self {
            adapters,
            config,
            session_cache: RwLock::new(SessionCache {
                sessions: HashMap::new(),
                mtimes: HashMap::new(),
            }),
        }
    }

    /// Initialize all adapters, logging any failures
    pub fn initialize_all(&self) {
        for adapter in &self.adapters {
            if let Err(e) = adapter.initialize() {
                tracing::warn!(
                    adapter_id = %adapter.id(),
                    error = %e,
                    "Adapter initialization failed"
                );
            }
        }
    }

    /// Get all installed agents, respecting user preferences
    pub fn installed_agents(&self) -> Vec<&dyn AgentAdapter> {
        let mut agents: Vec<_> = self
            .adapters
            .iter()
            .filter(|a| !self.config.disabled.contains(&a.id().to_string()))
            .filter(|a| a.is_installed())
            .map(|a| a.as_ref())
            .collect();

        agents.sort_by(|a, b| {
            let pos_a = self.config.agent_order.iter().position(|x| x == a.id());
            let pos_b = self.config.agent_order.iter().position(|x| x == b.id());
            match (pos_a, pos_b) {
                (Some(i), Some(j)) => i.cmp(&j),
                (Some(_), None) => std::cmp::Ordering::Less,
                (None, Some(_)) => std::cmp::Ordering::Greater,
                (None, None) => a.id().cmp(b.id()),
            }
        });

        agents
    }

    /// Detect sessions from ALL agents for a project path
    pub fn detect_all_sessions(&self, project_path: &str) -> Vec<AgentSession> {
        self.installed_agents()
            .iter()
            .filter_map(|adapter| adapter.detect_session(project_path))
            .collect()
    }

    /// Detect primary session for a project (first in preference order)
    /// Short-circuits on first match for better performance
    pub fn detect_primary_session(&self, project_path: &str) -> Option<AgentSession> {
        self.installed_agents()
            .into_iter()
            .find_map(|adapter| adapter.detect_session(project_path))
    }

    /// Get all sessions with mtime-based caching
    ///
    /// Avoids holding locks during I/O to prevent contention:
    /// 1. Read lock to check cache validity
    /// 2. Release lock, perform I/O for stale adapters
    /// 3. Write lock briefly to update cache
    pub fn all_sessions_cached(&self) -> Vec<AgentSession> {
        let installed = self.installed_agents();

        // Phase 1: Check cache validity under read lock
        let (cached_results, adapters_needing_refresh): (Vec<_>, Vec<_>) = {
            // Recover from poisoning - cache corruption is non-fatal, just refetch
            let cache = self
                .session_cache
                .read()
                .unwrap_or_else(|poisoned| poisoned.into_inner());

            installed
                .into_iter()
                .map(|adapter| {
                    let id = adapter.id();
                    let current_mtime = adapter.state_mtime();
                    let cached_mtime = cache.mtimes.get(id).copied();

                    let cache_valid = match (current_mtime, cached_mtime) {
                        (Some(curr), Some(cached)) => curr == cached,
                        _ => false,
                    };

                    if cache_valid {
                        if let Some(sessions) = cache.sessions.get(id) {
                            return (Some(sessions.clone()), None);
                        }
                    }

                    (None, Some((adapter, current_mtime)))
                })
                .fold((vec![], vec![]), |(mut cached, mut stale), (c, s)| {
                    if let Some(sessions) = c {
                        cached.push(sessions);
                    }
                    if let Some(adapter_info) = s {
                        stale.push(adapter_info);
                    }
                    (cached, stale)
                })
        };
        // Read lock released here

        // Phase 2: Fetch sessions for stale adapters (I/O without lock)
        let fresh_results: Vec<_> = adapters_needing_refresh
            .into_iter()
            .map(|(adapter, mtime)| {
                let sessions = adapter.all_sessions();
                (adapter.id().to_string(), sessions, mtime)
            })
            .collect();

        // Phase 3: Update cache under write lock (brief)
        if !fresh_results.is_empty() {
            // Recover from poisoning - cache corruption is non-fatal
            let mut cache = self
                .session_cache
                .write()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            for (id, sessions, mtime) in &fresh_results {
                if let Some(m) = mtime {
                    cache.mtimes.insert(id.clone(), *m);
                }
                cache.sessions.insert(id.clone(), sessions.clone());
            }
        }

        // Combine results
        let mut all_sessions: Vec<AgentSession> = cached_results.into_iter().flatten().collect();
        for (_, sessions, _) in fresh_results {
            all_sessions.extend(sessions);
        }

        all_sessions
    }

    /// Invalidate the session cache for a specific adapter
    pub fn invalidate_cache(&self, adapter_id: &str) {
        // Recover from poisoning - invalidation clears corrupt data anyway
        let mut cache = self
            .session_cache
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        cache.sessions.remove(adapter_id);
        cache.mtimes.remove(adapter_id);
    }

    /// Invalidate all caches
    pub fn invalidate_all_caches(&self) {
        // Recover from poisoning - invalidation clears corrupt data anyway
        let mut cache = self
            .session_cache
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        cache.sessions.clear();
        cache.mtimes.clear();
    }

    fn create_adapters() -> Vec<Arc<dyn AgentAdapter>> {
        vec![
            Arc::new(ClaudeAdapter::new()),
            Arc::new(CodexAdapter::new()),
            Arc::new(AiderAdapter::new()),
            Arc::new(AmpAdapter::new()),
            Arc::new(OpenCodeAdapter::new()),
            Arc::new(DroidAdapter::new()),
        ]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agents::test_utils::TestAdapter;
    use crate::agents::{AgentState, AgentType};

    fn create_test_session(agent_type: AgentType, cwd: &str, state: AgentState) -> AgentSession {
        AgentSession {
            agent_type,
            agent_name: agent_type.display_name().to_string(),
            state,
            session_id: Some("test-session".to_string()),
            cwd: cwd.to_string(),
            detail: None,
            working_on: None,
            updated_at: None,
        }
    }

    #[test]
    fn test_registry_filters_disabled_agents() {
        let adapter1 = Arc::new(TestAdapter::new("test1", "Test 1", true));
        let adapter2 = Arc::new(TestAdapter::new("test2", "Test 2", true));

        let config = AgentConfig {
            disabled: vec!["test1".to_string()],
            agent_order: vec![],
        };

        let registry = AgentRegistry::with_adapters(vec![adapter1, adapter2], config);

        let installed = registry.installed_agents();
        assert_eq!(installed.len(), 1);
        assert_eq!(installed[0].id(), "test2");
    }

    #[test]
    fn test_registry_filters_uninstalled_agents() {
        let adapter1 = Arc::new(TestAdapter::new("test1", "Test 1", true));
        let adapter2 = Arc::new(TestAdapter::new("test2", "Test 2", false));

        let config = AgentConfig::default();
        let registry = AgentRegistry::with_adapters(vec![adapter1, adapter2], config);

        let installed = registry.installed_agents();
        assert_eq!(installed.len(), 1);
        assert_eq!(installed[0].id(), "test1");
    }

    #[test]
    fn test_registry_respects_agent_order() {
        let adapter1 = Arc::new(TestAdapter::new("aaa", "AAA", true));
        let adapter2 = Arc::new(TestAdapter::new("zzz", "ZZZ", true));

        let config = AgentConfig {
            disabled: vec![],
            agent_order: vec!["zzz".to_string(), "aaa".to_string()],
        };

        let registry = AgentRegistry::with_adapters(vec![adapter1, adapter2], config);

        let installed = registry.installed_agents();
        assert_eq!(installed.len(), 2);
        assert_eq!(installed[0].id(), "zzz");
        assert_eq!(installed[1].id(), "aaa");
    }

    #[test]
    fn test_registry_alphabetical_fallback_for_unordered() {
        let adapter1 = Arc::new(TestAdapter::new("zebra", "Zebra", true));
        let adapter2 = Arc::new(TestAdapter::new("apple", "Apple", true));

        let config = AgentConfig::default();
        let registry = AgentRegistry::with_adapters(vec![adapter1, adapter2], config);

        let installed = registry.installed_agents();
        assert_eq!(installed.len(), 2);
        assert_eq!(installed[0].id(), "apple");
        assert_eq!(installed[1].id(), "zebra");
    }

    #[test]
    fn test_detect_all_sessions() {
        let adapter1 = Arc::new(TestAdapter::new("test1", "Test 1", true));
        let adapter2 = Arc::new(TestAdapter::new("test2", "Test 2", true));

        adapter1.add_session(create_test_session(
            AgentType::Claude,
            "/project",
            AgentState::Working,
        ));
        adapter2.add_session(create_test_session(
            AgentType::Codex,
            "/project",
            AgentState::Ready,
        ));

        let config = AgentConfig::default();
        let registry = AgentRegistry::with_adapters(vec![adapter1, adapter2], config);

        let sessions = registry.detect_all_sessions("/project");
        assert_eq!(sessions.len(), 2);
    }

    #[test]
    fn test_detect_primary_session_returns_first() {
        let adapter1 = Arc::new(TestAdapter::new("test1", "Test 1", true));
        let adapter2 = Arc::new(TestAdapter::new("test2", "Test 2", true));

        adapter1.add_session(create_test_session(
            AgentType::Claude,
            "/project",
            AgentState::Working,
        ));
        adapter2.add_session(create_test_session(
            AgentType::Codex,
            "/project",
            AgentState::Ready,
        ));

        let config = AgentConfig {
            disabled: vec![],
            agent_order: vec!["test2".to_string(), "test1".to_string()],
        };

        let registry = AgentRegistry::with_adapters(vec![adapter1, adapter2], config);

        let primary = registry.detect_primary_session("/project").unwrap();
        assert_eq!(primary.agent_type, AgentType::Codex);
    }

    #[test]
    fn test_detect_primary_session_returns_none_when_empty() {
        let adapter = Arc::new(TestAdapter::new("test1", "Test 1", true));
        let config = AgentConfig::default();
        let registry = AgentRegistry::with_adapters(vec![adapter], config);

        assert!(registry.detect_primary_session("/project").is_none());
    }

    #[test]
    fn test_invalidate_cache() {
        let adapter = Arc::new(TestAdapter::new("test1", "Test 1", true));
        adapter.add_session(create_test_session(
            AgentType::Claude,
            "/project",
            AgentState::Working,
        ));

        let config = AgentConfig::default();
        let registry = AgentRegistry::with_adapters(vec![adapter.clone()], config);

        let sessions1 = registry.all_sessions_cached();
        assert_eq!(sessions1.len(), 1);

        adapter.clear_sessions();
        registry.invalidate_cache("test1");

        let sessions2 = registry.all_sessions_cached();
        assert_eq!(sessions2.len(), 0);
    }
}
