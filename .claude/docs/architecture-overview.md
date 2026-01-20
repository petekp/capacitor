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

### Module Overview

The crate is organized into three layers:

```
┌─────────────────────────────────────────────────────────────┐
│                      engine.rs (Facade)                     │
│              Unified API for Swift via UniFFI               │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────┼──────────────────────────────────┐
│  Domain Modules          │                                  │
│  ┌──────────┐ ┌──────────┴───┐ ┌──────────┐ ┌──────────┐   │
│  │projects.rs│ │ sessions.rs │ │artifacts │ │ ideas.rs │   │
│  └──────────┘ └──────────────┘ └──────────┘ └──────────┘   │
│  ┌──────────┐                                              │
│  │ agents/  │ (multi-agent support)                        │
│  └──────────┘                                              │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────┼──────────────────────────────────┐
│  Infrastructure          │                                  │
│  ┌──────────┐ ┌──────────┴───┐ ┌──────────┐ ┌──────────┐   │
│  │ state/   │ │ activity.rs  │ │boundaries│ │ config   │   │
│  │ (module) │ │              │ │          │ │          │   │
│  └──────────┘ └──────────────┘ └──────────┘ └──────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### Modules (in `core/hud-core/src/`)

| Module | Purpose |
|--------|---------|
| `engine.rs` | `HudEngine` facade - unified API for Swift via UniFFI |
| `types.rs` | Shared FFI types: Project, SessionState, Artifact, Plugin, Idea |
| `error.rs` | Error types (`HudError`, `HudFfiError`) and Result alias |

**Domain Modules:**

| Module | Purpose |
|--------|---------|
| `projects.rs` | Project loading, discovery, path encoding, indicators |
| `sessions.rs` | High-level session state detection (wraps `state/` module) |
| `artifacts.rs` | Skill/command/agent discovery and frontmatter parsing |
| `ideas.rs` | Idea capture, status tracking, effort estimation |
| `stats.rs` | Token usage parsing from JSONL, mtime-based caching |
| `agents/` | **Multi-agent subsystem** - AgentAdapter trait, registry, CLI adapters |

**Infrastructure Modules:**

| Module | Purpose |
|--------|---------|
| `state/` | **Session state subsystem** - lock detection, state resolution, persistence |
| `activity.rs` | File activity tracking for monorepo project attribution |
| `boundaries.rs` | Project boundary detection (CLAUDE.md, .git, package.json, etc.) |
| `validation.rs` | Path validation, dangerous path detection |
| `config.rs` | Path resolution (`~/.claude`), config file I/O |
| `patterns.rs` | Pre-compiled regex patterns for JSONL parsing |

### The `state/` Subsystem

The most complex part of the core. Handles detecting whether Claude is running and what it's doing.

```
state/
├── mod.rs        # Public exports
├── types.rs      # ClaudeState, SessionRecord, LockInfo, HookEvent
├── store.rs      # StateStore - persists session states to JSON
├── lock.rs       # Lock file detection, PID verification, orphan cleanup
├── resolver.rs   # Fuses lock + state data to answer queries
├── transition.rs # State machine: HookEvent → ClaudeState
└── integration_tests.rs
```

**Key Types:**

```rust
pub enum ClaudeState { Ready, Working, Compacting, Blocked }

pub struct SessionRecord {
    pub session_id: String,
    pub state: ClaudeState,
    pub cwd: String,
    pub updated_at: DateTime<Utc>,
    pub working_on: Option<String>,
    pub pid: Option<u32>,
}
```

**Resolution Algorithm** (simplified):
1. Check for lock at project path (or child paths)
2. Verify lock's PID is alive with start-time matching
3. Find matching state record by cwd path
4. If record exists with different PID than lock:
   - If record's PID is alive → use record's state (newer session without lock)
   - Otherwise → search for sessions matching lock's PID
5. Apply tie-breakers: freshness → match type → session ID

See [ADR-002: State Resolver Matching Logic](../../docs/architecture-decisions/002-state-resolver-matching-logic.md) for full details.

### The `agents/` Subsystem

Multi-agent support enables HUD to track sessions from different coding assistant CLIs (Claude Code, Codex, Aider, etc.).

```
agents/
├── mod.rs        # AgentAdapter trait, AgentRegistry, test utilities
├── types.rs      # AgentSession, AgentState, AgentConfig, AgentType
├── claude.rs     # ClaudeAdapter - fully implemented for Claude Code
├── registry.rs   # AgentRegistry with mtime-based caching
└── stubs.rs      # Stub adapters for other CLIs (Codex, Aider, Amp, etc.)
```

**Key Types:**

```rust
pub trait AgentAdapter: Send + Sync {
    fn id(&self) -> &'static str;
    fn display_name(&self) -> &'static str;
    fn is_installed(&self) -> bool;
    fn detect_session(&self, project_path: &str) -> Option<AgentSession>;
    fn all_sessions(&self) -> Vec<AgentSession>;
    fn state_mtime(&self) -> Option<SystemTime>;
}

pub enum AgentState { Ready, Working, Waiting, Error }

pub struct AgentSession {
    pub agent_type: AgentType,
    pub state: AgentState,
    pub session_id: Option<String>,
    pub cwd: String,
    pub working_on: Option<String>,
    // ...
}
```

**Starship-style pattern:** Each CLI gets an adapter that knows how to detect installation and parse session state from that tool's specific files.

See [Adding a New CLI Agent Guide](adding-new-cli-agent-guide.md) for implementation details.

### Key Functions

**Session Detection (`sessions.rs`):**
- `detect_session_state()` - Main entry point for Swift; returns `ProjectSessionState`

**State Resolution (`state/resolver.rs`):**
- `resolve_state()` - Returns `Option<ClaudeState>` for a project path
- `resolve_state_with_details()` - Returns `ResolvedState` with session ID and cwd

**Lock Management (`state/lock.rs`):**
- `is_session_running()` - Checks if a lock exists for path (or children)
- `get_lock_info()` - Returns lock metadata (PID, path, timestamps)
- `reconcile_orphaned_lock()` - Cleans up locks with no matching state record

**Project Boundary (`boundaries.rs`):**
- `find_project_boundary()` - Walks up to find nearest CLAUDE.md, .git, etc.
- `is_dangerous_path()` - Rejects `/`, `/Users`, `/home`, etc.

**Activity Tracking (`activity.rs`):**
- `ActivityStore::record_activity()` - Records file edit with project attribution
- `ActivityStore::has_recent_activity()` - Checks for activity within threshold

**Configuration (`config.rs`):**
- `get_claude_dir()` - Resolves `~/.claude` directory
- `load_hud_config()` / `save_hud_config()` - Pinned projects persistence

**HudEngine Facade (`engine.rs`):**
- `HudEngine::new()` - Creates engine instance
- `list_projects()`, `add_project()`, `remove_project()` - Project management
- `get_session_state()`, `get_all_session_states()` - Session queries
- `list_artifacts()`, `list_plugins()` - Artifact discovery
- `load_dashboard()` - All dashboard data in one call

### Key Patterns

**Error Handling:**
- Functions return `Result<T, HudError>` with UniFFI error support
- File operations gracefully degrade (return empty defaults on missing files)

**Caching:**
- Stats cache uses mtime-based invalidation
- Summary cache persists generated summaries to avoid re-computation

**Atomic Writes:**
- All state files use temp file + rename for crash safety

## State Tracking Architecture

**Current approach:** Hooks track local Claude Code sessions, write state to Capacitor namespace.

See [ADR-001: State Tracking Approach](../../docs/architecture-decisions/001-state-tracking-approach.md) for the full decision rationale.

### Local Sessions

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

**State file:** `~/.capacitor/sessions.json` (written by hook script)

**Lock directory:** `~/.claude/sessions/{hash}.lock/` (created by Claude Code CLI)

**Hook script:** `~/.claude/scripts/hud-state-tracker.sh`

**Testing & Documentation:**
- **State machine reference:** `.claude/docs/hook-state-machine.md`
- **Prevention checklist:** `.claude/docs/hook-prevention-checklist.md`
- **Test suite:** `~/.claude/scripts/test-hud-hooks.sh`

## Runtime Configuration

The app uses two namespaces:

**Capacitor namespace** (`~/.capacitor/`) — owned by Capacitor:
```
~/.capacitor/
├── config.json                    # Pinned projects, settings
├── sessions.json                  # Session states (written by hooks)
├── stats-cache.json               # Cached token usage
├── summaries.json                 # Session summaries cache
├── project-summaries.json         # Project overview bullets
├── creations.json                 # Project creation progress
└── projects/{encoded-path}/       # Per-project data
    ├── ideas.md                   # Ideas for this project
    └── ideas-order.json           # Display order
```

**Claude namespace** (`~/.claude/`) — owned by Claude Code CLI, read-only for Capacitor:
```
~/.claude/
├── settings.json                  # Global Claude Code config
├── sessions/                      # Lock directories ({hash}.lock/)
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
- Chrono - Date/time handling
- Sysinfo - Process verification (PID alive checks)
