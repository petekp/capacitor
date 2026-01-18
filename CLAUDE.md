# Claude HUD

Native macOS dashboard for Claude Code—displays project statistics, session states, and helps you context-switch between projects instantly.

## Stack

- **Swift App** (`apps/swift/`) — SwiftUI, macOS 14+, 120Hz ProMotion
- **Rust Core** (`core/hud-core/`) — Business logic via UniFFI bindings

## Commands

```bash
# Build and run
cargo build -p hud-core --release && cd apps/swift && swift build && swift run

# Rust
cargo fmt                         # Format (required before commits)
cargo clippy -- -D warnings       # Lint
cargo test                        # Test

# Swift (from apps/swift/)
swift build                       # Debug build
swift run                         # Run app

# Restart app (use this script - pre-approved in permissions)
/Users/petepetrash/Code/claude-hud/scripts/restart-app.sh
```

## Structure

```
claude-hud/
├── core/hud-core/src/      # Rust: engine.rs, types.rs, stats.rs, projects.rs, sessions.rs
├── apps/swift/Sources/     # Swift: App.swift, Models/, Views/, Theme/
├── .claude/docs/           # Architecture docs, feature specs
└── docs/                   # Claude Code CLI docs, Agent SDK docs, ADRs
```

## Core Principle: Sidecar Architecture

**Claude HUD is a sidecar that powers up your existing Claude Code workflow—not a standalone app.**

- Read from `~/.claude/` — session files, config, plugins, stats
- Invoke the `claude` CLI — for AI features, call CLI rather than API directly
- Respect existing workflows — HUD observes and surfaces, doesn't replace

See [ADR-003: Sidecar Architecture Pattern](docs/architecture-decisions/003-sidecar-architecture-pattern.md).

## Key Files

| Purpose | Location |
|---------|----------|
| HudEngine facade | `core/hud-core/src/engine.rs` |
| Shared types | `core/hud-core/src/types.rs` |
| Session state detection | `core/hud-core/src/sessions.rs` |
| Swift app state | `apps/swift/Sources/ClaudeHUD/Models/AppState.swift` |
| UniFFI bindings | `apps/swift/Sources/ClaudeHUD/Bridge/hud_core.swift` |

## State Tracking

Hooks track local Claude Code sessions → state file → HUD reads.

- **State file:** `~/.claude/hud-session-states-v2.json`
- **Hook script:** `~/.claude/scripts/hud-state-tracker.sh`
- **State machine spec:** `.claude/docs/hook-state-machine.md`

## Documentation Index

| Need | Document |
|------|----------|
| Development workflows | `.claude/docs/development-workflows.md` |
| Detailed architecture | `.claude/docs/architecture-overview.md` |
| Debugging procedures | `.claude/docs/debugging-guide.md` |
| Hook state machine | `.claude/docs/hook-state-machine.md` |
| Hook troubleshooting | `.claude/docs/hook-prevention-checklist.md` |
| Claude Code CLI reference | `docs/claude-code/` |
| Agent SDK reference | `docs/agent-sdk/` |
| Architecture decisions | `docs/architecture-decisions/` |

## Notes

- **Path encoding:** Project paths use `/` → `-` replacement (e.g., `/Users/peter/Code` → `-Users-peter-Code`)
- **Caching:** Mtime-based invalidation in stats and summaries
- **Platform:** macOS 14+ (Apple Silicon and Intel)
- **UniFFI bindings:** Must update both `apps/swift/bindings/` and `apps/swift/Sources/ClaudeHUD/Bridge/` after Rust API changes (see development-workflows.md)
