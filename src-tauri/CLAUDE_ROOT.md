# Claude HUD - Development Guide

Claude HUD is a cross-platform desktop application serving as a dashboard for Claude Code, displaying project statistics, task tracking, plugin management, and global Claude Code configuration insights. It combines a Rust backend (Tauri) with a TypeScript/Vue frontend.

## Quick Start

### Development Setup (Two Terminals)

From the root `claude-hud/` directory:

**Terminal 1 - Frontend dev server:**
```bash
pnpm dev
# Runs Vue dev server on http://localhost:5173 with hot reload
```

**Terminal 2 - Tauri dev mode (watches both frontend and backend):**
```bash
cd src-tauri
cargo tauri dev
# Hot-reloads entire app when changes detected
```

Both processes must be running during development. The Tauri app automatically connects to the dev server.

### Common Commands

All backend commands run from `src-tauri/` directory. Frontend commands run from root.

**Frontend (from root):**
```bash
pnpm dev              # Start dev server
pnpm build            # Build for production (outputs to dist/)
pnpm preview          # Preview production build locally
pnpm lint             # Run ESLint
pnpm type-check       # Run TypeScript type checking
```

**Backend (from src-tauri/):**
```bash
cargo check           # Check code without building
cargo fmt             # Format code (required before commits)
cargo clippy -- -D warnings  # Lint and catch common mistakes
cargo build           # Debug build
cargo build --release # Release build (optimized)
cargo test            # Run all tests
cargo test name_pattern -- --nocapture  # Run specific test with output
cargo tauri dev       # Launch app in dev mode (watches both)
cargo tauri build     # Build optimized app for distribution
```

### Building for Distribution

```bash
# From root - build frontend first
pnpm build

# Then build the desktop app (from src-tauri/)
cd src-tauri
cargo tauri build

# Build for specific platform
cargo tauri build --target aarch64-apple-darwin # macOS Apple Silicon
cargo tauri build --target x86_64-apple-darwin  # macOS Intel
cargo tauri build --target x86_64-pc-windows-msvc # Windows
```

Built apps appear in `src-tauri/target/release/bundle/`.

## Architecture Overview

### Big Picture

Claude HUD is a desktop app with clear separation of concerns:

1. **Frontend** (TypeScript/Vue 3) - UI, user interactions, caching with Pinia
2. **IPC Bridge** (Tauri) - Secure command/event communication
3. **Backend** (Rust monolith in `lib.rs`) - All business logic, file I/O, data discovery

The backend is a single 1,733-line Rust file (`src-tauri/src/lib.rs`) containing:
- Data structures and serialization
- File system operations (stats parsing, artifact discovery)
- Tauri IPC command handlers (`#[tauri::command]`)
- Background task threads

### Data Flow Example: Load Dashboard

```
Frontend: invoke('load_dashboard')
    ↓
Backend: load_dashboard() command (lines 769-804)
    ├─ get_claude_dir() → resolve ~/.claude
    ├─ load_global_config() → read settings.json
    ├─ load_plugins() → parse installed_plugins.json
    ├─ load_projects_internal() → get pinned projects
    │   ├─ load_stats_cache() → mtime-based cache
    │   ├─ For each project:
    │   │   ├─ build_project_from_path()
    │   │   ├─ compute_project_stats()
    │   │   │   ├─ Check file mtime vs cached mtime
    │   │   │   ├─ If miss: parse all .jsonl files
    │   │   │   └─ parse_stats_from_content() → regex extract tokens
    │   │   └─ Format relative times
    │   └─ save_stats_cache()
    └─ Return DashboardData { global, plugins, projects }
        ↓
Frontend: Serialize JSON → display UI
```

### Technology Stack

| Layer | Technology | Purpose |
|-------|-----------|---------|
| Desktop Framework | Tauri 2.9.5 | Cross-platform app bundling |
| Backend | Rust 1.77.2+ | Performance, file ops, data discovery |
| Frontend | Vue 3 + TypeScript | Reactive UI, type safety |
| State Management | Pinia | Frontend caching and state |
| Build Tools | Cargo + pnpm | Backend and frontend builds |
| Platforms | macOS, Windows, Linux | Full desktop support |

## Core Data Structures

Located in `src-tauri/src/lib.rs` (lines 10-153):

**GlobalConfig** - Claude Code's global settings
- `settings_path`, `skills_path`, `commands_path`, `agents_path`
- Artifact counts (skill_count, command_count, agent_count)
- Parsed from `~/.claude/settings.json`

**Project** - Individual project metadata
- `name`, `path`, `display_path`
- `last_active`, `task_count`, `stats` (ProjectStats object)
- `claude_md_path`, `claude_md_preview`
- Built from pinned projects or discovered projects

**ProjectStats** - Token usage analytics
- `total_input_tokens`, `total_output_tokens`
- `total_cache_read_tokens`, `total_cache_creation_tokens`
- `opus_messages`, `sonnet_messages`, `haiku_messages` (model breakdown)
- `session_count`, `first_activity`, `last_activity`, `latest_summary`
- Computed by parsing JSONL session files with regex

**Task** - Individual Claude Code session
- `id`, `name`, `path`
- `last_modified`, `summary`, `first_message`
- Extracted from session metadata

**Plugin** - Installed Claude Code plugin
- `id`, `name`, `description`, `enabled`
- `path`, `skill_count`, `command_count`, `agent_count`, `hook_count`
- Read from `~/.claude/plugins/installed_plugins.json`

**Artifact** - Individual skill/command/agent
- `artifact_type` ("skill" | "command" | "agent")
- `name`, `description`, `source` (global or plugin name)
- `path` (absolute file system path)

## Key Functions by Module

### Configuration & Paths (lines 154-195)

| Function | Purpose |
|----------|---------|
| `get_claude_dir()` | Resolve `~/.claude` using `dirs` crate |
| `get_hud_config_path()` | Path to `~/.claude/hud.json` |
| `get_stats_cache_path()` | Path to `~/.claude/hud-stats-cache.json` |
| `load_hud_config()` | Load pinned projects from disk |
| `save_hud_config()` | Persist pinned projects |
| `load_stats_cache()` | Load cached token stats |
| `save_stats_cache()` | Persist token stats |

### Statistics & Parsing (lines 196-326)

**`parse_stats_from_content()` (lines 196-255):**
Regex-based extraction from JSONL lines. Updates ProjectStats with:
- `"input_tokens":(\d+)` → input_tokens
- `"output_tokens":(\d+)` → output_tokens
- `"cache_read_input_tokens":(\d+)` → cache_read_tokens
- `"cache_creation_input_tokens":(\d+)` → cache_creation_tokens
- `"model":"claude-([^"]+)"` → model detection (opus/sonnet/haiku)
- Timestamps for first/last activity

**`compute_project_stats()` (lines 257-326):**
Intelligent mtime-based caching:
- Checks file size and mtime against `StatsCache`
- Cache hit: returns cached ProjectStats
- Cache miss: parses all .jsonl files in directory
- Stores CachedFileInfo for future invalidation

### File Discovery & Artifacts (lines 336-472)

| Function | Purpose |
|----------|---------|
| `count_artifacts_in_dir()` | Count skills, commands, agents (by file pattern) |
| `parse_frontmatter()` | Extract YAML `name:` and `description:` from markdown |
| `collect_artifacts_from_dir()` | Build Artifact objects with metadata |
| `count_hooks_in_dir()` | Check for hooks.json in plugin directories |

### Project Management (lines 867-969)

| Function | Purpose |
|----------|---------|
| `has_project_indicators()` | Detect project type by file presence (.git, Cargo.toml, etc.) |
| `build_project_from_path()` | Construct Project object from directory path |
| `load_projects_internal()` | Load pinned projects from HUD config, compute stats |
| `try_resolve_encoded_path()` | Reconstruct path from encoded name (/ → -) |

### Session Summarization (lines 569-1494)

| Function | Purpose |
|----------|---------|
| `extract_session_context()` | Parse JSONL, extract up to 6 messages |
| `generate_session_summary_sync()` | Sync summary generation via Claude CLI |
| `generate_session_summary()` | On-demand summary with caching (lines 1313-1352) |
| `start_background_summaries()` | Thread-based summary generation with events (lines 1355-1396) |
| `start_background_project_summaries()` | Multi-session project overview (lines 1399-1494) |
| `is_bad_summary()` | Validate summary quality |

### Tauri IPC Handlers (lines 769-1678)

All use `#[tauri::command]` decorator, return `Result<T, String>`:

| Command | Purpose |
|---------|---------|
| `load_dashboard()` | GlobalConfig, plugins, projects |
| `load_projects()` | Pinned projects only |
| `load_project_details()` | Project + tasks + git status |
| `load_artifacts()` | All skills/commands/agents (global + plugins) |
| `toggle_plugin()` | Enable/disable plugin in settings.json |
| `read_file_content()` | Read arbitrary file content |
| `open_in_editor()` | Launch file in platform editor |
| `open_folder()` | Open folder in platform file browser |
| `launch_in_terminal()` | Open Warp terminal (macOS only) |
| `generate_session_summary()` | On-demand summary generation |
| `start_background_summaries()` | Background summaries with events |
| `start_background_project_summaries()` | Background project overview |
| `add_project()` / `remove_project()` | Manage pinned projects |
| `load_suggested_projects()` | Discover projects with activity |

## Runtime File Structure

Located at `~/.claude/` (managed by Claude Code, read by HUD):

```
~/.claude/
├── settings.json                  # Global config (skills, commands, agents paths)
├── CLAUDE.md                      # Global instructions
├── hud.json                       # HUD-specific: pinned projects
├── hud-stats-cache.json           # HUD-specific: cached token stats (mtime-based)
├── hud-summaries.json             # HUD-specific: cached session summaries
├── hud-project-summaries.json     # HUD-specific: cached project overviews
├── projects/                      # Claude Code session storage
│   └── {encoded-path}/            # Path encoding: /Users/john/Code → -Users-john-Code
│       ├── {uuid}.jsonl           # Session file (one JSON event per line)
│       ├── {uuid}.jsonl
│       └── ...
├── plugins/
│   ├── installed_plugins.json     # Plugin registry
│   └── {plugin-id}/
│       ├── .claude-plugin/plugin.json
│       ├── skills/, commands/, agents/
│       └── hooks/hooks.json
├── skills/ → {symlink}            # Global skills directory
├── commands/ → {symlink}          # Global commands directory
└── agents/ → {symlink}            # Global agents directory
```

### JSONL Session Format

Each line is a single JSON object (one event per line):

```json
{
  "type": "user|assistant|summary",
  "message": {
    "content": "string or [{\"type\": \"text\", \"text\": \"...\"}]"
  },
  "model": "claude-opus-4-5-20251101",
  "input_tokens": 1234,
  "output_tokens": 5678,
  "cache_read_input_tokens": 0,
  "cache_creation_input_tokens": 0,
  "timestamp": "2025-01-05T12:34:56Z"
}
```

## Project Structure

```
claude-hud/
├── CLAUDE.md                    # This guide
├── package.json                 # Frontend dependencies
├── pnpm-lock.yaml               # Frontend lock file
├── tsconfig.json                # TypeScript configuration
├── vite.config.ts               # Frontend bundler config
├── src/                         # Frontend (Vue 3 + TypeScript)
│   ├── main.ts                  # Vue app entry point
│   ├── App.vue                  # Root component and router
│   ├── components/              # Reusable UI components
│   ├── views/                   # Page-level components
│   ├── stores/                  # Pinia state management
│   └── assets/                  # Static assets
├── dist/                        # Built frontend (generated by pnpm build)
└── src-tauri/                   # Rust backend (see src-tauri/CLAUDE.md for details)
    ├── src/
    │   ├── main.rs              # Tauri app entry point
    │   └── lib.rs               # Core backend (1,733 lines)
    ├── Cargo.toml               # Rust dependencies
    ├── tauri.conf.json          # App configuration
    ├── icons/                   # App icons (32x32, 128x128, etc.)
    ├── capabilities/            # Tauri security capabilities
    └── target/                  # Build artifacts
```

## IPC Communication Patterns

### Frontend → Backend (Commands)

```typescript
import { invoke } from '@tauri-apps/api/core';

// Invoke a backend command
const projects = await invoke('load_projects');

// With arguments
const details = await invoke('load_project_details', {
  path: '/Users/john/my-project'
});

// Background task (returns immediately, emits events)
await invoke('start_background_summaries', {
  session_paths: ['/path/to/session1.jsonl']
});
```

### Backend → Frontend (Events)

```typescript
import { listen } from '@tauri-apps/api/event';

// Listen for summary generation completion
const unlisten = await listen('summary-ready', (event) => {
  const [sessionPath, summaryText] = event.payload;
  // Update UI with new summary
});

// Other events: 'project-summary-ready', custom events
```

### Type Safety

Rust structs with `#[derive(Serialize, Deserialize)]` are automatically serialized to JSON and sent over IPC. The frontend must define matching TypeScript interfaces:

```rust
// Backend (lib.rs)
#[derive(Serialize, Deserialize, Clone)]
pub struct Project {
    pub name: String,
    pub path: String,
    pub stats: ProjectStats,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
}
```

```typescript
// Frontend (types.ts or component)
interface Project {
  name: string;
  path: string;
  stats: ProjectStats;
  summary?: string; // Optional in Rust = optional in TypeScript
}
```

**Important:** Field names, types, and optionality must match exactly. Use `#[serde(rename)]` in Rust to handle naming differences.

## Code Style & Conventions

### Backend (Rust)

- Prefer easy-to-read code over clever code
- Code should be self-documenting; avoid extraneous comments
- Required formatting: `cargo fmt` (before every commit)
- Linting: `cargo clippy -- -D warnings` must pass
- Single-file architecture: all code in `src/lib.rs`, no modules

### Frontend (TypeScript/Vue)

- Vue 3 Composition API only (no Options API per global instructions)
- TypeScript strict mode enabled
- ESLint enforced
- Prefer easy-to-read code over clever code
- Never use IIFEs in React components (Vue doesn't apply, but prefer clarity)

### Common Patterns

**Error Handling:**
- Backend: Return `Result<T, String>` (automatically propagated to frontend)
- Graceful degradation: File operations return empty/default on missing files
- Use `?` operator for error propagation

**File Operations:**
- Synchronous I/O via `std::fs` (blocking is acceptable for desktop)
- `walkdir` for directory traversal (with early extension filtering)
- `regex` for pattern matching in JSONL files
- No async I/O (single-threaded command handlers)

**Caching Strategy:**
- **Mtime-based invalidation:** Check file mtime against cached mtime
- Cache hits return immediately, cache misses recompute
- Old cache entries are harmless (ignored on mtime mismatch)
- Delete `~/.claude/hud-stats-cache.json` to force full recomputation

**Threading & Background Tasks:**
- `std::thread::spawn()` for non-blocking work
- `app_handle.emit()` sends events back to frontend
- Clone all necessary data before moving into thread closure
- No async/await (keep it simple for desktop app)

**Path Handling:**
- Paths encoded: `/Users/john/Code` → `-Users-john-Code` (separator replacement)
- Lossy encoding (can't distinguish hyphens from separators)
- `try_resolve_encoded_path()` intelligently reconstructs by checking directory existence
- Use `PathBuf` for cross-platform compatibility

**Serialization:**
- All data structures: `#[derive(Serialize, Deserialize, Clone, Debug)]`
- Tauri auto-serializes for IPC via `serde_json`
- Clone required for passing data between threads
- Use `#[serde(skip_serializing_if = "Option::is_none")]` for optional fields

## Key Algorithms

### Stats Computation (cache-aware)

1. Check if project path exists in `hud-stats-cache.json`
2. If not in cache → parse all .jsonl files, extract tokens via regex
3. If in cache → check if file mtime changed
4. Cache miss (mtime differs) → reparse file
5. Cache hit (mtime same) → return cached stats
6. Write updated cache back to disk

**Performance:** O(number of JSONL files), but cached by mtime so typically O(1) lookups.

### Session Summarization (async with threading)

1. Frontend invokes `generate_session_summary()` or `start_background_summaries()`
2. Backend checks cache (`hud-summaries.json`)
3. Cache miss → spawn thread, extract context, invoke Claude CLI
4. Validate summary with `is_bad_summary()` (rejects generic/empty summaries)
5. Store in cache, emit event to frontend
6. Frontend listens for "summary-ready" event, updates UI

**Performance:** ~1-2 seconds per summary via subprocess.

### Project Discovery (filesystem scan)

1. Load pinned projects from `hud.json`
2. For each pinned project:
   - Check if `.git`, `package.json`, `Cargo.toml`, etc. exist
   - Build Project struct
   - Compute stats (with cache)
3. Load suggested projects (projects with activity, not yet pinned)
4. Return combined results sorted by activity

## Common Development Scenarios

### Modifying Stats Parsing

Stats are extracted from JSONL via regex in `parse_stats_from_content()` (lines 196-255).

**To update token extraction:**
1. Modify regex patterns in `parse_stats_from_content()`
2. Test with actual JSONL: `cat ~/.claude/projects/{encoded-path}/*.jsonl | head -1 | jq .`
3. Delete cache to force recomputation: `rm ~/.claude/hud-stats-cache.json`
4. Run `cargo test` to verify

**Key patterns:**
- Input tokens: `"input_tokens":(\d+)`
- Output tokens: `"output_tokens":(\d+)`
- Model detection: `"model":"claude-([^"]+)"`
- Timestamps: `"timestamp":"([^"]+)"`

### Adding Project Type Detection

Detected in `has_project_indicators()` (lines 867-888).

**To add new indicator:**
1. Add file/directory check (e.g., `.myconfig` for new project type)
2. Update function to return true if found
3. Update frontend UI to show new project type badge (if desired)
4. Test by creating test project directory with indicator file

### Modifying Frontend/Backend Interface

When changing data structures:

1. **Backend:** Update struct in `lib.rs` (add/remove field)
2. **Serialization:** Update `#[derive(...)]` and serde attributes
3. **Frontend:** Update TypeScript interface to match
4. **IPC:** Ensure field names, types, optionality align
5. **Test:** Run `cargo tauri dev`, verify data loads in UI

### Debugging Stat Caching Issues

```bash
# Inspect cache file
cat ~/.claude/hud-stats-cache.json | jq '.projects' | head -20

# View a specific session file
cat "~/.claude/projects/-Users-petepetrash-Code-my-project/abc123.jsonl" | jq '.' | head -1

# Force cache reset
rm ~/.claude/hud-stats-cache.json
# Cache will be regenerated on next load

# Check file mtimes
ls -la ~/.claude/projects/-Users-petepetrash-Code-my-project/*.jsonl
stat ~/.claude/projects/-Users-petepetrash-Code-my-project/abc123.jsonl | grep Modify
```

## Performance Characteristics

| Operation | Complexity | Notes |
|-----------|-----------|-------|
| Stats computation | O(files) | Cached by mtime → O(1) typical |
| Project load | O(pinned) | Typically 1-5 projects |
| Session parsing | O(size) | Regex-based, fast for typical sizes |
| Artifact discovery | O(depth) | Early extension filtering |
| Summary generation | 1-2 sec | Via Claude CLI subprocess |
| Suggested projects scan | O(session dirs) | Linear but quick |

**Scaling considerations:**
- For >1000 session files per project: consider async file I/O
- For >100 pinned projects: consider pagination
- For slow networks: cache is local, no latency penalty

## Common Gotchas

**Frontend/Backend Type Sync:**
- Mismatched field names cause silent serialization failures
- Use `#[serde(rename)]` or `#[serde(default)]` for compatibility
- Test TypeScript interfaces with actual CLI dumps: `cat ~/.claude/hud.json | jq . | head -20`

**Path Encoding Issues:**
- `/` replaced with `-`: lossy for paths with hyphens
- Example: `/Users/john-doe/Code` ambiguous (is the `-` a hyphen or separator?)
- `try_resolve_encoded_path()` reconstructs by checking directory existence
- For debugging, check: `ls -la ~/.claude/projects/ | grep "your-path"`

**Cache Invalidation:**
- Mtime-based, not content-hash based
- File touch without content change triggers recomputation
- Manual reset: `rm ~/.claude/hud-stats-cache.json`
- Old entries are ignored (harmless), can accumulate over time

**Regex Failures:**
- Patterns assume JSONL format (one JSON per line)
- Malformed lines silently skipped (no error thrown)
- Test regex: `echo '{"input_tokens":123}' | rg 'input_tokens":(\d+)'`
- Complex multiline patterns require `(?s)` flag

**Platform-Specific Operations:**
- File open: macOS (`open`), Windows (`explorer`), Linux (`xdg-open`)
- Terminal: Warp integration via osascript (macOS only, returns error on other platforms)
- Git operations: Gracefully fallback if .git missing
- Path separators: PathBuf handles automatically

## Debugging Tips

```bash
# Inspect runtime state
cat ~/.claude/hud.json | jq .            # Pinned projects
cat ~/.claude/hud-stats-cache.json | jq . # Token stats cache
cat ~/.claude/plugins/installed_plugins.json | jq . # Plugin registry

# Check specific session file
cat ~/.claude/projects/-Users-petepetrash-Code-my-project/abc123.jsonl | jq . | head -20

# Run tests with output
cd src-tauri && cargo test -- --nocapture

# Enable debug logging
cd src-tauri && RUST_LOG=debug cargo tauri dev

# Validate regex patterns
echo '{"input_tokens":1234,"model":"claude-opus"}' | rg 'input_tokens":(\d+)'

# Check app logs (macOS)
cat ~/Library/Logs/Claude\ HUD/main.log | tail -50

# Verify TypeScript types match
pnpm type-check
```

## Testing Strategy

### Manual Testing Checklist

Before each release:
1. `cargo clippy -- -D warnings` passes
2. `cargo fmt` and `cargo test` pass
3. `pnpm lint` and `pnpm type-check` pass
4. Run dev mode: `cargo tauri dev` + manual flows
5. Test key user flows: load dashboard, add/remove projects, toggle plugins

### Unit Test Priority Areas

Currently no tests exist. Priority areas for future work:

**`parse_stats_from_content()`** - Regex extraction:
- Valid JSONL with all token fields
- Missing/malformed fields (defaults)
- Multiple model types (opus/sonnet/haiku)
- Malformed JSON (should skip gracefully, not panic)

**`parse_frontmatter()`** - YAML metadata:
- Valid frontmatter (name, description)
- Missing fields
- Invalid YAML syntax
- Empty files

**`try_resolve_encoded_path()`** - Path encoding:
- Simple paths
- Paths with hyphens in original
- Deep nested paths
- Ambiguous paths

**`compute_project_stats()`** - Caching logic:
- Cache hit (mtime unchanged)
- Cache miss (mtime changed, recomputes)
- New file (not in cache, computes)

## Dependencies

**Frontend (see package.json):**
- Vue 3 - UI framework
- TypeScript - Type safety
- Vite - Build tool
- Pinia - State management
- Tauri API - IPC bridge

**Backend (see src-tauri/Cargo.toml):**
- tauri 2.9.5 - Desktop framework
- serde / serde_json - JSON serialization
- regex 1.11 - Pattern matching
- walkdir 2.5 - Directory traversal
- dirs 6.0 - Platform-specific paths
- tauri-plugin-shell - Execute commands
- tauri-plugin-dialog - File dialogs
- tauri-plugin-log - Logging

## Useful Commands Reference

```bash
# Code quality (from src-tauri/)
cargo fmt                  # Format (required)
cargo clippy -- -D warnings # Lint all
cargo check                # Compile check

# Testing (from src-tauri/)
cargo test                 # Run all tests
cargo test pattern         # Run specific test
cargo test -- --nocapture # Show output

# Development
cd src-tauri && cargo tauri dev  # Watch mode
pnpm dev                         # Frontend dev server

# Production build
pnpm build && cd src-tauri && cargo tauri build

# Debugging
cat ~/.claude/hud-stats-cache.json | jq .
RUST_LOG=debug cargo tauri dev
```

## Important Architectural Notes

1. **Monolithic Backend:** All logic in one `src/lib.rs` file (1,733 lines). No modules or separation.

2. **Mtime-Based Caching:** Stats cache invalidated by file modification time, not content hash. Fast but can have edge cases with file touches.

3. **Synchronous I/O:** No async/await. Desktop app with blocking file operations. Consider async refactor if >1000 session files per project.

4. **Type Safety:** Rust structs auto-serialize to JSON. Frontend TypeScript interfaces must match exactly.

5. **Path Encoding:** `/` → `-` replacement. Lossy but recoverable via directory existence checks.

6. **Error Propagation:** `Result<T, String>` for IPC compatibility. Errors automatically sent to frontend.

7. **Cross-Platform:** Uses conditional compilation (`#[cfg(...)]`) for platform-specific operations.

8. **No async GUI:** Tauri command handlers are single-threaded. Background tasks use `std::thread::spawn()` with events.

See `src-tauri/CLAUDE.md` for additional backend-specific details.
