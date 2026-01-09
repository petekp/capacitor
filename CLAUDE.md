# Claude HUD - Project Development Guide

Claude HUD is a cross-platform desktop application that serves as a dashboard for Claude Code, displaying project statistics, task tracking, plugin management, and global Claude Code configuration insights. It combines a Rust backend (Tauri) with a TypeScript/React frontend.

> **Development Workflow:** Run `pnpm tauri dev` to start the app. This automatically starts the frontend dev server and launches the desktop app. Changes auto-rebuild and hot-reload. Claude should make changes incrementally and verify results in the running app.

## Product Vision

**Claude HUD lets you develop and ship more projects in parallel by eliminating the cognitive overhead of context-switching.** Instead of remembering where you left off across a dozen projects, the HUD shows you—automatically, at a glance. Wake up, open the app, pick a project, and resume instantly.

**The core problem:** When you have many Claude Code projects in flight simultaneously, context-switching is expensive. You lose track of what you were working on, what the next step was, and whether you're blocked. Without visibility, projects stall and momentum is lost. The cognitive load of "remembering where everything is at" limits how many projects you can realistically push forward.

**The insight:** Claude already knows what you were doing in each project. The HUD surfaces that context automatically via hooks—so you don't have to maintain a separate system or hold it all in your head.

**Target use case:** You wake up, open Claude HUD, see all your projects with their current status, know exactly where each one stands, pick the one that makes sense to work on, and jump in with full context—in seconds, not minutes.

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

From the root `claude-hud/` directory:

```bash
pnpm tauri dev
```

This single command:
- Starts the Vite dev server on `http://localhost:5173` (via `beforeDevCommand`)
- Launches the Tauri desktop app
- Watches for changes in both frontend and backend, and auto-rebuilds

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
│   ├── claude-code-artifacts.md # Claude Code disk artifacts reference
│   ├── tauri-capabilities.md    # Tauri process/terminal capabilities reference
│   └── cc/                      # Claude Code official documentation (52 files)
├── scripts/
│   └── fetch-cc-docs.ts         # Script to update Claude Code docs
├── package.json                 # Frontend dependencies
├── pnpm-lock.yaml               # Frontend lock file
├── tsconfig.json                # TypeScript configuration
├── tsconfig.app.json            # App-specific TS config
├── vite.config.ts               # Vite bundler config
├── index.html                   # HTML entry point
├── src/                         # Frontend React source
│   ├── main.tsx                 # React app entry
│   ├── App.tsx                  # Root component (~476 lines, state and handlers)
│   ├── types.ts                 # TypeScript interfaces (must match Rust structs)
│   ├── index.css                # Tailwind CSS + theme (oklch colors)
│   ├── lib/
│   │   └── utils.ts             # Utility functions (cn for class merging)
│   ├── utils/
│   │   ├── format.ts            # formatTokenCount, formatCost
│   │   └── pricing.ts           # PRICING constants, calculateCost
│   ├── hooks/
│   │   ├── useWindowPersistence.ts  # Window position save/restore
│   │   ├── useTheme.ts              # Dark mode detection
│   │   ├── useFocusOnHover.ts       # Auto-focus on mouse enter
│   │   └── useNotificationSound.ts  # Ready notification sound
│   ├── components/
│   │   ├── Icon.tsx             # SVG icon component
│   │   ├── TabButton.tsx        # Header tab button
│   │   ├── ProjectCard.tsx      # Full project card
│   │   ├── CompactProjectCard.tsx  # Compact project card
│   │   ├── ui/                  # shadcn/ui components
│   │   │   ├── button.tsx
│   │   │   ├── badge.tsx
│   │   │   ├── card.tsx
│   │   │   ├── input.tsx
│   │   │   ├── switch.tsx
│   │   │   ├── table.tsx
│   │   │   ├── scroll-area.tsx
│   │   │   └── separator.tsx
│   │   └── panels/
│   │       ├── ProjectsPanel.tsx     # Project list view
│   │       ├── ProjectDetailPanel.tsx # Project details view
│   │       ├── AddProjectPanel.tsx    # Add project form
│   │       └── ArtifactsPanel.tsx     # Artifacts and plugins
│   └── assets/                  # Static assets
├── dist/                        # Built frontend (generated by pnpm build)
└── src-tauri/                   # Rust backend
    ├── src/
    │   ├── main.rs              # App entry point (6 lines)
    │   ├── lib.rs               # IPC commands and business logic (~2376 lines)
    │   ├── types.rs             # Public type definitions (~183 lines)
    │   ├── patterns.rs          # Compiled regex patterns (~39 lines)
    │   ├── config.rs            # Config and path utilities (~51 lines)
    │   └── stats.rs             # Statistics parsing and caching (~143 lines)
    ├── Cargo.toml               # Rust dependencies
    ├── tauri.conf.json          # Tauri app configuration
    ├── capabilities/            # Security capabilities
    └── icons/                   # App icons
```

## Frontend Architecture (React 19)

The frontend is a **modular React application** with state management in `App.tsx` (~476 lines) and UI components extracted into separate files. It communicates with the backend exclusively through Tauri IPC.

### Key Files

| File | Purpose |
|------|---------|
| `src/App.tsx` | State, event handlers, top-level layout |
| `src/types.ts` | TypeScript interfaces (must match Rust structs) |
| `src/index.css` | Tailwind CSS theme with oklch colors |
| `src/hooks/*.ts` | Custom hooks for window, theme, focus, audio |
| `src/utils/*.ts` | Formatting and pricing utilities |
| `src/components/panels/*.tsx` | Panel components (Projects, Details, Add, Artifacts) |

### Architecture

- **State Management:** React `useState` hooks (no external state library)
- **IPC:** `invoke()` from `@tauri-apps/api/core` for commands
- **Events:** `listen()` from `@tauri-apps/api/event` for backend events
- **UI Components:** shadcn/ui (Radix primitives + Tailwind CSS)
- **Styling:** Tailwind CSS 4 with oklch color scheme, dark mode via system preference
- **Custom Hooks:** Window persistence, theme detection, focus-on-hover, notification sounds

### Navigation

Tab-based navigation with internal view states:
- `Tab = "projects" | "artifacts"`
- `ProjectView = "list" | "detail" | "add"`

### Panel Components (in `src/components/panels/`)

| Component | Purpose |
|-----------|---------|
| `ProjectsPanel` | List of pinned projects with stats |
| `ProjectDetailPanel` | Project details, sessions, CLAUDE.md content |
| `AddProjectPanel` | Add projects via drag-drop, browse, or suggestions |
| `ArtifactsPanel` | Browse skills, commands, agents, and manage plugins |

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

The backend is organized into modules under `src-tauri/src/`:

| Module | Purpose |
|--------|---------|
| `lib.rs` | IPC command handlers and business logic (~2376 lines) |
| `types.rs` | Public structs: Project, Task, Artifact, Plugin, etc. |
| `patterns.rs` | Pre-compiled regex patterns for JSONL parsing |
| `config.rs` | Path resolution and config file operations |
| `stats.rs` | Token usage parsing and mtime-based caching |

### Data Structures (in `types.rs`)
- **GlobalConfig:** Claude Code global settings (skills, commands, agents directories)
- **Project/ProjectDetails/Task:** Project tracking and session management
- **ProjectStats:** Token usage analytics and caching
- **Plugin:** Plugin registry with artifact counts
- **HudConfig:** Pinned projects persistent state

### Key Functions

**Configuration & Paths (in `config.rs`):**
- `get_claude_dir()` - Resolves `~/.claude` directory
- `load_hud_config()` / `save_hud_config()` - Pinned projects persistence
- `load_stats_cache()` / `save_stats_cache()` - Token stats caching

**Statistics & Parsing (in `stats.rs`):**
- `parse_stats_from_content()` - Regex extraction from JSONL session files
- `compute_project_stats()` - Intelligent caching with file mtime tracking
- Tracks input/output tokens, cache tokens, model usage (Opus/Sonnet/Haiku)

**Project Discovery (in `lib.rs`):**
- `has_project_indicators()` - Detects project types (.git, package.json, Cargo.toml, etc.)
- `build_project_from_path()` - Constructs Project objects
- `load_projects_internal()` - Loads pinned projects sorted by activity

**Session Summarization (in `lib.rs`):**
- `generate_session_summary_sync()` - Summary generation via Claude CLI
- `start_background_summaries()` - Background thread-based generation
- Caches in `~/.claude/hud-summaries.json`

### IPC Commands (in `lib.rs`)

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

## Claude Code Documentation Reference

**IMPORTANT:** When working on features that integrate with Claude Code (hooks, plugins, settings, MCP, sessions, etc.), always consult the official documentation in `docs/cc/`. This ensures implementations align with current Claude Code behavior and APIs.

**Key documentation files:**

| Topic | File | Use When |
|-------|------|----------|
| Hooks | `docs/cc/hooks.md`, `docs/cc/hooks-guide.md` | Implementing hook-based features |
| Plugins | `docs/cc/plugins.md`, `docs/cc/plugins-reference.md` | Plugin management, discovery |
| Settings | `docs/cc/settings.md` | Reading/displaying Claude Code config |
| MCP | `docs/cc/mcp.md` | Model Context Protocol integration |
| Sessions | `docs/cc/interactive-mode.md` | Session file parsing, history |
| CLI | `docs/cc/cli-reference.md` | Invoking Claude Code programmatically |
| Memory | `docs/cc/memory.md` | CLAUDE.md files, project context |
| Sub-agents | `docs/cc/sub-agents.md` | Task tool, agent spawning |

**Updating docs:** Run `pnpm fetch-cc-docs` to pull the latest documentation from the official sources. The docs are mirrored from [ericbuess/claude-code-docs](https://github.com/ericbuess/claude-code-docs) which syncs every 3 hours.

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
