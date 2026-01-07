# Claude HUD - Project Development Guide

Claude HUD is a cross-platform desktop application that serves as a dashboard for Claude Code, displaying project statistics, task tracking, plugin management, and global Claude Code configuration insights. It combines a Rust backend (Tauri) with a TypeScript/React frontend.

> **Development Workflow:** The app should be running during development via `pnpm dev` (terminal 1) and `pnpm tauri dev` (terminal 2). Changes auto-rebuild and hot-reload. Claude should make changes incrementally and verify results in the running app.

## Project Overview

**Architecture:**
- **Frontend:** TypeScript with React 19 (located in `src/`)
  - Built to `dist/` directory for production
  - Dev server runs on `http://localhost:5173`
  - Single-file app architecture (`App.tsx`)
- **Backend:** Rust with Tauri v2.9.5 (located in `src-tauri/`)
  - Desktop application framework
  - IPC communication with frontend via Tauri commands
  - Handles file system access, subprocess execution, native dialogs
- **Build System:**
  - Frontend: pnpm + Vite
  - Backend: Cargo (Rust build system)
  - Desktop app bundling: Tauri CLI

**Tech Stack:**
- Node.js + TypeScript + React 19 + Tailwind CSS 4 + pnpm (Frontend)
- Rust 1.77.2+ with Tauri 2.9.5 (Backend)
- Cross-platform: macOS, Windows, Linux

## Development Workflow

### Quick Start

**IMPORTANT: The app should be running during development.** When making changes, the app auto-rebuilds and hot-reloads so you can immediately see results.

From the root `claude-hud/` directory, in **two separate terminals**:

**Terminal 1 - Frontend dev server:**
```bash
pnpm dev
```
Runs Vite dev server on `http://localhost:5173` with hot reload.

**Terminal 2 - Desktop app:**
```bash
pnpm tauri dev
```
Launches the Tauri app in dev mode, **watches for changes in both frontend and backend, and auto-rebuilds**.

The app automatically connects to the dev server at localhost:5173. Both processes must be running for development.

### Auto-Rebuild Behavior

When the app is running via `pnpm tauri dev`:
- **Frontend changes** (`src/*.tsx`, `src/*.css`) → Instant hot reload via Vite
- **Backend changes** (`src-tauri/src/*.rs`) → Auto-recompiles and restarts app (~5-10 seconds)

**Claude should keep the app running** and make changes incrementally. After each change, the app will automatically rebuild so you can verify the result immediately.

### Common Commands

All commands run from the root `claude-hud/` directory unless noted otherwise.

#### Frontend & App (pnpm)
```bash
pnpm dev          # Start frontend dev server
pnpm build        # Build frontend for production
pnpm tauri dev    # Launch app in dev mode (watches for changes)
pnpm tauri build  # Build app for distribution
pnpm preview      # Preview production build
pnpm lint         # Run ESLint
npx tsc --noEmit  # Run TypeScript type checking only
```

#### Backend (Cargo) - run from `src-tauri/`
```bash
cargo check       # Check code without building
cargo build       # Debug build
cargo build --release # Release build (optimized)
cargo fmt         # Format code (required before commits)
cargo clippy -- -D warnings  # Lint and catch common mistakes
cargo test        # Run all tests
cargo test test_name -- --nocapture  # Run specific test with output
```

### Building for Distribution

```bash
# From root directory
pnpm tauri build

# Build for specific platform
pnpm tauri build --target x86_64-apple-darwin  # macOS Intel
pnpm tauri build --target aarch64-apple-darwin # macOS Apple Silicon
pnpm tauri build --target x86_64-pc-windows-msvc # Windows
```

Built apps appear in `src-tauri/target/release/bundle/`.

## Project Structure

```
claude-hud/
├── CLAUDE.md                    # This file
├── docs/
│   └── claude-code-artifacts.md # Claude Code disk artifacts reference
├── package.json                 # Frontend dependencies
├── pnpm-lock.yaml               # Frontend lock file
├── tsconfig.json                # TypeScript configuration
├── tsconfig.app.json            # App-specific TS config
├── vite.config.ts               # Vite bundler config
├── index.html                   # HTML entry point
├── src/                         # Frontend React source
│   ├── main.tsx                 # React app entry
│   ├── App.tsx                  # Root component (1342 lines, contains all UI)
│   ├── types.ts                 # TypeScript interfaces (must match Rust structs)
│   ├── index.css                # Tailwind CSS + theme (oklch colors)
│   ├── lib/
│   │   └── utils.ts             # Utility functions (cn for class merging)
│   ├── components/
│   │   └── ui/                  # shadcn/ui components
│   │       ├── button.tsx
│   │       ├── badge.tsx
│   │       ├── card.tsx
│   │       ├── input.tsx
│   │       ├── switch.tsx
│   │       ├── table.tsx
│   │       ├── scroll-area.tsx
│   │       └── separator.tsx
│   └── assets/                  # Static assets
├── dist/                        # Built frontend (generated by pnpm build)
└── src-tauri/                   # Rust backend
    ├── src/
    │   ├── main.rs              # App entry point (6 lines)
    │   └── lib.rs               # Core application logic (1907 lines)
    ├── Cargo.toml               # Rust dependencies
    ├── tauri.conf.json          # Tauri app configuration
    ├── capabilities/            # Security capabilities
    └── icons/                   # App icons
```

## Frontend Architecture (React 19)

The frontend is a **single-file React application** (`src/App.tsx`, 1342 lines) that communicates with the backend exclusively through Tauri IPC.

### Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `src/App.tsx` | 1342 | All UI components, state, event handlers |
| `src/types.ts` | 90 | TypeScript interfaces (must match Rust structs) |
| `src/index.css` | 136 | Tailwind CSS theme with oklch colors |

### Architecture

- **State Management:** React `useState` hooks (no external state library)
- **IPC:** `invoke()` from `@tauri-apps/api/core` for commands
- **Events:** `listen()` from `@tauri-apps/api/event` for backend events
- **UI Components:** shadcn/ui (Radix primitives + Tailwind CSS)
- **Styling:** Tailwind CSS 4 with oklch color scheme, dark mode via system preference

### Navigation

Tab-based navigation with internal view states:
- `Tab = "projects" | "global" | "plugins" | "artifacts"`
- `ProjectView = "list" | "detail" | "add"`

### Panel Components (all in App.tsx)

| Component | Purpose |
|-----------|---------|
| `ProjectsPanel` | List of pinned projects with stats |
| `ProjectDetailPanel` | Project details, sessions, CLAUDE.md content |
| `AddProjectPanel` | Add projects via drag-drop, browse, or suggestions |
| `GlobalPanel` | Global Claude Code settings and directories |
| `PluginsPanel` | Plugin management with enable/disable toggles |
| `ArtifactsPanel` | Browse skills, commands, agents with filters |

### Type Safety

TypeScript interfaces in `src/types.ts` **must match** Rust struct definitions in `lib.rs`:

```typescript
// Frontend (src/types.ts)
export interface ProjectStats {
  total_input_tokens: number;
  total_output_tokens: number;
  // ... must match Rust exactly
}
```

```rust
// Backend (src-tauri/src/lib.rs)
pub struct ProjectStats {
    pub total_input_tokens: u64,
    pub total_output_tokens: u64,
    // ... serialized to JSON
}
```

## Backend Architecture (Rust/Tauri)

The backend (`src-tauri/src/lib.rs`, 1907 lines) is the single source of truth for application logic.

### Data Structures (lines 10-136)
- **GlobalConfig:** Claude Code global settings (skills, commands, agents directories)
- **Project/ProjectDetails/Task:** Project tracking and session management
- **ProjectStats:** Token usage analytics and caching
- **Plugin:** Plugin registry with artifact counts
- **HudConfig:** Pinned projects persistent state

### Key Functions

**Configuration & Paths (lines 154-195):**
- `get_claude_dir()` - Resolves `~/.claude` directory
- `load_hud_config()` / `save_hud_config()` - Pinned projects persistence
- `load_stats_cache()` / `save_stats_cache()` - Token stats caching

**Statistics & Parsing (lines 196-326):**
- `parse_stats_from_content()` - Regex extraction from JSONL session files
- `compute_project_stats()` - Intelligent caching with file mtime tracking
- Tracks input/output tokens, cache tokens, model usage (Opus/Sonnet/Haiku)

**Project Discovery (lines 937-1039):**
- `has_project_indicators()` - Detects project types (.git, package.json, Cargo.toml, etc.)
- `build_project_from_path()` - Constructs Project objects
- `load_projects_internal()` - Loads pinned projects sorted by activity

**Session Summarization (lines 569-605, 1462-1718):**
- `generate_session_summary_sync()` - Summary generation via Claude CLI
- `start_background_summaries()` - Background thread-based generation
- Caches in `~/.claude/hud-summaries.json`

### IPC Commands (14 total, lines 839-1903)

| Command | Purpose | Returns |
|---------|---------|---------|
| `load_dashboard` | All dashboard data | `DashboardData` |
| `load_projects` | Pinned projects only | `Vec<Project>` |
| `load_project_details` | Project with tasks and git status | `ProjectDetails` |
| `load_artifacts` | All skills/commands/agents | `Vec<Artifact>` |
| `toggle_plugin` | Enable/disable plugins | `()` |
| `read_file_content` | Read arbitrary files | `String` |
| `open_in_editor` / `open_folder` / `launch_in_terminal` | Platform-specific operations | `()` |
| `add_project` / `remove_project` | Manage pinned projects | `()` |
| `load_suggested_projects` | Discover projects with activity | `Vec<SuggestedProject>` |
| `generate_session_summary` | On-demand summary generation | `String` |
| `start_background_summaries` / `start_background_project_summaries` | Background tasks | `()` |

### Key Patterns

**Error Handling:**
- Functions return `Result<T, String>` for Tauri IPC compatibility
- File operations gracefully degrade (return empty defaults on missing files)

**Caching:**
- Stats cache uses mtime-based invalidation
- Summary cache persists generated summaries to avoid re-computation

**Threading:**
- `std::thread::spawn()` for background tasks
- `app_handle.emit()` sends events back to frontend

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

## Common Development Scenarios

### Adding a New Dashboard Tab

1. **Backend:** Add `#[tauri::command]` function in `src-tauri/src/lib.rs`
2. **Backend:** Register in `invoke_handler` (line ~1887)
3. **Frontend:** Add to `Tab` type union in `App.tsx`
4. **Frontend:** Add `SidebarItem` in navigation
5. **Frontend:** Create panel component and add conditional render in `<main>`
6. **Types:** Ensure TypeScript types in `types.ts` match backend structs

### Modifying Statistics Parsing
- Update regex patterns in `parse_stats_from_content()` (lib.rs:196-255)
- Update `ProjectStats` struct in both Rust and TypeScript
- Delete `~/.claude/hud-stats-cache.json` to force recomputation

### Adding Project Type Detection
- Modify `has_project_indicators()` (lib.rs:937-958)
- Add file/directory checks for new project type

## Code Style & Conventions

**Backend (Rust):**
- Use `cargo fmt` for formatting (required)
- Run `cargo clippy -- -D warnings` for linting
- Prefer easy-to-read code over clever code
- No extraneous comments; code should be self-documenting

**Frontend (TypeScript/React):**
- No IIFEs in React components
- ESLint configured in project
- TypeScript strict mode enabled
- Prefer easy-to-read code over clever code

## Debugging

**Backend:**
```bash
# Inspect cache files
cat ~/.claude/hud-stats-cache.json | jq .

# Enable debug logging
RUST_LOG=debug pnpm tauri dev

# Test regex patterns
echo '{"input_tokens":1234}' | rg 'input_tokens":(\d+)'
```

**Frontend:**
- Chrome DevTools via right-click "Inspect" in app window
- Check browser console for IPC errors

## Key Dependencies

**Frontend:**
- React 19 - UI framework
- TypeScript - Type safety
- Vite - Build tool
- Tailwind CSS 4 - Styling
- Radix UI - Accessible primitives
- Tauri API - IPC bridge

**Backend:**
- Tauri 2.9.5 - Desktop app framework
- Serde - JSON serialization
- Regex - Pattern matching in session files
- Walkdir - Directory traversal
- Dirs - Platform-specific paths

## Important Notes

- **Path Encoding:** Project paths use `/` → `-` replacement (e.g., `/Users/peter/Code` → `-Users-peter-Code`)
- **IPC Communication:** Frontend must always go through Tauri commands; never access file system directly
- **Frontend Build:** `pnpm tauri build` automatically runs `pnpm build` first via `beforeBuildCommand`
- **Caching Strategy:** Mtime-based invalidation; old cache entries are harmless
- **Platform Support:** Code handles Windows, macOS (Intel/ARM), and Linux
- **Claude CLI Path:** Summary generation uses `/opt/homebrew/bin/claude` (macOS Homebrew)

For detailed backend documentation, refer to `src-tauri/CLAUDE.md`.
