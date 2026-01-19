use hud_core::agents::{AgentConfig, AgentRegistry};

#[test]
fn test_registry_creates_all_adapters() {
    let config = AgentConfig::default();
    let registry = AgentRegistry::new(config);

    registry.initialize_all();
}

#[test]
fn test_registry_with_disabled_agents() {
    let config = AgentConfig {
        disabled: vec!["codex".to_string(), "amp".to_string()],
        agent_order: vec![],
    };
    let registry = AgentRegistry::new(config);

    let installed = registry.installed_agents();
    assert!(installed.iter().all(|a| a.id() != "codex"));
    assert!(installed.iter().all(|a| a.id() != "amp"));
}

#[test]
fn test_registry_with_agent_order() {
    let config = AgentConfig {
        disabled: vec![],
        agent_order: vec!["aider".to_string(), "claude".to_string()],
    };
    let registry = AgentRegistry::new(config);

    let installed = registry.installed_agents();
    if installed.len() >= 2 {
        let ids: Vec<_> = installed.iter().map(|a| a.id()).collect();
        if ids.contains(&"aider") && ids.contains(&"claude") {
            let aider_pos = ids.iter().position(|&x| x == "aider");
            let claude_pos = ids.iter().position(|&x| x == "claude");
            if let (Some(a), Some(c)) = (aider_pos, claude_pos) {
                assert!(
                    a < c,
                    "Aider should come before Claude based on agent_order"
                );
            }
        }
    }
}

#[test]
fn test_detect_sessions_returns_empty_for_unknown_path() {
    let config = AgentConfig::default();
    let registry = AgentRegistry::new(config);

    let sessions = registry.detect_all_sessions("/definitely/not/a/real/project/path");
    assert!(sessions.is_empty());
}

#[test]
fn test_detect_primary_session_returns_none_for_unknown_path() {
    let config = AgentConfig::default();
    let registry = AgentRegistry::new(config);

    let session = registry.detect_primary_session("/definitely/not/a/real/project/path");
    assert!(session.is_none());
}

#[test]
fn test_cache_invalidation() {
    let config = AgentConfig::default();
    let registry = AgentRegistry::new(config);

    let sessions1 = registry.all_sessions_cached();
    registry.invalidate_all_caches();
    let sessions2 = registry.all_sessions_cached();

    assert_eq!(sessions1.len(), sessions2.len());
}

#[test]
fn test_invalidate_specific_cache() {
    let config = AgentConfig::default();
    let registry = AgentRegistry::new(config);

    let _ = registry.all_sessions_cached();
    registry.invalidate_cache("claude");
}
