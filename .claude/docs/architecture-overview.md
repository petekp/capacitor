# Architecture Overview

Detailed architecture documentation for Claude HUD.

## System Architecture

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

### Patterns

- **State Management:** `@Observable` AppState class bridging to HudEngine
- **FFI:** UniFFI-generated Swift bindings to hud-core
- **UI Framework:** SwiftUI with 120Hz ProMotion support
- **Styling:** Native macOS design language
- **Navigation:** Tab-based with sidebar

## Rust Core Architecture

The `hud-core` library contains all business logic, exported via UniFFI for Swift consumption.

### Modules (in `core/hud-core/src/`)

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

### Data Structures (in `types.rs`)

- **GlobalConfig:** Claude Code global settings (skills, commands, agents directories)
- **Project/ProjectDetails/Task:** Project tracking and session management
- **ProjectStats:** Token usage analytics and caching
- **Plugin:** Plugin registry with artifact counts
- **HudConfig:** Pinned projects persistent state

### Key Functions

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

See [ADR-001: State Tracking Approach](../../docs/architecture-decisions/001-state-tracking-approach.md) for the full decision rationale.

### Local Sessions (Current)

For interactive CLI sessions, we use Claude Code hooks:

```
User runs claude → Hooks fire → State file updated → Swift HUD reads
```

**Hooks configured:**
- `SessionStart` → state: ready (creates lock file)
- `UserPromptSubmit` → state: working (creates lock if missing for resumed sessions)
- `PermissionRequest` → state: blocked
- `PostToolUse` → state transitions + heartbeat updates
- `Notification` (idle_prompt) → state: ready
- `Stop` → state: ready
- `PreCompact` → state: compacting
- `SessionEnd` → removes session from state file

**State file:** `~/.claude/hud-session-states-v2.json`

**Hook script:** `~/.claude/scripts/hud-state-tracker.sh`

**Testing & Documentation:**
- **State machine reference:** `.claude/docs/hook-state-machine.md`
- **Prevention checklist:** `.claude/docs/hook-prevention-checklist.md`
- **Test suite:** `~/.claude/scripts/test-hud-hooks.sh`

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

For a comprehensive reference of all Claude Code disk artifacts (file formats, data structures, retention policies), see **[docs/claude-code-artifacts.md](../../docs/claude-code-artifacts.md)**.

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
