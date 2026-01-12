# Claude HUD - Project Development Guide

Claude HUD is a native macOS desktop application that serves as a dashboard for Claude Code, displaying project statistics, task tracking, plugin management, and global Claude Code configuration insights.

- **Swift App** (apps/swift) - Native macOS app with SwiftUI, 120Hz ProMotion animations
- **Rust Core** (core/hud-core) - Shared business logic via UniFFI bindings

> **Development Workflow:** Run `cd apps/swift && swift build && swift run`. Rebuild after changes.

## Session Startup Checklist

When starting a development session on this project:

1. **Run the Swift HUD in background:** `cd apps/swift && swift run &`
2. **Rebuild after Swift changes:** If you modify Swift code or regenerate UniFFI bindings, rebuild with `cd apps/swift && swift build` then restart with `swift run &`
3. **State tracking is automatic:** Hooks in `~/.claude/settings.json` track thinking state. Just run `claude` normally.

## Product Vision

**Claude HUD lets you develop and ship more projects in parallel by eliminating the cognitive overhead of context-switching.** Instead of remembering where you left off across a dozen projects, the HUD shows you—automatically, at a glance. Wake up, open the app, pick a project, and resume instantly.

**The core problem:** When you have many Claude Code projects in flight simultaneously, context-switching is expensive. You lose track of what you were working on, what the next step was, and whether you're blocked. Without visibility, projects stall and momentum is lost. The cognitive load of "remembering where everything is at" limits how many projects you can realistically push forward.

**The insight:** Claude already knows what you were doing in each project. The HUD surfaces that context automatically via hooks—so you don't have to maintain a separate system or hold it all in your head.

**Target use case:** You wake up, open Claude HUD, see all your projects with their current status, know exactly where each one stands, pick the one that makes sense to work on, and jump in with full context—in seconds, not minutes.

## Project Overview

**Architecture:**

```
┌─────────────────────────────────────────────────────────────┐
│               Swift App (apps/swift)                        │
│               SwiftUI + 120Hz ProMotion                     │
│               Native macOS 14+                              │
└──────────────────────────┬──────────────────────────────────┘
                           │ UniFFI
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                    hud-core (core/hud-core)                 │
│  Shared Rust library: projects, sessions, stats, artifacts │
└─────────────────────────────────────────────────────────────┘
```

**Swift App** (`apps/swift/`):
- Native SwiftUI for macOS 14+
- UniFFI bindings to hud-core
- 120Hz ProMotion animations
- Single-platform focus for optimal native experience

**Shared Core** (`core/hud-core/`):
- Pure Rust library with all business logic
- Project scanning, session state, statistics, artifacts
- Exports via UniFFI for Swift

## Development Workflow

### Quick Start

```bash
cargo build -p hud-core --release  # Build Rust library first
cd apps/swift
swift build       # Debug build
swift run         # Run the app
```

### Common Commands

#### Rust Core (from root)
```bash
cargo check --workspace    # Check all crates
cargo build --workspace    # Build all crates
cargo build -p hud-core --release  # Build core for Swift
cargo fmt                  # Format code (required before commits)
cargo clippy -- -D warnings  # Lint
cargo test                 # Run all tests
```

#### Swift App (from `apps/swift/`)
```bash
swift build             # Debug build
swift build -c release  # Release build
swift run               # Run the app
```

### Building for Distribution

```bash
cargo build -p hud-core --release
cd apps/swift
swift build -c release
# Create .app bundle manually or use xcodebuild
```

## Project Structure

```
claude-hud/
├── CLAUDE.md                    # This file
├── Cargo.toml                   # Workspace manifest
├── core/
│   └── hud-core/                # Shared Rust core library
│       ├── Cargo.toml
│       └── src/
│           ├── lib.rs           # Re-exports + UniFFI scaffolding
│           ├── engine.rs        # HudEngine facade
│           ├── types.rs         # Shared types (UniFFI exported)
│           ├── error.rs         # Error types (UniFFI exported)
│           ├── patterns.rs      # Compiled regex patterns
│           ├── config.rs        # Config and path utilities
│           ├── stats.rs         # Statistics parsing and caching
│           ├── projects.rs      # Project loading and discovery
│           ├── sessions.rs      # Session state detection
│           └── artifacts.rs     # Artifact discovery
├── apps/
│   ├── swift/                   # Native macOS app
│   │   ├── Package.swift        # Swift Package Manager config
│   │   ├── Sources/
│   │   │   ├── ClaudeHUD/       # SwiftUI app
│   │   │   │   ├── App.swift
│   │   │   │   ├── ContentView.swift
│   │   │   │   ├── Models/
│   │   │   │   ├── Views/
│   │   │   │   └── Theme/
│   │   │   └── HudCoreFFI/      # FFI module wrapper
│   │   └── bindings/            # Generated UniFFI bindings
│   │       ├── hud_core.swift
│   │       └── hud_coreFFI.h
│   ├── daemon/                  # HUD daemon (TypeScript) - for future remote use
│   ├── relay/                   # WebSocket relay server
│   └── sdk-bridge/              # Agent SDK integration bridge
├── target/                      # Shared Rust build output
├── .claude/
│   └── docs/                    # Project architecture documentation
├── docs/
│   ├── claude-code-artifacts.md # Claude Code disk artifacts reference
│   ├── claude-code/             # Claude Code CLI documentation
│   ├── agent-sdk/               # Claude Agent SDK documentation
│   └── architecture-decisions/  # ADRs
└── scripts/
    ├── fetch-cc-docs.ts         # Fetch Claude Code docs from GitHub
    └── fetch-agent-sdk-docs.ts  # Fetch Agent SDK docs (requires Playwright)
```

## Swift App Architecture

The Swift app is a **native SwiftUI application** in `apps/swift/`. It communicates with the Rust core via UniFFI bindings.

### Key Files

| File | Purpose |
|------|---------|
| `Sources/ClaudeHUD/App.swift` | SwiftUI app entry point |
| `Sources/ClaudeHUD/ContentView.swift` | Main view with navigation |
| `Sources/ClaudeHUD/Models/AppState.swift` | State management with HudEngine bridge |
| `Sources/ClaudeHUD/Views/` | SwiftUI views (Projects, Artifacts, etc.) |
| `Sources/ClaudeHUD/Theme/` | Design system and styling |
| `bindings/hud_core.swift` | Generated UniFFI Swift bindings |

### Architecture

- **State Management:** `@Observable` AppState class bridging to HudEngine
- **FFI:** UniFFI-generated Swift bindings to hud-core
- **UI Framework:** SwiftUI with 120Hz ProMotion support
- **Styling:** Native macOS design language
- **Navigation:** Tab-based with sidebar

### Adding a New View

1. **Create view:** Add SwiftUI view in `apps/swift/Sources/ClaudeHUD/Views/`
2. **Update state:** Add published properties to `AppState.swift` if needed
3. **Wire up:** Add navigation in `ContentView.swift`

## Rust Core Architecture

The `hud-core` library contains all business logic, exported via UniFFI for Swift consumption.

### hud-core Modules (in `core/hud-core/src/`)

| Module | Purpose |
|--------|---------|
| `engine.rs` | `HudEngine` facade - unified API for Swift |
| `types.rs` | Shared types: Project, Task, Artifact, Plugin, etc. |
| `patterns.rs` | Pre-compiled regex patterns for JSONL parsing |
| `config.rs` | Path resolution and config file operations |
| `stats.rs` | Token usage parsing and mtime-based caching |
| `projects.rs` | Project loading, discovery, and indicators |
| `sessions.rs` | Session state detection and status reading |
| `artifacts.rs` | Artifact discovery and frontmatter parsing |
| `error.rs` | Error types and Result alias |

### Data Structures (in `hud-core/types.rs`)
- **GlobalConfig:** Claude Code global settings (skills, commands, agents directories)
- **Project/ProjectDetails/Task:** Project tracking and session management
- **ProjectStats:** Token usage analytics and caching
- **Plugin:** Plugin registry with artifact counts
- **HudConfig:** Pinned projects persistent state

### Key Functions (in hud-core)

**Configuration & Paths (`config.rs`):**
- `get_claude_dir()` - Resolves `~/.claude` directory
- `load_hud_config()` / `save_hud_config()` - Pinned projects persistence
- `load_stats_cache()` / `save_stats_cache()` - Token stats caching

**Statistics & Parsing (`stats.rs`):**
- `parse_stats_from_content()` - Regex extraction from JSONL session files
- `compute_project_stats()` - Intelligent caching with file mtime tracking
- Tracks input/output tokens, cache tokens, model usage (Opus/Sonnet/Haiku)

**Project Discovery (`projects.rs`):**
- `has_project_indicators()` - Detects project types (.git, package.json, Cargo.toml, etc.)
- `build_project_from_path()` - Constructs Project objects
- `load_projects()` - Loads pinned projects sorted by activity

**Session State (`sessions.rs`):**
- `detect_session_state()` - Determines current state (working, ready, idle, etc.)
- `read_project_status()` - Reads status from `~/.claude/hud-session-states.json`

**HudEngine Facade (`engine.rs`):**
- `HudEngine::new()` - Creates engine instance
- `list_projects()`, `add_project()`, `remove_project()` - Project management
- `list_artifacts()`, `list_plugins()` - Artifact discovery
- `load_dashboard()` - All dashboard data in one call

### Key Patterns

**Error Handling:**
- Functions return `Result<T, HudError>` with UniFFI error support
- File operations gracefully degrade (return empty defaults on missing files)

**Caching:**
- Stats cache uses mtime-based invalidation
- Summary cache persists generated summaries to avoid re-computation

## State Tracking Architecture

**Current approach:** Hooks for local sessions, daemon reserved for future remote/mobile use.

See [ADR-001: State Tracking Approach](docs/architecture-decisions/001-state-tracking-approach.md) for the full decision rationale.

### Local Sessions (Current)

For interactive CLI sessions, we use Claude Code hooks:

```
User runs claude → Hooks fire → State file updated → Swift HUD reads
```

**Hooks configured:**
- `UserPromptSubmit` → thinking: true, state: working
- `PostToolUse` → heartbeat (maintains thinking: true)
- `Stop` → thinking: false, state: ready
- `Notification` (idle_prompt) → thinking: false, state: ready

**State file:** `~/.claude/hud-session-states.json`

**Hook script:** `~/.claude/scripts/hud-state-tracker.sh`

### HUD Daemon (Future Remote Use)

The daemon in `apps/daemon/` provides **precise state tracking** via `--output-format stream-json`. It's reserved for future mobile/remote client integration.

**Why not use daemon for local?** Claude's `--output-format stream-json` replaces the TUI with JSON output. You can't have both Claude's interactive TUI and structured JSON from the same process.

For detailed daemon design, see `docs/hud-daemon-design.md`.

## Runtime Configuration

The app reads from `~/.claude/` directory:

```
~/.claude/
├── settings.json                  # Global Claude Code config
├── hud.json                       # Pinned projects
├── hud-stats-cache.json           # Cached token usage
├── hud-summaries.json             # Session summaries cache
├── hud-project-summaries.json     # Project overview bullets
├── projects/                      # Session files ({encoded-path}/{sessionid}.jsonl)
└── plugins/installed_plugins.json # Plugin registry
```

For a comprehensive reference of all Claude Code disk artifacts (file formats, data structures, retention policies), see **[docs/claude-code-artifacts.md](docs/claude-code-artifacts.md)**.

## Documentation

This project has comprehensive documentation organized by purpose.

### Quick Reference: Where to Look

| If you need to... | Look in |
|-------------------|---------|
| Implement hooks, plugins, MCP, or settings | `docs/claude-code/` |
| Build programmatic SDK integrations | `docs/agent-sdk/` |
| Understand HUD architecture decisions | `.claude/docs/` |
| Review ADRs (Architecture Decision Records) | `docs/architecture-decisions/` |
| Understand Claude Code disk artifacts | `docs/claude-code-artifacts.md` |

### Claude Code CLI Documentation (`docs/claude-code/`)

Official Claude Code documentation for integrating with hooks, plugins, settings, MCP, and sessions.

| Topic | File | Use When |
|-------|------|----------|
| Hooks | `hooks.md` | Implementing hook-based features |
| Plugins | `plugins.md` | Plugin management, discovery |
| Settings | `settings.md` | Reading/displaying Claude Code config |
| MCP | `mcp.md` | Model Context Protocol integration |
| Sessions | `interactive-mode.md` | Session file parsing, history |
| CLI | `cli-reference.md` | Invoking Claude Code programmatically |
| Memory | `memory.md` | CLAUDE.md files, project context |
| Sub-agents | `sub-agents.md` | Task tool, agent spawning |

**Update:** `npx tsx scripts/fetch-cc-docs.ts`

### Agent SDK Documentation (`docs/agent-sdk/`)

TypeScript/Python SDK for programmatic Claude Code integration.

| Topic | File | Use When |
|-------|------|----------|
| Overview | `overview.md` | Understanding SDK capabilities |
| Sessions | `sessions.md` | Session management, resumption, forking |
| Hooks | `hooks.md` | SDK hooks (PreToolUse, PostToolUse, etc.) |
| Subagents | `subagents.md` | Creating and invoking subagents |
| Permissions | `permissions.md` | Permission modes, tool access control |
| Custom Tools | `custom-tools.md` | Creating custom MCP tools |
| TypeScript | `typescript.md` | Full TypeScript API reference |
| Python | `python.md` | Full Python API reference |
| Migration | `migration-guide.md` | Migrating from CLI to SDK |

**Update:** `npx tsx scripts/fetch-agent-sdk-docs.ts` (requires Playwright)

### Project Architecture (`.claude/docs/`)

HUD-specific architecture documents, design decisions, and feature specs.

| Document | Purpose |
|----------|---------|
| `status-sync-architecture.md` | Real-time status sync between Claude sessions and HUD |
| `agent-sdk-migration-guide.md` | Migration strategy from CLI to Agent SDK |
| `feature-idea-to-v1-launcher.md` | TDD feature spec for "Idea → V1 Launcher" |

### ADRs (`docs/architecture-decisions/`)

Architecture Decision Records documenting key technical decisions.

| ADR | Decision |
|-----|----------|
| `001-state-tracking-approach.md` | Hooks for local sessions, daemon for remote/mobile |

### Maintaining Documentation

| Content Type | Location | When to Use |
|--------------|----------|-------------|
| Task list (what to do) | `TODO.md` | Adding/completing tasks |
| Completed work | `DONE.md` | Archiving finished work |
| Feature specs | `.claude/docs/feature-*.md` | Planning complex features |
| Architecture docs | `.claude/docs/*-architecture.md` | Documenting system design |
| Sprint plans | `.claude/plans/` | Planning milestones |
| Decision records | `docs/architecture-decisions/` | Recording key decisions |

**Rules for TODO.md:**
- Keep it scannable (< 100 lines of active work)
- Only unchecked `[ ]` items belong here
- Move completed items to `DONE.md` promptly
- Link to detailed specs rather than embedding them
- Use sections: 🎯 Active → 📋 Next → 💡 Backlog

## Common Development Scenarios

### Modifying Statistics Parsing
- Update regex patterns in `parse_stats_from_content()` (`core/hud-core/src/stats.rs`)
- Update `ProjectStats` struct in `core/hud-core/src/types.rs`
- Delete `~/.claude/hud-stats-cache.json` to force recomputation

### Adding Project Type Detection
- Modify `has_project_indicators()` (`core/hud-core/src/projects.rs`)
- Add file/directory checks for new project type

### Regenerating Swift Bindings
```bash
cd core/hud-core
cargo run --bin uniffi-bindgen generate src/lib.rs --language swift --out-dir ../../apps/swift/bindings/
```

## Code Style & Conventions

**Rust:**
- Use `cargo fmt` for formatting (required)
- Run `cargo clippy -- -D warnings` for linting
- Prefer easy-to-read code over clever code
- No extraneous comments; code should be self-documenting

**Swift:**
- Follow Swift API Design Guidelines
- Use SwiftUI idioms and patterns
- Prefer easy-to-read code over clever code

## Debugging

```bash
# Inspect cache files
cat ~/.claude/hud-stats-cache.json | jq .

# Enable Rust debug logging
RUST_LOG=debug swift run

# Test regex patterns
echo '{"input_tokens":1234}' | rg 'input_tokens":(\d+)'
```

## Key Dependencies

**Swift App:**
- SwiftUI - Native UI framework
- Foundation - Core utilities
- AppKit - macOS integration

**Rust Core:**
- UniFFI - Swift/Kotlin/Python bindings
- Serde - JSON serialization
- Regex - Pattern matching in session files
- Walkdir - Directory traversal
- Dirs - Platform-specific paths

## Important Notes

- **Workspace Structure:** This is a Cargo workspace with `core/hud-core` (shared library). Use `cargo build --workspace` to build.
- **UniFFI Bindings:** Swift app uses UniFFI-generated bindings in `apps/swift/bindings/`
- **Path Encoding:** Project paths use `/` → `-` replacement (e.g., `/Users/peter/Code` → `-Users-peter-Code`)
- **Caching Strategy:** Mtime-based invalidation; old cache entries are harmless
- **Platform Support:** macOS 14+ (Apple Silicon and Intel)
- **Claude CLI Path:** Summary generation uses `/opt/homebrew/bin/claude` (macOS Homebrew)
