# Multi-Agent CLI Support Design

**Date:** 2026-01-18
**Status:** Ready for Implementation
**Author:** Claude (via brainstorming session)

---

## 1. Overview

### Goal

Enable Claude HUD to detect and display session states from multiple AI coding CLI agents (Claude Code, Codex, Amp, Opencode, Droid, etc.) using a contributor-friendly adapter pattern.

### Design Principles

- **Sidecar philosophy**: Observe, don't control
- **TDD-first**: Tests define contracts before implementation
- **Contributor-friendly**: Adding a new agent should be straightforward
- **Resilient to change**: Live tests catch upstream CLI changes early

---

## 2. Architecture

### Pattern: Starship-Style Adapters

```
┌─────────────────────────────────────────────────────────────┐
│                      HudEngine (Facade)                     │
│                   Uses AgentRegistry                        │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────┴──────────────────────────────────┐
│                     AgentRegistry                           │
│         Manages adapters, caching, user preferences         │
└──────────────────────────┬──────────────────────────────────┘
                           │
       ┌───────────────────┼───────────────────┐
       ▼                   ▼                   ▼
┌──────────────┐   ┌──────────────┐   ┌──────────────┐
│ClaudeAdapter │   │ CodexAdapter │   │  AmpAdapter  │
│  (wraps      │   │   (stub)     │   │   (stub)     │
│  resolver)   │   │              │   │              │
└──────────────┘   └──────────────┘   └──────────────┘
```

### File Structure

```
core/hud-core/src/
├── agents/
│   ├── mod.rs           # AgentAdapter trait, re-exports
│   ├── types.rs         # AgentState, AgentType, AgentSession, AgentConfig
│   ├── registry.rs      # AgentRegistry with caching
│   ├── claude.rs        # Claude Code adapter (wraps existing resolver)
│   ├── codex.rs         # OpenAI Codex stub
│   ├── amp.rs           # Amp stub
│   ├── aider.rs         # Aider stub
│   ├── opencode.rs      # Opencode stub
│   ├── droid.rs         # Droid stub
│   └── test_utils.rs    # TestAdapter for testing
├── state/               # Existing - reused by ClaudeAdapter
└── engine.rs            # Updated to use AgentRegistry
```

---

## 3. Core Types

```rust
// core/hud-core/src/agents/types.rs

use serde::{Deserialize, Serialize};

/// Universal agent states - maps to any CLI agent's activity
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum, Serialize, Deserialize)]
pub enum AgentState {
    Idle,      // No session active
    Ready,     // Session active, waiting for input
    Working,   // Processing (thinking, tool use, etc.)
    Waiting,   // Blocked on user (permission, input needed)
}

/// Known agent types - flat enum for UniFFI compatibility
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum, Serialize, Deserialize)]
pub enum AgentType {
    Claude,
    Codex,
    Aider,
    Amp,
    OpenCode,
    Droid,
    Other,
}

impl AgentType {
    pub fn id(&self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
            Self::Aider => "aider",
            Self::Amp => "amp",
            Self::OpenCode => "opencode",
            Self::Droid => "droid",
            Self::Other => "other",
        }
    }
}

/// A detected agent session
///
/// NOTE: The composite key is (agent_type, session_id). Session IDs are only
/// unique within an agent type, not globally.
#[derive(Debug, Clone, uniffi::Record, Serialize, Deserialize)]
pub struct AgentSession {
    pub agent_type: AgentType,
    pub agent_name: String,  // Display name, e.g., "Claude Code"
    pub state: AgentState,
    #[serde(default)]
    pub session_id: Option<String>,
    pub cwd: String,
    #[serde(default)]
    pub detail: Option<String>,      // Agent-specific state info
    #[serde(default)]
    pub working_on: Option<String>,  // Current task description
    #[serde(default)]
    pub updated_at: Option<String>,  // ISO timestamp
}

/// Agent configuration with user preferences
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct AgentConfig {
    /// Disabled agents (won't be queried)
    #[serde(default)]
    pub disabled: Vec<String>,

    /// Agent display order (first = primary). Agents not listed appear after.
    #[serde(default)]
    pub agent_order: Vec<String>,
}

/// Errors that can occur in adapter operations
#[derive(Debug, Clone)]
pub enum AdapterError {
    CorruptedState { path: String, reason: String },
    PermissionDenied { path: String },
    IoError { message: String },
    InitFailed { reason: String },
}
```

---

## 4. AgentAdapter Trait

```rust
// core/hud-core/src/agents/mod.rs

use crate::agents::types::*;

/// Trait for CLI agent integrations
///
/// Implementors should:
/// - Return errors via `tracing::warn!` for diagnostic visibility
/// - Cache expensive operations internally when possible
/// - Gracefully degrade (return None/empty) on transient errors
pub trait AgentAdapter: Send + Sync {
    // === Required Methods (4) ===

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

    // === Optional Methods (3) ===

    /// Called once at registry startup for any needed initialization
    fn initialize(&self) -> Result<(), AdapterError> { Ok(()) }

    /// Return all known sessions across all projects
    fn all_sessions(&self) -> Vec<AgentSession> { vec![] }

    /// Return the mtime of the state source for cache invalidation
    fn state_mtime(&self) -> Option<std::time::SystemTime> { None }
}
```

---

## 5. AgentRegistry

```rust
// core/hud-core/src/agents/registry.rs

use crate::agents::{AgentAdapter, AgentSession, AgentConfig};
use std::collections::HashMap;
use std::sync::{Arc, RwLock};
use std::time::SystemTime;

pub struct AgentRegistry {
    adapters: Vec<Arc<dyn AgentAdapter>>,
    config: AgentConfig,
    session_cache: RwLock<SessionCache>,
}

struct SessionCache {
    sessions: HashMap<String, Vec<AgentSession>>,
    mtimes: HashMap<String, SystemTime>,
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

    /// Initialize all adapters, logging any failures
    pub fn initialize_all(&self) {
        for adapter in &self.adapters {
            if let Err(e) = adapter.initialize() {
                tracing::warn!(
                    adapter = adapter.id(),
                    error = ?e,
                    "Adapter initialization failed"
                );
            }
        }
    }

    /// Get all installed agents, respecting user preferences
    pub fn installed_agents(&self) -> Vec<&dyn AgentAdapter> {
        let mut agents: Vec<_> = self.adapters
            .iter()
            .filter(|a| !self.config.disabled.contains(&a.id().to_string()))
            .filter(|a| a.is_installed())
            .map(|a| a.as_ref())
            .collect();

        // Sort by user preference, then alphabetically
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
    pub fn detect_primary_session(&self, project_path: &str) -> Option<AgentSession> {
        self.detect_all_sessions(project_path).into_iter().next()
    }

    /// Get all sessions with mtime-based caching
    pub fn all_sessions_cached(&self) -> Vec<AgentSession> {
        let mut cache = self.session_cache.write().unwrap();
        let mut all_sessions = Vec::new();

        for adapter in self.installed_agents() {
            let id = adapter.id().to_string();
            let current_mtime = adapter.state_mtime();
            let cached_mtime = cache.mtimes.get(&id).copied();

            let use_cache = match (current_mtime, cached_mtime) {
                (Some(curr), Some(cached)) => curr == cached,
                _ => false,
            };

            if use_cache {
                if let Some(sessions) = cache.sessions.get(&id) {
                    all_sessions.extend(sessions.clone());
                    continue;
                }
            }

            let sessions = adapter.all_sessions();
            if let Some(mtime) = current_mtime {
                cache.mtimes.insert(id.clone(), mtime);
            }
            cache.sessions.insert(id, sessions.clone());
            all_sessions.extend(sessions);
        }

        all_sessions
    }

    fn create_adapters() -> Vec<Arc<dyn AgentAdapter>> {
        vec![
            Arc::new(super::claude::ClaudeAdapter::new()),
            Arc::new(super::codex::CodexAdapter::new()),
            Arc::new(super::amp::AmpAdapter::new()),
            // ... other adapters
        ]
    }
}
```

---

## 6. Claude Adapter (Reference Implementation)

```rust
// core/hud-core/src/agents/claude.rs

use crate::agents::{AgentAdapter, AgentSession, AgentState, AgentType, AdapterError};
use crate::state::{StateStore, LockStore, resolve_state_with_details, ClaudeState};
use crate::config::get_claude_dir;
use std::path::PathBuf;
use std::time::SystemTime;

pub struct ClaudeAdapter {
    claude_dir: Option<PathBuf>,
}

impl ClaudeAdapter {
    pub fn new() -> Self {
        Self { claude_dir: get_claude_dir().ok() }
    }

    #[cfg(test)]
    pub fn with_claude_dir(dir: PathBuf) -> Self {
        Self { claude_dir: Some(dir) }
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
}

impl AgentAdapter for ClaudeAdapter {
    fn id(&self) -> &'static str { "claude" }
    fn display_name(&self) -> &'static str { "Claude Code" }

    fn is_installed(&self) -> bool {
        self.claude_dir
            .as_ref()
            .and_then(|d| std::fs::metadata(d).ok())
            .map(|m| m.is_dir())
            .unwrap_or(false)
    }

    fn initialize(&self) -> Result<(), AdapterError> {
        if let Some(ref dir) = self.claude_dir {
            let state_file = dir.join("hud-session-states-v2.json");
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
        let claude_dir = self.claude_dir.as_ref()?;

        let state_store = match StateStore::new(claude_dir) {
            Ok(s) => s,
            Err(e) => {
                tracing::warn!(project = project_path, error = %e, "Failed to load state store");
                return None;
            }
        };

        let lock_store = match LockStore::new(claude_dir) {
            Ok(l) => l,
            Err(e) => {
                tracing::warn!(project = project_path, error = %e, "Failed to load lock store");
                return None;
            }
        };

        let resolved = resolve_state_with_details(&state_store, &lock_store, project_path)?;

        Some(AgentSession {
            agent_type: AgentType::Claude,
            agent_name: self.display_name().to_string(),
            state: Self::map_state(resolved.state),
            session_id: resolved.session_id,
            cwd: resolved.cwd,
            detail: Self::state_detail(resolved.state),
            working_on: resolved.working_on,
            updated_at: resolved.updated_at.map(|t| t.to_rfc3339()),
        })
    }

    fn all_sessions(&self) -> Vec<AgentSession> {
        let claude_dir = match &self.claude_dir {
            Some(d) => d,
            None => return vec![],
        };

        let state_store = match StateStore::new(claude_dir) {
            Ok(s) => s,
            Err(e) => {
                tracing::warn!(error = %e, "Failed to load state store for all_sessions");
                return vec![];
            }
        };

        state_store
            .all_records()
            .into_iter()
            .map(|r| AgentSession {
                agent_type: AgentType::Claude,
                agent_name: self.display_name().to_string(),
                state: Self::map_state(r.state),
                session_id: Some(r.session_id),
                cwd: r.cwd,
                detail: Self::state_detail(r.state),
                working_on: r.working_on,
                updated_at: Some(r.updated_at.to_rfc3339()),
            })
            .collect()
    }

    fn state_mtime(&self) -> Option<SystemTime> {
        let state_file = self.claude_dir.as_ref()?.join("hud-session-states-v2.json");
        std::fs::metadata(&state_file).ok()?.modified().ok()
    }
}
```

---

## 7. Testing Strategy (TDD)

### Testing Pyramid

```
                    ┌─────────────────┐
                    │  Live CLI Tests │  ← Catches upstream changes (nightly)
                    └────────┬────────┘
               ┌─────────────┴─────────────┐
               │   Fixture Integration     │  ← Validates parsing (every commit)
               └─────────────┬─────────────┘
        ┌────────────────────┴────────────────────┐
        │           Unit Tests (TDD)              │  ← Drives design (every commit)
        └─────────────────────────────────────────┘
```

### Unit Tests (Write First)

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_state_mapping_ready() {
        assert_eq!(ClaudeAdapter::map_state(ClaudeState::Ready), AgentState::Ready);
    }

    #[test]
    fn test_state_mapping_compacting_is_working_with_detail() {
        assert_eq!(ClaudeAdapter::map_state(ClaudeState::Compacting), AgentState::Working);
        assert_eq!(
            ClaudeAdapter::state_detail(ClaudeState::Compacting),
            Some("compacting context".to_string())
        );
    }

    #[test]
    fn test_is_installed_returns_false_when_dir_missing() {
        let adapter = ClaudeAdapter { claude_dir: None };
        assert!(!adapter.is_installed());
    }

    #[test]
    fn test_detect_session_returns_none_when_not_installed() {
        let adapter = ClaudeAdapter { claude_dir: None };
        assert!(adapter.detect_session("/some/project").is_none());
    }
}
```

### Fixture Tests

```rust
// tests/agents/claude_fixtures.rs

fn fixture_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/agents/claude")
        .join(name)
}

#[test]
fn test_parse_v2_state_file() {
    let adapter = ClaudeAdapter::with_claude_dir(fixture_path("v2-working"));
    let session = adapter.detect_session("/Users/test/project").unwrap();
    assert_eq!(session.state, AgentState::Working);
}

#[test]
fn test_corrupted_state_file_returns_none() {
    let adapter = ClaudeAdapter::with_claude_dir(fixture_path("corrupted"));
    assert!(adapter.detect_session("/any/path").is_none());
}
```

### Contract Tests

```rust
// tests/agents/adapter_contract.rs

pub trait AdapterContractTests {
    fn adapter(&self) -> &dyn AgentAdapter;

    fn test_id_is_lowercase_no_spaces(&self) {
        let id = self.adapter().id();
        assert_eq!(id, id.to_lowercase());
        assert!(!id.contains(' '));
    }

    fn test_is_installed_does_not_panic(&self) {
        let _ = self.adapter().is_installed();
    }

    fn test_detect_session_with_nonexistent_path_returns_none(&self) {
        assert!(self.adapter().detect_session("/nonexistent/path").is_none());
    }
}
```

### Live CLI Tests (Nightly)

```rust
// tests/integration/live_claude.rs

#[test]
#[ignore] // Run with: LIVE_CLI_TESTS=1 cargo test -- --ignored
fn test_live_session_detection() {
    if std::env::var("LIVE_CLI_TESTS").is_err() { return; }

    let adapter = ClaudeAdapter::new();
    assert!(adapter.is_installed());

    // Start Claude, verify detection, clean up
}
```

### Fixture Directory Structure

```
tests/fixtures/agents/
├── claude/
│   ├── v2-working/
│   │   ├── hud-session-states-v2.json
│   │   └── sessions/{hash}.lock/lock.json
│   ├── v2-multiple-sessions/
│   ├── corrupted/
│   └── empty/
├── codex/
└── amp/
```

### CI Configuration

```yaml
# .github/workflows/live-cli-tests.yml
name: Live CLI Integration Tests

on:
  schedule:
    - cron: '0 6 * * *'  # Daily at 6 AM UTC
  workflow_dispatch:

jobs:
  live-tests:
    runs-on: macos-latest
    strategy:
      fail-fast: false
      matrix:
        cli: [claude, codex, amp]
    steps:
      - uses: actions/checkout@v4
      - name: Run live tests
        run: LIVE_CLI_TESTS=1 cargo test --test live_${{ matrix.cli }} -- --include-ignored
        continue-on-error: true
```

---

## 8. Contributor Guide

### Adding a New Agent Adapter

#### Quick Start

1. Create `src/agents/{agent}.rs`
2. Implement `AgentAdapter` trait (4 required + 3 optional methods)
3. Register in `registry.rs::create_adapters()`
4. Add tests with mock data
5. Submit PR

#### Required Methods Checklist

- [ ] `id()` - lowercase, no spaces (e.g., "codex")
- [ ] `display_name()` - human-readable (e.g., "OpenAI Codex")
- [ ] `is_installed()` - safe check, never panics
- [ ] `detect_session()` - returns `Option<AgentSession>`

#### State Mapping Guide

| Universal State | Meaning | Examples |
|-----------------|---------|----------|
| `Idle` | No session | Not running, terminated |
| `Ready` | Awaiting input | Prompt shown, waiting |
| `Working` | Processing | Thinking, tool use, generating |
| `Waiting` | Blocked | Permission needed, user input required |

Use `detail` field for agent-specific info:

```rust
AgentSession {
    state: AgentState::Working,
    detail: Some("executing tool: browser".to_string()),
    // ...
}
```

#### Error Handling Rules

1. **Never panic** in adapter methods
2. **Log warnings** via `tracing::warn!`
3. **Return None/empty** for transient errors
4. **Use AdapterError** in `initialize()` for fatal issues

#### Testing Requirements

| Category | Required | Command |
|----------|----------|---------|
| Unit tests | ✅ | `cargo test -p hud-core` |
| Contract tests | ✅ | `cargo test --test adapter_contract` |
| Fixture tests | ✅ | `cargo test --test agent_fixtures` |
| Live CLI tests | Optional | `LIVE_CLI_TESTS=1 cargo test` |

#### PR Checklist

- [ ] Trait methods implemented
- [ ] State mapping documented
- [ ] Unit tests passing
- [ ] Contract tests passing
- [ ] Fixture data created
- [ ] `cargo clippy` clean
- [ ] Entry in AGENTS.md

---

## 9. Migration Plan

| Phase | Scope | Deliverables | Risk |
|-------|-------|--------------|------|
| **1** | Module structure | `types.rs`, `mod.rs`, `test_utils.rs` | None - no API changes |
| **2** | Claude adapter | `claude.rs` wrapping existing resolver | Low - behavior preserved |
| **3** | Wire registry | Registry replaces direct resolver calls | Medium - add feature flag |
| **4** | Multi-agent API | `get_all_agent_sessions()`, Swift UI | Low - additive only |
| **5** | Stub adapters | `codex.rs`, `amp.rs` stubs | None - `is_installed() → false` |
| **6** | Documentation | Contributor guide, AGENTS.md | None |

---

## 10. Design Decisions Summary

| Decision | Rationale |
|----------|-----------|
| Adapter pattern | Proven (Starship), contributor-friendly, testable |
| 4 universal states | Balances simplicity with expressiveness; detail string for specifics |
| Flat `AgentType` enum | UniFFI compatibility; `Other` variant for unknown agents |
| `(agent_type, session_id)` key | Prevents cross-agent ID collision |
| Mtime-based caching | Already proven in stats.rs; prevents expensive scans |
| `detect_all_sessions()` | Handles multi-agent scenario (Claude + Codex in same project) |
| User preference order | `agent_order` config; auto-detect with override |
| TDD + live tests | Tests define contracts; live tests catch upstream changes |
| Fixture capture script | Easy to update fixtures when CLIs change |

---

## 11. Open Questions / Future Work

| Topic | Status |
|-------|--------|
| Cross-agent session history | Future: `historical_sessions(since: DateTime)` |
| Agent-specific actions | Future: "resume session", "open in terminal" |
| Plugin-based adapters | Future: Dynamic loading from `~/.claude/agent-adapters/` |
| Windows support | Future: Path normalization for `C:\` style paths |
