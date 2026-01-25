# Multi-Agent CLI Support

**Status:** Done
**Completed:** January 2026

## Summary

Implemented Starship-style adapter pattern enabling Capacitor to detect sessions from multiple AI coding CLI agents (Claude Code, Codex, Aider, Amp, OpenCode, Droid), not just Claude.

## What Was Built

**AgentAdapter Trait** (`core/hud-core/src/agents/mod.rs`)
- 4 required methods: `id()`, `display_name()`, `is_installed()`, `detect_session()`
- 3 optional: `initialize()`, `all_sessions()`, `state_mtime()`

**Universal Types** (`core/hud-core/src/agents/types.rs`)
- `AgentState`: Idle, Ready, Working, Waiting
- `AgentSession`: Universal session representation
- `AgentType`: Claude, Codex, Aider, Amp, OpenCode, Droid, Other
- `AgentConfig`: User preferences (disabled agents, display order)

**AgentRegistry** (`core/hud-core/src/agents/registry.rs`)
- Creates and manages all adapters
- `detect_all_sessions()` returns sessions from all agents
- Mtime-based caching for performance
- Respects user agent_order preferences

**Adapters**
- Claude adapter (full implementation wrapping existing resolver)
- Stub adapters for Codex, Aider, Amp, OpenCode, Droid

## Engine API

```rust
engine.get_agent_sessions(project_path)  // All agents for a project
engine.get_primary_agent_session(path)   // First agent (backward compat)
engine.get_all_agent_sessions()          // Global cached sessions
engine.list_installed_agents()           // For UI display
```

## Files

| Component | Location |
|-----------|----------|
| Trait + types | `core/hud-core/src/agents/mod.rs`, `types.rs` |
| Registry | `core/hud-core/src/agents/registry.rs` |
| Claude adapter | `core/hud-core/src/agents/claude.rs` |
| Stub adapters | `core/hud-core/src/agents/stubs.rs` |
| Test fixtures | `tests/fixtures/agents/claude/` |
| Contributor guide | `.claude/docs/adding-new-cli-agent-guide.md` |

## Adding New Agents

See `.claude/docs/adding-new-cli-agent-guide.md` for the 4-milestone tutorial.
