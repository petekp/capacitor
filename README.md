# Capacitor

A native macOS dashboard for [Claude Code](https://claude.ai/claude-code) — see what Claude is doing across all your projects at a glance.

## What is Capacitor?

Capacitor is a **sidecar app** that gives you real-time visibility into your Claude Code sessions. Instead of switching between terminal windows to check if Claude is done thinking, Capacitor shows you the state of every project in one place.

**Key idea:** Capacitor reads from your existing Claude Code installation (`~/.claude/`) and invokes the CLI for AI features. No separate API key needed.

## Features

### Real-Time Session Tracking
See what Claude is doing right now:
- **Working** — Claude is generating a response
- **Ready** — Waiting for your input
- **Compacting** — Context is being summarized
- **Idle** — No active session

### Project Dashboard
- Pin your active projects for quick access
- Drag to reorder by priority
- See recent activity summaries
- One-click to open project in terminal

### Idea Capture
Capture ideas without breaking your flow:
- Full-canvas modal overlay (⌘+I from any project)
- AI-powered enrichment (priority, effort, tags)
- Per-project idea queues with drag-to-reorder
- Markdown storage — your ideas stay yours

### Dual Layout Modes
- **Vertical** — Full dashboard with navigation and details
- **Dock** — Compact horizontal strip for screen edge docking

### Project Statistics
- Token usage (input, output, cache)
- Model distribution (Opus/Sonnet/Haiku)
- Session history and activity timeline

## Supported Workflows

Capacitor works best when you run Claude Code in standalone terminal apps. IDE integrated terminals work for session tracking, but have limitations for project switching.

### Terminals ✅

These terminal emulators are fully supported with one-click project activation:

| Terminal | Session Tracking | Project Switching | Notes |
|----------|-----------------|-------------------|-------|
| **Ghostty** | ✅ | ✅ | Recommended — fast, modern |
| **iTerm2** | ✅ | ✅ | Full tab selection via AppleScript |
| **Terminal.app** | ✅ | ✅ | Full tab selection via AppleScript |
| **Alacritty** | ✅ | ✅ | Window activation |
| **kitty** | ✅ | ✅ | Requires `allow_remote_control yes` in config |
| **Warp** | ✅ | ⚠️ | No tab selection API — activates app only |

### Shells ✅

Shell integration tracks your current working directory for ambient project awareness:

| Shell | Support | Setup |
|-------|---------|-------|
| **Zsh** | ✅ | Via `precmd_functions` |
| **Bash** | ✅ | Via `PROMPT_COMMAND` |
| **Fish** | ✅ | Via `fish_postexec` event |

Shell setup snippets are provided in the app's Setup card.

### IDEs ⚠️

Claude Code sessions in IDE integrated terminals are tracked, but project switching has limitations:

| IDE | Session Tracking | Project Switching | Notes |
|-----|-----------------|-------------------|-------|
| **Cursor** | ✅ | ⚠️ | Opens project, but can't focus terminal panel |
| **VS Code** | ✅ | ⚠️ | Opens project, but can't focus terminal panel |
| **VS Code Insiders** | ✅ | ⚠️ | Same as VS Code |

**Why the limitation?** IDEs don't expose APIs to focus the integrated terminal programmatically. Capacitor can open the correct project window, but you'll need to manually focus the terminal panel (usually `Ctrl+\``).

### Terminal Multiplexers

| Multiplexer | Support | Notes |
|-------------|---------|-------|
| **tmux** | ✅ | Full support — detects sessions, switches clients, tracks host terminal |
| **screen** | ❌ | Not yet implemented |

### What Doesn't Work Yet

- **IDE terminal focus** — Can't programmatically focus the terminal panel within Cursor/VS Code
- **Warp/Ghostty tab selection** — These terminals don't expose tab selection APIs
- **GNU Screen** — Only tmux is supported for multiplexer workflows
- **SSH sessions** — Remote sessions aren't detected or tracked

## Requirements

- **Apple Silicon Mac** (M1/M2/M3/M4) — Intel Macs are not supported
- **macOS 14.0+** (Sonoma or later)
- **Claude Code** installed and configured
- **Rust 1.77+** and **Swift 5.9+** (for building from source)

## Installation

### From Release (Recommended)

Download the latest DMG from [Releases](https://github.com/petekp/capacitor/releases), open it, and drag Capacitor to Applications.

The app includes Sparkle for automatic updates.

### Building from Source

```bash
# Clone and setup (installs toolchains, builds everything, configures hooks)
git clone https://github.com/petekp/capacitor.git
cd capacitor
./scripts/dev/setup.sh

# Run the app
./scripts/dev/restart-app.sh
```

## Setup

### Enable Session Tracking

Capacitor tracks session state via Claude Code hooks. To enable:

1. Install the hook binary:
   ```bash
   ./scripts/sync-hooks.sh
   ```

2. Launch the app. If hooks aren't configured, you'll see a setup card with a "Fix All" button that automatically configures your `~/.claude/settings.json`.

   **Or manually** add hooks to your Claude Code settings (`~/.claude/settings.json`):
   ```json
   {
     "hooks": {
       "SessionStart": [{ "hooks": [{ "type": "command", "command": "CAPACITOR_DAEMON_LOCK_HEALTH=auto $HOME/.local/bin/hud-hook handle", "async": true, "timeout": 30 }] }],
       "SessionEnd": [{ "hooks": [{ "type": "command", "command": "CAPACITOR_DAEMON_LOCK_HEALTH=auto $HOME/.local/bin/hud-hook handle" }] }],
       "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "CAPACITOR_DAEMON_LOCK_HEALTH=auto $HOME/.local/bin/hud-hook handle", "async": true, "timeout": 30 }] }],
       "PreToolUse": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "CAPACITOR_DAEMON_LOCK_HEALTH=auto $HOME/.local/bin/hud-hook handle", "async": true, "timeout": 30 }] }],
       "PostToolUse": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "CAPACITOR_DAEMON_LOCK_HEALTH=auto $HOME/.local/bin/hud-hook handle", "async": true, "timeout": 30 }] }],
       "PermissionRequest": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "CAPACITOR_DAEMON_LOCK_HEALTH=auto $HOME/.local/bin/hud-hook handle", "async": true, "timeout": 30 }] }],
       "Stop": [{ "hooks": [{ "type": "command", "command": "CAPACITOR_DAEMON_LOCK_HEALTH=auto $HOME/.local/bin/hud-hook handle", "async": true, "timeout": 30 }] }],
       "PreCompact": [{ "hooks": [{ "type": "command", "command": "CAPACITOR_DAEMON_LOCK_HEALTH=auto $HOME/.local/bin/hud-hook handle", "async": true, "timeout": 30 }] }],
       "Notification": [{ "hooks": [{ "type": "command", "command": "CAPACITOR_DAEMON_LOCK_HEALTH=auto $HOME/.local/bin/hud-hook handle", "async": true, "timeout": 30 }] }]
     }
   }
   ```

   Note: `SessionEnd` runs synchronously (no `async`/`timeout`) to ensure cleanup completes before the session exits.

3. Restart any active Claude Code sessions.

### Add Projects

Click the **+** button in Capacitor to add project folders. Capacitor will detect Claude Code projects by looking for:
- `CLAUDE.md` file
- `.claude/` directory
- `.git/` directory
- `package.json`, `Cargo.toml`, etc.

## Architecture

```
capacitor/
├── core/hud-core/       # Rust business logic
│   └── src/
│       ├── engine.rs    # FFI facade (UniFFI)
│       ├── sessions.rs  # Session state detection
│       ├── projects.rs  # Project management
│       ├── ideas.rs     # Idea capture system
│       └── stats.rs     # Token usage parsing
│
├── core/hud-hook/       # Rust CLI hook handler
│   └── src/
│       ├── handle.rs    # Hook event processing
│       └── cwd.rs       # Shell CWD tracking
│
├── apps/swift/          # SwiftUI macOS app
│   └── Sources/Capacitor/
│       ├── Models/      # AppState, managers
│       ├── Views/       # UI components
│       └── Bridge/      # UniFFI bindings
│
└── scripts/             # Build and release tools
```

**Design principle:** Capacitor is a sidecar, not a replacement. It leverages Claude Code's existing infrastructure rather than duplicating it.

## Development

### Quick Start

```bash
# Format and lint Rust
cargo fmt && cargo clippy -- -D warnings

# Run Rust tests
cargo test

# Build and run the app
cargo build -p hud-core --release
cd apps/swift && swift run
```

### Useful Scripts

```bash
# Restart the app (rebuilds and relaunches)
./scripts/dev/restart-app.sh

# Run all tests (Rust + Swift + bash)
./scripts/dev/run-tests.sh

# Build distribution ZIP
./scripts/release/build-distribution.sh

# Create DMG installer
./scripts/release/create-dmg.sh
```

### Project Structure

| Directory | Purpose |
|-----------|---------|
| `core/hud-core/` | Rust library with business logic |
| `core/hud-hook/` | Rust CLI hook handler binary |
| `apps/swift/` | SwiftUI application |
| `scripts/` | Build, test, and release automation |
| `tests/` | Integration tests |

### Documentation

| Location | What's There |
|----------|--------------|
| `CLAUDE.md` | Project context, commands, gotchas — **start here** |
| `.claude/docs/` | Development workflows, architecture deep-dives, debugging |
| `.claude/plans/` | Implementation plans for features |
| `docs/` | Release procedures, ADRs, Claude Code CLI reference |

## How Session Tracking Works

1. **Hooks** — Claude Code fires events (SessionStart, Stop, etc.) that run the `hud-hook` binary
2. **State file** — The hook writes JSON to `~/.capacitor/sessions.json`
3. **Lock files** — The hook creates locks at `~/.capacitor/sessions/{hash}.lock/`
4. **Capacitor reads** — The app polls these files and resolves the current state

The state resolver handles edge cases like:
- Multiple sessions in the same project
- Crashed sessions (stale locks with dead PIDs)
- Monorepo projects with nested paths

## Data Storage

Capacitor uses two namespaces:

**`~/.capacitor/`** — owned by Capacitor:
```
~/.capacitor/
├── config.json                 # App preferences
├── projects.json               # Tracked projects list
├── sessions.json               # Current session states
├── sessions/                   # Lock directories ({hash}.lock/)
├── stats-cache.json            # Token usage cache
├── summaries.json              # Session summaries
├── shell-cwd.json              # Active shell CWD tracking
├── shell-history.jsonl         # CWD change history (30-day retention)
└── projects/{encoded-path}/    # Per-project data (ideas, order)
```

**`~/.claude/`** — owned by Claude Code CLI (read-only for Capacitor):
```
~/.claude/
├── settings.json               # Hooks configuration
└── projects/                   # Session transcripts
```

## Contributing

Contributions are welcome! Please:

1. Run `cargo fmt` and `cargo clippy -- -D warnings` before committing
2. Add tests for new functionality
3. Update documentation for user-facing changes
4. Follow the existing code style

See `.claude/docs/development-workflows.md` for detailed setup instructions.

## License

MIT

## Acknowledgments

Built with:
- [UniFFI](https://mozilla.github.io/uniffi-rs/) — Rust to Swift bindings
- [Sparkle](https://sparkle-project.org/) — macOS software updates
- [Variablur](https://github.com/daprice/Variablur) — Variable blur effects

---

*Capacitor is an independent project and is not affiliated with Anthropic.*
